import Foundation
import ImageIO
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
    /// and OCR gets a sharper temporary image for text recognition.
    enum Target {
        case gallery
        case step
        case ocr

        /// Long-edge ceiling in pixels. Source images smaller than this
        /// pass through without upscaling (the thumbnail API caps at the
        /// source size automatically).
        var maxLongEdgePixels: Int {
            switch self {
            case .gallery: return 1920
            case .step:    return 1280
            case .ocr:     return 2560
            }
        }

        /// JPEG quality for fallback re-encodes. HEIC ignores this and
        /// uses its own internal rate-distortion knob.
        var jpegQuality: CGFloat {
            switch self {
            case .gallery: return 0.85
            case .step:    return 0.82
            case .ocr:     return 0.92
            }
        }
    }

    /// Resize + re-encode `source` for the given target. Returns nil on
    /// undecodable input (corrupt picker output, exotic format with no
    /// ImageIO support). Cheap fallback at the call site is "store the
    /// source bytes anyway" — but that's the caller's choice; this
    /// function refuses to fabricate output.
    ///
    /// **Bytes guard:** if the re-encoded output is larger than the
    /// source (rare, mostly happens with already-tiny inputs), the
    /// source bytes are returned instead. We never make a photo bigger.
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

        let outputType = pickOutputType(for: imageSource)

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target.maxLongEdgePixels,
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
        // If the round-trip somehow inflated the bytes — rare, but real
        // for already-small inputs (e.g. a 200KB screenshot re-encoding
        // to ~250KB JPEG) — return the source unchanged. Better to keep
        // the user's original than to actively make things worse.
        return encoded.count < source.count ? encoded : source
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
