# Saves vs Imports — Design Note

Last refreshed: 2026-05-03. Pre-implementation design doc, not a record of behavior. Update or delete after the decision lands.

---

## 1. Current state

### What `RecipeImport` is

CloudKit public record type. Schema and writer/reader live in
`ios-native/Sources/Lib/CloudKitRecipeImport.swift`. Append-only audit row with
`originalCreatorID`, `originalRecipeID`, `importerID`, `importerDisplayName`,
`sourceUserID`, `importedAt` (file `CloudKitRecipeImport.swift:60-88`).

### Where it is **written** (one site only)

| Trigger | Call site | Notes |
|---|---|---|
| User taps a friend's recipe in `FriendLibraryView`, opens `FriendRecipeDetailView`, taps "Save to my cookbook" | `Views/Friends/FriendRecipeDetailView.swift:604` (`writeImportAuditRow(for:)`), which calls `CloudKitService.writeRecipeImport` at `FriendRecipeDetailView.swift:641` | Fire-and-forget, runs in `Task.detached` after the local SwiftData save succeeds. Skipped silently if `UserProfileMirror.cachedRecordID()` is nil. |

That's the **only** writer in the codebase
(`Grep writeRecipeImport` returns one production hit). Confirmed by walking
every other plausible importer:

- **Universal Link / share-permalink imports** — `RootView.routeUniversalLink`
  (`App/RootView.swift:505`), `routeCloudShareLink` (line 483),
  `routeShareURL` (line 465), `routeShareFile` (line 548) all funnel into
  `pendingShareImport`, which the sheet at `App/RootView.swift:260`
  presents as `RecipeImportPreviewView`. The preview's Save calls
  `RecipeShare.materialize` (`Views/Library/RecipeImportPreviewView.swift:381-398`).
  `RecipeShare.materialize` (`Lib/RecipeShare.swift:657-677`) stamps
  `sharedBy` / `sharedAt` / `sourceShareID` on the local Recipe but
  **never writes a `RecipeImport` CKRecord**. The friend-cookbook path
  uses a sibling, `materializeFromPublished` (`RecipeShare.swift:709-730`),
  whose caller (`FriendRecipeDetailView`) is the one site that does
  write the audit row.
- **Share extension** (`ShareExtension/ShareViewController.swift`) — no
  CloudKit writes; just hands the inbound payload to the host app via
  the App Group. `Grep RecipeImport` in the extension folder returns nothing.
- **Text / URL / OCR / AI imports** (`Lib/RecipeImporter.swift`,
  `RecipeURLImporter.swift`, `RecipeOCRImporter.swift`,
  `RecipeAIParser.swift`, `Views/Library/ImportFromTextView.swift`,
  `ImportFromLinkView.swift`, `PhotoImportPreviewView.swift`) — no
  `RecipeImport` writes, and shouldn't have any: no `originalCreatorID`
  for an arbitrary webpage/photo.

### Where it is **read**

| Surface | Call site | Query |
|---|---|---|
| "Saved by N" chip on Detail | `Views/Detail/RecipeDetailView.swift:742` (`refreshImportCountIfNeeded`); chip rendered at `RecipeDetailView.swift:644-667`; gated by `showsImportCounterChip` (`RecipeDetailView.swift:627`) which only shows the chip on **own-authored** recipes | `countRecipeImports(forOriginalRecipeID:)` |
| Importers list sheet (tap the chip) | `Views/Detail/ImportersListSheet.swift` | `fetchRecipeImports(forOriginalRecipeID:)` |
| "X Saved By Friends" line on Friend card | `Views/Friends/FriendsTabView.swift:230-238` (`loadTotalSavesIfNeeded`); rendered at `FriendsTabView.swift:428-436` | `countRecipeImports(forCreatorID:)` |

### Today's net behavior

| Event | RecipeImport row written? | Counted on chip? | Counted on friend card? |
|---|---|---|---|
| Lorenzo's friend Marco browses Lorenzo's friend cookbook in-app and taps Save | yes | yes | yes |
| Marco taps a Universal Link Lorenzo sent in iMessage and taps Save in the import preview | **no** | no | no |
| Marco taps a `.llamarecipe` file Lorenzo AirDropped | **no** | no | no |
| Marco opens the share-extension URL handoff for a webpage | n/a (no creator) | n/a | n/a |

---

