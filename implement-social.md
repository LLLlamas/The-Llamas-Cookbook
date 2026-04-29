# implement-social.md

Implementation plan for the Friends feature. Drafted 2026-04-29. Scope is locked; this doc is the build spec.

## Scope (what we're building)

- A **Friends** section in `ProfileView` (replaces the "coming soon" placeholder).
- Adding a friend uses a **share-an-invite-link** flow — no friend codes, no usernames, no global handle namespace.
- Tapping a friend opens **their cookbook** as a read-only library view.
- Tapping one of their recipes opens **their recipe detail** as a read-only view, with an **import button** in the top toolbar (left of the llama).
- Importing **deep-copies the recipe into your own cookbook** with new UUIDs (reuses `RecipeShare.materialize`).
- Imported recipe shows **"Originally shared by [Display Name]"** at the top of detail.
- Each recipe tracks an **import counter** — how many times anyone has imported it (transitive: chains back to the original).
- Each user can see, on their own recipe, **who imported it and when** (audit list).

Recipes are NOT individually shared. Your entire library is visible to your friends, automatically. (See "Library publishing model" below.)

## Friend discovery: name search, no handles

We don't need unique handles or friend codes. Search-by-Display-Name + a request/approve flow handles discovery:

- The actual identifier is the **CloudKit `userRecordName`** from SIWA — stable, opaque, never typed by humans.
- Display Name is the **search key**, not an identifier — collisions are a UX problem, solved with disambiguators in the search-result row (accent-color dot + join date), not a system-correctness problem.
- Names are not reserved. Two users can share "John" — they're distinguishable in search results by their accent dot and join date, and inside your Friends list by the dot alone.
- If disambiguation ever becomes a real complaint, we add handles in v2. Don't pay the cost upfront.

We are NOT using Cloudflare Pages `/f/` invite-link routes. The earlier draft of this doc had them; that approach is dropped.

## Pieces that already exist (reuse, don't rebuild)

| Existing | Location | Used for |
|---|---|---|
| SIWA + userRecordName | `App/UserAccount.swift`, `Lib/SignInWithAppleService.swift` | Stable friend identity |
| Display Name | `App/OwnerProfile.swift` | Friend's user-facing label |
| `CloudKitService` | `Lib/CloudKitService.swift` | All CK reads/writes |
| `RecipeShare.materialize` | `Lib/RecipeShare.swift` | Deep-copy recipe with new UUIDs + photo rewrite |
| Universal Link plumbing | `RootView.onOpenURL` + `onContinueUserActivity` | Invite link receive |
| Cloudflare Pages router | `cloudflare-pages/` | Serves invite link landing page (new `/f/` route) |
| Llama progress indicator | (used by share flow — confirm location during slice 5) | Reuse for import progress |
| Account-deletion outbox | `cloudShareOutbox.v1` in `CloudKitService` | Extend to wipe profile, friendships, library mirror |

## Data model

### CloudKit (public database)

Three new record types. Record IDs follow the existing 6-char `[A-Z2-9]` minus `I/O/0/1` convention where applicable; user-keyed records use `userRecordName` as the natural key.

**`UserProfile`** — one per signed-in user. Self-mirror of local profile.
- `userRecordName` (system, queryable) — the identity key
- `displayName` (String, queryable)
- `accentHex` (String, optional) — hex from `AppearanceSettings`. Used to render the friend's cookbook in their accent.
- `createdAt` (Date, queryable + sortable)
- `lastCookedAt` (Date, optional, queryable + sortable) — when this user last marked a cook complete
- `lastCookedRecipeID` (String, optional) — `Recipe.id` of the most-recently-cooked item
- `lastCookedTitle` (String, optional) — denormalized title for cheap display without fetching the full recipe
- `cookingStartedAt` (Date, optional) — non-nil while at least one `ActiveCook` is live. Cleared when the session goes empty. Drives the glowing-dot indicator.

