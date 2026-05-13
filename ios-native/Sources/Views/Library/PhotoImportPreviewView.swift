import SwiftUI
import SwiftData

/// Read-only preview of an OCR'd `DraftRecipe`. Modeled directly on
/// `RecipeImportPreviewView` (the cloud-share recipient screen) so
/// users get the same accept-or-cancel metaphor regardless of where
/// the recipe came from. The single architectural difference: this
/// view consumes a plain `DraftRecipe` instead of an
/// `LCRecipeShareV1` envelope — no sender provenance, no base64 photo
/// payload, no `RecipeShare.materialize` plumbing. Save persists a
/// fresh `Recipe` via the existing `Recipe.new(from: draft)`
/// initializer.
///
/// Toolbar mirrors the share-recipient screen exactly: principal
/// title set to "Import From Photo", Cancel left, Save right. Save
/// surfaces the same duplicate-title rename alert pattern (and reuses
/// the same `RecipeShare.libraryContainsRecipe` /
/// `RecipeShare.resolveImportTitle` helpers since they're not
/// share-specific — both are SwiftData fetch-by-title probes).
struct PhotoImportPreviewView: View {
    let draft: DraftRecipe
    /// True when the Worker served this parse result from its KV cache.
    /// Combined with `sessionAttemptIndex` to decide whether to show the
    /// "same photo as before" hint above the title block.
    var cacheHit: Bool = false
    /// 1-indexed count of how many vision attempts the user has made in
    /// this ImportFromPhotoView session. The cache-hit hint only shows
    /// when this is ≥ 2 (the user has already seen this result; they need
    /// to know it's cached).
    var sessionAttemptIndex: Int = 1

    var onSaved: (Recipe) -> Void = { _ in }
    var onSavedForEdit: (Recipe) -> Void = { _ in }

    @Environment(\.modelContext)     private var modelContext
    @Environment(\.dismiss)          private var dismiss
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(QuotaService.self)  private var quotaService

    @State private var isSaving              = false
    @State private var showingDuplicateAlert = false
    @State private var duplicateRenameText   = ""
    @State private var showRaceBanner        = false
    @State private var pendingMode: SaveMode = .save

    private enum SaveMode { case save, saveForEdit }

    private var showCacheHint: Bool { cacheHit && sessionAttemptIndex >= 2 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    if showCacheHint {
                        cacheHintBanner
                    }
                    if showRaceBanner {
                        raceBanner
                    }
                    titleBlock
                    metaLine
                    if !draft.summary.trimmed.isEmpty {
                        Text(draft.summary)
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    if !draft.tags.isEmpty {
                        FlowRow(spacing: AppSpacing.xs) {
                            ForEach(draft.tags.sorted(), id: \.self) { tag in
                                tagChip(tag)
                            }
                        }
                    }
                    ingredientsSection
                    stepsSection
                    notesSection
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
                    Text("Import From Photo")
                        .font(AppFont.eyebrow)
                        .foregroundStyle(AppColor.textTertiary)
                }
                // Two trailing buttons share the same persist path —
                // both run through `saveToLibrary` so the parent's
                // post-save choreography (Library scroll + letter
                // magnify + Detail push) plays for either tap. The
                // only difference is `pendingMode`: Save lands the
                // user on Detail (read-mode), Edit pushes Detail
                // and then opens the Editor on top so the user can
                // fix OCR typos directly. Group-form keeps declared
                // order (Edit left, Save right) on iOS.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Edit") {
                        Haptics.selection()
                        saveToLibrary(mode: .saveForEdit)
                    }
                    .foregroundStyle(appearance.accentColor)
                    .disabled(isSaving)

                    Button {
                        saveToLibrary(mode: .save)
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
        .alert(
            "Recipe already saved",
            isPresented: $showingDuplicateAlert
        ) {
            TextField("Recipe name", text: $duplicateRenameText)
                .textInputAutocapitalization(.words)
            Button("Save") {
                let trimmed = duplicateRenameText.trimmed
                guard !trimmed.isEmpty else { return }
                performSave(withOverrideTitle: trimmed)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You already have a recipe titled \"\(draft.title.trimmed)\". Save this one with a different name?")
        }
    }

