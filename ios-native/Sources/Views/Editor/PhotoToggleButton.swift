import SwiftUI
import PhotosUI

/// Per-step photo toggle. Same 36×36 circle shape as `TimerToggleButton`
/// and lives in the same trailing slot of step rows so the editor's
/// row layout stays predictable: `[step text] [TimerToggle] [PhotoToggle]`.
///
/// **Two states, two interactions:**
/// - `image == nil` → tap opens `PhotosPicker` (single image).
/// - `image != nil` → tap opens a confirmation dialog with **Replace**
///   (re-opens the picker) and **Remove** (clears the bytes).
///
/// Picked bytes flow through `ImageProcessing.prepare(_:for: .step)`
/// before the binding mutates, so the editor never holds raw 12MP
/// source bytes — keeps the live `DraftStep.image` size predictable
/// for whatever in-memory ops the editor does (re-orders, undo, etc.).
struct PhotoToggleButton: View {
    @Binding var image: Data?
    @Environment(AppearanceSettings.self) private var appearance

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var showingActionSheet = false
    @State private var isProcessing = false

    var body: some View {
        Button {
            Haptics.selection()
            if image == nil {
                showingPicker = true
            } else {
                showingActionSheet = true
            }
        } label: {
            iconBubble
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .photosPicker(
            isPresented: $showingPicker,
            selection: $pickerItems,
            maxSelectionCount: 1,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickerItems) { _, items in
            handlePicked(items)
        }
        .confirmationDialog(
            "Step photo",
            isPresented: $showingActionSheet,
            titleVisibility: .visible
        ) {
            Button("Replace") {
                showingPicker = true
            }
            Button("Remove", role: .destructive) {
                image = nil
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityLabel(image == nil
            ? "Add photo to this step"
            : "Step photo set; tap to replace or remove"
        )
    }

    // MARK: - Visual

    @ViewBuilder
    private var iconBubble: some View {
        let isSet = (image != nil)
        ZStack {
            Circle()
                .fill(isSet ? appearance.accentColor : AppColor.background)
            Circle()
                .stroke(appearance.accentColor, lineWidth: isSet ? 0 : 1.5)
            if isProcessing {
                ProgressView()
                    .tint(isSet ? AppColor.onAccent : appearance.accentColor)
            } else {
                Image(systemName: isSet ? "photo.fill" : "photo")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSet ? AppColor.onAccent : appearance.accentColor)
            }
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Pick handling

    private func handlePicked(_ items: [PhotosPickerItem]) {
        guard let item = items.first else { return }
        isProcessing = true
        Task {
            var processed: Data?
            if let raw = try? await item.loadTransferable(type: Data.self) {
                processed = await ImageProcessing.prepare(raw, for: .step)
            }
            await MainActor.run {
                if let processed {
                    image = processed
                }
                pickerItems = []
                isProcessing = false
            }
        }
    }
}
