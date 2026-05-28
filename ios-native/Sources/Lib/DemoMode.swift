import Foundation
import SwiftData
import SwiftUI
import os

/// App Store Review demo mode. Lets a reviewer bypass Sign in with
/// Apple + iCloud entirely and verify every feature against
/// pre-populated data — required for Guideline 2.1(a) on apps whose
/// only sign-in surface is SIWA (Apple Review can't supply iCloud
/// credentials, and we can't ship our personal Apple ID).
///
/// **Architecture.** Demo mode operates on the local layer only —
/// every CloudKit fan-out continues to short-circuit through its
/// existing nil-guard:
/// - `UserProfileMirror.cachedRecordID()` returns nil → no friend /
///   profile / published-recipe writes
/// - `KeychainStore.read(.appleSub)` returns nil → no `/api/usage`
///   poll, no Anthropic Worker proxy request
/// - `LibraryMirrorService` checks demo flag → skips bulk publish
///
/// What demo mode adds on top:
/// - A synthetic `UserAccount.UserIdentity` so the UI thinks we're
///   signed in (Profile tab shows the signed-in body, Friends + Pro
///   surfaces unlock)
/// - A roster of three synthetic friends with full pre-built libraries
///   (separate from `SeedFriend`'s "Your Llama" — the seed still
///   ships at `friends[0]`; demo friends are appended after)
/// - A toggleable Pro tier (free / monthly / yearly) so the reviewer
///   can verify every crown asset + paywall surface without an IAP
/// - A handful of recipes pre-seeded into the user's own SwiftData
///   library so cooking flows, editor, and Cook Mode are reachable
///   on first open
///
/// **Lifecycle.** `enter(modelContext:)` flips the flag, populates
/// demo recipes, and stamps default state. `exit(modelContext:)`
/// reverses all of it — seeded recipes are tracked by id in
/// UserDefaults so cleanup is precise and never touches the
/// reviewer's own additions if they create any during the session.
/// Both calls are `@MainActor` because SwiftData inserts must run on
/// the model context's actor.
enum DemoMode {
    private static let log = Logger(subsystem: "com.llamascookbook.app", category: "DemoMode")

    // MARK: - Flag

    private static let activeKey = "demoMode.active.v1"
    private static let planOverrideKey = "demoMode.planOverride.v1"
    private static let seededRecipeIDsKey = "demoMode.seededRecipeIDs.v1"

    /// Single source of truth for "are we in demo mode right now."
    /// Read by every cross-cutting check (CloudKit guards, FriendsStore,
    /// LlamaProStore, AI parser short-circuit, etc.).
    static func isActive() -> Bool {
        UserDefaults.standard.bool(forKey: activeKey)
    }

