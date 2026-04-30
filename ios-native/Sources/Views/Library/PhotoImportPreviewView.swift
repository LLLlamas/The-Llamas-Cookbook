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
    var onSaved: (Recipe) -> Void = { _ in }
    /// Called when the user taps **Edit** instead of Save. Hands the
    /// parsed draft back to the parent so it can dismiss both this
    /// preview and the photo-import sheet, then open the regular
    /// `RecipeEditorView` with the draft pre-filled. The user fixes
    /// any OCR typos in the editor and saves there. Defaults to a
    /// no-op for previews / future call sites that want a read-only
    /// preview without the inline-edit shortcut.
    var onEdit: (DraftRecipe) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance

    @State private var isSaving = false
    @State private var showingDuplicateAlert = false
    @State private var duplicateRenameText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
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
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(appearance.accentColor)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .principal) {
                    Text("Import From Photo")
                        .font(AppFont.eyebrow)
                        .foregroundStyle(AppColor.textTertiary)
                }
                // Two trailing buttons: Edit hands off to the regular
                // editor with the parsed draft pre-filled (one-tap fix
                // for OCR typos like "1 1/2" misread as "14 1/2");
                // Save commits the parse as-is. Group-form keeps
                // declared order (Edit left, Save right) on iOS.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Edit") {
                        Haptics.selection()
                        onEdit(draft)
                    }
                    .foregroundStyle(appearance.accentColor)
                    .disabled(isSaving)

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

    // MARK: helpers

    /// Recipe-level notes in canonical surface order. Trimmed +
    /// empty-filtered. Mirrors `RecipeImportPreviewView.collectedNotes`.
    private var collectedNotes: [String] {
        [draft.prefaceNote, draft.epilogueNote, draft.generalNote]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
    }

    /// Lightweight ingredient renderer. Same shape as
    /// `RecipeImportPreviewView.formatIngredient` but operates on
    /// `DraftIngredient` (plain Swift) instead of `ShareIngredient`
    /// (Codable). After Save the persisted `Ingredient` rows go
    /// through the canonical formatter as expected.
    private func formatIngredient(_ ing: DraftIngredient) -> String {
        let q = ing.quantity.trimmed
        let u = ing.unit.trimmed
        var measureParts: [String] = []
        if !q.isEmpty { measureParts.append(q) }
        if !u.isEmpty { measureParts.append(u) }
        let measure = measureParts.joined(separator: " ")
        return measure.isEmpty ? ing.name : "\(measure) — \(ing.name)"
    }

    // MARK: save

    private func saveToLibrary() {
        guard !isSaving else { return }
        let baseTitle = draft.title.trimmed
        guard !baseTitle.isEmpty else { return }
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
    /// user's edited name).
    private func performSave(withOverrideTitle overrideTitle: String?) {
        guard !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            var final = draft
            if let overrideTitle, !overrideTitle.isEmpty {
                final.title = overrideTitle
            } else {
                final.title = draft.title.trimmed
            }
            let recipe = Recipe.new(from: final)
            modelContext.insert(recipe)
            try? modelContext.save()

            isSaving = false
            Haptics.success()
            onSaved(recipe)
            dismiss()
        }
    }
}
