import SwiftUI

/// Per-step photo manager. Same 36×36 circle shape as
/// `TimerToggleButton` and lives in the same trailing slot of step
/// rows so the editor's row layout stays predictable:
/// `[step text] [TimerToggle] [PhotoToggle]`.
///
/// Tapping always opens the shared `PhotoCarouselView` in a sheet —
/// from there the user can pick (with confirmation), delete, and
/// browse. The carousel itself owns the picker + the add-confirmation
/// alert + the delete confirmation, so this button is a thin wrapper:
/// tap → sheet → done.
///
/// **Cap is 3 photos per step.** Enforced via
/// `PhotoCarouselView.maxImages`, defended again at the apply()
/// carry-through (`Recipe.apply(_:)` clamps to 3 when rebuilding
/// `RecipeStepPhoto` rows).
struct PhotoToggleButton: View {
    @Binding var images: [DraftStepPhoto]
    @Environment(AppearanceSettings.self) private var appearance

    @State private var showingCarousel = false

    /// Hard cap mirrored from `RecipeStep.photos` apply-time clamp.
    private static let maxImages = 3

    var body: some View {
        Button {
            Haptics.selection()
            showingCarousel = true
        } label: {
            iconBubble
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingCarousel) {
            PhotoCarouselView(
                photoData: images.map(\.image),
                captions: images.map(\.caption),
                onAdd: { rawDataArray in
                    await processAndAppend(rawDataArray)
                },
                onDelete: { index in
                    guard images.indices.contains(index) else { return }
                    images.remove(at: index)
                },
                onSetCaption: { index, newCaption in
                    guard images.indices.contains(index) else { return }
                    images[index].caption = newCaption
                },
                maxImages: Self.maxImages
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .accessibilityLabel(images.isEmpty
            ? "Add photo to this step"
            : "Step photos, \(images.count) attached"
        )
    }

    // MARK: - Visual

    @ViewBuilder
    private var iconBubble: some View {
        let isSet = !images.isEmpty
        ZStack {
            Circle()
                .fill(isSet ? appearance.accentColor : AppColor.background)
            Circle()
                .stroke(appearance.accentColor, lineWidth: isSet ? 0 : 1.5)
            Image(systemName: isSet ? "photo.fill" : "photo")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSet ? AppColor.onAccent : appearance.accentColor)
        }
        .frame(width: 36, height: 36)
        .overlay(alignment: .topTrailing) {
            // Small count badge when there's more than one photo. Single
            // photo shows just the filled glyph — count is implicit.
            if images.count > 1 {
                Text("\(images.count)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(appearance.accentColor)
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, 3)
                    .background(AppColor.background)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(appearance.accentColor, lineWidth: 1.2)
                    )
                    .offset(x: 6, y: -4)
            }
        }
    }

    // MARK: - Pick handling

    /// Process picked bytes through `ImageProcessing` and append to
    /// the binding as fresh `DraftStepPhoto` rows (no caption — the
    /// user can add one in the carousel afterward). Capped defensively
    /// at 3 (the carousel already caps at the picker level via
    /// `maxImages`, but a stale cap or concurrent edit elsewhere could
    /// let one extra slip through).
    private func processAndAppend(_ rawDataArray: [Data]) async {
        var processed: [DraftStepPhoto] = []
        let startingCount = await MainActor.run { images.count }
        for raw in rawDataArray {
            if startingCount + processed.count >= Self.maxImages { break }
            if let bytes = await ImageProcessing.prepare(raw, for: .step) {
                processed.append(DraftStepPhoto(image: bytes))
            }
        }
        await MainActor.run {
            images.append(contentsOf: processed)
        }
    }
}
