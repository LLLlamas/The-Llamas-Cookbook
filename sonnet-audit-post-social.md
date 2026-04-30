# Llamas Cookbook — Post-Social Audit (Slices 1–6)
*Generated 2026-04-30 by claude-sonnet-4-6*

## Summary

The friends/social feature is architecturally sound and follows the established coordinator-above-NavigationStack, `@Observable`, fire-and-forget cloud patterns consistently. No crashes or data-loss bugs were found. The dominant theme across findings is **CloudKit authorization gaps and public-DB exposure** that are benign today but will become real risks as the user base grows. Three medium-weight issues in the import path and the serial-fetch refresh model are the next most important things to address.

---

## Critical (crashes / data loss / security holes)

None found. No force-unwrap crashes, no unguarded optionals in the social paths, no data-model cascade holes specific to the social feature.

---

## High (auth/privacy gaps, race conditions, broken UX paths)

### [Security] `Lib/CloudKitFriendship.swift` — `currentUserID` parameter is optional and authorization check is silently skipped when nil

`approveFriendRequest(recordName:currentUserID:)` and `deleteFriendship(recordName:currentUserID:)` accept `currentUserID: String? = nil`. When nil, the guard block that verifies `currentUserID == userA || currentUserID == userB` is skipped entirely, allowing any caller with the friendship record name to approve or delete any friendship without identity verification.

The three live call sites in `FriendsStore` all pass the correct `me` value, so production paths are safe today. However, future call sites that omit the parameter (or any internal test) would silently bypass access control on a world-writable public DB record.

**Fix:** Make `currentUserID: String` non-optional (remove the `= nil` default). The `deleteAllFriendships` cascade path already passes the correct argument, so this is a one-line signature change with no behavioral impact.

---

### [Security/Privacy] `Lib/CloudKitUserProfile.swift` — `UserProfile` records are world-queryable by name prefix with no server-side rate-limit or identity gate

`searchUserProfiles(prefix:)` executes a `displayName BEGINSWITH[c]` query on the public DB. Any iCloud-authenticated user (not just Llamas Cookbook users) can enumerate all `UserProfile` records by iterating two-letter prefixes. The 2-character minimum and 20-result cap are **client-side only** — a direct CK SDK call bypasses them entirely.

Each record carries `displayName`, `accentHex`, `cookingStartedAt` (presence signal), `lastCookedTitle`, and `lastCookedAt`. `cookingStartedAt` and `lastCookedTitle` constitute real-time presence data that any iCloud user can observe.

**Fix (CloudKit Dashboard, not code):** Add a CK Security Role restriction so only users whose own `UserProfile` record exists can query the type. **Also:** Add a note to CLAUDE.md's capability map documenting this posture so contributors don't add more sensitive fields to `UserProfile` without revisiting the security model.

---

### [Social correctness] `Lib/CloudKitRecipeImport.swift` — `deleteAllRecipeImports` OR predicate requires both fields to be queryable; missing index causes silent cascade failure

The query `importerID == %@ OR originalCreatorID == %@` runs at account-deletion time. CloudKit public DB requires every field in an OR compound predicate to have a queryable index. If either index is missing (they must be added manually in the Dashboard), the query throws `CKError.invalidArguments` at runtime.

The call site uses `guard let matchResults = try? await`, swallowing this error — meaning every `deleteAccount()` call silently skips `deleteAllRecipeImports`, leaving audit rows stranded in CloudKit. This is an App Store Review compliance risk.

**Fix:** Split into two sequential single-field queries (`importerID == me`, then `originalCreatorID == me`) to eliminate the OR requirement entirely. This also makes each sub-query independently fallible without cascading.

---

## Medium (code quality, fragile patterns, missing error handling)

### [Fragile] `App/FriendsStore.swift` — serial per-friendship CloudKit fetches in `refresh()` are O(N) round-trips

For N accepted friends, `refresh()` fires one `fetchUserProfile` call per friend sequentially inside a for-loop. At N=20, this is 20 back-to-back CK round-trips (~100–300ms each on LTE), producing a 2–6 second wait every time ProfileView opens.

**Fix:** Collect all `otherID` values first, then fan out in a `withTaskGroup` capped at ~10 concurrent fetches, collecting results into the three buckets.

---

### [Fragile] `Views/Friends/FriendRecipeDetailView.swift` — `Task.detached` in `writeImportAuditRow` captures a SwiftData `@Model` reference across the concurrency boundary

