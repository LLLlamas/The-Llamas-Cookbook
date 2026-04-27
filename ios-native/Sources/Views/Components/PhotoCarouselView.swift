import SwiftUI
import PhotosUI
import UIKit

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
    /// Per-photo captions, parallel to `photoData`. Pass `nil` for the
    /// whole array to suppress caption rows entirely (legacy behavior);
    /// pass a non-nil array (with `nil` entries for photos without a
    /// caption) to enable display. When `onSetCaption` is also provided
    /// the caption row becomes editable; otherwise it's read-only.
    var captions: [String?]? = nil
    var onAdd: (([Data]) async -> Void)? = nil
    var onDelete: ((Int) -> Void)? = nil
    /// Edit a single caption. Carousel calls this with the trimmed
    /// value or `nil` if the field was cleared. Caller is responsible
    /// for trimming + nil-empty normalization on the persistence side.
    var onSetCaption: ((Int, String?) -> Void)? = nil
    /// Reorder callback. Plumbed for v2; not surfaced in the v1 UI
    /// because drag-to-reorder inside a `TabView` is non-trivial and
    /// not load-bearing for personal use.
    var onReorder: ((IndexSet, Int) -> Void)? = nil
    /// Total cap for the gallery this carousel is editing. `nil` =
    /// uncapped (recipe-level gallery). Set to 3 for step photos. The
    /// Add button hides at the cap and multi-pick selection narrows
    /// to fit the remaining slots.
    var maxImages: Int? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedPage: Int = 0
    @State private var pendingDeleteIndex: Int?
    @State private var isProcessing: Bool = false

    private var canAdd: Bool {
        guard onAdd != nil else { return false }
        if let maxImages { return photoData.count < maxImages }
        return true
    }
    private var canDelete: Bool { onDelete != nil }
    /// True when caller passed a captions array — the caption row
    /// should render. False (legacy callers) collapses the row.
    private var captionsEnabled: Bool { captions != nil }

    /// How many more photos the user can pick this round. Bound by the
    /// 10-per-pick library cap and (when set) the remaining slots
    /// before `maxImages`.
    private var pickLimit: Int {
        let perRound = 10
        guard let maxImages else { return perRound }
        let remaining = max(0, maxImages - photoData.count)
        return min(perRound, remaining)
    }

    var body: some View {
        NavigationStack {
            // `Group` gives the conditional content a stable parent so
            // the modifiers below sit on a consistent view identity.
            // Without this wrapper, swapping between `emptyState` and
            // `carousel` could tear down attached modifiers (notably
            // `.alert`), which caused the step-photo add to "escape"
            // mid-confirm — the alert was destroyed during the picker
            // dismiss animation, never re-presented.
            Group {
                if photoData.isEmpty {
                    emptyState
                } else {
                    carousel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(carouselBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        // Stable modifiers — attached to the NavigationStack so they
        // survive any internal view swaps inside `Group`.
        .onAppear { stylePageControl() }
        .onChange(of: pickerItems) { _, items in
            handlePicked(items)
        }
        .onChange(of: photoData.count) { _, newCount in
            // After a delete the bound page index can fall off the
            // end of the array. Clamp to the last valid page so
            // SwiftUI doesn't render an empty `TabView` slot.
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
                    // 10-per-round library cap, narrowed further when
                    // `maxImages` is set so a multi-pick can't push
                    // past the gallery's total cap (3 for steps).
                    maxSelectionCount: pickLimit,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    if isProcessing {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(isProcessing || pickLimit == 0)
                .foregroundStyle(AppColor.accent)
            }
        }
    }

    // MARK: - Body content
    // (Empty state vs. carousel selection now lives inline inside
    // `body`'s NavigationStack — see comment there about why the
    // wrapping `Group` matters for alert stability.)

    private var carousel: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedPage) {
                ForEach(Array(photoData.enumerated()), id: \.offset) { index, data in
                    photoPage(data: data, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // "2 of 5" pill anchored below the page-indicator dots.
            // Pairs the textual counter with the carousel's own dot
            // affordance so both sit together at the bottom of the
            // gallery — the photo stays the focal point at the top.
            counterPill
                .padding(.top, AppSpacing.xs)
                .padding(.bottom, AppSpacing.sm)
        }
    }

    /// One carousel page. The photo sits **near the top** of the page
    /// (no leading spacer) so the image is the immediate focal point
    /// when the carousel opens, with the page-indicator dots and counter
    /// trailing below. The corner radius applies *to the image edges*
    /// (via `RecipeImageView.cornerRadius`) so portrait shots round at
    /// the picture's actual corners, not the empty letterbox space.
    ///
    /// Photo height is capped at `photoMaxHeight` so the caption row
    /// below has unambiguous space to land. Without the cap, `.fit`
    /// would expand to the full available height and the caption
    /// would feel squeezed against the bottom edge.
    private func photoPage(data: Data, index: Int) -> some View {
        VStack(spacing: AppSpacing.sm) {
            RecipeImageView(
                data: data,
                contentMode: .fit,
                cornerRadius: AppRadius.xl
            ) {
                placeholderTile
            }
            .frame(maxWidth: .infinity, maxHeight: photoMaxHeight)
            .shadow(color: AppColor.shadow, radius: 14, x: 0, y: 6)
            .shadow(color: AppColor.shadowSoft, radius: 2, x: 0, y: 1)

            // Caption sits directly under the photo, per page, so the
            // description reads as part of the picture rather than a
            // strip floating at the sheet's bottom edge. Each page
            // owns its own CaptionRow + draft state — that's fine
            // because the page index is fixed and tab-swipe focus
            // changes drive the commit through `fieldFocused`.
            if captionsEnabled {
                CaptionRow(
                    pageIndex: index,
                    caption: caption(at: index),
                    editable: onSetCaption != nil,
                    onCommit: { newCaption in
                        onSetCaption?(index, newCaption)
                    }
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.sm)
        .padding(.bottom, AppSpacing.md)
        .contentShape(Rectangle())
        .onLongPressGesture {
            guard canDelete else { return }
            Haptics.warning()
            pendingDeleteIndex = index
        }
    }

    /// Look up the caption for a specific page index. Returns nil when
    /// captions weren't enabled or the index is out of range.
    private func caption(at index: Int) -> String? {
        guard let captions, captions.indices.contains(index) else { return nil }
        return captions[index]
    }

    /// Vertical cap for each photo. `420pt` leaves a comfortable
    /// caption strip beneath even on the smallest supported phones
    /// (iPhone SE 3rd gen, ~667pt tall in portrait); on larger
    /// phones it just reads as a more "framed" gallery look. When no
    /// caption is in scope the cap still applies — the photo no
    /// longer fights the page-indicator dots for vertical real estate
    /// regardless of whether the caller wired captions.
    private var photoMaxHeight: CGFloat { 420 }

    /// Small "2 of 5" indicator. Hidden in single-photo mode (e.g. the
    /// step-image viewer) since there's nothing to count.
    @ViewBuilder
    private var counterPill: some View {
        if photoData.count > 1 {
            Text("\(selectedPage + 1) of \(photoData.count)")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(AppColor.accent)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 5)
                .background(AppColor.accentSoft)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(AppColor.accent.opacity(0.25), lineWidth: 0.8)
                )
        }
    }

    /// Soft cream gradient — top is the standard `background`, bottom
    /// dips slightly toward `accentSoft` so the carousel feels warmer
    /// than a raw page. Subtle enough not to fight the photo for
    /// attention; just enough to give the page depth.
    private var carouselBackground: some View {
        LinearGradient(
            colors: [
                AppColor.background,
                AppColor.accentSoft.opacity(0.45)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Tint the UIPageControl dots with the accent. Has to go through
    /// UIKit appearance because `.indexViewStyle(.page)` uses
    /// `UIPageControl` internally and SwiftUI offers no public knob for
    /// the dot color in iOS 18.
    private func stylePageControl() {
        let appearance = UIPageControl.appearance()
        appearance.currentPageIndicatorTintColor = UIColor(AppColor.accent)
        appearance.pageIndicatorTintColor = UIColor(AppColor.accent.opacity(0.28))
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundStyle(AppColor.textTertiary)
            if canAdd {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: pickLimit,
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
                .disabled(isProcessing || pickLimit == 0)
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

    /// Picker selection → raw `Data` → caller's `onAdd`. Direct path,
    /// no intermediate confirmation: the picker itself is the
    /// deliberate user action, and a second "Add these photos?" alert
    /// just doubled friction (and used to race the picker dismiss
    /// inside the step-photo sheet-in-sheet hierarchy, blocking the
    /// add entirely on some configurations).
    ///
    /// Picker results clamp to `maxImages` defensively in case the
    /// remaining cap shrank between picker present + dismiss
    /// (concurrent add elsewhere); in practice the picker already
    /// respects `pickLimit`.
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
            if let maxImages {
                let remaining = max(0, maxImages - photoData.count)
                loadedData = Array(loadedData.prefix(remaining))
            }
            // Hand to the caller (which owns `ImageProcessing.prepare`).
            // Even when loadedData is empty after clamping, we still
            // clear pickerItems + isProcessing so the picker is ready
            // for another round.
            if !loadedData.isEmpty {
                await onAdd(loadedData)
            }
            await MainActor.run {
                pickerItems = []
                isProcessing = false
            }
        }
    }
}

/// Caption row beneath the carousel photo. Three states:
///   1. **Editable + has caption** — italic display, tap to edit.
///   2. **Editable + no caption** — "+ Add description" pill button.
///   3. **Read-only + has caption** — italic display, no tap.
///   4. **Read-only + no caption** — collapses (renders nothing).
///
/// Editing is inline: tapping flips into `isEditing`, the TextField
/// takes focus, and submit / Done commits via `onCommit`. Paging to a
/// different photo (`pageIndex` change) auto-commits the in-flight
/// edit so the user can't accidentally lose typed text by swiping.
private struct CaptionRow: View {
    let pageIndex: Int
    let caption: String?
    let editable: Bool
    let onCommit: (String?) -> Void

    @State private var draft: String = ""
    @State private var isEditing: Bool = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if isEditing && editable {
                editor
            } else if let caption, !caption.isEmpty {
                displayRow(caption)
            } else if editable {
                addButton
            } else {
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isEditing)
        .onChange(of: pageIndex) { _, _ in
            // User swiped to a different photo. If they were mid-edit,
            // commit whatever they had typed before tearing down — losing
            // a caption to a stray swipe would be the worst kind of
            // silent data loss. Then refresh the draft to match the new
            // page's caption.
            if isEditing { commit() }
            draft = caption ?? ""
        }
        .onChange(of: fieldFocused) { _, focused in
            // Tap-away dismissal — when the keyboard goes away (user
            // taps elsewhere, scroll dismisses, etc.) commit + collapse
            // back to display mode.
            if !focused && isEditing {
                commit()
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: AppSpacing.xs) {
            TextField(
                "Description",
                text: $draft,
                prompt: Text("Add a description…")
                    .foregroundStyle(AppColor.textTertiary),
                axis: .vertical
            )
            .lineLimit(1...3)
            .focused($fieldFocused)
            .submitLabel(.done)
            .onSubmit { commit() }
            .font(.system(size: 14, weight: .regular, design: .serif))
            .italic()
            .foregroundStyle(AppColor.textPrimary)
            .padding(AppSpacing.sm + 2)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.accent.opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

            Button("Done") { commit() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColor.accent)
        }
    }

    private func displayRow(_ caption: String) -> some View {
        Button {
            guard editable else { return }
            startEditing(seed: caption)
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Text(caption)
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if editable {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.textTertiary)
                        .padding(.top, 2)
                }
            }
            .padding(AppSpacing.sm + 2)
            .background(AppColor.surface.opacity(editable ? 1 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(
                        editable ? AppColor.divider : .clear,
                        lineWidth: editable ? 1 : 0
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.plain)
        .disabled(!editable)
    }

    private var addButton: some View {
        Button {
            startEditing(seed: "")
        } label: {
            HStack(spacing: AppSpacing.xs + 2) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("Add description")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(AppColor.accent)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .overlay(Capsule().stroke(AppColor.accent.opacity(0.6), lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startEditing(seed: String) {
        draft = seed
        isEditing = true
        // Defer focus until the editor view is fully attached. Inside a
        // sheet-presented carousel (the step-photos path), 40ms isn't
        // enough — the focus binding silently drops if the TextField
        // isn't yet in the responder chain. 200ms covers the sheet
        // hierarchy's settle time without feeling like a delay.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            fieldFocused = true
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        onCommit(trimmed.isEmpty ? nil : trimmed)
        isEditing = false
        fieldFocused = false
    }
}
