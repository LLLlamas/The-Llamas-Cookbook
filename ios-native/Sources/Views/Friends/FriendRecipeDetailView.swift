import SwiftUI

/// Read-only view of a single friend's recipe — pushed from
/// `FriendLibraryView` when the user taps a card. Fetches the full
/// `LCRecipeShareV1` envelope (envelope JSON + photo CKAssets) on
/// `.task`, then renders the same sectioned layout as the existing
/// `RecipeImportPreviewView` (titleBlock → meta → photos →
/// ingredients → steps → notes).
///
/// **Why mirror RecipeImportPreviewView's structure.** That view
/// already renders an envelope from scratch; the friend-detail
/// surface needs the same affordances minus the Save/Cancel
/// chrome and with friend's accent applied throughout. Reusing
/// the proven layout keeps the visual language consistent — a
/// recipe shared by Marco reads the same way whether the user
/// got it via AirDrop or by browsing his cookbook.
///
/// **Slice 4 scope.** Read-only render. The `square.and.arrow.down`
/// import button lands in slice 5 along with the
/// `materializeFromPublished` deep-copy entry point — for now
/// the toolbar exposes only the back chevron from the navigation
/// stack.
struct FriendRecipeDetailView: View {
    let friend: UserProfileSnapshot
    let summary: PublishedRecipeSummary

    @State private var envelope: LCRecipeShareV1?
    @State private var galleryPhotos: [Data] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var hasLoadedOnce: Bool = false

