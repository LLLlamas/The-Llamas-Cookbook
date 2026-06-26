import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct RecipeEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance

    /// nil when creating a new recipe; the target when editing.
    let recipe: Recipe?
    /// Optional override for the post-save dismissal. When the editor is pushed
    /// inside another sheet (e.g. the Import flow), the parent sets this to
    /// dismiss the *whole* sheet on Save instead of just popping the editor.
    /// The saved `Recipe` is passed back so callers that need to navigate
    /// after save (e.g. the photo-import "Edit then Save" hand-off pushing
    /// Detail via libraryPath.append) can do so without a second lookup.
    let onSaved: ((Recipe) -> Void)?

    @State private var draft: DraftRecipe
    @State private var showDiscardAlert = false
    /// Drives the "pick another title" alert when the title is rejected by
    /// the profanity screen.
    @State private var titleRejected = false
    @State private var editingStepId: UUID? = nil
    @State private var editingIngredientId: UUID? = nil
    @State private var draggingStepId: UUID? = nil
    @State private var showingPhotoCarousel = false
    @State private var showTour = false
    @FocusState private var isNumericFocused: Bool
    /// Drives the summary field's expand-on-focus behavior. When true
    /// the field grows to fit multi-line content (`axis: .vertical` +
    /// generous `lineLimit`); when false it collapses back to a single
    /// truncated line so the form stays compact at rest.
    @FocusState private var isSummaryFocused: Bool

    /// Tracks whether this editor instance was opened from a from-
    /// scratch entry vs. seeded from an import (text/link/photo) or
    /// an existing recipe. Used to gate the auto-tour: the user
    /// only sees the new-recipe walkthrough when they actually
    /// started a new-recipe flow.
    private let openedFromScratch: Bool

    @AppStorage("hasSeenNewRecipeTour") private var hasSeenNewRecipeTour = false
    @AppStorage("hasSeenImportHelp") private var hasSeenImportHelp = false

    init(recipe: Recipe?, initialDraft: DraftRecipe? = nil, onSaved: ((Recipe) -> Void)? = nil) {
        self.recipe = recipe
        self.onSaved = onSaved
        _draft = State(initialValue: initialDraft ?? recipe?.toDraft() ?? DraftRecipe())
        // No recipe AND no seed = "Write Down Your Recipe" entry
        // from the FAB. Imports / photo Edit-then-Save hand-offs
        // pass an `initialDraft` so they skip the tour.
        self.openedFromScratch = (recipe == nil && initialDraft == nil)
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            Haptics.selection()
                            attemptCancel()
                        } label: {
                            Text("Cancel")
                                .foregroundStyle(appearance.accentColor)
                                .accentTextOutline()
                        }
                    }
                    // Help icon — only shown when creating a new recipe.
                    // Editing an existing recipe doesn't surface the
                    // tour; the user already knows the layout, and the
                    // icon would also crowd the Save pill on narrow
                    // phones.
                    if openedFromScratch {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                Haptics.selection()
                                showTour = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(appearance.accentColor)
                            }
                            .accessibilityLabel("Replay walkthrough")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            save()
                        } label: {
                            Text("Save")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppColor.onAccent)
                                .padding(.horizontal, AppSpacing.md)
                                .padding(.vertical, 6)
                                .background(appearance.accentColor)
                                .clipShape(Capsule())
                                .opacity(draft.canSave ? 1 : 0.4)
                        }
                        .disabled(!draft.canSave)
                        .tourTarget(.saveButton)
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        if isNumericFocused {
                            Spacer()
                            Button {
                                Haptics.selection()
                                isNumericFocused = false
                            } label: {
                                Text("Done")
                                    .foregroundStyle(appearance.accentColor)
                                    .font(.system(size: 16, weight: .semibold))
                                    .accentTextOutline()
                            }
                        }
                    }
                }
                .alert("Discard changes?", isPresented: $showDiscardAlert) {
                    Button("Keep editing", role: .cancel) { }
                    Button("Discard", role: .destructive) { dismiss() }
                } message: {
                    Text("Your edits will be lost.")
                }
                .alert("Pick another title", isPresented: $titleRejected) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(ContentModeration.blockedMessage)
                }
                .fullScreenCover(isPresented: $showingPhotoCarousel) {
                    PhotoCarouselView(
                        photoData: draft.photos.compactMap(\.image),
                        title: draft.title,
                        // Parallel captions array. Filtering by image
                        // presence keeps captions aligned with the
                        // displayed photoData — in practice no
                        // DraftPhoto reaches this state with a nil
                        // image (apply() filters them), but the
                        // explicit pairing avoids index drift.
                        captions: draft.photos.compactMap { $0.image == nil ? nil : $0.caption },
                        onAdd: { rawDataArray in
                            await addPhotos(from: rawDataArray)
                        },
                        onDelete: { index in
                            deletePhoto(at: index)
                        },
                        onSetCaption: { index, newCaption in
                            setPhotoCaption(at: index, to: newCaption)
                        },
                        onReorder: { indices, destination in
                            reorderPhotos(fromOffsets: indices, toOffset: destination)
                        }
                    )
                }
                .onAppear {
                    syncDirty()
                    // Legacy `hasSeenImportHelp` users have already
                    // seen the static text/link help once — treat
                    // them as having seen the editor walkthrough too
                    // so the auto-tour doesn't fire on update.
                    if hasSeenImportHelp && !hasSeenNewRecipeTour {
                        hasSeenNewRecipeTour = true
                    }
                    if openedFromScratch && !hasSeenNewRecipeTour {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(500))
                            showTour = true
                        }
                    }
                }
                .onChange(of: draft) { _, _ in syncDirty() }
                .onDisappear { editor.hasUnsavedChanges = false }
                .overlayPreferenceValue(LlamaTourTargetKey.self) { anchors in
                    if showTour {
                        LlamaIntroOverlay(
                            steps: NewRecipeTour.steps,
                            anchors: anchors,
                            scrollProxy: proxy,
                            ingredientAdded: !draft.ingredients.isEmpty,
                            onFinish: {
                                showTour = false
                                hasSeenNewRecipeTour = true
                            }
                        )
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: showTour)
                    }
                }
        }
        .llamaBackground()
        .navigationTitle(headerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .tint(appearance.accentColor)
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                heroRow.tourTarget(.editorHero)
                titleBlock.tourTarget(.titleField)
                summaryField.tourTarget(.summaryField)

                servingsField.tourTarget(.servingsField)
                prepTimeField.tourTarget(.prepTimeField)

                photosButton.tourTarget(.photosButton)

                // Tour highlight wraps the header AND the tag input
                // so the "Tag It" walkthrough cutout extends down to
                // the custom-category text box rather than just the
                // section title above it.
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    categoriesHeader
                    TagInputView(tags: $draft.tags)
                }
                .tourTarget(.categoriesHeader)

                sectionHeader("Ingredients")
                sectionHint("Only the ingredient name is required. Leave quantity and unit blank if they don't have any in particular.")
                IngredientQuickAdd(numericFocus: $isNumericFocused) { draft.ingredients.append($0) }
                    .tourTarget(.ingredientQuickAdd)
                if !draft.ingredients.isEmpty {
                    VStack(spacing: 3) {
                        ForEach($draft.ingredients) { $ingredient in
                            let ingId = ingredient.id
                            IngredientRowEditor(
                                ingredient: $ingredient,
                                isEditing: Binding(
                                    get: { editingIngredientId == ingId },
                                    set: { newValue in
                                        editingIngredientId = newValue ? ingId : nil
                                    }
                                ),
                                numericFocus: $isNumericFocused
                            ) {
                                draft.ingredients.removeAll { $0.id == ingId }
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                        }
                    }
                    .tourTarget(.firstIngredientRow)
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: draft.ingredients.count)
                }

                sectionHeader("Steps")
                sectionHint("List the steps in order, and tap the timer icon if you need to use it for that step. Long press and drag to reorder if you need!")
                StepQuickAdd(nextNumber: draft.steps.count + 1) {
                    draft.steps.append($0)
                }
                .tourTarget(.stepQuickAdd)
                if !draft.steps.isEmpty {
                    VStack(spacing: AppSpacing.xs) {
                        ForEach($draft.steps) { $step in
                            let stepId = step.id
                            StepRowEditor(
                                index: draft.steps.firstIndex(where: { $0.id == stepId }) ?? 0,
                                step: $step,
                                isEditing: Binding(
                                    get: { editingStepId == stepId },
                                    set: { newValue in
                                        // No animation — the user wants the
                                        // pill to instantly switch state, not
                                        // spring between view and edit.
                                        editingStepId = newValue ? stepId : nil
                                    }
                                )
                            ) {
                                draft.steps.removeAll { $0.id == stepId }
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                            .onDrag {
                                // Starting a drag should pull every step out
                                // of edit mode so the keyboard gets out of
                                // the way and rows can slide around cleanly.
                                editingStepId = nil
                                draggingStepId = stepId
                                return NSItemProvider(object: stepId.uuidString as NSString)
                            } preview: {
                                stepDragPreview(for: step)
                            }
                            .onDrop(of: [.text], delegate: StepDropDelegate(
                                targetId: stepId,
                                draft: $draft,
                                draggingId: $draggingStepId
                            ))
                        }
                    }
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: draft.steps.count)
                }

                SpecialNotesEditor(
                    steps: $draft.steps,
                    prefaceNote: $draft.prefaceNote,
                    epilogueNote: $draft.epilogueNote,
                    generalNote: $draft.generalNote
                )
                .tourTarget(.specialNotesEditor)

                sectionHeader("Reference Link")
                sectionHint("Optional. Paste a URL if you adapted this from somewhere online.")
                TextField(
                    "",
                    text: $draft.sourceUrl,
                    // `prompt:` lets us style the placeholder directly —
                    // necessary here because the URL keyboard + URL-shaped
                    // placeholder otherwise renders link-styled blue.
                    prompt: Text("https://example.com/recipe")
                        .foregroundStyle(AppColor.textTertiary)
                )
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(AppColor.divider, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
            }
            .padding(AppSpacing.lg)
            // Generous bottom runway so iOS's keyboard auto-scroll can
            // settle the focused field high in the visible area instead
            // of crammed against the keyboard's top edge — the user can
            // see what they're typing with breathing room below.
            .padding(.bottom, 320)
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
                editingStepId = nil
                editingIngredientId = nil
            }
        }
    }

    /// Keep EditorCoordinator's dirty flag in sync with the live draft.
    /// The coordinator uses it to gate switch-to-a-different-sheet
    /// attempts behind the discard alert at RootView.
    private func syncDirty() {
        if let existing = recipe {
            editor.hasUnsavedChanges = (existing.toDraft() != draft)
        } else {
            editor.hasUnsavedChanges = draft.hasAnyContent
        }
    }

    // MARK: - Header

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaLogo(size: 72, shadowColor: appearance.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe == nil ? "New Recipe" : "Edit Recipe")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(appearance.accentColor)
                    .accentTextOutline()
                Text("What are we cookin'?")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                Text("RECIPE NAME")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(appearance.accentColor)
                Text("REQUIRED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(appearance.accentColor)
            }
            TextField("", text: $draft.title)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .lineLimit(1)
                .padding(AppSpacing.md)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(appearance.accentColor, lineWidth: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                // Step the title font down as the title gets longer so
                // the whole name stays inside the input — scrolling /
                // ellipsizing while typing your own recipe name reads
                // as a UI bug, not a feature. SwiftUI TextField ignores
                // `minimumScaleFactor` for entered text, so the choice
                // has to be driven off character count.
                .font(Self.titleFont(forLength: draft.title.count))
                .animation(.easeInOut(duration: 0.15), value: draft.title.count)
                .foregroundStyle(appearance.accentColor)
                .tint(appearance.accentColor)
        }
    }

    /// Serif title font that shrinks with length so a 50-character
    /// recipe name still fits the box on iPhone widths. Caps at 14pt
    /// because below that the title becomes hard to read; titles
    /// longer than ~60 chars will still get scaled by SwiftUI's text
    /// scrolling but at that point the user has bigger problems.
    private static func titleFont(forLength length: Int) -> Font {
        let size: CGFloat
        switch length {
        case ..<20:  size = 28
        case ..<28:  size = 24
        case ..<36:  size = 20
        case ..<46:  size = 17
        default:     size = 14
        }
        return .system(size: size, weight: .bold, design: .serif)
    }

    private var summaryField: some View {
        // `axis: .vertical` lets the field wrap to multiple lines while
        // editing; the lineLimit toggle off `isSummaryFocused` keeps it
        // a single truncated row at rest, so the form stays compact
        // until the user puts the cursor in the description and needs
        // to see what they're typing.
        TextField(
            "Short description (optional)",
            text: $draft.summary,
            axis: .vertical
        )
            .focused($isSummaryFocused)
            .lineLimit(isSummaryFocused ? 10 : 1, reservesSpace: false)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .frame(minHeight: 40, alignment: .topLeading)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(
                        isSummaryFocused ? appearance.accentColor : AppColor.divider,
                        lineWidth: isSummaryFocused ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .font(AppFont.body)
            .foregroundStyle(AppColor.textPrimary)
            .animation(.easeInOut(duration: 0.2), value: isSummaryFocused)
    }

    /// Compact servings input that lives right under the summary so the
    /// scaling control is visible without scrolling. Numeric keyboard,
    /// constrained width — the rest of the row is intentionally empty so
    /// it doesn't compete with the more important Categories block below.
    private var servingsField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Servings")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                TextField("4", text: $draft.servings)
                    .keyboardType(.numberPad)
                    .focused($isNumericFocused)
                    .padding(.horizontal, AppSpacing.sm + 2)
                    .padding(.vertical, AppSpacing.xs + 2)
                    .frame(maxWidth: 90, minHeight: 36)
                    .background(AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .stroke(AppColor.divider, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                Text("Set servings so you can scale ingredients while cooking.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Prep time in minutes — sits directly below servings so the two
    /// quantitative cooking inputs share a vertical column. Same shape
    /// as `servingsField` (label + numeric pad input + caption hint) so
    /// the user reads it as a sibling control. Detail surfaces it next
    /// to the servings line under the photo strip.
    private var prepTimeField: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Prep time (minutes)")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                TextField("15", text: $draft.prepTimeMinutes)
                    .keyboardType(.numberPad)
                    .focused($isNumericFocused)
                    .padding(.horizontal, AppSpacing.sm + 2)
                    .padding(.vertical, AppSpacing.xs + 2)
                    .frame(maxWidth: 90, minHeight: 36)
                    .background(AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.sm)
                            .stroke(AppColor.divider, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                Text("How long the prep work takes before cooking starts.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Categories section header with an inline nudge pointing users at
    /// the Sourdough tag — adding it is what unlocks the sourdough
    /// calculator chip in Detail view, so the hint lives next to the
    /// label that controls it.
    private var categoriesHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs + 2) {
            Text("Categories")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.textPrimary)
            Text("-- add the Sourdough tag if you need the calculator!")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, AppSpacing.md)
    }

    /// Photos entry-point. Same vertical position as in Detail (below
    /// the times/servings row, above Categories) so the user finds the
    /// gallery in the same place whether they're editing or browsing.
    /// Count is only shown when there's something to count — the empty
    /// label reads "Add photos" so the affordance is its own call to
    /// action rather than just a label.
    private var photosButton: some View {
        Button {
            Haptics.selection()
            showingPhotoCarousel = true
        } label: {
            HStack(spacing: AppSpacing.sm + 2) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(appearance.accentColor)
                    .frame(width: 24)
                Text(photoButtonLabel)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.textTertiary)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(draft.photos.isEmpty
            ? "Add photos"
            : "Photos, \(draft.photos.count)"
        )
    }

    private var photoButtonLabel: String {
        let count = draft.photos.count
        if count == 0 { return "Add Photos" }
        return "Photos (\(count))"
    }

    /// Process newly-picked photo bytes through `ImageProcessing` and
    /// append `DraftPhoto`s. Bytes that fail to encode are silently
    /// dropped (the user just won't see that pick in the gallery —
    /// safer than persisting unreadable data).
    private func addPhotos(from rawDataArray: [Data]) async {
        var newPhotos: [DraftPhoto] = []
        for raw in rawDataArray {
            if let processed = await ImageProcessing.prepare(raw, for: .gallery) {
                newPhotos.append(DraftPhoto(image: processed))
            }
        }
        await MainActor.run {
            draft.photos.append(contentsOf: newPhotos)
        }
    }

    private func deletePhoto(at index: Int) {
        // `index` comes from the carousel, which sees only photos
        // whose `image != nil`. Map back to the underlying `draft.photos`
        // array so deletion targets the same photo the user saw.
        let displayIndices = draft.photos.indices.filter { draft.photos[$0].image != nil }
        guard displayIndices.indices.contains(index) else { return }
        draft.photos.remove(at: displayIndices[index])
    }

    /// Set the caption on the displayable-photo at `index`. Trims +
    /// nil-empties so an empty TextField doesn't persist as
    /// `caption: ""` (which would render as an empty caption row in
    /// Detail next time).
    private func setPhotoCaption(at index: Int, to newCaption: String?) {
        let displayIndices = draft.photos.indices.filter { draft.photos[$0].image != nil }
        guard displayIndices.indices.contains(index) else { return }
        let trimmed = newCaption?.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.photos[displayIndices[index]].caption = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Apply a SwiftUI `.move(fromOffsets:toOffset:)` against the
    /// displayable subset of `draft.photos`, then reseat each shuffled
    /// row back at its original index in the underlying array. Photos
    /// without image bytes (rare) keep their slots so they don't get
    /// reshuffled around the user's intent.
    private func reorderPhotos(fromOffsets: IndexSet, toOffset: Int) {
        let displayIndices = draft.photos.indices.filter { draft.photos[$0].image != nil }
        var displayables = displayIndices.map { draft.photos[$0] }
        displayables.move(fromOffsets: fromOffsets, toOffset: toOffset)
        var newPhotos = draft.photos
        for (offset, draftIdx) in displayIndices.enumerated() {
            newPhotos[draftIdx] = displayables[offset]
        }
        draft.photos = newPhotos
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.sectionHeading)
            .foregroundStyle(AppColor.textPrimary)
            .padding(.top, AppSpacing.md)
    }

    private func sectionHint(_ hint: String) -> some View {
        Text(hint)
            .font(AppFont.caption)
            .foregroundStyle(AppColor.textSecondary)
            .padding(.bottom, AppSpacing.xs)
    }

    // MARK: - Actions

    private var headerTitle: String {
        let trimmed = draft.title.trimmed
        if !trimmed.isEmpty { return StringCase.titleCase(trimmed) }
        return recipe == nil ? "New Recipe" : "Edit Recipe"
    }

    private func attemptCancel() {
        if draft.hasAnyContent && recipe == nil {
            showDiscardAlert = true
        } else if let existing = recipe, existing.toDraft() != draft {
            showDiscardAlert = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard draft.canSave else { return }
        guard ContentModeration.isClean(draft.title) else {
            Haptics.warning()
            titleRejected = true
            return
        }
        Haptics.recipeSaved()
        let savedRecipe: Recipe
        if let existing = recipe {
            existing.apply(draft)
            savedRecipe = existing
        } else {
            let newRecipe = Recipe.new(from: draft)
            modelContext.insert(newRecipe)
            savedRecipe = newRecipe
        }
        // Force-flush to disk before dismissing the sheet. SwiftData's
        // auto-save is best-effort and runs asynchronously around app
        // lifecycle events; if the user immediately backgrounds or
        // kills the app after Save, an unsaved insert can be lost.
        // try? swallows the error path — if save fails (rare), the
        // user's changes still live in the in-memory context until
        // the next auto-save attempt. Without this, we saw recipes
        // appear in the @Query briefly then vanish on relaunch.
        try? modelContext.save()
        // Mirror to CloudKit's PublishedRecipe so friends see the
        // updated version. Debounced 5s inside the service — a Save
        // burst (typo correction → re-save) collapses to one upload.
        // Chain attribution (sharedBy / originalCreatorID /
        // originalRecipeID for the published record) is derived
        // from the recipe's `originalCreator*` fields inside the
        // service. Best-effort: silently no-ops when iCloud is
        // unavailable.
        LibraryMirrorService.shared.enqueueUpsert(savedRecipe)
        if let onSaved {
            onSaved(savedRecipe)
        } else {
            dismiss()
        }
    }

    // MARK: - Step reordering

    @ViewBuilder
    private func stepDragPreview(for step: DraftStep) -> some View {
        let indexLabel = (draft.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(appearance.accentColor)
            Text("\(indexLabel). \(step.text.isEmpty ? "Step" : step.text)")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(appearance.accentColor, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .shadow(color: AppColor.shadow, radius: 12, x: 0, y: 4)
    }

}

/// Drop delegate that reports `.move` semantics to iOS — which suppresses the
/// green "+" copy indicator on the drag preview. `.dropDestination(for:)`
/// always defaults to `.copy`, so we drop back to `onDrop(delegate:)` here.
private struct StepDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var draft: DraftRecipe
    @Binding var draggingId: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingId = nil }
        guard let fromId = draggingId,
              fromId != targetId,
              let fromIdx = draft.steps.firstIndex(where: { $0.id == fromId }),
              let toIdx = draft.steps.firstIndex(where: { $0.id == targetId })
        else { return false }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            let moved = draft.steps.remove(at: fromIdx)
            draft.steps.insert(moved, at: toIdx)
        }
        Haptics.impact(.medium)
        return true
    }
}

