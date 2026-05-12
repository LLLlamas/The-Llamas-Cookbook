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
    @Environment(\.dismiss) private var dismiss

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

    private var preview: some View {
        VStack(spacing: -6) {
            LlamaLogo(size: 140, shadowColor: pickerColor)
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
