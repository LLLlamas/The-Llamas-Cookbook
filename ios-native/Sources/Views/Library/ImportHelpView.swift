import SwiftUI

struct ImportHelpView: View {
    @Environment(AppearanceSettings.self) private var appearance
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    mascotHeader

                    VStack(alignment: .leading, spacing: AppSpacing.lg) {
                        section(
                            eyebrow: "FROM TEXT OR A LINK",
                            rows: [
                                "Paste a recipe blog URL at the top — I'll pull title, ingredients, steps, and times automatically.",
                                "Pinterest pins and TikTok captions come through too. Instagram and Facebook block previews — paste the caption in the text box below instead.",
                                "Or skip the link and paste plain text: **line 1** is the **recipe name**, leave a **blank line**, then **ingredients**, another **blank line**, then **steps**.",
                                "Bullets, numbers, fractions (½, 1/4), and units (g, tbsp, cup) all parse automatically."
                            ]
                        )

                        section(
                            eyebrow: "FROM A PHOTO",
                            rows: [
                                "Tap **Take a Photo** to scan a cookbook spread, magazine clipping, or recipe card with the camera.",
                                "Or pick an image from your photo library — multi-page scans concatenate top-to-bottom.",
                                "Lighting and framing help — flat surface, full page in the frame, no glare on glossy paper.",
                                "I OCR the page and parse it into the same preview screen as a shared recipe — review, then save."
                            ]
                        )

                        section(
                            eyebrow: "FROM YOUR VOICE",
                            rows: [
                                "Tap **Import From Voice** and read your recipe out loud — title first, then ingredients, then the steps.",
                                "Pause briefly between sections so I can tell them apart.",
                                "Numbers come through best when said with a unit — \"two cups flour\" parses cleaner than \"two flour\".",
                                "Recordings cap at 5 minutes; you can always edit the result before saving."
                            ]
                        )

                        formatExample
                    }
                    .padding(.horizontal, AppSpacing.sm)

                    Text("You can always edit everything before saving.")
                        .font(.system(size: 13))
                        .italic()
                        .foregroundStyle(AppColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(AppSpacing.lg)
                .padding(.top, AppSpacing.md)
                .frame(maxWidth: .infinity)
            }

            Button {
                Haptics.selection()
                onDismiss()
            } label: {
                Text("Got it")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(appearance.accentColor)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background(AppColor.background)
        }
        .llamaBackground()
    }

    private var mascotHeader: some View {
        VStack(spacing: AppSpacing.sm) {
            LlamaLogo(size: 72, shadowColor: appearance.accentColor)
            VStack(spacing: 2) {
                Text("Hi there!")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(appearance.accentColor)
                Text("A few ways to import a recipe")
                    .font(.system(size: 13, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
    }

    /// Compact visual of the expected paste shape — easier to grok than
    /// the prose rules above when the user is half-paying-attention.
    private var formatExample: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("EXAMPLE").eyebrowStyle()
                .padding(.bottom, 2)
            exampleLine("Garlic Butter Pasta", emphasis: true)
            exampleSpacer()
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                exampleLine("8 oz spaghetti")
                exampleLine("4 tbsp butter")
                exampleLine("3 cloves garlic, minced")
            }
            exampleSpacer()
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                exampleLine("Boil pasta until al dente")
                exampleLine("Melt butter, sauté garlic")
                exampleLine("Toss pasta in garlic butter")
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceSunken)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func exampleLine(_ text: String, emphasis: Bool = false) -> some View {
        Text(text)
            .font(.system(
                size: emphasis ? 14 : 13,
                weight: emphasis ? .bold : .regular,
                design: .monospaced
            ))
            .foregroundStyle(emphasis ? appearance.accentColor : AppColor.textPrimary)
    }

    private func exampleSpacer() -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 12)
            .overlay(
                Text("(blank line)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(AppColor.textTertiary.opacity(0.7))
            )
    }

    private func section(eyebrow: String, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(eyebrow).eyebrowStyle()
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    helpRow(idx + 1, row)
                }
            }
        }
    }

    private func helpRow(_ number: Int, _ markdown: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm + 2) {
            ZStack {
                Circle()
                    .fill(appearance.accentColor.opacity(0.18))
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.system(size: 12, weight: .heavy, design: .serif))
                    .foregroundStyle(appearance.accentColor)
            }
            Text(LocalizedStringKey(markdown))
                .font(.system(size: 14))
                .foregroundStyle(AppColor.textPrimary)
                .tint(appearance.accentColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
