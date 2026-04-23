import SwiftUI
import UIKit

extension View {
    /// Bind this field's focus to a shared Bool FocusState only when `when`
    /// is true. Used to light up one numeric-keyboard Done button at the
    /// editor root when any numeric field becomes first responder — without
    /// polluting non-numeric fields with the same binding.
    @ViewBuilder
    func focusedNumeric(_ binding: FocusState<Bool>.Binding, when: Bool) -> some View {
        if when {
            self.focused(binding)
        } else {
            self
        }
    }
}
