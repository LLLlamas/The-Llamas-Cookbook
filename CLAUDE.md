# CLAUDE.md

Current source of truth for agents. Code wins when this doc disagrees.

Last refreshed: 2026-04-30.

## Status

Native SwiftUI app is live under `ios-native/`. Shipped: CRUD, editor, Cook Mode, multi-cook pills, photos, text/link/photo import, share extension, Universal Link recipe sharing, Sign in with Apple, profile/accent, friends, friend cookbooks, friend recipe import, import attribution/counters, CloudKit subscription plumbing.

Current priorities:

- Verify Universal Links on real devices, then remove the temporary diagnostic alert in `RecipeDetailView.cloudShareError`.
- Finish Push Notifications portal/profile work so CloudKit subscription pushes actually deliver.
- Deploy `RecipeImport` schema/indexes Dev to Prod.
- Add per-cook `TimerLiveActivityRegistry`.
- Do aesthetic/type pass and adopt Liquid Glass before iOS 27.

## Product Rules

- The app is a personal, offline-first cookbook. Local recipes stay in SwiftData with CloudKit sync disabled.
- Sharing/social records are public/unlisted by product decision, not strict friend-private storage. Messages/links must work for non-friend recipients. Do not write copy that promises "only friends can see this."
- Friend UI controls in-app discovery. CloudKit/Cloudflare provide share delivery and previews.

## Stack

- Swift 5.10, SwiftUI, SwiftData, iOS 18+ deployment, iOS 26 SDK build.
- XcodeGen project: `ios-native/project.yml`; do not hand-edit generated Xcode files.
- CI only from Windows. Do not run `xcodegen`, `xcodebuild`, CocoaPods, or local previews here.
- Main targets: `com.llamascookbook.app`, `.widget`, `.shareext`.
- CloudKit container: `iCloud.com.llamascookbook.app`.
- Universal Link host: `llamascookbook.pages.dev`.

## Critical Files

- App shell: `ios-native/Sources/App/RootView.swift`, `LlamasCookbookApp.swift`.
- Models: `ios-native/Sources/Models/Recipe.swift`, `DraftRecipe.swift`.
- Theme: `ios-native/Sources/Theme/`.
- Library/import: `Views/Library/`, `Lib/RecipeImporter.swift`, `RecipeURLImporter.swift`, `RecipeOCRImporter.swift`, `RecipeAIParser.swift`.
- Detail/share: `Views/Detail/RecipeDetailView.swift`, `Lib/RecipeShare.swift`, `Lib/CloudKitService.swift`.
- Friends/social: `App/FriendsStore.swift`, `Lib/CloudKitFriendship.swift`, `CloudKitUserProfile.swift`, `CloudKitPublishedRecipe.swift`, `CloudKitRecipeImport.swift`, `CloudKitSubscriptions.swift`, `Views/Friends/`, `Views/Profile/`.
- Cook/timers: `Views/Cook/CookModeView.swift`, `App/CookingSession.swift`, `Lib/TimerNotifications.swift`, `TimerLiveActivityController.swift`.
- Share extension: `ios-native/ShareExtension/`, `Sources/Shared/SharedContainer.swift`, `Base64URL.swift`.
- Web preview: `cloudflare-pages/functions/r/[id].js`, `img/[id].js`, `lib/cloudkit.js`, `.well-known/apple-app-site-association`.

## Architecture Notes

- SwiftData cloud sync is intentionally off: `ModelConfiguration(... cloudKitDatabase: .none)`. Do not change to `.automatic`.
- Editor writes a draft, then `Recipe.apply(_:)` rebuilds relationships on Save. Photo bytes must travel through `DraftPhoto` / `DraftStep`.
- Coordinators live above navigation in `RootView`; re-inject `@Observable` environments into sheets/covers.
- `RecipeStep.image` is deprecated migration baggage. New step photos use `RecipeStepPhoto`.
- New CloudKit share/import IDs are 12 chars from `A-Z2-9` minus `I/O/0/1`; Cloudflare still accepts legacy 6-char share links.
- CloudKit query helpers must follow cursors. Do not reintroduce first-page-only social queries.
- Cloud asset reads have per-photo and total caps. Keep memory bounded for public records.

## UX Guardrails

- Keep recipe input fast: quick-add rows, Return-to-add, visible fallbacks for gestures.
- Cook Mode should feel distinct: larger type, warm background, check-off flow, ready overlay.
- Do not regress quantity formatting: strings, mixed fractions, `&` output, measurable chip set only.
- Detail ingredient display uses accent quantity + em dash.
- Per-step timers use the clock glyph and `needsTimer`.
- Friend/social copy should say "shared", "appears in Friends", or "unlisted"; avoid hard privacy promises.

## Signing And Portal

- Team: `GYFN949Q5E`; ASC app id: `6762527184`.
- Required GitHub secrets: distribution cert/profile, widget/share extension profiles, App Store Connect key id/issuer/key.
- `Resources/PrivacyInfo.xcprivacy` exists for required-reason APIs. App Store privacy labels still need to match actual CloudKit/Cloudflare sharing.
- `UIDesignRequiresCompatibility = true` is temporary Liquid Glass opt-out.
- App Group `group.com.llamascookbook.app` must match main app, share extension, portal profiles.
- CloudKit schema needs `RecipeShare`, `UserProfile`, `Friendship`, `PublishedRecipe`, `RecipeImport`; `photo0`-`photo19` asset fields are manual.
- Push Notifications capability and regenerated main provisioning profile are still required for subscription delivery.

## Docs

Most root markdown files are now compact historical summaries. Use `CLAUDE.md` plus code for current work. Update this file when behavior, privacy contract, CI, signing, or CloudKit schema changes.
