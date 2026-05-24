import Foundation
import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Resize + re-encode photo data for storage or temporary OCR prep.
/// Used by every photo entry point — gallery picks, step picks,
/// Detail-quick-edit, and import-from-photo. One implementation,
/// several callers; see [Photo-Capability.md §4](../../../Photo-Capability.md).
///
/// **Why ImageIO and not UIImage round-trips:**
///
/// - `CGImageSourceCreateThumbnailAtIndex` decodes at the target
///   resolution rather than fully decoding the source first, so a 12MP
///   HEIC stays under ~30MB of peak memory instead of ~150MB.
/// - `kCGImageSourceCreateThumbnailWithTransform = true` bakes EXIF
///   orientation into the output bytes — no `.imageOrientation` round
///   trip required, no portrait shots flipped sideways downstream.
/// - `CGImageDestination` writes directly to HEIC / JPEG without going
///   through a UIImage representation, which keeps us off the UIKit
///   allocator for the heavy lifting.
///
/// **Format preservation:** HEIC source -> HEIC out, JPEG -> JPEG out.
/// Anything else (PNG screenshots, BMP, TIFF) re-encodes to JPEG @ 0.85.
/// Choosing the source format keeps the user's intent intact when it
/// makes sense (HEIC stays small) and fails over to JPEG when the
/// source format isn't worth preserving for storage.
enum ImageProcessing {
    /// Different callers get different pixel budgets: gallery photos
    /// are viewed full-screen, step images render smaller in Cook Mode,
    /// OCR gets a sharper temporary image for text recognition, and the
    /// AI vision import path uses a payload-friendly size matched to
    /// Anthropic's recommended max long edge.
    enum Target {
        case gallery
        case step
        case ocr
        case aiVision

        /// Long-edge ceiling in pixels. Source images smaller than this
        /// pass through without upscaling (the thumbnail API caps at the
        /// source size automatically).
        ///
        /// The `.aiVision` ceiling is 1568px because Anthropic's vision
        /// docs recommend that exact value as the largest input that
        /// avoids server-side downscaling — going higher costs tokens
        /// and bandwidth without giving the model more signal.
        var maxLongEdgePixels: Int {
            switch self {
            case .gallery:  return 1920
            case .step:     return 1280
            case .ocr:      return 2560
            case .aiVision: return 1568
            }
        }

        /// JPEG quality for fallback re-encodes. HEIC ignores this and
        /// uses its own internal rate-distortion knob (so this only
        /// matters when the source is a non-HEIC format or when the
        /// target forces JPEG output via `forcesJPEGOutput`).
        var jpegQuality: CGFloat {
            switch self {
            case .gallery:  return 0.85
            case .step:     return 0.82
            case .ocr:      return 0.92
            case .aiVision: return 0.85
            }
        }

        /// `.aiVision` always emits JPEG because Anthropic's vision API
        /// only accepts image/jpeg, image/png, image/gif, image/webp —
        /// not HEIC. Forcing JPEG here keeps the upload format valid
        /// regardless of source camera/library format.
        var forcesJPEGOutput: Bool {
            self == .aiVision
        }
    }

