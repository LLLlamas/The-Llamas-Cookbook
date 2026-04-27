import SwiftUI
import SwiftData
import UIKit

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(CookingSession.self) private var session
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(NavigationContext.self) private var navContext

    let recipe: Recipe

    @State private var showingDeleteAlert = false
    @State private var showingConversions = false
    @State private var showingAppearance = false
    @State private var showingSourdough = false
    @State private var showingPhotoCarousel = false
    /// Tapped step's photo array, wrapped so `.sheet(item:)` can drive
    /// the viewer. Nil = no viewer; non-nil = present the carousel
    /// with that step's photos in view-only mode.
    @State private var viewingStepImages: ViewingStepImages?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text(StringCase.titleCase(recipe.title))
                        .font(AppFont.recipeTitle)
                        .foregroundStyle(appearance.accentColor)
                        .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)

                    if let summary = recipe.summary, !summary.isEmpty {
                        Text(summary)
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                    }

                    if !timeParts.isEmpty {
                        Text(timeParts.joined(separator: "  ·  "))
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }

                    if !recipe.tags.isEmpty {
                        FlowRow(spacing: AppSpacing.xs) {
                            // Sort at display time so legacy recipes with
                            // unsorted tag arrays still render alphabetically.
                            // New recipes write a sorted array on save.
                            ForEach(recipe.tags.sorted(), id: \.self) { tag in
                                TagPill(label: StringCase.titleCase(tag))
                            }
                        }
                    }

                    photosButton

                    if !sortedIngredients.isEmpty {
                        section("Ingredients", accessory: { ingredientAccessories }) {
                            VStack(spacing: AppSpacing.sm) {
                                ForEach(sortedIngredients) { ingredient in
                                    ingredientRow(ingredient)
                                }
                            }
                        }
                    }

                    if !sortedSteps.isEmpty {
                        section("Steps") {
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                if let preface = trimmedNote(recipe.prefaceNote) {
                                    noteCallout(preface)
                                }
                                ForEach(Array(sortedSteps.enumerated()), id: \.element.id) { idx, step in
                                    StepDetailRow(idx: idx, step: step) { stepPhotos, stepCaptions in
                                        Haptics.selection()
                                        viewingStepImages = ViewingStepImages(
                                            images: stepPhotos,
                                            captions: stepCaptions
                                        )
                                    }
                                }
                                if let epilogue = trimmedNote(recipe.epilogueNote) {
                                    noteCallout(epilogue)
                                }
                            }
                        }
                    } else if hasOrphanStepNotes {
                        // Preface / epilogue still need a home if the recipe
                        // has no steps yet but the user attached one.
                        section("Notes") {
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                if let preface = trimmedNote(recipe.prefaceNote) {
                                    noteCallout(preface)
                                }
                                if let epilogue = trimmedNote(recipe.epilogueNote) {
                                    noteCallout(epilogue)
                                }
                            }
                        }
                    }

                    if let general = trimmedNote(recipe.generalNote) {
                        section("General") {
                            noteCallout(general)
                        }
                    }

                    if let url = recipe.sourceUrl, !url.isEmpty {
                        section("Reference") {
                            sourceLink(url: url)
                        }
                    }

                    signatureRow

                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .medium))
                            Text("Delete recipe")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(AppColor.destructive)
                        .padding(AppSpacing.sm)
                    }
                    .padding(.top, AppSpacing.md)
                }
                .padding(AppSpacing.lg)
                .padding(.bottom, 100)
            }
            .background(AppColor.background)

            // Hide the full-width Start Cooking bar whenever a cook
            // session is already active — otherwise it collides
            // visually with the resume pill at the bottom of the
            // screen. The pill's green "+" button is the additive
            // entry point for spawning a parallel cook from this
            // recipe; replacing the existing session is intentionally
            // not surfaced here (would require closing the active
            // session first).
            if session.activeCooks.isEmpty {
                startCookingBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Center: llama icon → opens accent-color picker. Slightly
            // larger than the trailing icons so the mascot reads as the
            // headline element rather than just another toolbar button.
            ToolbarItem(placement: .principal) {
                Button {
                    Haptics.selection()
                    showingAppearance = true
                } label: {
                    LlamaMascot(size: 38, color: appearance.accentColor)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Customize accent color")
            }
            // Trailing trio — each its own ToolbarItem so iOS spreads them
            // out, each wrapped in an identical frame so heart/share/edit
            // all sit on exactly the same horizontal axis (without the
            // explicit frame, the share-link image renders at a slightly
            // different intrinsic height and ends up a hair below the
            // others). All three use the same font + accent.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.selection()
                    recipe.favorite.toggle()
                    recipe.updatedAt = .now
                } label: {
                    Image(systemName: recipe.favorite ? "heart.fill" : "heart")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(appearance.accentColor)
                        .frame(width: 30, height: 30)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: recipe.exportText,
                    subject: Text(recipe.title),
                    message: Text("Recipe from Llamas Cookbook")
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(appearance.accentColor)
                        .frame(width: 30, height: 30)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor.startEdit(recipe)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(appearance.accentColor)
                        .frame(width: 30, height: 30)
                }
            }
        }
        .sheet(isPresented: $showingConversions) {
            ConversionsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAppearance) {
            AccentColorPicker(settings: appearance)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSourdough) {
            SourdoughCalculatorView { row in
                addSourdoughIngredients(from: row)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            // .sheet inherits the parent's environment, but @Observable
            // values can drop out across sheet boundaries — re-injecting
            // is cheap insurance.
            .environment(appearance)
        }
        .onAppear {
            // Tell the cooking pills bar at root that the user is now
            // viewing this recipe — used to decide whether to surface
            // the "Add to Cook Mode" green button next to the resume
            // pill when a session is already minimized.
            navContext.detailedRecipeID = recipe.id
        }
        .onDisappear {
            // Clear only if we're still the foregrounded recipe — guards
            // against a fast Detail → Detail navigation racing the
            // disappear and clearing the next view's set value.
            if navContext.detailedRecipeID == recipe.id {
                navContext.detailedRecipeID = nil
            }
        }
        .alert("Delete recipe?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                // Mirror LibraryView's delete path: drop any cook for
                // this recipe before the @Model is deleted so the
                // session never references a dangling SwiftData fault.
                session.cleanupCooks(forDeletedRecipeID: recipe.id)
                modelContext.delete(recipe)
                dismiss()
            }
        } message: {
            Text("\"\(recipe.title)\" will be permanently removed.")
        }
        .fullScreenCover(isPresented: $showingPhotoCarousel) {
            // Live `@Model` mutations: tapping the carousel's add /
            // delete / caption-edit affordances writes through to
            // SwiftData immediately (same persistence model as the
            // favorite-toggle), no Save needed.
            let displayablePhotos = recipe.sortedPhotos.filter { $0.image != nil }
            PhotoCarouselView(
                photoData: displayablePhotos.compactMap(\.image),
                captions: displayablePhotos.map(\.caption),
                onAdd: { rawDataArray in
                    await addPhotos(from: rawDataArray)
                },
                onDelete: { index in
                    deletePhoto(at: index)
                },
                onSetCaption: { index, newCaption in
                    setPhotoCaption(at: index, to: newCaption)
                }
            )
        }
        // Step photos viewer. View-only mode (no onAdd / onDelete /
        // onSetCaption) — captions show but aren't editable from the
        // recipe-detail surface; users edit step photos through the
        // editor flow. Sheet (not full-screen cover) for the smaller
        // pop-up modal feel — step photos are nested inside one
        // step's content, not the whole-recipe gallery moment.
        .sheet(item: $viewingStepImages) { wrapper in
            PhotoCarouselView(
                photoData: wrapper.images,
                captions: wrapper.captions
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: subsections

    @ViewBuilder
    private func section<Content: View, Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(AppColor.textPrimary)
                    // Underline rides the padded bottom of the Text's own
                    // frame, so it stretches to match the word width —
                    // 130pt under "Ingredients", 50pt under "Steps" — rather
                    // than the previous fixed 32pt stub.
                    .padding(.bottom, 6)
                    .background(alignment: .bottom) {
                        Capsule()
                            .fill(appearance.accentColor.opacity(0.55))
                            .frame(height: 2)
                    }
                Spacer(minLength: AppSpacing.sm)
                accessory()
            }
            .padding(.top, AppSpacing.lg)
            content()
        }
    }

    /// Trailing accessories for the Ingredients section header. Sourdough
    /// chip is gated on the recipe carrying a "sourdough" tag — Conversions
    /// is always shown.
    @ViewBuilder
    private var ingredientAccessories: some View {
        HStack(spacing: AppSpacing.xs) {
            if isSourdoughRecipe {
                sourdoughChip
            }
            conversionsChip
        }
    }

    /// Tag presence drives the sourdough chip + calculator availability.
    /// Tags are stored lowercase by `TagInputView.normalize`, so we
    /// compare lowercased to be tolerant of legacy data.
    private var isSourdoughRecipe: Bool {
        recipe.tags.contains { $0.lowercased() == "sourdough" }
    }

    private var conversionsChip: some View {
        Button {
            Haptics.selection()
            showingConversions = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ruler")
                    .font(.system(size: 11, weight: .semibold))
                Text("Conversions")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(appearance.accentColor)
            .padding(.horizontal, AppSpacing.sm + 2)
            .padding(.vertical, AppSpacing.xs + 1)
            .overlay(Capsule().stroke(appearance.accentColor, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open kitchen conversions reference")
    }

    private var sourdoughChip: some View {
        Button {
            Haptics.selection()
            showingSourdough = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Sourdough")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(appearance.accentColor)
            .padding(.horizontal, AppSpacing.sm + 2)
            .padding(.vertical, AppSpacing.xs + 1)
            .overlay(Capsule().stroke(appearance.accentColor, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open sourdough feeding calculator")
    }

    private func ingredientRow(_ ingredient: Ingredient) -> some View {
        let display = ingredient.display()
        let hasMeasure = !display.quantity.isEmpty || !display.unit.isEmpty
        let takesOf = display.takesOf

        return HStack(alignment: .center, spacing: AppSpacing.sm + 2) {
            Circle()
                .fill(appearance.accentColor)
                .frame(width: 6, height: 6)

            // Measure column is rendered only when the ingredient actually
            // has a quantity or unit. Bare names (vanilla, salt, …) skip
            // the column entirely so the name sits flush with the bullet
            // instead of after a 96pt gap.
            if hasMeasure {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if !display.quantity.isEmpty {
                        Text(display.quantity)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    if !display.unit.isEmpty {
                        Text(display.unit)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(appearance.accentColor.opacity(0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 96, alignment: .leading)

                if takesOf {
                    Text("of")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColor.textSecondary)
                } else {
                    Text("—")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(AppColor.dividerStrong)
                }
            }

            Text(ingredient.name)
                .font(AppFont.ingredient)
                .foregroundStyle(AppColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppSpacing.sm + 2)
        .padding(.horizontal, AppSpacing.md + 2)
        .background(
            LinearGradient(
                colors: [AppColor.surfaceRaised, AppColor.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider.opacity(0.6), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: AppColor.shadow, radius: 5, x: 0, y: 2)
        .shadow(color: AppColor.shadowSoft, radius: 1, x: 0, y: 0.5)
    }

    /// Lightbulb-tinted italic callout — matches Cook Mode's per-step
    /// reminder styling, but driven by the user's accent so the box stays
    /// consistent with the rest of detail-view chrome.
    private func noteCallout(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(appearance.accentColor)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 15, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(AppColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(AppSpacing.md)
        .background(appearance.accentColor.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(appearance.accentColor.opacity(0.30), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func trimmedNote(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return nil
        }
        return v
    }

    private var hasOrphanStepNotes: Bool {
        trimmedNote(recipe.prefaceNote) != nil || trimmedNote(recipe.epilogueNote) != nil
    }

    private func sourceLink(url: String) -> some View {
        Button {
            if let parsed = URL(string: url) {
                UIApplication.shared.open(parsed)
            }
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(AppColor.accent)
                Text(url)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
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
    }

    /// Photos entry-point. Same shape and position as the editor's
    /// gallery button so the user reaches photos through the same row
    /// regardless of which surface they're on. Mutations from the
    /// carousel persist immediately (live `@Model` Recipe relationship)
    /// — same persistence model as the favorite-toggle.
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
        .accessibilityLabel(recipe.photos.isEmpty
            ? "Add photos"
            : "Photos, \(recipe.photos.count)"
        )
    }

    private var photoButtonLabel: String {
        let count = recipe.photos.count
        if count == 0 { return "Add Photos" }
        return "Photos (\(count))"
    }

    /// Process picked bytes through ImageProcessing and append
    /// RecipePhoto rows to the live relationship. Order extends from
    /// the current count so newest lands at the end of the carousel,
    /// matching the editor.
    private func addPhotos(from rawDataArray: [Data]) async {
        var processedBytes: [Data] = []
        for raw in rawDataArray {
            if let processed = await ImageProcessing.prepare(raw, for: .gallery) {
                processedBytes.append(processed)
            }
        }
        await MainActor.run {
            let baseOrder = recipe.photos.count
            for (offset, data) in processedBytes.enumerated() {
                recipe.photos.append(
                    RecipePhoto(image: data, order: baseOrder + offset)
                )
            }
            if !processedBytes.isEmpty {
                recipe.updatedAt = .now
            }
        }
    }

    private func deletePhoto(at index: Int) {
        // `index` indexes into the displayable-photos array (filtered
        // to non-nil image bytes), matching what the carousel renders.
        let displayable = recipe.sortedPhotos.filter { $0.image != nil }
        guard displayable.indices.contains(index) else { return }
        modelContext.delete(displayable[index])
        recipe.updatedAt = .now
    }

    /// Set caption on the live `@Model` at `index`. Mutating the
    /// SwiftData property persists immediately — same pattern as the
    /// favorite-toggle. Empty strings normalize to nil so a blank
    /// caption row doesn't render as a tiny empty box in the carousel.
    private func setPhotoCaption(at index: Int, to newCaption: String?) {
        let displayable = recipe.sortedPhotos.filter { $0.image != nil }
        guard displayable.indices.contains(index) else { return }
        let trimmed = newCaption?.trimmingCharacters(in: .whitespacesAndNewlines)
        displayable[index].caption = (trimmed?.isEmpty ?? true) ? nil : trimmed
        recipe.updatedAt = .now
    }

    private var signatureRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaMascot(size: 36)
            Text(metaFooter)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, AppSpacing.xl)
    }

    private var startCookingBar: some View {
        VStack {
            Button {
                Haptics.impact(.light)
                session.start(recipe)
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "fork.knife")
                    Text("Start Cooking")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(AppColor.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(appearance.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(AppColor.background.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(AppColor.divider).frame(height: 1)
        }
    }

    // MARK: Computed

    private var sortedIngredients: [Ingredient] { recipe.sortedIngredients }
    private var sortedSteps: [RecipeStep] { recipe.sortedSteps }

    private var timeParts: [String] {
        var parts: [String] = []
        if let s = recipe.servings {
            parts.append("\(s) serving\(s == 1 ? "" : "s")")
        }
        if let cook = recipe.cookTimeMinutes {
            parts.append("Cook \(cook)m")
        }
        return parts
    }

    private var metaFooter: String {
        var parts: [String] = []
        parts.append("Added \(recipe.createdAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year()))")
        if let last = recipe.lastCookedAt {
            parts.append("Last cooked \(last.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year()))")
        }
        if recipe.cookCount > 0 {
            parts.append("Cooked \(recipe.cookCount) time\(recipe.cookCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// Tail-append starter / water / flour ingredients computed from the
    /// chosen ratio + total. Order numbers continue from the highest
    /// existing ingredient so the new entries land at the bottom of the
    /// list. The relationship's inverse handles SwiftData registration —
    /// no explicit `modelContext.insert` needed since `recipe` is already
    /// managed.
    private func addSourdoughIngredients(from row: SourdoughCalculator.Row) {
        let nextOrder = (recipe.ingredients.map(\.order).max() ?? -1) + 1
        let entries: [(name: String, value: Double)] = [
            ("active starter", row.starter),
            ("water",          row.water),
            ("flour",          row.flour),
        ]
        for (offset, entry) in entries.enumerated() {
            let ingredient = Ingredient(
                quantity: SourdoughCalculator.gramsValue(entry.value),
                unit: "g",
                name: entry.name,
                order: nextOrder + offset
            )
            recipe.ingredients.append(ingredient)
        }
        recipe.updatedAt = .now
    }

}

private struct TagPill: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .foregroundStyle(AppColor.textPrimary)
            .background(AppColor.surface)
            .overlay(Capsule().stroke(AppColor.divider, lineWidth: 1))
            .clipShape(Capsule())
    }
}

/// A simple wrap layout for pills/chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One step in the detail-view numbered list. The row sits inside a
/// gradient "bubble" pill — cream shading into a soft tint of the user's
/// accent at the bottom-trailing corner, with layered shadows to lift
/// it off the page. Number is a fixed size, vertically centered against
/// the wrapping text.
private struct StepDetailRow: View {
    @Environment(AppearanceSettings.self) private var appearance

    let idx: Int
    let step: RecipeStep
    /// Caller-provided tap target for the step's photo button. Hoisting
    /// the viewer state to the parent (rather than per-row) avoids many
    /// concurrent `.sheet` modifiers on a long recipe and keeps the row
    /// purely presentational. The two arrays are parallel — index `i`
    /// in `images` corresponds to caption `captions[i]`.
    let onTapPhotos: ([Data], [String?]) -> Void

    private var displayablePhotos: [RecipeStepPhoto] {
        step.sortedStepPhotos.filter { $0.image != nil }
    }

    private var stepPhotoBytes: [Data] {
        displayablePhotos.compactMap(\.image)
    }

    private var stepPhotoCaptions: [String?] {
        displayablePhotos.map(\.caption)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                Text("\(idx + 1).")
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(appearance.accentColor)
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .leading)

                Text(step.text)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if step.needsTimer {
                    Image(systemName: "timer")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(appearance.accentColor.opacity(0.85))
                }
            }

            if !stepPhotoBytes.isEmpty {
                photosButton
            }
        }
        .padding(.vertical, AppSpacing.md)
        .padding(.horizontal, AppSpacing.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    AppColor.surfaceRaised,
                    appearance.accentColor.opacity(0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(appearance.accentColor.opacity(0.28), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: AppColor.shadow, radius: 6, x: 0, y: 2)
        .shadow(color: AppColor.shadowSoft, radius: 1, x: 0, y: 0.5)
    }

    /// Compact pill button under the step text. Only shown when the
    /// step has at least one photo — the user explicitly asked for the
    /// image button to disappear when there's nothing to view. Indented
    /// past the step-number gutter so it nestles under the body text.
    private var photosButton: some View {
        Button {
            onTapPhotos(stepPhotoBytes, stepPhotoCaptions)
        } label: {
            HStack(spacing: AppSpacing.xs + 2) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(stepPhotoBytes.count == 1
                     ? "View photo"
                     : "View photos · \(stepPhotoBytes.count)")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(appearance.accentColor)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(AppColor.surface)
            .overlay(
                Capsule().stroke(appearance.accentColor.opacity(0.45), lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.leading, 28 + AppSpacing.md)
        .accessibilityLabel(stepPhotoBytes.count == 1
            ? "View step \(idx + 1) photo"
            : "View \(stepPhotoBytes.count) photos for step \(idx + 1)"
        )
    }
}

/// Wrapper so `.sheet(item:)` can drive the step-photos viewer with
/// arbitrary byte arrays. `[Data]` itself isn't `Identifiable`; the
/// wrapper supplies the required id. `captions` is parallel to
/// `images` — same length, same indices — so the read-only carousel
/// can render them alongside.
private struct ViewingStepImages: Identifiable {
    let id = UUID()
    let images: [Data]
    let captions: [String?]
}
