# Llamas Cookbook — Recipe Sharing Plan

> **Goal:** let two users with the app exchange a recipe end-to-end —
> ingredients, steps, notes, gallery photos, per-step photos — through
> a single tap on iOS share targets (AirDrop, Messages, Mail), so a
> recipient never has to re-import or hand-merge anything.
>
> **Companion to:** [CLAUDE.md](./CLAUDE.md),
> [Photo-Capability.md](./Photo-Capability.md),
> [Multi-Recipe-Cook-Mode.md](./Multi-Recipe-Cook-Mode.md),
> [PROJECT.md](./PROJECT.md).
>
> **Audience:** Claude Code session, picking up to implement.

---

## 0. The 60-second summary

Today's "share" is `Recipe.exportText` — readable plain text that
round-trips through Notes / Messages / Mail. It loses every photo,
every structural cue, and the recipient has to re-paste through
`ImportRecipeView`. Two app users can't exchange a recipe in one tap.

We add **two new transports**, both built on the existing iOS share
sheet, and keep the plain-text path intact as a fallback:

1. **`.llamarecipe` file** — JSON envelope (recipe + ingredients +
   steps + notes + base64 photos), shared as an attachment. AirDrop /
   Messages / Mail / Files all handle it natively. The receiving app
   registers the UTType and opens it through `onOpenURL`.
2. **`llamascookbook://recipe/v1/<base64url>` URL** — same envelope
   minus photos, base64-encoded into a deep link. Tappable in any
   chat / clipboard surface. Falls back to "share as file" when the
   payload's too big or any photos are present.

The receiving side opens an **import preview sheet** (mini-Detail
read-only render + "Save to library" / "Cancel"), rewrites IDs on
save, and stamps three new fields onto the local `Recipe`:
`sharedBy`, `sharedAt`, `sourceShareID`. Detail renders a small
"Originally shared by Anna · Apr 27" line under the title for any
imported recipe — sticky through local edits, so the original
sharer's credit isn't lost when the receiver tweaks the recipe.
Same-title re-imports get an auto-incrementing suffix on save:
"Banana Bread" becomes "Banana Bread (1)", a third becomes "Banana
Bread (2)", and so on.

