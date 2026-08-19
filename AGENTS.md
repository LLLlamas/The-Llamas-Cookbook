# AGENTS.md

Source of truth for agents. Code wins when this disagrees.
Last refreshed: 2026-08-18 (grocery lists re-verified against the tree: full suite green — 216 Swift + 115 JS — file inventory and all four known gaps confirmed unchanged since 2026-08-09; no doc drift found)

Previous refresh: 2026-08-09 (shared grocery lists verified end-to-end: CloudKit schema confirmed deployed in Production, both grocery pushes fixed, check-off sync latency cut, shared-list toast + deep link added, `Sources/Views/Lists/` split into feature-sized files)

> **Planning docs / design handoffs / prior audits live in `md_files/`** —
> gitignored, kept on disk for reference. Only `AGENTS.md` (this file) and
> `README.md` are TRACKED at the repo root. A local `CLAUDE.md` may exist for
> Claude Code auto-load — it is gitignored (`.gitignore:41`) and must stay a
> thin pointer to this file, never a second copy of these facts.

---

## Stack

- Swift 5.10, SwiftUI, SwiftData, iOS 26+ / iOS 26 SDK
- `SWIFT_STRICT_CONCURRENCY: minimal`
- XcodeGen: `ios-native/project.yml` — do not hand-edit generated Xcode files
- Build: local Mac + Xcode 26 (primary; automatic signing — see `ios-native/README.md`). CI fallback: `macos-26` runner, Xcode 26, manual signing forced on the CLI
- Bundle IDs: `com.llamascookbook.app` (main), `.widget`, `.shareext`
- App Group: `group.com.llamascookbook.app` — must match in 4 places: `SharedContainer.appGroupID`, main app entitlements, share extension entitlements, portal profiles
- CloudKit container: `iCloud.com.llamascookbook.app` — public DB. Grants (verified against Production 2026-08-09): world **READ**, write scoped to `_icloud` (signed-in users). Do NOT grant WRITE to `_world` — see ### CloudKit Schema
- Universal Link host: `llamascookbook.pages.dev`
- Team: `GYFN949Q5E`. ASC app id: `6762527184`

---

## Directory Map

| Area | Path |
|---|---|
| App shell, tab bar, deep links, navigation | `ios-native/Sources/App/` |
| SwiftData models | `ios-native/Sources/Models/` |
| Theme (colors, fonts, spacing, outline) | `ios-native/Sources/Theme/` |
| Library, recipe cards, import flows | `ios-native/Sources/Views/Library/` |
| Recipe editor | `ios-native/Sources/Views/Editor/` |
| Recipe detail + sharing | `ios-native/Sources/Views/Detail/` |
| Cook mode + timers | `ios-native/Sources/Views/Cook/` |
| Friends / social views | `ios-native/Sources/Views/Friends/` |
| Profile + auth views | `ios-native/Sources/Views/Profile/` |
| Grocery Lists tab | `ios-native/Sources/Views/Lists/` |
| Reusable UI components | `ios-native/Sources/Views/Components/` |
| CloudKit ops + shared utilities | `ios-native/Sources/Lib/` |
| Widget + Live Activity | `ios-native/WidgetExtension/` |
| Share extension | `ios-native/ShareExtension/` |
| Web preview + Worker API | `cloudflare-pages/` |

---

## Feature → Files

**App shell** — `Sources/App/`
- `LlamasCookbookApp.swift` — `@main`, `ModelContainer`, `AppDelegate` (APNs, remote-push dispatch)
- `RootView.swift` — tab bar, deep-link routing, sheet/cover orchestration; owns `proTabIcon(named:)` for tab bar Pro icons
- `EditorCoordinator.swift`, `NavigationContext.swift`, `CookingSession.swift`, `CookingSessionState.swift`
- `FriendsStore.swift` — `@MainActor` cache; UserDefaults-backed stale-while-revalidate
- `UserAccount.swift` — SIWA identity, sign-out, delete cascade
- `AppearanceSettings.swift` — accent color; `applySignedOut()` / `restoreFromDefaults()` driven by `LlamasCookbookApp`

**Data models** — `Sources/Models/`
- `Recipe.swift` — `Recipe`, `Ingredient`, `RecipeStep`, `RecipePhoto`, `RecipeStepPhoto`; chain-attribution fields
- `DraftRecipe.swift` — editor draft; `Recipe.apply(_:)` defined here

**Theme** — `Sources/Theme/`
- `AppColor`, `AppFont`, `AppSpacing`, `ColorHex`, `AccentTextOutline`

**Library / import** — `Sources/Views/Library/`
- `LibraryView.swift`, `RecipeCardView.swift`, `EmptyLibraryView.swift`
- `ImportFromTextLinkView.swift` — merged paste + URL sheet; focus-mode dimming, duplicate-title check via `nextAvailableTitle(base:)`
- `ImportFromPhotoView.swift`, `RecipeImportPreviewView.swift`, `PhotoImportPreviewView.swift`
- `LetterIndex.swift`, `CookbookHeader.swift`
- Lib: `RecipeImporter.swift`, `RecipeURLImporter.swift`, `RecipeOCRImporter.swift`, `RecipeAIParser.swift`, `AnthropicRecipeParser.swift`, `StreamingRecipeParser.swift`, `RecipeSchemaParser.swift`, `RecipeExport.swift`
- Lib: `InstagramExtractor.swift`, `SpeechTranscriber.swift` — Instagram-reel device-side extraction (inline JSON / `og:*` / mp4 first-frame) + on-device `SFSpeechRecognizer` audio transcription
- Lib: `QuotaService.swift` — `@MainActor @Observable` singleton; polls `/api/usage`, fires `/api/usage/consume`
- Lib: `LlamaProStore.swift` — StoreKit 2 wrapper

**Editor** — `Sources/Views/Editor/`
- `RecipeEditorView.swift`
- `IngredientRowEditor.swift`, `IngredientQuickAdd.swift`, `StepRowEditor.swift`, `StepQuickAdd.swift`, `SpecialNotesEditor.swift`, `TagInputView.swift`, `PhotoToggleButton.swift`
- `Chips/QuantityChips.swift`, `UnitChips.swift`
- Lib: `TagPresets.swift`, `IngredientDisplay.swift`, `Plural.swift`

**Detail / share** — `Sources/Views/Detail/`
- `RecipeDetailView.swift`
- `ImportersListSheet.swift`, `AttributionSheet.swift`, `ConversionsView.swift`, `SourdoughCalculatorView.swift`
- Lib: `RecipeShare.swift` (wire format), `CloudKitService.swift` (upload/fetch/delete), `ImportCountCache.swift`

**Grocery Lists** — `Sources/Views/Lists/`, `Sources/Models/`, `Sources/Lib/`, `Sources/App/`

Free (no Pro gate). Two halves: a local list you build and shop, and an
app-to-app **shared** list a friend shops live while you watch.

- `ListsView.swift` — list-of-lists (Lists tab). Rows flip to green (`AppColor.success`) "All set" when fully shopped (`GroceryList.isAllSet`): green check icon + green border. New-list naming screened by `ContentModeration`. `.task` also requests visible-notification permission (iCloud-gated) — see ### Grocery Push.
- `GroceryListDetailView.swift` — one open list (aisle-grouped, store-walk order). Owns the view + its actions; the row, the celebration, and the surrounding chrome are separate files (split 2026-08-08, 837 → 516 lines):
  - `GroceryItemRow.swift` — the row. Four bounded hit zones: leading in-cart check, the name/measure column (also toggles the check), a "?" helper (`ItemHelperSheet`), and a "!" out-of-stock flag. Separated so a stray tap never cross-fires.
  - `CheckOffCelebration.swift` — `CheckStampPhase` / `CheckPoof` / `CheckSweep`, the one-shot check-off animation. Suppressed under Reduce Motion.
  - `GroceryListChrome.swift` — shared-status banner, add-item bar, empty state.
