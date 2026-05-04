# Launch Readiness Audit — Llamas Cookbook iOS

Audit date: 2026-05-04
Target: first public TestFlight → App Store submission of `com.llamascookbook.app` v1.0.0
Scope: `ios-native/`, `cloudflare-pages/`, build/CI config, signing, App Store Connect submission inputs.

Each finding has a severity, a file reference, and what to do about it. Severities:
- **Blocker** — App Review will reject, or the app will misbehave at launch in a way that hurts users
- **High** — should be fixed before a public launch even if Apple won't reject
- **Medium** — fine to ship as v1.0.0 if you accept the tradeoff, but track it
- **Low** — polish or future work

---

## TL;DR

You can ship. The codebase is in remarkably good shape — defensive byte caps everywhere, persistent retry on the only cascade Apple actually tests, single-source-of-truth constants for App Group / container IDs / share size limits, and a privacy manifest that's already correct. The 3 things you actually need to do before submitting:

1. **Move ASC privacy labels from "to verify" to "filled in"** in App Store Connect (separate from the `PrivacyInfo.xcprivacy` manifest, which is already good).
2. **Produce the screenshot set** — minimum 6.9" iPhone, optionally 6.5" and 13" iPad if you're declaring iPad support (you currently aren't; `TARGETED_DEVICE_FAMILY: "1"` is iPhone only).
3. **Verify Universal Links open the app on a real device** with the AASA file deployed on `llamascookbook.pages.dev`. (Listed as open work in CLAUDE.md.)

Everything below is the long form.

---

## 1. Security

### 1.1 Cleartext credentials sitting on the dev box — High

Files present on disk under `credentials/`:
- `credentials/github-secrets.txt` (21 KB — likely full secret dump)
- `credentials/ios/dist-cert.p12` (3 KB — distribution cert private key)
- `credentials/ios/profile.mobileprovision` (12 KB)
- `credentials.json` — contains the .p12 password **in plaintext**: `"password": "RRmPCn+HD5wp28kza6Oztg=="`

`.gitignore` covers `credentials/` and `credentials.json`, so none of this is committed. But all of it sits readable on the dev machine. App Review never sees this; the risk is your laptop being compromised. CLAUDE.md flagged "delete these pre-launch" — still pending.

**Action.** After confirming GitHub secrets are populated and CI builds work, delete `credentials/` and `credentials.json` from disk. Rotate the `.p12` password in your password manager (current password is now in shell history / Spotlight indexes).

### 1.2 Sign in with Apple — looks correct

`ios-native/Sources/Lib/SignInWithAppleService.swift` does this right:
- 32-byte CSPRNG nonce, SHA-256 hashed and attached to the request (lines ~125)
- Cancellation handled distinctly from other errors
- `getCredentialState` revocation check on cold launch via `UserAccount.refreshCredentialState`
- Only requests `.fullName` (no email scope, no noisier consent sheet)

`KeychainStore.swift` uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and is not synchronizable — survives reinstall, doesn't sync across devices. Wipe-all on Delete Account works.

No findings here. This is well done.

### 1.3 CloudKit public DB has no Security Role — Medium

CLAUDE.md is honest about this: "world-readable, world-writable (no Security Role yet — add one before expanding TestFlight)." For v1.0.0 launch with a small TestFlight, this is acceptable risk; an attacker would need to know about your container ID and have an iCloud account to write garbage records. The damage they can do is bounded (records are world-readable but not malicious-payload bearing — `RecipeShare.decode` stat-checks size, sniffs schema version, and rejects oversized photo assets).

Real impact today: a motivated user could pollute the public DB with junk records that show up nowhere in the UI (because all reads are by-record-name or by-`me` predicate). It's a quota concern, not a user-data-exfiltration concern.

**Action (post-launch is fine).** Add a CloudKit Security Role that requires authenticated iCloud user for write on `RecipeShare` / `Friendship` / `PublishedRecipe` / `RecipeImport`, and limit `UserProfile` writes to the matching `creatorUserRecordID`. Schedule before any marketing push that drives volume.

### 1.4 Image proxy and AASA on Cloudflare — looks correct

