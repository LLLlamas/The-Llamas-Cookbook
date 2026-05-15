import SwiftUI

extension View {
    /// Standard surface-card chrome: `AppSpacing.md` padding, full-width
    /// leading layout, surface fill, 1pt divider stroke, rounded clip.
    /// The canonical "settings/info card" container used across the
    /// Profile and Detail surfaces.
    func surfaceCard(cornerRadius: CGFloat = AppRadius.md) -> some View {
        self
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
