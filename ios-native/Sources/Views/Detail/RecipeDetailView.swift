import SwiftUI
import SwiftData
import UIKit
import CloudKit
import os

struct RecipeDetailView: View {
    private static let logger = Logger(
        subsystem: "com.llamascookbook.app",
        category: "CloudShare"
    )

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(CookingSession.self) private var session
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(NavigationContext.self) private var navContext
    @Environment(OwnerProfile.self) private var ownerProfile
    @Environment(FriendsStore.self) private var friendsStore
    @Environment(UserAccount.self) private var userAccount
    @Environment(LlamaProStore.self) private var proStore
    @Environment(GroceryListStore.self) private var groceryStore

    let recipe: Recipe

    @State private var showingDeleteAlert = false
    @State private var showingConversions = false
    @State private var showingAppearance = false
    @State private var showingSourdough = false
    @State private var showingAddToList = false
    /// Drives the "Added N items to <list>" confirmation toast after the
    /// Add-to-list sheet reports a successful add. Auto-clears after a beat.
    @State private var groceryToast: GroceryAddedInfo?
    @State private var showingPhotoCarousel = false
    /// "Imported by N" tap target. Sheet lists every
    /// `RecipeImport` audit row for this recipe (sorted newest
    /// first) so the user can see exactly which friends added
    /// it to their cookbook + when. Only ever rendered for
    /// own-authored recipes (`originalCreator*` nil); imported
    /// recipes show the attribution sheet below instead.
    @State private var showingImporters = false
    /// Driven detent for the Saves sheet. Starts at `.medium` for the
    /// importers list itself; flips to `.large` while the user is
    /// pushed into a friend's cookbook (so recipe cards are visible
    /// without an extra drag), and back to `.medium` on pop. Reset to
    /// `.medium` whenever the sheet is dismissed so the next open
    /// always starts compact.
    @State private var importersDetent: PresentationDetent = .medium
    /// Tap target for the "Originally shared by"
    /// caption on imported recipes. Sheet shows the chain root,
    /// import date, and (when chain length > 1) the
    /// intermediate sharer. Only ever non-nil for imported
    /// recipes.
    @State private var showingAttribution = false
    /// View-local mirror of `ImportCountCache` for this recipe.
    /// Seeded from UserDefaults on first appear and after each
    /// stale-while-revalidate refresh. SwiftUI re-renders the
    /// chip when this changes — UserDefaults reads alone won't
    /// trigger that since they're outside the SwiftData /
    /// `@Observable` change streams.
    @State private var cachedImportCount: Int = 0
    /// Page to land on when the carousel opens. Set by photo-row taps
    /// before flipping `showingPhotoCarousel`, so tapping the third
    /// thumb opens the carousel directly on that page.
    @State private var carouselStartPage: Int = 0
    /// Tapped step's photo array, wrapped so `.sheet(item:)` can drive
    /// the viewer. Nil = no viewer; non-nil = present the carousel
    /// with that step's photos in view-only mode.
    @State private var viewingStepImages: ViewingStepImages?

    /// Single ticker for the detail's vertical scroll surface. Per CLAUDE.md
    /// ("one `ScrollSectionTicker` per scroll surface"), the tag pills AND
    /// the major content sections (ingredients / steps / notes / general /
    /// reference / delete) all funnel into this one ticker — the dedup
    /// keys keep crossings distinct, so the user gets a tick on each tag
    /// AND on each section boundary as they scroll. Section markers are
    /// 1pt clear anchors so even sections taller than the viewport still
    /// hit the 0.95 visibility threshold.
    @State private var hapticTicker = ScrollSectionTicker()

    /// 1pt invisible anchor used to mark a vertical section boundary for
    /// `scrollSectionHaptic`. A full section block (e.g. Ingredients with
    /// 20 rows) can exceed viewport height and never report at threshold
    /// 0.95; a 1pt anchor reliably does. Layout impact is negligible
    /// because each major section already sits inside a VStack with
    /// `AppSpacing.md` between children.
    private func sectionAnchor(_ key: String) -> some View {
        Color.clear
            .frame(height: 1)
            .scrollSectionHaptic(section: key, ticker: hapticTicker)
    }

    // MARK: - Share state
    //
    // Three transports surfaced in the share Menu (file, link, text);
    // see Recipe-Sharing.md §7. Tap a menu item → `executeShare(_:)`
    // → straight to the share sheet. The sender display name is read
    // from `OwnerProfile.userName` at envelope-build time; an empty
    // value ships `sharedBy: nil` and the recipient's Detail hides
    // the provenance line entirely.

    /// Ready-to-share payload. Wrapped in a sum type so the cleanup
    /// path (`onComplete` of `ShareSheet`) can distinguish the file
    /// transport (which needs `FileManager.removeItem`) from URL /
    /// text (no cleanup).
    @State private var pendingShareItem: ShareItem?

    /// True while we're uploading the envelope to CloudKit. Drives a
    /// blocking loading overlay so the user doesn't tap "Share recipe"
    /// and stare at nothing for the second or two an upload takes.
    @State private var isPreparingCloudShare = false