The sender's display name lives in a new `OwnerProfile` Observable
(sibling to `AppearanceSettings`); a one-time prompt on the very
first outgoing share captures it ("Who's sharing? Lets the recipient
see who sent it") and every future share reuses the saved value.

The whole envelope schema is a plain `Codable` struct independent of
SwiftData — designed so a future cloud backend can accept the same
payload byte-for-byte.

**Effort:** ~1 dev-day for the schema + Codable + UTType + share /
import plumbing, ~0.5 day for provenance display + first-share
prompt, ~0.5 day for the URL variant + size guard, ~0.5 day for
tests + polish. Three CI cycles minimum.

---

## 1. What "share between users" means in practice

The reality this is solving: Lorenzo cooks something good, wants to
send it to a friend who also has the app. Today's options are all
lossy:

- **Plain-text export** — works, but the friend re-pastes through
  Import and loses photos.
- **Source URL** — only present for recipes that started on the web.
  Locally-authored recipes have no URL.
- **Screenshot the screen** — captures one screen, no structure,
  no round-trip.

After this lands, the user can:

1. Open Recipe Detail.
2. Tap the share toolbar button → action menu offers:
   - **Share recipe** (file form, includes photos)
   - **Share as link** (URL form, when small enough)
   - **Share as text** (existing plain-text path, for non-app users)
3. Pick a target. AirDrop sends the `.llamarecipe` file directly to
   the friend's device; Messages attaches it inline; Mail attaches
   it; Copy puts a `llamascookbook://recipe/...` URL on the clipboard.
4. The friend taps the file (or the link). The app opens to an
   **Import Preview** sheet showing the incoming recipe.
5. Friend taps "Save to library." Recipe lands with full fidelity —
   every photo, every note, every per-step image. Detail shows a
   "Originally shared by Lorenzo" line.

Out of scope for v1 (see §16): cloud-hosted shares, universal links
with a web fallback, multi-recipe / cookbook export, re-import
deduplication ("you already have this — update it?"), encrypted
shares, share analytics.

---

## 2. Two transports, one schema

```
                    ┌─────────────────────────┐
                    │  LCRecipeShareV1        │
                    │  (Codable JSON)         │
                    └────┬────────────────┬───┘
                         │                │
              JSON.encode│                │ JSON.encode
                         │                │
                         ▼                ▼
              ┌─────────────────┐   ┌─────────────────────┐
              │ .llamarecipe    │   │ base64url-encode    │
              │ file (UTType)   │   │ → URL path          │
              │ photos: ✅      │   │ photos: ❌ (size)   │
              └────────┬────────┘   └──────────┬──────────┘
                       │                       │
                       │ AirDrop / Messages /  │ Messages / Notes /
                       │ Mail / Files /        │ Slack / Copy /
                       │ Save to Files         │ any text channel
                       │                       │
                       ▼                       ▼
                ┌──────────────────────────────────┐
                │ Receiving device: onOpenURL      │
                │ → decode → ImportPreviewView     │
                │ → Save → rewrite IDs → persist   │
                └──────────────────────────────────┘
```

### 2.1 When does each transport win

| Situation | Best transport | Why |
|---|---|---|
| Recipe has any photos | **File** | URL would balloon past clipboard limits |
| AirDrop between two iPhones | **File** | Sender + recipient both have the app; UTType handoff is instant |
| Recipient might not have the app | **URL** OR **text** | Link tap on a phone without the app silently fails; text never fails |
| Sharing in a group chat with mixed users | **Text** (today's path) | Lowest common denominator |
| Compact recipe (no photos) for a chat | **URL** | Looks like a normal link; tap-to-open feels native |

The Detail share menu surfaces all three. The user picks based on
context.

### 2.2 Why not Universal Links

Universal Links (`https://llamascookbook.app/recipe/<id>`) would
gracefully fall back to a web page when the recipient doesn't have
the app. Tempting, but:

- Requires hosting `apple-app-site-association` on a real domain.
- Requires a working website with a "this recipe needs the app to
  open" landing page — or a full web renderer if we want richer
  fallback.
- Breaks the offline-first / no-backend ethos.

Out of scope for v1, deferrable to a future "share via link → web
landing page" push. The custom URL scheme is the offline-friendly
substitute.

---

## 3. Schema — `LCRecipeShareV1`

A pure-Codable struct, defined in `Lib/RecipeShare.swift`. This is
the **single source of truth for what gets shared** — every transport
encodes the same envelope.

```swift
struct LCRecipeShareV1: Codable {
    /// Always 1 for this version. Future versions bump this and add
    /// a `LCRecipeShareV2` type alongside; the decoder picks based on
    /// the value it reads. Forward-compat: receiving a v2 share on a
    /// v1 build surfaces a friendly "this recipe needs a newer version
    /// of Llamas Cookbook" alert rather than crashing.
    let schemaVersion: Int

    let share: ShareEnvelope
    let recipe: ShareRecipe

    struct ShareEnvelope: Codable {
        /// Unique to this share envelope, not the recipe itself.
        /// Lets the future re-import detection key on "I already
        /// imported THIS share" without confusing it with "I have a
        /// recipe with this same recipeID from somewhere else."
        let id: UUID
        /// ISO-8601. When the sender hit Share.
        let createdAt: Date
        /// Display name from the sender's `OwnerProfile`. May be nil
        /// when the sender hasn't set one yet — the first-share prompt
        /// (§7.4) captures it but the user can leave it blank.
        let sharedBy: String?
        /// The original `Recipe.id` on the sender's device at share
        /// time. NOT the same as `recipe.id` below — see §6 ID rewriting.
        /// Used for future "you already imported this" detection.
        let sourceRecipeID: UUID
        /// Sender's app version, surfaced on import-time errors.
        let appVersion: String
    }

    struct ShareRecipe: Codable {
        /// On the sender's side: same as `share.sourceRecipeID`. The
        /// receiver rewrites this to a fresh UUID on save (§6).
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
        /// Recipe-level gallery photos.
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
        /// layer, but the decoder accepts up to whatever the sender
        /// emitted (forward-compat for if we ever raise the cap).
        let photos: [SharePhoto]
    }

    struct SharePhoto: Codable {
        let id: UUID
        let order: Int
        let caption: String?
        /// JPEG bytes, base64-encoded. The sender re-runs photos
        /// through `ImageProcessing.prepare(_, for:)` before encoding
        /// to keep the payload small (matches the storage target the
        /// receiver will re-encode to anyway).
        let image: String
    }
}
```

### 3.1 Fields deliberately not shared

| Field on `Recipe` | Why excluded |
|---|---|
| `imageUri` | Deprecated; not used anywhere. |
| `lastCookedAt` / `cookCount` | Receiver-local state. Their cook log is theirs, not the sender's. |
| `createdAt` / `updatedAt` | Reset to "now" on the receiver — the recipe is "new" to their library. |
| `favorite` | Receiver's preference. Defaults to `false`. |
| `RecipeStep.image` | Deprecated single-image slot. Step photos go through `RecipeStep.photos` only. |

### 3.2 Photo encoding

Photos are stored as `Data?` with `@Attribute(.externalStorage)` —
already JPEG/HEIC bytes after `ImageProcessing.prepare`. For sharing:

1. **Sender:** for each `RecipePhoto.image` and
   `RecipeStepPhoto.image`, base64-encode the bytes directly into the
   `SharePhoto.image: String` field. **Do not** re-run `ImageProcessing`
   — the bytes are already at storage size and re-encoding only loses
   quality. The receiver will choose whether to re-encode on import
   based on the source's bytes (§6.3).
2. **Receiver:** base64-decode → `Data` → run through
   `ImageProcessing.prepare(_, for: .gallery)` /
   `(_, for: .step)`. This is the same idempotent re-encode the
   editor uses; the bytes guard in `ImageProcessing` (output bigger
   than input → keep input) ensures we don't double-degrade.

Base64 is ~33% bigger than raw bytes. A typical recipe with 5 gallery
photos at ~400KB and 3 step photos at ~200KB:
`(5 × 400 + 3 × 200) × 1.33 ≈ 3.5MB` envelope. Fine as a file
attachment, way too big as a URL.

### 3.3 Why not zip + photo sidecar files

A `.llamarecipe` could be a zip archive with `recipe.json` + `photos/*.jpg`
sidecars. Considered and rejected for v1:

- One file, one struct decode is simpler than iterating archive
  entries.
- Modern phones don't blink at a 3.5MB JSON over AirDrop.
- The base64 inflation cost only matters at the URL transport, where
  we already strip photos.

Defer the zip variant to a future optimization if envelope sizes
become a real-world problem (e.g. a recipe with 10 step photos pushing
20MB+).

---

## 4. New file — `Lib/RecipeShare.swift`

Pure logic, no SwiftUI, no SwiftData imports beyond `Recipe` /
`Ingredient` / `RecipeStep` / `RecipePhoto` / `RecipeStepPhoto` for
the bridges.

```swift
import Foundation
import SwiftData

enum RecipeShare {
    /// The only shape we currently emit and accept. Future schema
    /// versions add cases / type aliases.
    static let currentVersion = 1

    enum Error: Swift.Error, LocalizedError {
        case unsupportedSchemaVersion(Int)
        case decodeFailure(underlying: Swift.Error)
        case payloadTooLargeForURL(bytes: Int)
    }

    // MARK: - Encode

    /// Builds a v1 envelope from a live SwiftData `Recipe`. Doesn't
    /// touch `Recipe` itself — pulls bytes through the existing
    /// relationships and the `OwnerProfile` for `sharedBy`.
    static func envelope(
        for recipe: Recipe,
        sharedBy: String?,
        appVersion: String
    ) -> LCRecipeShareV1 { ... }

    static func encodeFile(_ envelope: LCRecipeShareV1) throws -> Data { ... }

    /// Builds the URL form. Throws `payloadTooLargeForURL` when the
    /// resulting URL would exceed `urlByteCeiling` (~6000 chars after
    /// base64url + scheme overhead). Caller decides whether to fall
    /// back to file or surface "share as link is unavailable for this
    /// recipe" to the user.
    static func encodeURL(_ envelope: LCRecipeShareV1) throws -> URL { ... }

    static let urlByteCeiling = 6000

    // MARK: - Decode

    static func decode(fileData: Data) throws -> LCRecipeShareV1 { ... }

    /// Parses `llamascookbook://recipe/v1/<base64url>` and returns the
    /// envelope. Returns nil for any other URL (so RootView's
    /// onOpenURL can keep its existing cook-deep-link branch).
    static func decode(url: URL) throws -> LCRecipeShareV1? { ... }

    // MARK: - Materialize on import

    /// Creates a fresh `Recipe` (+ children) inside `context` from a
    /// decoded envelope. **Rewrites every UUID** so two users can each
    /// re-import the same share without colliding on the original
    /// sender's IDs (§6). Stamps `sharedBy` / `sharedAt` /
    /// `sourceShareID` for provenance display.
    @MainActor
    static func materialize(
        _ envelope: LCRecipeShareV1,
        into context: ModelContext
    ) async -> Recipe { ... }
}
```

The `encodeFile` / `decodeFile` pair are symmetric:
`JSONEncoder().encode(envelope)` and `JSONDecoder().decode(...)`. The
URL pair adds base64url translation (URL-safe alphabet, no padding)
on top of the JSON bytes:

```swift
// Pseudo:
let json = try JSONEncoder().encode(envelope)
let b64url = json.base64URLEncodedString()
let url = URL(string: "llamascookbook://recipe/v1/\(b64url)")!
guard url.absoluteString.count <= urlByteCeiling else {
    throw Error.payloadTooLargeForURL(bytes: url.absoluteString.count)
}
return url
```

`Data.base64URLEncodedString()` is a tiny extension that swaps `+/=`
for `-_` and trims padding.

---

## 5. Schema additions — `Recipe`

Three new optional fields on `Recipe`:

```swift
@Model final class Recipe {
    // ... existing fields ...

    /// Display name from the sender's `OwnerProfile` at share time.
    /// Nil for locally-authored recipes (the user made it themselves).
    /// Surfaced as "Originally shared by {name} · {date}" under the recipe title
    /// in Detail (§8). Sticky once set: editing the recipe locally
    /// does NOT clear the field — the user might tweak someone else's
    /// recipe and still want to remember it came from them.
    var sharedBy: String?

    /// When THIS device received the share. Distinct from `createdAt`
    /// (which reads "today" on import — the recipe is new to their
    /// library) and from `share.createdAt` in the envelope (the
    /// sender's clock).
    var sharedAt: Date?

    /// The original `Recipe.id` on the sender's device. Stored so a
    /// future "you already imported this" UX can detect duplicates
    /// without forcing a fuzzy title match. Nil for locally-authored
    /// recipes.
    var sourceShareID: UUID?
}
```

These are all nil-defaulted optionals → SwiftData lightweight
migration handles them. Same playbook as `prefaceNote` /
`epilogueNote` / `generalNote` (§5 of CLAUDE.md notes).

`Recipe.toDraft()` / `Recipe.apply(_:)` do **not** carry these
fields — the editor doesn't expose them. They're set at materialize
time (§6.2) and read at display time (§8). `apply(_:)` leaves them
untouched on save.

---

## 6. Import path — UUID rewriting + provenance stamping

This is the equivalent of [Photo-Capability.md §3's "carry bytes
through draft"](./Photo-Capability.md) gotcha — silent regression
mode if you skip it.

### 6.1 Why every UUID gets rewritten

If the sender's `Recipe.id = ABC` and the receiver imports verbatim,
the receiver's library now has a recipe with `id = ABC`. Three
problems:

1. **Re-importing the same share** would either crash on a SwiftData
   uniqueness conflict OR silently "merge" (depending on how
   SwiftData handles the dup), neither of which is correct.
2. **Two users sharing different recipes that happen to have the
   same ID** (vanishingly unlikely but possible across UUID
   collisions in cloned testing builds) would conflict.
3. **The user's library has a permanent record of someone else's
   ID space** — opaque to debugging and future cloud sync.

Rewriting at the materialize boundary keeps every device's UUID space
internal. The original ID is preserved in `sourceShareID` for
provenance / future dedup.

### 6.2 What `materialize(_:)` does

Three jobs: rewrite UUIDs (§6.1), stamp provenance fields, and resolve
title collisions so re-imports of the same recipe land as numbered
duplicates ("Banana Bread" → "Banana Bread (1)" → "Banana Bread (2)")
rather than identical entries the user can't tell apart in the
Library list.

```swift
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
        favorite: false,                        // receiver's preference
        tags: envelope.recipe.tags
    )
    // recipe.id was assigned a fresh UUID by the init.

    recipe.prefaceNote   = envelope.recipe.prefaceNote
    recipe.epilogueNote  = envelope.recipe.epilogueNote
    recipe.generalNote   = envelope.recipe.generalNote

    // Provenance — the heart of why this exists.
    recipe.sharedBy      = envelope.share.sharedBy
    recipe.sharedAt      = .now
    recipe.sourceShareID = envelope.share.sourceRecipeID

    // Ingredients — fresh IDs preserved by Ingredient.init().
    for ing in envelope.recipe.ingredients.sorted(by: { $0.order < $1.order }) {
        recipe.ingredients.append(Ingredient(
            quantity: ing.quantity,
            unit: ing.unit,
            name: ing.name,
            order: ing.order
        ))
    }

    // Steps — including their per-step photo galleries. Bytes go
    // through ImageProcessing on the way in (§3.2).
    for step in envelope.recipe.steps.sorted(by: { $0.order < $1.order }) {
        let local = RecipeStep(
            text: step.text,
            order: step.order,
            needsTimer: step.needsTimer,
            specialNote: step.specialNote
        )
        for photo in step.photos.sorted(by: { $0.order < $1.order }) {
            guard let raw = Data(base64Encoded: photo.image) else { continue }
            let processed = await ImageProcessing.prepare(raw, for: .step) ?? raw
            local.photos.append(RecipeStepPhoto(
                image: processed,
                caption: photo.caption,
                order: photo.order
            ))
        }
        recipe.steps.append(local)
    }

    // Recipe gallery — same shape as step photos.
    for photo in envelope.recipe.photos.sorted(by: { $0.order < $1.order }) {
        guard let raw = Data(base64Encoded: photo.image) else { continue }
        let processed = await ImageProcessing.prepare(raw, for: .gallery) ?? raw
        recipe.photos.append(RecipePhoto(
            image: processed,
            caption: photo.caption,
            order: photo.order
        ))
    }

    context.insert(recipe)
    return recipe
}
```

### 6.3 Title-collision helper — `resolveImportTitle`

```swift
/// Returns either the base title (no collision) or "{base} (N)"
/// where N is the smallest positive integer that doesn't already
/// match an existing recipe's title. Cookbook is a personal library
/// (~hundreds of recipes max), so a full fetch + Set lookup is cheap
/// and avoids SwiftData predicate gymnastics with `contains` /
/// `starts(with:)`.
private static func resolveImportTitle(
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
```

Edge-case behavior, called out so test #12 captures the right
expectations:

- **Base title not in library** → return the base unchanged. No
  spurious "(1)" on first import.
- **`Banana Bread (1)` exists but `Banana Bread` doesn't** (e.g. user
  manually deleted the original after a prior import) → next free is
  "(2)". The scan finds the lowest *unused* slot rather than the
  lowest *adjacent* slot.
- **Sender's title already carries a suffix** (e.g. they named theirs
  "Banana Bread (2)" because they imported from someone else) → the
  whole sender string is the base. If the receiver doesn't have it,
  it saves verbatim. If they do, it becomes "Banana Bread (2) (1)" —
  slightly ugly but unambiguous and v1-acceptable.
- **No upper bound** — there is no cap at "(99)" or similar; the loop
  runs until it finds a free slot. In practice the user will rename
  long before this matters.

The Import Preview sheet (§8.2) shows the **original** title, not
the resolved one — the user picks "Save to Library" and the suffix
is applied at materialize time. If the title gets bumped, surface a
small toast on save: "Saved as 'Banana Bread (1)' — you already had
a 'Banana Bread'." (Toast is nice-to-have, defer past v1 if time-
pressed; the new title is visible in the Library list either way.)

### 6.4 Why re-run `ImageProcessing.prepare` on import

Two reasons:

1. **Format / size hygiene.** A sender on an old build might have
   stored larger bytes than a current build's target. Re-encoding
   normalizes the receiver's library.
2. **Bytes guard already protects.** `ImageProcessing.prepare` keeps
   the source bytes if the re-encode is bigger — so for already-tight
   bytes the receiver pays a small CPU cost and stores the exact same
   content.

The `?? raw` fallback handles the case where `prepare` returns nil
(corrupt or unrecognized image format) — we'd rather keep undecodable
bytes than drop a photo silently. `RecipeImageView` renders a
placeholder for undecodable bytes, so the user sees "this photo
didn't load" rather than a phantom empty slot.

---

## 7. Sender-side UX — share menu in Detail

### 7.1 Today's ShareLink

Today's [`RecipeDetailView`](./ios-native/Sources/Views/Detail/RecipeDetailView.swift)
has a single ShareLink in the toolbar passing `recipe.exportText`.
We replace it with a `Menu` that surfaces all three share options.

### 7.2 New menu

```swift
ToolbarItem(placement: .topBarTrailing) {
    Menu {
        ShareLink(
            item: RecipeShareTransfer(recipe: recipe, ownerProfile: ownerProfile),
            preview: SharePreview(recipe.title, image: recipe.firstPhotoForPreview)
        ) {
            Label("Share recipe", systemImage: "square.and.arrow.up.on.square")
        }

        if let url = try? RecipeShare.encodeURL(envelope) {
            ShareLink(
                item: url,
                preview: SharePreview(recipe.title)
            ) {
                Label("Share as link", systemImage: "link")
            }
        }

        ShareLink(
            item: recipe.exportText,
            preview: SharePreview(recipe.title)
        ) {
            Label("Share as text", systemImage: "doc.plaintext")
        }
    } label: {
        Image(systemName: "square.and.arrow.up")
    }
}
```

The "Share as link" item only renders when `encodeURL` succeeds
(i.e. the payload fits under `urlByteCeiling` — automatically true
when there are no photos). When photos are present it disappears
quietly; the user has "Share recipe" (file form) covering the rich
case.

### 7.3 `RecipeShareTransfer: Transferable`

A small wrapper that lets ShareLink emit the `.llamarecipe` file:

```swift
struct RecipeShareTransfer: Transferable {
    let recipe: Recipe
    let ownerProfile: OwnerProfile

    var fileName: String {
        // Filesystem-safe; "Banana Bread.llamarecipe" not "Banana
        // Bread / version 2.llamarecipe"
        let safe = recipe.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces))
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return safe.isEmpty ? "Recipe.llamarecipe" : "\(safe).llamarecipe"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .llamaRecipe) { transfer in
            let envelope = RecipeShare.envelope(
                for: transfer.recipe,
                sharedBy: transfer.ownerProfile.userName.nilIfEmpty,
                appVersion: Bundle.main.appVersion
            )
            return try RecipeShare.encodeFile(envelope)
        }
        .suggestedFileName(\.fileName)
    }
}

