# Friend Timer Indicators — Implementation Plan

Status: planning. Author handoff doc; nothing in this file is in code yet.

## Goal & UX intent

Today, when a friend is in cook mode, friends see (a) the pulsing presence dot, (b) a "Currently Cooking: <title>" eyebrow, and (c) the friend-card cooking border. We want those same surfaces to **also** surface the friend's currently-active cook-mode timers — e.g. *"Pasta — 4:32 left"* or *"Sauce ready ✓"* — with the displayed countdown ticking live in the local UI.

"Live" here is **two-tier**:

- **Server-driven cadence** — push or refresh updates the *set* of timers and their `endsAt`. Realistic floor today is whatever push/refresh granularity already drives `cookingStartedAt`. New timers and cancellations propagate seconds-to-minutes after the cooking friend taps.
- **Client-driven cadence** — once a timer's `endsAt` is in hand, the countdown ticks every second locally (`Timer.publish(every: 1, ...)` or the existing per-second tick pattern in `CookModeView`). No round-trip per second.

This is the same trick `CookModeView` already uses for the user's own timer (`tickTimer()` in `CookModeView.swift` increments a local `now` once per second; `endsAt` comes from state).

## Important architectural fact uncovered during research

`CloudKitSubscriptions.swift` currently has **two** push subscription kinds — `friendship` and `recipeImport`. **There is no `UserProfile` push subscription today.** Friend presence changes (cookingStartedAt, lastCookedTitle) are picked up *only* by foreground refresh in `FriendsStore.refreshIfStale(minimumAge: 30)` — fired from scene-active hooks and `.task` on Profile/Friends surfaces. That means:

- Today, a friend who's already on the Friends tab when *you* start cooking won't see your dot light up until they leave and come back to the tab (or 30s pass and a refresh is triggered).
- Adding live timers under the same model means timers will appear / update on the same lazy cadence — fine for the first cut, but worth flagging.
- A real "live" experience (timers that show up within seconds of the friend tapping Start) would require a new `userProfile-events-friends-of-<me>` push subscription. That's a meaningful schema/predicate design problem (CloudKit subscriptions key off the *changed* record, not "records owned by my friends" — you'd need each friend's friends to subscribe to `recordName IN <list of friend recordNames>`, which CK predicates can express but at a quota cost). **Punt this to a phase 4.**

The phase-1 design below assumes the existing foreground-refresh model. Lorenzo decides whether to upgrade to push.

---

## Data model changes

### `UserProfile` (CloudKit public DB) — add one new field

| Field | Type | Notes |
|---|---|---|
| `activeTimers` | `String` (optional) | JSON-encoded array of compact timer descriptors. Not queryable; not sortable. Read by recordID. |

JSON shape (one element per running timer):

```json
[
  { "label": "Pasta", "endsAt": "2026-05-07T18:42:11Z", "stepNumber": 3, "ringing": false },
  { "label": "Sauce", "endsAt": "2026-05-07T18:39:00Z", "stepNumber": 5, "ringing": true }
]
```

**Why JSON-as-String, not parallel String-List fields:**

- A `String List` schema forces the field to be queryable in CloudKit Console, which we don't need (we read by recordID, see `fetchUserProfile`). String-as-JSON keeps the field non-queryable and avoids a CK index.
- Multiple parallel `String List` fields (`timerLabels[]`, `timerEndsAt[]`, …) would require ordering invariants across lists — fragile.
- A single optional `String` field is the smallest schema delta and the easiest to evolve (add a new key in the JSON without re-indexing).
- Size is bounded — `CookingSession.maxConcurrentCooks` = 4, and one timer per cook = 4 entries × ~80 bytes = ~320 B. Well under any CK record limit.

**Schema-deployment ritual** (per CLAUDE.md convention): the `activeTimers` field must be added manually in CloudKit Console (Dev → Prod) before the write path is enabled. Auto-discovery via record write *will* create the field type but won't provision it through Prod, and CLAUDE.md flags this for `RecipeShare.photo0–photo19` as well. List as a deploy-time checklist item.

