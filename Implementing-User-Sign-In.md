# Llamas Cookbook — User Sign-In & Cloud Recipe Delivery Plan

> **Goal:** let two users with the app exchange recipes over the
> internet without AirDrop, file transfers, or chat apps in between.
> Sender taps "Send to friend", picks a recipient, hits send.
> Recipient opens the app and the recipe is waiting in their inbox.
>
> **Companion to:** [CLAUDE.md](./CLAUDE.md),
> [Recipe-Sharing.md](./Recipe-Sharing.md),
> [Share-Extension-Plan.md](./Share-Extension-Plan.md),
> [PROJECT.md](./PROJECT.md), [ROADMAP.md](./ROADMAP.md).
>
> **Audience:** Claude Code session, picking up to implement.

---

## 0. The 60-second summary

Today's app-to-app sharing (PRs 1–4 of Recipe-Sharing) requires a
transport in between — AirDrop, Messages, Mail, Files. The recipient
has to receive the file or link in some other app first, then tap it
to land in our Import Preview. It works, but it's not what people
mean when they say "share with my friend."

This plan adds **cloud delivery on top of the existing share schema**:

1. **Identity** — Sign in with Apple (free, secure, Apple-handled).
   Gives every user a stable opaque ID, optional name + email at
   first sign-up. No passwords. Required if we ever offer any other
   third-party login per Apple's App Store rules.
2. **User directory** — CloudKit public DB record per user, keyed
   by Apple's stable `sub` claim, exposing only `displayName` and
   a 6-character random `friendCode` for lookup. Friend code is the
   shareable handle ("Add me: BISCUIT").
3. **Recipe transport** — sender uploads the existing
   `LCRecipeShareV1` envelope (reused byte-for-byte) to a CloudKit
   public DB `RecipeShare` record tagged with the recipient's user
   ID. Photos go in as `CKAsset` instead of base64 — saves bytes and
   gets us free CDN delivery.
4. **Inbox + push** — recipient's app holds a `CKQuerySubscription`
   that fires a silent push when a new `RecipeShare` lands for them.
   App fetches in background, recipe shows up in a new Inbox tab
   (or a badge on Library). Tapping a pending share opens the
   existing **Import Preview** sheet — Save / Cancel work identically
   to the file/link path.
5. **Profile page** — minimal first version: display name (editable),
   friend code (read-only, share button), Sign in / Sign out, Delete
   Account. Sized so option 3 (social layer — friends list, feed,
   notifications-on-share) can grow into it later without redesign.

**Cost:** $0 baseline. CloudKit free tier covers 10 GB private
storage per user, 100 MB public storage **per app**, 10 GB asset
transfer per user per day. Recipe shares are kilobytes; even with
photos a recipe is ~1–3 MB. We'd need ~30 active users sharing 100
recipes/day each before we touch the public-DB cap; CloudKit scales
the cap with active install count after that. APNs is free. Sign in
with Apple is free. Apple Developer Program membership we already
pay for.

**iOS-only forever?** This locks us in. CloudKit + Sign in with
Apple don't have an Android/web story. Acknowledged and accepted
per scope conversation 2026-04-27 — Llamas Cookbook is iOS-only by
design.

**Effort:** ~1.5 dev-days for Sign in with Apple + identity model
(PR 1), ~2 dev-days for CloudKit setup + send flow (PR 2), ~1.5
dev-days for inbox + push subscriptions (PR 3), ~1 dev-day for
Profile page + Delete Account (PR 4). Plus 1 dev-day of Apple
Developer Portal + App Store Connect plumbing (capabilities,
provisioning, privacy labels). 4–6 CI cycles end to end.

---

## 1. What "send to friend" means in practice

After this lands, the user can:

1. Open Recipe Detail.
2. Tap the share toolbar button → action menu now offers a
   **fourth** option: **Send to friend in app** (alongside the
   existing file / link / text exports).