extension UTType {
    /// Matches the UTExportedTypeDeclarations in AppInfo.plist.
    static var llamaRecipe: UTType {
        UTType(exportedAs: "com.llamascookbook.recipe")
    }
}
```

The `UTType.llamaRecipe` and the AppInfo.plist declaration must agree
on `com.llamascookbook.recipe` — typo here means iOS quietly fails to
register the file type and AirDrop falls back to "this file" with no
icon.

### 7.4 First-share prompt — `OwnerProfile`

A new Observable, sibling to `AppearanceSettings`:

```swift
@Observable
final class OwnerProfile {
    private static let nameKey = "ownerUserName"
    private static let hasPromptedKey = "ownerUserNamePrompted"

    /// Display name surfaced to recipients as "Originally shared by {name}".
    /// Empty string == not set; envelope ships with `sharedBy: nil`.
    var userName: String = "" {
        didSet { persist() }
    }

    /// True once the user has seen the first-share prompt (whether or
    /// not they typed a name). Subsequent shares skip the prompt and
    /// just emit whatever's stored.
    var hasPromptedForName: Bool = false {
        didSet { persist() }
    }

    init() {
        userName = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        hasPromptedForName = UserDefaults.standard.bool(forKey: Self.hasPromptedKey)
    }

    private func persist() {
        UserDefaults.standard.set(userName, forKey: Self.nameKey)
        UserDefaults.standard.set(hasPromptedForName, forKey: Self.hasPromptedKey)
    }
}
```

Hung off `RootView` like every other coordinator. Injected via
`.environment(ownerProfile)`.

The first-share UX:

1. User taps "Share recipe" in the menu.
2. Detail checks `ownerProfile.hasPromptedForName`.
3. **First time** — present a small alert sheet:
   - "Who's sharing? Lets the recipient see who sent it."
   - Text field prefilled with the device name (or empty).
   - Buttons: **Share** (saves name, marks prompted, proceeds to
     ShareLink), **Skip** (marks prompted, proceeds with `sharedBy: nil`),
     **Cancel** (does not mark prompted, dismisses).
4. **Subsequent times** — skip straight to ShareLink. No friction.

A tiny "Edit" affordance in the menu lets the user revisit the name
later (sets `hasPromptedForName = false` and re-prompts). When the
Settings screen finally ships, it'll surface the same field with no
prompt indirection.

---

## 8. Receiver-side UX — import preview + provenance

### 8.1 Routing — extend `onOpenURL` and add a file handler

Existing [`RootView`](./ios-native/Sources/App/RootView.swift)
`onOpenURL` already handles `llamascookbook://cook/<uuid>`. Add a
second branch for `host == "recipe"`:

```swift
.onOpenURL { url in
    if let recipeID = parseCookDeepLink(url) {
        // ... existing cook routing ...
    } else if url.scheme == "llamascookbook", url.host == "recipe" {
        // llamascookbook://recipe/v1/<base64url>
        do {
            if let envelope = try RecipeShare.decode(url: url) {
                pendingShareImport = envelope
            }
        } catch {
            shareImportError = error.localizedDescription
        }
    } else if url.isFileURL {
        // .llamarecipe file opened from Files / AirDrop / Mail
        do {
            let data = try Data(contentsOf: url)
            let envelope = try RecipeShare.decode(fileData: data)
            pendingShareImport = envelope
        } catch {
            shareImportError = error.localizedDescription
        }
    }
}
```

`pendingShareImport: LCRecipeShareV1?` is new state on `RootView` (or
a coordinator if it gets noisy — see §10). When non-nil, presents
`RecipeImportPreviewView` as a sheet.

### 8.2 `RecipeImportPreviewView`

A new view, similar in shape to a stripped-down `RecipeDetailView`:

```
┌──────────────────────────────────────┐
│ ✕                            [Save]  │  ← toolbar
├──────────────────────────────────────┤
│                                      │
│ Banana Bread                         │  ← title (large)
│ Originally shared by Lorenzo         │  ← provenance eyebrow
│                                      │
│ Serves 8 · Cook 60 min               │
│                                      │
│ A simple loaf with...                │  ← summary
│                                      │
│ ─── Photos (3) ───                   │  ← carousel preview, view-only
│ [thumb][thumb][thumb]                │
│                                      │
│ ─── Ingredients ───                  │
│ • 2 & 1/2 cups — flour               │
│ • 1 tsp — baking soda                │
│   ...                                │
│                                      │
│ ─── Steps ───                        │
│ 1. Preheat the oven to 350°F.        │
│ 2. Mash the bananas in a bowl.       │
│   [step photo thumb]                 │
│   ...                                │
│                                      │
│ ─── Notes ───                        │
│ Note: rest the loaf for 10 min...    │
│                                      │
│              [ Save to Library ]     │
│                                      │
└──────────────────────────────────────┘
```