    // MARK: subsections

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(StringCase.titleCase(draft.title.trimmed))
                .font(AppFont.recipeTitle)
                .foregroundStyle(appearance.accentColor)
                .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        let parts: [String] = {
            var bits: [String] = []
            let s = draft.servings.trimmed
            if !s.isEmpty { bits.append("Serves \(s)") }
            let c = draft.cookTimeMinutes.trimmed
            if !c.isEmpty { bits.append("Cook \(c) min") }
            let p = draft.prepTimeMinutes.trimmed
            if !p.isEmpty { bits.append("Prep \(p) min") }
            return bits
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
        }
    }

    @ViewBuilder
    private var ingredientsSection: some View {
        if !draft.ingredients.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                sectionHeading("Ingredients")
                ForEach(draft.ingredients) { ing in
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
        if !draft.steps.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                sectionHeading("Steps")
                ForEach(Array(draft.steps.enumerated()), id: \.offset) { (idx, step) in
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
                        if let note = step.specialNote?.trimmed, !note.isEmpty {
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

    // MARK: banners

    private var cacheHintBanner: some View {
        HStack(spacing: AppSpacing.sm) {
            LlamaLogo(size: 28, shadowColor: appearance.accentColor)
            Text("Same photo as before — same result. Try a clearer or differently-angled photo for a fresh parse.")
                .font(.system(size: 13))
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.accentColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(appearance.accentColor.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var raceBanner: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(appearance.accentColor)
            Text("This one's on us — you're already at your monthly limit. Recipe saved!")
                .font(.system(size: 13))
                .foregroundStyle(AppColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.accentColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(appearance.accentColor.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: helpers

    /// Recipe-level notes in canonical surface order. Trimmed +
    /// empty-filtered. Mirrors `RecipeImportPreviewView.collectedNotes`.
    private var collectedNotes: [String] {
        [draft.prefaceNote, draft.epilogueNote, draft.generalNote]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
    }

    /// Lightweight ingredient renderer for draft rows. Reuses the same
    /// quantity/plural helpers as persisted ingredients without needing
    /// a temporary SwiftData object just to render the preview.
    private func formatIngredient(_ ing: DraftIngredient) -> String {
        let q = Quantity.displayFormat(ing.quantity.trimmed)
        let u = Plural.unit(ing.unit.trimmed, for: ing.quantity.trimmed)
        var measureParts: [String] = []
        if !q.isEmpty { measureParts.append(q) }
        if !u.isEmpty { measureParts.append(u) }
        let measure = measureParts.joined(separator: " ")
        return measure.isEmpty ? ing.name : "\(measure) — \(ing.name)"
    }

    // MARK: save

    private func saveToLibrary(mode: SaveMode) {
        guard !isSaving else { return }
        let baseTitle = draft.title.trimmed
        guard !baseTitle.isEmpty else { return }
        pendingMode = mode
        // Reuse the share-side helpers — both are simple SwiftData
        // fetch-by-title probes, not share-specific.
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
    /// (`overrideTitle: nil` keeps the OCR'd title) and the
    /// duplicate-confirmation path (`overrideTitle` carries the
    /// user's edited name). Routes the saved recipe to the right
    /// callback based on `pendingMode`.
    private func performSave(withOverrideTitle overrideTitle: String?) {
        guard !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            var final = draft
            if let overrideTitle, !overrideTitle.isEmpty {
                final.title = StringCase.titleCase(overrideTitle)
            } else {
                final.title = StringCase.titleCase(draft.title.trimmed)
            }
            let recipe = Recipe.new(from: final)
            modelContext.insert(recipe)
            try? modelContext.save()

            // Fire consume after the local save so the server counter
            // only ticks when the user actually kept the recipe.
            // This is fire-and-forget from the UX perspective; we show
            // a soft banner if the race-condition 402 comes back.
            Task {
                let result = await quotaService.consume()
                if case .race = result {
                    showRaceBanner = true
                }
            }

            let mode = pendingMode
            isSaving = false
            pendingMode = .save
            Haptics.success()
            switch mode {
            case .save:        onSaved(recipe)
            case .saveForEdit: onSavedForEdit(recipe)
            }
            dismiss()
        }
    }
}
