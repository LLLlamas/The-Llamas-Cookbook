import SwiftUI

extension View {
    /// Filter / category chip background: active = solid accent fill (so the
    /// selected state reads as a strong opaque pill), inactive = native iOS 26
    /// frosted-glass capsule. The single source of truth for the active/inactive
    /// capsule split shared by `LibraryView`'s home filter strip and
    /// `CategoryFilterStrip`'s friend-library strip — both must look identical.
    @ViewBuilder
    func glassChip(isActive: Bool, accent: Color) -> some View {
        if isActive {
            self.background(accent, in: Capsule())
        } else {
            self.glassEffect(.regular, in: Capsule())
        }
    }
}
