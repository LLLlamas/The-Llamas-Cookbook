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
        /// Chain-root creator's iCloud user record name. Carried so
        /// the recipient can write a `RecipeImport` audit row that
        /// credits the chain root (A's stat ticks even when B
        /// re-shared A's recipe to C). Optional + Codable-defaults
        /// to nil so legacy envelopes already in iMessage threads
        /// round-trip without breakage; the import audit write
        /// silently skips when nil rather than guessing. Sender
        /// populates from `Recipe.originalCreatorUserRecordName` when
        /// present (re-shared chain), otherwise from
        /// `UserProfileMirror.cachedRecordID()` (own-authored).
        let originalCreatorID: String?
        /// Chain-root recipe id (UUID string). Same chain-preservation
        /// reason as `originalCreatorID` — `sourceRecipeID` above is
        /// the *sender's* local id, which diverges from the chain
        /// root after the first re-share hop. Optional for legacy
        /// envelopes; the import audit write falls back to skipping
        /// when nil rather than crediting the wrong recipe.
        let originalRecipeID: String?

        init(
            id: UUID,
            createdAt: Date,
            sharedBy: String?,
            sourceRecipeID: UUID,
            appVersion: String,
            originalCreatorID: String? = nil,
            originalRecipeID: String? = nil
        ) {
            self.id = id
            self.createdAt = createdAt
            self.sharedBy = sharedBy
            self.sourceRecipeID = sourceRecipeID
            self.appVersion = appVersion
            self.originalCreatorID = originalCreatorID
            self.originalRecipeID = originalRecipeID
        }

        // Explicit decode so older envelopes (which lack the chain
        // fields) round-trip cleanly to nil instead of throwing
        // `keyNotFound`. `JSONDecoder` does not auto-default missing
        // keys for non-Optional Codable, and even for Optional fields
        // the safer pattern is `decodeIfPresent` — which is also what
        // matches the "silently skip the audit write" contract above.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id              = try c.decode(UUID.self, forKey: .id)
            createdAt       = try c.decode(Date.self, forKey: .createdAt)
            sharedBy        = try c.decodeIfPresent(String.self, forKey: .sharedBy)
            sourceRecipeID  = try c.decode(UUID.self, forKey: .sourceRecipeID)
            appVersion      = try c.decode(String.self, forKey: .appVersion)
            originalCreatorID = try c.decodeIfPresent(String.self, forKey: .originalCreatorID)
            originalRecipeID  = try c.decodeIfPresent(String.self, forKey: .originalRecipeID)
        }
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

extension LCRecipeShareV1 {
    /// Returns a copy of this envelope with every photo byte stripped
    /// — recipe-level gallery and per-step gallery both empty.
    /// Used by the URL-form share path so a photo-bearing recipe can
    /// still slip under `RecipeShare.urlByteCeiling`; base64-encoded
    /// JPEGs blow past it on a single photo. Receivers see the recipe
    /// with empty photo arrays and can re-add their own. The file form
    /// (`encodeFile`) preserves photos for AirDrop / Files / Mail
    /// when full fidelity matters.
    func withoutPhotos() -> LCRecipeShareV1 {
        let strippedSteps = recipe.steps.map { step in
            ShareStep(
                id: step.id,
                order: step.order,
                text: step.text,
                needsTimer: step.needsTimer,
                specialNote: step.specialNote,
                photos: []
            )
        }
        let strippedRecipe = ShareRecipe(
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
            ingredients: recipe.ingredients,
            steps: strippedSteps,
            photos: []
        )
        return LCRecipeShareV1(
            schemaVersion: schemaVersion,
            share: share,
            recipe: strippedRecipe
        )
    }