`Task.detached` is used correctly (values captured are all value types or `String`). However, the `newRecipe` argument passed into `writeImportAuditRow(for:)` is a SwiftData `@Model` reference, which is not `Sendable`. Inside the method, only `newRecipe.originalCreatorUserRecordName` and `newRecipe.originalRecipeID` are read — both `String?` — but `SWIFT_STRICT_CONCURRENCY: minimal` does not flag this. If the SwiftData context is torn down before the detached task reads those properties (possible on fast delete-then-import sequences), the reads are undefined behavior.

**Fix:** Extract the two `String?` values before the detachment boundary and capture the extracted strings instead of the `@Model` reference.

---

### [Fragile] `Views/Friends/FriendRecipeDetailView.swift` — double-tap window on photoless imports

`isImporting = true` is set only when `hasPhotos` is true. For photoless imports `isImporting` is never set to true before the first `await`, making the `guard !isImporting else { return }` guard at the top useless for that path. A double-tap between the `canImport` check and the first `await` fires two `performImport()` calls simultaneously.

**Fix:** Set `isImporting = true` unconditionally at the very start of `performImport()`, before any condition check. Conditionally show the photo-progress overlay separately.

---

### [Social correctness] `Lib/CloudKitSubscriptions.swift` — `exhaustedRetries` failure in `writeRecipeImport` is silently discarded

The two-attempt retry only helps an extreme record-ID collision case. Network timeout, quota exceeded, or permission errors throw `exhaustedRetries` which propagates to a `try?` site in `FriendRecipeDetailView.writeImportAuditRow`, silently discarding the failure with no logging.

**Fix:** Add an `os_log` (or `Logger`) call on the `exhaustedRetries` path to make audit-write failures observable in device logs during development. No user-visible behavior change.

---

### [Code quality] `Views/Friends/FriendRecipeDetailView.swift` — inline `.sorted { $0.order < $1.order }` on envelope types

Three places sort ingredients, steps, and photos by `order` inline. Per CLAUDE.md, `Recipe.sortedIngredients` etc. are the canonical helpers, but those operate on SwiftData `@Model` types. The envelope types (`LCRecipeShareV1.ShareIngredient`, etc.) have no equivalent.

**Fix:** Add `sortedIngredients`, `sortedSteps`, and `sortedPhotos` computed properties to `LCRecipeShareV1.ShareRecipe` (as an extension) so all envelope-side views use the same one-liner. Prevents a future contributor from sorting the other direction by mistake.

---

### [Side-effect] `Views/Detail/RecipeDetailView.swift` — direct mutation of `importCountCache` and `importCountCheckedAt` on the `@Model` triggers `updatedAt` change, which re-publishes to CloudKit via `LibraryMirrorService`

`RecipeDetailView` mutates `recipe.importCountCache` / `recipe.importCountCheckedAt` directly (same pattern as `recipe.favorite`). This is intentional for persistence but has a side effect: SwiftData's change notification propagates `updatedAt`, causing `LibraryMirrorService.enqueueUpsert` to re-publish the recipe to CloudKit. A user with popular recipes who opens Detail frequently triggers CloudKit publishes on every chip refresh.

**Fix (two options):**
1. Store the import count cache in UserDefaults keyed by `recipe.id` instead of on the `@Model` — no SwiftData change notification, no re-publish.
2. Add a `wasOnlyImportCountRefresh` sentinel and guard `LibraryMirrorService.enqueueUpsert` against it.

---

## Low (style, dead code, minor inconsistencies)

### [Style] `Views/Friends/FriendRecipeDetailView.swift` — redundant `@MainActor` on a `View` method

The `performImport` method is marked `@MainActor` but `FriendRecipeDetailView` is a `View` (already `@MainActor` implicitly on iOS 18). Annotation is harmless but adds noise. Remove it.

---

### [Consistency] `Views/Detail/AttributionSheet.swift` — comment references `pendingFriendOpenID` on `NavigationContext` which does not exist

The comment describes a v2 navigation hook ("closes this sheet and navigates to their friend library via the `pendingFriendOpenID` signal on `NavigationContext`"). `NavigationContext` has no such field. This is a stale plan reference.

**Fix:** Update the comment to "v2 tap-to-friend-library navigation is deferred; `NavigationContext.pendingFriendOpenID` was never added."

---

### [Consistency] Environment re-injection pattern is inconsistently applied across social sheets

`ImportersListSheet` is injected with `.environment(appearance)` but not `.environment(friendsStore)`. `AttributionSheet` is injected with both. `ImportersListSheet` doesn't consume `FriendsStore` today, so the omission is correct now — but if it ever does (e.g., showing whether an importer is a current friend), the missing re-injection produces a silent environment lookup failure.

