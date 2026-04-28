import Foundation
import SwiftData
import UniformTypeIdentifiers

/// `.llamarecipe` UTType. **Must stay in sync with the
/// `UTExportedTypeDeclarations` entry in `Resources/AppInfo.plist`** —
/// a typo here means iOS silently fails to register the type and
/// AirDrop / Files / Mail handoffs land as "Unknown app" with no icon.
extension UTType {
    static var llamaRecipe: UTType {
        UTType(exportedAs: "com.llamascookbook.recipe")
    }
}

// MARK: - LCRecipeShareV1

/// Wire format for app-to-app recipe sharing — the same JSON envelope
/// is written to a `.llamarecipe` file (UTType `com.llamascookbook.recipe`)
/// or base64url-encoded into a `llamascookbook://recipe/v1/<...>` deep
/// link. Schema is intentionally independent of SwiftData so a future
/// cloud transport can accept the same payload byte-for-byte.
///
/// Versioning rules:
/// - Always serialize with `RecipeShare.currentVersion`.
/// - On decode, an unknown version surfaces a friendly
///   `unsupportedSchemaVersion` error rather than crashing or silently
///   dropping fields.
/// - When v2 ships, this type stays as-is and a parallel
///   `LCRecipeShareV2` is added; the decoder picks based on the value.
///
/// See Recipe-Sharing.md §3 for the full field-by-field rationale.
struct LCRecipeShareV1: Codable {
    let schemaVersion: Int
    let share: ShareEnvelope
    let recipe: ShareRecipe

    struct ShareEnvelope: Codable {
        /// Unique to this share envelope, not to the recipe. Future
        /// re-import detection keys on this so duplicate-envelope and
        /// duplicate-recipe stay distinguishable.
        let id: UUID
        /// Sender's clock at the moment they hit Share.
        let createdAt: Date
        /// Display name from the sender's `OwnerProfile`. May be nil.
        let sharedBy: String?
        /// The original `Recipe.id` on the sender's device at share
        /// time. NOT the same as `recipe.id` on the receiver — every
        /// UUID gets rewritten at materialize, this one's preserved
        /// only for future re-import dedup.
        let sourceRecipeID: UUID
        /// Sender's `CFBundleShortVersionString`. Surfaced on
        /// import-time errors so the user knows how stale the sender
        /// is.
        let appVersion: String
    }

    struct ShareRecipe: Codable {
        let id: UUID
        let title: String
        let summary: String?
        let sourceUrl: String?
        let servings: Int?
        let cookTimeMinutes: Int?
        let notes: String
        let tags: [String]
        let prefaceNote: String?
        let epilogueNote: String?
        let generalNote: String?
        let ingredients: [ShareIngredient]
        let steps: [ShareStep]
        /// Recipe-level gallery photos. Per-step photos hang off
        /// `ShareStep.photos`.
        let photos: [SharePhoto]
    }

    struct ShareIngredient: Codable {
        let id: UUID
        let quantity: String?
        let unit: String?
        let name: String
        let order: Int
    }

    struct ShareStep: Codable {
        let id: UUID
        let order: Int
        let text: String
        let needsTimer: Bool
        let specialNote: String?
        /// Per-step gallery photos. Up to 3 enforced at the editor
        /// layer; the decoder accepts up to whatever the sender
        /// emitted (forward-compat for raising the cap).
        let photos: [SharePhoto]
    }

    struct SharePhoto: Codable {
        let id: UUID
        let order: Int
        let caption: String?
        /// JPEG / HEIC bytes, base64-encoded. Sender does NOT re-run
        /// `ImageProcessing.prepare` (storage bytes are already at
        /// target size); receiver DOES re-run on materialize so output
        /// matches the receiver's storage budget.
        let image: String
    }
}

/// Drives `.sheet(item:)` on `RootView` for the import preview —
/// `share.id` is a fresh UUID per envelope, so two back-to-back
/// imports don't collapse into one sheet. Conformance is read-only
/// from a property; keeps the Codable wire shape unchanged.
extension LCRecipeShareV1: Identifiable {
    var id: UUID { share.id }
}

// MARK: - RecipeShare

/// Encode / decode / materialize entry points for the share envelope.
/// Stateless. All callers (sender's `Transferable`, receiver's
/// `onOpenURL` branches, future cloud transport) route through here.
enum RecipeShare {
    static let currentVersion = 1

    /// URL-form payload size ceiling — past this we refuse to mint a
    /// `llamascookbook://recipe/v1/<...>` URL and fall back to the
    /// file form. ~6000 chars keeps us clear of practical clipboard /
    /// SMS transport limits while leaving headroom for chat-app
    /// surrounding metadata (link previews etc.).
    static let urlByteCeiling = 6000

