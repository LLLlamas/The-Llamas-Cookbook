import SwiftUI
import PhotosUI

/// Reusable carousel modal body. Used by Editor (full-edit gallery),
/// Detail (quick-edit gallery), and Detail (single-photo step viewer).
/// **One implementation, three callers.**
///
/// The view is **closure-driven**, not binding-driven, because the two
/// gallery callers store photos in different shapes — live `@Model`
/// `RecipePhoto` rows in Detail vs. plain-struct `DraftPhoto` in
/// Editor — and asking the carousel to know about either type would
/// couple it to persistence concerns it doesn't need. Callers pass
/// already-decoded byte arrays in, and adapt mutations through the
/// `onAdd` / `onDelete` closures.
///
/// **View-only mode:** omit `onAdd` and `onDelete`. The Add button and
/// long-press-Delete affordance disappear; the carousel becomes a
/// pure viewer. The step-image viewer in Detail uses this shape with
/// a single-element `photoData` array.
struct PhotoCarouselView: View {
    let photoData: [Data]
    var onAdd: (([Data]) async -> Void)? = nil
    var onDelete: ((Int) -> Void)? = nil
    /// Reorder callback. Plumbed for v2; not surfaced in the v1 UI
    /// because drag-to-reorder inside a `TabView` is non-trivial and
    /// not load-bearing for personal use.
    var onReorder: ((IndexSet, Int) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedPage: Int = 0
    @State private var pendingDeleteIndex: Int?
    @State private var isProcessing: Bool = false

    private var canAdd: Bool { onAdd != nil }
    private var canDelete: Bool { onDelete != nil }

    var body: some View {
        NavigationStack {
            content
                .background(AppColor.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .onChange(of: pickerItems) { _, items in
                    handlePicked(items)
                }
                .onChange(of: photoData.count) { _, newCount in
                    // After a delete the bound page index can fall off
                    // the end of the array. Clamp to the last valid page
                    // so SwiftUI doesn't render an empty `TabView` slot.
                    if selectedPage >= newCount {
                        selectedPage = max(0, newCount - 1)
                    }
                }
                .confirmationDialog(
                    "Remove this photo?",
                    isPresented: deleteDialogBinding,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) {
                        if let idx = pendingDeleteIndex {
                            onDelete?(idx)
                        }
                        pendingDeleteIndex = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingDeleteIndex = nil
                    }
                }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { dismiss() }
                .foregroundStyle(AppColor.accent)
        }
        if canAdd {
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(
                    selection: $pickerItems,
                    // Cap at 10 per add. Keeps memory predictable on
                    // the processing pass and prevents a huge multi-pick
                    // from saturating the bg queue.
                    maxSelectionCount: 10,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    if isProcessing {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(isProcessing)
                .foregroundStyle(AppColor.accent)
            }
        }
    }

    // MARK: - Body content

    @ViewBuilder
    private var content: some View {
        if photoData.isEmpty {
            emptyState
        } else {
            carousel
        }
    }

    private var carousel: some View {
        TabView(selection: $selectedPage) {
            ForEach(Array(photoData.enumerated()), id: \.offset) { index, data in
                RecipeImageView(data: data, contentMode: .fit) {
                    placeholderTile
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(AppSpacing.md)
                .tag(index)
                .contentShape(Rectangle())
                .onLongPressGesture {
                    guard canDelete else { return }
                    Haptics.warning()
                    pendingDeleteIndex = index
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundStyle(AppColor.textTertiary)
            if canAdd {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: 10,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Text("Add Photos")
                        .font(AppFont.body.weight(.semibold))
                        .padding(.horizontal, AppSpacing.xl)
                        .padding(.vertical, AppSpacing.md)
                        .background(AppColor.accent)
                        .foregroundStyle(AppColor.onAccent)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .disabled(isProcessing)
            } else {
                Text("No photos yet")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Fallback tile for a photo whose bytes failed to decode. Shows
    /// the same `photo.stack` symbol as the empty state — the user
    /// reads "the slot is here, but the image is missing" rather than
    /// "something exploded."
    private var placeholderTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(AppColor.surfaceRaised)
            Image(systemName: "photo")
                .font(.system(size: 48))
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    // MARK: - State plumbing

    /// Bridge between the optional `pendingDeleteIndex` and the
    /// confirmation dialog's `Bool` `isPresented` binding.
    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteIndex != nil },
            set: { presented in
                if !presented { pendingDeleteIndex = nil }
            }
        )
    }

    /// Picker selection -> raw `Data` -> caller's `onAdd`. The caller
    /// owns the resize step (`ImageProcessing.prepare`) — keeping it
    /// out of the carousel preserves the single-responsibility split:
    /// this view is about presentation, not encoding.
    private func handlePicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, let onAdd else {
            pickerItems = []
            return
        }
        isProcessing = true
        Task {
            var loadedData: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    loadedData.append(data)
                }
            }
            await onAdd(loadedData)
            await MainActor.run {
                pickerItems = []
                isProcessing = false
            }
        }
    }
}