    /// Returns a copy of this envelope with every `SharePhoto.image`
    /// replaced by an empty string, but the photo arrays themselves
    /// (and per-photo `id` / `order` / `caption`) preserved. Used by
    /// the cloud-permalink upload path: photo *bytes* travel as
    /// separate `CKAsset` fields on the parent record (no base64
    /// inflation, no JSON-encoding cost), and the receiver walks the
    /// envelope's photo arrays in canonical order to re-inject the
    /// asset bytes during `fetchShare`. Empty `image` strings are the
    /// signal that "the bytes live on a sibling field." Distinct
    /// from `withoutPhotos()` — that drops the photo arrays
    /// entirely, used by the URL-form share where there's no place
    /// to attach assets at all.
    func withClearedPhotoBytes() -> LCRecipeShareV1 {
        let clearedSteps = recipe.steps.map { step in
            ShareStep(
                id: step.id,
                order: step.order,
                text: step.text,
                needsTimer: step.needsTimer,
                specialNote: step.specialNote,
                photos: step.photos.map { p in
                    SharePhoto(id: p.id, order: p.order, caption: p.caption, image: "")
                }
            )
        }
        let clearedPhotos = recipe.photos.map { p in
            SharePhoto(id: p.id, order: p.order, caption: p.caption, image: "")
        }
        let clearedRecipe = ShareRecipe(
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
            ingredients: recipe.ingredients,
            steps: clearedSteps,
            photos: clearedPhotos
        )
        return LCRecipeShareV1(
            schemaVersion: schemaVersion,
            share: share,
            recipe: clearedRecipe
        )
    }

    /// Flattens every photo's bytes (recipe gallery first, then each
    /// step's photos in step order, each in `order` order) into a
    /// single array. The position in this array IS the index used as
    /// the suffix in the CloudKit record's `photo<N>` Asset field.
    /// Pairs with `withClearedPhotoBytes()` on upload and
    /// `injecting(photoBytes:)` on download. Photos that fail to
    /// base64-decode (corrupt sender-side bytes) land as empty
    /// `Data()` so the index sequence stays aligned.
    func flattenedPhotoBytes() -> [Data] {
        var result: [Data] = []
        for p in recipe.photos.sorted(by: { $0.order < $1.order }) {
            result.append(Data(base64Encoded: p.image) ?? Data())
        }
        for step in recipe.steps.sorted(by: { $0.order < $1.order }) {
            for p in step.photos.sorted(by: { $0.order < $1.order }) {
                result.append(Data(base64Encoded: p.image) ?? Data())
            }
        }
        return result
    }

    /// Inverse of `withClearedPhotoBytes()` + `flattenedPhotoBytes()`:
    /// walks the envelope's photo arrays in the same canonical order
    /// (recipe gallery, then each step's photos) and base64-encodes
    /// the matching bytes into each `SharePhoto.image` field.
    /// Bytes shorter than the photo array (= the upload was capped)
    /// leave trailing photos with empty image strings — those render
    /// as missing in `RecipeImportPreviewView` and skip during
    /// `RecipeShare.materialize` (the `Data(base64Encoded:)` guard).
    func injecting(photoBytes: [Data]) -> LCRecipeShareV1 {
        var index = 0
        let injectedRecipePhotos: [SharePhoto] = recipe.photos
            .sorted(by: { $0.order < $1.order })
            .map { p in
                let bytes: Data = index < photoBytes.count ? photoBytes[index] : Data()
                index += 1
                let encoded = bytes.isEmpty ? "" : bytes.base64EncodedString()
                return SharePhoto(id: p.id, order: p.order, caption: p.caption, image: encoded)
            }
        let injectedSteps: [ShareStep] = recipe.steps
            .sorted(by: { $0.order < $1.order })
            .map { step in
                let injectedStepPhotos: [SharePhoto] = step.photos
                    .sorted(by: { $0.order < $1.order })
                    .map { p in
                        let bytes: Data = index < photoBytes.count ? photoBytes[index] : Data()
                        index += 1
                        let encoded = bytes.isEmpty ? "" : bytes.base64EncodedString()
                        return SharePhoto(id: p.id, order: p.order, caption: p.caption, image: encoded)
                    }
                return ShareStep(
                    id: step.id,
                    order: step.order,
                    text: step.text,
                    needsTimer: step.needsTimer,
                    specialNote: step.specialNote,
                    photos: injectedStepPhotos
                )
            }
        let injectedRecipe = ShareRecipe(
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
            ingredients: recipe.ingredients,
            steps: injectedSteps,
            photos: injectedRecipePhotos
        )
        return LCRecipeShareV1(
            schemaVersion: schemaVersion,
            share: share,
            recipe: injectedRecipe
        )
    }
}

// MARK: - RecipeShare

