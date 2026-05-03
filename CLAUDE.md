# CLAUDE.md

Source of truth for agents. Code wins when this disagrees.

Last refreshed: 2026-05-03.

## Status

Live SwiftUI app under `ios-native/`. Versioned `0.1.0` for first public TestFlight. Shipped: CRUD, editor, Cook Mode, multi-cook pills, photos, text/link/photo import, share extension, Universal Link recipe sharing, Sign in with Apple, profile/accent, friend search/requests/cookbooks, friend recipe import with chain attribution, "Imported by N" chip + importers list sheet, CloudKit subscription pushes for friendship + import events, share permalink delete-outbox with retry queue, Re-publish library + Re-sync profile diagnostic actions in Profile.

Open work:

- Verify Universal Links on real devices, then drop the diagnostic alert in `RecipeDetailView.cloudShareError`.
- Per-cook `TimerLiveActivityRegistry`.
- Aesthetic/type pass; adopt Liquid Glass before iOS 27 drops the compatibility opt-out.
- Add CloudKit Console Security Role gating `UserProfile` queries to `_icloud` (authenticated iCloud users) before TestFlight expands.
- Server-side uniqueness for `Friendship(userA,userB)` (today the dedupe is client-side: `FriendsStore.refresh` collapses + sweeps via `deleteAllFriendshipsBetween`).
- Account-deletion cascade still needs offline / interrupted re-test; share-deletes have an outbox + retry, but `Friendship` / `PublishedRecipe` / `RecipeImport` / `UserProfile` / push-subscription cascades are still single-shot best-effort.
- Pre-launch: delete `credentials/github-secrets.txt`, `credentials/ios/dist-cert.p12`, `credentials/ios/profile.mobileprovision` from dev box.

## Product rules

- Local cookbook is offline-first SwiftData. CloudKit sync stays disabled.
- Sharing/social records are public/unlisted. Messages/links must work for non-friend recipients. Copy must NOT promise "only friends can see this."
- Friend UI controls in-app discovery. CloudKit + Cloudflare deliver shares and previews.

## Stack

- Swift 5.10, SwiftUI, SwiftData, iOS 18+ deploy, iOS 26 SDK build.
- App version: `MARKETING_VERSION = 0.1.0` in `ios-native/project.yml`; CI overrides `CURRENT_PROJECT_VERSION` per archive.
- XcodeGen project: `ios-native/project.yml`. Do not hand-edit generated Xcode files.
- CI only from Windows. Do not run `xcodegen`, `xcodebuild`, CocoaPods, or local previews here.
- Targets: `com.llamascookbook.app`, `.widget`, `.shareext`.
- App Group: `group.com.llamascookbook.app`.
- CloudKit container: `iCloud.com.llamascookbook.app`.
- Universal Link host: `llamascookbook.pages.dev`.

## Critical files

- App shell: `ios-native/Sources/App/RootView.swift`, `LlamasCookbookApp.swift` (also owns `AppDelegate` for APNs + remote-push dispatch).
- Models: `ios-native/Sources/Models/Recipe.swift` (carries `originalCreator*` / `originalSharer*` / `originalRecipeID` / `importedAt` chain-attribution fields), `DraftRecipe.swift`.
- Theme: `ios-native/Sources/Theme/`.
- Library/import: `Views/Library/`, `Lib/RecipeImporter.swift`, `RecipeURLImporter.swift`, `RecipeOCRImporter.swift`, `RecipeAIParser.swift`.
- Detail/share: `Views/Detail/RecipeDetailView.swift`, `Views/Detail/ImportersListSheet.swift`, `Views/Detail/AttributionSheet.swift`, `Lib/RecipeShare.swift`, `Lib/CloudKitService.swift`, `Lib/ImportCountCache.swift`.
- Friends/social: `App/FriendsStore.swift`, `App/UserAccount.swift`, `Lib/CloudKitFriendship.swift`, `CloudKitUserProfile.swift`, `CloudKitPublishedRecipe.swift`, `CloudKitRecipeImport.swift`, `CloudKitSubscriptions.swift`, `Lib/UserProfileMirror.swift`, `Lib/LibraryMirrorService.swift`, `Views/Friends/FriendLibraryView.swift`, `Views/Friends/FriendRecipeDetailView.swift`, `Views/Profile/ProfileView.swift`, `Views/Profile/AddFriendSheet.swift`.
- Cook/timers: `Views/Cook/CookModeView.swift`, `App/CookingSession.swift`, `Lib/TimerNotifications.swift`, `Lib/TimerLiveActivityController.swift`, `Sources/Shared/TimerAttributes.swift`.
- Share extension: `ios-native/ShareExtension/`, `Sources/Shared/SharedContainer.swift`, `Base64URL.swift`.
- Web preview: `cloudflare-pages/functions/r/[id].js`, `functions/img/[id].js`, `lib/cloudkit.js`, `.well-known/apple-app-site-association`. (`lib/` lives at `cloudflare-pages/lib/`, not under `functions/` — Pages bundler follows the relative import.)