`UserProfile.accentHex` is updated on the CloudKit side every time the local user changes their accent in settings. Cheap write, fires on `AppearanceSettings.accentHex` didSet.

`lastCooked*` fields update on cook completion (existing event that sets `Recipe.lastCookedAt`). `cookingStartedAt` updates on `CookingSession.start` / `addParallel` (set if currently nil) and on the transition to zero active cooks (clear). One write per cook start, one per session-end. Negligible volume.

**`Friendship`** — one per accepted friendship. Symmetric: written once, readable by both parties.
- `userA` (String, queryable) — lexicographically smaller of the two userRecordNames
- `userB` (String, queryable) — the larger one
- `requesterID` (String) — who sent the invite
- `status` (String) — `pending` | `accepted` (only `accepted` is queryable for friends-list)
- `acceptedAt` (Date, queryable + sortable, optional)

Sort-then-store `userA`/`userB` so each pair has exactly one record regardless of who initiated.

**`PublishedRecipe`** — your library, mirrored. One per local recipe per user.
- `ownerID` (String, queryable) — userRecordName of owner
- `localRecipeID` (String, queryable) — owner's local Recipe.id (so we can update/delete by lookup)
- `envelope` (CKAsset) — same JSON envelope shape as existing `RecipeShare`
- `photo0`–`photo19` (CKAsset, optional) — same convention as existing `RecipeShare`
- `recipeTitle` (String, queryable + sortable) — for browse list rendering without downloading envelope
- `originalCreatorID` (String, queryable, optional) — userRecordName of the original creator if this was imported (chains back through the import graph)
- `originalRecipeID` (String, optional) — the very first `localRecipeID` in the chain
- `updatedAt` (Date, queryable + sortable)

**`RecipeImport`** — audit row, one per import event. Powers the counter and the "who imported this from me" list.
- `originalCreatorID` (String, queryable) — root creator's userRecordName
- `originalRecipeID` (String, queryable) — root recipe id
- `importerID` (String, queryable) — who imported
- `importerDisplayName` (String) — denormalized for cheap display
- `sourceUserID` (String) — who they imported it FROM (immediate parent, may equal originalCreatorID)
- `importedAt` (Date, queryable + sortable)

**Counter implementation:** the count of imports for one of your recipes is `count(RecipeImport where originalRecipeID == X)`. CloudKit doesn't have atomic counters, so we don't try — we query and cache. Update the cache opportunistically when the recipe is opened.

### Local (SwiftData) additions to `Recipe`

```swift
@Model final class Recipe {
    // ...existing fields...

    var originalSharerUserRecordName: String?   // who you imported it from (immediate)
    var originalSharerDisplayName: String?      // denormalized for offline display
    var originalCreatorUserRecordName: String?  // root creator (chain root)
    var originalRecipeID: String?               // root recipe id (chain root)
    var importedAt: Date?
    var importCountCache: Int                   // refreshed on detail open
    var importCountCheckedAt: Date?
}
```

`originalSharer*` is the immediate parent (the friend you tapped). `originalCreator*` chains back. Display the **original creator** in the "Originally shared by" header — that's the value users care about.

## Library publishing model

Every recipe in your library auto-publishes as a `PublishedRecipe` once you have at least one accepted friend. Triggers:

- On `Recipe.apply(_:)` save in editor → enqueue mirror write.
- On recipe deletion → delete the matching `PublishedRecipe`.
- On first friendship acceptance → bulk-publish the whole library.
- On last friendship removal → bulk-unpublish (deferred — fine to leave records).

**Write amplification mitigation:** debounce mirror writes per recipe (e.g. 5s) and batch in a `LibraryMirrorService`. A single editor session that hits Save four times only writes to CloudKit once.

**Privacy stance:** the public DB is technically world-readable, but records are only **discoverable** by knowing a friend's `userRecordName`. Recipes aren't sensitive data — this is the right tradeoff. We do not build per-recipe-private toggles in the MVP.

