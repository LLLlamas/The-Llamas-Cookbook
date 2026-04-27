import SwiftUI

struct StepQuickAdd: View {
    let nextNumber: Int
    let onAdd: (DraftStep) -> Void

    @State private var text = ""
    @State private var needsTimer = false
    /// Photos staged for the next quick-add. Cleared on submit
    /// alongside `text` and `needsTimer` so the picker state doesn't
    /// leak into subsequent rows. Up to 3 entries — each carries
    /// optional caption text the user can add inline in the carousel.
    @State private var stagedImages: [DraftStepPhoto] = []
    @State private var showPhotoSheet: Bool = false
    @Environment(AppearanceSettings.self) private var appearance
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Text("\(nextNumber)")
                .font(AppFont.sectionHeading)
                .foregroundStyle(appearance.accentColor)
                .monospacedDigit()
                .frame(width: 36, height: 44)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

            HStack(spacing: AppSpacing.xs) {
                TextField("Describe step \(nextNumber)…", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .submitLabel(.done)
                    .focused($focused)
                    .onChange(of: text) { _, newValue in
                        // `axis: .vertical` swallows `.onSubmit` and turns
                        // Return into a literal newline. Treat any newline
                        // as the Done press: strip it, then submit.
                        if newValue.contains("\n") {
                            text = newValue.replacingOccurrences(of: "\n", with: "")
                            submit()
                        }
                    }
                    .onSubmit { submit() }
                    .tint(appearance.accentColor)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)

                TimerToggleButton(isOn: $needsTimer)
                PhotoToggleButton(images: $stagedImages, showSheet: $showPhotoSheet)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .frame(minHeight: 44)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .sheet(isPresented: $showPhotoSheet) {
            PhotoCarouselView(
                photoData: stagedImages.map(\.image),
                captions: stagedImages.map(\.caption),
                onAdd: { rawDataArray in
                    await appendStepPhotos(raw: rawDataArray, into: $stagedImages)
                },
                onDelete: { idx in
                    guard stagedImages.indices.contains(idx) else { return }
                    stagedImages.remove(at: idx)
                },
                onSetCaption: { idx, newCaption in
                    guard stagedImages.indices.contains(idx) else { return }
                    stagedImages[idx].caption = newCaption
                },
                maxImages: PhotoToggleButton.maxImages
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func submit() {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else {
            focused = false
            return
        }
        Haptics.impact(.light)
        onAdd(DraftStep(
            text: trimmed,
            needsTimer: needsTimer,
            images: stagedImages
        ))
        text = ""
        needsTimer = false
        stagedImages = []
        focused = true
    }
}

struct TimerToggleButton: View {
    @Binding var isOn: Bool
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        Button {
            Haptics.selection()
            isOn.toggle()
        } label: {
            Image(systemName: "timer")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isOn ? AppColor.onAccent : appearance.accentColor)
                .frame(width: 36, height: 36)
                .background(isOn ? appearance.accentColor : AppColor.background)
                .overlay(
                    Circle().stroke(appearance.accentColor, lineWidth: isOn ? 0 : 1.5)
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Timer enabled for this step" : "Enable timer for this step")
    }
}
