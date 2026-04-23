import SwiftUI
import UIKit

extension View {
    /// Attach a keyboard-toolbar "Done" button to this field. Use on numeric
    /// keyboards (decimalPad / numberPad) that don't have a Return key.
    func numericKeyboardDone() -> some View {
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
                .foregroundStyle(AppColor.accent)
                .font(.system(size: 16, weight: .semibold))
            }
        }
    }
}

/// Conditional variant — only attaches the keyboard toolbar when `apply` is
/// true, so text fields sharing a helper can opt in by keyboard type.
struct NumericDoneModifier: ViewModifier {
    let apply: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if apply {
            content.numericKeyboardDone()
        } else {
            content
        }
    }
}