    /// Resize + re-encode `source` for the given target. Returns nil on
    /// undecodable input (corrupt picker output, exotic format with no
    /// ImageIO support). Cheap fallback at the call site is "store the
    /// source bytes anyway" — but that's the caller's choice; this
    /// function refuses to fabricate output.
    ///
    /// **Bytes guard:** for stored gallery/step photos, if the re-encoded
    /// output is larger than the source (rare, mostly happens with
    /// already-tiny inputs), the source bytes are returned instead. OCR
    /// always keeps the resized/oriented copy because it is temporary and
    /// the pixel cap matters more than byte size.
    ///
    /// Run from `Task.detached` — a 12MP source takes ~150-300ms on a
    /// recent device. The editor stays responsive because the picker
    /// callback doesn't block the main actor while this runs.
    static func prepare(_ source: Data, for target: Target) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            prepareSync(source, for: target)
        }.value
    }

    // MARK: - Synchronous core

    private static func prepareSync(_ source: Data, for target: Target) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(
            source as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }

        let outputType = target.forcesJPEGOutput ? UTType.jpeg : pickOutputType(for: imageSource)

        // For .aiVision, satisfy both the 1568px long-edge cap AND a ~1.2 MP
        // pixel cap so Anthropic doesn't server-resize common portrait shots.
        // Server-side downscaling increases time-to-first-token without
        // giving the model more signal. Other targets keep the simple cap.
        let maxPixelSize: Int
        if case .aiVision = target,
           let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0 {
            let scale = min(
                1.0,
                1568.0 / Double(max(w, h)),
                sqrt(1_200_000.0 / Double(w * h))
            )
            maxPixelSize = max(1, Int((Double(max(w, h)) * scale).rounded(.down)))
        } else {
            maxPixelSize = target.maxLongEdgePixels
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            thumbOptions as CFDictionary
        ) else {
            return nil
        }

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            outputType.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        var destinationOptions: [CFString: Any] = [:]
        if outputType == .jpeg {
            destinationOptions[kCGImageDestinationLossyCompressionQuality] = target.jpegQuality
        }
        CGImageDestinationAddImage(destination, thumb, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let encoded = destinationData as Data
        // OCR and AI-vision are temporary uploads where pixel/format
        // discipline matters more than byte size — always return the
        // re-encoded copy so callers get a guaranteed-shape payload.
        if case .ocr = target { return encoded }
        if case .aiVision = target { return encoded }
        // If the round-trip somehow inflated the bytes — rare, but real
        // for already-small inputs (e.g. a 200KB screenshot re-encoding
        // to ~250KB JPEG) — return the source unchanged. Better to keep
        // the user's original than to actively make things worse.
        return encoded.count < source.count ? encoded : source
    }

    /// Prepare directly from a `UIImage` (camera capture path) without first
    /// round-tripping to lossy JPEG `Data`. The camera path can't hand us the
    /// original sensor bytes — `UIImagePickerController` decodes them to
    /// `UIImage` before we get them — so the best we can do is encode the
    /// in-memory `CGImage` exactly once at the target format. Going through
    /// `UIImage.jpegData(compressionQuality:)` first adds an unnecessary
    /// lossy pass that measurably degrades handwriting recognition on dim
    /// photos; the library path's `loadTransferable(type: Data.self)`
    /// already hands us raw bytes so it doesn't suffer this.
    ///
    /// Orientation is baked in by drawing the `UIImage` through a
    /// `UIGraphicsImageRenderer` before reading `.cgImage`. The underlying
    /// CGImage on a camera capture is often pixel-rotated relative to its
    /// display orientation (portrait photos commonly carry `.right`
    /// orientation); writing the raw CGImage would send Sonnet a sideways
    /// image. Returns nil only when the `UIImage` has no backing pixels.
    static func prepare(uiImage: UIImage, for target: Target) async -> Data? {
        guard uiImage.cgImage != nil else { return nil }
        let upright = bakeOrientation(uiImage)
        guard let cgImage = upright.cgImage else { return nil }
        return await prepare(cgImage: cgImage, for: target)
    }

    /// Render `image` into a new bitmap with its `.imageOrientation`
    /// applied as a pixel transform, so the resulting `cgImage` is
    /// display-upright. No-op (returns the input) when the image is
    /// already in `.up` orientation — the common library-load case.
    private static func bakeOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Resize + encode a `CGImage` for the given target. Single lossy pass
    /// at the destination format; no intermediate `Data` round-trip. Used
    /// by the camera capture path where we hold a `UIImage` rather than
    /// raw photo bytes.
    static func prepare(cgImage: CGImage, for target: Target) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            prepareCGImageSync(cgImage, for: target)
        }.value
    }

    private static func prepareCGImageSync(_ cgImage: CGImage, for target: Target) -> Data? {
        let srcWidth  = cgImage.width
        let srcHeight = cgImage.height
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        // Mirror the `.aiVision` dual cap (long-edge + ~1.2 MP) from
        // `prepareSync` so camera and library paths produce comparably-sized
        // payloads to Anthropic.
        let maxLongEdge: Double
        if case .aiVision = target {
            let scale = min(
                1.0,
                1568.0 / Double(max(srcWidth, srcHeight)),
                sqrt(1_200_000.0 / Double(srcWidth * srcHeight))
            )
            maxLongEdge = Double(max(srcWidth, srcHeight)) * scale
        } else {
            maxLongEdge = min(Double(max(srcWidth, srcHeight)), Double(target.maxLongEdgePixels))
        }

        let aspect = Double(srcWidth) / Double(srcHeight)
        let (targetWidth, targetHeight): (Int, Int) = {
            if srcWidth >= srcHeight {
                let w = max(1, Int(maxLongEdge.rounded(.down)))
                let h = max(1, Int((Double(w) / aspect).rounded()))
                return (w, h)
            } else {
                let h = max(1, Int(maxLongEdge.rounded(.down)))
                let w = max(1, Int((Double(h) * aspect).rounded()))
                return (w, h)
            }
        }()

        let resized: CGImage = {
            // Skip the resize pass when the source is already at-or-below
            // the target — re-blitting a same-size CGImage just wastes
            // memory and adds a small interpolation pass for no gain.
            if targetWidth >= srcWidth && targetHeight >= srcHeight {
                return cgImage
            }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return cgImage }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return context.makeImage() ?? cgImage
        }()

        // `.aiVision` forces JPEG (Anthropic doesn't accept HEIC). Other
        // targets pick HEIC for storage when iOS can encode it; iOS supports
        // HEIC encoding on every device that supports HEIC capture (A10+),
        // so falling back to JPEG is rare in practice. We still fall back to
        // JPEG if `CGImageDestinationCreateWithData` returns nil for HEIC.
        let preferredType = target.forcesJPEGOutput ? UTType.jpeg : UTType.heic

        if let data = encodeCGImage(resized, type: preferredType, quality: target.jpegQuality) {
            return data
        }
        if preferredType != .jpeg {
            return encodeCGImage(resized, type: .jpeg, quality: target.jpegQuality)
        }
        return nil
    }

    private static func encodeCGImage(_ image: CGImage, type: UTType, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Transcode HEIC bytes to JPEG without resizing. Pass-through for
    /// JPEG/PNG/WebP inputs. Used by the cloud-share upload path so
    /// recipients on non-Apple platforms (WhatsApp, Slack, Discord,
    /// Chrome) get a previewable image — those unfurlers don't decode
    /// HEIC. Local SwiftData storage stays HEIC; only the share-bound
    /// copy is converted.
    static func transcodeHEICToJPEGForSharing(_ source: Data) -> Data {
        guard isHEIC(source) else { return source }
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return source
        }
        let dest = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            dest,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return source
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return source }
        return dest as Data
    }

    /// HEIC magic-byte check: `ftyp` at offset 4 with a HEIC brand at
    /// offset 8. Same brand list as the Cloudflare image proxy's
    /// `detectImageContentType`.
    private static func isHEIC(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let ftyp = data[4..<8]
        guard ftyp == Data([0x66, 0x74, 0x79, 0x70]) else { return false }
        let brand = data[8..<12]
        let brands: [Data] = [
            Data([0x68, 0x65, 0x69, 0x63]), // heic
            Data([0x68, 0x65, 0x69, 0x78]), // heix
            Data([0x68, 0x65, 0x76, 0x63]), // hevc
            Data([0x68, 0x65, 0x76, 0x78]), // hevx
            Data([0x6d, 0x69, 0x66, 0x31]), // mif1
            Data([0x6d, 0x73, 0x66, 0x31]), // msf1
        ]
        return brands.contains(brand)
    }

    /// Pick the output container format. HEIC source preserves HEIC,
    /// JPEG preserves JPEG, everything else (PNG screenshot, BMP, etc.)
    /// re-encodes to JPEG to avoid bloat. Falls back to JPEG when the
    /// source's UTType is unknown so we never end up emitting a file
    /// the SwiftData / image view layer can't decode.
    private static func pickOutputType(for source: CGImageSource) -> UTType {
        guard let raw = CGImageSourceGetType(source) as String?,
              let sourceType = UTType(raw) else {
            return .jpeg
        }
        if sourceType.conforms(to: .heic) || sourceType == .heic {
            return .heic
        }
        if sourceType.conforms(to: .jpeg) {
            return .jpeg
        }
        return .jpeg
    }
}
