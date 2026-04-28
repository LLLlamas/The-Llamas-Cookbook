import SwiftUI

struct StepRowEditor: View {
    let index: Int
    @Binding var step: DraftStep
    @Binding var isEditing: Bool
    let onDelete: () -> Void

    @Environment(AppearanceSettings.self) private var appearance
    @FocusState private var fieldFocused: Bool
    /// Owns the photo-carousel sheet so it survives `editContent`
    /// unmounting when the keyboard goes away to make room for the
    /// sheet. See `PhotoToggleButton` for the full reasoning.
    @State private var showPhotoSheet: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm + 2) {
            Text("\(index + 1).")
                .font(AppFont.sectionHeading)
                .foregroundStyle(appearance.accentColor)
                .monospacedDigit()
                .frame(minWidth: 28, alignment: .leading)

            if isEditing {
                editContent
            } else {
                viewContent
            }

            Button {
                Haptics.impact(.light)
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(AppSpacing.xs)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, AppSpacing.sm - 1)
        .padding(.horizontal, AppSpacing.sm)
        .background(isEditing ? AppColor.accentSoft.opacity(0.55) : AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(
                    isEditing ? appearance.accentColor : AppColor.divider,
                    lineWidth: isEditing ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                Haptics.selection()
                isEditing = true
            }
        }
        .onChange(of: isEditing) { _, newValue in
            // Chain edit-mode ↔ TextField focus. Entering edit pops the
            // keyboard automatically; losing focus (scroll, tap away,
            // keyboard Return, another step tapped) collapses edit mode
            // without the caller having to orchestrate it.
            if newValue {
                fieldFocused = true
            } else {
                fieldFocused = false
            }
        }
        .onChange(of: fieldFocused) { _, focused in
            // The photo-carousel sheet steals key window when it
            // presents, blurring this row's TextField — which would
            // normally collapse edit mode and unmount the photo
            // button before the sheet has even fully presented.
            // Skip the auto-collapse while the sheet is up so the
            // carousel (and any in-flight caption typing) stays alive.
            if !focused && isEditing && !showPhotoSheet {
                isEditing = false
            }
        }
        .sheet(isPresented: $showPhotoSheet) {
            PhotoCarouselView(
                photoData: step.images.map(\.image),
                captions: step.images.map(\.caption),
                onAdd: { rawDataArray in
                    await appendStepPhotos(raw: rawDataArray, into: $step.images)
                },
                onDelete: { idx in
                    guard step.images.indices.contains(idx) else { return }
                    step.images.remove(at: idx)
                },
                onSetCaption: { idx, newCaption in
                    guard step.images.indices.contains(idx) else { return }
                    step.images[idx].caption = newCaption
                },
                onReorder: { indices, destination in
                    step.images.move(fromOffsets: indices, toOffset: destination)
                },
                maxImages: PhotoToggleButton.maxImages
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var viewContent: some View {
        Text(step.text.isEmpty ? "Tap to edit" : step.text)
            .font(AppFont.body)
            .foregroundStyle(step.text.isEmpty ? AppColor.textTertiary : AppColor.textPrimary)
            .lineLimit(2...)
            .frame(maxWidth: .infinity, alignment: .leading)
        if step.needsTimer {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(appearance.accentColor.opacity(0.8))
        }
        // Mirror of the timer glyph: a tiny photo dot tells the user
        // "this step has a picture attached" without entering edit
        // mode. The thumbnail itself shows in Detail; this is just an
        // editor breadcrumb.
        if !step.images.isEmpty {
            Image(systemName: "photo.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(appearance.accentColor.opacity(0.8))
        }
    }

    @ViewBuilder
    private var editContent: some View {
        TextField("Step \(index + 1)", text: $step.text, axis: .vertical)
            .lineLimit(1...4)
            .font(AppFont.body)
            .foregroundStyle(AppColor.textPrimary)
            .submitLabel(.done)
            .focused($fieldFocused)
            .onChange(of: step.text) { _, newValue in
                // `axis: .vertical` swallows `.onSubmit` and turns Return
                // into a literal newline. Treat any newline as Done:
                // strip it and collapse edit mode.
                if newValue.contains("\n") {
                    step.text = newValue.replacingOccurrences(of: "\n", with: "")
                    isEditing = false
                }
            }
            .onSubmit { isEditing = false }
            .tint(appearance.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
        TimerToggleButton(isOn: $step.needsTimer)
        PhotoToggleButton(images: $step.images, showSheet: $showPhotoSheet)
    }
}