Read-only render (no checkboxes, no Cook Mode entry, no edit
affordances). Two buttons: **Save** (commits via
`RecipeShare.materialize`), **Cancel** (dismisses; envelope is
discarded).

Because we materialize on Save (not on preview render), the user can
peek and dismiss without bloating their library with half-imported
artifacts.

### 8.3 Provenance display in `RecipeDetailView`

When `recipe.sharedBy` or `recipe.sharedAt` is non-nil, render a
small line below the recipe title:

```
Banana Bread
Originally shared by Lorenzo · Apr 27
```

Style: `AppFont.eyebrow` + `AppColor.textTertiary`. Tap to see a
fuller provenance sheet ("Originally shared by Lorenzo on Apr 27,
2026 from Llamas Cookbook 0.1.0") — nice-to-have, defer past v1 if
time-pressed.

**The "Originally" wording is deliberate.** The line **does not**
clear when the user edits the recipe locally — a cookbook-from-Mom
is a cookbook-from-Mom even after you tweak the salt amount, and
the past-tense "Originally" reads correctly even after the recipient
has made the recipe their own. `Recipe.apply(_:)` from the editor
leaves `sharedBy` / `sharedAt` / `sourceShareID` untouched on every
save — provenance is set once at materialize time and is never
mutated by editor flows.

---

## 9. UTType + document-type registration

Two new entries in [`Resources/AppInfo.plist`](./ios-native/Resources/AppInfo.plist):

```xml
<key>UTExportedTypeDeclarations</key>
<array>
    <dict>
        <key>UTTypeIdentifier</key>
        <string>com.llamascookbook.recipe</string>
        <key>UTTypeDescription</key>
        <string>Llamas Cookbook Recipe</string>
        <key>UTTypeConformsTo</key>
        <array>
            <string>public.json</string>
            <string>public.data</string>
            <string>public.content</string>
        </array>
        <key>UTTypeTagSpecification</key>
        <dict>
            <key>public.filename-extension</key>
            <array>
                <string>llamarecipe</string>
            </array>
            <key>public.mime-type</key>
            <array>
                <string>application/x-llamas-recipe+json</string>
            </array>
        </dict>
    </dict>
</array>

<key>CFBundleDocumentTypes</key>
<array>
    <dict>
        <key>CFBundleTypeName</key>
        <string>Llamas Cookbook Recipe</string>
        <key>LSItemContentTypes</key>
        <array>
            <string>com.llamascookbook.recipe</string>
        </array>
        <key>LSHandlerRank</key>
        <string>Owner</string>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
    </dict>
</array>
```

`LSHandlerRank: Owner` declares us as the canonical app for the
type. `UTTypeConformsTo: public.json` matters for AirDrop preview
rendering — iOS shows the file as JSON-shaped without it falling back
to "Unknown."

**iOS UTI cache gotcha:** the very first install after adding the
declaration sometimes doesn't register the type until a clean reboot.
Reinstalling fresh works around it. Document this in the test plan
(§14).

---

## 10. State plumbing — share + import coordinators

A judgment call: do these live as `@State` on `RootView` directly, or
as their own `ShareCoordinator` Observable?

For v1: **add `@State private var pendingShareImport: LCRecipeShareV1?`
and `@State private var shareImportError: String?` to `RootView`
directly.** The state is small (two values), the consumers are few
(the import sheet + an error alert), and a coordinator would just be
ceremony.

The `OwnerProfile` Observable (§7.4) is its own type because it has
non-trivial internal logic (persistence + first-prompt gating) and
gets `.environment`'d into multiple views.

If a future feature (re-share chain visualization, share history,
analytics) lands and `RootView`'s share state grows past 4–5 fields,
that's the time to extract a `ShareCoordinator`. Not now.

---

## 11. File inventory

### New files (3)

```
ios-native/Sources/Lib/RecipeShare.swift                  ← §3, §4 — schema + encode + decode + materialize
ios-native/Sources/App/OwnerProfile.swift                 ← §7.4 — Observable for sender display name
ios-native/Sources/Views/Library/RecipeImportPreviewView.swift  ← §8.2 — sheet for incoming share
```

`RecipeImportPreviewView` lands under `Views/Library/` next to
`ImportRecipeView` because both are entry points for "a recipe
arriving from outside" — they share a mental category even though
they don't share code.

### Modified files (5)

```
ios-native/Sources/Models/Recipe.swift                    ← §5 — sharedBy / sharedAt / sourceShareID fields
ios-native/Sources/App/LlamasCookbookApp.swift            ← OwnerProfile @State + .environment injection
ios-native/Sources/App/RootView.swift                     ← §8.1 + §10 — onOpenURL recipe branch + import sheet + state
ios-native/Sources/Views/Detail/RecipeDetailView.swift    ← §7.2 share menu + §8.3 provenance line
ios-native/Resources/AppInfo.plist                        ← §9 — UTType + CFBundleDocumentTypes
```

### Untouched (verify, don't edit)

- `Lib/RecipeExport.swift` — plain-text export stays as-is. The new
  share menu's third option still routes through `recipe.exportText`.
- `Lib/RecipeImporter.swift` / `RecipeURLImporter.swift` /
  `RecipeAIParser.swift` — these handle external/web/text sources,
  not app-to-app. New `.llamarecipe` path is its own decoder.
- `App/CookingSession.swift`, `App/CookingSessionStore.swift` — Cook
  Mode unaware of sharing.
- `WidgetExtension/*` — widget renders Live Activities only.
- `Views/Editor/*` — editor doesn't know about provenance; `apply(_:)`
  leaves `sharedBy` / `sharedAt` / `sourceShareID` untouched.

---

## 12. DRY checklist — what's shared, where

| Concern | Single source of truth | Used by |
|---|---|---|
| Share envelope schema | `LCRecipeShareV1` in `Lib/RecipeShare.swift` | File transport, URL transport, future cloud transport |
| Encode / decode | `RecipeShare.encodeFile/decodeFile` + `encodeURL/decode(url:)` | `RecipeShareTransfer` (sender), `RootView.onOpenURL` (receiver) |
| Materialize-into-SwiftData (UUID rewrite + provenance stamp + photo re-encode) | `RecipeShare.materialize(_:into:)` | `RecipeImportPreviewView` Save action |
| Photo bytes guard / re-encode | `ImageProcessing.prepare(_, for:)` | Sender (no — bytes already at storage size); **receiver** on import |
| Sender display name | `OwnerProfile.userName` | First-share prompt, `RecipeShareTransfer` envelope build |
| Provenance fields | `Recipe.sharedBy/sharedAt/sourceShareID` | Materialize on import, render in Detail |
| URL parsing | `RecipeShare.decode(url:)` | `RootView.onOpenURL` recipe branch |
| File parsing | `RecipeShare.decode(fileData:)` | `RootView.onOpenURL` file URL branch |
| UTType identifier | `"com.llamascookbook.recipe"` (single string) | `AppInfo.plist` declarations + `UTType.llamaRecipe` extension |

Three things deliberately **not** unified:

1. **Plain-text export and the share envelope.** `Recipe.exportText`
   is human-readable, lossy by design (no photos, no structure tags).
   The envelope is machine-readable, lossless. Two formats serving
   two audiences. The share menu surfaces both side-by-side.
2. **Import path for `.llamarecipe` and import path for free-form
   text.** They don't share code: free-form text goes through
   `RecipeImporter.parse(_:)` (with all its splitter heuristics);
   structured envelope goes through `RecipeShare.decode` (one
   `JSONDecoder.decode` call). Trying to unify them would force the
   text path through Codable (it's not — it's regex-driven).
3. **`OwnerProfile` and `AppearanceSettings`.** Both are Observables
   persisted to UserDefaults, but their concerns don't overlap (visual
   theme vs. share identity). Keeping them separate matches the
   one-Observable-per-concern pattern (`CookingSession`,
   `EditorCoordinator`, `NavigationContext`).

