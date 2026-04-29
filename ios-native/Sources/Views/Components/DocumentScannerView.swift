import SwiftUI
import VisionKit

/// SwiftUI wrapper for `VNDocumentCameraViewController`. Returns the
/// scanned pages via `onComplete([UIImage])`; cancellation calls
/// `onCancel`. The system camera UI handles its own permission
/// prompt; no need to gate from outside (denial dismisses with
/// onCancel and we surface a soft inline banner with an "Open
/// Settings" button on the host screen).
///
/// Use as a `.fullScreenCover` content — the document scanner UI
/// owns the entire screen; presenting it inside a sheet leaves the
/// system controls partially out of reach.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(
            onComplete: @escaping ([UIImage]) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var images: [UIImage] = []
            for i in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: i))
            }
            onComplete(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            // Same UX as cancel — host screen catches the empty state.
            onCancel()
        }
    }
}
