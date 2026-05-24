import Foundation
import os

/// "Your Llama" — a synthetic, local-only friend that ships with every
/// fresh install. Renders alongside real CloudKit friends in the
/// Friends tab so a brand-new user has somewhere to browse and import
/// from on day one, with zero network dependency and no 24/7 backend
/// account to maintain.
///
/// **What's synthetic about it.** The `UserProfileSnapshot` carries a
/// sentinel `userRecordName` (`SeedFriend.sentinelRecordName`) that
/// never appears in CloudKit, so every social code path that fans out
/// to the network — `fetchPublishedRecipeSummaries`, `fetchPublishedRecipe`,
/// `writeRecipeImport`, the `Friendship` delete cascade, the friend-
/// presence push subscriptions — can short-circuit on it as a single
/// check (`isSeed(_:)`).
///
/// **What's not synthetic.** The recipes the seed friend "owns" are
/// real `LCRecipeShareV1` envelopes built from
/// `Resources/SeedRecipes.json` at first access and cached for the
/// process lifetime. They flow through the same
/// `RecipeShare.materializeFromPublished` import path as any other
/// friend recipe, so chain-attribution stamping ("Originally shared
/// by Your Llama"), duplicate-title resolution, the llama progress
/// overlay, and the post-import toast all work identically.
///
/// **Counts toward the social threshold.** `FriendsStore` keeps the
/// seed friend at the head of `friends` regardless of refresh /
/// sign-out state, which means `friends.count` is never zero — the
/// Friends-tab grid always has at least one card and the dedicated
/// "looking for a friend?" empty state is no longer reachable.
/// Brand-new users start at 1/3 toward `isBelowSocialThreshold`,
/// which surfaces (4 ➝) wherever the app still nudges toward
/// adding more people.
enum SeedFriend {
    /// Stable record-name sentinel for the seed friend. Chosen to
    /// look obviously local (kebab-case ASCII, no UUID, no `profile_`
    /// prefix) so a future log diff between a CloudKit query and the
    /// in-memory friends list reads cleanly. Used both as the
    /// `UserProfileSnapshot.userRecordName` and as the
    /// `originalCreatorUserRecordName` stamped onto imported recipes
    /// — there's no real iCloud user record behind it, but the
    /// downstream attribution chain doesn't need one to render
    /// "Originally shared by Your Llama."
    static let sentinelRecordName = "your-llama-seed"

    /// Display name. Surfaced in the friends-tab card title, the
    /// FriendLibraryView nav title ("Your Llama's Cookbook"), and as
    /// `originalCreatorDisplayName` on every imported seed recipe.
    static let displayName = "Your Llama"

    static let accentHex = "#C97C5D"

    /// Predicate every CloudKit-touching call site uses to skip a
    /// network round-trip when the target is the seed friend. Kept as
    /// a tiny helper rather than inlined so a future rename of the
    /// sentinel only touches one place.
    static func isSeed(_ friend: UserProfileSnapshot) -> Bool {
        friend.userRecordName == sentinelRecordName
    }

    /// Synthetic profile snapshot used everywhere a real
    /// `UserProfileSnapshot` would be. `createdAt` is a fixed
    /// reference date (not `.now`) so the snapshot is stable across
    /// re-creations within a session — Hashable equality stays
    /// invariant, which matters for `NavigationLink(value:)` routing
    /// and `friendsStore.friends` diffing.
    static let profile: UserProfileSnapshot = {
        // 2026-01-01 — arbitrary, just needs to be stable across
        // calls. The value isn't shown anywhere; it's only used by
        // Hashable / Equatable conformance derived from the struct's
        // stored properties.
        let reference = Date(timeIntervalSince1970: 1_767_225_600)
        return UserProfileSnapshot(
            userRecordName: sentinelRecordName,
            displayName: displayName,
            accentHex: accentHex,
            createdAt: reference,
            lastCookedAt: nil,
            lastCookedRecipeID: nil,
            lastCookedTitle: nil,
            cookingStartedAt: nil
        )
    }()

    // MARK: - Library

    /// Card-list payload for `FriendLibraryView`. Built from the
    /// cached envelope set on first call, then memoized for the
    /// process lifetime — the seed JSON ships in the app bundle and
    /// never changes between launches, so re-decoding it on every
    /// `.task` would be pure waste.
    static func librarySummaries() -> [PublishedRecipeSummary] {
        cachedSummaries
    }

    /// Full envelope payload for `FriendRecipeDetailView`, addressed
    /// by the same `recordName` the summary published. Returns nil
    /// when the recordName doesn't match a seed recipe — that's not
    /// a valid runtime state given the summaries are the only source
    /// of `recordName`s passed into detail, but the optional gives
    /// the call site a clean fallback path instead of a force-unwrap.
    static func detail(forRecordName recordName: String) -> PublishedRecipeDetail? {
        cachedDetails[recordName]
    }

    // MARK: - Cache

    /// One-time decode of the bundled JSON into the wire envelopes
    /// every consumer reads through. Storing both summaries and
    /// details in parallel dicts avoids walking the envelope list on
    /// every detail tap.
    private static let cachedPayload: SeedPayload = {
        loadPayload()
    }()

