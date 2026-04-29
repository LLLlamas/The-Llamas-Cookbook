import SwiftUI
import UIKit

/// SwiftUI wrapper for `UIImagePickerController` configured for
/// manual photo capture from the rear camera. Returns the captured
/// image via `onComplete([UIImage])`; cancellation calls `onCancel`.
///
/// **Why `UIImagePickerController` rather than `VNDocumentCameraViewController`:**
/// the document-scanner controller auto-captures when it detects a
/// rectangular document. That's great for cookbook spreads but
/// fires too eagerly (or not at all) on handwritten recipe cards
/// where edges are softer and the page may be at an angle. This
/// wrapper instead gives the user the standard iOS camera UX:
///
/// - Live preview with a manual shutter button — photo is only
///   taken when the user explicitly taps it
/// - Built-in confirm screen with "Use Photo" / "Retake" buttons
///   after capture, so the user can verify focus / framing before
///   the OCR pipeline runs
/// - Cancel control to bail out without capturing
///
/// Single image per session — multi-page document capture is
/// dropped relative to the prior VNDocumentCameraViewController
/// implementation. Single-page is the dominant case for handwritten
/// recipes, and any future multi-page need can be served by letting
/// the user re-invoke the capture flow rather than baking complex
/// multi-page UI into a custom camera.
///
/// Use as a `.fullScreenCover` content — the camera UI owns the
/// entire screen; presenting it inside a sheet leaves the system
/// controls partially out of reach.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        // No edit step before confirm — the system's "Use Photo"
        // screen gives a full-frame preview already, and the
        // editing rectangle would crop arbitrarily from the
        // recipe card. The OCR pipeline handles its own resizing
        // (`ImageProcessing.prepare(_, for: .gallery)`) so we want
        // the largest unmodified bytes the camera can hand us.
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onComplete: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(
            onComplete: @escaping ([UIImage]) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // `.originalImage` is what we want — `.editedImage` is
            // only populated if `allowsEditing == true`. Wrapped in
            // a single-element array to match the existing
            // `onComplete([UIImage])` callback shape (the prior
            // VNDocumentCameraViewController returned multiple
            // pages; the array is now always 0 or 1).
            if let image = info[.originalImage] as? UIImage {
                onComplete([image])
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