3. Pick recipient — either from a **Recents** list (people the user
   has sent to or received from before) or by typing a friend code.
4. Tap Send. App shows a "Sent to Anna" toast and dismisses.
5. Anna's phone, in the background, receives a silent push. The app
   downloads the recipe envelope. Anna opens the app — a small
   badge sits on the Library tab; an **Inbox** sheet shows
   "1 recipe waiting from Lorenzo". Tap → existing Import Preview →
   Save → recipe lands with the same provenance line we already
   render ("Originally shared by Lorenzo · Apr 27").
6. Anna's app marks the `RecipeShare` consumed; CloudKit deletes
   the record on a 14-day TTL whether consumed or not.

The existing file/link/share-extension paths **stay**. Cloud
delivery is additive — the sender picks the transport at share time
based on whether the recipient has the app + an account
(cloud-eligible) vs. doesn't (file/link still works).

---

## 2. Why Sign in with Apple + CloudKit (the architecture choice)

Three options were on the table; here's why this combo wins for
this app specifically.

| Option | Identity | Backend | Cost | Effort | Notes |
|---|---|---|---|---|---|
| **Sign in with Apple + CloudKit** *(chosen)* | Apple `sub` claim | CloudKit public DB | $0 | Medium | Apple-native, free CDN for photos, free push |
| Email/password + Firebase | Custom + Firebase Auth | Firebase Firestore + Storage | $0 → $25+/mo | High | Cross-platform, but adds Google dep, more security surface |
| Email/password + custom backend | Custom | Self-hosted | $5+/mo + ops | Highest | Full control, full responsibility |

**Sign in with Apple wins** because:

- **Free, no backend for auth.** Apple's authorization service mints
  a stable per-app user ID. We never see a password, never store
  one, never have to handle reset / verification / breach.
- **Required-by-rule if we ever add another login.** App Store
  Review Guideline 4.8: any app offering a third-party login (Google,
  Facebook, Twitter, etc.) must also offer Sign in with Apple. By
  going Apple-only from day one we sidestep the rule entirely; if we
  later add Google, we'll already have Apple in place.
- **Bridges to option 3 cleanly.** The same `sub` claim that
  identifies a recipient for cloud delivery is the same primary key
  for a friends-list entry, a follower record, an activity feed item.

**CloudKit wins for the data layer** because:

- **Silent on top of Apple ID.** No second auth UI; if the user is
  signed into iCloud (most users are) and Sign in with Apple, they're
  signed into CloudKit too.
- **Free tier is enormous for our scale.** Recipe shares are
  KB-scale; 100 MB shared public storage and per-user 10 GB asset
  transfer means we'd need a real audience before cost matters.
- **`CKQuerySubscription` does push for free.** No APNs server to
  run. Recipient's device subscribes to "RecipeShare records where
  recipientID = me", CloudKit fires a silent push when one lands.
- **`CKAsset` means free photo CDN.** We stop base64-bloating the
  envelope; photos upload as binary assets, download lazily on the
  recipient side.
- **Encrypted in transit and at rest** by default. Apple manages
  the keys.

**Honest limitation acknowledged:** CloudKit public DB records are
addressable by anyone who knows the record ID. We mitigate by (a)
random opaque record IDs, (b) recipient-ID filtering at query time,
(c) auto-delete 14 days after creation. This is **not end-to-end
encrypted**. A motivated attacker who learned someone's userRecordID
could in theory query their pending shares. For a cookbook this
threat model is acceptable; if the app ever holds anything truly
sensitive, switch to per-recipient `CKShare` with the standard
zone-share security model.

---

## 3. Identity model

A single source of truth for "who am I" lives in a new
`UserAccount` Observable, sibling to `OwnerProfile` and
`AppearanceSettings`:

```swift
@Observable
final class UserAccount {
    enum Status {
        case signedOut
        case signingIn
        case signedIn(UserIdentity)
        case signInFailed(Error)
    }

    struct UserIdentity: Codable {
        let appleSub: String           // Sign in with Apple stable ID
        let cloudKitUserRecordID: String
        let displayName: String        // editable; defaults to Apple-supplied
        let friendCode: String         // 6 chars [A-Z2-9], no I/O/0/1
        let createdAt: Date
    }

    private(set) var status: Status
}
```

- `appleSub` is the Sign in with Apple `userIdentifier` — stable
  for life of the Apple ID, unique per app team, not an email.
  Stored locally in Keychain (not UserDefaults — survives app
  reinstall, doesn't sync to other devices).
- `cloudKitUserRecordID` comes from
  `CKContainer.fetchUserRecordID()` after the user is signed into
  iCloud. Used as the "to" address for inbound shares.
- `friendCode` is generated server-side (well, client-side at
  account creation, validated against CloudKit public DB for
  uniqueness via a transactional check).
- `displayName` is user-editable in Profile; first value is whatever
  Sign in with Apple returns at sign-up (`fullName.givenName` if the
  user agreed to share it, else "Cook"), or `OwnerProfile.displayName`
  if it was already set from the existing share flow.

**Migration from `OwnerProfile`:** the existing `OwnerProfile`
Observable (introduced in Recipe-Sharing PR 2) already holds a
display name + a "have we asked yet" flag. On first sign-in, copy
`OwnerProfile.displayName` into `UserAccount` and stop using
`OwnerProfile` for new code. Leave `OwnerProfile` declared so old
share flows that haven't been routed through the cloud path still
work for users who haven't signed in.

---

## 4. Data model — local

One new SwiftData `@Model`:

```swift
@Model final class PendingShareRecord {
    var id: UUID                       // local, distinct from cloud
    var cloudRecordName: String        // CloudKit record ID, for dedup
    var senderDisplayName: String
    var senderFriendCode: String
    var senderAppleSub: String         // verified at fetch time
    var recipeTitle: String            // shown in inbox before download
    var receivedAt: Date
    var downloadedAt: Date?            // nil = metadata only, not yet fetched
    var envelopeJSON: Data?            // populated when full payload downloaded
    var photoAssetCount: Int           // for "downloading 3 photos…" UI
}
```

This sits alongside `Recipe` etc. in `Sources/Models/`. Inbox UI
queries by `downloadedAt == nil` for the "new" badge count;
materialization on Save calls the existing `RecipeShare.materialize`
on `envelopeJSON` and then deletes the `PendingShareRecord`.

No new fields on `Recipe` — the existing `sharedBy` / `sharedAt` /
`sourceShareID` provenance fields (Recipe-Sharing PR 1) cover this
path identically. We're swapping the transport, not the payload.

---

## 5. Data model — CloudKit

Three record types in the **public** database, one container
(`iCloud.com.llamascookbook.app`):

### `User`
| Field | Type | Notes |
|---|---|---|
| `appleSub` | String, queryable | Primary lookup; matches local `UserAccount.appleSub` |
| `displayName` | String | Public — anyone with the friend code can see it |
| `friendCode` | String, queryable, unique | 6 chars [A-Z2-9] |
| `createdAt` | Date/Time | |

`recordName` = `appleSub`. Owner = the user themselves (set via
`CKRecord(recordType:, recordID:zoneID:.default)` in their own
context). Security role: world-readable (anyone with friend code
can resolve to display name); only owner can write.

### `RecipeShare`
| Field | Type | Notes |
|---|---|---|
| `recipientAppleSub` | String, queryable | The "to" address |
| `senderAppleSub` | String | Verified server-side via `creatorUserRecordID` |
| `senderDisplayName` | String | Cached at send time |
| `recipeTitle` | String | For inbox preview without downloading payload |
| `envelope` | Bytes (or `CKAsset` if > 1 MB) | The `LCRecipeShareV1` JSON, photos stripped |
| `photo0`…`photoN` | `CKAsset` | One per gallery + step photo, indexed by envelope |
| `createdAt` | Date/Time | TTL anchor |

`recordName` = random UUID. Security role: world-readable but
recipient-filtered at query time (acknowledged: not E2E
encrypted; threat model accepted in §2). Auto-deleted after 14
days by a CloudKit lifecycle rule (or by a daily janitor query the
sender's app runs against its own outbox if Apple doesn't expose
TTL on public records — verify during PR 2 spike).

### `BlockedUser` *(deferred to PR 5+)*
For when a user blocks another. Keeps `RecipeShare` queries
filtering out blocked senders client-side. Schema-only for now.

---

## 6. Sending flow

1. User on Recipe Detail taps Share button → menu shows existing
   options + new **Send to friend in app** (gated on
   `UserAccount.status == .signedIn`; otherwise the row says "Sign
   in to send to friends" and routes to Profile).
2. **Recipient picker sheet** opens:
   - Top: `Recents` list (last 10 distinct recipients/senders from
     local `PendingShareRecord` history + outbox log).
   - Below: friend-code text field. Type 6 chars → as soon as the
     final character lands, fire a CloudKit query against `User
     WHERE friendCode == X` → show resolved display name + "Send to
     Anna" button, or "No user found" inline error.
   - Cancel returns to Detail.
3. On Send tap:
   - Encode the recipe via `LCRecipeShareV1.encode` (existing).
   - Pull photos out of the envelope into a `[Data]` array; the
     envelope keeps photo placeholders (e.g. `{"assetIndex": 0}`).
   - Construct `RecipeShare` record. Attach `envelope` as bytes
     (or asset if big), each photo as `photo{N}` `CKAsset`.
   - `CKModifyRecordsOperation` → public DB → save.
   - Sender's app appends an outbox entry locally for the Recents
     list and the future "delivered" indicator.
   - Toast: "Sent to Anna".

If iCloud is unavailable (no signal, account problem), surface a
non-blocking error and offer the existing file/link path as a
fallback inside the same sheet.

---

## 7. Receiving flow

1. **Subscription registration** (one-time, on first sign-in):
   `CKQuerySubscription` against `RecipeShare WHERE
   recipientAppleSub == self.appleSub`, predicate firing on
   record creation. Notification info has `shouldSendContentAvailable
   = true` (silent push, not visible alert by default).
2. **Push arrives** (silent or on app foreground): `AppDelegate`'s
   `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
   handles it. Fetch the new `RecipeShare` by its record name from
   the push payload, write a `PendingShareRecord` into SwiftData
   with `downloadedAt = nil` initially, kick off envelope + asset
   download in a background `Task`, then update `downloadedAt` and
   `envelopeJSON` when complete.
3. **App foreground** (push didn't arrive — silent push is best-
   effort; system may suppress under low-power / background restrict):
   on app launch / foreground, fire a one-shot
   `CKQueryOperation` against `RecipeShare WHERE
   recipientAppleSub == me AND createdAt > lastFetchedAt` to catch
   any missed deliveries. Update `lastFetchedAt` in UserDefaults.
4. **Inbox UI** is a new screen reachable from a tray icon in
   `LibraryView`'s toolbar (badge with count when
   `PendingShareRecord` count > 0). Listing: each row = sender +
   recipe title + received-at relative time + tappable. Tap routes
   to the existing `RecipeImportPreviewView` with the envelope
   pre-loaded. Save / Cancel work identically to the file path;
   Save additionally deletes the `PendingShareRecord` and tells
   CloudKit to delete the `RecipeShare` record (server-side cleanup
   + mark consumed).
5. **Edge case — user not signed in but a share is sent to them:**
   not possible, because the sender resolved their friend code,
   which means they have an account. Friend code creation requires
   sign-in.

---

## 8. Profile page

A new `ProfileView` at `Sources/Views/Profile/`, reachable from a
person-circle button added to `LibraryView`'s toolbar (left side,
balancing the FAB on the right).

**Signed-out state:**
- App icon + tagline
- "Sign in with Apple" button (the official `SignInWithAppleButton`
  SwiftUI view)
- One-line explainer: "Optional — only needed to send recipes
  directly to friends in the app."

**Signed-in state:**
- Display name (editable via a small inline pencil → text field,
  saved on commit)
- Friend code (large, monospaced, with a copy button + share button
  that opens `UIActivityViewController` with text "Add me on Llamas
  Cookbook: BISCUIT")
- *(option 3 placeholder)* Friends list section, currently a "Coming
  soon" row
- "Sign out" button (destructive secondary; clears local
  `UserAccount` but does NOT delete CloudKit `User` record — they
  can sign back in)
- "Delete account" button (destructive primary, with confirm
  alert). On confirm: deletes the `User` record from CloudKit,
  deletes all outstanding `RecipeShare` records authored by this
  user, clears local `UserAccount` and Keychain entry. **Required
  by App Store Review Guideline 5.1.1(v) since 2022** for any app
  with account creation; we ship this from PR 1, not later.

Layout matches the Theme tokens already in use (`AppColor.surface`,
`AppFont.sectionHeading`, `AppSpacing.lg`); no new UI primitives
needed.

---

## 9. PR breakdown

### PR 1 — Sign in with Apple + identity model

- Add Sign in with Apple capability to the main app target in
  `project.yml`.
- New `App/UserAccount.swift` Observable per §3.
- New `Lib/SignInWithAppleService.swift` wrapping
  `ASAuthorizationAppleIDProvider` + `ASAuthorizationController`.
- Keychain persistence helper for the Apple `sub` (new
  `Lib/KeychainStore.swift`).
- `ProfileView` skeleton (signed-out / signed-in toggle, no
  friend code yet).
- Account-deletion flow (clears Keychain + local state). CloudKit
  cleanup deferred to PR 2 since CloudKit isn't wired yet.
- **Does NOT yet hit CloudKit.** All cloud calls stubbed; this PR
  only adds the auth UI and local identity. Lets us ship the
  Profile screen + Apple sign-in alone if CloudKit setup runs long.

### PR 2 — CloudKit container + User + Send flow

- Enable iCloud capability in `project.yml`, container
  `iCloud.com.llamascookbook.app`.
- CloudKit Dashboard setup (manual, Apple Developer Portal):
  create container, define `User` and `RecipeShare` record types
  with the schemas in §5, set indexes (`appleSub`, `friendCode`,
  `recipientAppleSub` all queryable).
- New `Lib/CloudKitService.swift` wrapping
  `CKContainer.default()` access.
- On first sign-in completion, write the `User` record (friend
  code generated locally, uniqueness checked with a query +
  retry-on-collision loop, max 5 retries before surfacing an error
  — collision space is 32^6 = ~1 billion so this is paranoia).
- Recipient picker sheet + friend-code resolution.
- Send flow per §6 (envelope + photos as `CKAsset`).
- Outbox log in UserDefaults for Recents.
- Account-deletion flow upgraded to also remove `User` record +
  authored `RecipeShare` records.

### PR 3 — Inbox + push subscription

- Add Push Notifications capability in `project.yml` (already
  enabled for the timer notification path; verify entitlement
  covers silent pushes).
- New `Models/PendingShareRecord.swift` per §4.
- `CKQuerySubscription` registration in `UserAccount` post-sign-in.
- `AppDelegate` extension for
  `didReceiveRemoteNotification` handling.
- Foreground catch-up query on app launch + foreground.
- New `Views/Inbox/InboxView.swift` listing
  `PendingShareRecord`s.
- Toolbar tray icon + badge in `LibraryView`.
- Routing: inbox row tap → existing `RecipeImportPreviewView` with
  envelope pre-loaded.
- Server-side cleanup of consumed `RecipeShare` after Save.

### PR 4 — Profile polish + Delete Account final + privacy

- Friends list placeholder section (option 3 prep).
- Display name edit UX.
- Friend code share-via-`UIActivityViewController` button.
- Delete Account confirm dialog wording + final cascade test.
- Privacy policy URL hosted (GitHub Pages or a static page on a
  personal domain — must exist before App Store submission).
- App Store Connect privacy nutrition labels updated to declare:
  "Identifiers" (Apple sub), "Contact info" (display name),
  "User content" (recipes shared via cloud).

### PR 5+ — Option 3 social layer *(deferred — designed in)*

Friends list (mutual add), activity feed (friend's recently shared
recipes — opt-in), block/report, possibly recipe reactions. Not in
scope for this plan, but PR 1–4 leave the right hooks.

---

## 10. Apple Developer Portal + App Store Connect checklist

Mirroring [Share-Extension-Plan.md §8](./Share-Extension-Plan.md)
in shape — these are the manual portal steps that must be done by
the human (you, Lorenzo) before CI can sign and TestFlight will
accept the build.

### Capabilities to enable on the main app's App ID (`com.llamascookbook.app`)

1. **Sign in with Apple** — toggle on, save. Provisioning profile
   must be regenerated after this; the entitlement is baked in at
   issue time.
2. **iCloud** — toggle on, choose "Include CloudKit support",
   create new container `iCloud.com.llamascookbook.app`. Save.
   Regenerate profile.
3. **Push Notifications** — already enabled per existing timer
   path; verify still on. Silent pushes use the same entitlement.

### CloudKit Dashboard setup (one-time, before PR 2 lands)

- Visit [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard/).
- Select container `iCloud.com.llamascookbook.app`.
- **Schema → Record Types**: create `User` with the fields in §5,
  mark `appleSub` and `friendCode` queryable. Create `RecipeShare`
  with fields in §5, mark `recipientAppleSub` and `createdAt`
  queryable.
- **Schema → Security Roles**: confirm the default
  `_world` / `_creator` roles match §5's sharing model. May need a
  custom role for the recipient-only filter; spike during PR 2.
- **Deploy schema from Development to Production** before any
  TestFlight build that uses cloud features. Forgetting this is
  the #1 way "it works in dev, fails in TestFlight" happens with
  CloudKit.

### App Store Connect

- **Privacy nutrition labels** — update before submitting. New
  declarations: Identifiers (Apple sub), Contact Info (display
  name), User Content (shared recipes). All "Linked to user", none
  "Used for tracking".
- **Privacy policy URL** — required field in App Store Connect for
  any app that collects data. Must be a real URL; GitHub Pages
  (e.g. `septemberfinesse.github.io/llamas-cookbook-privacy`)
  or a personal domain works.
- **Sign in with Apple review** — Apple specifically tests this
  flow. Make sure first-launch sign-in works on a clean install
  before submitting; also test the "Hide My Email" path
  (Apple-relayed email — we don't store email so it doesn't matter
  much for us, but it must not crash).
- **Account deletion** — App Store Review now greps for an
  in-app delete path on submission. Document where it is in your
  review notes ("Profile → Delete Account").

### GitHub Secrets / CI

- No new secrets needed for sign-in itself (Apple manages the
  keys).
- If we later add server-to-server notifications from Sign in with
  Apple (to detect when a user revokes their Apple ID consent),
  we'd add a `.p8` key here. Deferred.
- Provisioning profiles regenerated above will need the
  `IOS_PROVISIONING_PROFILE_BASE64` secret refreshed in
  GitHub → Settings → Secrets. Same dance as the share-extension
  rollout.

---

## 11. Risks & open questions

1. **CloudKit public DB is not E2E encrypted.** Threat model
   accepted in §2 (cookbook content, not sensitive). If we ever
   regret this, the migration path is per-recipient `CKShare` with
   private-DB zone shares, which adds complexity to send/receive
   but keeps the schema mostly intact.
2. **Silent pushes are unreliable.** iOS may suppress them under
   low-power, background-refresh-disabled, or "send less
   frequently" throttling. The foreground catch-up query in §7 is
   the safety net; users may see "Anna sent this 3 hours ago"
   instead of an immediate notification, which is fine for a
   recipe app.
3. **Friend code collisions.** 32^6 = ~1 billion codes; with even
   100k users, collision probability per generation is ~0.01%. The
   retry loop in PR 2 handles it. If we ever push past a million
   users we may want to grow to 7 chars — but that's a great
   problem to have.
4. **Sign in with Apple at sign-up only returns name once.** If the
   user denies sharing it, or if they sign in on a second device
   after the first, the name field will be empty. We fall back to
   "Cook" + let them edit immediately in Profile.
5. **Hide My Email relays.** We never collect email, so this is
   inert for us — but if PR 5+ ever needs to email users
   (notification preferences?), we'll need to handle the relay
   address.
6. **CloudKit schema deploy is not reversible from the dashboard
   without contacting Apple.** Be deliberate during PR 2; deploy
   to Production only after the schema is exercised end-to-end
   in Development.
7. **Push notification permission prompt timing.** Don't ask at
   first launch — that's a guaranteed deny. Ask on first sign-in
   *after* showing what notifications enable ("Get notified when a
   friend sends you a recipe"). Standard rationale-then-prompt
   pattern.
8. **What happens to a shared recipe if the sender deletes their
   account?** The `RecipeShare` records they authored get cascaded
   in PR 2's delete flow. If a recipient already imported, the
   local `Recipe` keeps its `sharedBy` line — names persist, the
   credit doesn't disappear because the sender left.
9. **CloudKit container name is permanent.** Once created in the
   Apple Developer Portal it can't be renamed. `iCloud.com.
   llamascookbook.app` matches the bundle ID — match this exactly.

---

## 12. What this enables for option 3 (social layer)

Designed-in but not implemented. PR 5+ would add:

- **Friends collection** — a `Friend` record type linking two
  `User` IDs, with mutual-accept handshake. Friend code stays as
  the lookup primitive; once added, future shares can be one-tap.
- **Activity feed** — a `Post` record type per `User`, queried as
  "posts where author IN my friends, ordered by createdAt".
  Subscriptions push new posts. Reuses the same `LCRecipeShareV1`
  envelope.
- **Notifications-on-share** — silent push from PR 3 swaps to a
  visible push with sender + recipe title.
- **Profile view of a friend** — recipes they've shared, friend
  count, join date.
- **Block / report** — `BlockedUser` schema lands in PR 2 already,
  filtering applies in PR 5+.

The point: every PR 1–4 schema is shaped so option 3 grows by
addition, not redesign. The `User` record gains friend list as a
references field. The `RecipeShare` record stays exactly as is —
the friends-list send flow just looks up multiple recipient IDs
instead of one.

---

## 13. Out of scope (explicit)

- **Cross-platform (Android / web).** Not happening; iOS-only by
  design.
- **Recipe collaboration / co-editing.** Send is one-way; recipient
  gets a copy and can fork freely. Use `CKShare` if ever needed.
- **End-to-end encryption.** See §2 / §11.1.
- **In-app messaging / comments on a shared recipe.** Different
  product surface.
- **Following public chefs / discovery feed.** Different product
  surface; would need a moderation pipeline we're not staffed for.
- **Recipe ratings / reviews.** Not in scope.
- **Username (vs friend code) as the lookup primitive.** Friend
  code is opaque, collision-managed, and unlinkable to identity.
  Usernames invite squatting and impersonation; we'd need them
  only if option 3's social layer demands them.