    private static let cachedSummaries: [PublishedRecipeSummary] = {
        // Alphabetical by title (case-insensitive, locale-aware) so the
        // seed cookbook grid reads like a sorted recipe book rather than
        // arbitrary JSON order. Real friends' libraries are server-sorted
        // by updatedAt — the seed friend's reference timestamp is
        // identical across all recipes, so without an explicit sort the
        // displayed order would be undefined.
        cachedPayload.recipes
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { seed in
                PublishedRecipeSummary(
                    recordName: seed.id.uuidString,
                    ownerID: sentinelRecordName,
                    localRecipeID: seed.id,
                    recipeTitle: seed.title,
                    updatedAt: cachedPayload.referenceDate,
                    summary: seed.summary,
                    tags: seed.tags,
                    // Same JPEG that ships as the recipe-level hero photo
                    // — `RecipeImageView` decodes off-main on display, so
                    // a 1600px source is fine for the friend-library grid
                    // thumbnail. Without this, the seed cards fall through
                    // to the photo-glyph placeholder and the seed cookbook
                    // reads as empty on a fresh install.
                    thumbnailData: loadHeroPhoto(seed.heroPhoto)
                )
            }
    }()

    private static let cachedDetails: [String: PublishedRecipeDetail] = {
        var result: [String: PublishedRecipeDetail] = [:]
        for seed in cachedPayload.recipes {
            // Bundled hero photo, base64-encoded into a single recipe-
            // level `SharePhoto`. Missing files are skipped silently —
            // the recipe still materializes, just without a gallery
            // photo. Same degrade-don't-crash contract as `loadPayload`.
            let envelopePhotos: [LCRecipeShareV1.SharePhoto]
            if let heroData = loadHeroPhoto(seed.heroPhoto) {
                envelopePhotos = [
                    LCRecipeShareV1.SharePhoto(
                        id: UUID(),
                        order: 0,
                        caption: nil,
                        image: heroData.base64EncodedString()
                    )
                ]
            } else {
                envelopePhotos = []
            }
            let envelope = LCRecipeShareV1(
                schemaVersion: RecipeShare.currentVersion,
                share: LCRecipeShareV1.ShareEnvelope(
                    id: seed.id,
                    createdAt: cachedPayload.referenceDate,
                    sharedBy: displayName,
                    sourceRecipeID: seed.id,
                    appVersion: AppMetadata.currentAppVersion,
                    originalCreatorID: sentinelRecordName,
                    originalRecipeID: seed.id.uuidString
                ),
                recipe: LCRecipeShareV1.ShareRecipe(
                    id: seed.id,
                    title: seed.title,
                    summary: seed.summary,
                    sourceUrl: nil,
                    servings: seed.servings,
                    cookTimeMinutes: seed.cookTimeMinutes,
                    prepTimeMinutes: seed.prepTimeMinutes,
                    notes: "",
                    tags: seed.tags,
                    prefaceNote: seed.prefaceNote,
                    epilogueNote: seed.epilogueNote,
                    generalNote: nil,
                    ingredients: seed.ingredients.map { ing in
                        LCRecipeShareV1.ShareIngredient(
                            id: UUID(),
                            quantity: emptyToNil(ing.quantity),
                            unit: emptyToNil(ing.unit),
                            name: ing.name,
                            order: ing.order
                        )
                    },
                    steps: seed.steps.map { step in
                        LCRecipeShareV1.ShareStep(
                            id: UUID(),
                            order: step.order,
                            text: step.text,
                            needsTimer: step.needsTimer,
                            specialNote: nil,
                            photos: []
                        )
                    },
                    photos: envelopePhotos
                )
            )
            result[seed.id.uuidString] = PublishedRecipeDetail(
                envelope: envelope,
                originalCreatorID: sentinelRecordName,
                originalRecipeID: seed.id.uuidString
            )
        }
        return result
    }()

    // MARK: - JSON decode

    private static let log = Logger(subsystem: "com.llamascookbook.app", category: "SeedFriend")

    /// Stable reference timestamp for everything the seed friend
    /// exposes — published-at, envelope createdAt, updatedAt — so the
    /// cards render the same "Updated" line on every install rather
    /// than drifting around with `.now`. 2026-01-01.
    private static let referenceDate = Date(timeIntervalSince1970: 1_767_225_600)