---

## 13. Cloud-readiness — design hooks, not implementation

Nothing in this plan ships a cloud feature, but several decisions are
made to keep cloud adoption uncomplicated later:

| Future cloud capability | What we're doing now to enable it |
|---|---|
| Backend accepts uploaded recipe | Schema is `Codable` JSON, independent of SwiftData. POST `LCRecipeShareV1` to a future `/recipes` endpoint with no rewrite. |
| User identity tied to a cloud account | `OwnerProfile.userName` is the seed. A future "Sign in" flow can replace the free-form name with an account display name without touching share/import logic. |
| "Share via short URL" (cloud-hosted) | A future scheme `llamascookbook://recipe/cloud/<short-id>` lives alongside today's `v1/<base64url>`. Same `onOpenURL` branch, different fetch (network vs. inline decode). |
| Re-import detection ("you already have this") | `Recipe.sourceShareID` already records the upstream ID. Future import flow can check `FetchDescriptor<Recipe>(predicate: #Predicate { $0.sourceShareID == envelope.share.sourceRecipeID })` and offer Update / Save-as-new. |
| Cross-device sync of imports | UUID rewriting on import means each device's local recipe is independent of the cloud-side record. Future cloud sync layers on as a separate identity, not retroactively rewiring `Recipe.id`. |
| Versioning the schema (v2, v3, ...) | `schemaVersion: Int` lets the decoder switch on the value; old builds surface a friendly "needs newer version" alert. |

