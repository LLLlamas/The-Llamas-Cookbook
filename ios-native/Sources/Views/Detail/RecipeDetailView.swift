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
    @Environment(OwnerProfile.self) private var ownerProfile

    let recipe: Recipe

    @State private var showingDeleteAlert = false
    @State private var showingConversions = false
    @State private var showingAppearance = false
    @State private var showingSourdough = false
    @State private var showingPhotoCarousel = false
    /// Page to land on when the carousel opens. Set by photo-row taps
    /// before flipping `showingPhotoCarousel`, so tapping the third
    /// thumb opens the carousel directly on that page.
    @State private var carouselStartPage: Int = 0
    /// Tapped step's photo array, wrapped so `.sheet(item:)` can drive
    /// the viewer. Nil = no viewer; non-nil = present the carousel
    /// with that step's photos in view-only mode.
    @State private var viewingStepImages: ViewingStepImages?

    // MARK: - Share state
    //
    // Three transports surfaced in the share Menu (file, link, text);
    // see Recipe-Sharing.md §7. The flow:
    //   1. Tap menu item → `triggerShare(_:)`.
    //   2. If the action is `.text` OR the user has already responded
    //      to the first-share name prompt, jump straight to the share
    //      sheet via `executeShare(_:)`.
    //   3. Otherwise stash the action in `pendingShareAction` and flip
    //      `showingNamePrompt`. After Continue / Skip, defer the share
    //      sheet by ~350ms so the alert dismiss doesn't race with the
    //      sheet present (same iOS 18 modal-stacking workaround the
    //      photo carousel uses on its picker dismiss path).

    /// What the user selected from the menu while the name prompt is
    /// in flight. Cleared on Cancel; consumed on Continue / Skip.
    @State private var pendingShareAction: ShareAction?
    @State private var showingNamePrompt = false
    @State private var pendingNameInput: String = ""

    /// Ready-to-share payload. Wrapped in a sum type so the cleanup
    /// path (`onComplete` of `ShareSheet`) can distinguish the file
    /// transport (which needs `FileManager.removeItem`) from URL /
    /// text (no cleanup).
    @State private var pendingShareItem: ShareItem?

    /// True while we're uploading the envelope to CloudKit. Drives a
    /// blocking loading overlay so the user doesn't tap "Share recipe"
    /// and stare at nothing for the second or two an upload takes.
    /// Slice 2 of the cloud-share rollout (Implementing-User-Sign-In.md
    /// §0 architecture pivot 2026-04-28).
    @State private var isPreparingCloudShare = false

    private enum ShareAction {
        case file, url, text
    }

    private enum ShareItem {
        case file(URL)
        case url(URL)
        case text(String)

        var activityItem: Any {
            switch self {
            case .file(let u), .url(let u): return u
            case .text(let s): return s
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text(StringCase.titleCase(recipe.title))
                        .font(AppFont.recipeTitle)
                        .foregroundStyle(appearance.accentColor)
                        .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)

                    // Provenance line for recipes imported from another
                    // user. Sticky through local edits on purpose —
                    // see Recipe-Sharing.md §8.3 ("a cookbook-from-Mom
                    // is a cookbook-from-Mom even after you tweak the
                    // salt amount").
                    if let provenance = provenanceLine {
                        Text(provenance)
                            .font(AppFont.eyebrow)
                            .foregroundStyle(AppColor.textTertiary)
                    }

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
                .padding(.bottom, AppSpacing.xl)
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
        .overlay {
            if isPreparingCloudShare {
                cloudShareLoadingOverlay
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
                    LlamaLogo(size: 72, shadowColor: appearance.accentColor)
                        .frame(width: 72, height: 72)
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
                Menu {
                    // URL form — `llamascookbook://recipe/v<N>/<base64url>`
                    // deep link, photos stripped to keep it under the
                    // URL byte ceiling. Tapping the link on a recipient
                    // with the app installed lands them straight in the
                    // import preview — no attachment-tap dance. Photo-
                    // bearing recipes still go through; the recipient
                    // sees the recipe without photos and can re-add
                    // their own.
                    //
                    // Cloud-first routing: when iCloud is available
                    // (almost always on iPhone), `shareViaPreferredTransport`
                    // uploads to CloudKit and emits a short
                    // `llamascookbook://share/<6char-id>` permalink with
                    // photos included. iCloud-unavailable / upload-failed
                    // → falls back to the self-contained
                    // `llamascookbook://recipe/v2/<base64url>` URL form
                    // (lzma-compressed, photos stripped). The internal
                    // `.file` ShareAction + `shareAsFile()` are kept as
                    // a paranoid last-resort fallback in
                    // `shareAsLocalURL()` for pathological long-text
                    // recipes that still trip the URL ceiling.
                    Button {
                        triggerShare(.url)
                    } label: {
                        Label("Share recipe", systemImage: "square.and.arrow.up")
                    }
                    // Text form — existing plain-text export. Bridge for
                    // recipients without the app. Skips the name prompt
                    // because plain text doesn't carry provenance.
                    Button {
                        triggerShare(.text)
                    } label: {
                        Label("Share as text", systemImage: "doc.plaintext")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(appearance.accentColor)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Share recipe")
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
                title: recipe.title,
                initialPage: carouselStartPage,
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
        // First-share name prompt. Fires the very first time the user
        // taps "Share recipe" or "Share as link" — both forms include
        // `sharedBy` in the envelope, so we capture it once before the
        // first outbound share. "Share as text" skips this entirely
        // (plain text has no provenance). After Continue / Skip, the
        // pending action is deferred ~350ms before triggering the
        // share sheet to avoid an alert→sheet present race.
        .alert("Who's sharing?", isPresented: $showingNamePrompt) {
            TextField("Your name (optional)", text: $pendingNameInput)
                .textInputAutocapitalization(.words)
            Button("Continue") {
                let trimmed = pendingNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                ownerProfile.userName = trimmed
                ownerProfile.hasPromptedForName = true
                deferredExecutePendingShare()
            }
            Button("Skip", role: .destructive) {
                ownerProfile.userName = ""
                ownerProfile.hasPromptedForName = true
                deferredExecutePendingShare()
            }
            Button("Cancel", role: .cancel) {
                pendingShareAction = nil
            }
        } message: {
            Text("Lets the recipient see who sent the recipe. You can leave it blank.")
        }
        // System share sheet — wraps UIActivityViewController so the
        // first-share prompt can finish before this presents. See
        // Views/Components/ShareSheet.swift for why this can't be a
        // SwiftUI ShareLink.
        .sheet(isPresented: shareSheetVisible) {
            if let item = pendingShareItem {
                ShareSheet(items: [item.activityItem]) { _ in
                    cleanupTempFile(for: item)
                    pendingShareItem = nil
                }
            }
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
        let takesOf = display.takesOf

        // Always reserve the qty/unit column + separator so name-only
        // ingredients (vanilla, salt) line up with measured ones in the
        // same list — the user explicitly asked for the name column to
        // stay anchored on the right even when there's no measurement.
        return HStack(alignment: .center, spacing: AppSpacing.sm + 2) {
            Circle()
                .fill(appearance.accentColor)
                .frame(width: 6, height: 6)

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

    /// Photos entry-point. Renders **every** gallery photo as a small
    /// rounded thumbnail in a single horizontal scroll row — first
    /// photo on the left acts as the "hero", every additional photo
    /// trails after it on the same row, no cap. Tapping any thumbnail
    /// opens the existing carousel at that index, so the larger
    /// viewing experience is unchanged. Empty gallery falls back to
    /// a single "Add" placeholder so the user still has a tap target.
    private var photosButton: some View {
        let displayablePhotos = recipe.sortedPhotos.filter { $0.image != nil }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                if displayablePhotos.isEmpty {
                    photoThumb(image: nil, index: 0)
                } else {
                    // Iterate over indices with `\.self` ID — bulletproof
                    // against any Identifiable conformance edge cases on
                    // the @Model `RecipePhoto` and avoids enumerated()
                    // tuple keypath quirks. Each thumbnail's index is
                    // routed straight into `carouselStartPage` so taps
                    // open the carousel on the matching page.
                    ForEach(displayablePhotos.indices, id: \.self) { idx in
                        photoThumb(
                            image: displayablePhotos[idx].image,
                            index: idx
                        )
                    }
                }
            }
            // Tiny inset on either end so a shadow on the first/last
            // thumb isn't clipped by the ScrollView's content bounds.
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        // Slightly taller than the 72pt thumb so the soft drop shadow
        // has room without getting clipped by the scroll view's
        // content rect.
        .frame(height: 84)
    }

    /// One thumbnail in the photo strip. Tap opens the carousel at
    /// `index`. Nil image renders the empty-gallery "Add" placeholder.
    private func photoThumb(image: Data?, index: Int) -> some View {
        Button {
            Haptics.selection()
            carouselStartPage = index
            showingPhotoCarousel = true
        } label: {
            Group {
                if let image {
                    RecipeImageView(
                        data: image,
                        contentMode: .fill,
                        cornerRadius: AppRadius.md
                    )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .fill(AppColor.accentSoft.opacity(0.5))
                        VStack(spacing: 2) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 18, weight: .regular))
                            Text("Add")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(appearance.accentColor.opacity(0.7))
                    }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider.opacity(0.7), lineWidth: 0.5)
            )
            .shadow(color: AppColor.shadowSoft, radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(image == nil ? "Add photos" : "Photo \(index + 1)")
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
            LlamaLogo(size: 72, shadowColor: appearance.accentColor)
            Text(metaFooter)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, AppSpacing.xl)
    }

    private var startCookingBar: some View {
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
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xs)
        .padding(.bottom, AppSpacing.xs)
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
            parts.append("Last cooked on \(last.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year()))")
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

    // MARK: - Provenance

    /// "Originally shared by Lorenzo · Apr 27" when both name and date
    /// are present; "Originally shared by Lorenzo" alone when only the
    /// name is set; nil when `sharedBy` is empty/nil. Locally-authored
    /// recipes always return nil. Stamped at materialize time and
    /// never cleared by `Recipe.apply(_:)` — the editor leaves it
    /// alone so credit survives local edits.
    private var provenanceLine: String? {
        guard let by = recipe.sharedBy?.trimmingCharacters(in: .whitespacesAndNewlines),
              !by.isEmpty else { return nil }
        guard let at = recipe.sharedAt else {
            return "Originally shared by \(by)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "Originally shared by \(by) · \(formatter.string(from: at))"
    }

    // MARK: - Share flow

    /// Menu-tap entry point. Routes through the first-share name
    /// prompt for file/url forms; text form skips the prompt because
    /// plain text doesn't carry provenance.
    private func triggerShare(_ action: ShareAction) {
        if action == .text || ownerProfile.hasPromptedForName {
            executeShare(action)
        } else {
            pendingShareAction = action
            // Pre-fill the field with whatever name the user has
            // stored — handles the "user reset their name from a
            // future Settings screen" case gracefully.
            pendingNameInput = ownerProfile.userName
            showingNamePrompt = true
        }
    }

    /// Routes the user-picked transport to the right builder. The
    /// `.url` path is async — we probe iCloud first and prefer the
    /// cloud-permalink form (short URL, photos included) when
    /// available, falling back to the local self-contained URL form
    /// (lzma-compressed, photos stripped) when iCloud is signed out
    /// or upload fails. `.file` and `.text` stay synchronous since
    /// they don't depend on network.
    private func executeShare(_ action: ShareAction) {
        switch action {
        case .file:
            shareAsFile()
        case .url:
            Task { @MainActor in
                await shareViaPreferredTransport()
            }
        case .text:
            pendingShareItem = .text(recipe.exportText)
        }
    }

    private func shareAsFile() {
        do {
            let envelope = makeShareEnvelope()
            let data = try RecipeShare.encodeFile(envelope)
            let url = try writeTempFile(data: data, name: filenameForRecipe())
            pendingShareItem = .file(url)
        } catch {
            // Last-ditch fallback. The user picked Share, we should
            // still get them a share sheet — degrading to plain text
            // beats silent failure.
            pendingShareItem = .text(recipe.exportText)
        }
    }

    /// Cloud-first share routing for the "Share recipe" menu entry.
    /// Probes iCloud account state (cheap, locally cached) and
    /// attempts a CloudKit upload when available. Cloud success →
    /// short permalink (~50 chars, photos included). Anything else →
    /// fall back to the existing self-contained URL form.
    @MainActor
    private func shareViaPreferredTransport() async {
        let status = await CloudKitService.accountStatus()
        if status == .available, await tryShareViaCloud() {
            return
        }
        shareAsLocalURL()
    }

    /// Returns true on a successful cloud upload; the caller (and
    /// `shareViaPreferredTransport`) treats false as "fall back to
    /// the local URL form." Surfaces a blocking spinner via
    /// `isPreparingCloudShare` while the upload is in flight.
    @MainActor
    private func tryShareViaCloud() async -> Bool {
        isPreparingCloudShare = true
        defer { isPreparingCloudShare = false }

        let envelope = makeShareEnvelope()
        let trimmedName = ownerProfile.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let recordName = try await CloudKitService.uploadShare(
                envelope,
                senderDisplayName: trimmedName.isEmpty ? nil : trimmedName
            )
            guard let url = URL(string: "llamascookbook://share/\(recordName)") else {
                // Vanishingly unlikely (recordName uses an
                // alphanumeric-only alphabet) — clean up the
                // orphaned record best-effort and fall through.
                try? await CloudKitService.deleteShare(recordName: recordName)
                return false
            }
            pendingShareItem = .url(url)
            return true
        } catch {
            // Network blip, schema not yet deployed, account state
            // changed mid-flight, etc. — silent fall-through to the
            // local URL form is friendlier than a "couldn't share"
            // alert when the user just wants to send a recipe.
            return false
        }
    }

    /// Self-contained URL form, used as fallback when iCloud is
    /// unavailable or the cloud upload fails. Photos are stripped to
    /// keep the URL under `RecipeShare.urlByteCeiling`; recipient
    /// gets the recipe data without photos and can re-add their own.
    private func shareAsLocalURL() {
        let envelope = makeShareEnvelope().withoutPhotos()
        if let url = try? RecipeShare.encodeURL(envelope) {
            pendingShareItem = .url(url)
        } else {
            // Pathological fallback — a photoless recipe with enormous
            // notes/steps could still trip the ceiling. Drop to file
            // form rather than silently failing.
            shareAsFile()
        }
    }

    /// Blocking overlay while the cloud upload is in flight. Cream
    /// card on a dimmed scrim; matches the visual language of
    /// existing modal indicators. Animated with a spring so it
    /// doesn't snap in/out jarringly.
    private var cloudShareLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: AppSpacing.md) {
                ProgressView()
                    .controlSize(.large)
                    .tint(appearance.accentColor)
                Text("Preparing share…")
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
            }
            .padding(AppSpacing.xl)
            .background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            .shadow(color: AppColor.shadow, radius: 12, y: 4)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: isPreparingCloudShare)
    }

    /// Defers the actual share sheet present by ~350ms after the
    /// alert resolves. Without this, the sheet sometimes fails to
    /// appear because UIKit is mid-transition dismissing the alert.
    /// Same workaround the photo carousel uses on its picker dismiss
    /// path (CLAUDE.md "Source layout" note re: the iOS 18 sheet-in-
    /// sheet alert race).
    private func deferredExecutePendingShare() {
        let action = pendingShareAction
        pendingShareAction = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if let action {
                executeShare(action)
            }
        }
    }

    private var shareSheetVisible: Binding<Bool> {
        Binding(
            get: { pendingShareItem != nil },
            set: { newValue in
                if !newValue, let item = pendingShareItem {
                    // User dismissed via swipe-down without completing
                    // (or system-dismissed); still want temp-file
                    // cleanup. The completion handler also runs in
                    // most paths — both paths are idempotent because
                    // `removeItem` on a missing file just throws and
                    // we swallow.
                    cleanupTempFile(for: item)
                    pendingShareItem = nil
                }
            }
        )
    }

    private func cleanupTempFile(for item: ShareItem) {
        if case .file(let url) = item {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeShareEnvelope() -> LCRecipeShareV1 {
        let trimmed = ownerProfile.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return RecipeShare.envelope(
            for: recipe,
            sharedBy: trimmed.isEmpty ? nil : trimmed,
            appVersion: currentAppVersion()
        )
    }

    private func currentAppVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Filesystem-safe filename for the share attachment. Strips
    /// punctuation but preserves spaces ("Banana Bread.llamarecipe"
    /// reads better than "BananaBread.llamarecipe" once it lands in a
    /// recipient's Files inbox).
    private func filenameForRecipe() -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespacesAndNewlines)
        let safe = recipe.title
            .components(separatedBy: allowed.inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "Recipe.llamarecipe" : "\(safe).llamarecipe"
    }

    private func writeTempFile(data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
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