    /// Decode the bundled JSON. A missing or malformed payload at
    /// runtime is a developer bug (the file ships in the app binary
    /// and is validated at build time), but crashing on launch is
    /// worse than degrading: every user would lose the entire app
    /// over a single missing resource. We log loudly and fall back
    /// to an empty seed cookbook so the rest of the app stays usable.
    private static func loadPayload() -> SeedPayload {
        guard let url = Bundle.main.url(forResource: "SeedRecipes", withExtension: "json") else {
            log.error("SeedRecipes.json missing from app bundle — check project.yml sources. Returning empty seed payload.")
            return SeedPayload(recipes: [], referenceDate: referenceDate)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let envelope = try decoder.decode(SeedJSONEnvelope.self, from: data)
            return SeedPayload(
                recipes: envelope.recipes.compactMap { dto in
                    guard let uuid = dto.resolvedUUID else {
                        log.error("SeedRecipes.json: skipping recipe with invalid UUID \(dto.id, privacy: .public)")
                        return nil
                    }
                    return SeedRecipe(
                        id: uuid,
                        title: dto.title,
                        summary: dto.summary,
                        servings: dto.servings,
                        prepTimeMinutes: dto.prepTimeMinutes,
                        cookTimeMinutes: dto.cookTimeMinutes,
                        tags: dto.tags,
                        prefaceNote: dto.prefaceNote,
                        epilogueNote: dto.epilogueNote,
                        heroPhoto: dto.heroPhoto,
                        ingredients: dto.ingredients.enumerated().map { (idx, raw) in
                            SeedIngredient(
                                quantity: raw.quantity,
                                unit: raw.unit,
                                name: raw.name,
                                order: idx
                            )
                        },
                        steps: dto.steps.enumerated().map { (idx, raw) in
                            SeedStep(
                                text: raw.text,
                                order: idx,
                                needsTimer: raw.needsTimer ?? false
                            )
                        }
                    )
                },
                referenceDate: referenceDate
            )
        } catch {
            log.error("Failed to decode SeedRecipes.json: \(error.localizedDescription, privacy: .public). Returning empty seed payload.")
            return SeedPayload(recipes: [], referenceDate: referenceDate)
        }
    }

    private static func emptyToNil(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// Loads a bundled hero photo by filename (e.g. `01-hot-honey-chicken.jpg`).
    /// Photos live in `Resources/SeedPhotos/`. Depending on how xcodegen
    /// ingests the directory entry — group (flattened) vs folder
    /// reference (preserved) — the JPEGs end up either at the bundle
    /// root or under a `SeedPhotos/` subdirectory. We try both lookups
    /// so the same code works regardless of which form the project file
    /// ends up with after a `xcodegen generate`. Returns nil for missing
    /// filenames or unreadable files (logged via `os.Logger`) so the
    /// recipe still materializes without a photo rather than crashing
    /// the seed cookbook over a single asset.
    private static func loadHeroPhoto(_ filename: String?) -> Data? {
        guard let filename, !filename.isEmpty else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        let ext  = (filename as NSString).pathExtension
        let url = Bundle.main.url(forResource: stem, withExtension: ext)
                ?? Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "SeedPhotos")
        guard let url else {
            log.error("Seed hero photo missing from bundle: \(filename, privacy: .public) — has `xcodegen generate` been run since SeedPhotos/ was added?")
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            log.error("Failed to load seed hero photo \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Decode types

/// Internal in-memory model after the JSON file has been parsed.
/// Distinct from the wire envelope so the decode shape can stay
/// terse (no `id` or `order` on ingredients/steps in the JSON — we
/// fill those in here).
private struct SeedPayload {
    let recipes: [SeedRecipe]
    let referenceDate: Date
}

private struct SeedRecipe {
    let id: UUID
    let title: String
    let summary: String?
    let servings: Int?
    let prepTimeMinutes: Int?
    let cookTimeMinutes: Int?
    let tags: [String]
    let prefaceNote: String?
    let epilogueNote: String?
    /// Bundled hero photo filename (e.g. `01-hot-honey-chicken.jpg`),
    /// resolved against `Resources/SeedPhotos/` at envelope-build time.
    /// Nil leaves the recipe photoless — same render path as before
    /// hero photos shipped.
    let heroPhoto: String?
    let ingredients: [SeedIngredient]
    let steps: [SeedStep]
}

private struct SeedIngredient {
    let quantity: String?
    let unit: String?
    let name: String
    let order: Int
}

private struct SeedStep {
    let text: String
    let order: Int
    let needsTimer: Bool
}

/// Wire shape matching `Resources/SeedRecipes.json` exactly. The
/// `id` field is a UUID string in the JSON; we decode to String here
/// and resolve to UUID once via `uuid` so a malformed seed id throws
/// at startup with a clean message instead of mid-render.
private struct SeedJSONEnvelope: Decodable {
    let recipes: [SeedJSONRecipe]
}

private struct SeedJSONRecipe: Decodable {
    let id: String
    let title: String
    let summary: String?
    let servings: Int?
    let prepTimeMinutes: Int?
    let cookTimeMinutes: Int?
    let tags: [String]
    let prefaceNote: String?
    let epilogueNote: String?
    /// Bundled hero photo filename — optional + `decodeIfPresent` so a
    /// photoless seed entry (or a future test fixture) still decodes.
    let heroPhoto: String?
    let ingredients: [SeedJSONIngredient]
    let steps: [SeedJSONStep]

    /// Optional UUID for graceful skip-on-bad-id behavior in
    /// `loadPayload`. Never force-unwrap — a malformed seed UUID
    /// should drop one recipe, not crash the app.
    var resolvedUUID: UUID? {
        UUID(uuidString: id)
    }
}

private struct SeedJSONIngredient: Decodable {
    let quantity: String?
    let unit: String?
    let name: String
}

private struct SeedJSONStep: Decodable {
    let text: String
    let needsTimer: Bool?
}
