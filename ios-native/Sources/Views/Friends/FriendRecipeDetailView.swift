import SwiftUI
import SwiftData

/// Read-only view of a single friend's recipe — pushed from
/// `FriendLibraryView` when the user taps a card. Fetches the full
/// `PublishedRecipeDetail` (envelope JSON + photo CKAssets + chain
/// attribution metadata) on `.task`, then renders the same
/// sectioned layout as the existing `RecipeImportPreviewView`
/// (titleBlock → meta → photos → ingredients → steps → notes).
///
/// **Why mirror RecipeImportPreviewView's structure.** That view
/// already renders an envelope from scratch; the friend-detail
/// surface needs the same affordances minus the Save/Cancel
/// chrome and with friend's accent applied throughout. Reusing
/// the proven layout keeps the visual language consistent — a
/// recipe shared by Marco reads the same way whether the user
/// got it via AirDrop or by browsing his cookbook.
///
/// **Slice 5 scope.** Read-only render plus the
/// `square.and.arrow.down` import button in the trailing toolbar
/// slot. Tap → `RecipeShare.materializeFromPublished` deep-copies
/// the recipe into the user's local library with chain
/// attribution stamped (`originalCreator*` + `originalSharer*` +
/// `originalRecipeID` + `importedAt`), then signals via
/// `NavigationContext.pendingImportedRecipeID` so RootView pushes
/// the new recipe's Detail and LibraryView dismisses the Profile
/// sheet that hosts this view. A llama progress overlay shows
/// during photo-bearing imports; photoless imports are instant
/// (no overlay needed — sheet dismiss + Detail push is the visible
/// confirmation).
struct FriendRecipeDetailView: View {
    let friend: UserProfileSnapshot
    let summary: PublishedRecipeSummary

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(NavigationContext.self) private var navContext
    @Environment(UserAccount.self) private var userAccount

    /// Fetched payload — envelope + chain-attribution metadata.
    /// Stored together so the import handler has both in scope
    /// without re-fetching. `envelope` below reads through this.
    @State private var publishedDetail: PublishedRecipeDetail?
    @State private var galleryPhotos: [Data] = []
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var hasLoadedOnce: Bool = false
    @State private var isImporting: Bool = false
    /// Whether to render the full-screen llama progress overlay.
    /// Decoupled from `isImporting` because the overlay is a UI
    /// concern — only photo-bearing imports take long enough to
    /// warrant it — while `isImporting` exists strictly to gate
    /// double-taps and is set unconditionally for that purpose.
    @State private var showImportOverlay: Bool = false
    @State private var importError: String? = nil
    @State private var showingDuplicateAlert = false
    @State private var duplicateRenameText = ""

    /// Single ticker for the friend-detail's vertical scroll surface.
    /// Per CLAUDE.md ("one `ScrollSectionTicker` per scroll surface"),
    /// the tag pills AND the major content sections (photos / tags /
    /// ingredients / steps / notes) all funnel into this one ticker —
    /// dedup keys keep the crossings distinct. `reset()` on each
    /// `loadDetail()` since a refetch swaps the whole envelope.
    @State private var hapticTicker = ScrollSectionTicker()

    /// 1pt invisible anchor for a vertical section boundary. A full
    /// section block (e.g. Steps with a dozen entries) can exceed
    /// viewport height and never hit the 0.95 visibility threshold
    /// `scrollSectionHaptic` requires; a 1pt anchor reliably does.
    private func sectionAnchor(_ key: String) -> some View {
        Color.clear
            .frame(height: 1)
            .scrollSectionHaptic(section: key, ticker: hapticTicker)
    }

    /// Sugared accessor for the envelope half of `publishedDetail`,
    /// so the rendering code below reads `envelope` symmetrically
    /// to its slice 4 form.
    private var envelope: LCRecipeShareV1? {
        publishedDetail?.envelope
    }

