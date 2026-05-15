import SwiftUI
import SwiftData

/// Read-only preview of an imported `DraftRecipe`. Operates in two modes:
///
/// 1. **Final-draft mode** (`streamingState == nil`): renders the full draft
///    immediately. Used by the local-accept path and the OCR + text-AI
///    fallback path — anywhere the draft is fully formed before the preview
///    opens.
///
/// 2. **Streaming mode** (`streamingState != nil`): the preview opens
///    immediately when the Sonnet path begins (blank content). A
///    "Asking the llama…" overlay covers the blank view during TTFB; it
///    dismisses the instant the title token arrives and the title's
///    insertion transition plays. Content ticks in progressively from there.
///    Save is disabled until `streamingState.status == .completed`, at which
///    point `streamingState.finalDraft` becomes the canonical draft to persist.
///
/// Toolbar mirrors the share-recipient screen exactly: principal title set
/// to "Import From Photo", Cancel left, Edit + Save right. Save surfaces
/// the same duplicate-title rename alert pattern as cloud share.
struct PhotoImportPreviewView: View {
    let draft: DraftRecipe
    /// Non-nil when this preview is bound to a live Sonnet stream. The
    /// view reads title / ingredients / steps from this state while
    /// `status == .streaming` and from `finalDraft` (or `draft`) after
    /// completion. See `effectiveDraft`.
    var streamingState: StreamingRecipeState? = nil
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
    @State private var titleHapticFired      = false

    private enum SaveMode { case save, saveForEdit }

    // MARK: - Streaming-aware view model

    /// True while we're still receiving streamed content. Drives the
    /// shimmer placeholders + Save-disabled state.
    private var isStreaming: Bool {
        guard let s = streamingState else { return false }
        switch s.status {
        case .waitingForFirstByte, .streaming: return true
        case .completed, .cancelled, .failed:  return false
        }
    }

    /// True when streaming has produced a usable final draft. Used to
    /// flip the view from "live state" to the canonical post-stream
    /// draft (which has gone through the full `ParsedAPIRecipe.toDraft`
    /// post-processing including step splitting, plural normalization,
    /// orphan-duration merge).
    private var streamFinalDraftReady: Bool {
        streamingState?.status == .completed && streamingState?.finalDraft != nil
    }

    /// The draft to render. Streaming live state during the stream;
    /// `streamingState.finalDraft` (post-processed) after completion;
    /// `draft` when there's no streaming state at all.
    private var effectiveDraft: DraftRecipe {
        if streamFinalDraftReady, let final = streamingState?.finalDraft {
            return final
        }
        if let s = streamingState, isStreaming {
            return s.snapshotDraft()
        }
        return draft
    }

    private var showCacheHint: Bool {
        // cacheHit on the payload is always false (created before we know);
        // read the resolved value from streamingState once completeStream fires.
        let hit = streamingState?.cacheHit ?? cacheHit
        return hit && sessionAttemptIndex >= 2
    }

    /// True while we're waiting for the first title token from Sonnet.
    /// Drives the "Asking the llama…" overlay that covers the blank preview.
    private var showProcessingOverlay: Bool {
        guard let s = streamingState else { return false }
        guard s.title.isEmpty else { return false }
        switch s.status {
        case .cancelled, .failed, .completed: return false
        default: return true
        }
    }

    private var canSave: Bool {
        guard !isSaving else { return false }
        guard !isStreaming else { return false }
        return !effectiveDraft.title.trimmed.isEmpty
    }