/// Encode / decode / materialize entry points for the share envelope.
/// Stateless. All callers (sender's `Transferable`, receiver's
/// `onOpenURL` branches, future cloud transport) route through here.
enum RecipeShare {
    /// JSON envelope schema version. Lives on the wire inside
    /// `LCRecipeShareV1.schemaVersion` and is the gate for the
    /// `unsupportedSchemaVersion` error. Independent of the URL-form
    /// encoding version below — a single schema can be carried by
    /// multiple URL encodings, and a future schema v2 would also
    /// keep its own URL encoding version stream.
    static let currentVersion = 1

    /// URL-form encoding version. Bumped 2026-04-28 to v2 when we
    /// switched from `base64url(JSON)` to `base64url(lzma(JSON))` —
    /// a typical recipe URL shrinks ~60% (text JSON compresses
    /// extremely well, repeated keys + English vocab). Decoders
    /// accept both:
    ///
    /// - **v1** = `llamascookbook://recipe/v1/<base64url-of-JSON>`
    ///   (legacy; still produced by older app builds and by any test
    ///   links sitting in iMessage history pre-2026-04-28)
    /// - **v2** = `llamascookbook://recipe/v2/<base64url-of-lzma(JSON)>`
    ///   (current default; what `encodeURL` mints)
    ///
    /// Encoder always emits v2. Receiver branches on the path
    /// component before peeking schema version.
    static let currentURLEncodingVersion = 2

    /// URL-form payload size ceiling — past this we refuse to mint a
    /// `llamascookbook://recipe/v<N>/<...>` URL and fall back to the
    /// file form. ~6000 chars keeps us clear of practical clipboard /
    /// SMS transport limits while leaving headroom for chat-app
    /// surrounding metadata (link previews etc.). With v2's lzma
    /// compression most photoless recipes land well under this; the
    /// ceiling exists for the long-form pathological case.
    static let urlByteCeiling = 6000

    /// Hard cap on inbound share payloads, enforced by every decode
    /// path (`decode(fileData:)`, `decode(url:)` post-decompress,
    /// `decode(fileURL:)` pre-read, `CloudKitService.fetchShare`'s
    /// envelope read). 25 MB is generous: a fully-photo'd recipe
    /// envelope (4 gallery + 3 step photos × ~10 steps, each ~150 KB
    /// JPEG) lands at ~5 MB; the cap leaves 5× headroom for unusual
    /// content and still hard-stops a 500 MB attacker-supplied
    /// `.llamarecipe` from OOM-killing the app on lower-end devices.
    /// Also blocks a decompression-bomb attack on the URL form (a
    /// small base64 payload that lzma-expands to gigabytes).
    static let maxInboundBytes = RecipeShareLimits.maxInboundBytes

    /// Hard cap on the sender's display name (`sharedBy` in the
    /// envelope, `senderDisplayName` on the CloudKit record). 40
    /// grapheme clusters fits any real name (the Library of Congress
    /// "longest legal name" stat sits at ~32) and short-circuits two
    /// attacker patterns:
    /// 1. **Layout break** — a 10 KB display name would push every
    ///    consumer of the provenance line off-screen.
    /// 2. **UI spoof** — `"Apple Inc. — VERIFIED ✓"` against an
    ///    unbounded field reads as system trust; capping at 40 keeps
    ///    the field a label, not a banner. Render sites also apply
    ///    `lineLimit(1)`.
    /// Enforced everywhere a display name crosses a trust boundary
    /// (write-time in `UserAccount.updateDisplayName` /
    /// `OwnerProfile`, encode-time in `envelope(...)`, render-time
    /// in the two provenance lines for defense-in-depth against
    /// older-app-version envelopes that didn't enforce on encode).
    static let maxDisplayNameLength = 40