### `UserProfileSnapshot` (`CloudKitUserProfile.swift`)

Add:

```swift
struct ActiveTimerInfo: Codable, Hashable {
    let label: String
    let endsAt: Date
    let stepNumber: Int
    let ringing: Bool
}

// on UserProfileSnapshot:
let activeTimers: [ActiveTimerInfo]
```

Decode in `init(record:userRecordName:)` by reading the `activeTimers` String, base64? no — plain JSON UTF-8 — and `JSONDecoder().decode([ActiveTimerInfo].self, ...)`. Defensive: empty array on decode failure, missing field, or empty string. Same defensive posture the existing init takes for `displayName`.

### `TimerAlarmMetadata` (`Sources/Shared/TimerAlarmMetadata.swift`)

No change needed for phase 1 — the metadata is already shared between app + widget for AlarmKit's local presentation. The cloud-mirror payload is a **separate shape** (`ActiveTimerInfo`) because it's what *friends* see, not what AlarmKit's lock-screen UI consumes. Keeping them separate avoids coupling the cloud schema to widget-side rendering choices.

---

## Write path

### Where the hooks go

The cooking-side mirror calls live in `Sources/Lib/UserProfileMirror.swift`. Add:

```swift
// MARK: - Cooking timers (phase 1)

/// Snapshot of all running timers across all active cooks. Called
/// after every timer add/extend/cancel/fire. Debounced 1s — the
/// SwiftUI binding can fire several updates inside one user action
/// (start timer → schedule alarm → tick loop kicks in).
static func updateActiveTimers(_ timers: [ActiveTimerInfo]) {
    timersDebounceTask?.cancel()
    timersDebounceTask = Task {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        guard let recordID = cachedRecordID() else { return }
        let payload: String?
        if timers.isEmpty {
            payload = nil  // null on cloud → friends see no chips
        } else if let data = try? JSONEncoder().encode(timers),
                  let s = String(data: data, encoding: .utf8) {
            payload = s
        } else {
            payload = nil
        }
        try? await CloudKitService.upsertUserProfile(userRecordName: recordID) { record in
            if let payload {
                record["activeTimers"] = payload as NSString
            } else {
                record["activeTimers"] = nil
            }
        }
    }
}
```

Mirror the existing `accentDebounceTask` shape — module-level `Task<Void, Never>?`, cancel-and-replace.

### Wiring sites

Three places need to call `updateActiveTimers(...)`:

1. **`CookingSession.swift`** — owns the canonical "what's currently live across all cooks" state (`activeCooks: [ActiveCook]`, each with `timerEndsAt` / `timerLabel` / `timerStepID`). Add a private `pushTimerSnapshot()` that builds `[ActiveTimerInfo]` from `activeCooks` (filtering out cooks with `timerEndsAt == nil`) and calls `UserProfileMirror.updateActiveTimers(...)`. Invoke from:
   - `start(_:)` (no timers yet, but covers the "cleared from previous cook" case)
   - `addParallel(_:)`
   - `remove(cookID:)`
   - `endAll()` — passes `[]` so the cloud field clears
   - `persistForegroundedSnapshot(_:)` — already runs after every per-tick mutation in CookModeView (timer start, extend, cancel)

2. **`CookModeView.swift`** — the per-cook `@State` for `timerEndsAt` etc. already pushes through `persistForegroundedSnapshot` after every mutation, so wiring through the session (point 1) is sufficient. **No direct `UserProfileMirror` calls from `CookModeView`** — keeps the view thin and the session as the single source of truth.

3. **AlarmKit fire / dismiss** — when a timer hits zero, the user may not have re-opened the app yet, so `CookingSession`'s in-memory state still says "this timer is running" with `timerEndsAt` in the past. **For phase 1, skip a "ringing" state** (see "Phased rollout" below) — just let the chip continue to count toward zero and render `0:00` once `endsAt` passes. When the user dismisses the AlarmKit alert and returns to Cook Mode, the existing `cancelTimer()` path runs and clears `timerEndsAt`, which propagates a fresh snapshot.