    private static func setActive(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: activeKey)
    }

    // MARK: - Synthetic identity

    /// Stable display name + appleSub for the demo "account". The
    /// `appleSub` never lands in Keychain (we deliberately skip
    /// `KeychainStore.write` in the demo entry path) so any code path
    /// that reads `KeychainStore.read(.appleSub)` as its CloudKit /
    /// quota gate continues to see nil — preserving the existing
    /// short-circuit semantics.
    static let demoDisplayName = "Demo Cook"
    static let demoAppleSub = "demo-mode-synthetic-sub"

    static var demoIdentity: UserAccount.UserIdentity {
        UserAccount.UserIdentity(
            appleSub: demoAppleSub,
            displayName: demoDisplayName,
            createdAt: Date(timeIntervalSince1970: 1_767_225_600), // 2026-01-01
            cloudKitUserRecordID: nil,
            friendCode: nil
        )
    }

    // MARK: - Pro plan override

    /// What plan to surface in the UI while in demo. Backed by
    /// UserDefaults so the picker survives relaunches. Default is
    /// yearly so the reviewer sees the most-featured state immediately;
    /// they can flip to free / monthly via the in-demo controls.
    static func planOverride() -> LlamaProStore.Plan {
        guard isActive() else { return .none }
        switch UserDefaults.standard.string(forKey: planOverrideKey) {
        case "monthly": return .monthly
        case "yearly":  return .yearly
        case "none":    return .none
        default:        return .yearly
        }
    }

    static func setPlanOverride(_ plan: LlamaProStore.Plan) {
        let raw: String
        switch plan {
        case .none:    raw = "none"
        case .monthly: raw = "monthly"
        case .yearly:  raw = "yearly"
        }
        UserDefaults.standard.set(raw, forKey: planOverrideKey)
    }

    // MARK: - Enter / exit

    /// Begin demo mode. Seeds the user's library with demo recipes
    /// (idempotent — re-entering won't duplicate them), flips the
    /// active flag, primes the plan override to yearly, and returns
    /// the synthetic identity that `UserAccount` will surface as
    /// `.signedIn(...)`.
    ///
    /// Caller must update `UserAccount.status` and call
    /// `FriendsStore.refresh()` themselves — this enum doesn't reach
    /// up into those observables. See `UserAccount.enterDemoMode`.
    @MainActor
    static func enter(modelContext: ModelContext) {
        guard !isActive() else { return }
        setActive(true)
        // Default to yearly so the reviewer sees the highest-tier
        // crown + sunglasses asset on first frame. The in-demo
        // controls let them flip down to monthly / free.
        if UserDefaults.standard.string(forKey: planOverrideKey) == nil {
            UserDefaults.standard.set("yearly", forKey: planOverrideKey)
        }
        seedDemoLibrary(into: modelContext)
        log.info("Demo mode entered — seeded \(seededRecipeIDs().count, privacy: .public) recipes.")
    }

    /// End demo mode. Flips the active flag and clears the plan
    /// override. **Deliberately does NOT delete the seeded Recipe
    /// rows** — doing so synchronously crashed SwiftData's
    /// backing-data assertion when `LibraryView`'s `RecipeCardView`
    /// re-rendered against the about-to-be-deleted rows after
    /// `modelContext.save()`. Even deferring the delete a tick is
    /// fragile because SwiftUI re-evaluates `body` for the removed
    /// rows during the @Query-driven removal animation.
    ///
    /// Leaving the rows in place is safe — they're plain local
    /// recipes after exit, indistinguishable from anything the user
    /// could author themselves. The `seededRecipeIDsKey` tracking
    /// stays put so a future re-entry into demo mode skips
    /// re-seeding (idempotent). If a real user accidentally
    /// stumbled into demo and exited, they can delete the leftover
    /// recipes the same way they'd delete any recipe — swipe-to-
    /// delete in `LibraryView`.
    @MainActor
    static func exit(modelContext: ModelContext) {
        guard isActive() else { return }
        UserDefaults.standard.removeObject(forKey: planOverrideKey)
        setActive(false)
        log.info("Demo mode exited.")
    }

    // MARK: - Demo friends roster

    /// Sentinel-prefixed record names so every CloudKit-touching call
    /// site can `isDemoFriend(_:)`-guard a network round-trip. Mirrors
    /// the `SeedFriend.sentinelRecordName` pattern.
    static let demoFriendIDs: [String] = [
        "demo-friend-marco",
        "demo-friend-priya",
        "demo-friend-jules"
    ]

    static func isDemoFriend(_ profile: UserProfileSnapshot) -> Bool {
        demoFriendIDs.contains(profile.userRecordName)
    }

    static func isDemoFriend(_ recordName: String) -> Bool {
        demoFriendIDs.contains(recordName)
    }

    private static let referenceDate = Date(timeIntervalSince1970: 1_767_225_600)

    /// The three demo friends — different accent colors so the friend-
    /// tinted surfaces (FriendLibraryView, FriendRecipeDetailView)
    /// each render distinctly. Marco is presented as "currently
    /// cooking" so the presence-dot pulse is reachable without a
    /// CloudKit round-trip.
    static let demoFriends: [UserProfileSnapshot] = [
        UserProfileSnapshot(
            userRecordName: "demo-friend-marco",
            displayName: "Marco",
            accentHex: "#7C9F6F", // sage
            createdAt: referenceDate,
            lastCookedAt: referenceDate,
            lastCookedRecipeID: "11111111-1111-1111-1111-111111111101",
            lastCookedTitle: "Cacio e Pepe",
            cookingStartedAt: Date().addingTimeInterval(-25 * 60) // 25 min ago — pulse on
        ),
        UserProfileSnapshot(
            userRecordName: "demo-friend-priya",
            displayName: "Priya",
            accentHex: "#B86A6A", // rose
            createdAt: referenceDate,
            lastCookedAt: referenceDate.addingTimeInterval(-7 * 86_400),
            lastCookedRecipeID: "22222222-2222-2222-2222-222222222201",
            lastCookedTitle: "Chana Masala",
            cookingStartedAt: nil
        ),
        UserProfileSnapshot(
            userRecordName: "demo-friend-jules",
            displayName: "Jules",
            accentHex: "#6B8AB0", // slate blue
            createdAt: referenceDate,
            lastCookedAt: referenceDate.addingTimeInterval(-2 * 86_400),
            lastCookedRecipeID: "33333333-3333-3333-3333-333333333301",
            lastCookedTitle: "Sourdough Boule",
            cookingStartedAt: nil
        )
    ]

    /// Lookup helper for `FriendLibraryView`/`FriendRecipeDetailView`
    /// when those views need to resolve a friend back from an id
    /// (e.g. after a NavigationLink push).
    static func demoFriend(forRecordName recordName: String) -> UserProfileSnapshot? {
        demoFriends.first { $0.userRecordName == recordName }
    }

    // MARK: - Demo friend libraries

    /// Card-list payload for `FriendLibraryView` when the friend is a
    /// demo friend. Mirrors `SeedFriend.librarySummaries()` — bundled,
    /// network-free, deterministic.
    static func librarySummaries(forFriend friend: UserProfileSnapshot) -> [PublishedRecipeSummary] {
        guard let recipes = demoLibraries[friend.userRecordName] else { return [] }
        return recipes
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { rec in
                PublishedRecipeSummary(
                    recordName: rec.id.uuidString,
                    ownerID: friend.userRecordName,
                    localRecipeID: rec.id,
                    recipeTitle: rec.title,
                    updatedAt: referenceDate,
                    summary: rec.summary,
                    tags: rec.tags,
                    thumbnailData: nil
                )
            }
    }

    /// Full envelope payload for `FriendRecipeDetailView`. Returns
    /// nil when the recordName doesn't match any demo recipe — same
    /// contract as `SeedFriend.detail(forRecordName:)`.
    static func detail(forRecordName recordName: String, friend: UserProfileSnapshot) -> PublishedRecipeDetail? {
        guard let recipes = demoLibraries[friend.userRecordName],
              let rec = recipes.first(where: { $0.id.uuidString == recordName })
        else { return nil }
        let envelope = LCRecipeShareV1(
            schemaVersion: RecipeShare.currentVersion,
            share: LCRecipeShareV1.ShareEnvelope(
                id: rec.id,
                createdAt: referenceDate,
                sharedBy: friend.displayName,
                sourceRecipeID: rec.id,
                appVersion: AppMetadata.currentAppVersion,
                originalCreatorID: friend.userRecordName,
                originalRecipeID: rec.id.uuidString
            ),
            recipe: LCRecipeShareV1.ShareRecipe(
                id: rec.id,
                title: rec.title,
                summary: rec.summary,
                sourceUrl: nil,
                servings: rec.servings,
                cookTimeMinutes: rec.cookTimeMinutes,
                prepTimeMinutes: rec.prepTimeMinutes,
                notes: "",
                tags: rec.tags,
                prefaceNote: rec.prefaceNote,
                epilogueNote: nil,
                generalNote: nil,
                ingredients: rec.ingredients.enumerated().map { (idx, ing) in
                    LCRecipeShareV1.ShareIngredient(
                        id: UUID(),
                        quantity: ing.quantity,
                        unit: ing.unit,
                        name: ing.name,
                        order: idx
                    )
                },
                steps: rec.steps.enumerated().map { (idx, step) in
                    LCRecipeShareV1.ShareStep(
                        id: UUID(),
                        order: idx,
                        text: step.text,
                        needsTimer: step.needsTimer,
                        specialNote: nil,
                        photos: []
                    )
                },
                photos: []
            )
        )
        return PublishedRecipeDetail(
            envelope: envelope,
            originalCreatorID: friend.userRecordName,
            originalRecipeID: rec.id.uuidString
        )
    }

    // MARK: - User's own demo library (SwiftData seed)

    /// UUIDs of recipes we inserted into SwiftData during `enter(...)`.
    /// Tracked so `exit(...)` can delete exactly those recipes — never
    /// touching anything the reviewer adds during the session.
    private static func seededRecipeIDs() -> [UUID] {
        guard let raw = UserDefaults.standard.array(forKey: seededRecipeIDsKey) as? [String] else {
            return []
        }
        return raw.compactMap(UUID.init(uuidString:))
    }

    private static func setSeededRecipeIDs(_ ids: [UUID]) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: seededRecipeIDsKey)
    }

    @MainActor
    private static func seedDemoLibrary(into modelContext: ModelContext) {
        // Idempotent: if our seeded list is non-empty AND all of those
        // recipes are still in the store, skip. If any were deleted
        // (reviewer cleaned up before re-entering demo), wipe the list
        // and re-seed so the demo starts fresh.
        let existing = seededRecipeIDs()
        if !existing.isEmpty {
            let stillPresent = existing.compactMap { id -> Recipe? in
                let descriptor = FetchDescriptor<Recipe>(predicate: #Predicate { $0.id == id })
                return try? modelContext.fetch(descriptor).first
            }
            if stillPresent.count == existing.count { return }
            // Partial — reset.
            for recipe in stillPresent { modelContext.delete(recipe) }
            setSeededRecipeIDs([])
        }

        var insertedIDs: [UUID] = []
        for template in ownLibraryTemplates {
            let recipe = Recipe(
                title: template.title,
                summary: template.summary,
                servings: template.servings,
                cookTimeMinutes: template.cookTimeMinutes,
                prepTimeMinutes: template.prepTimeMinutes,
                notes: "",
                favorite: template.favorite,
                tags: template.tags
            )
            recipe.prefaceNote = template.prefaceNote
            for (idx, ing) in template.ingredients.enumerated() {
                let model = Ingredient(
                    quantity: ing.quantity,
                    unit: ing.unit,
                    name: ing.name,
                    order: idx
                )
                model.recipe = recipe
                recipe.ingredients.append(model)
            }
            for (idx, step) in template.steps.enumerated() {
                let model = RecipeStep(
                    text: step.text,
                    order: idx,
                    needsTimer: step.needsTimer
                )
                model.recipe = recipe
                recipe.steps.append(model)
            }
            modelContext.insert(recipe)
            insertedIDs.append(recipe.id)
        }
        do {
            try modelContext.save()
            setSeededRecipeIDs(insertedIDs)
        } catch {
            log.error("Failed to seed demo library: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Photo import simulation

    /// Drop-in replacement for `parseImagesStreaming` when demo mode
    /// is active. The Worker proxy can't authorize a request without
    /// `x-llamas-user` (which we never write to Keychain in demo),
    /// so real photo parsing would 401 and dead-end the flow. Instead
    /// we pace a canned recipe into the supplied `StreamingRecipeState`
    /// over ~1.5 s — title first (so `PhotoImportPreviewView`'s
    /// overlay dismisses on schedule), then ingredients and steps —
    /// and return a `VisionParseOutcome` with the assembled draft.
    /// The reviewer sees the same overlay → skeleton → preview → save
    /// sequence a real import produces.
    @MainActor
    static func simulatePhotoImportStream(
        into state: StreamingRecipeState,
        sourceUrl: String?
    ) async -> VisionParseOutcome {
        // Pull from `ownLibraryTemplates` so the demo "parse result"
        // is one of the recipes the reviewer can already see in the
        // demo library — visually consistent, no extra content to
        // maintain. Hash-pick by a fresh UUID per call so back-to-
        // back simulated parses don't always land the same recipe.
        let template = ownLibraryTemplates.randomElement() ?? ownLibraryTemplates[0]

        // Title lands first so `PhotoImportPreviewView.onAppear`'s
        // 4 s skeleton timer is preempted and the overlay dismisses.
        try? await Task.sleep(for: .milliseconds(600))
        state.applyEvent(.title(template.title))
        if let s = template.summary { state.applyEvent(.summary(s)) }
        if let servings = template.servings {
            state.applyEvent(.servings(String(servings)))
        }
        if let cook = template.cookTimeMinutes {
            state.applyEvent(.cookTimeMinutes(String(cook)))
        }
        if let prep = template.prepTimeMinutes {
            state.applyEvent(.prepTimeMinutes(String(prep)))
        }

        // Ingredients in two small bursts — mimics how Sonnet's
        // stream tends to land structured arrays.
        var draftIngredients: [DraftIngredient] = []
        for ing in template.ingredients {
            try? await Task.sleep(for: .milliseconds(80))
            let draftIng = DraftIngredient(
                quantity: ing.quantity ?? "",
                unit: ing.unit ?? "",
                name: ing.name
            )
            draftIngredients.append(draftIng)
            state.applyEvent(.ingredient(draftIng))
        }

        // Steps next.
        var draftSteps: [DraftStep] = []
        for step in template.steps {
            try? await Task.sleep(for: .milliseconds(120))
            let draftStep = DraftStep(
                text: step.text,
                needsTimer: step.needsTimer
            )
            draftSteps.append(draftStep)
            state.applyEvent(.step(draftStep))
        }

        var draft = DraftRecipe()
        draft.title = template.title
        draft.summary = template.summary ?? ""
        draft.sourceUrl = sourceUrl ?? ""
        draft.servings = template.servings.map(String.init) ?? ""
        draft.cookTimeMinutes = template.cookTimeMinutes.map(String.init) ?? ""
        draft.prepTimeMinutes = template.prepTimeMinutes.map(String.init) ?? ""
        draft.tags = template.tags
        draft.ingredients = draftIngredients
        draft.steps = draftSteps
        draft.prefaceNote = template.prefaceNote ?? ""

        state.finalDraft = draft
        state.status = .completed
        return VisionParseOutcome(draft: draft, cacheHit: false)
    }

    // MARK: - Recipe templates

    private struct OwnRecipeTemplate {
        let title: String
        let summary: String?
        let servings: Int?
        let cookTimeMinutes: Int?
        let prepTimeMinutes: Int?
        let tags: [String]
        let favorite: Bool
        let prefaceNote: String?
        let ingredients: [DemoIngredient]
        let steps: [DemoStep]
    }

    fileprivate struct DemoIngredient {
        let quantity: String?
        let unit: String?
        let name: String
    }

    fileprivate struct DemoStep {
        let text: String
        let needsTimer: Bool
    }

    /// Recipes inserted into the reviewer's own SwiftData library.
    /// Chosen to exercise the editor's range — varying servings,
    /// timers, tag combinations, a favorited entry, a recipe with a
    /// preface note.
    private static let ownLibraryTemplates: [OwnRecipeTemplate] = [
        OwnRecipeTemplate(
            title: "Weeknight Sheet-Pan Salmon",
            summary: "Roasted in 15 minutes with lemon, garlic, and herbs.",
            servings: 4,
            cookTimeMinutes: 15,
            prepTimeMinutes: 10,
            tags: ["Dinner", "Quick", "Fish"],
            favorite: true,
            prefaceNote: "Pat the salmon dry before seasoning — wet skin steams instead of crisping.",
            ingredients: [
                DemoIngredient(quantity: "4", unit: "fillets", name: "salmon, skin-on"),
                DemoIngredient(quantity: "2", unit: "tbsp", name: "olive oil"),
                DemoIngredient(quantity: "1", unit: nil, name: "lemon, sliced thin"),
                DemoIngredient(quantity: "3", unit: "cloves", name: "garlic, minced"),
                DemoIngredient(quantity: "1", unit: "tsp", name: "kosher salt"),
                DemoIngredient(quantity: "1/2", unit: "tsp", name: "black pepper"),
                DemoIngredient(quantity: "2", unit: "tbsp", name: "fresh dill, chopped")
            ],
            steps: [
                DemoStep(text: "Preheat oven to 425°F. Line a sheet pan with parchment.", needsTimer: false),
                DemoStep(text: "Pat salmon dry; rub with olive oil, salt, pepper, and garlic.", needsTimer: false),
                DemoStep(text: "Lay lemon slices over each fillet.", needsTimer: false),
                DemoStep(text: "Roast for 12–15 minutes until the thickest part flakes easily.", needsTimer: true),
                DemoStep(text: "Top with fresh dill and serve immediately.", needsTimer: false)
            ]
        ),
        OwnRecipeTemplate(
            title: "Brown-Butter Chocolate Chip Cookies",
            summary: "Crisp edges, soft centers, with toasted-butter depth.",
            servings: 24,
            cookTimeMinutes: 11,
            prepTimeMinutes: 20,
            tags: ["Dessert", "Baking"],
            favorite: true,
            prefaceNote: "Let the brown butter cool to room temp before mixing — hot butter melts the sugar and you lose the chew.",
            ingredients: [
                DemoIngredient(quantity: "1", unit: "cup", name: "unsalted butter"),
                DemoIngredient(quantity: "1", unit: "cup", name: "brown sugar, packed"),
                DemoIngredient(quantity: "1/2", unit: "cup", name: "granulated sugar"),
                DemoIngredient(quantity: "2", unit: nil, name: "large eggs"),
                DemoIngredient(quantity: "2", unit: "tsp", name: "vanilla extract"),
                DemoIngredient(quantity: "2 1/4", unit: "cups", name: "all-purpose flour"),
                DemoIngredient(quantity: "1", unit: "tsp", name: "baking soda"),
                DemoIngredient(quantity: "1", unit: "tsp", name: "kosher salt"),
                DemoIngredient(quantity: "2", unit: "cups", name: "dark chocolate chips")
            ],
            steps: [
                DemoStep(text: "Brown the butter in a light-colored pan over medium heat, swirling, until nutty and amber. About 5 minutes.", needsTimer: true),
                DemoStep(text: "Pour into a large bowl and let cool 10 minutes.", needsTimer: true),
                DemoStep(text: "Whisk in both sugars, then the eggs and vanilla.", needsTimer: false),
                DemoStep(text: "Fold in flour, baking soda, and salt until just combined. Stir in chocolate.", needsTimer: false),
                DemoStep(text: "Chill the dough 30 minutes (or overnight for more depth).", needsTimer: true),
                DemoStep(text: "Scoop onto parchment-lined sheets. Bake at 375°F for 10–11 minutes.", needsTimer: true),
                DemoStep(text: "Cool on the pan 5 minutes before moving to a rack.", needsTimer: true)
            ]
        ),
        OwnRecipeTemplate(
            title: "Miso-Glazed Eggplant",
            summary: "Broiled until silky with a sweet-savory miso lacquer.",
            servings: 2,
            cookTimeMinutes: 18,
            prepTimeMinutes: 5,
            tags: ["Dinner", "Vegetarian"],
            favorite: false,
            prefaceNote: nil,
            ingredients: [
                DemoIngredient(quantity: "2", unit: nil, name: "Japanese eggplants, halved lengthwise"),
                DemoIngredient(quantity: "3", unit: "tbsp", name: "white miso paste"),
                DemoIngredient(quantity: "2", unit: "tbsp", name: "mirin"),
                DemoIngredient(quantity: "1", unit: "tbsp", name: "sake (or water)"),
                DemoIngredient(quantity: "1", unit: "tbsp", name: "sugar"),
                DemoIngredient(quantity: "1", unit: "tsp", name: "neutral oil"),
                DemoIngredient(quantity: "1", unit: "tsp", name: "toasted sesame seeds")
            ],
            steps: [
                DemoStep(text: "Score the cut sides of the eggplant in a diamond pattern.", needsTimer: false),
                DemoStep(text: "Heat oil in a skillet; cook eggplant cut-side down until golden, 4 minutes.", needsTimer: true),
                DemoStep(text: "Flip, add a splash of water, cover, and steam until tender, 6 minutes.", needsTimer: true),
                DemoStep(text: "Whisk miso, mirin, sake, and sugar into a glaze.", needsTimer: false),
                DemoStep(text: "Brush glaze over cut sides; broil 3 minutes until bubbling and caramelized.", needsTimer: true),
                DemoStep(text: "Top with sesame seeds and serve over rice.", needsTimer: false)
            ]
        ),
        OwnRecipeTemplate(
            title: "Roasted Tomato Soup",
            summary: "Deeply roasted tomatoes blended with garlic and basil.",
            servings: 4,
            cookTimeMinutes: 45,
            prepTimeMinutes: 10,
            tags: ["Lunch", "Soup", "Vegetarian"],
            favorite: false,
            prefaceNote: nil,
            ingredients: [
                DemoIngredient(quantity: "3", unit: "lb", name: "Roma tomatoes, halved"),
                DemoIngredient(quantity: "1", unit: nil, name: "yellow onion, quartered"),
                DemoIngredient(quantity: "6", unit: "cloves", name: "garlic, peeled"),
                DemoIngredient(quantity: "3", unit: "tbsp", name: "olive oil"),
                DemoIngredient(quantity: "1", unit: "tsp", name: "kosher salt"),
                DemoIngredient(quantity: "1/2", unit: "tsp", name: "black pepper"),
                DemoIngredient(quantity: "2", unit: "cups", name: "vegetable stock"),
                DemoIngredient(quantity: "1/4", unit: "cup", name: "fresh basil leaves")
            ],
            steps: [
                DemoStep(text: "Heat oven to 400°F.", needsTimer: false),
                DemoStep(text: "Toss tomatoes, onion, and garlic with olive oil, salt, and pepper on a sheet pan.", needsTimer: false),
                DemoStep(text: "Roast 40 minutes until deeply browned at the edges.", needsTimer: true),
                DemoStep(text: "Transfer everything to a blender with stock and basil. Blend until smooth.", needsTimer: false),
                DemoStep(text: "Adjust salt and pepper; warm through before serving.", needsTimer: false)
            ]
        ),
        OwnRecipeTemplate(
            title: "Garlicky White Beans on Toast",
            summary: "5-minute lunch with crisp sourdough, smashed beans, and chili oil.",
            servings: 2,
            cookTimeMinutes: 5,
            prepTimeMinutes: 5,
            tags: ["Lunch", "Quick", "Vegetarian"],
            favorite: false,
            prefaceNote: nil,
            ingredients: [
                DemoIngredient(quantity: "1", unit: "can", name: "cannellini beans, drained"),
                DemoIngredient(quantity: "3", unit: "cloves", name: "garlic, thinly sliced"),
                DemoIngredient(quantity: "3", unit: "tbsp", name: "olive oil"),
                DemoIngredient(quantity: "1/2", unit: "tsp", name: "red pepper flakes"),
                DemoIngredient(quantity: "1", unit: "tbsp", name: "lemon juice"),
                DemoIngredient(quantity: "2", unit: "slices", name: "sourdough, toasted"),
                DemoIngredient(quantity: nil, unit: nil, name: "flaky salt, to finish")
            ],
            steps: [
                DemoStep(text: "Warm olive oil in a skillet over medium-low. Add garlic and chili flakes; sizzle 1 minute.", needsTimer: true),
                DemoStep(text: "Add beans; mash about half with a fork. Cook 2 minutes until creamy.", needsTimer: true),
                DemoStep(text: "Squeeze in lemon juice and season with salt.", needsTimer: false),
                DemoStep(text: "Spoon over toasted sourdough; finish with flaky salt and a drizzle of olive oil.", needsTimer: false)
            ]
        )
    ]

    // MARK: - Friend libraries (per-friend recipe tables)

    private struct FriendRecipeTemplate {
        let id: UUID
        let title: String
        let summary: String?
        let servings: Int?
        let cookTimeMinutes: Int?
        let prepTimeMinutes: Int?
        let tags: [String]
        let prefaceNote: String?
        let ingredients: [DemoIngredient]
        let steps: [DemoStep]
    }

    /// Per-friend recipe rosters. Each friend's recordName maps to
    /// their library. Stable UUIDs so navigation links resolve
    /// consistently across re-launches.
    private static let demoLibraries: [String: [FriendRecipeTemplate]] = [
        "demo-friend-marco": [
            FriendRecipeTemplate(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111101")!,
                title: "Cacio e Pepe",
                summary: "Three ingredients, all about technique. Emulsify the cheese with hot pasta water until silky.",
                servings: 2,
                cookTimeMinutes: 15,
                prepTimeMinutes: 5,
                tags: ["Pasta", "Italian", "Dinner"],
                prefaceNote: "Grate the pecorino on a microplane — coarser shreds clump instead of melting.",
                ingredients: [
                    DemoIngredient(quantity: "200", unit: "g", name: "tonnarelli or spaghetti"),
                    DemoIngredient(quantity: "100", unit: "g", name: "pecorino romano, finely grated"),
                    DemoIngredient(quantity: "2", unit: "tsp", name: "black peppercorns, freshly cracked"),
                    DemoIngredient(quantity: nil, unit: nil, name: "kosher salt, for pasta water")
                ],
                steps: [
                    DemoStep(text: "Bring a small pot of water to boil with a generous pinch of salt — less water than usual for starchier results.", needsTimer: false),
                    DemoStep(text: "Toast cracked pepper in a dry skillet 30 seconds until fragrant.", needsTimer: true),
                    DemoStep(text: "Cook pasta to 1 minute shy of al dente.", needsTimer: true),
                    DemoStep(text: "Reserve 1 cup pasta water; drain. Off heat, add pasta to the pepper pan.", needsTimer: false),
                    DemoStep(text: "Add a splash of pasta water, then sprinkle pecorino while tossing constantly. Add water as needed to form a glossy sauce.", needsTimer: false),
                    DemoStep(text: "Plate immediately — the sauce stiffens fast as it cools.", needsTimer: false)
                ]
            ),
            FriendRecipeTemplate(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111102")!,
                title: "Nonna's Sunday Ragù",
                summary: "Beef, pork, and a long simmer. The kind of sauce that fills the kitchen.",
                servings: 6,
                cookTimeMinutes: 180,
                prepTimeMinutes: 20,
                tags: ["Pasta", "Italian", "Dinner"],
                prefaceNote: nil,
                ingredients: [
                    DemoIngredient(quantity: "1", unit: "lb", name: "ground beef chuck"),
                    DemoIngredient(quantity: "1/2", unit: "lb", name: "ground pork"),
                    DemoIngredient(quantity: "1", unit: nil, name: "onion, finely diced"),
                    DemoIngredient(quantity: "2", unit: nil, name: "carrots, finely diced"),
                    DemoIngredient(quantity: "2", unit: "ribs", name: "celery, finely diced"),
                    DemoIngredient(quantity: "4", unit: "cloves", name: "garlic, minced"),
                    DemoIngredient(quantity: "1", unit: "can", name: "tomato paste (6 oz)"),
                    DemoIngredient(quantity: "1", unit: "cup", name: "dry red wine"),
                    DemoIngredient(quantity: "2", unit: "cans", name: "San Marzano tomatoes (28 oz each)"),
                    DemoIngredient(quantity: "1", unit: "cup", name: "whole milk"),
                    DemoIngredient(quantity: nil, unit: nil, name: "salt, pepper, bay leaf")
                ],
                steps: [
                    DemoStep(text: "Brown both meats in a heavy pot; transfer to a bowl.", needsTimer: false),
                    DemoStep(text: "Cook soffritto (onion, carrot, celery, garlic) in the rendered fat until very soft, 15 minutes.", needsTimer: true),
                    DemoStep(text: "Add tomato paste; cook until brick-red, 3 minutes.", needsTimer: true),
                    DemoStep(text: "Deglaze with wine; reduce by half.", needsTimer: false),
                    DemoStep(text: "Return meat, crushed tomatoes, milk, and bay leaf. Simmer uncovered 2.5 hours, stirring occasionally.", needsTimer: true),
                    DemoStep(text: "Season to taste. Toss with rigatoni or pappardelle.", needsTimer: false)
                ]
            )
        ],
        "demo-friend-priya": [
            FriendRecipeTemplate(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222201")!,
                title: "Chana Masala",
                summary: "Chickpeas in a spiced tomato gravy. My mother's weeknight version, finished with kasuri methi.",
                servings: 4,
                cookTimeMinutes: 35,
                prepTimeMinutes: 10,
                tags: ["Indian", "Vegetarian", "Dinner"],
                prefaceNote: nil,
                ingredients: [
                    DemoIngredient(quantity: "2", unit: "cans", name: "chickpeas, drained"),
                    DemoIngredient(quantity: "1", unit: nil, name: "yellow onion, finely chopped"),
                    DemoIngredient(quantity: "2", unit: nil, name: "tomatoes, pureed"),
                    DemoIngredient(quantity: "1", unit: "tbsp", name: "ginger-garlic paste"),
                    DemoIngredient(quantity: "2", unit: "tsp", name: "garam masala"),
                    DemoIngredient(quantity: "1", unit: "tsp", name: "cumin"),
                    DemoIngredient(quantity: "1", unit: "tsp", name: "coriander"),
                    DemoIngredient(quantity: "1/2", unit: "tsp", name: "turmeric"),
                    DemoIngredient(quantity: "1/2", unit: "tsp", name: "kashmiri chili powder"),
                    DemoIngredient(quantity: "1", unit: "tsp", name: "kasuri methi, crushed"),
                    DemoIngredient(quantity: "2", unit: "tbsp", name: "ghee or neutral oil"),
                    DemoIngredient(quantity: nil, unit: nil, name: "cilantro, lemon, to finish")
                ],
                steps: [
                    DemoStep(text: "Heat ghee; bloom cumin seeds until they pop.", needsTimer: true),
                    DemoStep(text: "Add onions; cook until deep golden, 10 minutes.", needsTimer: true),
                    DemoStep(text: "Stir in ginger-garlic paste; cook 1 minute.", needsTimer: true),
                    DemoStep(text: "Add pureed tomatoes and all dry spices. Cook until oil separates, 8 minutes.", needsTimer: true),
                    DemoStep(text: "Add chickpeas and 1 cup water. Simmer 15 minutes, mashing some chickpeas to thicken.", needsTimer: true),
                    DemoStep(text: "Crush kasuri methi between your palms and stir in. Finish with cilantro and a squeeze of lemon.", needsTimer: false)
                ]
            ),
            FriendRecipeTemplate(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222202")!,
                title: "Mango Lassi",
                summary: "Cold, creamy, lightly cardamomed. The best fix for a too-spicy meal.",
                servings: 2,
                cookTimeMinutes: nil,
                prepTimeMinutes: 5,
                tags: ["Indian", "Drink", "Quick"],
                prefaceNote: nil,
                ingredients: [
                    DemoIngredient(quantity: "1", unit: "cup", name: "ripe mango pulp (Alphonso if you can)"),
                    DemoIngredient(quantity: "1", unit: "cup", name: "full-fat yogurt"),
                    DemoIngredient(quantity: "1/4", unit: "cup", name: "whole milk"),
                    DemoIngredient(quantity: "2", unit: "tbsp", name: "sugar (to taste)"),
                    DemoIngredient(quantity: "1", unit: "pinch", name: "cardamom"),
                    DemoIngredient(quantity: nil, unit: nil, name: "ice, to serve")
                ],
                steps: [
                    DemoStep(text: "Blend everything except ice until completely smooth.", needsTimer: false),
                    DemoStep(text: "Pour over ice. Garnish with a pinch more cardamom if you like.", needsTimer: false)
                ]
            ),
            FriendRecipeTemplate(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222203")!,
                title: "Jeera Rice",
                summary: "Fragrant basmati with toasted cumin — the perfect bed for any curry.",
                servings: 4,
                cookTimeMinutes: 20,
                prepTimeMinutes: 5,
                tags: ["Indian", "Side", "Rice"],
                prefaceNote: "Rinse the basmati until the water runs clear — this is what gives you separate, fluffy grains.",
                ingredients: [
                    DemoIngredient(quantity: "1", unit: "cup", name: "basmati rice"),
                    DemoIngredient(quantity: "1.75", unit: "cups", name: "water"),
                    DemoIngredient(quantity: "1", unit: "tbsp", name: "ghee"),
                    DemoIngredient(quantity: "1", unit: "tsp", name: "cumin seeds"),
                    DemoIngredient(quantity: "1", unit: nil, name: "bay leaf"),
                    DemoIngredient(quantity: nil, unit: nil, name: "salt, to taste")
                ],
                steps: [
                    DemoStep(text: "Rinse rice in cool water until it runs clear, then soak 20 minutes.", needsTimer: true),
                    DemoStep(text: "Heat ghee in a saucepan; bloom cumin and bay leaf until fragrant.", needsTimer: true),
                    DemoStep(text: "Drain rice; add to pan and toast 1 minute.", needsTimer: true),
                    DemoStep(text: "Add water and salt. Bring to a boil, cover, reduce to low.", needsTimer: false),
                    DemoStep(text: "Cook 12 minutes. Rest off heat 5 minutes before fluffing.", needsTimer: true)
                ]
            )
        ],
        "demo-friend-jules": [
            FriendRecipeTemplate(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333301")!,
                title: "Sourdough Boule",
                summary: "A patient overnight bulk, cold retard, and high-heat bake in a Dutch oven.",
                servings: 1,
                cookTimeMinutes: 45,
                prepTimeMinutes: 60,
                tags: ["Baking", "Bread", "Sourdough"],
                prefaceNote: "If your starter doubled in 4–6 hours after the last feed, it's ready.",
                ingredients: [
                    DemoIngredient(quantity: "500", unit: "g", name: "bread flour"),
                    DemoIngredient(quantity: "375", unit: "g", name: "water (75%)"),
                    DemoIngredient(quantity: "100", unit: "g", name: "active starter"),
                    DemoIngredient(quantity: "10", unit: "g", name: "fine sea salt")
                ],
                steps: [
                    DemoStep(text: "Mix flour and water; rest 1 hour (autolyse).", needsTimer: true),
                    DemoStep(text: "Add starter and salt; pinch and fold until incorporated.", needsTimer: false),
                    DemoStep(text: "Bulk ferment 4–6 hours at 75°F with 4 sets of stretch-and-folds every 30 minutes.", needsTimer: true),
                    DemoStep(text: "Pre-shape into a round; rest 20 minutes.", needsTimer: true),
                    DemoStep(text: "Final shape; place seam-up in a floured banneton.", needsTimer: false),
                    DemoStep(text: "Cold retard in the fridge 12–16 hours.", needsTimer: false),
                    DemoStep(text: "Preheat Dutch oven at 500°F for 45 minutes.", needsTimer: true),
                    DemoStep(text: "Score the dough; bake covered 20 minutes, then uncovered at 450°F for 25 minutes.", needsTimer: true),
                    DemoStep(text: "Cool on a rack at least 1 hour before slicing.", needsTimer: true)
                ]
            ),
            FriendRecipeTemplate(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333302")!,
                title: "Olive Oil Focaccia",
                summary: "Pillowy, dimpled, drenched in good oil and flaky salt.",
                servings: 8,
                cookTimeMinutes: 25,
                prepTimeMinutes: 30,
                tags: ["Baking", "Bread", "Italian"],
                prefaceNote: nil,
                ingredients: [
                    DemoIngredient(quantity: "500", unit: "g", name: "bread flour"),
                    DemoIngredient(quantity: "400", unit: "g", name: "water"),
                    DemoIngredient(quantity: "10", unit: "g", name: "fine sea salt"),
                    DemoIngredient(quantity: "5", unit: "g", name: "instant yeast"),
                    DemoIngredient(quantity: nil, unit: nil, name: "olive oil, generous"),
                    DemoIngredient(quantity: nil, unit: nil, name: "flaky salt, rosemary")
                ],
                steps: [
                    DemoStep(text: "Whisk flour, water, salt, and yeast; cover and rest at room temp 4 hours, doing 2 sets of stretch-and-folds in the first hour.", needsTimer: true),
                    DemoStep(text: "Pour generous olive oil into a 9x13 pan. Transfer the dough; coat in oil.", needsTimer: false),
                    DemoStep(text: "Cover and proof in the fridge overnight.", needsTimer: false),
                    DemoStep(text: "Let come to room temp 1 hour. Dimple aggressively with oiled fingers.", needsTimer: true),
                    DemoStep(text: "Scatter rosemary and flaky salt.", needsTimer: false),
                    DemoStep(text: "Bake at 450°F for 22–25 minutes until deeply golden.", needsTimer: true)
                ]
            )
        ]
    ]
}
