import SwiftUI
import SwiftData

/// Read-only preview of an incoming `.llamarecipe` share. Presented
/// as a sheet from `RootView` whenever `pendingShareImport` becomes
/// non-nil — file open via `onOpenURL` (AirDrop / Files / Mail) or
/// URL-scheme deep link (`llamascookbook://recipe/v1/<base64url>`).
///
/// Two outcomes:
///
/// - **Save to Library** → calls `RecipeShare.materialize(_:into:)`,
///   which rewrites UUIDs, stamps provenance, resolves title
///   collisions ("Banana Bread" → "Banana Bread (1)" if needed), and
///   re-runs photos through `ImageProcessing.prepare` before
///   inserting into SwiftData. Dismisses on success.
/// - **Cancel** → dismisses without persisting. The decoded envelope
///   is dropped from RootView's state.
///
/// The preview displays the **original** sender title; the resolved
/// (possibly suffixed) title only appears after Save lands the recipe
/// in Library. See Recipe-Sharing.md §6.3 for the title-collision
/// rationale.
struct RecipeImportPreviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(UserAccount.self) private var userAccount

    let envelope: LCRecipeShareV1
    /// Called after `RecipeShare.materialize` returns the new
    /// `Recipe` and before the sheet dismisses. RootView uses it to
    /// push the recipient straight into the new recipe's Detail view
    /// — appending to its programmatic NavigationPath after a brief
    /// delay so the dismiss animation doesn't race with the push.
    /// Defaults to a no-op so call sites that just want the import
    /// without the navigation hand-off (tests, future entry points)
    /// don't have to supply one.
    var onSaved: (Recipe) -> Void = { _ in }

    /// Decoded gallery photos. Computed in `onAppear` once so we don't
    /// re-base64-decode on every render. Step photos are surfaced as a
    /// count badge in the steps section rather than thumbnails — keeps
    /// the preview light, full step photos appear after Save.
    @State private var galleryPhotos: [Data] = []
    @State private var isSaving = false

    /// Drives the "you already have this recipe" alert — when Save is
    /// tapped against an envelope whose title exactly matches an
    /// existing library entry, we pause the materialize, ask the user
    /// to confirm, and let them edit the auto-numbered suffix
    /// ("Banana Bread (1)") before the recipe lands. Existing silent
    /// suffix-resolution still runs as the fallback safety net inside
    /// `RecipeShare.materialize` for any path that doesn't go through
    /// this prompt.
    @State private var showingDuplicateAlert = false
    @State private var duplicateRenameText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    titleBlock
                    metaLine
                    if !galleryPhotos.isEmpty { photosStrip }
                    if let summary = envelope.recipe.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !summary.isEmpty {
                        Text(summary)
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
                    ingredientsSection
                    stepsSection
                    notesSection
                    // Breathing room past the bottom safe area so the
                    // last note isn't crammed against the home indicator.
                    Color.clear.frame(height: AppSpacing.xxl)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.lg)
            }
            .llamaBackground()
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Text("Cancel")
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .principal) {
                    Text("Imported Recipe")
                        .font(AppFont.eyebrow)
                        .foregroundStyle(AppColor.textTertiary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveToLibrary()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                                .foregroundStyle(appearance.accentColor)
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { decodeGalleryPhotos() }
        // SwiftUI .alert with a TextField is the iOS-standard rename
        // prompt (Photos folder rename, Files duplicate handling).
        // The TextField pre-populates with the auto-resolved
        // "{title} (N)" suffix so the user can either accept the
        // placeholder verbatim or edit it before confirming.
        .alert(
            "Recipe already saved",
            isPresented: $showingDuplicateAlert
        ) {
            TextField("Recipe name", text: $duplicateRenameText)
                .textInputAutocapitalization(.words)
            Button("Save") {
                let trimmed = duplicateRenameText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                performSave(withOverrideTitle: trimmed)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You already have a recipe titled \"\(envelope.recipe.title)\". Save this one with a different name?")
        }
    }

    // MARK: subsections

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(StringCase.titleCase(envelope.recipe.title))
                .font(AppFont.recipeTitle)
                .foregroundStyle(appearance.accentColor)
                .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)

            if let provenance = provenanceLine {
                Text(provenance)
                    .font(AppFont.eyebrow)
                    .foregroundStyle(AppColor.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var metaLine: some View {
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

    @ViewBuilder
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
    private var ingredientsSection: some View {
        let sorted = envelope.recipe.ingredients.sorted { $0.order < $1.order }
        if !sorted.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                sectionHeading("Ingredients")
                ForEach(sorted, id: \.id) { ing in
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                        Circle()
                            .fill(appearance.accentColor.opacity(0.5))
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
    private var stepsSection: some View {
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
                                .foregroundStyle(appearance.accentColor)
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
                        if let note = step.specialNote?.trimmingCharacters(in: .whitespacesAndNewlines),
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
    private var notesSection: some View {
        let notes = collectedNotes
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

    @ViewBuilder
    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(AppFont.sectionHeading)
            .foregroundStyle(AppColor.textPrimary)
            .padding(.bottom, 6)
            .background(alignment: .bottom) {
                Capsule()
                    .fill(appearance.accentColor.opacity(0.55))
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
            .foregroundStyle(appearance.accentColor)
            .overlay(Capsule().stroke(appearance.accentColor.opacity(0.45), lineWidth: 1))
            .clipShape(Capsule())
    }

    // MARK: helpers

    /// Renders "Originally shared by Lorenzo · Apr 27, 2026" when both
    /// fields are present; "Originally shared by Lorenzo" alone when
    /// only the name is set; nil when sharedBy is empty/nil (matches
    /// Recipe-Sharing.md §15 test #14 — empty-name share emits no
    /// provenance line). Display-name cap is enforced here as a
    /// render-side defense for envelopes from older app versions
    /// that predate the encode-side cap.
    /// `createdAt` is clamped to "now" to stop a sender from emitting
    /// a future-dated provenance line ("shared by X · Jan 1 2099").
    private var provenanceLine: String? {
        guard let by = RecipeShare.cappedDisplayName(envelope.share.sharedBy) else { return nil }
        let safeDate = min(envelope.share.createdAt, Date())
        return "Originally shared by \(by) · \(Formatters.date.string(from: safeDate))"
    }

    /// Recipe-level notes in canonical surface order: preface, then
    /// epilogue, then general (general is "free-floating" so it sits
    /// last). Trimmed + empty-filtered.
    private var collectedNotes: [String] {
        [envelope.recipe.prefaceNote,
         envelope.recipe.epilogueNote,
         envelope.recipe.generalNote]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Lightweight ingredient renderer for the preview only. The full
    /// `Ingredient.display(scaledBy:)` pipeline (pluralization, "of"
    /// connector, measurable-fraction snap) is overkill for a
    /// read-only confirmation view — and `display` is on the SwiftData
    /// `@Model` `Ingredient`, not on the Codable `ShareIngredient`,
    /// so reusing it would mean constructing a temp managed object
    /// just to render text. After Save, the real `Ingredient` rows
    /// run through the canonical formatter as expected.
    private func formatIngredient(_ ing: LCRecipeShareV1.ShareIngredient) -> String {
        let quantity = ing.quantity?.trimmingCharacters(in: .whitespaces) ?? ""
        let unit = ing.unit?.trimmingCharacters(in: .whitespaces) ?? ""
        var measureParts: [String] = []
        if !quantity.isEmpty { measureParts.append(quantity) }
        if !unit.isEmpty { measureParts.append(unit) }
        let measure = measureParts.joined(separator: " ")
        return measure.isEmpty ? ing.name : "\(measure) — \(ing.name)"
    }

    private func decodeGalleryPhotos() {
        let sorted = envelope.recipe.photos.sorted { $0.order < $1.order }
        galleryPhotos = sorted.compactMap { Data(base64Encoded: $0.image) }
    }

    private func saveToLibrary() {
        guard !isSaving else { return }
        let baseTitle = envelope.recipe.title
        // Branch on exact-title duplicate detection. Match the
        // case-sensitive, no-trim semantics of
        // `RecipeShare.resolveImportTitle` so we surface the prompt
        // for the same titles the silent path would have suffixed.
        if RecipeShare.libraryContainsRecipe(withTitle: baseTitle, in: modelContext) {
            duplicateRenameText = RecipeShare.resolveImportTitle(
                base: baseTitle,
                in: modelContext
            )
            Haptics.warning()
            showingDuplicateAlert = true
            return
        }
        performSave(withOverrideTitle: nil)
    }

    /// Shared save tail used by both the no-collision path
    /// (`overrideTitle: nil` lets `materialize` run its silent
    /// suffix-resolver) and the duplicate-confirmation path
    /// (`overrideTitle` carries the user's edited name).
    private func performSave(withOverrideTitle overrideTitle: String?) {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            let recipe = await RecipeShare.materialize(
                envelope,
                into: modelContext,
                overrideTitle: overrideTitle
            )
            writeImportAuditRow(forEnvelope: envelope)
            isSaving = false
            Haptics.success()
            // Hand the new recipe back to the parent BEFORE dismiss —
            // RootView uses it to queue a Detail push that fires once
            // the sheet finishes its dismiss animation.
            onSaved(recipe)
            dismiss()
        }
    }

    /// Mirror of `FriendRecipeDetailView.writeImportAuditRow` for the
    /// link/file share path. Same fire-and-forget semantics —
    /// `RecipeImport` powers the "Saved by N" chip on the chain
    /// root's Detail view and the "Saved By N Cooks" line on their
    /// friend card; a network blip during this write under-counts
    /// by one event (acceptable, the surfaces are delight, not
    /// billing). Three skip cases, all silent:
    ///
    /// 1. **Signed-out / no iCloud** (`cachedRecordID()` nil). Same
    ///    short-circuit every other social write uses.
    /// 2. **Legacy envelope** (`originalCreatorID` nil — sender on a
    ///    pre-chain-attribution build). Skipped rather than guessing,
    ///    so we never credit the wrong account.
    /// 3. **Self-import** (importer == chain root). Saving your own
    ///    recipe back into your own cookbook via your own permalink
    ///    shouldn't inflate your own count.
    private func writeImportAuditRow(forEnvelope envelope: LCRecipeShareV1) {
        guard let importerID = UserProfileMirror.cachedRecordID() else { return }
        guard let originalCreatorID = envelope.share.originalCreatorID,
              let originalRecipeID  = envelope.share.originalRecipeID
        else { return }
        guard importerID != originalCreatorID else { return }
        let importerDisplayName = userAccount.status.identity?.displayName ?? "Cook"
        // Link/file shares carry no chain-hop info beyond the chain
        // root — the recipient doesn't know who the immediate sender
        // was as a CK user record name (only `sharedBy` display name).
        // Pin `sourceUserID` to the chain root so the field stays
        // populated; the friend-cookbook flow uses the actual
        // immediate-friend id, which is more precise but unavailable
        // here.
        let sourceUserID = originalCreatorID
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
}