`cloudflare-pages/functions/img/[id].js`:
- 10 MB content-length precheck (line 18 / 63)
- Magic-byte sniff on JPEG/PNG/WebP/HEIC, rejects anything else
- Falls back to `/llama-icon.png` on any failure
- Adds `x-content-type-options: nosniff` and `referrer-policy: no-referrer`
- Edge-caches with `stale-while-revalidate`

`cloudflare-pages/_headers` correctly serves `apple-app-site-association` as `application/json` (Apple is strict; `text/plain` makes Universal Links silently fail). AASA itself declares `GYFN949Q5E.com.llamascookbook.app` against `/r/*`, matching the Associated Domains entitlement.

`lib/cloudkit.js` uses ECDSA P-256 server-to-server keys with the private key as a Cloudflare encrypted secret. Keys live in Cloudflare env, not in the repo.

No findings.

### 1.5 URL importer hardening — looks correct

`ios-native/Sources/Lib/RecipeURLImporter.swift`:
- 15-second request timeout
- 10 MB max response size, with **streaming abort** (won't OOM on adversarial response)
- Content-length precheck before reading bytes
- Rejects non-2xx-3xx HTTP status

### 1.6 Share extension input cap — single source of truth

`ios-native/Sources/Shared/RecipeShareLimits.swift` defines `maxInboundBytes = 25_000_000`. The share extension (line 35 of `ShareViewController.swift`) and the main app's `RecipeShare.decode` both reference this constant — no duplicated literals. Stat-checks before reading. Belt-and-suspenders second check on in-memory `Data` path.

### 1.7 Account deletion cascade — partially compliant

App Review tests Delete Account on flaky networks. Today:

| Record type | Persistent retry on failure? |
|---|---|
| `RecipeShare` | **Yes** — outbox + pending-delete queue, retries on every launch via `CloudKitService.retryPendingDeletes` |
| `Friendship` | No — best-effort, single shot |
| `PublishedRecipe` | No — best-effort, single shot |
| `RecipeImport` | No — best-effort, single shot |
| `UserProfile` | No — best-effort, single shot |
| `CKQuerySubscriptions` | No — best-effort, single shot |

CLAUDE.md flags this. The local UI flips to signed-out instantly regardless, so **the user-visible behavior is correct** (they appear deleted). But if a reviewer toggles airplane mode mid-cascade, the cloud-side records can strand. Apple's Delete Account guideline (5.1.1(v)) is about whether deletion is *offered and works* end-to-end, and partial cleanup with no retry is a defensible interpretation but risky if a reviewer is thorough.

**Action.** Promote each cascade to the `RecipeShare` pattern: enqueue record IDs to a UserDefaults pending-delete queue at deleteAccount time, drain on every launch. The mechanics already exist in `CloudKitService.deleteAuthoredShares` / `retryPendingDeletes`; replicate them per-record-type. ~1–2 hours of work; well worth it.

---

## 2. Auth & account lifecycle

### 2.1 Sign-in flow

`UserAccount.swift` orchestrates correctly:
- `beginSignIn` / `completeSignIn` / `failSignIn` / `cancelInFlightSignIn` state machine
- Cancel surfaces silently (no error UI), other errors surface as `.signInFailed(message)`
- Belt-and-suspenders `cancelInFlightSignIn` for the iOS 18 `SignInWithAppleButton` regression where `onCompletion` doesn't fire on swipe-down
- Display name resolution cascade: Apple-supplied → OwnerProfile carryover → "Cook"
- Display names always run through `RecipeShare.cappedDisplayName` so a sender can't smuggle a long name into a share envelope

### 2.2 Sign-out and Delete Account

`signOut()`:
- Captures `cascadeUserID` *before* clearing the mirror cache (so the unsubscribe call has the user record name)
- Wipes Keychain, UserDefaults
- Resets bulk-publish marker (so a re-sign-in on a different Apple ID gets a fresh bulk publish)
- Fires `CloudKitSubscriptions.unregisterAll` detached

`deleteAccount()`:
- Local wipe is synchronous (UI flips instantly)
- Cloud cascade fires detached, with the cascadeUserID captured before the mirror clear
- Cleans `RecipeShare` (persistent), then friendships, published recipes, recipe imports, subscriptions (best-effort)

See 1.7 above for the persistent-retry gap.

### 2.3 Account state edge cases

- `cancelInFlightSignIn` recovers from stranded `.signingIn` state when ProfileView reappears. Good defensive code.
- `refreshCredentialState` runs on cold launch and drops the user back to signed-out if they revoked SIWA from Settings. Good.
- `UserProfileMirror.cachedRecordID()` is the canonical "is iCloud bound?" check; every social write short-circuits when nil. Confirmed used throughout `FriendsStore`, `LibraryMirrorService`, `CloudKitSubscriptions.registerIfNeeded`. Invariant holds.

---

## 3. CloudKit & data layer

### 3.1 SwiftData configuration — correct

`LlamasCookbookApp.makeModelContainer` explicitly sets `cloudKitDatabase: .none`. Schema declares `Recipe` / `Ingredient` / `RecipeStep` / `RecipePhoto` / `RecipeStepPhoto` with `.cascade` delete rules — these would silently degrade to in-memory storage if SwiftData were CloudKit-backed. Invariant holds.

Last-resort in-memory fallback present (line 98) so the app still launches if container open fails — user sees empty library rather than crash. Reasonable.

### 3.2 `Recipe.apply(_:)` preserves attribution chain — confirmed

`DraftRecipe.swift:235-313`. The `apply` method writes title/summary/source/servings/times/tags/favorite/notes/ingredients/steps/photos but never touches `sharedBy`/`sharedAt`/`sourceShareID`/`originalCreatorUserRecordName`/`originalCreatorDisplayName`/`originalSharerUserRecordName`/`originalSharerDisplayName`/`originalRecipeID`/`importedAt`. Editing an imported recipe preserves the chain.

### 3.3 Friendship dedup — client-side only

`FriendsStore.refresh` collapses duplicates with a precedence rule (accepted > pending), then dispatches a background sweep that deletes the losers. `sendRequest` does a remote `fetchFriendships` backstop before issuing a new request to handle the "schema deploying / network blip" race that historically created duplicates. CLAUDE.md flags server-side uniqueness as open work — the client-side dedup is solid for v1.0.0 but means two users mutual-requesting at the exact same instant on different devices can briefly land two pending records (caught by the next refresh).

**Acceptable for launch.** Track for v1.1 — CloudKit doesn't support unique constraints on the public DB, so this would be a periodic sweep job or a tighter atomic-write pattern.

### 3.4 Predicate splits — invariant respected

`fetchFriendships` splits the symmetric "userA OR userB" lookup into two single-field queries (lines 152–162 of `CloudKitFriendship.swift`). `registerFriendshipSubscription` does the same split for the CKQuerySubscription. CloudKit's public-DB OR-across-fields requirement is honored. Good.

### 3.5 `queryAllRecords` follows cursors — confirmed

`CloudKitService.queryAllRecords` (line 105) loops `continuingMatchFrom:` until cursor is nil. Every social path (`fetchFriendships`, importer audit log, account-deletion cascade) goes through this helper. Invariant holds.

### 3.6 `UserProfile` recordName prefix — confirmed

`CloudKitUserProfile.swift` applies/strips `profile_` prefix to avoid colliding with CloudKit's system `Users` record type. Callers pass raw iCloud user record names. Invariant holds.

### 3.7 `LibraryMirrorService` debounce — correct

5-second per-`Recipe.id` debounce (line 64). `@MainActor`-isolated singleton. `resetBulkPublishMarker()` called from both `signOut` and `deleteAccount`. ImportCountCache lives in UserDefaults (not on the `@Model`) so chip refreshes don't cause spurious republishes. Invariant holds.

---

## 4. Cook mode & timers

### 4.1 AlarmKit integration — well done

`TimerNotifications.schedule` keys alarms by deterministic `cookID` UUID. Re-extending the same cook overwrites the existing alarm rather than stacking; `cancel(cookID:)` is targeted, doesn't disturb other concurrent cooks. `cancelAll()` enumerates every alarm AlarmKit knows about (the only alarms this app schedules are cook timers, so safe).

`AlarmAttributes<TimerAlarmMetadata>` carries recipe title / step number / end date through to the widget extension. The widget renders the countdown using `endDate` from the metadata rather than any `AlarmPresentationState` field that might shift across AlarmKit beta SDK versions. Defensively forward-compatible.

CLAUDE.md called out "per-cook `TimerLiveActivityRegistry` not implemented" — but you confirmed this is now superseded by AlarmKit's built-in per-UUID Live Activity management. Verified: no `TimerLiveActivityRegistry` exists in the codebase, and the per-cook isolation comes for free from AlarmKit's UUID keying.

### 4.2 NSAlarmKitUsageDescription — present

`AppInfo.plist:86` carries: "Llamas Cookbook uses alarms so cooking timers reach you even when the app isn't open or the phone is silenced." Required for `AlarmManager.shared.requestAuthorization()`. Honest copy.

### 4.3 Concurrent cooks

`maxConcurrentCooks = 4` in `CookingSession.swift:194`. Each cook has its own AlarmKit alarm keyed by cookID. Scheduling, canceling, and ending all wire through correctly.

### 4.4 Sound asset

`timer-alarm.caf` is generated at CI time via ffmpeg+afconvert (per `project.yml` comment). Optional source path, so local dev builds without it fall back to `.default`. `TimerNotifications.alarmSound` checks `Bundle.main.url(forResource:withExtension:)` and falls back gracefully. Good.

---

## 5. Bugs, races, error handling

### 5.1 Forced unwraps — only safe ones

```
ios-native/Sources/App/LlamasCookbookApp.swift:108  try! ModelContainer(...)  // in-memory fallback after primary failed
ios-native/Sources/Views/Library/LibraryView.swift:699  try! ModelContainer(...)  // SwiftUI #Preview block
ios-native/Sources/Lib/CloudKitService.swift:464  recordIDAlphabet.randomElement()!  // static non-empty array
ios-native/Sources/Lib/CloudKitRecipeImport.swift:277  recordIDAlphabet.randomElement()!  // same
```

All four are safe. The `try!` on the in-memory fallback is intentional — schema is fully defaulted, in-memory always succeeds.

### 5.2 Race protection — `FriendsStore.refresh()` invariant

Line 135: `isRefreshing = true` is set **synchronously before** any `await`. CLAUDE.md invariant; confirmed in code. Prevents the `.task + .onChange of sign-in status` re-entrancy race.

### 5.3 Universal Links delivered on either of two paths — handled

`RootView.onOpenURL` and `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` both route to `routeUniversalLink`, which calls `fetchCloudShareRecord` → sets `pendingShareImport`. Duplicate deliveries no-op since both produce the same envelope. Per CLAUDE.md and verified in `RootView.swift:264–286`.

### 5.4 Logging in production

Three `print(...)` calls survive into production:
- `LlamasCookbookApp.swift:160` — APNs registration failed
- `RecipeDetailView.swift:1228` — CloudKit account status not available
- `RecipeDetailView.swift:1272` — uploadShare threw

Low impact (these are diagnostic, no PII), but worth cleaning up or routing through a logger that strips in Release. **Low.**

### 5.5 No `fatalError` / `as!` / unsafe `!` outside the four documented sites

I grepped. Codebase is well-disciplined.

### 5.6 Light-mode lock — intentional but worth noting

`LlamasCookbookApp.swift:65` locks `.preferredColorScheme(.light)`. The cream + terracotta palette has no dark-mode variant. Apple won't reject for this, but:
- All App Store screenshots must be light mode (no dark-mode variant available)
- Users with system dark mode get a noticeably different visual experience inside Llamas vs. the rest of their phone
- The Cloudflare `index.html` landing page *does* have a dark-mode variant via `prefers-color-scheme` — slight inconsistency, but landing-page-only

**Acceptable.** Document as a v1 design decision; consider dark mode for v1.x once you've heard from real users.

---

## 6. Aesthetics & UX

### 6.1 Liquid Glass — NOT yet adopted

`AppInfo.plist:64` sets `UIDesignRequiresCompatibility = true` — explicit opt-out from iOS 26 Liquid Glass design. Codebase confirms: zero usages of `.glass`, `glassBackground`, `GlassEffect`, etc. across all of `ios-native/Sources/`.

CLAUDE.md flags this: "adopt before iOS 27 forces it off." Apple has not announced exact iOS 27 timing, but the compatibility key is documented as transitional.

**For v1.0.0 launch: acceptable.** The compatibility opt-out is supported on iOS 26. The current cream/terracotta aesthetic reads cohesively.

**Pre-iOS 27.** Plan a Liquid Glass adoption pass — likely lands around late 2026 / early 2027. Touchpoints: tab bar (you already have a comment in `RootView.configureTabBarAppearance` noting "Inheriting the rest of `UITabBarAppearance()`'s defaults preserves iOS 26 Liquid Glass background styling" — so flipping the compatibility flag may largely "just work" for the tab bar), navigation chrome, sheet presentations, and any custom card surfaces in Library / Friends / Detail.

### 6.2 Accessibility — partial coverage

Grep shows `accessibilityLabel` / `accessibilityHint` usage on:
- LlamaIntro overlay (Previous/Next/step counter)
- PhotoCarouselView (Rearrange / Remove)
- SavedToast
- CookModeView (Exit / Minimize / photo additions / running timer)
- AttributionSheet (close hint)
- ImportersListSheet (opens cookbook)
- RecipeDetailView (accent picker, favorite, share, edit, importer view, attribution)

**Missing or unclear coverage:**
- LibraryView card grid — no explicit accessibility audit visible
- FriendsTabView card grid
- Editor row controls (ingredient quick-add, step quick-add, tag input)
- Color picker

**Action (Medium).** Run a VoiceOver pass before submission. Apple's review will silently penalize apps that fail rotor navigation; not a guaranteed reject but a real quality signal. Particularly important: ingredient list rows during Cook Mode (strike-through state should be announced), timer countdowns (you already have a label for the running case at `CookModeView.swift:738` — good — but check the ready overlay).

### 6.3 Dynamic Type — not assessed in code

I didn't see explicit `dynamicTypeSize` clamps or overrides, which usually means SwiftUI's defaults apply (good). One thing to verify on a real device: the cooking step text + ingredient list at `accessibility5` size (largest accessibility setting). The Cook Mode "large type, warm cream" guidance in CLAUDE.md suggests this is intentional, but worth running through Accessibility Inspector once before submitting.

### 6.4 iPad — not declared

`project.yml` sets `TARGETED_DEVICE_FAMILY: "1"` (iPhone only). The repo has `adapt-for-ipad.md` (19 KB, suggesting iPad work has been planned), but it's not enabled. This is fine — better to ship iPhone-only and add iPad cleanly than to ship a poor iPad experience. Just make sure your App Store listing says "Designed for iPhone."

### 6.5 Friend surfaces and presence dots

CLAUDE.md UX guardrails confirm these are implemented:
- Friend surfaces tint in friend's accent color
- Presence dot: filled+pulsing when `cookingStartedAt < 6h`, hollow when idle
- "Cooking: <title>" eyebrow during a cook

I didn't deep-read the rendering code but the supporting state (`UserProfileSnapshot.cookingStartedAt`, `lastCookedTitle`, `lastCookedAt`) is all present in `CloudKitUserProfile.swift`. Recommend a final pass with two test accounts on real devices — presence is hard to QA in the simulator.

### 6.6 Onboarding tour

`Sources/Views/Components/LlamaIntro/` has six consolidated tour steps (Name+Description, Servings+PrepTime, Photos, Tag It, Ingredients, Steps+Notes). Tour is interactive — dim/halo are non-hit-testing so the user types into real fields. No Skip button (intentional — you've made the call that anyone can finish in <60s). Tour finish lands you in a normal editor with Save in the toolbar.

**Verify on a real device** — the no-skip choice is bold and worth pressure-testing with one or two actual non-technical users before launch. If anyone gets frustrated, consider adding a small "I've used a recipe app before" link that skips it.

---

## 7. App Store submission requirements — what you need to provide

Even with a perfect codebase, App Store Connect needs assets and metadata that don't live in the repo. Here's the punch list.

### 7.1 Screenshots — Blocker until provided

Required (for an iPhone-only app):
- **6.9" iPhone** (iPhone 16 Pro Max): 1320 × 2868 px, portrait. Up to 10 images, minimum 3.
- **6.5" iPhone** (iPhone 11 Pro Max / XS Max): 1242 × 2688 px or 1284 × 2778 px. Up to 10, minimum 3.

Apple no longer requires the smaller sizes if you provide 6.9". You can upload one set and it scales.

**Suggested 6 screenshots that would tell your story well**:
1. **Library** — cooked recipes shown as warm cards with photos, illustrating the "your cookbook" thesis
2. **Recipe Detail** — accent-tinted title, ingredients, photo carousel
3. **Cook Mode** — the warm cream "currently cooking" view with timer
4. **Friends Tab** — cards of friends' libraries (use anonymized test accounts)
5. **Import a recipe** — paste-from-link with a parsed preview ready to save
6. **Sharing a recipe** — Messages bubble showing the rich-link preview

Take these on a real iPhone 16 Pro Max in iOS 26 light mode. Don't use simulator screenshots — review screens for status-bar artifacts.

### 7.2 App icon — already in place

`Resources/Assets.xcassets/AppIcon.appiconset` has all sizes including the 1024×1024 marketing icon (`Icon-iOS-1024@1x.png`). Good. Spot-check:
- No transparency or rounded corners on the 1024 (iOS adds the mask)
- No alpha channel on any icon image

### 7.3 App Store Connect Privacy Labels (Nutrition Labels) — High

**These are different from the `PrivacyInfo.xcprivacy` privacy manifest.** You have the manifest (good — declares UserDefaults usage with reason CA92.1, file timestamp with C617.1, no tracking, no collected data). The labels are filled in App Store Connect itself.

Based on what your app actually does, your labels should be:

**Data Used to Track You:** None
**Data Linked to You:** None (everything stays on-device or in user's own iCloud)
**Data Not Linked to You:** None

This is unusual — most apps end up with at least crash diagnostics. Confirm:
- You're not using any analytics SDK (Firebase, Sentry, Mixpanel, etc.) — grep confirms you aren't
- You're not using TestFlight feedback collection in a way that ties to user identity (TestFlight itself is separate from your privacy labels)
- CloudKit data is "in the user's own iCloud" — Apple treats this as user-on-device, not collected

**Action.** In App Store Connect → App Privacy → Data Collection, select "Data Not Collected." Be ready to defend this in App Review if challenged (you have a clean answer — everything is local SwiftData, on-device Keychain, or CloudKit public DB owned by Apple). Have your `PrivacyInfo.xcprivacy` ready to point at if asked.

### 7.4 Age rating

Likely **4+**. Recipes are general audience. No user-generated text content displayed publicly in a way that could surface mature material (friend-only sharing has the same trust boundary as iMessage).

In ASC: walk through the questionnaire honestly — answer No to all "frequent/intense" categories, No to user-generated content (since friend libraries are a closed graph, not a public feed), No to gambling, alcohol, etc.

### 7.5 App description, subtitle, keywords

**Subtitle (30 chars max):** Something like "Your kitchen, your way" or "Recipes worth keeping" — pick after reading 10 cookbook-app subtitles in the App Store for tone calibration.

**Description (4000 chars max):** Open with the user pain you solve (recipes scattered across screenshots, browser tabs, Notes). Then your three pillars — Library, Cook Mode, Sharing. Then the friends feature as the differentiator. Then a feature list. Mention iCloud sync and AlarmKit-backed lock-screen timers since both signal quality.

**Keywords (100 chars max):** `recipe,cookbook,cooking,timer,kitchen,meal,food,shopping list,grocery,baking,sourdough,share`

(Don't repeat words from your title or subtitle — Apple already indexes those.)

### 7.6 Support URL & Privacy Policy URL — Required

Both required for submission.
- **Support URL** — `https://llamascookbook.pages.dev/support` would be natural. You'll need to add a `support.html` to the Cloudflare Pages site with at least an email address.
- **Privacy Policy URL** — `https://llamascookbook.pages.dev/privacy`. Required even with "data not collected" labels. Should match your privacy labels: state plainly that the app stores data on-device and in the user's own iCloud, names no third parties, and contains a section on Sign in with Apple identity handling.

Both pages probably take you 30 minutes to write. Use the existing `index.html` aesthetic.

### 7.7 What's New / version notes

For v1.0.0 (first version): something like "Welcome to Llamas Cookbook!" — Apple is fine with brief intro copy on the inaugural version.

### 7.8 App Review demo account / contact info

- **Demo account** — not required since Sign in with Apple works without a server-side account creation step. App Reviewer can SIWA with their own Apple ID. **Verify this on a real device first** — if anything in the social/friends flow requires a partner account to be set up, you may need to provide a second test account so the reviewer can exercise the friend-request flow end-to-end.
- **Contact info** — first / last name + phone + email of someone reachable during App Review (typically Lorenzo). Include a note explaining the AlarmKit / NSAlarmKitUsageDescription so the reviewer doesn't trip on it.

### 7.9 Capabilities sanity-check in Apple Developer Portal

The `LlamasCookbook.entitlements` file declares:
- App Group `group.com.llamascookbook.app`
- Sign in with Apple (Default)
- iCloud (`iCloud.com.llamascookbook.app`) + CloudKit
- Associated Domains (`applinks:llamascookbook.pages.dev`)
- `aps-environment = development` (auto-substituted to `production` at distribution-profile time)

All five capabilities must be enabled on the App ID in Apple Developer Portal. The provisioning profile must have been regenerated *after* each capability was added, since the entitlement is baked into the profile at issue time. CLAUDE.md flags this multiple times for good reason — this is the #1 source of "ITMS-90xxx entitlement not in profile" rejections.

**Action.** Before your first archive: in Apple Developer Portal → Identifiers → `com.llamascookbook.app`, confirm all five are enabled. Then regenerate the App Store distribution provisioning profile, download it, base64-encode it, and update `IOS_PROVISIONING_PROFILE_BASE64` in GitHub Secrets. Same for the widget profile (`com.llamascookbook.app.widget`) and share extension profile (`com.llamascookbook.app.shareext`).

### 7.10 Universal Links — Verify on real device

CLAUDE.md flags this as open work. The setup is correct on paper:
- AASA at `https://llamascookbook.pages.dev/.well-known/apple-app-site-association` declares `GYFN949Q5E.com.llamascookbook.app` against `/r/*`
- Cloudflare `_headers` serves it as `application/json` (Apple is strict)
- Entitlement carries `applinks:llamascookbook.pages.dev`
- App routes both `.onOpenURL` (https) and `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` to the same handler

But iOS validates the AASA on first launch and caches the result. Once you have a TestFlight build:
1. Install from TestFlight on a real iPhone
2. Wait ~30 seconds for AASA validation
3. Generate a share permalink from one device, send to another via Messages, tap the bubble
4. Confirm the recipient device opens the app rather than Safari
5. If it opens Safari: in Settings → Developer → Universal Links, confirm `llamascookbook.pages.dev` is listed and "AASA Validation" passed

If validation fails, the most common causes are: wrong content-type on the AASA file (already correct in `_headers`), CDN caching a stale version (force-purge in Cloudflare dashboard), or the `appIDs` value not exactly matching `<TeamID>.<BundleID>`.

---

## 8. Other things worth noting

### 8.1 Camera permission

`NSCameraUsageDescription` in `AppInfo.plist:76`: "Llamas Cookbook uses the camera to scan recipe pages. The photos stay on your device." Honest, specific, mentions user benefit. Good.

### 8.2 Background modes

`UIBackgroundModes = [remote-notification]` for silent CloudKit pushes. Apple checks that apps declaring this actually use it for content updates — you do (FriendsStore refresh + recipe-import-count refresh on push). Defensible.

### 8.3 Document type (`.llamarecipe`) and URL scheme

`UTExportedTypeDeclarations` and `CFBundleDocumentTypes` are paired correctly — AirDrop / Files / Mail will recognize `.llamarecipe` attachments and route them into the app. `LSSupportsOpeningDocumentsInPlace = false` is correct (you copy bytes into a new SwiftData record, don't keep editing the source file). This avoids the ITMS-90737 emit Apple sends when document types are declared without that key.

URL scheme `llamascookbook` is registered with editor role. Used by share extension handoff and Live Activity tap deep links. Good.

### 8.4 Marketing version vs build number

`MARKETING_VERSION = 1.0.0` is the user-visible "Version" in the App Store. `CURRENT_PROJECT_VERSION` defaults to `"1"` in `project.yml` but is overridden at archive time by CI to `date -u +%s` (Unix timestamp). This means each TestFlight build gets a strictly increasing build number — App Store Connect requires monotonically increasing builds within the same marketing version. Good pattern.

### 8.5 macOS / runner pinning

CI uses `macos-26` and explicitly selects Xcode 26 (preferring stable over beta), with thoughtful retry logic on the simulator runtime download. This is unusually careful CI hygiene; well done.

### 8.6 What about App Store Connect agreements?

Before you can submit, the Paid Apps Agreement (or Free Apps Agreement, since your app is presumably free) must be signed by the team's Account Holder. Bank info and tax forms also need to be in good standing even for free apps. This is account-level; check ASC → Agreements, Tax, and Banking before you start the submission flow.

---

## 9. Code-change to-do list

Per your direction, these are *changes* not made during this audit; do them when you're ready.

### Must-do before submitting

1. **Delete on-disk credentials.** Remove `credentials/`, `credentials.json` from the dev box. Rotate the `.p12` password.
2. **Verify Universal Links on real device** — see 7.10. Block submission until this works.
3. **Write Privacy Policy and Support pages** for `llamascookbook.pages.dev/privacy` and `/support`. Add URLs to App Store Connect.
4. **Confirm Apple Developer Portal capabilities** are all enabled on the App ID, and regenerate provisioning profiles. Update GitHub Secrets.
5. **Take 6.9" iPhone screenshots** (suggested set in 7.1).

### Should-do before submitting

6. **Promote Friendship / PublishedRecipe / RecipeImport / UserProfile / CKQuerySubscription cascades to persistent retry**, mirroring the `RecipeShare` outbox+pending-delete pattern in `CloudKitService.swift`. ~1–2 hours.
7. **VoiceOver audit pass** — particularly Library card grid, Friends card grid, Editor row controls, ingredient strike-throughs in Cook Mode.
8. **Real-device test of the friend-request flow** with two TestFlight accounts. Confirm presence dots, "Cooking: <title>" eyebrows, mutual-request edge case.
9. **Real-device test of the cook timer** firing on lock screen, in another app, and in Silent mode (the AlarmKit promise).

### Can do post-launch

10. **Add a CloudKit Security Role** restricting public DB writes to authenticated iCloud users + ownership-checked updates. Schedule before any growth push.
11. **Plan Liquid Glass adoption** for v1.x — flip `UIDesignRequiresCompatibility` off and audit each navigation/tab/sheet surface.
12. **Replace the three production `print(...)` calls** with a logger that strips in Release.
13. **Reconsider light-mode-only lock** once you have user data on dark-mode preferences.
14. **Server-side Friendship uniqueness** — periodic sweep job or tighter atomic-write pattern. v1.1.
15. **iPad adaptation** — `adapt-for-ipad.md` plan exists; v1.1 or v2 candidate.

---

## Sources

- Project instructions: [CLAUDE.md](computer://C:\Users\fines\Documents\2026 Repository\The-Llamas-Cookbook/CLAUDE.md)
- Build configuration: [ios-native/project.yml](computer://C:\Users\fines\Documents\2026 Repository\The-Llamas-Cookbook/ios-native/project.yml)
- Privacy manifest: [Resources/PrivacyInfo.xcprivacy](computer://C:\Users\fines\Documents\2026 Repository\The-Llamas-Cookbook/ios-native/Resources/PrivacyInfo.xcprivacy)
- Entitlements: [Resources/LlamasCookbook.entitlements](computer://C:\Users\fines\Documents\2026 Repository\The-Llamas-Cookbook/ios-native/Resources/LlamasCookbook.entitlements)
- App Info plist: [Resources/AppInfo.plist](computer://C:\Users\fines\Documents\2026 Repository\The-Llamas-Cookbook/ios-native/Resources/AppInfo.plist)
- AASA file: [cloudflare-pages/.well-known/apple-app-site-association](computer://C:\Users\fines\Documents\2026 Repository\The-Llamas-Cookbook/cloudflare-pages/.well-known/apple-app-site-association)