## 2. The flow Lorenzo wants counted

Stated intent: **A shares a recipe to B, B saves it to their cookbook → A's saves stat increments.**

The two share-out paths from a chain-root creator's library are:

1. **In-app friend cookbook** — friend opens `FriendLibraryView`, taps a recipe, taps Save. *Already counted.*
2. **Share permalink / file** — chain-root taps Share in `RecipeDetailView`, recipient taps the link in iMessage / Mail / DMs / etc. and saves through the import preview. **Not counted today.**

Both should count. They're the same human action ("B added A's recipe to their cookbook") with different acquisition channels.

Open: should the chain-extending case count too — Marco shares Lorenzo's recipe to Sara via permalink, Sara saves it. Today the in-app variant of this *is* counted (and `originalCreator*` resolves to Lorenzo, so Lorenzo's friend-card stat ticks even though Sara imported from Marco). The link variant of the same chain hop is also broken because it shares the same gap.

---

## 3. Gap analysis

### Should count, doesn't

**Permalink / file share imports.** `RecipeImportPreviewView.performSave`
(`Views/Library/RecipeImportPreviewView.swift:381-398`) needs to write a
`RecipeImport` row after `RecipeShare.materialize` returns. The new local
Recipe carries `sharedBy` / `sharedAt` / `sourceShareID` but **not**
`originalCreator*` / `originalRecipeID` (those are friend-mirror-only
fields). So the writer needs to source `originalCreatorID` from the
envelope, not from the local Recipe.

The envelope's `share.sharedBy` is just a display name string. There is
no `originalCreatorID` (CloudKit user record name) field on the share
envelope today. This is the deeper part of the gap: the link-share
envelope doesn't carry the chain-root's iCloud user record name, only
their display name. Writing a `RecipeImport` row with no
`originalCreatorID` defeats the per-creator query
(`countRecipeImports(forCreatorID:)`).

So the gap is two-step:
1. The share envelope (`LCRecipeShareV1` in `Lib/RecipeShare.swift`) needs a
   new `originalCreatorID` field carried from sender to recipient.
2. `RecipeImportPreviewView.performSave` (or `RecipeShare.materialize`)
   needs to emit `writeRecipeImport` using that field.

### Probably shouldn't count, currently doesn't