## Architecture invariants

- SwiftData: `ModelConfiguration(... cloudKitDatabase: .none)`. Do not switch to `.automatic`.
- Editor writes a `DraftRecipe`; `Recipe.apply(_:)` rebuilds relationships on Save. Photo bytes must travel through `DraftPhoto` / `DraftStep`.
- `Recipe.apply(_:)` MUST NOT touch the share-attribution fields (`sharedBy`/`sharedAt`/`sourceShareID`) or chain-attribution fields (`originalCreator*`/`originalSharer*`/`originalRecipeID`/`importedAt`). Edits preserve the chain.
- `RecipeStep.image` is deprecated migration baggage. New step photos use `RecipeStepPhoto`.
- Coordinators live above navigation in `RootView`; re-inject `@Observable` environments into sheets/covers.
- New CloudKit share/import IDs are 12 chars from `[A-Z2-9]` minus `I/O/0/1`. Cloudflare still routes legacy 6-char IDs.
- `PublishedRecipe.recordName == Recipe.id.uuidString` so upsert can fetch by recordName without a query.
- `UserProfile` records use a `profile_` prefix on the recordName so they don't collide with CloudKit's system `Users` record type (saving custom fields to a record matching the iCloud user record name fails with "Cannot create or modify field 'accentHex' in record Users"). The prefix is applied/stripped inside `CloudKitUserProfile.swift`; callers pass raw iCloud user record names.
- CloudKit query helpers must follow cursors (`queryAllRecords`). Never reintroduce first-page-only social queries.
- Predicates split per field instead of using OR — CloudKit public-DB OR requires every field carry a queryable index, and a missing index throws `invalidArguments` and skips the cascade. See `deleteAllRecipeImports` (importer + creator legs) and `CloudKitSubscriptions.registerFriendshipSubscription` (userA + userB legs).
- CloudKit photo asset reads enforce per-photo (`maxCloudPhotoBytes = 10 MB`) and total (`maxCloudTotalPhotoBytes = 40 MB`) caps.
- `ImportCountCache` lives in UserDefaults, not on `Recipe`, so chip refreshes do not trigger `LibraryMirrorService` re-publishes.
- `LibraryView` profile button is `.disabled(editor.active != nil)` so it is not a silent no-op while the editor sheet is up.
- `FriendsStore` is `@MainActor`-isolated. `refresh()` sets the `isRefreshing` flag synchronously before any await to defeat re-entrancy across `.task` + `.onChange` racers.
- `LibraryMirrorService` is a `@MainActor` singleton with a per-`Recipe.id` 5s debounce; sign-out / delete-account paths reset the bulk-publish marker so a re-sign-in re-bulks.
- `UserProfileMirror.cachedRecordID()` is the canonical "is this device bound to iCloud?" check. Every social write short-circuits when nil.

## CloudKit posture

