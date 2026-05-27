import SwiftUI

extension View {
    /// Re-enables the interactive pop gesture after `.navigationBarBackButtonHidden(true)`.
    /// The gesture is guarded — it only fires when there are 2+ VCs in the stack.
    ///
    /// The delegate is re-pinned on `viewWillAppear` (not just on
    /// `didMove(toParent:)`) so a child push/pop cycle that stomped the
    /// shared `interactivePopGestureRecognizer.delegate` doesn't leave
    /// the current screen with a stale or nil delegate. Simultaneous
    /// recognition is also allowed so horizontal chip strips and card
    /// scroll transitions near the left edge don't swallow the edge pan.
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
            pinDelegate()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // The nav controller's `interactivePopGestureRecognizer.delegate`
            // is a single shared slot. A pushed child (e.g. RecipeDetailView)
            // can stomp it; on pop back to this screen `didMove(toParent:)`
            // doesn't re-fire because the controller wasn't re-added. Re-pin
            // here so this screen's gesture is reliable for the lifetime of
            // its appearance.
            pinDelegate()
        }

        private func pinDelegate() {
            navigationController?.interactivePopGestureRecognizer?.delegate = self
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        // Allow the edge pop pan to coexist with other horizontal pans —
        // horizontal chip strips and card scroll transitions sit near the
        // left edge in views like FriendLibraryView and would otherwise
        // win the recognizer contest and silently kill the swipe-back.
        // The pop gesture only activates within ~20pt of the screen edge,
        // so unconditional simultaneous recognition is safe.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer == navigationController?.interactivePopGestureRecognizer
        }
    }
}
