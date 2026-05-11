import SwiftUI

extension View {
    /// Re-enables the interactive pop gesture after `.navigationBarBackButtonHidden(true)`.
    /// The gesture is guarded — it only fires when there are 2+ VCs in the stack.
    func enableSwipeBack() -> some View {
        background(SwipeBackEnabler())
    }
}

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Ctrl { Ctrl() }
    func updateUIViewController(_: Ctrl, context: Context) {}

    final class Ctrl: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            navigationController?.interactivePopGestureRecognizer?.delegate = self
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
