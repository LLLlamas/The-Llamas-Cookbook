import SwiftUI

/// Small modal sheet for choosing the app's accent color. Tapping the
/// inline `ColorPicker` opens iOS's system color UI — the hexagon Grid,
/// Spectrum, Sliders, and Eyedropper tabs — so the user can pick from
/// any color including the standard hex grid.
///
/// Live preview at the top updates as they pick: the llama mascot, a
/// sample title, and a heart all retint in real time. Reset returns to
/// the default terracotta.
struct AccentColorPicker: View {
    @Bindable var settings: AppearanceSettings
    @Environment(\.dismiss) private var dismiss

    // Local state drives the ColorPicker binding. Writing directly to
    // settings.accentColor causes SwiftUI to re-render the ColorPicker
    // with the new value, which programmatically updates the underlying
    // UIColorPickerViewController.selectedColor — breaking the two-way
    // sync for the rest of that picker session (only the first pick
    // registers). The @State here is never written back by SwiftUI on
    // re-render, so the picker's internal drag/slider state stays intact.
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
            .padding(AppSpacing.lg)
            .padding(.bottom, AppSpacing.sm)
            .llamaBackground()
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.large)
            .tint(settings.accentColor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(settings.accentColor)
                }
            }
            .onAppear {
                pickerColor = settings.accentColor
            }
            .onChange(of: pickerColor) { _, newColor in
                // Sync user pick → observable. Only the @State pickerColor
                // writes here; the ColorPicker binding never sees a
                // programmatic update, so mid-session picks work correctly.
                settings.accentColor = newColor
            }
            .onDisappear {
                settings.syncToUIKit()
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 6) {
            LlamaLogo(size: 140, shadowColor: settings.accentColor)

            Text("Sample Recipe Title")
                .font(AppFont.recipeTitle)
                .foregroundStyle(settings.accentColor)
                .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)
                .multilineTextAlignment(.center)

            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(settings.accentColor)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(settings.accentColor)
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(settings.accentColor)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, AppSpacing.sm)
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
            settings.resetToDefault()
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