## Friend request flow

1. User taps `+` (right of the Friends heading in `ProfileView`).
2. A small popover appears with a single text input: "Search by name…".
3. As the user types (debounced 300ms, fires after ≥2 characters), `CloudKitService.searchUserProfiles(prefix:)` queries `UserProfile` where `displayName BEGINSWITH <input>`, case-insensitive, limit 20, ordered by Display Name.
4. Each result row renders: `[● accent dot]  Display Name  ·  Joined <month year>     [+]`.
5. Tapping the row's `+` writes a `Friendship` record:
   - `userA` / `userB` = the two userRecordNames, sorted lexicographically
   - `requesterID` = me
   - `status = pending`
   - The row's `+` flips to a clock/"Pending" badge. Tap again to cancel (deletes the record).
6. The recipient's app sees the pending `Friendship` (queried at app foreground via `CloudKitService.fetchIncomingRequests()` — userRecordName matches `userA` or `userB`, `status == pending`, `requesterID != me`).
7. Recipient sees a **Requests** section in their `ProfileView` (between the Display Name block and the Friends list). Each row: `[● dot] Display Name   [Deny] [Approve]`.
8. **Approve** → flip `Friendship.status = accepted`, set `acceptedAt = .now`. Both users now see each other in their Friends lists.
9. **Deny** → delete the `Friendship` record. No notification fired to the requester (saves face — they just see the request silently disappear from their Pending state on next sync).
10. CKSubscription on `Friendship` pushes "X accepted your friend request" to the requester on approval (deferred to slice 6).

**Self-handling:** the search query filters out my own userRecordName client-side. No "add yourself" footgun.

**Already-friends / already-pending handling:** the `+` button on a search row checks the local cache + a quick CK lookup before writing. If a friendship already exists in any state, the `+` shows the appropriate state (Pending / Friends / Cancel) instead of letting you double-write.

## Friends UI

### `ProfileView` layout (the spec)

The whole Profile tab is now structured around Friends as its primary content.

```
┌──────────────────────────────────────────────┐
│ [⚙]                                          │   ← cog top-left, llama centered (existing)
│              [llama logo]                    │
│             Cookbook Title                   │   ← existing
│           [ Display Name ✎ ]                 │   ← editable, inline (existing pattern)
│         Last cooked: Lasagna                 │   ← new, only renders if lastCookedTitle != nil
│                                              │
│  Requests (2)                                │   ← only renders when count > 0
│  ┌────────────────────────────────────────┐  │
│  │ ● Anna Bianchi      [Deny] [Approve]  │  │
│  │ ● Marco Rossi       [Deny] [Approve]  │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  Friends                              [+]    │   ← section header + add button
│  ┌────────────────────────────────────────┐  │
│  │ ● Anna Bianchi                        │  │
│  │ ● Marco Rossi                         │  │
│  │ ● Sofia Greco                         │ A│   ← A–Z scrub on the right edge
│  │  ...                                   │ B│      (reuse Library's scroller)
│  │                                        │ C│
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

| Element | Behavior |
|---|---|
| Cog (top-left) | Opens a small sheet with **Sign Out** and **Delete Account**. Both move out of inline Profile and live exclusively here. |
| Llama + Cookbook title + Display Name | Unchanged from current `ProfileView`. Display Name remains inline-editable. Display Name edits propagate to `UserProfile.displayName` on CloudKit. |
| Last cooked line | Renders below Display Name when `lastCookedTitle != nil`. Format: `Last cooked: <Title>`. Tap → opens that recipe's detail. Hidden entirely if user has never cooked anything. |
| Requests section | Only renders when there are pending incoming requests. Each row: accent-color dot + Display Name + Deny + Approve buttons. Approve flips `Friendship.status` to `accepted`; Deny deletes the record. |
| Friends heading | Static label. Empty-state copy when `friends.count == 0`: *"No friends yet. Tap + to find someone you know."* |
| `+` button (right of heading) | Opens a small inline popover (NOT a full sheet) containing a single text input ("Search by name…") and a results list below it. Search debounces at 300ms after ≥2 characters. Each result row has its own `+` to send a request. See "Friend request flow" for full behavior. |
| Friends list | Alphabetical by Display Name. Each row: accent-color dot (their `accentHex`) + Display Name. The dot **glows** if that friend is currently cooking (see "Presence indicator" below). Tap → push `FriendLibraryView`. Long-press → "Remove friend" confirmation. |
| A–Z scroller | Reuse the same component as `LibraryView`'s alphabetical scrub. |

### Presence indicator (the glowing dot)

A friend is considered "cooking now" when:

```
profile.cookingStartedAt != nil
  && Date.now.timeIntervalSince(profile.cookingStartedAt!) < 6 * 3600