Anti-goals — things we're explicitly **not** doing despite their cloud
relevance:

- No persistent share IDs that imply server-side hosting (the URL
  transport is stateless / inline-encoded).
- No analytics or telemetry on share events.
- No encryption / signed envelopes — recipes aren't sensitive.
- No app-bound "this recipe was shared with you specifically"
  recipient binding. Anyone with the file/URL can import.

---

## 14. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Photos vanish on import** because `materialize` skips the bytes-through pattern | **High** — silent data loss | §6.2 explicit `Data(base64Encoded:)` + `ImageProcessing.prepare` per photo; test #4 in §15 catches it. |
| URL transport drops bytes through copy-paste in some chat apps (ASCII gymnastics) | Medium — share-as-link silently fails | base64url alphabet (URL-safe, no `+/=`); test #6 verifies round-trip across Messages, Notes, Mail, generic clipboard. |
| iOS UTI cache fails to register `.llamarecipe` on first install | Low / annoying — file opens "Unknown app" | Reinstall workaround. Document in test plan. Apple-side bug; nothing to fix code-side. |
| User shares from sender on v2 schema, receiver still on v1 | Medium — receiver crashes or shows garbage | `schemaVersion` switch + `unsupportedSchemaVersion` error → friendly alert "this recipe was shared from a newer version of Llamas Cookbook." |
| Receiver imports the same share twice → two duplicate recipes | Low — UX papercut | v1 behavior: always create new. Document in §16 as deliberate. Future: dedup by `sourceShareID`. |
| Sender's `OwnerProfile.userName` is empty / blank | Low — provenance line shows "Shared with you" or nothing | Acceptable. The first-share prompt nudges but doesn't force. |
| `.llamarecipe` file opened on a phone without the app | Out of our hands — no UTI registration on that device | Universal Links would solve this, but we deferred them (§2.2). The plain-text fallback is the bridge for non-app users. |
| Round-tripping a photo loses quality across re-encode | Low — `ImageProcessing` bytes guard already protects | Verify with a 12MP source on test #4. |
| Recipe with no photos exceeds `urlByteCeiling` because of huge notes / 200 ingredients | Low — share-as-link option just disappears | `encodeURL` throws cleanly; menu hides the entry. The file form still works. |
| `RootView.onOpenURL` recipe branch shadows the cook deep-link branch on a subtle URL shape | Medium — broken cook deep-links | Order matters: cook branch first, recipe branch second (§8.1 sketch shows this). Add an explicit test #11. |
| Fresh-install over an existing TestFlight build fails the new `Recipe` field migration | High in theory — schema change | Adding optional fields with nil defaults is a lightweight migration. Same playbook as `prefaceNote` etc. Test #10 covers a real device upgrade path. |

---

## 15. Test plan — must-pass before merge

Real-device walkthrough (one sender device, one receiver — TestFlight
the same build to both):

1. **Single-recipe round-trip via AirDrop.** Sender shares Banana
   Bread (3 gallery photos, 5 steps, 2 step photos on step 3). Tap
   AirDrop → receiver. Receiver sees the import preview sheet within
   ~1s of accept. Save → recipe appears in their Library. Open
   Detail: title, summary, ingredients, steps, all 3 gallery photos,
   step 3's 2 photos, all notes — every field intact.
2. **🚨 Provenance line renders.** On the receiver side, Detail of
   the imported recipe shows "Originally shared by {sender name} · {date}". On
   the sender side (where they authored locally), no provenance line.
3. **Share via Messages.** Same recipe, share to a Messages thread
   between the two devices. Recipient taps the attachment → import
   preview opens. Save → identical to test #1.
4. **🚨 Photo bytes survive the round trip.** Use a recipe with one
   gallery photo and one step photo, both ~400KB JPEG. Share →
   import. On receiver, open both photos in carousel. Visual quality
   is indistinguishable from sender. Storage size on receiver is in
   the ~400KB range, not megabytes (verify the bytes-guard didn't
   bloat).
5. **Share-as-link with no photos.** Recipe with 0 photos. "Share as
   link" item appears in the menu. Tap → Messages → recipient taps the
   `llamascookbook://...` URL → import preview opens.
6. **Share-as-link with photos hides the option.** Recipe with photos.
   "Share as link" item does NOT appear (file mode and text mode are
   the only options).
7. **Share-as-text fallback unchanged.** Existing plain-text path
   still works through Notes and Messages. Output identical to today.
8. **First-share prompt fires once.** Fresh install → Detail → Share
   recipe → name prompt appears. Type a name → Share → completes.
   Open Detail again → Share recipe → no prompt. Skip is also
   sticky — Skip then re-share never re-prompts.
9. **Sender name shows up on receiver.** Sender types "Lorenzo" in
   the prompt. Receiver imports → Detail shows "Originally shared by Lorenzo".
10. **Migration from prior install.** Install previous TestFlight
    build, create a recipe with photos, upgrade to this build. Old
    recipe still renders, no provenance line (sharedBy is nil),
    sharing it works (new envelope format, no schema corruption).