- Text / URL / OCR / AI imports — correctly don't write. No creator.
- Sender's own re-import of their own recipe via permalink — would write
  `importerID == originalCreatorID`. Acceptable per the existing
  comment at `CloudKitRecipeImport.swift:84-87` ("counts events, not
  unique people").

### Probably should count, currently does

- Friend-cookbook re-imports of the same recipe by the same person ->
  produce two audit rows, intentionally
  (`CloudKitRecipeImport.swift:84-87`). Lorenzo should confirm this
  matches his mental model of "saves" — a save count that double-counts
  re-saves is unusual social-product behavior.

---

## 4. Saves vs Imported by — same or different?

**Same data, two aggregations.** Both surfaces today read the same
`RecipeImport` table:

- "Saved by N" chip (Detail) = `count where originalRecipeID == this recipe`
- "X Saved By Friends" (Friend card) = `count where originalCreatorID == this friend`

Naming-wise the app has already converged on "Saved by" copy on Detail
(`RecipeDetailView.swift:672`) — only the Friend card adds the "By
Friends" suffix, and CLAUDE.md / source comments still mix both verbs
("Imported by N", "Saved By Friends", `RecipeImport`,
`writeImportAuditRow`). That naming drift is its own UX paper-cut.

A meaningful semantic split would only exist if Lorenzo wants to
surface "saved via shared link" vs "saved from your in-app cookbook"
separately. The audit table can support that with one optional `source`
field; no second record type needed.

---

## 5. Open questions for Lorenzo

1. **Re-imports.** If Marco saves Lorenzo's recipe, deletes it, and saves it
   again, does Lorenzo's stat go up by 1 or 2? Today: 2. Friend-card
   "X Saved By Friends" reads more naturally as **unique people** (count
   distinct `importerID`).
2. **Friend vs non-friend savers.** Anyone with the share link can save —
   they don't have to be Lorenzo's friend. Should the "X Saved By **Friends**"
   copy stay, drop the "By Friends" suffix, or distinguish the two
   buckets in the UI?
3. **Source attribution.** Worth adding `source: String` to `RecipeImport`
   ("friend-cookbook" / "share-link" / "share-file") so we can later
   surface "X saved from your cookbook · Y from a shared link" without
   another schema migration?
4. **Sender envelope fields.** The link-share envelope has `sharedBy`
   (display name) but no `originalCreatorID` (record name). Adding it
   on the sender is straightforward but means older versions of the
   app sending to a newer recipient still produce un-attributable
   imports (the recipient won't know whose stat to credit). Acceptable?
5. **Chip naming.** Detail chip = "Saved by N", friend card = "Saved By
   Friends", record type = `RecipeImport`, helper = `writeImportAuditRow`.
   Worth a one-pass rename to either "saves" or "imports" everywhere?
6. **`showsImportCounterChip` gate** (`RecipeDetailView.swift:627-636`) only
   shows the chip on **own-authored** recipes. That's correct for "people
   who saved my recipe" semantics. Confirm this stays — fixing the
   permalink gap will start incrementing chips on recipes that already
   render the chip; nothing changes about which recipes show it.

---

## 6. Implementation sizing

The most-likely path is **Small leaning toward Medium**, depending on
whether `source` (Q3) is in scope.

### Small (no schema change, ~30 lines of Swift)

Scope: write `RecipeImport` from the permalink import path so messaged
shares count.

- `Lib/RecipeShare.swift` — add an optional `originalCreatorID: String?`
  to `LCRecipeShareV1.share` (Codable migration: optional, decodes nil
  for older payloads). Sender code that builds the envelope (search for
  `LCRecipeShareV1.Share(` constructions) sets it from
  `UserProfileMirror.cachedRecordID()`.
- `Views/Library/RecipeImportPreviewView.swift:381-398` — after
  `RecipeShare.materialize` returns, call
  `CloudKitService.writeRecipeImport` with
  `originalCreatorID = envelope.share.originalCreatorID`,
  `originalRecipeID = envelope.recipe.id.uuidString`,
  `importerID = UserProfileMirror.cachedRecordID()`,
  `importerDisplayName = userAccount.status.identity?.displayName ?? "Cook"`,
  `sourceUserID = envelope.share.originalCreatorID` (no chain hop info
  in a link share). Skip silently when `originalCreatorID` is nil
  (older envelopes) or `importerID` is nil (signed-out recipient).
- Files touched: 2. CloudKit Console: **no schema change** — the
  envelope's `originalCreatorID` is just a Swift Codable field, the CK
  `RecipeImport` schema already has the column.

### Medium (+ `source` field, ~3-5 files + 1 CK deploy)

Scope: Small + a `source: String` column on `RecipeImport` so Detail
and Friend card can split "from your cookbook" vs "from a shared link"
later.

- CloudKit Console: add `source` (String, queryable optional) to
  `RecipeImport` in Dev → Prod (the established schema deployment ritual
  per CLAUDE.md "CloudKit posture").
- `Lib/CloudKitRecipeImport.swift` — add `source` to write/read paths,
  to `RecipeImportRecord`.
- Both writers (existing `FriendRecipeDetailView.writeImportAuditRow`
  + new permalink writer) pass the appropriate enum.
- Optional UI follow-up on `RecipeDetailView` / `FriendsTabView` /
  `ImportersListSheet` to surface the split.

### Big (separate "Save" record type)

Not recommended. The data model is identical — just per-event audit rows
keyed by recipe + importer. Splitting the table would duplicate the
account-deletion cascade, the subscription wiring
(`CloudKitSubscriptions.swift:166`), and the importer-list sheet for
no semantic gain.

---

## 7. Recommendation

Do the **Small** path first, this week. Carry `originalCreatorID` in the
share envelope, write the audit row from the permalink import preview,
ship the friend-card stat as the unified "Saved" count it pretends to
be. That alone closes the gap Lorenzo flagged. Skip the `source` field
until there's a second product reason to want the split — adding it
later is a single `RecipeImport` schema column, not a migration. While
in there, do the one-pass rename (Q5): pick "Saved" or "Imported"
everywhere — Detail chip already says "Saved by N" so "Saved" is the
shorter migration. The re-import dedupe (Q1) and friend-vs-stranger
copy (Q2) are real questions but answering them shouldn't block the
first ship — current "counts events, not unique people" is defensible
for v1 and easy to revisit once you see real numbers.