```

The 6-hour ceiling is a stale-state guard — protects against the app being force-killed mid-cook leaving `cookingStartedAt` stuck on the server. Most cook sessions are well under 4 hours; 6 is a comfortable buffer.

Visual: the small accent-color dot pulses with a soft glow. SwiftUI implementation roughly:

```swift
Circle()
    .fill(friend.accentColor)
    .frame(width: 10, height: 10)
    .shadow(color: friend.accentColor.opacity(isCooking ? 0.9 : 0),
            radius: isCooking ? 6 : 0)
    .scaleEffect(pulse ? 1.15 : 1.0)
    .animation(isCooking
        ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
        : .default,
        value: pulse)
    .onAppear { if isCooking { pulse = true } }
```

The same dot appears at the top of `FriendLibraryView`, in the friend's recipe card if you're previewing them, and (optionally — design call) in the import-attribution sheet.

**Update propagation:** `cookingStartedAt` is written on cook start, cleared on the transition to zero active cooks. Friends pick up the change either via CKSubscription (slice 6) or on next foreground refresh of the friends list. There's no realtime-presence socket — we trust the periodic-refresh + push model. A 30-60s lag in the dot turning on is acceptable.

### Friend-side views

| Surface | What it does |
|---|---|
| `FriendLibraryView` (new) | Mirrors `LibraryView` rendering — recipe cards from `PublishedRecipe` where `ownerID == friend`. Read-only (no long-press delete, no FAB). No tag chips in v1. **Renders entirely in the friend's accent color** (their `accentHex` from `UserProfile`) so visiting their cookbook feels visually theirs. Header at the top shows: their accent-color dot (glowing if cooking now) + Display Name + their `Last cooked: <Title>` line. |
| `FriendRecipeDetailView` (new) | Mirrors `RecipeDetailView` rendering, **also in the friend's accent**. Top toolbar: llama centered (existing pattern), **import button (`square.and.arrow.down`) immediately to its left**. No edit, no share, no delete. |
| `RecipeDetailView` (existing, mine) | If `originalSharerDisplayName != nil`, show **"Originally shared by [name]"** caption above the title. Tap opens a small attribution sheet with original creator name + import date. |
| `RecipeDetailView` → import counter chip | Small `imported by N` chip near title; tap shows list of importers + dates pulled from `RecipeImport` records. |

`FriendLibraryView` and `FriendRecipeDetailView` reuse the existing rendering components (`RecipeImageView`, `PhotoCarouselView`, ingredient and step rendering) — they're just data-source swaps with a scoped tint override.

### Friend accent color rendering — implementation note

Apply via `.tint(Color(hex: friend.accentHex))` at the root of `FriendLibraryView` and `FriendRecipeDetailView`. This works for all SwiftUI primitives (buttons, navigation tints, accent-styled text, the chip on ingredient rows).

**Known limitation:** the three deliberate UIKit-appearance reaches documented in CLAUDE.md (`UIView.appearance().tintColor`, `UIPageControl.appearance()`, `ShareSheet`) are global and won't respect the scoped tint. `UIPageControl` shows up in `PhotoCarouselView` page dots — those will stay your color, not the friend's. Acceptable for v1; revisit if it looks jarring in practice.

## Import flow (the toolbar button)

**Visual:** existing share icon (`square.and.arrow.up`), rotated 180° so the arrow points down. SF Symbols has `square.and.arrow.down` already — use that directly, no rotation needed. Place it where the share button currently sits (right side) but on the **left of the llama** in `FriendRecipeDetailView`'s toolbar.

**Behavior on tap:**

1. Animate the icon (haptic + scale-pulse).
2. Begin import: pull the full envelope + photo CKAssets via `CloudKitService.fetchPublishedRecipe(_:)`.
3. Decide animation up front based on photo count:
   - **0 photos:** fast path. Animate the icon flying down to the bottom-left (where the Library tab/back button is) and back to its origin in ~600ms. No progress indicator.
   - **1+ photos:** show the **llama progress indicator** overlay (same component as cloud-share). Photos download serially or in small parallel batches.
4. On completion, call a new `RecipeShare.materializeFromPublished(_:into:attribution:)` which:
   - Deep-copies envelope into a new `Recipe` with fresh UUIDs (existing logic).
   - Sets `originalSharerUserRecordName`/`originalSharerDisplayName` to the friend.
   - Sets `originalCreatorUserRecordName`/`originalRecipeID` to the chain root (copied from the friend's record if present, otherwise to the friend themselves).
   - Sets `importedAt = .now`.
5. Write a `RecipeImport` record to CloudKit (fire-and-forget, queued via outbox if offline).
6. Auto-publish the new local recipe as a `PublishedRecipe` so YOUR friends can also see it (carrying chain attribution forward).
7. Dismiss `FriendRecipeDetailView`, navigate to the newly-imported recipe in your own library with a confirmation toast.

**Empirical guess on timing:** envelope is small (~10 KB JSON), so fetching that is sub-100ms. Photos at ~500 KB/each over LTE = ~1s each, over WiFi = ~200ms each. A 5-photo recipe is **2–5 seconds**, so we WILL need the llama progress indicator for typical recipes. The fast-icon-fly animation only covers photoless recipes.

**Failure modes:**
- Friend has unfriended me mid-import → CK returns "no permission" → toast "This recipe is no longer available" and abort.
- Photos fail mid-download → import the text-only recipe, surface a non-blocking toast "Some photos couldn't be downloaded" with a retry option.
- Offline → disable the import button with a tooltip ("Connect to import").

## "Originally shared by" attribution

Rendered at the top of `RecipeDetailView` for any recipe with non-nil `originalSharerDisplayName`. Tasteful: a small caption row above the title, accent-tinted, low visual weight.

```
Originally shared by Marco Rossi
Lasagna alla Bolognese                     ← existing title
```

Tap → small sheet:
- Original creator: name + when they created the recipe (if known)
- Imported by you: date
- Chain length if > 1: "passed through 2 friends"

If the original creator is also a current friend, the sheet name becomes a button that opens their library.

## Import counter on your own recipes

Below the title row, a small chip: `imported by 7`. Pulled from `count(RecipeImport where originalRecipeID == self.id)` cached in `importCountCache` and refreshed when detail opens (with a stale-while-revalidate strategy — show cached, fetch live, update if changed).

Tap the chip → sheet listing each `RecipeImport` row: importer display name + date, sorted newest first. This is a great delight surface — "your sourdough has been imported by 14 friends" is exactly the kind of feedback that makes social sticky.

## Implementation slices

| # | Slice | Scope | CK schema deploy? |
|---|---|---|---|
| 1 | UserProfile mirror | Add `UserProfile` record (incl. `accentHex`, `lastCooked*`, `cookingStartedAt`). On SIWA sign-in, upsert mine. Wire local hooks: cook complete → updates `lastCooked*`; cook start/all-end → updates `cookingStartedAt`; accent change → updates `accentHex`. Read others' on demand. | Yes |
| 2 | Invite link + Friendship | Generate link, share sheet, Cloudflare Pages `/f/` route, accept screen, `Friendship` write. Friends list in `ProfileView`. | Yes |
| 3 | Library mirror | `PublishedRecipe` upsert on Save, delete on delete, batch-publish on first friend, debounced via `LibraryMirrorService`. | Yes |
| 4 | Friends UI | `FriendLibraryView` + `FriendRecipeDetailView`, pulling from CK. Read-only renderers. | No |
| 5 | Import flow | New `materializeFromPublished`, toolbar button + animation, llama progress for photo-heavy, attribution fields on local Recipe, "Originally shared by" header. | No |
| 6 | Import audit + counter | `RecipeImport` writes on import, counter chip on own recipe detail, importer-list sheet, CKSubscription pushes for new imports + new friend requests. | Yes |

Slices 1–3 are infrastructure. Slice 4 is when it becomes visibly a feature. Slice 5 is the magic moment. Slice 6 is the delight pass.

## Schema deployment ritual (don't forget)

Per CLAUDE.md, every CloudKit schema change needs Dev → Prod deploy AND the manual photo-field-add for asset fields. Specifically:

- Slice 1: deploy `UserProfile` Dev → Prod.
- Slice 2: deploy `Friendship` Dev → Prod. Index `userA`, `userB`, `status` queryable.
- Slice 3: deploy `PublishedRecipe` Dev → Prod. **Manually add `photo0`–`photo19` Asset fields in the dashboard** — auto-discovery won't catch them on first publish, same trap that hit `RecipeShare`.
- Slice 6: deploy `RecipeImport` Dev → Prod. Index `originalRecipeID` queryable.

## Account deletion cascade

Extend the existing `cloudShareOutbox.v1` outbox handling to also wipe, on account deletion:
- The user's `UserProfile`.
- All `Friendship` records where they appear in `userA` or `userB`.
- All `PublishedRecipe` records where `ownerID == them`.
- All `RecipeImport` records where they're either the importer or the original creator. (Or: orphan them — keep the count but anonymize the importer name. Decide during slice 6.)

This is the App Store account-deletion compliance requirement; we already pass it for the existing share flow, so it's an extension not a new effort.

## Decisions locked

- **Friend request acceptance step:** YES. Tapping an invite link opens an accept screen, not auto-add.
- **Friends list location:** inside `ProfileView`, immediately below the existing llama / title / display-name block. No separate Friends tab.
- **Settings (Sign Out + Delete Account):** moved into a cog top-left of `ProfileView`.
- **Add Friend entry point:** `+` button right of the Friends heading, opens an inline popover.
- **Friend cookbook tinting:** uses friend's `accentHex` from their `UserProfile`. Mirrored on every accent change.
- **Avatar:** no upload UI in v1. Friends list rows show a small accent-color dot + Display Name. (Display Name initials inside the dot if we want — design call during slice 4.)

## Still open — please confirm

1. **What goes in the `+` popover?** I drafted it as **(a) Share my invite link** (primary, opens system share sheet) plus **(b) a Paste invite text field** for pasting links received outside iMessage. Was your "little input text" the paste field, the share-link entry, or something else (e.g. typing a Display Name to search — which we'd need handles for)?
2. **What does "Originally shared by" show when chain length > 1?** Recommend always showing the chain root creator. The intermediate friends are an implementation detail.
3. **Anonymize-on-delete vs hard-delete `RecipeImport` rows?** Recommend anonymize — preserves counter integrity, which is a delight surface.
4. **Per-recipe private toggle?** Deferred. Everything in your library is visible to friends. Add toggle later if user feedback demands it.

## What this doc does not cover

- In-app messaging / chat.
- Comments, ratings, or likes on friends' recipes.
- A public "explore" feed for non-friends.
- Group cookbooks / shared editing.
- Push notification copy and settings UX (slice 6 will cover the wiring; copy is a design pass).