- `UserProfile` records are world-queryable on the public DB. Add a CloudKit Console Security Role to gate query access to registered users; revisit before adding sensitive fields. `cookingStartedAt` / `lastCookedTitle` count as real-time presence today.
- `Friendship`, `PublishedRecipe`, `RecipeImport`, `RecipeShare` are also public/unlisted by design.
- `Friendship` symmetry: `userA` < `userB` lexicographically; one record per pair regardless of who initiated. Status `pending` / `accepted`. Deny is destructive.
- `RecipeShare` permalinks: 12-char record IDs, photos as `photo0`-`photo19` `CKAsset` siblings, envelope JSON as a `CKAsset`. Sender outbox + persistent pending-delete queue (`cloudShareOutbox.v1`, `cloudSharePendingDelete.v1`); `retryPendingDeletes()` runs on cold launch.
- Share envelope (`LCRecipeShareV1.ShareEnvelope`) carries optional chain-root `originalCreatorID` + `originalRecipeID`. Sender derives from `Recipe.originalCreator*` (re-share) or `cachedRecordID()` + local id (own-authored). Recipient's import preview writes a `RecipeImport` audit row from these; nil envelope fields (legacy) and self-imports skip the write.
- `PublishedRecipe`: per-recipe friend-readable mirror keyed by `Recipe.id.uuidString`. Carries `originalCreatorID` / `originalRecipeID` for chain attribution. Photo asset slots same as `RecipeShare`.
- `RecipeImport`: append-only audit log. Powers the "Imported by N" chip on the chain root's Detail view (`countRecipeImports(forOriginalRecipeID:)`) and the importers list sheet. Chain root's account-deletion cascade hard-deletes downstream rows (we picked simplicity over counter-integrity).
- CloudKit subscriptions (slice 6): `friendship-events-A-<me>`, `friendship-events-B-<me>` (both halves of the symmetric pair), `recipe-import-events-<me>`. Silent pushes (`shouldSendContentAvailable = true`, no alert / badge). Registered idempotently from `RootView.task` and `UserAccount.completeSignIn`; gated by a UserDefaults flag keyed to the iCloud user record name. Unregistered on sign-out / delete-account.
- Push fan-out: `AppDelegate` -> `CloudKitSubscriptions.dispatchRemoteNotification` -> `NotificationCenter.didFireNotification` with `userInfo["kind"]`. `FriendsStore` and `RecipeDetailView` observe and refresh their own state.
- `deleteAccount()` cascades: pending-delete queue for authored shares (with retry), `UserProfile` mirror, all `Friendship` records, all `PublishedRecipe` records, all `RecipeImport` rows (importer + creator legs), push subscriptions. Best-effort beyond shares; reviewers should still see records gone within one retry.

## UX guardrails

- Quick-add rows, Return-to-add, visible fallbacks for gestures.
- Cook Mode: larger type, warm background, check-off flow, ready overlay.
- Quantity formatting: strings, mixed fractions, `&` output, measurable chip set only.
- Detail ingredient display uses accent quantity + em dash.
- Per-step timers use the clock glyph and `needsTimer`.
- Carousels: no inline reorder arrows. Use a dedicated reorder mode.
- Imports prompt on exact duplicate recipe titles and prefill the next editable `Title (N)` name, including friend cookbook imports.
- Friend/social copy: "shared", "appears in Friends", "unlisted". Never "private to friends" or "only friends can see."
- Friend cookbook surfaces (`FriendLibraryView`, `FriendRecipeDetailView`) tint in the friend's accent. Presence dot: filled+pulsing when `cookingStartedAt` is within 6h, hollow outline when idle. `lastCookedTitle` doubles as live "Cooking: <title>" eyebrow during a cook.

## Signing & portal

- Team `GYFN949Q5E`. ASC app id `6762527184`.
- Required GitHub Secrets: `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.
- `Resources/PrivacyInfo.xcprivacy` covers required-reason APIs. App Store privacy labels still need a once-over against CloudKit/Cloudflare sharing.
- `UIDesignRequiresCompatibility = true` is the temporary Liquid Glass opt-out.
- App Group `group.com.llamascookbook.app` must match main app + share extension entitlements + portal profiles.
- Entitlements on the main app: App Group, Sign in with Apple, iCloud (CloudKit) container `iCloud.com.llamascookbook.app`, Associated Domains `applinks:llamascookbook.pages.dev`, `aps-environment` (Push Notifications). All require the provisioning profile to be regenerated after enabling — the entitlement is baked in at issue time.
- CloudKit schema (`RecipeShare`, `UserProfile`, `Friendship`, `PublishedRecipe`, `RecipeImport`) deployed Dev → Prod. `photo0`-`photo19` asset fields are added manually (auto-discovery doesn't catch optional `CKAsset` slots without sample records carrying them).
- AASA at `cloudflare-pages/.well-known/apple-app-site-association` declares `GYFN949Q5E.com.llamascookbook.app` against `/r/*`. The image proxy enforces `MAX_PROXY_IMAGE_BYTES = 10_000_000`, content-length precheck, and magic-byte content-type sniffing (JPEG/PNG/WebP/HEIC) before serving.
- Cloudflare Pages env: `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (encrypted), `CLOUDKIT_ENVIRONMENT`.

## Docs

Other root markdown files (including `implement-social.md`, `Implementing-User-Sign-In.md`, `Recipe-Sharing.md`) are compact historical summaries. Update this file when behavior, privacy contract, CI, signing, or CloudKit schema changes.