### Debounce rationale

`updateActiveTimers` debounces 1 second (vs. accent's 2s) — accent fires on slider tick (~30 Hz), timers fire on discrete user actions (start / cancel / extend) plus the per-second tick re-saves the snapshot to UserDefaults but doesn't change the timer set itself. 1s is enough to coalesce a fast "start → extend by 1 min → extend by 5 min" burst into one CK write while keeping the cloud reasonably current.

A future optimization: **only push when the timer set actually changed**, not on every tick-driven `persistForegroundedSnapshot`. Compare a hash of the proposed `[ActiveTimerInfo]` against a `lastPushedTimersHash` static and short-circuit if equal. Worth doing on day one — the per-second tick path runs through `persistForegroundedSnapshot` every second.

### Last-write-wins / re-entrancy

Same posture as accent: cancel-and-replace the debounce task, single writer (the local user is the only one writing their own profile), CloudKit's `serverRecordChanged` is acceptable to swallow because the next snapshot push will reconcile.

---

## Read path

### Where the data lands

`UserProfileSnapshot.activeTimers: [ActiveTimerInfo]` is populated by the existing `fetchUserProfile` round-trip in `FriendsStore.refresh()` — the `withTaskGroup` parallel fetch over `otherIDs` already runs once per refresh. **No new round-trips needed for phase 1.**

When `FriendsStore.refresh()` finishes, every `friend.activeTimers` is fresh. SwiftUI's `@Observable` propagation re-renders `FriendsTabView`, `FriendLibraryView`, `FriendRecipeDetailView` automatically.

### Push subscription (deferred to phase 4)

`CloudKitSubscriptions.swift` does not currently subscribe to `UserProfile` changes. A new `userProfile-events-<friend>` subscription, one per friend, would be expensive (linear in friend count) and quota-heavy. Better long-term option: a `friendship-presence-<me>` subscription on a future `Presence` record type that the cooking friend writes into a small per-pair record. That's a phase-4 schema discussion.

For phase 1 / 2 / 3: **explicitly accept the foreground-refresh cadence** — same as today's `cookingStartedAt`. Document the limitation in the chip's empty-state behavior (see "Stale data" gotcha below).

### Local tick path

When a chip is on screen, the displayed `mm:ss` is computed from `endsAt - Date()`. A single per-view `Timer.publish(every: 1, on: .main, in: .common).autoconnect()` drives a `@State var now: Date = .init()` that gets read by every visible chip. Same shape as `CookModeView.tickTimer()`. **One ticker per view, not per chip** — five chips on FriendsTab tick off the same publisher.

---

## Render path

### Surfaces (in priority order)

| View | Where the chip(s) go | Density |
|---|---|---|
| `FriendRecipeDetailView` | Below the title block, above the photos / meta. Same horizontal indentation as the existing accent meta line. | Up to 3 chips, "+N more" pill. **Phase 1.** |
| `FriendLibraryView.headerLabel` | Beside the existing "Currently Cooking: <title>" eyebrow — same horizontal row. Single inline chip ("4:32 — Pasta") if room, else collapsed glyph + count. | Phase 2. |
| `FriendsTabView` `FriendCardView.cookingLine` | Replaces the static "Cooking: <title>" eyebrow with a dynamic "Cooking: <title> · 4:32" when one timer is running, falls back to current copy when none. | Phase 2. Resist showing more than one timer on the card — it's already dense. |

### Chip shape

Reuse existing tokens — no new visual primitives:

```swift
struct FriendTimerChip: View {
    let info: ActiveTimerInfo
    let accent: Color
    let now: Date  // injected by the view's per-second ticker

    private var remaining: TimeInterval { info.endsAt.timeIntervalSince(now) }
    private var isReady: Bool { remaining <= 0 }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isReady ? "bell.fill" : "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            if isReady {
                Text("\(info.label) ready")
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Text("\(info.label) · \(formatRemaining(remaining))")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(AppColor.textPrimary)
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, 4)
        .background(accent.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 1))
    }
}
```

`formatRemaining` returns `m:ss` for sub-hour, `h:mm` for sub-day. Match the existing CookModeView formatter (`mm:ss` style; reuse if it's exposed, else duplicate the small helper — it's 4 lines).

### "Ringing" / "ready" state

For phase 1 + 2 we drive the ready state purely from `endsAt < now` on the *displayed* side — no `ringing` field on the cloud yet. This keeps the schema minimal and the friend's chip flips to "Pasta ready" the second the local clock crosses `endsAt`, without a cloud round-trip. Phase 3 introduces an explicit ringing flag if/when the cooking friend's "I dismissed the alarm" event needs to differentiate "ready, untouched" from "still on the lock screen ringing right now."

### Tinting

Always the friend's accent (`friend.accentHex` resolved through `Color(hex:)`, fallback to `AppColor.accent`). Mirrors `FriendCardView`, `FriendLibraryView`, `FriendRecipeDetailView`. Never the local user's accent.

---

## Hard invariants & gotchas

- **`UserProfile` recordName uses `profile_` prefix.** Already handled inside `CloudKitUserProfile.swift`; no external caller change.
- **`cloudKitDatabase: .none` (CLAUDE.md hard invariant).** Manual mirroring only — `UserProfileMirror.updateActiveTimers` is the *only* writer. Don't add a SwiftData side-effect.
- **Don't add a queryable index on `activeTimers`.** Read by recordID through `fetchUserProfile`; queryability would burn an unnecessary CK index slot.
- **`recordCookSessionEmpty` must also clear `activeTimers`.** Today it clears `cookingStartedAt`. Add `record["activeTimers"] = nil` in the same upsert closure so a force-quit-then-relaunch doesn't leave ghost timers visible to friends.
- **Sign-out / delete-account cascade.** `UserProfileMirror.clearAfterSignOut()` and `deleteOnAccountDeletion()` already cancel the `accentDebounceTask`. Add `timersDebounceTask?.cancel(); timersDebounceTask = nil` to both. Account-deletion goes through `enqueueUserProfileDeletion` → `CloudPendingDeleteQueue`, which deletes the whole record — `activeTimers` rides along automatically.
- **Re-entrancy: timers fire often.** Per-second `persistForegroundedSnapshot` calls all hit `updateActiveTimers`, so the debounce + last-write-wins pattern is load-bearing. The "skip push when set unchanged" optimization (hash compare in `updateActiveTimers`) is strongly recommended on day one.
- **Stale data when cooking friend force-quits.** `cookingStartedAt` already has a 6-hour client-side TTL (`UserProfileSnapshot.isCookingNow`). Apply the same gate to timer rendering: **if `friend.isCookingNow == false`, ignore `activeTimers` entirely.** A force-quit mid-cook leaves both `cookingStartedAt` and `activeTimers` stranded; the existing 6h TTL lets us drop both at once. Implement as a computed property on `UserProfileSnapshot`:

  ```swift
  var visibleTimers: [ActiveTimerInfo] {
      isCookingNow ? activeTimers : []
  }
  ```

  Every render-path consumer reads `visibleTimers`, never `activeTimers` directly.
- **Privacy.** A friend seeing your timer label is the same trust level as seeing your `lastCookedTitle` — both are user-authored strings tied to the active cook. Acceptable. (See open question below for whether to make it tighter.)
- **Photo-bytes / photo-cap rules don't apply** — the field is a small JSON string, not a CKAsset.
- **Do not touch `Recipe.apply(_:)` or step models.** The chain-attribution invariants in CLAUDE.md are unrelated to this work.
- **AlarmKit's role is unchanged.** The local lock-screen alert + Live Activity is still owned by AlarmKit. The new mirror is purely an additional cloud-side fan-out.

---

## Phased rollout

### Phase 1 — minimum viable

- CloudKit schema: add `activeTimers: String (optional)` to `UserProfile` in Dev + Prod.
- Code:
  - `UserProfileSnapshot`: add `ActiveTimerInfo` + `activeTimers` + `visibleTimers`.
  - `UserProfileMirror`: add `updateActiveTimers(_:)` with 1s debounce + hash-skip.
  - `UserProfileMirror.recordCookSessionEmpty`: clear `activeTimers`.
  - `UserProfileMirror.clearAfterSignOut` / `deleteOnAccountDeletion`: cancel debounce.
  - `CookingSession`: add `pushTimerSnapshot()` private helper, call from `start`, `addParallel`, `remove`, `endAll`, `persistForegroundedSnapshot`.
- UI: render up to 3 chips on `FriendRecipeDetailView` only. Per-second local ticker. Friend's accent. "ready" state derived from `endsAt < now`.
- Verification (manual on device because Lorenzo is on Windows): start a cook on phone A, watch chip appear in friend's `FriendRecipeDetailView` on phone B after a manual pull-to-refresh / tab switch.

### Phase 2 — surface coverage

- Add chip to `FriendLibraryView.headerLabel` (single inline form).
- Replace static cooking eyebrow on `FriendCardView` with dynamic "Cooking: <title> · 4:32" when one timer running.
- Add a `+N more` collapse when timer count > 3.

### Phase 3 — ringing state

- Add `ringing: Bool` to `ActiveTimerInfo` JSON.
- Cooking-side: when AlarmKit fires (via the existing `ResumeCookModeIntent` notification posted by AlarmKit's secondary button, or by intercepting the in-app `timerExpired` flag in `CookModeView`), flip `ringing = true` for that timer's entry. When the user dismisses (struck step, cancelled timer), drop the entry.
- Friend-side: chip uses an explicit "ringing" treatment (pulsing border, bell icon) distinct from the passive "0:00" state. Ringing entries can stay in the array until the cooking user takes an action — friend sees "Pasta ready · 1m ago" instead of just "Pasta ready" (relative-time stamp).

### Phase 4 — true live (push)

- Stand up a per-friend `userProfile-events-<friend>` subscription, OR design a small `Presence` per-pair record type that's cheaper to subscribe to.
- Goal: a friend already on the Friends tab sees a new timer appear within ~5s of the cooking user tapping Start, no manual refresh needed.
- Re-evaluate quota cost — a 25-friend graph * 25 friends * 25 friends grows fast. Worth a dedicated design pass.

---

## Open questions for Lorenzo

1. **Timer-label privacy.** Right now the cooking user types the label freeform ("Pasta", "Pizza", or whatever). Is showing the *raw label* to friends fine, or do you want a coarser surface ("3 timers running, 1 ready")? My read is the labels are already low-stakes and match the `lastCookedTitle` precedent, so showing them is fine — but it's your call.

2. **FriendsTab card density.** The card already shows: dot, name, recipe count, saves OR friends-since, cooking eyebrow, thumbnail. Adding a live timer to that card pushes the line count by one. **Should the card show a timer at all** (phase 2), or should timers only appear once you tap into `FriendLibraryView` / `FriendRecipeDetailView`?

3. **"Ringing" / fired state.** Is phase-3's "Pasta ready · 1m ago" worth the schema complication, or do you want the chip to just disappear once the cooking friend dismisses the alarm and silently move on?

4. **Live cadence (the big one).** Are you OK with phase-1's foreground-refresh cadence — meaning a friend with the app open sees timers appear when they pull-to-refresh or scene-active fires — or do you want phase-4's true push from the start? My recommendation: ship phase 1 and see if the cadence feels off before paying the quota cost.

5. **Recipe-context filter.** On `FriendRecipeDetailView`, do you want to show **all** of the friend's running timers (any cook), or only the ones tied to *this specific recipe* (filter by `recipeID` — would require adding `recipeID` to `ActiveTimerInfo`)? Recipe-scoped feels right to me — seeing a timer for a different recipe on this detail page would be confusing — but it adds one more field to the schema.
