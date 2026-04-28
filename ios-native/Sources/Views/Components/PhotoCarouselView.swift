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
    /// Optional header title — typically the recipe name when the
    /// carousel is showing a recipe gallery. Nil falls back to the
    /// generic system inline title (no header text). Step-photo
    /// viewer leaves this nil since the step text is already in
    /// scope on the Detail page beneath.
    var title: String? = nil
    /// Page to land on when the carousel first appears. Lets callers
    /// open the carousel directly to the photo the user tapped (e.g.
    /// the horizontal photo row in detail) instead of always
    /// starting from page 0.
    var initialPage: Int = 0
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
    /// Reorder callback in SwiftUI's `move(fromOffsets:toOffset:)`
    /// convention. When provided, the toolbar surfaces ←/→ controls
    /// that shift the currently visible photo by one slot — much
    /// simpler than drag-to-reorder inside a paging `TabView`. Pass
    /// nil for view-only carousels.
    var onReorder: ((IndexSet, Int) -> Void)? = nil
    /// Total cap for the gallery this carousel is editing. `nil` =
    /// uncapped (recipe-level gallery). Set to 3 for step photos. The
    /// Add button hides at the cap and multi-pick selection narrows
    /// to fit the remaining slots.
    var maxImages: Int? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedPage: Int
    @State private var pendingDeleteIndex: Int?
    @State private var isProcessing: Bool = false

    /// Custom init so `selectedPage` seeds from `initialPage` exactly
    /// once at view-storage allocation. Parent re-renders (e.g. after
    /// the user commits a caption and the captions array updates)
    /// re-evaluate this struct's body, but `@State` storage is keyed
    /// by view identity — initial values written through `_state =
    /// State(initialValue:)` do not reset on re-evaluation. The
    /// previous `.onAppear` seed was vulnerable to re-firing in some
    /// SwiftUI contexts and silently snapping the carousel back to
    /// `initialPage` whenever the user committed a caption.
    init(
        photoData: [Data],
        title: String? = nil,
        initialPage: Int = 0,
        captions: [String?]? = nil,
        onAdd: (([Data]) async -> Void)? = nil,
        onDelete: ((Int) -> Void)? = nil,
        onSetCaption: ((Int, String?) -> Void)? = nil,
        onReorder: ((IndexSet, Int) -> Void)? = nil,
        maxImages: Int? = nil
    ) {
        self.photoData = photoData
        self.title = title
        self.initialPage = initialPage
        self.captions = captions
        self.onAdd = onAdd
        self.onDelete = onDelete
        self.onSetCaption = onSetCaption
        self.onReorder = onReorder
        self.maxImages = maxImages
        let clamped = photoData.isEmpty
            ? 0
            : max(0, min(initialPage, photoData.count - 1))
        self._selectedPage = State(initialValue: clamped)
    }

    private var canAdd: Bool {
        guard onAdd != nil else { return false }
        if let maxImages { return photoData.count < maxImages }
        return true
    }
    private var canDelete: Bool { onDelete != nil }
    /// Reorder controls surface only when the caller wired `onReorder`
    /// AND there's more than one photo to shuffle. Single-photo galleries
    /// hide the arrows entirely so the toolbar doesn't carry dead chrome.
    private var canReorder: Bool { onReorder != nil && photoData.count > 1 }
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
        .onAppear {
            stylePageControl()
            // `selectedPage` is now seeded from `initialPage` in init —
            // doing it here would risk re-firing on parent re-render
            // and snapping back to `initialPage` whenever the user
            // commits a caption.
        }
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
        if let title, !title.isEmpty {
            ToolbarItem(placement: .principal) {
                Text(StringCase.titleCase(title))
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        // Pack reorder + delete + add into one trailing slot so SwiftUI's
        // default per-item spacing doesn't spread them apart and break
        // the "controls for the current photo" mental grouping. Same
        // pattern as RecipeDetailView's heart/share/edit cluster.
        if canReorder || (canDelete && !photoData.isEmpty) || canAdd {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: AppSpacing.md) {
                    if canReorder {
                        reorderButtons
                    }
                    if canDelete && !photoData.isEmpty {
                        deleteButton
                    }
                    if canAdd {
                        addButton
                    }
                }
            }
        }
    }

    /// Move-left / move-right pair. Acts on whichever photo is in
    /// view (`selectedPage`). Disabled at the array's edges. Uses
    /// chevrons so the affordance reads as "shift this photo" rather
    /// than the navigation back/forward you'd see in a List.
    private var reorderButtons: some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                moveCurrent(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
            }
            .disabled(selectedPage <= 0)
            .foregroundStyle(selectedPage <= 0 ? AppColor.textTertiary : AppColor.accent)
            .accessibilityLabel("Move photo left")

            Button {
                moveCurrent(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
            }
            .disabled(selectedPage >= photoData.count - 1)
            .foregroundStyle(selectedPage >= photoData.count - 1 ? AppColor.textTertiary : AppColor.accent)
            .accessibilityLabel("Move photo right")
        }
    }

    /// Visible delete affordance. Mirrors the long-press path — both
    /// flow into the same confirmation dialog so the destructive
    /// behaviour stays consistent regardless of how the user got there.
    private var deleteButton: some View {
        Button {
            Haptics.warning()
            pendingDeleteIndex = selectedPage
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 17, weight: .semibold))
        }
        .foregroundStyle(AppColor.destructive)
        .accessibilityLabel("Remove this photo")
    }

    private var addButton: some View {
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
                    .font(.system(size: 17, weight: .semibold))
            }
        }
        .disabled(isProcessing || pickLimit == 0)
        .foregroundStyle(AppColor.accent)
    }

    /// Shift the currently visible photo by `delta` slots (-1 = left,
    /// +1 = right). Translates to SwiftUI's `move(fromOffsets:toOffset:)`
    /// convention before handing off to the caller's `onReorder`, then
    /// optimistically updates `selectedPage` so the user keeps watching
    /// the same photo as it slides into its new position.
    private func moveCurrent(by delta: Int) {
        guard let onReorder else { return }
        let from = selectedPage
        let to = from + delta
        guard to >= 0, to < photoData.count else { return }
        // SwiftUI's move convention: destination is the index in the
        // pre-removal array. Moving right by 1 means "land at offset
        // from+2" (drop is past the original neighbor). Left moves
        // are simpler — toOffset == target index.
        let toOffset = delta > 0 ? from + 2 : to
        Haptics.selection()
        onReorder(IndexSet([from]), toOffset)
        selectedPage = to
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

/// Caption row beneath the carousel photo. Two render modes:
///
///   - **Editable** — TextField is always rendered when editable. The
///     placeholder ("Add a description…") doubles as the empty-state
///     affordance, and tapping the field focuses it + raises the
///     keyboard. Tapping Done dismisses the keyboard; the field stays
///     visible with the typed text. There is **no swap** to a separate
///     "display" view on Done — that swap was responsible for two
///     bugs: (a) layout would shift when the editor's reserved-3-line
///     height collapsed to a 1-line display row, and (b) the user's
///     just-released Done finger could land on the freshly-rendered
///     display row and bring the keyboard right back up.
///
///   - **Read-only** — italic text display when caption is non-empty;
///     collapses to nothing when caption is empty.
///
/// Caption persistence funnels entirely through `onChange(of: fieldFocused)`:
/// any path that drops focus (Done button, tap-away, page swipe, view
/// teardown) calls `commit()` once. Caller's `onCommit` is idempotent
/// w.r.t. unchanged text, so multiple commits during a session are safe.
private struct CaptionRow: View {
    let pageIndex: Int
    let caption: String?
    let editable: Bool
    let onCommit: (String?) -> Void

    @State private var draft: String
    @FocusState private var fieldFocused: Bool

    init(
        pageIndex: Int,
        caption: String?,
        editable: Bool,
        onCommit: @escaping (String?) -> Void
    ) {
        self.pageIndex = pageIndex
        self.caption = caption
        self.editable = editable
        self.onCommit = onCommit
        // Seed `draft` from the caption at view-storage allocation so
        // the TextField shows existing text on first render — no
        // post-onAppear flicker.
        self._draft = State(initialValue: caption ?? "")
    }

    var body: some View {
        Group {
            if editable {
                editor
            } else if let caption, !caption.isEmpty {
                readOnlyRow(caption)
            } else {
                EmptyView()
            }
        }
        .onChange(of: caption) { _, newCaption in
            // Caption changed externally (e.g. delete reordered the
            // captions array, or another flow updated it). Mirror to
            // `draft` only when the user isn't actively typing — we'd
            // never want to clobber unsaved input.
            if !fieldFocused {
                draft = newCaption ?? ""
            }
        }
        .onChange(of: pageIndex) { _, _ in
            // Defensive: each per-page CaptionRow has a static
            // pageIndex so this rarely fires, but if it ever does
            // commit any unsaved typing first, then re-sync the draft.
            if fieldFocused { commit() }
            draft = caption ?? ""
        }
        .onChange(of: fieldFocused) { _, focused in
            // Single commit funnel — Done button, tap-away, page
            // swipe, view teardown all flow through here.
            if !focused {
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
            // `reservesSpace: true` keeps the field at 3 lines tall
            // even when the user has only typed one — so adding a
            // newline doesn't reflow the page and shrink the photo
            // above. The 3-line cap matches the previous max.
            .lineLimit(3, reservesSpace: true)
            .focused($fieldFocused)
            // System Return on the keyboard so newlines insert
            // naturally inside the multi-line field.
            .submitLabel(.return)
            .font(.system(size: 14, weight: .regular, design: .serif))
            .italic()
            .foregroundStyle(AppColor.textPrimary)
            .padding(AppSpacing.sm + 2)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(
                        fieldFocused ? AppColor.accent.opacity(0.5) : AppColor.divider,
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

            // Done button. Action is **just** "dismiss focus" — the
            // commit happens through `onChange(of: fieldFocused)` so
            // the codepath is identical to tap-away or page-swipe
            // dismissal. The button stays mounted regardless of
            // focus state so the editor's overall height never shifts;
            // when `fieldFocused == false` it's effectively a no-op
            // (resigning a non-existent first responder is harmless).
            Button {
                fieldFocused = false
                // Belt-and-suspenders responder resign — some sheet
                // contexts drop the focus binding mid-dismiss, and
                // we want the keyboard gone every time Done fires.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(fieldFocused ? AppColor.accent : AppColor.accent.opacity(0.4))
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.xs + 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func readOnlyRow(_ caption: String) -> some View {
        Text(caption)
            .font(.system(size: 14, weight: .regular, design: .serif))
            .italic()
            .foregroundStyle(AppColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .padding(AppSpacing.sm + 2)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        onCommit(trimmed.isEmpty ? nil : trimmed)
    }
}