    // MARK: - Body

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
                    summaryBlock
                    tagsBlock
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
            .toolbar { toolbarContent }
        }
        .interactiveDismissDisabled(isSaving || isStreaming)
        // "Asking the llama…" overlay — shown while Sonnet TTFB is in progress
        // (title not yet extracted). Fades out the instant the title token
        // arrives, then the title's insertion transition plays immediately.
        .overlay {
            if showProcessingOverlay {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    llamaProcessingCard
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showProcessingOverlay)
        // Haptic when the title first lands. onAppear catches the case where
        // the title is already present when the view opens (onFirstContent
        // fires after state.title is set, so the view may open pre-populated).
        .onAppear {
            if let s = streamingState, !s.title.isEmpty, !titleHapticFired {
                titleHapticFired = true
                Haptics.impact(.soft)
            }
        }
        .onChange(of: streamingState?.title ?? "") { _, newValue in
            if !newValue.isEmpty && !titleHapticFired {
                titleHapticFired = true
                Haptics.impact(.soft)
            }
        }
        // Animate content arrival. Driven by count/empty changes so each new
        // row triggers its insertion transition as events land from the stream.
        .animation(.spring(response: 0.4, dampingFraction: 0.75),
                   value: effectiveDraft.ingredients.count)
        .animation(.spring(response: 0.5, dampingFraction: 0.8),
                   value: effectiveDraft.steps.count)
        .animation(.easeOut(duration: 0.4),
                   value: effectiveDraft.title.trimmed.isEmpty)
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
            Text("You already have a recipe titled \"\(effectiveDraft.title.trimmed)\". Save this one with a different name?")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
        // Two trailing buttons share the same persist path — both route
        // through `saveToLibrary` so the parent's post-save choreography
        // plays for either tap. `pendingMode` differs: Save lands on
        // Detail (read-mode), Edit pushes Detail then opens the Editor.
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Edit") {
                Haptics.selection()
                saveToLibrary(mode: .saveForEdit)
            }
            .foregroundStyle(canSave ? appearance.accentColor : AppColor.textTertiary)
            .disabled(!canSave)

            Button {
                saveToLibrary(mode: .save)
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("Save")
                        .fontWeight(.semibold)
                        .foregroundStyle(canSave ? appearance.accentColor : AppColor.textTertiary)
                }
            }
            .disabled(!canSave)
        }
    }

    // MARK: - Title

    @ViewBuilder
    private var titleBlock: some View {
        let title = effectiveDraft.title.trimmed
        if !title.isEmpty {
            Text(StringCase.titleCase(title))
                .font(AppFont.recipeTitle)
                .foregroundStyle(appearance.accentColor)
                .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .leading)),
                    removal:   .opacity
                ))
                .id("title-\(title.hashValue)")
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        let parts: [String] = {
            var bits: [String] = []
            let s = effectiveDraft.servings.trimmed
            if !s.isEmpty { bits.append("Serves \(s)") }
            let c = effectiveDraft.cookTimeMinutes.trimmed
            if !c.isEmpty { bits.append("Cook \(c) min") }
            let p = effectiveDraft.prepTimeMinutes.trimmed
            if !p.isEmpty { bits.append("Prep \(p) min") }
            return bits
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var summaryBlock: some View {
        let summary = effectiveDraft.summary.trimmed
        if !summary.isEmpty {
            Text(summary)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var tagsBlock: some View {
        if !effectiveDraft.tags.isEmpty {
            FlowRow(spacing: AppSpacing.xs) {
                ForEach(effectiveDraft.tags.sorted(), id: \.self) { tag in
                    tagChip(tag)
                }
            }
        }
    }

    // MARK: - Ingredients

    @ViewBuilder
    private var ingredientsSection: some View {
        if !effectiveDraft.ingredients.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                sectionHeading("Ingredients")
                ForEach(effectiveDraft.ingredients) { ing in
                    ingredientRow(ing)
                        .transition(.asymmetric(
                            insertion: .modifier(
                                active:   TickIn(offsetX: -20, opacity: 0),
                                identity: TickIn(offsetX: 0,   opacity: 1)
                            ),
                            removal: .opacity
                        ))
                }
            }
        }
    }

    private func ingredientRow(_ ing: DraftIngredient) -> some View {
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

    // MARK: - Steps

    @ViewBuilder
    private var stepsSection: some View {
        if !effectiveDraft.steps.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                sectionHeading("Steps")
                ForEach(Array(effectiveDraft.steps.enumerated()), id: \.element.id) { (idx, step) in
                    stepRow(idx: idx, step: step)
                        .transition(.asymmetric(
                            insertion: .modifier(
                                active:   TickIn(offsetY: 12, opacity: 0),
                                identity: TickIn(offsetY: 0,  opacity: 1)
                            ),
                            removal: .opacity
                        ))
                }
            }
        }
    }

    private func stepRow(idx: Int, step: DraftStep) -> some View {
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
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Notes

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

    // MARK: - Banners

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

    private var llamaProcessingCard: some View {
        VStack(spacing: AppSpacing.md) {
            LlamaProgressIndicator(size: 96, accent: appearance.accentColor)
            Text("Asking the llama…")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
        }
        .padding(AppSpacing.xl)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: AppColor.shadow, radius: 18, y: 6)
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

    // MARK: - Helpers

    private var collectedNotes: [String] {
        [effectiveDraft.prefaceNote, effectiveDraft.epilogueNote, effectiveDraft.generalNote]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
    }

    private func formatIngredient(_ ing: DraftIngredient) -> String {
        let q = Quantity.displayFormat(ing.quantity.trimmed)
        let u = Plural.unit(ing.unit.trimmed, for: ing.quantity.trimmed)
        var measureParts: [String] = []
        if !q.isEmpty { measureParts.append(q) }
        if !u.isEmpty { measureParts.append(u) }
        let measure = measureParts.joined(separator: " ")
        return measure.isEmpty ? ing.name : "\(measure) — \(ing.name)"
    }

    // MARK: - Save

    private func saveToLibrary(mode: SaveMode) {
        guard !isSaving else { return }
        let baseTitle = effectiveDraft.title.trimmed
        guard !baseTitle.isEmpty else { return }
        pendingMode = mode
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

        private func performSave(withOverrideTitle overrideTitle: String?) {
        guard !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            var final = effectiveDraft
            if let overrideTitle, !overrideTitle.isEmpty {
                final.title = StringCase.titleCase(overrideTitle)
            } else {
                final.title = StringCase.titleCase(final.title.trimmed)
            }
            let recipe = Recipe.new(from: final)
            modelContext.insert(recipe)
            try? modelContext.save()

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
            // Do NOT call dismiss() here — the onSaved/onSavedForEdit closures
            // call dismiss() on ImportFromPhotoView, which tears down the entire
            // sheet hierarchy (including this fullScreenCover) in one animation.
            // Calling dismiss() here first would flash ImportFromPhotoView briefly.
        }
    }
}

// MARK: - Tick-in transition modifier

/// Offset + opacity modifier for the streaming insertion transition.
/// Spring-driven by the parent `.animation(.spring(...), value: count)`.
private struct TickIn: ViewModifier {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var opacity: Double  = 1
    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .offset(x: offsetX, y: offsetY)
    }
}