    /// Whether the "Add to my book" action should be enabled.
    /// Disabled during in-flight load (no envelope yet) and during
    /// the import itself (no double-fire). The materialize is
    /// purely local — iCloud availability isn't a precondition for
    /// the import to succeed; the cloud-side mirror upload of the
    /// resulting local recipe is best-effort and silent-no-ops on
    /// its own when iCloud is unreachable.
    private var canImport: Bool {
        publishedDetail != nil && !isImporting
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
        .llamaBackground()
        .navigationTitle(StringCase.titleCase(summary.recipeTitle))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .tint(friend.resolvedAccent)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.selection()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(friend.resolvedAccent)
                        .accentTextOutline()
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Back")
            }
            // "Add to my book" — primary action, trailing position
            // (iOS HIG convention for an action-on-this-screen).
            // Spec sketch said "left of the llama," but `Friend`
            // surfaces don't carry a llama in the toolbar (the
            // llama lives in `RecipeDetailView` for own recipes
            // and isn't transplanted into this read-only view);
            // trailing keeps the affordance discoverable in the
            // place users look first.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await performImport() }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canImport ? friend.resolvedAccent : AppColor.textTertiary)
                        .accentTextOutline()
                }
                .disabled(!canImport)
                .accessibilityLabel("Add to my book")
            }
        }
        .overlay {
            if showImportOverlay {
                importOverlay
            }
        }
        .alert(
            "Couldn't import recipe",
            isPresented: importErrorPresented,
            presenting: importError
        ) { _ in
            Button("OK") { importError = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "Recipe already saved",
            isPresented: $showingDuplicateAlert
        ) {
            TextField("Recipe name", text: $duplicateRenameText)
                .textInputAutocapitalization(.words)
            Button("Import") {
                let trimmed = duplicateRenameText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task { await performImport(overrideTitle: trimmed) }
            }
            Button("Cancel", role: .cancel) { Haptics.selection() }
        } message: {
            if let title = envelope?.recipe.title {
                Text("You already have a recipe titled \"\(title)\". Import this one with a different name?")
            } else {
                Text("You already have a recipe with this title. Import this one with a different name?")
            }
        }
        .task {
            if !hasLoadedOnce {
                await loadDetail()
            }
        }
        .refreshable {
            await loadDetail()
        }
    }

    private var importErrorPresented: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }

    /// Full-screen translucent overlay during a photo-bearing
    /// import. Ignores hit testing on the underlying view so the
    /// user can't double-tap import or pop back mid-write.
    private var importOverlay: some View {
        ZStack {
            AppColor.background.opacity(0.85)
                .ignoresSafeArea()
            VStack(spacing: AppSpacing.md) {
                LlamaProgressIndicator(size: 80, accent: friend.resolvedAccent)
                Text("Adding to your book…")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textSecondary)
            }
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
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
                Task { await loadDetail() }
            } label: {
                Text("Try again")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm)
                    .background(friend.resolvedAccent)
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
            sectionAnchor("photos")
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
                        .scrollSectionHaptic(section: tag, ticker: hapticTicker)
                }
            }
        }
        if !envelope.recipe.ingredients.isEmpty {
            sectionAnchor("ingredients")
        }
        ingredientsSection(envelope)
        if !envelope.recipe.steps.isEmpty {
            sectionAnchor("steps")
        }
        stepsSection(envelope)
        if !collectedNotes(envelope).isEmpty {
            sectionAnchor("notes")
        }
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
                .foregroundStyle(friend.resolvedAccent)
                .accentTextOutline()
                .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)

            // Render an attribution line only when the friend
            // imported the recipe from someone else — surfaces
            // the chain root so credit travels with the recipe.
            // The friend's own recipes get no eyebrow line here:
            // "Shared by <Friend>" repeats the navigation title
            // ("<Friend>'s Cookbook") and adds visual noise.
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
            if let p = envelope.recipe.prepTimeMinutes { bits.append("Prep \(p) min") }
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
                            .fill(friend.resolvedAccent.opacity(0.5))
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
                                .foregroundStyle(friend.resolvedAccent)
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
                    .fill(friend.resolvedAccent.opacity(0.55))
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
            .foregroundStyle(friend.resolvedAccent)
            .overlay(Capsule().stroke(friend.resolvedAccent.opacity(0.45), lineWidth: 1))
            .clipShape(Capsule())
    }

    // MARK: - Provenance + formatting

    /// Attribution line under the recipe title — only rendered when
    /// the friend imported the recipe from someone else (chain
    /// attribution). For the friend's own recipes we suppress the
    /// line entirely: the friend's name is already in the
    /// navigation title ("Catalina's Cookbook"), so a "Shared by
    /// Catalina" eyebrow on every card just repeats what the user
    /// already knows. The chain-attribution case still surfaces
    /// because the original creator isn't otherwise visible.
    ///
    /// Always passes through `RecipeShare.cappedDisplayName` for
    /// the same render-side defense the share preview applies.
    private func provenanceLine(_ envelope: LCRecipeShareV1) -> String? {
        guard let cappedEnvelopeName = RecipeShare.cappedDisplayName(envelope.share.sharedBy) else {
            return nil
        }
        let cappedFriendName = RecipeShare.cappedDisplayName(friend.displayName)
        if cappedEnvelopeName == cappedFriendName {
            return nil
        }
        return "Originally shared by \(cappedEnvelopeName)"
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

    private func loadDetail() async {
        isLoading = true
        // A refetch can swap the envelope wholesale (and with it the
        // tag set), so re-arm the chip ticker — a re-populated FlowRow
        // shouldn't tick on its initial settle.
        hapticTicker.reset()
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        // Seed friend: pull the pre-built envelope from
        // `SeedFriend.detail(forRecordName:)`. Seed envelopes now ship
        // with a bundled hero photo encoded into `recipe.photos`, so
        // run them through the same `decodeGallery` path as CloudKit
        // detail — the photos strip renders identically across seed
        // and real-friend recipes.
        if SeedFriend.isSeed(friend) {
            if let fetched = SeedFriend.detail(forRecordName: summary.recordName) {
                publishedDetail = fetched
                galleryPhotos = decodeGallery(fetched.envelope)
                loadError = nil
            } else {
                loadError = "Couldn't load this recipe."
            }
            return
        }
        do {
            let fetched = try await CloudKitService.fetchPublishedRecipe(
                recordName: summary.recordName
            )
            publishedDetail = fetched
            galleryPhotos = decodeGallery(fetched.envelope)
            loadError = nil
        } catch {
            // Don't blank a previously-loaded detail on a transient
            // refetch error — keep showing the cached version while
            // the user decides whether to retry. Only surface the
            // error UI when there's nothing to fall back to.
            if publishedDetail == nil {
                loadError = errorMessage(for: error)
            }
        }
    }

    // MARK: - Import

    /// Deep-copy the friend's recipe into the local library with
    /// chain attribution stamped, then signal RootView (via
    /// `NavigationContext`) to dismiss the Profile sheet and push
    /// the new recipe's Detail. Best-effort: a SwiftData save
    /// failure surfaces an alert; everything else degrades to the
    /// existing CloudKit-unavailable handling.
    ///
    /// Photo-bearing imports show the llama progress overlay (the
    /// `ImageProcessing.prepare` re-encode of N photos can take
    /// 200ms-2s); photoless imports skip it (the work is
    /// instantaneous and the sheet-dismiss + Detail-push transition
    /// is its own visible confirmation).
    @MainActor
    private func performImport(overrideTitle: String? = nil) async {
        // Gate double-taps before any async work. Duplicate-title
        // checks stay before the flag so the rename prompt can appear
        // without putting the toolbar into an importing state.
        guard !isImporting else { return }
        guard let detail = publishedDetail else {
            return
        }

        if overrideTitle == nil,
           RecipeShare.libraryContainsRecipe(
               withTitle: detail.envelope.recipe.title,
               in: modelContext
           ) {
            duplicateRenameText = RecipeShare.resolveImportTitle(
                base: detail.envelope.recipe.title,
                in: modelContext
            )
            Haptics.warning()
            showingDuplicateAlert = true
            return
        }

        isImporting = true
        let hasPhotos = !detail.envelope.recipe.photos.isEmpty
            || detail.envelope.recipe.steps.contains { !$0.photos.isEmpty }

        Haptics.impact(.light)
        if hasPhotos {
            withAnimation { showImportOverlay = true }
        }

        let newRecipe = await RecipeShare.materializeFromPublished(
            detail,
            into: modelContext,
            friend: friend,
            overrideTitle: overrideTitle
        )

        do {
            try modelContext.save()
        } catch {
            // The rare case where SwiftData refuses the insert —
            // we surface this rather than swallow because the user
            // tapped a deliberate action and would otherwise wonder
            // why nothing happened.
            withAnimation {
                isImporting = false
                showImportOverlay = false
            }
            importError = "Couldn't save the imported recipe."
            return
        }

        Haptics.success()
        // Hide the overlay before the signal fires so the sheet-
        // dismiss animation doesn't fight the overlay's fade-out.
        withAnimation {
            isImporting = false
            showImportOverlay = false
        }

        // Audit write — fire-and-forget so a network blip doesn't
        // delay the post-import navigation. The chip on the
        // original creator's detail view depends on this row
        // landing, but a missed write only under-counts by one
        // (acceptable for a delight surface). Captured locals
        // make the detached task `Sendable`-safe — `newRecipe`
        // and the `friend` snapshot are both reference / value
        // types we can copy out cheaply.
        writeImportAuditRow(for: newRecipe)

        // Fire the fly-to-tab ghost + "Saved" toast affordance.
        // Carries the friend's accent so the toast tints
        // consistently regardless of where the overlay decodes it.
        // Set BEFORE `pendingImportedRecipeID` so the toast overlay
        // sees its signal before the sheet-dismiss / Detail-push
        // cascade pulls focus.
        navContext.pendingFriendImportToast = FriendImportToast(
            accentHex: friend.accentHex
        )

        // Trigger the cross-sheet navigation. LibraryView's
        // `.onChange(pendingImportedRecipeID)` dismisses the
        // Profile sheet; RootView's same observer runs the
        // existing post-save highlight + Detail-push sequence.
        navContext.pendingImportedRecipeID = newRecipe.id
    }

    /// Emit the `RecipeImport` CK record for this import event.
    /// Pulls the chain-root identifiers from the freshly-stamped
    /// local Recipe (set inside `materializeFromPublished` —
    /// `originalCreatorUserRecordName` always resolves, falling
    /// back to the friend's id when the friend is the chain
    /// root, so this row's `originalCreatorID` is never empty).
    /// Importer fields come from `UserAccount` for identity and
    /// `UserProfileMirror` for the iCloud user record name —
    /// the same pair that powers the `Friendship` and
    /// `PublishedRecipe` writes elsewhere in the app, so a
    /// missing iCloud account silently skips the write the same
    /// way those flows do.
    private func writeImportAuditRow(for newRecipe: Recipe) {
        // Importing from the seed friend never produces a CloudKit
        // audit row — there's no real creator to credit, and writing
        // one would just pollute the public DB with rows pointing at
        // the `your-llama-seed` sentinel.
        guard !SeedFriend.isSeed(friend) else { return }
        guard let importerID = UserProfileMirror.cachedRecordID() else { return }
        // Read the @Model fields into local `String?` values BEFORE
        // crossing the `Task.detached` boundary. SwiftData @Model
        // references are not Sendable, and a fast delete-then-import
        // could tear down the model context before the detached task
        // runs — capturing the strings makes the closure independent
        // of the model's lifetime.
        let creatorIDLocal: String? = newRecipe.originalCreatorUserRecordName
        let recipeIDLocal: String? = newRecipe.originalRecipeID
        guard let originalCreatorID = creatorIDLocal,
              let originalRecipeID = recipeIDLocal
        else { return }
        let importerDisplayName = userAccount.status.identity?.displayName ?? "Cook"
        let sourceUserID = friend.userRecordName
        Task.detached {
            try? await CloudKitService.writeRecipeImport(
                originalCreatorID: originalCreatorID,
                originalRecipeID: originalRecipeID,
                importerID: importerID,
                importerDisplayName: importerDisplayName,
                sourceUserID: sourceUserID
            )
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
