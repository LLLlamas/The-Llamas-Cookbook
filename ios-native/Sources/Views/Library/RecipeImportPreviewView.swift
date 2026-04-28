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

    let envelope: LCRecipeShareV1

    /// Decoded gallery photos. Computed in `onAppear` once so we don't
    /// re-base64-decode on every render. Step photos are surfaced as a
    /// count badge in the steps section rather than thumbnails — keeps
    /// the preview light, full step photos appear after Save.
    @State private var galleryPhotos: [Data] = []
    @State private var isSaving = false

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
            .background(AppColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
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
            }
        }
    }

    @ViewBuilder
    private var metaLine: some View {
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

    /// Renders "Originally shared by Lorenzo · Apr 27" when both
    /// fields are present; "Originally shared by Lorenzo" alone when
    /// only the name is set; nil when sharedBy is empty/nil (matches
    /// Recipe-Sharing.md §15 test #14 — empty-name share emits no
    /// provenance line).
    private var provenanceLine: String? {
        guard let by = envelope.share.sharedBy?.trimmingCharacters(in: .whitespacesAndNewlines),
              !by.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let dateString = formatter.string(from: envelope.share.createdAt)
        return "Originally shared by \(by) · \(dateString)"
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
        isSaving = true
        Task { @MainActor in
            _ = await RecipeShare.materialize(envelope, into: modelContext)
            isSaving = false
            Haptics.success()
            dismiss()
        }
    }
}