    enum Error: Swift.Error, LocalizedError {
        case unsupportedSchemaVersion(Int)
        case decodeFailure(underlying: Swift.Error)
        case payloadTooLargeForURL(bytes: Int)
        case malformedShareURL

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let v):
                return "This recipe was shared from a newer version of Llamas Cookbook (schema v\(v)). Update the app to import it."
            case .decodeFailure(let err):
                return "Couldn't read this recipe share: \(err.localizedDescription)"
            case .payloadTooLargeForURL(let bytes):
                return "This recipe is too large to share as a link (\(bytes) bytes). Share it as a file instead."
            case .malformedShareURL:
                return "This share link is malformed."
            }
        }
    }

    // MARK: - Encode

    /// Builds a v1 envelope from a live SwiftData `Recipe`. Pulls bytes
    /// through the existing relationships in canonical order and
    /// stamps the sender's display name from `OwnerProfile.userName`
    /// (caller passes it as `sharedBy` so this layer stays free of
    /// UserDefaults coupling).
    static func envelope(
        for recipe: Recipe,
        sharedBy: String?,
        appVersion: String
    ) -> LCRecipeShareV1 {
        let ingredients = recipe.sortedIngredients.map { ing in
            LCRecipeShareV1.ShareIngredient(
                id: ing.id,
                quantity: ing.quantity,
                unit: ing.unit,
                name: ing.name,
                order: ing.order
            )
        }

        let steps = recipe.sortedSteps.map { step in
            LCRecipeShareV1.ShareStep(
                id: step.id,
                order: step.order,
                text: step.text,
                needsTimer: step.needsTimer,
                specialNote: step.specialNote,
                photos: step.sortedStepPhotos.compactMap { photo -> LCRecipeShareV1.SharePhoto? in
                    guard let data = photo.image else { return nil }
                    return LCRecipeShareV1.SharePhoto(
                        id: photo.id,
                        order: photo.order,
                        caption: photo.caption,
                        image: data.base64EncodedString()
                    )
                }
            )
        }

        let photos = recipe.sortedPhotos.compactMap { photo -> LCRecipeShareV1.SharePhoto? in
            guard let data = photo.image else { return nil }
            return LCRecipeShareV1.SharePhoto(
                id: photo.id,
                order: photo.order,
                caption: photo.caption,
                image: data.base64EncodedString()
            )
        }

        return LCRecipeShareV1(
            schemaVersion: currentVersion,
            share: LCRecipeShareV1.ShareEnvelope(
                id: UUID(),
                createdAt: .now,
                sharedBy: sharedBy,
                sourceRecipeID: recipe.id,
                appVersion: appVersion
            ),
            recipe: LCRecipeShareV1.ShareRecipe(
                id: recipe.id,
                title: recipe.title,
                summary: recipe.summary,
                sourceUrl: recipe.sourceUrl,
                servings: recipe.servings,
                cookTimeMinutes: recipe.cookTimeMinutes,
                notes: recipe.notes,
                tags: recipe.tags,
                prefaceNote: recipe.prefaceNote,
                epilogueNote: recipe.epilogueNote,
                generalNote: recipe.generalNote,
                ingredients: ingredients,
                steps: steps,
                photos: photos
            )
        )
    }

    static func encodeFile(_ envelope: LCRecipeShareV1) throws -> Data {
        try makeEncoder().encode(envelope)
    }

    /// Builds the URL form. Throws `payloadTooLargeForURL` if the
    /// resulting URL exceeds `urlByteCeiling` — caller (the sender's
    /// share menu) decides whether to fall back to file or hide the
    /// "Share as link" option.
    static func encodeURL(_ envelope: LCRecipeShareV1) throws -> URL {
        let json = try makeEncoder().encode(envelope)
        let b64url = json.base64URLEncodedString()
        guard let url = URL(string: "llamascookbook://recipe/v\(currentVersion)/\(b64url)") else {
            throw Error.malformedShareURL
        }
        let length = url.absoluteString.utf8.count
        guard length <= urlByteCeiling else {
            throw Error.payloadTooLargeForURL(bytes: length)
        }
        return url
    }

    // MARK: - Decode

    static func decode(fileData: Data) throws -> LCRecipeShareV1 {
        // Peek schemaVersion first so a future v2 surfaces the
        // friendly "needs newer version" error instead of a generic
        // decodeFailure with garbled key paths.
        let probe: SchemaProbe
        do {
            probe = try makeDecoder().decode(SchemaProbe.self, from: fileData)
        } catch {
            throw Error.decodeFailure(underlying: error)
        }
        guard probe.schemaVersion == currentVersion else {
            throw Error.unsupportedSchemaVersion(probe.schemaVersion)
        }
        do {
            return try makeDecoder().decode(LCRecipeShareV1.self, from: fileData)
        } catch {
            throw Error.decodeFailure(underlying: error)
        }
    }

    /// Parses `llamascookbook://recipe/v1/<base64url>`. Returns nil for
    /// any other scheme/host so the existing cook deep-link branch in
    /// `RootView.onOpenURL` can match its own shape without overlap.
    static func decode(url: URL) throws -> LCRecipeShareV1? {
        guard url.scheme == "llamascookbook", url.host == "recipe" else {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        // Expect `/v<N>/<base64url>` — exactly two path components.
        guard parts.count == 2 else {
            throw Error.malformedShareURL
        }
        let versionTag = parts[0]
        guard versionTag.hasPrefix("v"), let version = Int(versionTag.dropFirst()) else {
            throw Error.malformedShareURL
        }
        guard version == currentVersion else {
            throw Error.unsupportedSchemaVersion(version)
        }
        guard let data = Data(base64URLEncoded: parts[1]) else {
            throw Error.malformedShareURL
        }
        return try decode(fileData: data)
    }

    // MARK: - Materialize

    /// Creates a fresh `Recipe` (+ children) inside `context` from a
    /// decoded envelope. Three jobs:
    ///
    /// 1. **Rewrite UUIDs** — every `Recipe`/`Ingredient`/`RecipeStep`/
    ///    `RecipePhoto`/`RecipeStepPhoto` gets a fresh UUID via its
    ///    `init`, so two users can re-import the same share without
    ///    colliding on the original sender's IDs.
    /// 2. **Stamp provenance** — `sharedBy`, `sharedAt`,
    ///    `sourceShareID` are set once here. `Recipe.apply(_:)` (the
    ///    editor save path) intentionally leaves these alone so they
    ///    survive local edits.
    /// 3. **Resolve title collisions** — see `resolveImportTitle`.
    ///
    /// Photos go through `ImageProcessing.prepare(_:for:)` again on
    /// the receiver side so output matches the receiver's storage
    /// budget regardless of what the sender's build emitted. The
    /// bytes-guard inside `ImageProcessing` keeps already-tight bytes
    /// from double-degrading.
    @MainActor
    static func materialize(
        _ envelope: LCRecipeShareV1,
        into context: ModelContext
    ) async -> Recipe {
        let resolvedTitle = resolveImportTitle(
            base: envelope.recipe.title,
            in: context
        )

        let recipe = Recipe(
            title: resolvedTitle,
            summary: envelope.recipe.summary,
            sourceUrl: envelope.recipe.sourceUrl,
            servings: envelope.recipe.servings,
            cookTimeMinutes: envelope.recipe.cookTimeMinutes,
            notes: envelope.recipe.notes,
            favorite: false,
            tags: envelope.recipe.tags
        )
        recipe.prefaceNote   = envelope.recipe.prefaceNote
        recipe.epilogueNote  = envelope.recipe.epilogueNote
        recipe.generalNote   = envelope.recipe.generalNote

        recipe.sharedBy      = envelope.share.sharedBy
        recipe.sharedAt      = .now
        recipe.sourceShareID = envelope.share.sourceRecipeID

        context.insert(recipe)

        for ing in envelope.recipe.ingredients.sorted(by: { $0.order < $1.order }) {
            recipe.ingredients.append(Ingredient(
                quantity: ing.quantity,
                unit: ing.unit,
                name: ing.name,
                order: ing.order
            ))
        }

        for step in envelope.recipe.steps.sorted(by: { $0.order < $1.order }) {
            let local = RecipeStep(
                text: step.text,
                order: step.order,
                needsTimer: step.needsTimer,
                specialNote: step.specialNote
            )
            recipe.steps.append(local)
            for photo in step.photos.sorted(by: { $0.order < $1.order }) {
                guard let raw = Data(base64Encoded: photo.image) else { continue }
                let processed = await ImageProcessing.prepare(raw, for: .step) ?? raw
                local.photos.append(RecipeStepPhoto(
                    image: processed,
                    caption: photo.caption,
                    order: photo.order
                ))
            }
        }

        for photo in envelope.recipe.photos.sorted(by: { $0.order < $1.order }) {
            guard let raw = Data(base64Encoded: photo.image) else { continue }
            let processed = await ImageProcessing.prepare(raw, for: .gallery) ?? raw
            recipe.photos.append(RecipePhoto(
                image: processed,
                caption: photo.caption,
                order: photo.order
            ))
        }

        return recipe
    }

    /// Returns either the base title (no collision) or `"{base} (N)"`
    /// where N is the smallest positive integer that doesn't already
    /// match an existing recipe's title. Cookbook is a personal
    /// library (~hundreds of recipes max), so a full fetch + Set
    /// lookup is cheap and avoids SwiftData predicate gymnastics with
    /// `contains` / `starts(with:)`. See Recipe-Sharing.md §6.3 for
    /// edge cases (gap-skipping, sender-already-suffixed, no upper
    /// bound).
    static func resolveImportTitle(
        base: String,
        in context: ModelContext
    ) -> String {
        let allRecipes = (try? context.fetch(FetchDescriptor<Recipe>())) ?? []
        let titles = Set(allRecipes.map(\.title))
        guard titles.contains(base) else { return base }
        var n = 1
        while titles.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    // MARK: - Helpers

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        // Sorted keys keep the file output deterministic — easier to
        // diff during dev and friendlier for any future content-hash
        // dedup.
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }
}

// base64url helpers live in `Sources/Shared/Base64URL.swift` so the
// share extension target can use them too. Importing `Sources/Shared`
// into both targets keeps a single implementation; importing this
// `Lib/` file would drag in SwiftData + `Recipe` references.