- `ItemHelperSheet.swift` — the "?" helper: a brief on-device blurb (`IngredientAssistant.describe`) + likely aisle. **Read-only** — the swap/substitution picker was removed 2026-06-29. `GroceryItem.substitution` is still parsed, synced, and rendered ("Swap: …", filled `?` glyph) but NOTHING in the app or the web page can currently SET it. Either restore a picker or strip the plumbing; don't assume it's reachable.
- `ShareGroceryListSheet.swift` — pick friend(s) to share with; re-opening pre-selects current recipients so it doubles as "change who".
- `StoreLayoutsView.swift` + Lib `StoreProfiles.swift` — per-store custom aisle walk order; assignment is a per-device viewing preference, so recipients get the menu too.
- `GroceryList.swift` — `GroceryList` + `GroceryItem`. `toBuyCount` / `isAllSet` / `isOpen` are the SINGLE SOURCE OF TRUTH for shopping progress (Lists row summary, Lists tab badge, done indicator all read these). `isAllSet` requires a NON-empty list. `touch()` bumps `updatedAt` on EVERY mutation incl. child scalars, so the `@Query`-driven Lists tab badge in `RootView` re-fires.
- Lib: `GroceryAisle.swift` (store-walk grouping), `GroceryKnowledge.swift` (~200-keyword aisle taxonomy incl. non-food depts + brands), `GroceryKeyword.swift` (plural-tolerant matcher), `IngredientAssistant.swift` (`triage` / `describe`).
- **Sharing** — `App/GroceryListStore.swift` + `Lib/CloudGroceryListService.swift`. See ### Shared Grocery Lists.
- **Recipe → list**: `AddToGroceryListSheet` from `RecipeDetailView` — pick which ingredients (all preselected), then a list or a new one named after the recipe. Dedups by `GroceryKeyword.normalize`, stamps `sourceRecipeID`, fires the fly-to-Lists "Added" toast (see ### Toasts).
- **Tab badges** (`RootView`): Lists tab = count of `isOpen` lists (a `@Query<GroceryList>`) OR'd with `groceryStore.hasSharedUpdate`; Friends tab = `friendsStore.incomingRequests.count`.
- **Accent cascade:** `GroceryListRow` participates in the global accent cascade exactly like `RecipeCardView` — `@Environment(AppearanceSettings)`, an `index:`, `heldAccentOverride` + `glowActive`, and `scheduleStaggeredGlow()` driven by the SHARED `recipeCardCascadeToken`. The Lists header icon (`checklist`) glows on `isAccentGlowActive(.header)` like the Library logo.
- **"Done" marking:** a fully-shopped list (`isAllSet`) renders a green-tinted card + stronger green border + a "Done" (`checkmark.seal.fill`) badge in place of the date.
- Web: `cloudflare-pages/functions/list/[id].js` — public read-only page for a shared list, `cloudflare-pages/lib/grocery.js` — record parse + aisle group + plain-text render. **No in-app entry point yet**: nothing generates a `/list/<recordName>` URL, so the page is only reachable if you know the record name.

### Shared Grocery Lists

One `GroceryListShare` CloudKit record per shared list is the source of truth for the state both sides race on. Public DB + `recipientIDs` membership (not CKShare) to reuse the existing social-graph pattern.

- **Slot model** — item metadata rides in `itemsJSON`; live state lives in flat `check0…check39` / `note0…note39` fields. Array position IS the slot index (`GroceryItem.shareIndex`). Two shoppers ticking *different* items write different fields, so they can't clobber each other. Cap = `maxSharedItems` (40); rows past it still work locally but silently don't sync (no UI warning — known gap).
- **Who owns what** — the owner is authoritative for item *structure*; anyone may flip a check or set a note. `applyItems` (recipient) rewrites rows to match the snapshot; `applyLiveState` (owner) only syncs check/note onto rows they already have.
- **INVARIANT — a re-sync must not rewrite live state it didn't change.** `upsertShare` diffs the server's existing `itemsJSON` against the incoming one and writes ONLY slots whose *occupant* changed (`slotsNeedingReseed`, keyed on the owner's stable `GroceryItem.id`). Untouched slots keep the server's values. Callers still pass every slot — `upsertShare` decides. Do not "simplify" `shareList` to pass only changed slots; the diff needs the full picture. Without this, an owner adding one item un-checked whatever the shopper had just ticked. Reseeded slots are written in FULL (including clearing a stale note) so a new item can't inherit the previous occupant's "couldn't find it".
- **Writes are blind single-round-trip patches** — `mutateSlot` builds the record locally and saves with `savePolicy = .changedKeys` at `.userInitiated` QoS; no pre-fetch. More clobber-safe than fetch-modify-save (the payload cannot contain another shopper's slot). Fetch-modify-save with `serverRecordChanged` retry remains as a fallback.
- **Reads** — on a push, `scheduleCoalescedRefresh` refreshes the list ON SCREEN first (one `record(for:)`, tracked implicitly via `refreshSharedList`) before the two-query full reconcile. Detail view also polls every 3 s for the first 20 polls, then 30 s — the owner's subscription is content-available only and iOS throttles silent pushes, so the poll is often what actually delivers.
- **Destructive-reconcile guard** — a THROWN fetch must never be flattened to `[]`: `reconcileReceived` deletes every mirror not present, and `reconcileOwned` strips sharing metadata. `refresh()` reconciles only the side whose fetch actually succeeded.
- **Deletion** — deleting an owned+shared list tears down the cloud record too, or recipients keep a ghost mirror.

### Grocery Push

Four subscriptions; see ### CloudKit Schema for IDs.

- **First share** (creation) — visible, personalized: *"Dad just shared a new grocery list with you! “Weekend Shop”"* via `GROCERY_SHARE_NEW_BODY` + args `["ownerName", "listName"]`. Carries category `GROCERY_SHARE_NEW` with **View List** / **Close** actions (registered in `AppDelegate.registerNotificationCategories`). Tap or "View List" → `llamascookbook://list/<recordName>`.
- **Later edits** (update) — visible, generic. Split from creation because a CKSubscription's payload is FIXED AT SAVE TIME: one subscription covering both can only ever carry one body.
- **Owner** — silent, update-only (no banner for your own edits).
- **Owner out-of-stock alert** — visible, creation-only on `GroceryListAlert`, via `GROCERY_OOS_ALERT_BODY`.
- **INVARIANT — `Localizable.strings` MUST live in `Resources/Localizations/en.lproj/`.** iOS string lookup only searches `.lproj` directories. A copy at the bundle root ships and is invisible, and a loc-key push then renders as the RAW KEY with no fallback (shipped that way until 2026-08-08). Nothing warns you: SwiftUI `Text("literal")` falls back to the literal, so ordinary UI looks identical either way. In `project.yml`, point the source at the PARENT dir (`Resources/Localizations`) — naming the `.lproj` or the file directly silently drops it. Verify: `find LlamasCookbook.app -name '*.lproj'`. Locked by `PushLocalizationTests`.
- **INVARIANT — permission must be asked before someone can be a recipient.** Visible pushes need `UNUserNotificationCenter` authorization; iOS silently drops the alert half when `.notDetermined`. Requested from `ListsView.task`, `ShareGroceryListSheet`, and `GroceryListDetailView`. The Lists-tab one is load-bearing: a pure recipient has never shared or opened a shared list, so without it the push announcing the list is the one being suppressed.
- **Registration gate** — `registeredForKey` is version-suffixed (`.v5`). Bump it whenever a subscription's payload/predicate/ID set changes, or existing installs skip re-registration and keep the old push forever.

### Shared-list toast

`Components/SharedListToast.swift` + `GroceryListStore.incomingShare` + `RootView.sharedListToastOverlay`.

- Top banner at the app root (above every tab — a share can land anywhere). Row opens the list; trailing ✕ dismisses and leaves you put. Auto-clears after 6 s.
- The row and the ✕ are **sibling buttons with disjoint hit areas**, never a parent `.onTapGesture` wrapping a nested `Button` — precedence between those is a SwiftUI implementation detail, and a dismiss that navigates is the worst bug an unprompted banner can have.
- **Announce only genuinely-new shares.** `hasHydratedReceivedShares` gates on the first reconcile completing; otherwise a fresh install / re-install / new device toasts every list already shared with the user.
- `openSharedList(recordName:)` in `RootView` is the ONE destination for both the banner and the push. Resolves via `groceryStore.list(withShareRecordName:)`; falls back to the Lists tab when the mirror hasn't synced yet (tapping a push can beat the reconcile). Pushes onto `listsPath` (the Lists `NavigationStack`'s programmatic path, sibling of `libraryPath`).

**Cook mode** — `Sources/Views/Cook/`
- `CookModeView.swift`
- Lib: `TimerNotifications.swift` — AlarmKit (`AlarmManager.shared`); `ResumeCookModeIntent.swift`
- `Shared/TimerAlarmMetadata.swift`; Widget: `TimerLiveActivity.swift`, `TimerWidgetBundle.swift`

**Friends / social** — `Sources/Views/Friends/`, `Sources/Lib/`
- `FriendsTabView.swift` — friend grid + `requestsSection` compact card shown above the grid whenever `friendsStore.incomingRequests` or `friendsStore.outgoingRequestProfiles` are non-empty; incoming rows have deny/accept buttons, outgoing rows show a "Sent" clock badge + cancel; animates in/out via `.spring(response:0.4)` as both lists change. `FriendLibraryView.swift` (`showsBackButton: Bool = true`), `FriendRecipeDetailView.swift`
- Lib: `CloudKitFriendship.swift`, `CloudKitUserProfile.swift`, `CloudKitPublishedRecipe.swift`, `CloudKitRecipeImport.swift`, `CloudKitSubscriptions.swift`, `CloudPendingDeleteQueue.swift`, `UserProfileMirror.swift`, `LibraryMirrorService.swift`
- `SeedFriend.swift` + `SeedRecipes.json` + `Resources/SeedPhotos/` — "Your Llama" synthetic friend; always `friends[0]`. Each seed recipe carries a `heroPhoto` filename resolved against the bundled `SeedPhotos/` folder reference and base64-encoded into the recipe-level `SharePhoto` at envelope-build time (also used as the friend-library grid `thumbnailData`). `cachedSummaries` is sorted alphabetically by title (case-insensitive, locale-aware) — seed `updatedAt` is identical across all recipes so without an explicit sort the order is undefined. `loadHeroPhoto` tries both bundle root AND `subdirectory: "SeedPhotos"` to survive whichever form xcodegen emits for the folder entry. `FriendRecipeDetailView.loadDetail`'s seed branch MUST run `decodeGallery(fetched.envelope)` (not hardcoded empty) or the detail view's photos strip stays blank. Photo sources logged in `md_files/seed-photo-credits.md`

**Quota + IAP** — `Sources/Lib/`, `Sources/Views/Profile/`
- `QuotaService.swift`, `LlamaProStore.swift`, `PaywallView.swift`

**Auth** — `Sources/Lib/`
- `SignInWithAppleService.swift`, `KeychainStore.swift`

**Share extension** — `ShareExtension/`
- `ShareViewController.swift` — URL → `llamascookbook://share-url/`, file → App Group inbox
- `Sources/Shared/SharedContainer.swift`, `Base64URL.swift`

**Cloudflare Workers** — `cloudflare-pages/`
- `functions/r/[id].js` — OG preview; `functions/img/[id].js` — image proxy (10 MB cap, magic-byte sniff)
- `functions/api/parse.js` — Anthropic proxy + quota enforcement + KV parse-result cache
- `functions/api/usage.js` (GET quota snapshot), `functions/api/usage/consume.js` (POST save-confirm)
- `lib/cloudkit.js` — CloudKit Web Services client (ECDSA P-256); `lib/quota.js` — shared quota helpers
- `.well-known/apple-app-site-association` — AASA

**Reusable components** — `Sources/Views/Components/`
- `PhotoCarouselView`, `PhotoReorderView`, `CameraCaptureView`, `ShareSheet`, `LlamaLogo`, `LlamaWatermark`, `LlamaProgressIndicator`
- `LlamaFloatModifier.swift` — `.llamaFloat()` bob animation; 250ms delayed start (do not remove)
- `AccentColorPicker.swift`, `SavedToast.swift`, `SharedListToast.swift`, `RecipeImageView.swift`
- Lib: `ImageProcessing.swift`, `Conversions.swift`, `Quantity.swift`, `SourdoughCalculator.swift`, `Haptics.swift`, `SwipeBack.swift`, `AppMetadata.swift`

**Shared helpers — always reuse, never re-inline**

| Helper | File | Purpose |
|---|---|---|
| `ContentModeration.check/isClean` | `Lib/ContentModeration.swift` | Profanity/slur screen for user-chosen NAMES — BLOCK-at-commit. Mirrored server-side in `cloudflare-pages/lib/moderation.js` (keep the two word lists in sync). See ### Content Moderation |
| `GroceryKeyword.normalize` | `Lib/GroceryKeyword.swift` | Shared normalization for grocery item names (recipe→list dedup) |
| `FlyToast` + `runFriendImportToast` | `App/NavigationContext.swift`, `App/RootView.swift` | Spring-to-a-tab "Saved/Added" toast — friend-import AND recipe→list both use it. See ### Toasts |
| `View.cardScrollTransition()` | `Components/View+CardScrollTransition.swift` | Scroll-focus zoom on card lists |
| `View.cardGlare(cornerRadius:)` | `Components/View+CardGlare.swift` | Card glare: soft sweep-in on entry + scroll-reactive shine + static top/bottom edge depth rim, clipped to card shape |
| `View.scrollSectionHaptic(section:ticker:)` + `ScrollSectionTicker` | `Components/ScrollSectionHaptic.swift` | Per-section scroll tick — fires on (a) each card crossing while free-scrolling cookbook / friend-library lists (section key = `recipe.id.uuidString` / `summary.id`, so every card ticks regardless of letter bucket), (b) each chip crossing on category/tag chip strips (`LibraryView.filterStrip`, `CategoryFilterStrip`, `RecipeDetailView` / `FriendRecipeDetailView` tags), (c) each major-section boundary AND each ingredient/step row crossing while scrolling `RecipeDetailView` / `FriendRecipeDetailView` content, and (d) each ingredient row / step row crossing while scrolling `CookModeView` (one shared `hapticTicker` for both lists — unique row ids dedup; reset on phase flip and on `recipe.id` change). Major-section markers are 1pt `sectionAnchor("ingredients"/"steps"/"photos"/"notes"/"general"/"reference"/"delete")` views (so tall sections still hit the 0.95 threshold on header crossing); per-row ticks are layered on top with section key = ingredient/step `id.uuidString`. Unique dedup keys keep header and row crossings distinct on the same shared ticker. One `ScrollSectionTicker` per scroll surface, never shared — `RecipeDetailView` / `FriendRecipeDetailView` use ONE shared ticker for tags + section anchors + row anchors (same vertical surface); the horizontal chip strips have their own. Call `ticker.reset()` when the section/tag/chip set changes wholesale (LibraryView on `allTags` change, CategoryFilterStrip on `categories` change, RecipeDetailView on `recipe.id` change, FriendRecipeDetailView on each `loadDetail()`). `ticker.magnifyLetter` is the observable `LetterIndex` magnify-pulse channel (set only on a real letter-bucket crossing, never on first report or `reset()`) — it fires LESS often than the per-card haptic now that cards tick individually |
| `Haptics.*` | `Lib/Haptics.swift` | ALL haptic feedback. Every call site MUST go through a named `Haptics.*` function (`selection()`, `success()`, `warning()`, `impact(_:)`, `recipeSaved()`, `cookModeStarted()`, `timerAlmostDone()`) — never construct `UINotificationFeedbackGenerator` / `UIImpactFeedbackGenerator` / `UISelectionFeedbackGenerator` inline at a call site. Generators live only inside `Haptics.swift`; add a new named wrapper there if one is missing. Never fire from a `@ViewBuilder` body — only callbacks / `.onChange` / `.task` / `.onAppear` / button actions |
| `View.surfaceCard(cornerRadius:)` | `Components/View+SurfaceCard.swift` | Settings/info card chrome |
| `View.liftedCard()` | `Components/View+Lifted.swift` | Static drop shadow, non-interactive cards |
| `.buttonStyle(.lifted)` | `Components/View+Lifted.swift` | Press-down shadow + 0.96 scale |
| `.buttonStyle(.scaleOnly)` | `Components/View+Lifted.swift` | Scale-only, no shadow (elevated surfaces) |
| `LlamaLogoOrCrown(size:accent:crownAsset:)` | `Components/LlamaLogoOrCrown.swift` | Llama / Pro crown swap |
| `Formatters.date` | `Lib/Formatters.swift` | All date display — `.medium` style only |
| `Optional<String>.trimmedIfNonEmpty` | `Lib/String+Extensions.swift` | Trim + nil-if-empty |
| `UserProfileSnapshot.resolvedAccent` | `Lib/CloudKitUserProfile.swift` | Friend accent with terracotta fallback |
| `LetterIndex.firstItem(in:atOrAfter:letters:bucket:)` | `Components/LetterIndex.swift` | Letter-scrub traversal |

---

## Critical Invariants

### SwiftData
- `cloudKitDatabase: .none` — cascade deletes + non-optional props break CloudKit auto-opt-in (silently degrades to in-memory)
- `RecipeStep.image` and `Recipe.imageUri` are deprecated migration baggage — do not repurpose
- `Recipe.apply(_:)` must NOT touch `sharedBy`/`sharedAt`/`sourceShareID` or any `originalCreator*`/`originalSharer*`/`originalRecipeID`/`importedAt` — attribution is stamped at materialize time and must survive saves

### CloudKit
- `UserProfile` recordName = `profile_<iCloudUserRecordName>` — prefix applied/stripped in `CloudKitUserProfile.swift`; callers pass raw record names
- `PublishedRecipe.recordName == Recipe.id.uuidString`
- Predicates must be **split per field, not OR** — public-DB OR on non-queryable fields throws `invalidArguments`
- `queryAllRecords` must follow cursors — never truncate to first page
- HEIC → JPEG before CloudKit upload via `ImageProcessing.transcodeHEICToJPEGForSharing`; local SwiftData stays HEIC
- `RecipeShareLimits.maxInboundBytes` (25 MB) in `Sources/Shared/` — shared by app and share extension

### SwiftUI / iOS 26
- **Re-inject `@Observable` environments into every `sheet`/`fullScreenCover`** — values drop across presentation boundaries on iOS 26
- Custom back buttons: `.navigationBarBackButtonHidden(true)` + `.enableSwipeBack()` (`SwipeBack.swift`). `RecipeEditorView` intentionally omits `.enableSwipeBack()` (Cancel/Save, data-loss risk)
- `AccentColorPicker` commits on `.onDisappear` — driving it earlier desyncs `UIColorPickerViewController`
- `.drawingGroup()` goes INSIDE `.clipShape()` / before outer shadows. Never apply to views using `.blur()` or `.regularMaterial`
- `.buttonStyle(.lifted)` must NOT be applied inside `.drawingGroup()` — shadows clip to texture bounds
- `cardGlare(cornerRadius:)` — apply AFTER the card's `.drawingGroup()` (it's a thin overlay); pass the SAME radius the card clips to so all layers stay inside the corners. Renders three layers: a soft one-shot sweep-in, a scroll-reactive shine, and a static always-on top/bottom edge-depth rim. Sweep + shine positioning runs entirely via `visualEffect` (layout-pass, no `body` invalidation) + a one-shot `onAppear` sweep; the edge-depth rim has NO state/animation/`visualEffect` — never per-frame `@State`
- Scroll-list haptics: fire via `scrollSectionHaptic(section:ticker:)` per row, NOT inline. One `ScrollSectionTicker` per list (`@State`); call `ticker.reset()` on filter/sort change so a re-populated list doesn't tick on settle. The cookbook list (`LibraryView`) and friend library (`FriendLibraryView`) cards tick **per card** — `section:` is the card's stable id (`recipe.id.uuidString` / `summary.id`), NOT the letter bucket — so long letter sections still tick every row as it passes the focus line. Letter-bucket grouping is surfaced separately via the `LetterIndex` magnify-pulse channel (`ticker.magnifyLetter`), which is unchanged. `RecipeDetailView` / `FriendRecipeDetailView` ingredients and steps tick **per row** (section key = ingredient/step `id.uuidString`); the existing `sectionAnchor("ingredients"/"steps"/…)` markers above each ForEach still fire ONCE on header crossing — different dedup keys, won't collide on the shared `hapticTicker`. `CookModeView`'s ingredient list and step list each tick per row using the single shared `hapticTicker` (both lists live inside the same outer `ScrollView`; unique row-id keys keep crossings distinct); reset on phase flip and on `recipe.id` change so the list swap doesn't tick on settle. The horizontal category-chip strips (`LibraryView.filterStrip`, `CategoryFilterStrip`) use the same modifier with their OWN per-strip ticker — never share with the recipe-list ticker, or moving focus between strip and list mis-ticks; reset on chip-set change
- Scroll-driven `LetterIndex` magnify: feed `scrollTicker.magnifyLetter` into `LetterIndex(scrollFocusLetter:)` — `magnifyLetter` is set only on a real letter-bucket boundary crossing (never on first report or `reset()`). The per-card scroll haptic now ticks more often than the magnify pulse (every card vs. every bucket change), so the two channels are intentionally decoupled — the magnify pulse still marks letter transitions, while the haptic gives one-card-at-a-time feedback. Each bucket crossing pulses the compact magnify badge (quick fade-in / brief hold / fade-out). `scrollFocusLetter` is a SEPARATE channel from `externalHighlightLetter` — the transient scroll pulse and persistent post-save flash render in their own overlay layers with their own state; do not overload one for the other. Precedence: an active scrubber drag (`activeIndex`) and the post-save flash (`externalHighlightLetter`/its fading echo) BOTH outrank the scroll pulse — `pulseIndex` is `nil` whenever either owns the badge. Pulse is event-driven (one `withAnimation` per crossing), never per-frame `@State`

### Auth / Social
- `UserProfileMirror.cachedRecordID()` is the canonical "is iCloud bound?" check — all social writes short-circuit when nil
- `FriendsStore.refresh()` sets `isRefreshing` synchronously before any `await` (re-entrancy guard)
- `LibraryMirrorService` — `@MainActor` singleton, 5s debounce per `Recipe.id`; sign-out/delete must call `resetBulkPublishMarker()`
- `ImportCountCache` lives in UserDefaults, not `@Model` — prevents spurious `LibraryMirrorService` re-publishes
- `SeedFriend.isSeed(_:)` short-circuits ALL CloudKit fan-outs (fetch, import, remove, etc.) — never remove this guard

### UserDefaults Caches (stale-while-revalidate)
- `LlamaProStore.plan` → key `"llamaPro.cachedPlan"` — always use `setPlan(_:)`, never direct assignment
- `FriendsStore` friends → key `"friendsStore.cachedFriends"` — only real CloudKit friends cached; seed friend always prepended programmatically. `clearOnSignOut()` removes the key

### Accent / Appearance
- Unsigned user accent is always terracotta — `applySignedOut()` uses `isForcingDefault` flag so stored prefs survive sign-out
- Plan pills and upgrade chips use `AppColor.accent` (terracotta `#C97C5D`), never `appearance.accentColor`
- `AppearanceSettings.previewAccentColor` is the uncommitted live pick — set continuously from `AccentColorPicker`'s `pickerColor` so the cookbook title retints instantly (no wait for the `.onDisappear` commit). It has NO didSet side-effects and `AccentColorPicker.body` must never read it (would re-snapshot `UIColorPickerViewController`). `cookbookTitleAccentColor` returns it when non-nil; `commitSelection` clears it. Only set while signed in
- Accent-cascade sequence (`startAccentTransition`) is strictly ordered, total run ~0.7s: All chip at t=0 (`.allChip` stage, `allChipAccentColor`) → header (llama glow + profile button) at t=0.08 → categories (Favorites + tag chips) at t=0.14 → `recipeList` stage at t=0.20 + BOTH per-row tokens bumped synchronously (`recipeCardCascadeToken`, `letterIndexCascadeToken`) → plus button at t=0.55 → bottom tab bar at t=0.66 → state clears at t=0.85. **The cookbook title is EXCLUDED from the header stage's color application**: `cookbookTitleAccentColor` returns `accentColor` directly (bypassing `transitionColor`), never the cascade-held old color — the title is already showing the new color from `previewAccentColor` before Done is tapped, and must not briefly revert to the old hue when the cascade fires. The header stage's glow (`isAccentGlowActive(.header)`) still applies to the llama and profile button; only the title color is excluded. Per-row stagger: each `RecipeCardView` and each `LetterRow` snapshot `cascadePreviousAccentColor` as a local `heldAccentOverride`, then clear it (and pulse glow) at `recipeListFlipDelay (0.20) + index * stagger` — cards at `recipeCardGlowStagger` (0.035s), letter rows at `letterIndexGlowStagger` (0.012s). Result: titles AND letter strip retint top → bottom in lockstep rather than flipping in unison. `LibraryView` MUST pass `index:` to `RecipeCardView` (via `filtered.enumerated()`) AND pass `previousAccent:` + `cascadeToken:` into `LetterIndex` or both staggers collapse. `isAccentGlowActive(.recipeList)` stays a single shared boolean that drives the global `LetterIndex` glow halo and the recipe-list color floor; per-row holds are layered on top. The All chip's `.allChip` stage is SEPARATE from `.categories` so the All pill can lead the cascade visibly before the rest of the chips. **Category chips** advance left → right via `categoryCascadeToken` (bumped synchronously at cascade start); each `FilterChip` schedules its own reveal at `categoriesFlipDelay (0.14) + index * categoryChipGlowStagger (0.025)` — a 15-chip strip completes in ~0.375 s, inside the `.categories` → `.recipeList` window. **ProfileView** now has its own parallel `ProfileTransitionStage` 6-stage cascade: `header (t=0)` → `colorNudge (0.08)` → `nameCard (0.14)` → `lastCooked (0.20)` → `requests (0.26)` → `friendsList (0.33)`; `friendLetterCascadeToken` is bumped at cascade start and ProfileView's `LetterIndex` uses `profileFriendsListFlipDelay (0.33)` as its base delay (instead of `recipeListFlipDelay (0.20)`) so its per-row stagger fires inside the profile beat. `FriendLibraryView`'s `LetterIndex` still passes `cascadeToken: 0` and never bumps — that list doesn't participate

### Photo Import
- `ImportFromPhotoView` always sets `.interactiveDismissDisabled(true)` unconditionally — not just during OCR
- Anthropic vision rejects HEIC — `aiVision` format forces JPEG via `forcesJPEGOutput`
- `VisionParseOutcome.error` non-nil = Worker rejected (quota/auth/rate-limit) → do NOT fall through to OCR; refresh `QuotaService` instead
- `performSave` does NOT call `dismiss()` — `onSaved`/`onSavedForEdit` closures dismiss `ImportFromPhotoView`, collapsing the full sheet hierarchy in one animation
- Parse-result KV cache key: `parseCache:<promptVersion>:model=<model>:<contentHash>`. `PROMPT_VERSION = "v3"` in `parse.js` — bump whenever `RecipeAIParser.instructions` changes
- Photo-import quota: Free 5 saves/month, Pro 30/month, 5 parse attempts/day. iOS sends `x-llamas-user`, `x-llamas-tz`, `x-llamas-import-kind: photo`. Consume is fire-and-forget (save to SwiftData first, then POST)
- Text/link parse abuse gate (NOT a user-visible feature limit): per-identity daily cap in the Worker — `TEXT_LINK_DAILY_CAP_SIGNED = 100` keyed on `x-llamas-user`, `TEXT_LINK_DAILY_CAP_ANON = 30` keyed on `cf-connecting-ip` when no user header is present. Hit returns HTTP 429 with `{error:"rate_limited",scope,limit,used,resetAt}`. Sign-in is NOT required for text/link — anon users get the lower cap. Plus `TEXT_LINK_MAX_BODY_BYTES = 60 * 1024` server-side body-size cap (returns 413). iOS text-path sends `x-llamas-import-kind: text`, `x-llamas-user` (if signed in), `x-llamas-tz`; treats 429 the same as Anthropic 429 (back off + retry); after retries exhausted, caller falls back to Apple Intelligence → regex unchanged. Counter is incremented BEFORE forwarding so abuse ticks even on upstream failure. KV key shape: `textParse:<user:<id>|ip:<addr>>:<YYYY-MM-DD>` with 26h TTL. Constants live in `cloudflare-pages/lib/quota.js`
- **Camera vs library image fidelity**: `PhotosPicker` hands us raw photo bytes via `loadTransferable(type: Data.self)` (typically HEIC); `UIImagePickerController` only gives us a `UIImage`. The camera path in `ImportFromPhotoView.preparePages` MUST go through `ImageProcessing.prepare(uiImage:for:)` — never `UIImage.jpegData(compressionQuality:)` then `ImageProcessing.prepare(_:for:)`, which adds a lossy JPEG round-trip that measurably degrades Sonnet's handwriting recognition on dim photos. `ImageProcessing.prepare(cgImage:for:)` is the underlying single-encode primitive (CGContext resize → CGImageDestination at target format); `prepare(uiImage:)` is a thin wrapper that pulls `.cgImage` first.
- `photoImportConfident(_:)` gate: `title.nonEmpty && (ingredients.nonEmpty || steps.nonEmpty)` — NOT all three. The earlier "all three" form rejected partial-but-truthful Sonnet drafts (e.g. an ingredient-only handwritten card with no instructions on it) and dumped the user into the OCR regex fallback, which on noisy handwritten input produces worse output than the partial vision draft. The NEVER FABRICATE rule in the system prompt makes an empty section a deliberate truthful answer, not a parse failure.
- `RecipeImporter.stripTitleLabel` strips dash-suffixed yield ("Empanada Dough - 28 servings" → "Empanada Dough"). Handwritten cards routinely glue yield onto the title line; the parser still recovers the number via the regular metadata extractor. Pattern is constrained to trailing `\s*[-–—]\s*\d+\s*(servings?|portions?|makes|yields?|people)\b.*$` so legit dash content ("Mac n Cheese - 4 ways") survives — covered by `RecipeImporterTests.testCleanTitleStripsDashYieldSuffix` and `testCleanTitlePreservesNonYieldDashSuffix`.
- **Processing-overlay cap + skeleton reveal**: `PhotoImportPreviewView.overlayTimeoutSeconds = 4`. The "Asking the llama…" modal dismisses on whichever fires first — title-token arrival OR the 4 s timeout. Past the timeout, `showSkeleton` flips true and `titleBlock` / `ingredientsSection` / `stepsSection` render pulsing `SkeletonBlock` placeholders so the user sees structure within 4 s on slow networks. Real content replaces the skeleton via the existing tick-in transitions as the stream lands. The timeout `Task` is armed in `.onAppear` (only when streaming + title empty), cancelled in `.onDisappear`; never poll. Don't remove the 4 s cap — observed Sonnet TTFB has a long tail.

### AI Parser Chain
- Text/link: `RecipeAIParser.parseBestOf` → `AnthropicRecipeParser.parse` (CF Worker `/api/parse`) → Apple Intelligence → regex
- Photo: `RecipeAIParser.parseImagesStreaming` → streaming SSE Sonnet 4.6 → OCR text-AI fallback
- `AnthropicRecipeParser.isConfigured = true` unconditionally — API key lives in Cloudflare env only, never in binary or Keychain

### Instagram Import (`RecipeURLImporter.fetchInstagram`)
- Three-stage device-side: (1) inline JSON for full caption; (2) `og:*` meta + mp4 download + on-device `SFSpeechRecognizer` transcription; (3) `.insufficientForImport` handoff. All network from user's residential IP (IG blocks Cloudflare datacenter ranges); desktop UA mandatory in `InstagramExtractor` (mobile UA gets the "Open in app" stub with no meta tags).
- **Confidence gate (IG only)**: `.full` requires `title + ingredients`. **Steps are optional** — IG reels routinely ship ingredients in the caption while narrating prep only in the video audio, so transcription-failed-but-caption-clean drafts are still a useful save. When `.full` returns with an empty `steps` array, `ImportFromTextLinkView` shows an `.info` heads-up banner ("Got the title and ingredients — I couldn't pull steps from this. Tap Preview and add them in the editor.") instead of the plain success banner; user lands in the editor with empty steps section ready to fill. Looser drafts (missing title OR missing ingredients) route to `.insufficientForImport(enrichment:hint:)` which `ImportFromTextLinkView` surfaces as a "Write it down myself" capsule below the warning banner. Tap clears `editor.hasUnsavedChanges` and calls `editor.startNew(seed: enrichment)` — `EditorCoordinator` swaps the sheet content in-place to `RecipeEditorView` with hero photo + source URL + `@creator` summary pre-filled. The empty-steps heads-up banner trigger lives in `ImportFromTextLinkView.fetchURL`'s `.full` branch and applies to ANY platform whose `.full` outcome happens to have empty steps, not just IG. TikTok / Pinterest / generic-blog imports keep their looser `.partial` behavior; the IG-specific bar is the **title + ingredients** requirement before returning `.full`. **Critical**: the AI parser's NEVER FABRICATE rule (`RecipeAIParser.instructions`) guarantees an empty `steps` array is a truthful answer — never paper over it with placeholder steps, and never relax the rule to "fill in plausible steps from the title".
- **Hallucination guard (IG only)** — `RecipeURLImporter.isAIDraftGroundedInSource(_:sourceText:)` rejects AI drafts whose title shares ZERO significant (≥4 chars, non-stopword) words with the source text. IG often serves crawlers only a truncated `og:description` preview, and Haiku given sparse input has been observed to fabricate fully-formed recipes from training data (real case: a Cheese Danish reel where the og:description "Copycat Starbucks Cheese Danish! Recipe in caption…" was all we got triggered a complete "Greek Pasta Salad" with matching ingredients + steps). The guard catches that class of failure — if the title can't be grounded in the source bytes we actually sent the model, the whole draft is treated as fabricated and routed to `.insufficientForImport`. Only validates the title (not ingredients — those are routinely paraphrased through canonical units and would false-positive). Lives in `buildInstagramOutcome(aiDraft:enrichment:sourceText:)`; the source text passed in is the SAME post-`liftHashtags` string that went to the AI parser, so the guard reasons against the exact bytes the model saw.
- **Hero photo fallback chain (in priority order)**:
  1. **mp4 first-frame** via `InstagramExtractor.extractFirstFrame(from:)`. IG bakes its white play triangle into `og:image` for ANY video post — extracting the actual video frame dodges it. The extractor retries multiple candidate timestamps (`[1.0, 0.5, 2.0, 0.1, 0.0]` filtered by clip duration) with **infinite `requestedTimeTolerance` both directions** so AVFoundation snaps to the nearest keyframe — earlier strict `tolerance = .zero` at t=0.1s was failing silently on real reels (IG places first keyframes at 1–2 s in many clips) and dumping users into the play-overlay'd og:image fallback. JPEG-encoded at quality 0.85 via `ImageIO`. Returns nil (never throws) on any failure.
  2. **Non-video carousel slide** via `Extraction.carouselPhotoURLs` (parsed from `edge_sidecar_to_children.edges[].node.display_url` where `is_video == false`). For carousels containing any video item, IG also bakes the play overlay into `og:image` — picking a non-video slide directly dodges it.
  3. **`og:image` thumbnail** (last resort — has play overlay baked in for video posts). Photo posts with no video get this safely; video posts only reach here if both prior steps failed.
- All three candidate downloads (mp4, first carousel slide, og:image) fire as parallel `Task.detached` immediately after extraction so each is hot-cached by the time the fallback chain asks for it. Diagnostic logging via `os.Logger` subsystem `com.llamascookbook.app`, categories `InstagramExtractor` + `RecipeURLImporter.Instagram` — filter Console.app on those when debugging a "still shows play overlay" report.
- **Parallelism (deliberate, do not collapse to serial)**:
  - mp4 download + `og:image` thumbnail download fire as **parallel detached `Task`s** immediately after extraction, before any stage branching. Whichever path the import takes we end up needing the hero photo, and the mp4 is needed for transcription in stage 2 anyway.
  - **Stage 1** (full caption available): `RecipeAIParser.parseBestOf` runs **in parallel** with hero-photo resolution via `async let`. AI parse usually finishes first (~1–2s) and we just wait for frame-extract to complete (~mp4 download + 200ms). Saves 1–3 s vs. serial.
  - **Stage 2** (transcription needed): once the mp4 lands, first-frame extraction (`Task.detached`) runs **in parallel** with `SpeechTranscriber.transcribe` — both read the same file read-only. Saves ~200–300ms.
  - `cleanupInstagramVideoFile(_:)` awaits the download Task's cached value at end, then removes the tmp file. Don't replace with `defer { try? FileManager.default.removeItem }` — `defer` runs synchronously and can't `await` the Task.
- **Speech**: `SpeechTranscriber` uses `SFSpeechRecognizer` (not iOS 26 `SpeechAnalyzer`) for stability + the 60s-per-request limit matches reel length. `requiresOnDeviceRecognition = true`. Permission gated via `NSSpeechRecognitionUsageDescription`.

### Performance
- `RecipeImageView` decodes asynchronously — NSCache hit = warm `@State`; miss = `Task.detached` off main thread. Never use synchronous `UIImage(data:)` in `body` (HEIC takes 50–150ms, stalls push-animation frames)
- `RecipeImagePrewarm.prewarm(_ datas: [Data])` — batch-decodes a set of payloads into the shared `imageCache` off-main. Required when many cells with photos realize at once in a `LazyVStack` (e.g. seed friend's 25-card cookbook): without prewarm, each cell's own `.task(id:)` decode can lose its `@State` update to cell-realization churn, leaving the placeholder visible until the user taps into a detail view (which warms the cache as a side effect) and pops back. `FriendLibraryView.loadLibrary` calls this in the seed branch BEFORE assigning `summaries`, so the cache is hot by the time the grid cells' `init` warm-check runs. Fire-and-forget; idempotent (cache hits are skipped); the existing per-cell `.task(id:)` is the fallback if a cell realizes before prewarm finishes
- `.llamaFloat()` has 250ms delayed start (`LlamaFloatModifier`) — do not remove when adding new call sites

### Content Moderation
- User-chosen NAMES are BLOCK-at-commit screened by `ContentModeration` (`Lib/ContentModeration.swift`): recipe title (`RecipeEditorView.save`), grocery list name (`ListsView.createList` + `GroceryListDetailView.renameList`), display name (`UserAccount.updateDisplayName` is `@discardableResult -> Bool`, returns false WITHOUT applying when blocked; `ProfileView.commitNameEdit` checks first + shows the alert), custom tags (`TagInputView.commitPending`). All surface `ContentModeration.blockedMessage`. Long-form body prose is deliberately NOT screened (false-positive friction).
- `cloudflare-pages/lib/moderation.js` MIRRORS the Swift word list + normalizer EXACTLY — edit both together. It's the non-bypassable backstop (any signed-in iCloud user can write these public records). Wired into the public OG render (`functions/r/[id].js` → `sanitizedOr` neutralizes a profane title) AND the shared-list page (`functions/list/[id].js` screens the list title, every item name, each substitution, and `ownerName`).
- Matching is whole-token (+ leetspeak/diacritic/separator/repeat-collapse normalization) to dodge the Scunthorpe problem; a culinary allowlist (shiitake, bass, cumin, coq…) backstops false positives. Tests: `ContentModerationTests.swift` + `cloudflare-pages/test/moderation.test.js`.
- Complementary App Store 1.2 requirements NOT yet built (fast-follow): report-a-shared-recipe/list, block-a-user.

### Toasts (fly-to-tab)
- `FlyToast` (`NavigationContext.swift`) is the generalized payload for the spring-to-a-tab success affordance (centered `SavedToast` badge + `ImportFlyGhost` token); `FriendImportToast` is a back-compat typealias. ONE overlay + ONE runner in `RootView` (`friendImportToastOverlay` / `runFriendImportToast`, observing `navContext.pendingFriendImportToast`) drive BOTH the friend-import save (bookmark → Home) and the recipe→grocery-list add (basket → Lists). Fire one with `FlyToast(accentHex:glyph:label:destinationTab:)`; the destination x is computed from the tab's index (`width·(2i+1)/8`). `SavedToast`/`ImportFlyGhost` take a `glyph` (default `bookmark.fill`).

### AlarmKit
- Cook-timer lock-screen alerts + Live Activity owned by AlarmKit. Sound always `AlertConfiguration.AlertSound.default`

### Haptics (`Lib/Haptics.swift`)
- All haptics route through the `Haptics` enum — never construct `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` / `CHHapticEngine` at a call site
- Named moments: `recipeSaved()` (CoreHaptics save thud — used by editor save + photo-import save), `cookModeStarted()` / `timerAlmostDone()` (ascending light→medium→heavy ramps), plus `impact`/`selection`/`success`/`warning`
- `recipeSaved()` is the canonical save feedback — text/link imports persist via `RecipeEditorView.save()`, so they already get the thud; do NOT fire it again in `ImportFromTextLinkView`
- CoreHaptics engine is a lazily-warmed `@MainActor` singleton (`HapticEngineHost`); rebuilds silently on iOS reset, falls back to `UIImpact(.heavy)` when haptics are unavailable

### Cook pills / bottom overlay clearance (`RecipeDetailView`)
- `CookingPillsOverlay` (applied per-tab in `RootView`) uses `.overlay(alignment: .bottom)`, NOT `safeAreaInset` — the scroll view inside `RecipeDetailView` doesn't automatically know about the pill.
- **Tap priority (load-bearing):** the pill bar carries `.contentShape(Rectangle())` + a no-op `.onTapGesture { }` so a tap that lands in the bar's footprint but MISSES a pill is absorbed instead of falling through to a recipe card scrolling behind the overlay. The pills are `Button`s, so their taps still win inside the region — only stray gaps are swallowed. Don't remove this; it's what stops accidental recipe taps while reaching for the pill.
- `RecipeDetailView` handles this with two layered mechanisms:
  1. `safeAreaInset(edge: .bottom)` — renders `startCookingBar` when no active cooks; renders `Color.clear.frame(height: 70)` when cook mode is minimized (resume pill visible). This is the **primary** clearance: it shrinks the scroll view's scrollable region so content can never rest behind an overlay.
  2. `.padding(.bottom, AppSpacing.xl + bottomOverlayClearance)` — adds runway so the Delete button clears the inset boundary. `bottomOverlayClearance` = 80 for the Start Cooking bar, 40 for the resume pill (safeAreaInset already handles the pill's footprint), 0 when Cook Mode is foregrounded.
- The 70pt spacer = pill height (~54pt) + `CookingPillsOverlay` bottom gap (`AppSpacing.md` = 12pt) + 4pt air.
- `CookPill` (non-compact path) enforces uniform height via `.lineLimit(1)` on the title `Text` — never `.lineLimit(2)` or higher. Long titles truncate with `.truncationMode(.tail)`. The compact path also uses `.lineLimit(2)` / `.minimumScaleFactor(0.7)` intentionally (compact pills are narrower and need wrapping), but only the standard single-pill uses strict `.lineLimit(1)`.

### CI
- `macos-26` renames beta Xcode `.app`s `_disabled_…` and re-pins both `DEVELOPER_DIR` and `PATH` — setting only `DEVELOPER_DIR` leaves sub-tools on the beta; TestFlight rejects beta-built archives

---

## CloudKit Schema

Public DB. **World READ; write scoped to `_icloud`** (`GRANT WRITE TO "_creator"`, `GRANT READ, CREATE, WRITE TO "_icloud"`, `GRANT READ TO "_world"`). Signed-in recipients are `_icloud`, so they can still tick items off. Never grant WRITE to `_world` — every field on these records is already attacker-controlled (hence the escaping + moderation on the public web renders); world-write would let an unauthenticated caller rewrite anyone's data.

| Record type | Key fields | Notes |
|---|---|---|
| `RecipeShare` | `envelope` (Asset), `senderDisplayName`, `recipeTitle`, `createdAt`, `photo0`–`photo19` | 12-char recordName; CF routes legacy 6-char IDs |
| `UserProfile` | `displayName`, `accentHex`, `createdAt`, `lastCookedAt`, `lastCookedRecipeID`, `lastCookedTitle`, `cookingStartedAt` | recordName = `profile_<iCloudUserRecordName>` |
| `Friendship` | `userA`, `userB` (queryable, lexicographic pair), `requesterID`, `status`, `acceptedAt` | One record per pair; deny is destructive |
| `PublishedRecipe` | `ownerID`, `localRecipeID`, `recipeTitle`, `updatedAt`, `originalCreatorID`, `originalRecipeID`, `summary`, `tags` (String List), `photo0`–`photo19` | recordName = `Recipe.id.uuidString`; `summary`+`tags` not queryable |
| `RecipeImport` | `originalCreatorID`, `originalRecipeID`, `importerID`, `importerDisplayName`, `sourceUserID`, `importedAt` | Append-only audit log |
| `GroceryListShare` | `ownerID` (Q), `ownerName`, `listName`, `itemsJSON`, `revisedByName`, `recipientIDs` (List, Q), `updatedAt` (Q+S), `check0`–`check39` (Int64), `note0`–`note39` | recordName = `GroceryList.id.uuidString`. Note format: `"out"` \| `"sub:<text>"` |
| `GroceryListAlert` | `ownerID` (Q), `listRecordName`, `listName`, `itemName`, `shopperName`, `createdAt` | Creation-only; exists solely so the owner's subscription has something to fire a visible push on. `shopperName`/`itemName`/`listName` are load-bearing NAMES — the push body interpolates them server-side |

Photo cap: 10 MB per asset, 40 MB total. `photo0`–`photo19` must be added manually in CloudKit Console.

**Deploy** — `cloudkit/` holds `.ckdb` fragments + `deploy-grocery-schema.sh` (export → merge → import → verify both types). Fragments are exported verbatim from Production; if you change the schema in the Console, re-export rather than hand-editing, or the next run of the script reverts you. Needs a management token: `xcrun cktool save-token --type management` (account-level Settings → Tokens in CloudKit Console — NOT the container's API Access section, which holds the server-to-server key the Worker uses). Verified deployed in Dev + Production 2026-08-09.

**Push subscriptions** — `friendship-events-A/B-<me>`, `recipe-import-events-<me>`, `grocery-list-shared-<me>` (first share, visible + actionable), `grocery-list-events-recipient-<me>` (later edits, visible), `grocery-list-events-owner-<me>` (silent), `grocery-list-alerts-<me>` (out-of-stock, visible). Fan-out: `AppDelegate` → `CloudKitSubscriptions.dispatchRemoteNotification` → `Notification.Name.cloudKitSubscriptionFired`; the grocery prefixes all map to `.groceryList`. See ### Grocery Push.

---

## Signing & Security

**GitHub Secrets:** `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_WIDGET_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_EXT_PROVISIONING_PROFILE_BASE64`, `APPSTORE_API_KEY_P8_BASE64`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`

**Cloudflare Pages env:** `CLOUDKIT_CONTAINER_ID`, `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (encrypted), `CLOUDKIT_ENVIRONMENT`, `ANTHROPIC_API_KEY` (encrypted)

**Entitlements** (`Resources/LlamasCookbook.entitlements`): App Group, SIWA, iCloud CloudKit, Associated Domains (`applinks:llamascookbook.pages.dev`), `aps-environment`. Regenerate provisioning profile after any capability change.

**Keychain** (`KeychainStore.swift`): `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable.

**Liquid Glass** — opted IN (2026-05-25). `UIDesignRequiresCompatibility` removed from `AppInfo.plist`; stock SwiftUI/UIKit surfaces render with iOS 26 glass materials. `RootView.configureTabBarAppearance` calls `configureWithDefaultBackground()` explicitly so the tab-bar proxy survives the flip.
- **Established glass call shapes (the only forms confirmed compiling in-repo — reuse these, don't invent):** inactive chip → `.glassEffect(.regular, in: Capsule())`; interactive tinted control → `.glassEffect(.regular.tint(<Color>).interactive(), in: <Capsule/.circle/RoundedRectangle>)`. The active/inactive capsule split lives in `LibraryView.ChipBackground` / `CategoryFilterStrip.ChipBackground` (active = solid accent fill, inactive = glass). (`GroceryListDetailView.GlassChipBackground` is gone — it backed the removed have/need toggle.)
- **Convention:** floating CONTROLS/chips/action-bars use `.glassEffect`; content CARDS stay solid (`.liftedCard()` / `.surfaceCard()`); decorative icon wells are tinted fills (not glass); tab badges are native `.badge()`. Cream `AppColor.onAccent` glyphs ON glass carry `.accentTextOutline()` to lift off the translucent backing.
- **Adopted glass (2026-06-26 LG pass):** `RecipeDetailView.startCookingBar` (tinted interactive glass, matching its CookPill twin), `RootView.AddToCookButton` (outline), grocery add-item "+" disc, `ListsView` empty-state CTA. **Second pass (finish-everywhere):** removed `LibraryView`'s `.toolbarBackground` (nav bar now glass), grocery add bar `.regularMaterial` + `PhotoCarouselView` keyboard bar `.thinMaterial` → `.glassEffect(.regular, in: Rectangle())`, CookMode timer pill `.buttonStyle(.lifted)`→`.plain`, and the cook-pills bar (`CookingPillsBar`) wrapped in `GlassEffectContainer(spacing:)`. **Compiles** — confirmed on Xcode 26 / iOS 26 simulator (the "needs a build to confirm" caveat is resolved; visual verification on device is still open). Since then: the grocery add bar also uses `GlassEffectContainer`, and `SharedListToast` uses `.glassEffect(.regular, in: RoundedRectangle(...))`, so `CookingPillsBar` is no longer the only container in the repo.
- **Still deferred (scroll-target risk — needs build + device):** `GlassEffectContainer` around the horizontal filter chip strips (`LibraryView` / `CategoryFilterStrip`) and the `ConversionsView` unit menus. Skipped because a container between a `ScrollView` and its `.scrollTargetLayout()` content can break scroll snapping — verify on device before wrapping.
- **Device-verification checklist:** `md_files/liquid-glass-adoption.md` (regenerated 2026-06-26 — 14 items, incl. the new grocery surfaces + the sage `AppColor.success` "All set"/"Swap:" contrast risk). NOTE: `CookbookHeader` no longer uses `.regularMaterial` (it's now a plain outlined title on the system nav-bar glass) — the old "CookbookHeader's `.regularMaterial`" review note is obsolete.

**AASA** (`cloudflare-pages/.well-known/apple-app-site-association`): `GYFN949Q5E.com.llamascookbook.app` against `/r/*`.

---

## Llama Pro

Three tiers: `.none` (free) / `.monthly` (crown) / `.yearly` (crown + sunglasses). `isPro = plan != .none`.

Product IDs: `com.llamascookbook.app.pro.monthly`, `com.llamascookbook.app.pro.yearly`

**Crown assets by context:**

| Context | Monthly | Yearly |
|---|---|---|
| Generic | `Llama-Pro-Icon-Crown` | `Llama-Pro-Icon-Crown-Sunglasses` |
| Friends | `Llama-Pro-Icon-Friends-Crown` | `Llama-Pro-Icon-Friends-Crown-Sunglasses` |
| Profile | `Llama-Pro-Icon-Profile-Crown` | `Llama-Pro-Icon-Profile-Crown-Sunglasses` |

**Implementation rules:**
- Use `LlamaLogoOrCrown(size:accent:crownAsset:)` for `LlamaLogo` replacements (handles `plan` internally)
- Named-image call sites: `Image(proStore.plan == .yearly ? "X-Sunglasses" : proStore.isPro ? "X-Crown" : "X")`
- Tab bar Pro icons must use `proTabIcon(named:)` in `RootView` — crown assets are ~96–140pt; UIKit can't reliably downscale to ~26pt tab slot
- `PaywallView` dismisses on `.onChange(of: proStore.plan)`, not `isPro` — required for monthly→yearly upgrade path
- `PaywallView.task` calls `checkCurrentEntitlements()` before loading products
- Never show a plan card for the plan the user already holds; yearly users never open the paywall
- **Manage Subscription** — shown in ProfileView's settings sheet only when `proStore.isPro`. Calls `AppStore.showManageSubscriptions(in:)` (StoreKit 2) — no custom UI needed. `ProfileView` preview must inject `proStore` via `.environment(proStore)`

---

## UX Rules

- **Back buttons**: `.navigationBarBackButtonHidden(true)` + `.enableSwipeBack()`. Editor intentionally omits `.enableSwipeBack()` (data-loss risk). `.enableSwipeBack()` re-pins the nav controller's `interactivePopGestureRecognizer.delegate` on `viewWillAppear` (not just on `didMove`) and allows simultaneous recognition with other gestures, so horizontal chip strips / card transitions near the left edge don't swallow the edge pan
- **Photo strip** (`RecipeDetailView`): fixed 84pt row — 0 → Add only; 1 → photo + Add; 2 → 2 photos + Add; 3+ → 2 photos + "+N more" chip. No `ScrollView`
- **Favorited thumbnails**: `HeartShape()` clip for all `recipe.favorite == true` — no separate heart glyph next to title
- **Tab bar**: do not apply `.accentTextOutline()` directly — UIKit strips SwiftUI modifiers from `.tabItem`. The UIKit equivalent (`NSShadow` via `titleTextAttributes[.shadow]`) is configured by `RootView.configureTabBarAppearance` and is **always-on** as of 2026-05-25 (`glow: true` default + all three call sites hardcoded), so tab labels always carry the soft halo against the LG glass strip
- **`.accentTextOutline()`** (`Theme/AccentTextOutline.swift`): 4× 0.4pt shadows at 0.22 opacity. Applied to accent-tinted glyphs that need to lift off their surface. Surfaces using it (as of 2026-05-25): cookbook header title, recipe-card titles, recipe-detail title, ingredient quantity + unit, cook-mode running-timer pill labels + digits, cook-mode large-timer 44pt digits, friend names. Filter chip labels deliberately do NOT use it — they now use `.glassEffect(.regular, in: Capsule())` for the LG capsule look (halo at 13pt was too muddy). `AppColor.onAccent` glyphs only use it on glass surfaces where the dark shadow still reads behind cream text
- **Duplicate title import**: always show alert via `nextAvailableTitle(base:)` with `Title (N)` — never silently rename
- **Friends empty state threshold**: `isBelowSocialThreshold = friends.count < 3` (seed counts). CTA visible until 2 real friends added
- **Presence dot**: filled+pulsing when `cookingStartedAt` < 6h; hollow when idle
- **Social copy**: "shared", "appears in Friends", "unlisted" — never "private to friends"
- **`LibraryView` profile button**: `.disabled(editor.active != nil)` — explicit, not a silent no-op
- **Processing-llama overlay (any operation expected to take >1–2 s)**: show `LlamaProgressIndicator(size: 96, accent: appearance.accentColor)` + "Asking the llama…" caption on `AppColor.surface` rounded card over a `Color.black.opacity(0.35)` scrim, gated behind a **1 s debounce**. Pattern: a `Task.sleep(for: .seconds(1))` task that flips an `@State showOverlay` only if the operation is still pending; cancel it on completion and in `.onDisappear`. Fast ops (sub-second JSON-LD parses, oEmbed fetches) never flash the modal; multi-second ops (IG mp4 + transcription, Sonnet streaming, etc.) sit behind it for the duration. Reference impls: `ImportFromTextLinkView.fetchingOverlay` (URL fetch path), `PhotoImportPreviewView.llamaProcessingCard` (streaming photo import with 4 s skeleton-reveal cap layered on top). Do NOT replace tiny inline button spinners — those are for sub-second ops where a full-sheet modal would feel heavier than the wait. The bar: if the user could plausibly think "is it stuck?", show the llama.

---

## Testing

**JavaScript (Cloudflare)** — run from `cloudflare-pages/`: `npm test` (Vitest v3, Node ≥ 20). **115 tests across 4 files** as of 2026-08-09.
- `test/quota.test.js` (39) — quota constants, timezone helpers, cap arithmetic, `deriveAppAccountToken`
- `test/moderation.test.js` (29) — the word list + normalizer mirror of `ContentModeration`
- `test/grocery.test.js` (29) — aisle taxonomy, `parseGroceryRecord`, grouping, plain-text render
- `test/list-page.test.js` (18) — `/list/<id>` HTML: escaping, moderation, title-casing, Smart App Banner id, og/canonical tags, a11y, `relativeTime`
- Shared module: `lib/quota.js` — single source for `FREE_CAP`, `PRO_CAP`, `getLocalYYYYMM`, `nextMonthResetUTC`, `deriveAppAccountToken`; never re-inline these

**Swift (iOS)** — `LlamasCookbookNativeTests` target in `project.yml`; ⌘U in Xcode, or:

```sh
cd ios-native && xcodegen generate && xcodebuild \
  -project LlamasCookbookNative.xcodeproj -scheme LlamasCookbookNative \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Note the scheme is `LlamasCookbookNative` (not `LlamasCookbook`). **216 tests**, all green on a local Xcode 26 run 2026-08-18.

Test files in `ios-native/Tests/LlamasCookbookTests/`:

| File | Covers |
|---|---|
| `LlamaProStoreTests.swift` | `Plan.isPro`, `displayLabel`, `appAccountToken` UUID bits |
| `QuotaSnapshotTests.swift` | `isPro`, `isMonthlyExhausted`, `resetDateFormatted` |
| `QuantityTests.swift` | parse/format/scale/combine, `ClockFormat.mmss`, `StringCase` |
| `SourdoughCalculatorTests.swift` | 10-row table, ratio invariants, sum==total |
| `FormattersTests.swift` | `shortMonthDay`, `date` (.medium) |
| `StringExtensionsTests.swift` | `Optional<String>.trimmedIfNonEmpty` |
| `SeedFriendTests.swift` | sentinel, `isSeed`, profile fields (no `loadPayload()`) |
| `RecipeImporterTests.swift` | `cleanTitle`, `mergeOrphanDurationSteps` |
| `ContentModerationTests.swift` | whole-token matching, leetspeak/diacritic normalization, culinary allowlist |
| `InstagramExtractorTests.swift` | inline-JSON / `og:*` extraction shapes |
| `LaunchStateTests.swift` | first-launch / seed gating |
| `GroceryListTests.swift` | `toBuyCount`/`isAllSet`/`isOpen`, availability-note encode/decode, **`slotsNeedingReseed`** (the re-sync invariant) |
| `GroceryKnowledgeTests.swift` | aisle classification incl. plural matching + brand keywords |
| `StoreProfilesTests.swift` | custom walk order: persistence, stale-profile healing, permutation completeness |
| `PushLocalizationTests.swift` | **both push bodies resolve from the bundle** (the `.lproj` regression guard), positional slots, category/action identifiers, create-vs-update subscription split, `IncomingShare.headline` |

Not tested by design: network calls, CloudKit ops, StoreKit purchase flow, SwiftUI views — integration concerns only. Where a CloudKit path has a decision worth locking (e.g. which slots a re-sync rewrites), extract it as a pure function and test THAT rather than the I/O around it.

**SwiftData test-container trap:** the test host app already builds the full-schema `ModelContainer` at launch, and SwiftData traps on a second container over the same `@Model` types in-process. Model tests therefore use un-inserted instances and exercise pure computed properties — do not add a `ModelContainer` to a test.

---

## Open Work

**App status: live on the App Store. Current version shipping: v1.1.2 (2026-06-08). `MARKETING_VERSION` in `project.yml` is 1.2.0, unreleased — the Grocery Lists TestFlight build.**

**Blocking v1.2.0 — one real two-device run against Production.** Everything below is code-complete and green in CI/simulator (re-confirmed 2026-08-18: 216 Swift + 115 JS tests pass, no code drift since 2026-08-09), but none of it can be proven from a build machine:
- Check-off syncs both ways, and fast enough (the `.changedKeys` blind write is the one change with no simulator coverage — it falls back safely, but verify it takes the fast path).
- First share produces the personalized banner with working View List / Close, and the tap lands on the right list.
- The in-app toast fires exactly once per new share (not on a fresh install's backlog).
- `!` produces a push on the owner's phone reading as a sentence, not `GROCERY_OOS_ALERT_BODY`.
- **Existing installs must launch once** after this build before any of the new pushes apply — `registeredForKey` v4 → v5 re-registration happens at launch.

Before archiving: `xcodegen generate` then `agvtool new-version -all $(date -u +%s)` — regeneration resets `CURRENT_PROJECT_VERSION` to 1, and ASC rejects a duplicate/lower build number.

Carry-forward from launch (still unverified on real devices):
- Verify Universal Links on real devices
- Verify Liquid Glass adoption on real devices — checklist in `md_files/liquid-glass-adoption.md` (sheets, custom back chevrons, accent-text-outline legibility, CookingPillsOverlay contrast)

Known gaps in shared grocery lists (documented, not blockers):
- **Substitutions are display-only** — the `?` helper's swap picker was removed 2026-06-29, so nothing in the app or the read-only web page can SET `GroceryItem.substitution`. The parse/sync/render path is intact and the CloudKit `note` format still carries `sub:<text>`. Restore a picker or strip the plumbing.
- **The web list page has no in-app entry point** — `/list/<recordName>` is built, tested, CSP-hardened and moderation-screened, but nothing generates the URL (only `/r/<id>` recipe links exist). Needs a "Copy link" affordance to be reachable.
- **The 40-item shared cap is silent** — rows past `maxSharedItems` get `shareIndex = nil` and never sync, with no warning to the owner.
- **`functions/r/[id].js` has the Smart App Banner bug** the list page just fixed: `app-id=com.llamascookbook.app` should be the numeric ASC id `6762527184`, or Safari drops the banner.

Accepted limitations (documented, not blockers):
- **Server-side `Friendship(userA,userB)` uniqueness** — currently client-side dedup only (`CloudKitFriendship.swift` ll. 65–67, 148–154, 218–221 explicitly guard duplicate sends and dedupe symmetric reads). Race window between two devices is sub-second; collision produces a benign duplicate row that the next refresh's defensive dedup hides. Acceptable for initial launch scale; revisit if abuse appears or scale grows. Real fix would require a CF Worker write-proxy with CAS — meaningful new architecture, not a one-line patch.
- **Account-deletion cascade** — `UserAccount.deleteAccount()` cascades through `deleteAuthoredShares` → `UserProfileMirror.deleteOnAccountDeletion` → `deleteAllFriendships` → `deleteAllPublishedRecipes` → `deleteAllRecipeImports` → `CloudKitSubscriptions.unregisterAll`, with `CloudPendingDeleteQueue` providing persistent retry across launches for the 5 record types. The subscription unregister is best-effort (orphaned subscriptions are cheap server-side state CloudKit GCs; APNs token rotates on reinstall). Meets App Store Review Guideline 5.1.1(v).

Recently resolved (2026-08-09 shared-grocery-list hardening):
- **CloudKit schema verified, not missing** — `GroceryListShare` AND `GroceryListAlert` are both deployed in Development and Production with the right queryable indexes and all 80 slot fields. Earlier suspicion that the feature was blocked on schema was wrong; it had been deployed through the Console. What WAS wrong: the checked-in `.ckdb` granted `WRITE` to `_world`, so running the deploy script would have downgraded a live container to world-writable. Fragments now exported verbatim from Production, and the script verifies both types after import.
- **Out-of-stock push rendered as a raw key** — `Localizable.strings` was bundled at the app root instead of `en.lproj`, so it shipped but was invisible to iOS string lookup and the loc-key had no fallback. Moved to `Resources/Localizations/en.lproj/`; `PushLocalizationTests` guards it.
- **"Shared with you" banner was suppressed for recipients** — notification permission was only requested after sharing a list yourself or opening a shared list, neither of which a pure recipient has done, so the push announcing the list was the one being dropped. Now also requested from `ListsView.task`.
- **First-share push is personalized + actionable** — recipient stream split into creation-only and update-only subscriptions (a CKSubscription's body is fixed at save time). New body names the friend and the list; `GROCERY_SHARE_NEW` category adds View List / Close; tap routes via the new `llamascookbook://list/<recordName>` deep link. `registeredForKey` v4 → v5.
- **In-app shared-list toast** — `SharedListToast` at the app root; open or dismiss, auto-clears after 6 s, and only announces shares that arrive after the first reconcile.
- **Owner structure syncs no longer clobber live check-offs** — `upsertShare` now diffs server vs incoming `itemsJSON` and rewrites only slots whose occupant changed; also fixed a new item inheriting the previous occupant's out-of-stock note.
- **Check-off latency** — blind single-round-trip `.changedKeys` write at `.userInitiated` QoS (was fetch-then-save), visible list refreshed ahead of the full reconcile on push, detail poll 8 s → 3 s.
- **`Sources/Views/Lists/` split** — `GroceryListDetailView` 837 → 516 lines; row, celebration, and chrome extracted.
- **Shared-list web page** — valid markup (a `<div>` was nested in a `<span>`), title-cased names matching the iOS row, "Shared by X · updated N min ago", green check matching the app, dark-mode-correct "all set" pill, og:image/og:url/canonical/theme-color, a11y labels, and the Smart App Banner fixed to the numeric ASC id.

Recently resolved (2026-06-08 v1.1.2):
- **Friend requests UI** — `FriendsTabView` now shows a `requestsSection` compact card above the friend grid whenever `friendsStore.incomingRequests` or `friendsStore.outgoingRequestProfiles` are non-empty. Incoming rows have deny/accept buttons; outgoing rows show a "Sent" clock badge + cancel. Animates in/out via `.spring(response:0.4, dampingFraction:0.85)`.
- **ProfileView accent cascade** — `AppearanceSettings` extended with `ProfileTransitionStage` (6 stages: header/colorNudge/nameCard/lastCooked/requests/friendsList), `friendLetterCascadeToken`, `categoryCascadeToken`, and timing constants `profileFriendsListFlipDelay (0.33)` / `categoriesFlipDelay (0.14)` / `categoryChipGlowStagger (0.025)`. ProfileView's llama, ring, nav icons, name, and friends list now all retint top → bottom in the cascade; category chips advance left → right.
- **Liquid Glass inactive chips** — `CategoryFilterStrip` inactive pills now use `.glassEffect(.regular, in: Capsule())` via `ChipBackground` ViewModifier (matches `LibraryView.ChipBackground`). Active pills retain solid accent fill.
- **Manage Subscription button** — added to ProfileView settings sheet for Pro users; calls `AppStore.showManageSubscriptions(in:)` (StoreKit 2). `import StoreKit` added to `ProfileView.swift`; `proStore` injected into preview via `.environment(proStore)`.
- **Version bump** — `MARKETING_VERSION` 1.1.1 → 1.1.2 in `project.yml`.

Recently resolved (2026-05-29 post-launch cleanup):
- **Demo mode removed** — `DemoMode.swift` deleted; all call sites in `UserAccount`, `FriendsStore`, `LlamaProStore`, `RecipeAIParser`, `ProfileView`, `RecipeDetailView`, `FriendLibraryView`, `FriendRecipeDetailView` cleaned up. Unused `@Environment(\.modelContext)` in `ProfileView` also removed. Ships in v1.0.1.

Recently resolved (2026-05-25 Instagram import polish):
- **IG confidence gate (title + ingredients; steps optional)** — `RecipeURLImporter.fetchInstagram` returns `.full` when AI parse lands a title AND at least one ingredient; steps are optional because IG reels routinely caption ingredients while narrating prep only in audio. Empty-steps `.full` outcomes get a heads-up `.info` banner ("Got the title and ingredients — I couldn't pull steps…") in `ImportFromTextLinkView` so the user knows to add them in the editor. Drafts missing title OR ingredients route to `Outcome.insufficientForImport(enrichment:hint:)` which renders as a "Write it down myself" capsule that hands the enrichment to `EditorCoordinator.startNew(seed:)` — sheet content swaps in-place to a near-empty `RecipeEditorView` with hero photo + source URL + `@creator` summary pre-filled. Earlier strict bar required all three (title + ingredients + steps) and was rejecting useful caption-only saves; relaxed 2026-05-25 after a real Cheese Danish reel that had ingredients in the caption but no extractable steps. AI parser's NEVER FABRICATE rule keeps empty-steps honest — never papered over with placeholder steps.
- **Clean hero photo, three-tier fallback** — IG bakes a white play triangle into `og:image` for any video post. `InstagramExtractor.extractFirstFrame(from:)` now retries 5 candidate timestamps (1.0/0.5/2.0/0.1/0.0 s) with **infinite `requestedTimeTolerance`** (snap to nearest keyframe) — the earlier strict-tolerance-at-t=0.1s setup was failing silently on real reels and dumping users into the play-overlay'd og:image. New `Extraction.carouselPhotoURLs` parses `edge_sidecar_to_children` from inline JSON to grab non-video slide URLs for carousels (which also get the play-overlay'd og:image when any slide is a video). Final fallback chain: mp4 first-frame → non-video carousel slide → og:image. All three candidates fire as parallel `Task.detached` so the fallback is hot-cached.
- **Parallel mp4 + thumbnail + AI parse** — mp4 download, thumbnail download, carousel-slide download, AI parse, and first-frame extraction are now structured-concurrency parallel via `async let` + `Task.detached`. Stage 1 runs AI parse alongside hero-photo resolution; stage 2 runs frame-extract alongside transcription on the shared mp4 file. Shaves 1–3 s off perceived wall-clock vs. the prior serial chain.
- **Processing-llama overlay (1 s debounce)** — `ImportFromTextLinkView` now shows a centered `LlamaProgressIndicator` + "Asking the llama…" card during URL fetches, debounced 1 s so fast blog/Pinterest fetches never flash the modal while multi-second IG fetches stay covered. Documented as the canonical >1–2 s pattern in UX Rules.
- **`os.Logger` diagnostics** — `InstagramExtractor` + `RecipeURLImporter.Instagram` log subsystems trace videoURL / thumbnailURL / carousel-slide presence, which fallback tier supplied the final hero photo, the first 300 chars of text sent to the AI parser per stage, and any hallucination-guard rejection (with the bogus title + source byte count). Filter Console.app on `com.llamascookbook.app` subsystem when triaging "still shows play overlay" or "got wrong recipe" reports.
- **AI hallucination guard (IG)** — `isAIDraftGroundedInSource` rejects drafts whose title has zero significant word overlap with the bytes sent to Haiku, so sparse-input fabrications (real case: Cheese Danish reel → "Greek Pasta Salad" full recipe from Haiku training data) get caught and routed to the "Write it down myself" handoff instead of being shown as a confident result. Title-only check (ingredients routinely paraphrased through canonical units, would false-positive).

Recently resolved (2026-05-24 audit pass 2):
- **Credentials hygiene** — local `credentials/` directory deleted; ASC API key rotated; new secrets pushed to GitHub Actions
- **Planning-doc relocation** — 29 design/audit/handoff `.md` files moved from repo root into `md_files/` (gitignored); only `AGENTS.md` + `README.md` remain at root
- **`.gitignore` hardening** — added `.dev.vars`, `.wrangler/`, `md_files/`, `.idea/`, `.vscode/`, `*.swp`, `*~`, `*.log`

Recently resolved (2026-05-24 audit pass 1):
- Privacy manifest populated (`UserID`, `PhotosOrVideos`, `OtherUserContent` with linked/tracking/purposes)
- Anthropic key migration to CF Worker complete — no key in Swift binary or Keychain
- `CookModeView` `.fullScreenCover` (TimerReadyOverlay) and `.sheet` (RunningTimerSheet) now re-inject `AppearanceSettings` (iOS 26 environment-drop fix)
- `ImportersListSheet` now uses canonical `UserProfileSnapshot.resolvedAccent` with `AppColor.accent` fallback (was falling back to user's accent)
- `ImportFromPhotoView` PhotosPicker decode moved to `Task.detached(.userInitiated)` — HEIC decode no longer blocks main actor during multi-photo selection
- `PhotoCarouselView.commit` routes through `Optional(draft).trimmedIfNonEmpty`
- `SeedFriend.loadPayload()` no longer calls `fatalError` — logs via `os.Logger` and returns an empty payload if `SeedRecipes.json` is missing/malformed, so the app stays usable