**Fix:** Establish a convention: re-inject all app-level `@Observable` values into every social sheet, not just the ones currently consumed.

---

### [Deferred — now higher priority] Duplicate `Friendship` records possible across two devices

`sendRequest` has a client-side duplicate guard but no server-side uniqueness constraint on `(userA, userB)` in CloudKit. A user with two devices, or a force-killed app mid-send, can create two `Friendship` records for the same pair. `FriendsStore.refresh()` would surface both — one in `accepted`, one in `pending` — corrupting the friendship state machine.

**Fix:** In `approveFriendRequest`, query for an existing record with the same pair before writing a new `Friendship` record.

---

## Concurrent navigation: Can you edit a recipe while viewing a friend's recipe list or detail view?

**Short answer: No — silently broken in one key scenario.**

The architecture:
- The **Profile/Friends sheet** is presented from `LibraryView` (inside the `NavigationStack` inside `RootView`) via `showingProfile`.
- The **Editor sheet** is presented from `RootView` directly via `editorBinding`.
- The editor has `.presentationBackgroundInteraction(.enabled(upThrough: .height(80)))`, so the LibraryView background (including the profile button) IS interactive when the editor is minimized to its 80pt detent.

The problematic scenario:

> User opens editor → minimizes it to 80pt → taps the Profile/person button → **nothing happens**

When the editor sheet is active (even minimized), iOS/SwiftUI blocks a second sheet from being presented from a child view (`LibraryView`). The `showingProfile = true` state change fires, but SwiftUI silently suppresses the actual presentation. The user sees no feedback.

The reverse scenario (Profile open → try to open editor) is less broken: `editor.active` being set on `RootView` may present the editor on top of the Profile sheet, since they originate from different hierarchy levels. However, this is fragile and untested behavior.

**Fix:** Disable the profile toolbar button in `LibraryView` when `editor.active != nil`:

```swift
// In LibraryView toolbar
Button {
    Haptics.selection()
    showingProfile = true
} label: {
    Image(systemName: ...)
}
.disabled(editor.active != nil)  // Add this
```

This requires `LibraryView` to read `@Environment(EditorCoordinator.self) private var editor`, which it already should have (it's injected in `RootView`). This gives the user clear feedback (greyed icon) that the profile is inaccessible while editing, which is honest about the modal constraint.

**Alternative fix (larger scope):** Present the Profile sheet from `RootView` as a `fullScreenCover` so it sits at the same hierarchy level as the editor sheet, allowing iOS to manage the two independently. This requires extracting `showingProfile` into `NavigationContext` or a new `@State` on `RootView`.

---

## Cross-surface observations

**Display-name denormalization is inconsistent.** `RecipeImportRecord` stores `importerDisplayName` as a denormalized string (used by `ImportersListSheet`). `FriendshipRecord` does NOT store a display name. `PublishedRecipeSummary` stores `recipeTitle` but not `ownerDisplayName`. This means `FriendLibraryView` can only be pushed with a full `UserProfileSnapshot` — document this constraint explicitly so a future refactor doesn't try to construct the view from just an `ownerID`.

---

## Recommended fix order

| Priority | File(s) | Change |
|---|---|---|
| 1 | `Lib/CloudKitFriendship.swift` | Make `currentUserID` non-optional — eliminates auth bypass class |
| 2 | `Lib/CloudKitRecipeImport.swift` | Split OR predicate into two sequential queries — ensures account deletion always works |
| 3 | `Views/Friends/FriendRecipeDetailView.swift` | Set `isImporting = true` unconditionally — closes double-tap window |
| 4 | `Views/Friends/FriendRecipeDetailView.swift` | Extract `String?` properties before `Task.detached` — strict-concurrency safety |
| 5 | `Views/Library/LibraryView.swift` | Disable profile button when `editor.active != nil` — fixes silent broken UX |
| 6 | `Lib/CloudKitSubscriptions.swift` | Add `os_log` on `exhaustedRetries` path — makes failures observable |
| 7 | `Views/Detail/RecipeDetailView.swift` | Move `importCountCache` to UserDefaults — stops phantom CloudKit re-publishes |
| 8 | CloudKit Dashboard | Add CK Security Role to restrict `UserProfile` queries to registered users |
| 9 | `CLAUDE.md` | Document CloudKit public DB security posture; note `pendingFriendOpenID` was never added |
| 10 | `Views/Detail/AttributionSheet.swift` | Fix stale `pendingFriendOpenID` comment |
