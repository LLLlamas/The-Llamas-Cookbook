import SwiftUI

/// The branded "Asking the llama…" processing card — a cream rounded card
/// with the `LlamaProgressIndicator` and a caption. Shown (over a dimmed
/// scrim the caller supplies) during any operation expected to take >1–2 s,
/// per the CLAUDE.md UX rule. Extracted so the three call sites — photo
/// import (`PhotoImportPreviewView`), text/link import
/// (`ImportFromTextLinkView`), and cloud share (`RecipeDetailView`) —
/// compose from one source instead of three byte-identical copies.
struct ProcessingCard: View {
    let caption: String
    var indicatorSize: CGFloat = 96
    var shadowRadius: CGFloat = 48
    var shadowY: CGFloat = 8

    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            LlamaProgressIndicator(size: indicatorSize, accent: appearance.accentColor)
            Text(caption)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
        }
        .padding(AppSpacing.xl)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: AppColor.shadow, radius: shadowRadius, y: shadowY)
    }
}