    private var friendAccent: Color {
        if let hex = friend.accentHex, let color = Color(hex: hex) {
            return color
        }
        return AppColor.accent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                content
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColor.background)
        .navigationTitle(StringCase.titleCase(summary.recipeTitle))
        .navigationBarTitleDisplayMode(.inline)
        .tint(friendAccent)
        .task {
            if !hasLoadedOnce {
                await loadEnvelope()
            }
        }
        .refreshable {
            await loadEnvelope()
        }
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if let envelope {
            envelopeBody(envelope)
        } else if isLoading {
            loadingState
        } else if let loadError {
            errorState(message: loadError)
        } else {
            // First frame before .task fires — render a minimal
            // placeholder that matches the loading state's shape so
            // the layout doesn't jolt when the spinner appears.
            loadingState
        }
    }

    // MARK: - Loading / error

    private var loadingState: some View {
        VStack(spacing: AppSpacing.md) {
            Spacer().frame(height: AppSpacing.xxl)
            ProgressView()
                .controlSize(.regular)
            Text("Loading recipe…")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
            Spacer().frame(height: AppSpacing.xxl)
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(AppColor.textTertiary)
            Text(message)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.selection()
                Task { await loadEnvelope() }
            } label: {
                Text("Try again")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm)
                    .background(friendAccent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxl)
    }

    // MARK: - Envelope render

    @ViewBuilder
    private func envelopeBody(_ envelope: LCRecipeShareV1) -> some View {
        titleBlock(envelope)
        metaLine(envelope)
        if !galleryPhotos.isEmpty {
            photosStrip
        }
        if let summaryText = envelope.recipe.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryText.isEmpty {
            Text(summaryText)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
        }
        if !envelope.recipe.tags.isEmpty {
            FlowRow(spacing: AppSpacing.xs) {
                ForEach(envelope.recipe.tags.sorted(), id: \.self) { tag in
                    tagChip(tag)
                }
            }
        }
        ingredientsSection(envelope)
        stepsSection(envelope)
        notesSection(envelope)
    }

    private func titleBlock(_ envelope: LCRecipeShareV1) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            // The recipe's title — already in the navigation bar but
            // also rendered prominently in the body so it reads as
            // a real title rather than just chrome. Same shadow
            // treatment as RecipeImportPreviewView so a shared
            // recipe looks identical viewed via friend-browse vs.
            // AirDrop import.
            Text(StringCase.titleCase(envelope.recipe.title))
                .font(AppFont.recipeTitle)
                .foregroundStyle(friendAccent)
                .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)

            // Always render an attribution line under the title
            // when viewing via FriendLibraryView. Two cases:
            //
            // 1. The recipe is the friend's own — show "Shared by
            //    <Friend>"; envelope.share.sharedBy may be nil for
            //    own-authored recipes that were published before
            //    the share-flow stamped sharedBy automatically. We
            //    fall back to the friend's UserProfile displayName.
            // 2. The recipe was imported by the friend from someone
            //    else — envelope.share.sharedBy carries that
            //    original name (slice 5 will set this on import).
            //    We render that instead so the chain root gets
            //    credit.
            if let provenance = provenanceLine(envelope) {
                Text(provenance)
                    .font(AppFont.eyebrow)
                    .foregroundStyle(AppColor.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func metaLine(_ envelope: LCRecipeShareV1) -> some View {
        let parts: [String] = {
            var bits: [String] = []
            if let s = envelope.recipe.servings { bits.append("Serves \(s)") }
            if let c = envelope.recipe.cookTimeMinutes { bits.append("Cook \(c) min") }
            return bits
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
        }
    }

    private var photosStrip: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Photos (\(galleryPhotos.count))")
                .font(AppFont.eyebrow)
                .foregroundStyle(AppColor.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(0..<galleryPhotos.count, id: \.self) { idx in
                        RecipeImageView(
                            data: galleryPhotos[idx],
                            contentMode: .fill,
                            cornerRadius: AppRadius.md
                        ) {
                            AppColor.surfaceRaised
                        }
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private func ingredientsSection(_ envelope: LCRecipeShareV1) -> some View {
        let sorted = envelope.recipe.ingredients.sorted { $0.order < $1.order }
        if !sorted.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                sectionHeading("Ingredients")
                ForEach(sorted, id: \.id) { ing in
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                        Circle()
                            .fill(friendAccent.opacity(0.5))
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(formatIngredient(ing))
                            .font(AppFont.ingredient)
                            .foregroundStyle(AppColor.textPrimary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stepsSection(_ envelope: LCRecipeShareV1) -> some View {
        let sorted = envelope.recipe.steps.sorted { $0.order < $1.order }
        if !sorted.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                sectionHeading("Steps")
                ForEach(Array(sorted.enumerated()), id: \.offset) { (idx, step) in
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                            Text("\(idx + 1).")
                                .font(AppFont.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(friendAccent)
                                .frame(width: 24, alignment: .leading)
                            Text(step.text)
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textPrimary)
                        }
                        if !step.photos.isEmpty {
                            Label(
                                "\(step.photos.count) \(step.photos.count == 1 ? "photo" : "photos")",
                                systemImage: "photo.fill"
                            )
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textTertiary)
                            .padding(.leading, 32)
                        }
                        if let note = step.specialNote?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !note.isEmpty {
                            Text("Note: \(note)")
                                .font(AppFont.caption)
                                .italic()
                                .foregroundStyle(AppColor.textSecondary)
                                .padding(.leading, 32)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ envelope: LCRecipeShareV1) -> some View {
        let notes = collectedNotes(envelope)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                sectionHeading("Notes")
                ForEach(notes, id: \.self) { note in
                    Text("Note: \(note)")
                        .font(AppFont.body)
                        .italic()
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        }
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(AppFont.sectionHeading)
            .foregroundStyle(AppColor.textPrimary)
            .padding(.bottom, 6)
            .background(alignment: .bottom) {
                Capsule()
                    .fill(friendAccent.opacity(0.55))
                    .frame(height: 2)
            }
            .padding(.top, AppSpacing.lg)
    }

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        Text(StringCase.titleCase(tag))
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .foregroundStyle(friendAccent)
            .overlay(Capsule().stroke(friendAccent.opacity(0.45), lineWidth: 1))
            .clipShape(Capsule())
    }

    // MARK: - Provenance + formatting

    /// Two-mode attribution line under the recipe title:
    ///
    /// - **Friend's own recipe** (envelope's `sharedBy` matches the
    ///   friend's display name, or is nil): "Shared by <Friend>".
    ///   The friend's UserProfile is the truth here even though
    ///   `sharedBy` may not be set on records published before the
    ///   share-flow stamped it.
    /// - **Friend imported it from someone else** (slice 5+ — the
    ///   chain root's name is in `sharedBy`): "Originally shared
    ///   by <Original Creator>". Surfaces the actual chain root so
    ///   credit travels with the recipe.
    ///
    /// Always passes through `RecipeShare.cappedDisplayName` for
    /// the same render-side defense the share preview applies.
    private func provenanceLine(_ envelope: LCRecipeShareV1) -> String? {
        let envelopeName = envelope.share.sharedBy
        let cappedEnvelopeName = RecipeShare.cappedDisplayName(envelopeName)
        // `cappedDisplayName` returns nil for empty / whitespace-only
        // input; in that rare case we'd otherwise render "Shared by "
        // with a trailing space, so suppress the line entirely.
        guard let cappedFriendName = RecipeShare.cappedDisplayName(friend.displayName) else {
            return nil
        }

        if let cappedEnvelopeName,
           cappedEnvelopeName != cappedFriendName {
            // Different name than the friend → chain attribution.
            return "Originally shared by \(cappedEnvelopeName)"
        }
        // Friend's own (or unstamped) recipe → just credit them.
        return "Shared by \(cappedFriendName)"
    }

    private func collectedNotes(_ envelope: LCRecipeShareV1) -> [String] {
        [envelope.recipe.prefaceNote,
         envelope.recipe.epilogueNote,
         envelope.recipe.generalNote]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Lightweight ingredient renderer — same logic as
    /// `RecipeImportPreviewView.formatIngredient` since both views
    /// render off `LCRecipeShareV1.ShareIngredient` rather than the
    /// SwiftData `Ingredient`. Trimmed; falls back to bare-name when
    /// quantity + unit are both empty.
    private func formatIngredient(_ ing: LCRecipeShareV1.ShareIngredient) -> String {
        let quantity = ing.quantity?.trimmingCharacters(in: .whitespaces) ?? ""
        let unit = ing.unit?.trimmingCharacters(in: .whitespaces) ?? ""
        var measureParts: [String] = []
        if !quantity.isEmpty { measureParts.append(quantity) }
        if !unit.isEmpty { measureParts.append(unit) }
        let measure = measureParts.joined(separator: " ")
        return measure.isEmpty ? ing.name : "\(measure) — \(ing.name)"
    }

    // MARK: - Fetch

    private func loadEnvelope() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            let fetched = try await CloudKitService.fetchPublishedRecipeEnvelope(
                recordName: summary.recordName
            )
            envelope = fetched
            galleryPhotos = decodeGallery(fetched)
            loadError = nil
        } catch {
            // Don't blank a previously-loaded envelope on a transient
            // refetch error — keep showing the cached version while
            // the user decides whether to retry. Only surface the
            // error UI when there's nothing to fall back to.
            if envelope == nil {
                loadError = errorMessage(for: error)
            }
        }
    }

    private func decodeGallery(_ envelope: LCRecipeShareV1) -> [Data] {
        let sorted = envelope.recipe.photos.sorted { $0.order < $1.order }
        // Drop empty bytes — `injecting(photoBytes:)` writes "" for
        // photos whose CKAsset was missing or over-cap, and an empty
        // Data renders as a blank thumbnail.
        return sorted
            .compactMap { Data(base64Encoded: $0.image) }
            .filter { !$0.isEmpty }
    }

    /// Map underlying CK / RecipeShare errors to user-facing copy.
    /// Most failures collapse to "couldn't load" since the user's
    /// remediation is the same regardless of the underlying cause.
    /// The unfriended case (CK returns "no permission") gets its
    /// own message because it's actionable: the user should leave
    /// this view rather than retry.
    private func errorMessage(for error: Error) -> String {
        if let recipeError = error as? RecipeShare.Error {
            return recipeError.errorDescription ?? "Couldn't load this recipe."
        }
        if let cloudError = error as? CloudKitServiceError {
            return cloudError.errorDescription ?? "Couldn't load this recipe."
        }
        return "Couldn't load this recipe."
    }
}