    @State private var showCloudShareUnavailable = false

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
        ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text(StringCase.titleCase(recipe.title))
                        .font(AppFont.recipeTitle)
                        .foregroundStyle(appearance.detailTitleAccentColor)
                        .accentTextOutline()
                        .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)
                        .accentGlow(when: appearance.isDetailGlowActive(.title), color: appearance.detailTitleAccentColor)

                    // One eyebrow line under the title. Provenance wins
                    // when the recipe came from someone else — see
                    // Recipe-Sharing.md §8.3 ("a cookbook-from-Mom is a
                    // cookbook-from-Mom even after you tweak the salt
                    // amount") — otherwise we surface the local
                    // "Added <date>" stamp here so it has a home
                    // since the bottom signature row was removed.
                    //
                    // When the line is provenance (recipe was
                    // imported), wrap it in a button that opens
                    // the attribution sheet (chain root, import date,
                    // optional "via [Sharer]" hop). Local "Added
                    // <date>" stays static text — there's nothing
                    // to drill into.
                    topMetadataLineView

                    // "Imported by N" chip. Own-authored recipes
                    // only (the attribution path is mutually
                    // exclusive). Tap opens the importers list.
                    // Refreshed via stale-while-revalidate on appear
                    // and on each recipe-import push.
                    if showsImportCounterChip {
                        importCounterChip
                    }

                    if let summary = recipe.summary, !summary.isEmpty {
                        Text(summary)
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                    }

                    if !recipe.tags.isEmpty {
                        FlowRow(spacing: AppSpacing.xs) {
                            // Sort at display time so legacy recipes with
                            // unsorted tag arrays still render alphabetically.
                            // New recipes write a sorted array on save.
                            ForEach(recipe.tags.sorted(), id: \.self) { tag in
                                TagPill(label: StringCase.titleCase(tag))
                                    .scrollSectionHaptic(section: tag, ticker: hapticTicker)
                            }
                        }
                    }

                    sectionAnchor("photos")
                    photosButton

                    if !timeParts.isEmpty {
                        Text(timeParts.joined(separator: "  ·  "))
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }

                    if !sortedIngredients.isEmpty {
                        sectionAnchor("ingredients")
                        section("Ingredients",
                                headingColor: appearance.detailIngredientsHeadingAccentColor,
                                headingGlow: appearance.isDetailGlowActive(.ingredientsHeading),
                                containerGlow: appearance.isDetailGlowActive(.ingredients),
                                containerGlowColor: appearance.detailIngredientsAccentColor,
                                accessory: { ingredientAccessories }) {
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                // "Add to grocery list" sits right under the
                                // heading — the prep-stage call to action the
                                // user reaches for before they start cooking.
                                // Kept OUTSIDE the rows' `.drawingGroup()` below
                                // because `.buttonStyle(.lifted)` shadows clip to
                                // the texture bounds inside a drawingGroup.
                                addToListBar
                                VStack(spacing: AppSpacing.sm) {
                                    ForEach(sortedIngredients) { ingredient in
                                        ingredientRow(ingredient)
                                            .scrollSectionHaptic(
                                                section: ingredient.id.uuidString,
                                                ticker: hapticTicker
                                            )
                                    }
                                }
                                // Flatten each row's gradient + stroke + shadow layers
                                // (plus the accentTextOutline quad-shadows on qty/unit
                                // text) into a single Metal texture. Cuts first-render
                                // compositing cost proportional to ingredient count,
                                // which is the heaviest contributor to push-animation
                                // frame drops on detail views for longer recipes.
                                .drawingGroup()
                            }
                        }
                    }

                    if !sortedSteps.isEmpty {
                        sectionAnchor("steps")
                        section("Steps",
                                headingColor: appearance.detailStepsHeadingAccentColor,
                                headingGlow: appearance.isDetailGlowActive(.stepsHeading),
                                containerGlow: appearance.isDetailGlowActive(.steps),
                                containerGlowColor: appearance.detailStepsAccentColor) {
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                if let preface = recipe.prefaceNote.trimmedIfNonEmpty {
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
                                    .cardScrollTransition()
                                    .scrollSectionHaptic(
                                        section: step.id.uuidString,
                                        ticker: hapticTicker
                                    )
                                }
                                if let epilogue = recipe.epilogueNote.trimmedIfNonEmpty {
                                    noteCallout(epilogue)
                                }
                            }
                        }
                    } else if hasOrphanStepNotes {
                        sectionAnchor("notes")
                        // Preface / epilogue still need a home if the recipe
                        // has no steps yet but the user attached one.
                        section("Notes") {
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                if let preface = recipe.prefaceNote.trimmedIfNonEmpty {
                                    noteCallout(preface)
                                }
                                if let epilogue = recipe.epilogueNote.trimmedIfNonEmpty {
                                    noteCallout(epilogue)
                                }
                            }
                        }
                    }

                    if let general = recipe.generalNote.trimmedIfNonEmpty {
                        sectionAnchor("general")
                        section("General") {
                            noteCallout(general)
                        }
                    }

                    if let url = recipe.sourceUrl, !url.isEmpty {
                        sectionAnchor("reference")
                        section("Reference") {
                            sourceLink(url: url)
                        }
                    }

                    sectionAnchor("delete")
                    Button(role: .destructive) {
                        Haptics.warning()
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
                // Extra bottom runway so the Delete button clears
                // whatever bottom overlay is in play — the Start
                // Cooking bar (no active cooks) or the minimized cook
                // resume pill (cook in progress, not foregrounded).
                // ~80pt covers the bar/pill height + safe-area inset.
                // Without this the Delete button sits flush behind the
                // overlay and the user has to overscroll to reach it.
                .padding(.bottom, AppSpacing.xl + bottomOverlayClearance)
            }
            .llamaBackground()
            // safeAreaInset shrinks the scroll view's visible area by the
            // inset's height, so content never rests behind a bottom overlay.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.activeCooks.isEmpty {
                    // No active cooks — show the full-width Start Cooking bar.
                    // Hiding it when a cook is active avoids collision with
                    // the resume pill; the pill's green "+" is the additive
                    // entry point for parallel cooks.
                    startCookingBar
                } else if !session.isCookModeVisible {
                    // Cook mode is minimized — the resume pill floats at the
                    // bottom via CookingPillsOverlay (.overlay, not safeAreaInset),
                    // so the scroll view doesn't know about it. A transparent
                    // spacer matching the pill's visual footprint (~54pt pill
                    // + 12pt bottom gap = ~66pt; 70pt gives a bit of air)
                    // keeps content scrollable above the pill.
                    Color.clear.frame(height: 70)
                }
            }
        .overlay {
            if isPreparingCloudShare {
                cloudShareLoadingOverlay
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = groceryToast {
                groceryToastView(toast)
                    // Float above the Start Cooking bar / resume pill so the
                    // confirmation never hides behind the bottom overlay.
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: groceryToast)
        .task(id: groceryToast?.id) {
            guard groceryToast != nil else { return }
            try? await Task.sleep(for: .seconds(2.2))
            groceryToast = nil
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .enableSwipeBack()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.selection()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(appearance.detailNavAccentColor)
                        .accentTextOutline()
                        .frame(width: 30, height: 30)
                        .accentGlow(when: appearance.isDetailGlowActive(.nav), color: appearance.detailNavAccentColor)
                }
                .accessibilityLabel("Back")
            }
            // Center: llama icon → opens accent-color picker. Slightly
            // larger than the trailing icons so the mascot reads as the
            // headline element rather than just another toolbar button.
            ToolbarItem(placement: .principal) {
                Button {
                    Haptics.selection()
                    showingAppearance = true
                } label: {
                    LlamaLogoOrCrown(size: 66, accent: appearance.accentColor)
                        .frame(width: 66, height: 66)
                        // Pull the (now larger) mascot up toward the top of
                        // the bar: top padding trimmed 26 → 10 so the icon
                        // sits high AND the bar's TOTAL height (10 + 66 + 8 =
                        // 84) is actually shorter than the prior 52pt / 92pt
                        // baseline. A shorter bar keeps the Liquid Glass blur
                        // boundary higher — i.e. further above the recipe
                        // title — even though the icon itself is bigger.
                        .padding(.top, 10)
                        // Bottom padding kept minimal (was 36) — under
                        // iOS 26 Liquid Glass the nav bar sizes itself
                        // to content height and applies its blur zone
                        // to the full bar, so a tall principal item
                        // pushes the glass-blur boundary down over the
                        // page title. The 8pt here is the lever that
                        // keeps the blur out of "Coconut Lentil Soup" /
                        // similar recipe titles below — do not grow it.
                        .padding(.bottom, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Customize accent color")
            }
            // Trailing trio collapsed into a single ToolbarItem so we
            // control the spacing between heart / share / edit (iOS's
            // default per-item padding spread them apart enough that
            // they read as three separate clusters). Heart gets a 1pt
            // downward offset because the SF Symbol's optical center
            // sits a hair above the geometric center, and the explicit
            // 30×30 frame uses geometric centering — without the
            // offset, heart visibly floats above share + edit on the
            // y-axis.
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: AppSpacing.xs) {
                    Button {
                        Haptics.selection()
                        recipe.favorite.toggle()
                        recipe.updatedAt = .now
                    } label: {
                        Image(systemName: recipe.favorite ? "heart.fill" : "heart")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(appearance.detailNavAccentColor)
                            .accentTextOutline()
                            .frame(width: 30, height: 30)
                            .offset(y: 1)
                            .accentGlow(when: appearance.isDetailGlowActive(.nav), color: appearance.detailNavAccentColor)
                    }
                    .accessibilityLabel(recipe.favorite ? "Unfavorite" : "Favorite")
                    Menu {
                        // Cloud-first routing: `shareViaPreferredTransport`
                        // uploads to CloudKit and emits an HTTPS Universal
                        // Link permalink with photos included. iCloud-
                        // unavailable / upload-failed surfaces a friendly
                        // "try again later" alert and aborts.
                        Button {
                            executeShare(.url)
                        } label: {
                            Label("Share recipe", systemImage: "square.and.arrow.up")
                        }
                        // Text form — existing plain-text export. Bridge for
                        // recipients without the app. Plain text carries no
                        // provenance, so the envelope's `sharedBy` field is
                        // irrelevant for this transport.
                        Button {
                            executeShare(.text)
                        } label: {
                            Label("Share as text", systemImage: "doc.plaintext")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(appearance.detailNavAccentColor)
                            .accentTextOutline()
                            .frame(width: 30, height: 30)
                            .accentGlow(when: appearance.isDetailGlowActive(.nav), color: appearance.detailNavAccentColor)
                    }
                    .accessibilityLabel("Share recipe")
                    Button {
                        Haptics.selection()
                        editor.startEdit(recipe)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(appearance.detailNavAccentColor)
                            .accentTextOutline()
                            .frame(width: 30, height: 30)
                            .accentGlow(when: appearance.isDetailGlowActive(.nav), color: appearance.detailNavAccentColor)
                    }
                    .accessibilityLabel("Edit recipe")
                }
            }
        }
        .sheet(isPresented: $showingConversions) {
            ConversionsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAppearance) {
            AccentColorPicker()
                .environment(appearance)
                .environment(userAccount)
                .environment(proStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingImporters) {
            // Chain-root recipe id is `recipe.id` for own-authored
            // recipes. The chip never renders for imported recipes,
            // so this fork is the only one we need. FriendsStore +
            // NavigationContext + UserAccount
            // are re-injected so a row tap can push the importer's
            // cookbook (and onward into a friend recipe detail)
            // without a missing-environment crash — sheets break
            // the @Observable chain so explicit re-injection is
            // required.
            ImportersListSheet(
                originalRecipeID: recipe.id.uuidString,
                recipeTitle: recipe.title,
                detent: $importersDetent
            )
            .presentationDetents([.medium, .large], selection: $importersDetent)
            .presentationDragIndicator(.visible)
            .environment(appearance)
            .environment(friendsStore)
            .environment(navContext)
            .environment(userAccount)
        }
        .onChange(of: showingImporters) { _, isShowing in
            // Re-arm the saves sheet to its compact landing state
            // every time it closes — without this, dismissing while
            // pushed into a friend cookbook would leave `.large`
            // selected and the next open would skip the medium
            // landing the user expects.
            if !isShowing { importersDetent = .medium }
        }
        .sheet(isPresented: $showingAttribution) {
            // Only ever presented for imported recipes
            // (`originalCreator*` non-nil). Reads the chain via
            // the local Recipe's denormalized fields so the sheet
            // works offline.
            AttributionSheet(recipe: recipe)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environment(appearance)
                .environment(friendsStore)
                .environment(navContext)
                .environment(userAccount)
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
        .sheet(isPresented: $showingAddToList) {
            AddToGroceryListSheet(recipe: recipe) { count, listName in
                // Fired just before the sheet dismisses itself — stash the
                // result so the toast overlay (below, on the detail surface
                // behind the sheet) animates in as the sheet slides away.
                groceryToast = GroceryAddedInfo(count: count, listName: listName)
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                // @Observable values can drop across the sheet boundary on
                // iOS 26 — re-inject everything the sheet reads (it now also
                // re-syncs shared lists, so it needs the store + identity).
                .environment(appearance)
                .environment(groceryStore)
                .environment(userAccount)
                .environment(ownerProfile)
        }
        .onAppear {
            // Tell the cooking pills bar at root that the user is now
            // viewing this recipe — used to decide whether to surface
            // the "Add to Cook Mode" green button next to the resume
            // pill when a session is already minimized.
            navContext.detailedRecipeID = recipe.id
        }
        .onChange(of: recipe.id) { _, _ in
            // A different recipe is now displayed — clear the scroll
            // ticker so the re-laid-out content doesn't tick on its
            // initial settle into a fresh tag / section set.
            hapticTicker.reset()
        }
        .task(id: recipe.id) {
            // Stale-while-revalidate refresh of the "Imported by
            // N" chip. Triggers once on first appear, and again
            // whenever the user navigates to a different recipe
            // (the `id:` parameter restarts
            // the task on identity change). Seed `cachedImportCount`
            // from `ImportCountCache` first so the chip renders
            // its last-known value instantly, then fan in the
            // live fetch — a fresh fetch only swaps the rendered
            // count when the value differs, so the chip doesn't
            // double-flicker on identical data.
            cachedImportCount = ImportCountCache.count(for: recipe.id)
            await refreshImportCountIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: CloudKitSubscriptions.didFireNotification
        )) { note in
            // Re-fetch the import count when a push arrives
            // signaling a new RecipeImport row. Don't gate by
            // recipe match (the push payload doesn't include
            // record fields) — re-fetch unconditionally
            // and let the cache-vs-fresh comparison decide
            // whether to re-render. Cheap (one network call,
            // dedup'd on identical values).
            guard let kindRaw = note.userInfo?["kind"] as? String,
                  CloudKitSubscriptions.FiredKind(rawValue: kindRaw) == .recipeImport
            else { return }
            Task { await refreshImportCountIfNeeded(forceFetch: true) }
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
            Button("Cancel", role: .cancel) { Haptics.selection() }
            Button("Delete", role: .destructive) {
                // Mirror LibraryView's delete path: drop any cook for
                // this recipe before the @Model is deleted so the
                // session never references a dangling SwiftData fault.
                session.cleanupCooks(forDeletedRecipeID: recipe.id)
                // Tear down the cloud-side mirror for this recipe so
                // friends stop seeing it in `FriendLibraryView`.
                LibraryMirrorService.shared.deleteRecipe(recipeID: recipe.id)
                ImportCountCache.clear(for: recipe.id)
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
                },
                onReorder: { indices, destination in
                    reorderPhotos(fromOffsets: indices, toOffset: destination)
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
        // System share sheet — wraps UIActivityViewController.
        // See Views/Components/ShareSheet.swift for why this can't be a
        // SwiftUI ShareLink.
        .sheet(isPresented: shareSheetVisible) {
            if let item = pendingShareItem {
                // Wrap the payload in a `RecipeShareActivityItem` so
                // the share-sheet preview header (and the rich
                // previews in Messages / Mail / AirDrop) carry the
                // recipe title + llama app icon instead of the
                // generic "Untitled" iOS shows for custom-scheme URLs.
                ShareSheet(items: [
                    RecipeShareActivityItem(
                        payload: item.activityItem,
                        recipeTitle: recipe.title
                    )
                ]) { _ in
                    cleanupTempFile(for: item)
                    pendingShareItem = nil
                }
            }
        }
        .alert("Couldn't share recipe", isPresented: $showCloudShareUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Sharing needs iCloud and a network connection. Please try again later.")
        }
    }

    // MARK: subsections

    @ViewBuilder
    private func section<Content: View, Accessory: View>(
        _ title: String,
        headingColor: Color? = nil,
        headingGlow: Bool = false,
        containerGlow: Bool = false,
        containerGlowColor: Color? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        let hColor = headingColor ?? appearance.accentColor
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
                            .fill(hColor.opacity(0.55))
                            .frame(height: 2)
                            .accentGlow(when: headingGlow, color: hColor)
                    }
                Spacer(minLength: AppSpacing.sm)
                accessory()
            }
            .padding(.top, AppSpacing.lg)
            content()
        }
        .accentGlow(when: containerGlow, color: containerGlowColor ?? appearance.accentColor)
    }

    // MARK: - Import-count chip + provenance tap

    /// True for recipes the local user authored — drives the
    /// "Imported by N" chip + the importers-list sheet path. The
    /// canonical signal is "this Recipe wasn't materialized from
    /// a friend's PublishedRecipe," which we read from the
    /// attribution fields:
    ///
    /// - `originalCreatorUserRecordName == nil` → never imported,
    ///   user authored from scratch (Write / Text / Link / Photo).
    /// - `originalCreatorUserRecordName == self` → user imported
    ///   their own recipe back (rare, but covered for completeness
    ///   — could happen if user signs in on a second device and
    ///   imports from their own friend mirror).
    ///
    /// We DON'T treat the older file/link share path's `sharedBy`
    /// stamp as an "imported" signal — those recipes predate the
    /// chain-attribution model and don't have a matching
    /// `RecipeImport` audit row, so the chip would always read 0.
    private var showsImportCounterChip: Bool {
        // No iCloud / signed-out → conservatively treat as own
        // (the chip is a cloud-side delight surface and should
        // be hidden when the cloud isn't reachable anyway).
        let me = UserProfileMirror.cachedRecordID()
        if let creator = recipe.originalCreatorUserRecordName {
            return creator == me
        }
        return true
    }

    /// "Saved by N" pill below the title. Cap at "99+" so the
    /// chip width stays bounded for viral recipes (vanishingly
    /// unlikely on a friends-of-friends graph, but cheap to
    /// guard). 0-count case is hidden — no chip until at least
    /// one friend has saved, otherwise the surface reads as
    /// pre-emptive bragging.
    @ViewBuilder
    private var importCounterChip: some View {
        if cachedImportCount > 0 {
            Button {
                Haptics.selection()
                showingImporters = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text(importCounterLabel)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(appearance.detailProvenanceAccentColor)
                .padding(.horizontal, AppSpacing.sm + 2)
                .padding(.vertical, AppSpacing.xs + 1)
                .background(appearance.detailProvenanceAccentColor.opacity(0.10))
                .overlay(Capsule().stroke(appearance.detailProvenanceAccentColor.opacity(0.35), lineWidth: 1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View who saved this recipe")
        }
    }

    private var importCounterLabel: String {
        let n = cachedImportCount
        if n == 1 { return "1 Save" }
        let display = n > 99 ? "99+" : "\(n)"
        return "\(display) Saves"
    }

    /// Eyebrow line under the title. For imported recipes, wraps
    /// the provenance string in a button that opens the
    /// attribution sheet (chain root, import date, optional
    /// "via Sharer" hop). For locally-authored recipes, renders
    /// the static "Added MM/DD/YYYY" stamp — there's nothing to
    /// drill into.
    @ViewBuilder
    private var topMetadataLineView: some View {
        if let provenance = provenanceLine {
            Button {
                Haptics.selection()
                showingAttribution = true
            } label: {
                HStack(spacing: 4) {
                    Text(provenance)
                        .font(AppFont.eyebrow)
                        .foregroundStyle(appearance.detailProvenanceAccentColor)
                        .accentTextOutline()
                        .lineLimit(1)
                    Image(systemName: "info.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(appearance.detailProvenanceAccentColor.opacity(0.6))
                        .accentTextOutline()
                }
                .accentGlow(when: appearance.isDetailGlowActive(.provenance), color: appearance.detailProvenanceAccentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(provenance)
            .accessibilityHint("Tap for attribution details")
        } else {
            Text(addedDateLine)
                .font(AppFont.eyebrow)
                .foregroundStyle(AppColor.textTertiary)
                .lineLimit(1)
        }
    }

    /// Just the local "Added <date>" half of the eyebrow —
    /// `topMetadataLineView` reaches for this when `provenanceLine`
    /// is nil (recipe is locally authored).
    private var addedDateLine: String {
        "Added \(Formatters.date.string(from: recipe.createdAt))"
    }

    /// Stale-while-revalidate fetch of the import count.
    /// Renders the cached count immediately (read from
    /// `ImportCountCache`); fires a live CK query in the
    /// background; writes back to the cache + `cachedImportCount`
    /// if the value changed. Skipped when:
    ///
    /// - The chip wouldn't render anyway (imported recipe).
    /// - iCloud isn't bound (cached recordID missing).
    /// - The cache is fresh (< 60s old) AND `forceFetch` is
    ///   false. Forces fetch on push receipt — that's the
    ///   "real-time presence beyond the foreground refresh"
    ///   hook from the spec.
    @MainActor
    private func refreshImportCountIfNeeded(forceFetch: Bool = false) async {
        guard showsImportCounterChip else { return }
        guard UserProfileMirror.cachedRecordID() != nil else { return }
        if !forceFetch,
           let last = ImportCountCache.checkedAt(for: recipe.id),
           Date().timeIntervalSince(last) < 60 {
            return
        }
        let originalRecipeID = recipe.id.uuidString
        do {
            let count = try await CloudKitService.countRecipeImports(
                forOriginalRecipeID: originalRecipeID
            )
            ImportCountCache.set(count: count, checkedAt: Date(), for: recipe.id)
            if cachedImportCount != count {
                cachedImportCount = count
            }
        } catch {
            // Silent — the cache stays at its last value, the chip
            // keeps rendering whatever it was. Next foreground fires
            // this again.
        }
    }

    /// Trailing accessories for the Ingredients section header. Sourdough
    /// chip is gated on the recipe carrying a "sourdough" tag — Conversions
    /// is always shown. "Add to List" used to live here too; it's been
    /// promoted to a full-width bar (`addToListBar`) right under the heading.
    @ViewBuilder
    private var ingredientAccessories: some View {
        HStack(spacing: AppSpacing.xs) {
            if isSourdoughRecipe {
                sourdoughChip
            }
            conversionsChip
        }
    }

    /// Sends this recipe's ingredients to a grocery list. Free feature —
    /// no Pro gate. Full-width bar pinned right below the Ingredients
    /// heading so the prep-stage "grab the list" action reads as the first
    /// thing the user does with this section. Solid accent fill + cream
    /// text for an unambiguous, high-contrast read (the faint-tint outline
    /// version washed out against the page).
    private var addToListBar: some View {
        Button {
            Haptics.selection()
            showingAddToList = true
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "basket.fill")
                    .font(.system(size: 15, weight: .bold))
                    .accentTextOutline()
                Text("Add to grocery list")
                    .font(.system(size: 16, weight: .bold))
                    .accentTextOutline()
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .accentTextOutline()
            }
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 3)
            .background(appearance.detailChipsAccentColor)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .accentGlow(when: appearance.isDetailGlowActive(.chips), color: appearance.detailChipsAccentColor)
        }
        .buttonStyle(.lifted)
        .accessibilityLabel("Add ingredients to a grocery list")
    }

    /// Confirmation pill shown after the Add-to-list sheet reports a
    /// successful add. Reads "Added 3 items to Tacos", or "Already on
    /// Tacos" when every selected item was already on the list (dedup
    /// returned 0). Accent-filled capsule, matches the app's toast idiom.
    private func groceryToastView(_ info: GroceryAddedInfo) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: info.count > 0 ? "checkmark.circle.fill" : "basket.fill")
                .font(.system(size: 16, weight: .bold))
            Text(groceryToastText(info))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(AppColor.onAccent)
        .accentTextOutline()
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(appearance.accentColor, in: Capsule())
        .shadow(color: AppColor.shadow, radius: 12, x: 0, y: 4)
        .padding(.horizontal, AppSpacing.xl)
    }

    private func groceryToastText(_ info: GroceryAddedInfo) -> String {
        guard info.count > 0 else { return "Already on \(info.listName)" }
        let noun = info.count == 1 ? "item" : "items"
        return "Added \(info.count) \(noun) to \(info.listName)"
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
            .foregroundStyle(appearance.detailChipsAccentColor)
            .padding(.horizontal, AppSpacing.sm + 2)
            .padding(.vertical, AppSpacing.xs + 1)
            .overlay(Capsule().stroke(appearance.detailChipsAccentColor, lineWidth: 1))
            .clipShape(Capsule())
            .accentGlow(when: appearance.isDetailGlowActive(.chips), color: appearance.detailChipsAccentColor)
        }
        .buttonStyle(.lifted)
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
            .foregroundStyle(appearance.detailChipsAccentColor)
            .padding(.horizontal, AppSpacing.sm + 2)
            .padding(.vertical, AppSpacing.xs + 1)
            .overlay(Capsule().stroke(appearance.detailChipsAccentColor, lineWidth: 1))
            .clipShape(Capsule())
            .accentGlow(when: appearance.isDetailGlowActive(.chips), color: appearance.detailChipsAccentColor)
        }
        .buttonStyle(.lifted)
        .accessibilityLabel("Open sourdough feeding calculator")
    }

    private func ingredientRow(_ ingredient: Ingredient) -> some View {
        let display = ingredient.display()

        // Always reserve the qty/unit column + dash separator so name-only
        // ingredients (vanilla, salt) line up with measured ones in the
        // same list — the user explicitly asked for the name column to
        // stay anchored on the right even when there's no measurement.
        return HStack(alignment: .center, spacing: AppSpacing.sm + 2) {
            Circle()
                .fill(appearance.detailIngredientsAccentColor)
                .frame(width: 6, height: 6)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if !display.quantity.isEmpty {
                    Text(display.quantity)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appearance.detailIngredientsAccentColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accentTextOutline()
                }
                if !display.unit.isEmpty {
                    Text(display.unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(appearance.detailIngredientsAccentColor.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accentTextOutline()
                }
            }
            .frame(width: 96, alignment: .leading)

            Text("—")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(AppColor.dividerStrong)

            Text(ingredient.name)
                .font(AppFont.ingredient)
                .foregroundStyle(AppColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppSpacing.sm + 2)
        .padding(.horizontal, AppSpacing.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Chrome matches `StepDetailRow` (top-down gradient + white
        // top-edge glare + gradient stroke that lights the top edge)
        // so ingredient cards and step cards read as the same kind of
        // surface. The earlier diagonal gradient + flat dark stroke
        // had no top highlight to balance `.liftedCard()`'s drop
        // shadow, which made the shadow read as an awkward isolated
        // halo around each row.
        .background(
            LinearGradient(
                colors: [AppColor.surfaceRaised, AppColor.surface],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            LinearGradient(
                colors: [Color.white.opacity(0.20), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.60),
                            AppColor.divider.opacity(0.50),
                            AppColor.divider.opacity(0.80)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
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

    private var hasOrphanStepNotes: Bool {
        recipe.prefaceNote.trimmedIfNonEmpty != nil || recipe.epilogueNote.trimmedIfNonEmpty != nil
    }

    private func sourceLink(url: String) -> some View {
        Button {
            if let parsed = URL(string: url) {
                UIApplication.shared.open(parsed)
            }
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(appearance.accentColor)
                    .accentTextOutline()
                Text(url)
                    .font(AppFont.body)
                    .foregroundStyle(appearance.accentColor)
                    .accentTextOutline()
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
        .buttonStyle(.lifted)
    }

    /// Photos entry-point. Shows the first two gallery photos as 72pt
    /// thumbnails, then either a "+N more" overflow chip (when the gallery
    /// has more than 2 photos) or an "Add" tile (when 0–2 photos exist so
    /// there's always a visible tap target to open the carousel). Tapping
    /// any element opens the carousel; the overflow chip opens at index 2.
    private var photosButton: some View {
        let displayablePhotos = recipe.sortedPhotos.filter { $0.image != nil }
        let visiblePhotos = Array(displayablePhotos.prefix(2))
        let remainingCount = displayablePhotos.count - visiblePhotos.count

        return HStack(spacing: AppSpacing.sm) {
            ForEach(visiblePhotos.indices, id: \.self) { idx in
                photoThumb(image: visiblePhotos[idx].image, index: idx)
            }

            if remainingCount > 0 {
                // "+N more" — opens carousel at the third photo.
                Button {
                    Haptics.selection()
                    carouselStartPage = 2
                    showingPhotoCarousel = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .fill(AppColor.accentSoft.opacity(0.5))
                        VStack(spacing: 2) {
                            Text("+\(remainingCount)")
                                .font(.system(size: 16, weight: .semibold))
                            Text("more")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(appearance.accentColor)
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(AppColor.divider.opacity(0.7), lineWidth: 0.5)
                    )
                    .liftedCard()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(remainingCount) more photo\(remainingCount == 1 ? "" : "s")")
            } else {
                // Add tile — always present when fewer than 3 photos exist.
                photoThumb(image: nil, index: displayablePhotos.count)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
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
                    ) {
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .fill(AppColor.accentSoft.opacity(0.5))
                    }
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
            .liftedCard()
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

    /// Apply a SwiftUI-style `.move(fromOffsets:toOffset:)` against the
    /// displayable photos, then rewrite every `RecipePhoto.order` to
    /// match the new sequence. Photos with nil image bytes are pushed
    /// past the visible tail so any future re-render still sorts the
    /// real photos in the order the user just chose.
    private func reorderPhotos(fromOffsets: IndexSet, toOffset: Int) {
        var displayable = recipe.sortedPhotos.filter { $0.image != nil }
        let hidden = recipe.sortedPhotos.filter { $0.image == nil }
        displayable.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (i, photo) in displayable.enumerated() { photo.order = i }
        for (i, photo) in hidden.enumerated() { photo.order = displayable.count + i }
        recipe.updatedAt = .now
    }

    private var startCookingBar: some View {
        Button {
            Haptics.impact(.light)
            session.start(recipe)
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "fork.knife")
                    .accentTextOutline()
                Text("Start Cooking")
                    .font(.system(size: 17, weight: .semibold))
                    .accentTextOutline()
            }
            .foregroundStyle(AppColor.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.md)
            .background(appearance.detailCookBarAccentColor)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .shadow(color: appearance.detailCookBarAccentColor.opacity(appearance.isDetailGlowActive(.cookBar) ? 0.45 : 0), radius: appearance.isDetailGlowActive(.cookBar) ? 16 : 0)
            .animation(.easeInOut(duration: 0.14), value: appearance.isDetailGlowActive(.cookBar))
        }
        .buttonStyle(.lifted)
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

    /// Extra bottom padding so the Delete button clears whatever overlay
    /// is in play. The primary clearance is now handled by safeAreaInset
    /// (startCookingBar or the transparent 70pt spacer for the resume
    /// pill). This value is layered on top of that, giving the Delete
    /// button comfortable runway above the inset boundary.
    private var bottomOverlayClearance: CGFloat {
        if session.activeCooks.isEmpty { return 80 }       // Start Cooking bar
        if !session.isCookModeVisible { return 40 }        // resume pill — safeAreaInset handles primary clearance
        return 0
    }

    private var timeParts: [String] {
        var parts: [String] = []
        if let s = recipe.servings {
            parts.append("\(s) serving\(s == 1 ? "" : "s")")
        }
        if let prep = recipe.prepTimeMinutes {
            parts.append("Prep \(prep)m")
        }
        if let cook = recipe.cookTimeMinutes {
            parts.append("Cook \(cook)m")
        }
        return parts
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

    /// "Originally shared by Lorenzo · Apr 27, 2026" when both name and
    /// date are present; "Originally shared by Lorenzo" alone when only
    /// the name is set; nil for locally-authored recipes. Stamped at
    /// materialize time and never cleared by `Recipe.apply(_:)` — the
    /// editor leaves it alone so credit survives local edits.
    /// Display-name cap is enforced here as a render-side defense for
    /// envelopes from older app versions that predate the encode-side
    /// cap.
    ///
    /// **Two-source resolution.** The friend-import path
    /// stamps `originalCreatorDisplayName` + `importedAt`; the
    /// older file/link share path stamps `sharedBy` + `sharedAt`.
    /// We prefer the friend-import fields (they're the canonical
    /// chain-root attribution that travels through downstream
    /// imports) and fall back to the share fields, so both flows
    /// surface the same caption shape and existing share-imports
    /// stay visible after the model migration.
    private var provenanceLine: String? {
        if let line = formatProvenance(
            name: recipe.originalCreatorDisplayName,
            date: recipe.importedAt
        ) {
            return line
        }
        return formatProvenance(
            name: recipe.sharedBy,
            date: recipe.sharedAt
        )
    }

    /// Shared formatter used by both attribution sources. Returns
    /// nil when the name is empty/nil so the caller can collapse
    /// the line entirely.
    private func formatProvenance(name: String?, date: Date?) -> String? {
        guard let by = RecipeShare.cappedDisplayName(name) else { return nil }
        guard let at = date else {
            return "Originally shared by \(by)"
        }
        return "Originally shared by \(by) · \(Formatters.date.string(from: at))"
    }

    // MARK: - Share flow

    /// Menu-tap entry point — routes the user-picked transport to the
    /// right builder. The `.url` path is async: we probe iCloud first
    /// and prefer the cloud-permalink form (short URL, photos
    /// included) when available, falling back to the local
    /// self-contained URL form (lzma-compressed, photos stripped)
    /// when iCloud is signed out or upload fails. `.file` and `.text`
    /// stay synchronous since they don't depend on network.
    private func executeShare(_ action: ShareAction) {
        switch action {
        case .file:
            shareAsFile()
        case .url:
            // Re-entry guard. The cloud path runs an async account-status
            // probe before the upload sets its own gate, so two fast taps
            // could both clear the inner check and queue duplicate
            // uploads. Setting the flag synchronously here closes that
            // window; the Task's defer hands it back regardless of which
            // branch shareViaPreferredTransport returns through.
            guard !isPreparingCloudShare else { return }
            isPreparingCloudShare = true
            Task { @MainActor in
                defer { isPreparingCloudShare = false }
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
    /// surface a friendly "try again later" alert and abort.
    @MainActor
    private func shareViaPreferredTransport() async {
        let status = await CloudKitService.accountStatus()
        guard status == .available else {
            Self.logger.info("Account status not .available: \(status.rawValue, privacy: .public)")
            showCloudShareUnavailable = true
            return
        }
        if await tryShareViaCloud() {
            return
        }
        showCloudShareUnavailable = true
    }

    /// Returns true on a successful cloud upload; the caller (and
    /// `shareViaPreferredTransport`) treats false as "fall back to
    /// the local URL form." `isPreparingCloudShare` is set by the
    /// outer `executeShare(.url)` entry point so the spinner stays up
    /// across the account-status probe too.
    @MainActor
    private func tryShareViaCloud() async -> Bool {
        let envelope = makeShareEnvelope()
        let resolvedName = resolvedSenderDisplayName()
        do {
            let recordName = try await CloudKitService.uploadShare(
                envelope,
                senderDisplayName: resolvedName
            )
            // HTTPS Universal Link — the matching AASA file at the
            // `applinks:` host opens the URL directly in the app on
            // devices where it's installed, and falls through to a
            // friendly Cloudflare-Pages-rendered page otherwise.
            // Critically, the HTTPS URL also unlocks the rich
            // Messages preview bubble (recipe photo + title) on the
            // recipient side — Messages won't render previews for
            // custom URL schemes, so the old `llamascookbook://share/`
            // form would surface as bare URL text in the bubble.
            let urlString = "https://\(CloudKitService.shareLinkHost)/\(CloudKitService.shareLinkPathPrefix)/\(recordName)"
            guard let url = URL(string: urlString) else {
                // Vanishingly unlikely (recordName uses an
                // alphanumeric-only alphabet) — clean up the
                // orphaned record best-effort and fall through.
                try? await CloudKitService.deleteShare(recordName: recordName)
                return false
            }
            pendingShareItem = .url(url)
            Haptics.success()
            return true
        } catch {
            Self.logger.error("uploadShare threw: \(AppMetadata.describeServerError(error), privacy: .public)")
            return false
        }
    }

    /// Blocking overlay while the cloud upload is in flight. Cream
    /// card on a dimmed scrim; uses the branded `LlamaProgressIndicator`
    /// (logo with halo filling bottom-to-top) instead of a plain
    /// `ProgressView` so the user gets a recognizable signal that the
    /// app is working rather than the generic "is it stuck?" spinner.
    private var cloudShareLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            VStack(spacing: AppSpacing.md) {
                LlamaProgressIndicator(size: 76, accent: appearance.accentColor)
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
        return RecipeShare.envelope(
            for: recipe,
            sharedBy: resolvedSenderDisplayName(),
            appVersion: AppMetadata.currentAppVersion
        )
    }

    /// Sender display name used for outgoing share envelopes. Prefers
    /// the SIWA identity (`UserAccount.status.identity.displayName`)
    /// since that's the canonical post-sign-in name; falls back to the
    /// legacy `OwnerProfile.userName` for sessions that haven't gone
    /// through SIWA yet (Apple keeps the entitlement optional and the
    /// app can be used signed-out for local-only flows). Returns nil
    /// for empty/whitespace so the envelope omits the sharedBy field
    /// rather than emitting an empty string.
    private func resolvedSenderDisplayName() -> String? {
        let candidate = userAccount.status.identity?.displayName
            ?? ownerProfile.userName
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            .foregroundStyle(AppColor.textPrimary)
            .accentTextOutline()
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(AppColor.surface)
            .overlay(Capsule().stroke(AppColor.divider, lineWidth: 1))
            .clipShape(Capsule())
            // Toned-down lift — roughly half the `liftedCard()` shadow
            // (0.13 opacity / radius 6) so the small category pills don't
            // read as heavily as the larger ingredient/step cards. Same
            // black color and y:3 offset as `liftedCard()`.
            .shadow(color: .black.opacity(0.07), radius: 3, x: 0, y: 3)
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
/// neutral cream card — top→bottom cream gradient with a white bevel
/// highlight and a white-to-divider gradient stroke for a subtle 3D
/// lift, matching ingredient-row chrome. Number is a fixed size,
/// vertically centered against the wrapping text.
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
                    .foregroundStyle(appearance.detailStepsAccentColor)
                    .accentTextOutline()
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
                        .foregroundStyle(appearance.detailStepsAccentColor.opacity(0.85))
                        .accentTextOutline()
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
                colors: [AppColor.surfaceRaised, AppColor.surface],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            LinearGradient(
                colors: [Color.white.opacity(0.20), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.60),
                            AppColor.divider.opacity(0.50),
                            AppColor.divider.opacity(0.80)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .liftedCard()
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
                    .accentTextOutline()
                Text(stepPhotoBytes.count == 1
                     ? "View photo"
                     : "View photos · \(stepPhotoBytes.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .accentTextOutline()
            }
            .foregroundStyle(appearance.detailStepsAccentColor)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(AppColor.surface)
            .overlay(
                Capsule().stroke(appearance.detailStepsAccentColor.opacity(0.45), lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.lifted)
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

/// Payload for the "Added N items to <list>" confirmation toast. `count`
/// is the post-dedup figure reported by `AddToGroceryListSheet` (0 = all
/// selected items were already on the list). `Equatable` so the toast
/// overlay's `.animation(value:)` springs on each distinct add.
private struct GroceryAddedInfo: Identifiable, Equatable {
    let id = UUID()
    let count: Int
    let listName: String
}
