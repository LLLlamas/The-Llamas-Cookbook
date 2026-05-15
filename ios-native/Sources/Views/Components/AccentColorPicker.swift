import SwiftUI

/// Small modal sheet for choosing the app's accent color. Tapping the
/// inline `ColorPicker` opens iOS's system color UI: the hexagon Grid,
/// Spectrum, Sliders, and Eyedropper tabs, so the user can pick from
/// any color including the standard hex grid.
///
/// Live preview at the top updates as they pick: the llama mascot, a
/// sample title, and a heart all retint in real time. Reset returns to
/// the default terracotta.
struct AccentColorPicker: View {
    // settings is passed explicitly by callers AND injected via
    // .environment(appearance) at every call site. We read from
    // @Environment here so that iOS 26's @Observable environment
    // re-injection actually takes effect for the preview section.
    @Environment(AppearanceSettings.self) private var settings
    @Environment(UserAccount.self)        private var userAccount
    @Environment(\.dismiss)              private var dismiss

    private var isSignedIn: Bool { userAccount.status.isSignedIn }

    // Local state drives the ColorPicker binding AND every live-preview
    // read in this sheet. We deliberately do NOT write to settings.accentColor
    // mid-session: doing so causes the @Observable to fire, which re-renders
    // the parent body (which reads settings.accentColor in tint/preview),
    // which rebuilds the ColorPicker subtree, which can desync the system
    // UIColorPickerViewController so only the first pick registers.
    // The preview llama follows pickerColor continuously; the app-wide
    // accent commits once in .onDisappear.
    @State private var pickerColor: Color = AppColor.accent

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.md) {
                preview

                if isSignedIn {
                    VStack(spacing: AppSpacing.sm) {
                        ColorPicker(
                            "Accent color",
                            selection: $pickerColor,
                            supportsOpacity: false
                        )
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AppColor.textPrimary)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm + 2)
                        .background(AppColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.md)
                                .stroke(AppColor.divider, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

                        Text("Tap the swatch to open the hex grid, sliders, or the eyedropper.")
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    resetButton
                } else {
                    signInLockedCard
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, 0)
            .padding(.bottom, AppSpacing.lg + AppSpacing.sm)
            .llamaBackground()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .tint(pickerColor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(pickerColor)
                        .accentTextOutline()
                }
            }
            .onAppear {
                pickerColor = settings.accentColor
            }
            .onDisappear {
                commitSelection()
            }
        }
    }

    private func commitSelection() {
        // Unsigned users have no color picker, so there's nothing to commit.
        guard isSignedIn else { return }
        let selectedHex = pickerColor.toHex
        let currentHex = settings.accentColor.toHex
        if selectedHex != nil, selectedHex == currentHex {
            settings.syncToUIKit()
            return
        }

        settings.accentColor = pickerColor
        // Final UIKit chrome sync (UIView.appearance().tintColor) is
        // done once after dismiss to avoid mutating the appearance
        // proxy mid-picker-session, which would re-snapshot
        // UIColorPickerViewController.selectedColor back onto the
        // binding (see AppearanceSettings docs).
        settings.syncToUIKit()
    }

    private var signInLockedCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
                Text("Sign in to customize")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
            }
            Text("Accent color customization is available once you sign in with Apple. Head to the Profile tab to sign in — it's free and keeps your recipes and friends in sync.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var preview: some View {
        VStack(spacing: -6) {
            LlamaLogoOrCrown(size: 140, accent: pickerColor)
                .llamaFloat()

            Text("Sample Recipe Title")
                .font(AppFont.recipeTitle)
                .foregroundStyle(pickerColor)
                .accentTextOutline()
                .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)
                .multilineTextAlignment(.center)

            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(pickerColor)
                    .accentTextOutline()
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(pickerColor)
                    .accentTextOutline()
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(pickerColor)
                    .accentTextOutline()
            }
            .padding(.top, 2)
        }
        .padding(.top, 2)
        .padding(.bottom, AppSpacing.sm)
        .padding(.horizontal, AppSpacing.md)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [AppColor.surfaceRaised, AppColor.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        // Flatten the preview's layer tree (LlamaLogo + float animation +
        // accentTextOutline shadows + gradient) into one Metal texture so
        // live color-pick updates re-rasterize a single surface instead of
        // re-compositing ~16 shadow/gradient layers per frame.
        .drawingGroup()
        .shadow(color: AppColor.shadowSoft, radius: 4, x: 0, y: 2)
    }

    private var resetButton: some View {
        Button {
            Haptics.selection()
            // Local-only reset; commit happens onDisappear like any other pick.
            pickerColor = AppColor.accent
        } label: {
            HStack(spacing: AppSpacing.xs + 2) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
                Text("Reset to terracotta")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppColor.textSecondary)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .overlay(Capsule().stroke(AppColor.divider, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
