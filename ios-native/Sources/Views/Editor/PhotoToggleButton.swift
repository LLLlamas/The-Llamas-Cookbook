import SwiftUI

/// Per-step photo manager. Same 36×36 circle shape as
/// `TimerToggleButton` and lives in the same trailing slot of step
/// rows so the editor's row layout stays predictable:
/// `[step text] [TimerToggle] [PhotoToggle]`.
///
/// Tapping flips a binding owned by the parent `StepRowEditor`, which
/// hosts the actual `.sheet` modifier on its always-rendered outer
/// container. Hoisting the presentation up the tree matters: the
/// button itself only renders inside `editContent`, which unmounts
/// when the step row's `isEditing` collapses (and `isEditing`
/// collapses the moment the keyboard goes away to present the sheet).
/// If the sheet's `isPresented` binding lived on the button's own
/// `@State`, the carousel would be torn down mid-edit — visible to
/// the user as an "Add description" tap that instantly cancels.
///
/// **Cap is 3 photos per step.** Enforced via
/// `PhotoCarouselView.maxImages`, defended again at the apply()
/// carry-through (`Recipe.apply(_:)` clamps to 3 when rebuilding
/// `RecipeStepPhoto` rows).
struct PhotoToggleButton: View {
    @Binding var images: [DraftStepPhoto]
    @Binding var showSheet: Bool
    @Environment(AppearanceSettings.self) private var appearance

    /// Hard cap mirrored from `RecipeStep.photos` apply-time clamp.
    static let maxImages = 3

    var body: some View {
        Button {
            Haptics.selection()
            showSheet = true
        } label: {
            iconBubble
        }
        .buttonStyle(.plain)
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

}

/// Process picked bytes through `ImageProcessing` and append fresh
/// `DraftStepPhoto` rows to the bound array. Lives at file scope so
/// `StepRowEditor` (which hosts the carousel sheet) can call it
/// without re-implementing the same clamp logic. Capped defensively
/// at `PhotoToggleButton.maxImages` — the carousel already caps at
/// the picker level, but a stale cap or concurrent edit could let
/// one slip through.
@MainActor
func appendStepPhotos(
    raw rawDataArray: [Data],
    into images: Binding<[DraftStepPhoto]>
) async {
    var processed: [DraftStepPhoto] = []
    let startingCount = images.wrappedValue.count
    for raw in rawDataArray {
        if startingCount + processed.count >= PhotoToggleButton.maxImages { break }
        if let bytes = await ImageProcessing.prepare(raw, for: .step) {
            processed.append(DraftStepPhoto(image: bytes))
        }
    }
    images.wrappedValue.append(contentsOf: processed)
}