    /// Sanitizes and caps a display name for safe rendering.
    /// 1. Trims surrounding whitespace.
    /// 2. Collapses every whitespace / newline run (including embedded
    ///    `\n`, `\t`, control chars) to a single space — stops a
    ///    sender from smuggling a multi-line spoof inside the 40-char
    ///    budget ("Apple Inc.\n✓ VERIFIED"). Render sites still apply
    ///    `lineLimit(1)` belt-and-suspenders.
    /// 3. Caps to `maxDisplayNameLength` grapheme clusters.
    /// 4. Returns nil for empty input so the call site can use
    ///    `if let` to skip rendering entirely.
    /// Single helper so the six call sites (UserAccount, OwnerProfile,
    /// encode, two render sites, ImportPreview) stay byte-identical.
    static func cappedDisplayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxDisplayNameLength { return collapsed }
        return String(collapsed.prefix(maxDisplayNameLength))
    }

    enum Error: Swift.Error, LocalizedError {
        case unsupportedSchemaVersion(Int)
        case decodeFailure(underlying: Swift.Error)
        case payloadTooLargeForURL(bytes: Int)
        case payloadTooLarge(bytes: Int)
        case malformedShareURL

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let v):
                return "This recipe was shared from a newer version of Llamas Cookbook (schema v\(v)). Update the app to import it."
            case .decodeFailure(let err):
                return "Couldn't read this recipe share: \(err.localizedDescription)"
            case .payloadTooLargeForURL(let bytes):
                return "This recipe is too large to share as a link (\(bytes) bytes). Share it as a file instead."
            case .payloadTooLarge(let bytes):
                return "This recipe share is too large to import (\(bytes) bytes)."
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
    ///
    /// **Chain attribution** is derived here so callers don't have to
    /// know the rules. Two cases:
    /// - Re-shared recipe (sender imported it from someone earlier):
    ///   the local `Recipe` carries `originalCreatorUserRecordName` /
    ///   `originalRecipeID`. Use those — the envelope must credit the
    ///   *chain root*, not the sender, so A→B→C still tallies on A.
    /// - Own-authored recipe: chain fields are nil locally; substitute
    ///   the sender's iCloud user record name + the recipe's local id.
    /// When `UserProfileMirror.cachedRecordID()` returns nil
    /// (signed-out / no iCloud), the envelope ships with
    /// `originalCreatorID == nil` and recipients silently skip the
    /// audit write — same contract as the friend-cookbook flow.
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

        // Resolve chain root. `Recipe.originalCreatorUserRecordName`
        // is set on import (file/link path stamps `sharedBy*` only;
        // friend path stamps the `originalCreator*` fields). When
        // it's set, this is a re-share and we forward as-is. When
        // nil, this is an own-authored recipe and we use the
        // sender's iCloud user record name + local recipe id.
        let chainCreatorID: String?
        let chainRecipeID: String?
        if let importedCreator = recipe.originalCreatorUserRecordName,
           !importedCreator.isEmpty {
            chainCreatorID = importedCreator
            chainRecipeID  = recipe.originalRecipeID ?? recipe.id.uuidString
        } else if let me = UserProfileMirror.cachedRecordID() {
            chainCreatorID = me
            chainRecipeID  = recipe.id.uuidString
        } else {
            chainCreatorID = nil
            chainRecipeID  = nil
        }

        return LCRecipeShareV1(
            schemaVersion: currentVersion,
            share: LCRecipeShareV1.ShareEnvelope(
                id: UUID(),
                createdAt: .now,
                sharedBy: cappedDisplayName(sharedBy),
                sourceRecipeID: recipe.id,
                appVersion: appVersion,
                originalCreatorID: chainCreatorID,
                originalRecipeID: chainRecipeID
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
    ///
    /// Pipeline: JSON-encode → lzma-compress → base64url. lzma is the
    /// best-ratio of `NSData.CompressionAlgorithm` for KB-scale text
    /// (recipe envelopes compress ~60-70%); speed is irrelevant for a
    /// one-shot encode. iOS-only (no Android/web target) so the
    /// non-portable algorithm is fine.
    static func encodeURL(_ envelope: LCRecipeShareV1) throws -> URL {
        let json = try makeEncoder().encode(envelope)
        let compressed: Data
        do {
            compressed = try (json as NSData).compressed(using: .lzma) as Data
        } catch {
            throw Error.decodeFailure(underlying: error)
        }
        let b64url = compressed.base64URLEncodedString()
        guard let url = URL(string: "llamascookbook://recipe/v\(currentURLEncodingVersion)/\(b64url)") else {
            throw Error.malformedShareURL
        }
        let length = url.absoluteString.utf8.count
        guard length <= urlByteCeiling else {
            throw Error.payloadTooLargeForURL(bytes: length)
        }
        return url
    }

    // MARK: - Decode

    /// Single guarded entry point for all inbound share data. Every
    /// caller (file URL, App Group inbox, CloudKit asset, decompressed
    /// URL payload) routes through here so the size cap is enforced
    /// once. Caller-supplied `maxBytes` lets callers tighten for their
    /// own context; the default `maxInboundBytes` is the floor everyone
    /// agrees on.
    static func decode(fileData: Data, maxBytes: Int = maxInboundBytes) throws -> LCRecipeShareV1 {
        guard fileData.count <= maxBytes else {
            throw Error.payloadTooLarge(bytes: fileData.count)
        }
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

    /// File-URL convenience that stat-checks the file size *before*
    /// loading bytes into memory. Without this, a 500 MB
    /// `.llamarecipe` from AirDrop / Files / Mail / share-extension
    /// inbox would be fully read into memory and then rejected by
    /// `decode(fileData:)` — same security outcome, much worse memory
    /// behavior on lower-end devices. `Data(contentsOf:)` itself has
    /// no built-in size cap.
    static func decode(fileURL: URL) throws -> LCRecipeShareV1 {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        if let size = attrs[.size] as? Int, size > maxInboundBytes {
            throw Error.payloadTooLarge(bytes: size)
        }
        let data = try Data(contentsOf: fileURL)
        return try decode(fileData: data)
    }

    /// Parses `llamascookbook://recipe/v<N>/<base64url>`. Returns nil
    /// for any other scheme/host so the existing cook deep-link branch
    /// in `RootView.onOpenURL` can match its own shape without overlap.
    ///
    /// Accepts both:
    /// - **v1**: payload = `base64url(JSON)`. Legacy; emitted by app
    ///   builds before 2026-04-28 and by any test links still sitting
    ///   in iMessage history.
    /// - **v2**: payload = `base64url(lzma(JSON))`. Current encoder.
    ///
    /// The path version is the URL-form encoding version (see
    /// `currentURLEncodingVersion`), which is independent of the JSON
    /// envelope's `schemaVersion`. Both are checked: path version
    /// gates the decompression step; envelope schema version gates the
    /// "you need a newer app" error.
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
        guard versionTag.hasPrefix("v"), let urlVersion = Int(versionTag.dropFirst()) else {
            throw Error.malformedShareURL
        }
        guard let raw = Data(base64URLEncoded: parts[1]) else {
            throw Error.malformedShareURL
        }
        // Pre-decompress cap on the base64-decoded blob — stops an
        // attacker from constructing a small URL whose payload alone
        // is gigabytes (would never lzma-expand smaller than its input,
        // so this is a safe upper bound).
        guard raw.count <= maxInboundBytes else {
            throw Error.payloadTooLarge(bytes: raw.count)
        }
        let json: Data
        switch urlVersion {
        case 1:
            json = raw
        case 2:
            do {
                json = try (raw as NSData).decompressed(using: .lzma) as Data
            } catch {
                throw Error.decodeFailure(underlying: error)
            }
        default:
            // Unknown URL encoding version — sender is on a newer app
            // build than us. Reuse the schema-version error since the
            // user-facing remediation is the same ("update the app").
            throw Error.unsupportedSchemaVersion(urlVersion)
        }
        // Post-decompress cap — lzma is the canonical decompression-
        // bomb vector (small input, huge output). Belt-and-suspenders
        // against a hostile sender even though the pre-decompress cap
        // already guards the upstream byte count.
        return try decode(fileData: json)
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
    ///
    /// `overrideTitle` is the explicit title chosen at the import
    /// preview's duplicate-confirmation prompt — when the user keeps a
    /// custom name (or accepts the auto-suggested "(N)" placeholder)
    /// for a duplicate-title import. When nil, the original silent
    /// `resolveImportTitle` collision-resolution still applies, so
    /// existing call sites and the no-collision happy path are
    /// unchanged.
    @MainActor
    static func materialize(
        _ envelope: LCRecipeShareV1,
        into context: ModelContext,
        overrideTitle: String? = nil
    ) async -> Recipe {
        let recipe = await createLocalRecipe(
            from: envelope,
            into: context,
            overrideTitle: overrideTitle
        )

        // File/link share attribution. Stamped here (not in the
        // shared helper) because the friend-import path uses a
        // separate set of attribution fields and shouldn't touch
        // these — see `materializeFromPublished` below.
        recipe.sharedBy      = envelope.share.sharedBy
        recipe.sharedAt      = .now
        recipe.sourceShareID = envelope.share.sourceRecipeID

        // Carry chain attribution forward when the envelope carries
        // it (newer-sender envelopes only — legacy envelopes leave
        // these nil and the recipient is treated as if they own-
        // authored). Without this, B saving A's recipe via link
        // forgets A; B's subsequent re-share to C would credit B
        // as the chain root in the next envelope's
        // `originalCreatorID`. Display name comes from `sharedBy`
        // since the link-share envelope has no separate
        // chain-root display name field.
        if let chainCreatorID = envelope.share.originalCreatorID,
           !chainCreatorID.isEmpty {
            recipe.originalCreatorUserRecordName = chainCreatorID
            recipe.originalCreatorDisplayName    = envelope.share.sharedBy
            recipe.originalRecipeID              = envelope.share.originalRecipeID
                ?? envelope.recipe.id.uuidString
            recipe.importedAt                    = .now
        }

        return recipe
    }

    /// Slice 5 entry point — creates a fresh local Recipe from a
    /// friend's `PublishedRecipe` envelope and stamps the chain-
    /// attribution fields. Distinct from `materialize` above so the
    /// file/link share path's attribution (`sharedBy`/`sharedAt`/
    /// `sourceShareID`) and the friend-import path's attribution
    /// (`originalCreator*` / `originalSharer*` / `originalRecipeID`
    /// / `importedAt`) coexist without overlap.
    ///
    /// **Chain logic:**
    /// - `originalSharer*` always reflects the friend the user
    ///   tapped to import — even if that friend is also the chain
    ///   root, so a single source of truth for "who I imported
    ///   from."
    /// - `originalCreator*` falls back from the published record's
    ///   `originalCreatorID` (chain root user record name; non-nil
    ///   means the friend imported it from someone earlier) and
    ///   the envelope's `sharedBy` (chain root display name) to the
    ///   friend's own identity. So importing directly from the
    ///   chain root sets `originalCreator == originalSharer`,
    ///   which downstream `RecipeDetailView` collapses correctly.
    /// - `originalRecipeID` falls back from the published record's
    ///   field (chain root recipe id) to the envelope's recipe id
    ///   so we always have *some* stable identifier to pivot on
    ///   for the slice 6 import-counter query.
    ///
    /// `overrideTitle` carries the explicit title chosen from the
    /// friend-import duplicate-confirmation prompt. When nil, title
    /// collisions still resolve silently via `resolveImportTitle`, so
    /// callers that skip the prompt keep the same safety net.
    @MainActor
    static func materializeFromPublished(
        _ detail: PublishedRecipeDetail,
        into context: ModelContext,
        friend: UserProfileSnapshot,
        overrideTitle: String? = nil
    ) async -> Recipe {
        let envelope = detail.envelope
        let recipe = await createLocalRecipe(
            from: envelope,
            into: context,
            overrideTitle: overrideTitle
        )

        recipe.originalSharerUserRecordName = friend.userRecordName
        recipe.originalSharerDisplayName    = friend.displayName
        recipe.originalCreatorUserRecordName = detail.originalCreatorID ?? friend.userRecordName
        recipe.originalCreatorDisplayName    = envelope.share.sharedBy ?? friend.displayName
        recipe.originalRecipeID = detail.originalRecipeID ?? envelope.recipe.id.uuidString
        recipe.importedAt       = .now

        return recipe
    }

    /// Shared body for `materialize` and `materializeFromPublished`.
    /// Resolves the title, creates the new Recipe with fresh UUIDs
    /// throughout, inserts into the context, and walks the
    /// envelope's ingredients / steps / photos to populate the
    /// relationships. Caller is responsible for stamping
    /// attribution — that's the only thing that differs between
    /// the two materialize paths.
    @MainActor
    private static func createLocalRecipe(
        from envelope: LCRecipeShareV1,
        into context: ModelContext,
        overrideTitle: String?
    ) async -> Recipe {
        let resolvedTitle: String
        if let override = overrideTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            resolvedTitle = override
        } else {
            resolvedTitle = resolveImportTitle(
                base: envelope.recipe.title,
                in: context
            )
        }

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

    /// Exact-title duplicate probe used by the import preview's
    /// duplicate-confirmation prompt. Same fetch + Set membership as
    /// `resolveImportTitle` (case-sensitive, no trimming) so the
    /// "already have this recipe" detection lines up byte-for-byte
    /// with the suffix-resolution that runs on the silent path.
    static func libraryContainsRecipe(
        withTitle title: String,
        in context: ModelContext
    ) -> Bool {
        let allRecipes = (try? context.fetch(FetchDescriptor<Recipe>())) ?? []
        return allRecipes.contains { $0.title == title }
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
