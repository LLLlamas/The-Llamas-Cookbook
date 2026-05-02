# CLAUDE.md

Source of truth for agents. Code wins when this disagrees.

Last refreshed: 2026-05-01.

## Status

Live SwiftUI app under `ios-native/`. Shipped: CRUD, editor, Cook Mode, multi-cook pills, photos, text/link/photo import, share extension, Universal Link recipe sharing, Sign in with Apple, profile/accent, friends, friend cookbooks, friend recipe import, import attribution/counters, CloudKit subscription plumbing.

Open work:

- Verify Universal Links on real devices, then drop the diagnostic alert in `RecipeDetailView.cloudShareError`.
- Per-cook `TimerLiveActivityRegistry`.
- Aesthetic/type pass; adopt Liquid Glass before iOS 27 drops the compatibility opt-out.
- Add CloudKit Console Security Role gating `UserProfile` queries to `_icloud` (authenticated iCloud users) before TestFlight expands.
- Pre-launch: delete `credentials/github-secrets.txt`, `credentials/ios/dist-cert.p12`, `credentials/ios/profile.mobileprovision` from dev box.

## Product rules

- Local cookbook is offline-first SwiftData. CloudKit sync stays disabled.
- Sharing/social records are public/unlisted. Messages/links must work for non-friend recipients. Copy must NOT promise "only friends can see this."
- Friend UI controls in-app discovery. CloudKit + Cloudflare deliver shares and previews.

## Stack

- Swift 5.10, SwiftUI, SwiftData, iOS 18+ deploy, iOS 26 SDK build.
- XcodeGen project: `ios-native/project.yml`. Do not hand-edit generated Xcode files.
- CI only from Windows. Do not run `xcodegen`, `xcodebuild`, CocoaPods, or local previews here.
- Targets: `com.llamascookbook.app`, `.widget`, `.shareext`.
- App Group: `group.com.llamascookbook.app`.
- CloudKit container: `iCloud.com.llamascookbook.app`.
- Universal Link host: `llamascookbook.pages.dev`.

## Critical files

- App shell: `ios-native/Sources/App/RootView.swift`, `LlamasCookbookApp.swift`.
- Models: `ios-native/Sources/Models/Recipe.swift`, `DraftRecipe.swift`.
- Theme: `ios-native/Sources/Theme/`.
- Library/import: `Views/Library/`, `Lib/RecipeImporter.swift`, `RecipeURLImporter.swift`, `RecipeOCRImporter.swift`, `RecipeAIParser.swift`.
- Detail/share: `Views/Detail/RecipeDetailView.swift`, `Lib/RecipeShare.swift`, `Lib/CloudKitService.swift`.
- Friends/social: `App/FriendsStore.swift`, `App/UserAccount.swift`, `Lib/CloudKitFriendship.swift`, `CloudKitUserProfile.swift`, `CloudKitPublishedRecipe.swift`, `CloudKitRecipeImport.swift`, `CloudKitSubscriptions.swift`, `Views/Friends/`, `Views/Profile/`.
- Cook/timers: `Views/Cook/CookModeView.swift`, `App/CookingSession.swift`, `Lib/TimerNotifications.swift`, `TimerLiveActivityController.swift`.
- Share extension: `ios-native/ShareExtension/`, `Sources/Shared/SharedContainer.swift`, `Base64URL.swift`.
- Web preview: `cloudflare-pages/functions/r/[id].js`, `img/[id].js`, `lib/cloudkit.js`, `.well-known/apple-app-site-association`.

## Architecture invariants

- SwiftData: `ModelConfiguration(... cloudKitDatabase: .none)`. Do not switch to `.automatic`.
- Editor writes a `DraftRecipe`; `Recipe.apply(_:)` rebuilds relationships on Save. Photo bytes must travel through `DraftPhoto` / `DraftStep`.
- `RecipeStep.image` is deprecated migration baggage. New step photos use `RecipeStepPhoto`.
- Coordinators live above navigation in `RootView`; re-inject `@Observable` environments into sheets/covers.
- New CloudKit share/import IDs are 12 chars from `[A-Z2-9]` minus `I/O/0/1`. Cloudflare still routes legacy 6-char IDs.
- CloudKit query helpers must follow cursors (`queryAllRecords`). Never reintroduce first-page-only social queries.
- CloudKit photo asset reads enforce per-photo (`maxCloudPhotoBytes = 10 MB`) and total (`maxCloudTotalPhotoBytes = 40 MB`) caps.
- `ImportCountCache` lives in UserDefaults, not on `Recipe`, so chip refreshes do not trigger `LibraryMirrorService` re-publishes.
- `LibraryView` profile button is `.disabled(editor.active != nil)` so it is not a silent no-op while the editor sheet is up.

## CloudKit posture

- `UserProfile` records are world-queryable on the public DB. Add a CloudKit Console Security Role to gate query access to registered users; revisit before adding sensitive fields. `cookingStartedAt` / `lastCookedTitle` count as real-time presence today.
- `Friendship`, `PublishedRecipe`, `RecipeImport`, `RecipeShare` are also public/unlisted by design.
- `deleteAccount()` cascades: authored shares, `UserProfile` mirror, all friendships, all published recipes, all import audit rows, push subscriptions. Best-effort; no outbox yet for stranded records.

## UX guardrails

- Quick-add rows, Return-to-add, visible fallbacks for gestures.
- Cook Mode: larger type, warm background, check-off flow, ready overlay.
- Quantity formatting: strings, mixed fractions, `&` output, measurable chip set only.
- Detail ingredient display uses accent quantity + em dash.
- Per-step timers use the clock glyph and `needsTimer`.
- Carousels: no inline reorder arrows. Use a dedicated reorder mode.
- Imports prompt on exact duplicate recipe titles and prefill the next editable `Title (N)` name, including friend cookbook imports.
- Friend/social copy: "shared", "appears in Friends", "unlisted". Never "private to friends" or "only friends can see."

## Signing & portal

- Team `GYFN949Q5E`. ASC app id `6762527184`.
- Required GitHub Secrets: `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`.
- `Resources/PrivacyInfo.xcprivacy` covers required-reason APIs. App Store privacy labels still need a once-over against CloudKit/Cloudflare sharing.
- `UIDesignRequiresCompatibility = true` is the temporary Liquid Glass opt-out.
- App Group `group.com.llamascookbook.app` must match main app + share extension entitlements + portal profiles.
- CloudKit schema (`RecipeShare`, `UserProfile`, `Friendship`, `PublishedRecipe`, `RecipeImport`) deployed Dev → Prod. `photo0`-`photo19` asset fields are added manually.
- Push Notifications capability + main provisioning profile shipped.
- Cloudflare Pages env: `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (encrypted), `CLOUDKIT_ENVIRONMENT`.

## Docs

Other root markdown files are compact historical summaries. Update this file when behavior, privacy contract, CI, signing, or CloudKit schema changes.
