import SwiftUI
import UniformTypeIdentifiers

/// Dedicated reorder mode for `PhotoCarouselView`. Renders all photos
/// as a 3-column tile grid with drag-and-drop reordering. Each drop
/// fires the parent's `onMove` closure — same `(IndexSet, Int)`
/// SwiftUI move convention used by `PhotoCarouselView.onReorder` —
/// and mutates the sheet's local state in lockstep so the grid stays
/// visually consistent without needing the parent's photo array to
/// round-trip through SwiftData / draft state mid-drag.
///
/// The sheet seeds its local arrays from `initialPhotos` exactly once
/// (via the `init` State seed). Subsequent parent re-renders don't
/// reset the order — by the time the parent re-renders with the new
/// order, the sheet has already updated its own state and they agree.
struct PhotoReorderView: View {
    let initialPhotos: [Data]
    /// Optional sheet header — typically the recipe name, mirrors the
    /// carousel's principal title slot for continuity.
    var title: String?
    /// Forwarded to the parent's `onReorder` after each drop. The
    /// sheet also applies the same move to its own `photos` / `ids`
    /// arrays so the grid reflects the change immediately.
    let onMove: (IndexSet, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance

    /// Stable identity for each tile. Generated once on init so a tile
    /// keeps the same UUID across reorders — required for
    /// `.onDrag` / `.onDrop` to track which tile is in flight even as
    /// indices shift around it.
    @State private var ids: [UUID]
    @State private var photos: [Data]
    /// UUID of the tile currently being dragged. Read by the drop
    /// delegates to find the source row regardless of where it has
    /// scrolled to mid-gesture.
    @State private var draggingID: UUID? = nil

    init(
        initialPhotos: [Data],
        title: String? = nil,
        onMove: @escaping (IndexSet, Int) -> Void
    ) {
        self.initialPhotos = initialPhotos
        self.title = title
        self.onMove = onMove
        // Seed both arrays from initialPhotos exactly once. @State seeds
        // run only at view-storage allocation, so subsequent renders of
        // this struct don't clobber drag state.
        self._photos = State(initialValue: initialPhotos)
        self._ids = State(initialValue: initialPhotos.map { _ in UUID() })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: AppSpacing.sm + 2) {
                    // Iterate over enumerated IDs so the ForEach diff is
                    // keyed on the stable photo UUID — required for the
                    // move animation to track tiles to their new slots.
                    // `photos[index]` is safe because the drop delegate
                    // mutates `ids` and `photos` atomically.
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        tile(id: id, data: photos[index], index: index)
                    }
                }
                .padding(AppSpacing.lg)
            }
            .llamaBackground()
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(photos.count) photo\(photos.count == 1 ? "" : "s")")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Haptics.selection()
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                hint
            }
        }
    }

    /// Three-column grid keeps tiles thumbnail-sized on iPhone widths
    /// while still showing four rows on a typical 9-photo recipe at a
    /// glance. Adjusts naturally on iPad widths if support is ever added.
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: AppSpacing.sm + 2), count: 3)
    }

    /// Pulled-back instructions strip at the very top of the sheet.
    /// Lives in `safeAreaInset` so it floats above the scroll content
    /// — a regular row at the top would be hidden as the user scrolls
    /// down through a long gallery.
    private var hint: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "hand.draw")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(appearance.accentColor)
            Text("Drag a photo onto another to swap their order.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .background(AppColor.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppColor.divider)
                .frame(height: 1)
        }
    }

    /// One tile in the grid. The actual photo is rendered with
    /// `RecipeImageView` so caching, downscaling, and graceful
    /// placeholder behaviour all match Detail / Carousel rendering.
    /// Index badge in the top-leading corner gives the user a numeric
    /// anchor while reordering ("photo 4 went to position 2").
    private func tile(id: UUID, data: Data, index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            RecipeImageView(
                data: data,
                contentMode: .fill,
                cornerRadius: AppRadius.md
            )
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(
                        draggingID == id
                            ? AppColor.accent
                            : AppColor.divider.opacity(0.6),
                        lineWidth: draggingID == id ? 2 : 0.8
                    )
            )
            .shadow(
                color: draggingID == id
                    ? AppColor.accent.opacity(0.45)
                    : AppColor.shadowSoft,
                radius: draggingID == id ? 8 : 2,
                x: 0,
                y: 1
            )

            // Position badge — small accent-tinted pill in the top-leading
            // corner. Helps the user track ordering as they shuffle.
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(AppColor.onAccent)
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 4)
                .background(Capsule().fill(AppColor.accent.opacity(0.92)))
                .padding(AppSpacing.xs)
        }
        .opacity(draggingID == id ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.15), value: draggingID)
        .onDrag {
            // Carry the tile's UUID so the drop delegate can find the
            // source even after the user has scrolled away from it.
            // Setting `draggingID` immediately gives the source tile
            // its dimmed/highlighted appearance without waiting for
            // the system to surface a drag preview.
            draggingID = id
            return NSItemProvider(object: id.uuidString as NSString)
        } preview: {
            // Compact preview that matches the tile size — without an
            // explicit preview SwiftUI lifts the entire view tree and
            // can produce an oversized lift on the first drag.
            RecipeImageView(
                data: data,
                contentMode: .fill,
                cornerRadius: AppRadius.md
            )
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .shadow(color: AppColor.shadow, radius: 12, y: 4)
        }
        .onDrop(of: [.text], delegate: PhotoTileDropDelegate(
            targetID: id,
            ids: $ids,
            photos: $photos,
            draggingID: $draggingID,
            onMove: onMove
        ))
    }

    private var headerTitle: String {
        guard let title, !title.isEmpty else { return "Rearrange" }
        return "Rearrange — \(StringCase.titleCase(title))"
    }
}

/// Drop delegate that translates "drop tile A onto tile B" into the
/// `Array.move(fromOffsets:toOffset:)` SwiftUI convention, applies
/// the move to the sheet's local state, and forwards the same move
/// to the parent's `onMove` closure. Reports `.move` to suppress
/// iOS's default green "+" copy indicator on the drag preview.
private struct PhotoTileDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var ids: [UUID]
    @Binding var photos: [Data]
    @Binding var draggingID: UUID?
    let onMove: (IndexSet, Int) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingID = nil }
        guard let fromID = draggingID,
              fromID != targetID,
              let fromIdx = ids.firstIndex(of: fromID),
              let toIdx = ids.firstIndex(of: targetID)
        else { return false }
        // SwiftUI move semantics: `toOffset` is the destination index in
        // the *pre-removal* array. Forward moves (fromIdx < toIdx) need
        // toIdx + 1 so the dragged item lands AT the target's old slot
        // (the target slides one left to make room). Backward moves use
        // toIdx directly — the dragged item lands at toIdx, target slides
        // one right.
        let toOffset = fromIdx < toIdx ? toIdx + 1 : toIdx
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            ids.move(fromOffsets: IndexSet([fromIdx]), toOffset: toOffset)
            photos.move(fromOffsets: IndexSet([fromIdx]), toOffset: toOffset)
        }
        Haptics.impact(.medium)
        // Forward the same move to the source-of-truth (Recipe / Draft).
        onMove(IndexSet([fromIdx]), toOffset)
        return true
    }
}
