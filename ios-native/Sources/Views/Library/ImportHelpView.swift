import SwiftUI

struct ImportHelpView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    mascotHeader

                    VStack(alignment: .leading, spacing: AppSpacing.lg) {
                        section(
                            eyebrow: "FROM A LINK",
                            rows: [
                                "Paste a recipe blog URL — I'll pull title, ingredients, steps, and times automatically.",
                                "Pinterest pins work too — I'll grab the description, or follow it to the source recipe.",
                                "TikTok captions come through, but you may need to label \"Ingredients\" and \"Steps\" yourself.",
                                "Instagram and Facebook block link previews — paste the caption text in the box below instead."
                            ]
                        )

                        section(
                            eyebrow: "FROM TEXT",
                            rows: [
                                "First non-empty line becomes the **recipe name**.",
                                "Type **\"Ingredients\"** above your first ingredient.",
                                "Type **\"Steps\"** above your first step.",
                                "Bullets, numbers, fractions (½, 1/4), and units (g, tbsp, cup) all parse cleanly."
                            ]
                        )
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
                    .background(AppColor.accent)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background(AppColor.background)
        }
        .background(AppColor.background)
    }

    private var mascotHeader: some View {
        VStack(spacing: AppSpacing.sm) {
            LlamaMascot(size: 64)
            VStack(spacing: 2) {
                Text("Hi there!")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.accentDeep)
                Text("Two ways to import a recipe")
                    .font(.system(size: 13, weight: .medium))
                    .tracking(0.3)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
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
                    .fill(AppColor.accentSoft)
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.system(size: 12, weight: .heavy, design: .serif))
                    .foregroundStyle(AppColor.accentDeep)
            }
            Text(LocalizedStringKey(markdown))
                .font(.system(size: 14))
                .foregroundStyle(AppColor.textPrimary)
                .tint(AppColor.accentDeep)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    ImportHelpView(onDismiss: {})
}