11. **🚨 Cook deep link still works.** Existing
    `llamascookbook://cook/<recipeID>` route from a Live Activity tap
    still opens Cook Mode (didn't shadow with the recipe branch).
12. **🚨 Same-title re-import gets a numbered suffix.** Receiver
    imports "Banana Bread." Sender re-shares the same recipe.
    Receiver imports again — Library shows "Banana Bread" + "Banana
    Bread (1)". A third re-import yields "Banana Bread (2)". Both
    duplicates carry the same provenance line ("Originally shared by
    Lorenzo · Apr 27"). Verify the Library A–Z scrub still groups all
    three under "B" cleanly.
13. **Edit-after-import preserves provenance.** Receiver imports
    Banana Bread, opens the editor, changes the title to "Banana
    Bread (modified)." Save. Detail still shows "Originally shared by Lorenzo".
14. **Empty-name share emits no provenance line.** Skip the prompt.
    Share. Receiver imports → Detail shows no "Originally shared by" line (no
    awkward "Originally shared by null").
15. **Mismatched schema version.** Hand-craft a `.llamarecipe` file
    with `schemaVersion: 99`. Open it on the device. App surfaces
    "this recipe was shared from a newer version of Llamas Cookbook"
    alert; no crash, no half-import.
16. **Files app handoff.** Save a `.llamarecipe` to Files. Reopen
    from Files → import preview opens. (UTI registration check.)

Hold the bar at **#1, #2, #4, #11, #12**. If #15 / #16 wobble
slightly (UTI cache shenanigans), log and ship; reinstall workaround
documented. **Don't ship without #4, #11, and #12 passing.**

---

## 16. Sequencing — recommended PR shape

Three pushes minimum, each one CI cycle:

**PR 1 — `feat(share): schema + UTType + provenance fields (no UI)`**

- §3 + §4 `Lib/RecipeShare.swift` (schema, encode/decode, materialize).
- §5 `Recipe.sharedBy / sharedAt / sourceShareID` schema additions.
- §7.4 `OwnerProfile` Observable + injection at `LlamasCookbookApp`.
- §9 AppInfo.plist UTType + CFBundleDocumentTypes.
- `UTType.llamaRecipe` extension.
- No share UI, no import UI, no menu changes. Test plan #10 must
  pass (migration on existing data).

**PR 2 — `feat(share): outbound — Detail share menu + first-share prompt`**

- §7.2 Detail share menu (file + URL + text options).
- §7.3 `RecipeShareTransfer: Transferable`.
- §7.4 first-share prompt UX.
- Test plan #5–9 + #14.

**PR 3 — `feat(share): inbound — onOpenURL routing + import preview + provenance display`**

- §8.1 `RootView.onOpenURL` recipe + file-URL branches.
- §8.2 `RecipeImportPreviewView`.
- §8.3 provenance line in Detail.
- Test plan #1–4, #11–13, #15–16.

Why this order:

1. **PR 1 ships infrastructure with no user-visible change.** Highest
   risk (schema migration + Plist registration); easy to validate
   alone.
2. **PR 2 ships the sender side first.** A user can share before
   anyone has the receiver-side import code. The recipient just gets
   a file that opens "Unknown app" — annoying but reversible.
3. **PR 3 closes the loop** with import + provenance display. After
   this lands, the round-trip works end-to-end.

Plan one retry per PR for the typical "missed an import / forgot
`async` / `await`" first-pass error, since the dev loop has no
Previews.

---

## 17. Out of scope (deliberately deferred)

- **Cloud-hosted shares.** Schema is cloud-ready (§13) but no
  backend, no upload, no fetch. Stays peer-to-peer.
- **Universal Links / web fallback.** Sharing to a non-app user
  fails silently for the URL form; plain-text is the bridge.
- **Multi-recipe / cookbook export.** A `.llamacookbook` zip
  containing N recipes. Future feature; orthogonal to v1.
- **Re-import detection beyond title-collision.** v1 always creates
  a numbered duplicate ("Banana Bread (1)", "(2)", etc.) when the
  title collides — see §6.3. `sourceShareID` is recorded so a future
  "you already have this — Update or Save as new?" UX can detect
  cross-title matches that the title-collision logic alone wouldn't
  catch (e.g. if the user renamed their imported copy).
- **Edit-before-save on import.** Save / Cancel only. Adding
  "Edit before saving" requires a path from `RecipeImportPreviewView`
  into a pre-filled editor draft — possible but not v1.
- **Share history / log.** No record of "I shared X to Y on date Z."
- **Encrypted shares / signed envelopes.** Recipes aren't sensitive.
- **Per-recipient binding.** Anyone with the file/URL can import.
- **Sharing analytics or telemetry.** Offline-first; no phone-home.
- **Rich provenance chain** ("Originally shared by Anna, originally from
  Lorenzo"). v1 records only the most-recent sharer.
- **Settings screen housing the name field.** First-share prompt
  carries the load until Settings ships separately.
- **Live Activity / widget on incoming share notifications.** Out of
  scope; share imports are user-initiated, not background.

---

## 18. Update these docs after merge

- **CLAUDE.md "Capability map":** add a "Recipe sharing" row pointing
  to `RecipeShare.swift` + `RecipeShareTransfer` + the share menu.
- **CLAUDE.md "Architectural patterns":** add a "Share envelope is
  cloud-portable JSON" note explaining the SwiftData-independent
  schema + UUID rewriting on import.
- **CLAUDE.md "Shared helpers":** add `RecipeShare.envelope/encodeFile/decodeFile/encodeURL/decode(url:)/materialize`.
- **CLAUDE.md "Source layout":** add `OwnerProfile` to the `App/`
  coordinators list and `RecipeImportPreviewView` to
  `Views/Library/`.
- **CLAUDE.md "Source of truth — read in this order":** add this
  doc as a feature plan reference.
- **CLAUDE.md "Tech stack":** mention `UTType.llamaRecipe` /
  CFBundleDocumentTypes under Persistence or a new "Sharing" row.
- **CLAUDE.md "Known limitations / deferred":** add cloud sync, web
  fallback, multi-recipe share, re-import dedup, edit-before-save.
- **CLAUDE.md "What's next":** drop "Recipe sharing between users"
  from the queue; promote whatever was below it.
- **PROJECT.md:** if it lists app capabilities, add sharing.
- **ROADMAP.md:** add follow-ups: "cloud-hosted share IDs", "Universal
  Links + web landing page", "re-import dedup", "edit-before-save on
  import", "multi-recipe `.llamacookbook` bundle".
