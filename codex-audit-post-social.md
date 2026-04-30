# Codex Audit: Post-Social Update

Date: 2026-04-30

Scope: static audit of the app after the friends/social rollout, with emphasis on code cleanliness, DRY/reusability, consistency, efficiency, security, privacy, and user risk. This is intended as a handoff for another agent to clarify product/security decisions and implement fixes.

## Executive Summary

The app is in a strong place overall: the codebase has clear product intent, cohesive SwiftUI styling, good local/offline foundations, thoughtful import/share guardrails, and a lot of useful inline rationale. The recent social work is well organized for an MVP, but the current architecture has one major product/security mismatch:

**Friend-only social data is not currently enforceably private.** Friend libraries, published recipes, social graph records, profile/presence fields, and import audit records live in the CloudKit public database and are protected primarily by client-side UI flow and assumptions. That may be acceptable if the app explicitly treats shared cookbook data as public/unlisted. It is not acceptable if the product promise is "only accepted friends can see this."

The privacy contract is now decided as public/unlisted sharing. The remaining work is making sure copy, privacy policy, App Store labels, and docs consistently describe that model.

## Privacy Decision

Decision from Lorenzo on 2026-04-30: use **Option A, public/unlisted sharing**.

Friend cookbooks and recipe-share records are intentionally not strict friend-private storage. Accepted-friend UI controls discovery inside the app, but recipe links must remain readable by non-friend recipients through Messages/Universal Links. The implementation should therefore avoid copy that says or implies "only friends can see this," and privacy policy/App Store labels should describe social/shared cookbook data as data stored for sharing.

## Touchup Progress

Started on 2026-04-30:

- Removed tracked local Claude settings from the Git index and added `.claude/settings.local.json` to `.gitignore`.
- Hardened Cloudflare share preview routes with exact share-token validation, `nosniff`, referrer policy, CSP, image MIME allowlisting, and image size checks.
- Increased newly generated CloudKit recipe share/import record IDs from 6 to 12 characters while keeping Cloudflare compatibility for legacy 6-character share links.
- Made friend push observation idempotent so repeated `RootView.task` runs do not register duplicate block observers.
- Added a shared CloudKit cursor-pagination helper and routed friendship, published recipe, and recipe import queries through it.
- Added defensive client-side participant checks for friendship approve/delete flows.
- Added a receive-side total cloud-photo payload cap to reduce memory risk from malformed or hostile public records.
- Documented the public/unlisted social privacy decision and softened the remove-friend copy so it does not imply hard access revocation.

## Docs Reviewed

Root markdown files reviewed during this audit:

- `CLAUDE.md`
- `PROJECT.md`
- `STATE.md`
- `ROADMAP.md`
- `implement-social.md`
- `Implementing-User-Sign-In.md`
- `Recipe-Sharing.md`
- `Share-Extension-Plan.md`
- `Photo-Capability.md`
- `picture-import-implementation.md`
- `Multi-Recipe-Cook-Mode.md`
- `SDK-Update-Plan.md`
- `llama-intro.md`
- `llamas-cookbook-plan.md`
- `README.md`

Important context from the docs:

- The original product vision is a personal, offline-first cookbook, explicitly not a broad social discovery app.
- `implement-social.md` accepts that the MVP public CloudKit database is technically readable/discoverable and says recipes are not treated as sensitive.
- The user request for this audit asks to make sure "what needs to be private is private," so the old MVP assumption should be revisited.
- `ROADMAP.md` still lists required portal/schema steps for push notifications and `RecipeImport` Dev to Prod deployment.
- Several feature docs are ahead of code or slightly drifted from implementation. Treat `CLAUDE.md` plus live code as the practical source of truth.

## Priority Key

- P0: must clarify or fix before making privacy/security promises.
- P1: high risk of user-visible errors, data residue, privacy drift, or scaling failure.
- P2: maintainability, performance, and consistency improvements that reduce future bug risk.
- P3: polish, docs, and low-risk cleanup.

## High Priority Findings

### P0 - Social data is not enforceably friend-private

Evidence:

- `implement-social.md` states the MVP stores friend-visible data in CloudKit public DB and accepts discoverability.
- `ios-native/Sources/Lib/CloudKitPublishedRecipe.swift:218` fetches published recipe summaries by `ownerID`.
- `ios-native/Sources/Lib/CloudKitUserProfile.swift:132` searches public `UserProfile` records.
- `ios-native/Sources/Lib/CloudKitFriendship.swift:129` queries public `Friendship` records.
- `ios-native/Sources/Lib/CloudKitRecipeImport.swift:145` queries public `RecipeImport` records.
- `ios-native/Sources/Views/Friends/FriendRecipeDetailView.swift:595` writes import audit rows fire-and-forget to the same public surface.

Risk:

- A modified client, future bug, broad CloudKit role, or record-name leak could reveal data outside the intended friend UI.
- Friend cookbook contents, imported-from attribution, importer names, profile display names, presence-style fields, and social graph metadata should not be described as private unless access is enforced outside the client.
- This conflicts with the original product promise of a private personal cookbook unless the app clearly scopes the social feature as public/unlisted sharing.

Status:

- Resolved by product decision: public/unlisted sharing is acceptable for this phase.

Recommendation:

1. Make a product decision:
   - Option A: social recipes are public/unlisted cookbook shares. **Chosen 2026-04-30.** Update all user copy, docs, privacy policy, and App Store labels. Avoid "only friends can see" wording.
   - Option B: accepted friends only. Move sensitive social data behind an enforceable boundary: backend-gated access, CloudKit private DB plus `CKShare`, or encrypted per-friend payloads where keys are only available to accepted friends.
2. Do not rely on client-side friendship checks as a privacy boundary.
3. Verify CloudKit Dashboard security roles for `UserProfile`, `Friendship`, `PublishedRecipe`, and `RecipeImport` before shipping wider.

Clarification needed:

- Are recipes, profile/presence fields, friend graph, and import audit rows considered private user data?
- Should publishing be automatic when a user has one friend, or should it be opt-in/per-recipe?
- Is a server component acceptable if true authorization is needed?

### P1 - Public DB mutation authorization needs a real security model

Evidence:

- `ios-native/Sources/Lib/CloudKitFriendship.swift:87` approves a friend request by arbitrary record name.
- `ios-native/Sources/Lib/CloudKitFriendship.swift:104` deletes a friendship by arbitrary record name.
- `ios-native/Sources/Lib/CloudKitFriendship.swift:69` creates random friendship records and leaves duplicate checks to the caller.
- `ios-native/Sources/Lib/CloudKitPublishedRecipe.swift` uses recipe UUIDs as public record names and stores caller-supplied owner fields.

Risk:

- If CloudKit public DB roles allow broad authenticated writes, a modified client may be able to approve, delete, spoof, or overwrite records.
- If roles are restricted to creator writes only, some intended flows may break, such as the recipient approving a requester-created friendship.
- The app currently does not document the required CloudKit security matrix.

Recommendation:

1. Document and verify CloudKit Dashboard roles for every social record type.
2. Add defensive client checks before approve/delete:
   - Current user must be recipient to approve.
   - Current user must be requester or recipient to delete.
   - Current user must match `ownerID` for recipe publish/delete.
3. Treat these checks as defense-in-depth, not true security.
4. For enforceable authorization, put friendship mutations behind a trusted server or use a CloudKit design where platform permissions match the mutation model.

### P1 - Account deletion cascade is best-effort and can leave social records behind

Evidence:

- `ios-native/Sources/App/UserAccount.swift:215` starts account deletion.
- `ios-native/Sources/Lib/CloudKitService.swift:334` has a persistent pending-delete queue for authored recipe share records only.
- `ios-native/Sources/Lib/CloudKitPublishedRecipe.swift:204` best-effort deletes published recipes but ignores query cursor and failure retry.
- `ios-native/Sources/Lib/CloudKitRecipeImport.swift:215` best-effort deletes recipe imports but ignores query cursor and failure retry.
- `ios-native/Sources/Lib/CloudKitFriendship.swift:165` best-effort deletes friendships.
- `ios-native/Sources/Lib/UserProfileMirror.swift` clears local identity/cache during deletion, reducing retry ability after failure.

Risk:

- If the app is offline, interrupted, killed, or CloudKit schema/indexes fail, public profile, friendship, published recipe, and import audit records can remain after the user believes the account is deleted.
- Because local identity is wiped, later retries may not know which public records to clean.

Recommendation:

1. Build a unified CloudKit deletion outbox for account deletion.
2. Persist the user record name and target record types before wiping local identity.
3. Retry until each record type is confirmed deleted or `unknownItem`.
4. Include `UserProfile`, `Friendship`, `PublishedRecipe`, `RecipeImport`, and existing `RecipeShare` records.
5. Surface deletion as "queued/finishing cleanup" if network is unavailable, rather than silently dropping the cleanup job.

### P1 - Friendship duplicate and race handling is incomplete

Evidence:

- `ios-native/Sources/Lib/CloudKitFriendship.swift:69` creates request records with a random record name.
- `ios-native/Sources/App/FriendsStore.swift:172` checks local cache before sending, but there is no server-side deterministic uniqueness.
- The spec in `implement-social.md` expected a quick CloudKit lookup before write.

Risk:

- Two users can send requests at the same time.
- One user can send from two devices before refresh.
- Duplicate rows can produce inconsistent pending/accepted UI and removal behavior.

Recommendation:

1. Use a deterministic friendship record name from the sorted pair of user record names, for example a SHA-256-derived safe token.
2. Store requester and recipient fields separately for directionality.
3. On create, fetch existing first and handle `serverRecordChanged`/`unknownItem` deterministically.
4. If a server is introduced for authorization, put dedupe there instead.

### P1 - CloudKit query pagination is missing in several user-facing paths

Evidence:

- `ios-native/Sources/Lib/CloudKitFriendship.swift:129` uses `records(matching:)` and ignores the cursor.
- `ios-native/Sources/Lib/CloudKitPublishedRecipe.swift:204` and `:222` ignore query cursors.
- `ios-native/Sources/Lib/CloudKitRecipeImport.swift:145`, `:177`, and `:215` ignore query cursors.

Risk:

- Large friend lists, published cookbooks, import counts, and deletion cascades silently stop at the first CloudKit page.
- Account deletion can leave records behind even when online.
- Import counters can be stale or wrong.

Recommendation:

1. Add one shared CloudKit query helper that follows cursors until exhaustion.
2. Use it for friend refresh, cookbook summaries, import counts, import lists, and deletion cascades.
3. Add tests or a manual validation case with 101+ records for each paginated path.

## Security and Privacy Findings

### P1 - Privacy labels and user-facing privacy copy need review

Evidence:

- `ios-native/Resources/PrivacyInfo.xcprivacy:24` declares no collected data types.
- `Implementing-User-Sign-In.md` says App Store Connect privacy labels should declare identifiers/contact info/user content.
- Social CloudKit records include display name, stable user identifiers, recipe content/photos, social graph records, import audit rows, and activity/presence-style fields.
- Cloudflare preview routes can read public share records to render web previews.

Risk:

- App Store privacy labels and in-app/privacy-policy copy may understate what is stored in the developer CloudKit container and exposed through the sharing/social stack.
- Users may believe all cookbook/social data is local/private when some data is mirrored publicly for friends and shares.

Recommendation:

1. Separate two concepts:
   - `PrivacyInfo.xcprivacy` required reason/data collection manifest.
   - App Store Connect privacy labels and user-facing privacy policy.
2. Reconcile both against actual data flows.
3. Explicitly document what data leaves the device for:
   - Sign in/profile.
   - Friend discovery.
   - Friend cookbook publishing.
   - Recipe import attribution.
   - Cloud share/web preview.
4. Keep Sign in with Apple minimization. It currently requests full name only, not email, which is good.

### P1 - Cloudflare image proxy should harden upstream content handling

Evidence:

- `cloudflare-pages/functions/img/[id].js:24` accepts record names by regex.
- `cloudflare-pages/functions/img/[id].js:46` fetches a CloudKit CDN URL.
- `cloudflare-pages/functions/img/[id].js:58` forwards upstream `content-type`.
- `cloudflare-pages/functions/img/[id].js:64` streams the response body.
- `cloudflare-pages/functions/r/[id].js:69` serves HTML preview with basic content type and cache headers.

Risk:

- If a public CloudKit record points to unexpected content, `/img/<id>` can proxy non-image bytes under the app's preview origin.
- Missing `X-Content-Type-Options: nosniff` and content-type whitelisting increase browser risk.

Recommendation:

1. Enforce an exact app token format for record names. Align with generated token length and alphabet.
2. Whitelist image MIME types only, such as `image/jpeg`, `image/png`, `image/webp`, and `image/heic` if supported.
3. Reject or redirect on missing/large `content-length`.
4. Add `X-Content-Type-Options: nosniff` to image and HTML responses.
5. Add conservative security headers in `_headers`, including CSP for the preview page if compatible.

### P2 - Short public share IDs are not strong unlisted tokens

Evidence:

- `ios-native/Sources/Lib/CloudKitService.swift:68` sets `recordIDLength = 6`.
- `ios-native/Sources/Lib/CloudKitService.swift:430` generates IDs from the configured length.
- Cloudflare preview routes accept 4 to 32 uppercase alphanumeric chars.

Risk:

- Six base32-ish characters are fine for collision avoidance at small scale, but weak for unlisted privacy.
- If share links are framed as private-by-obscurity, the token length should be longer.

Recommendation:

1. If share links are public/unlisted, document that.
2. If share links are expected to be hard to guess, move to 12 to 16 chars minimum, or a 128-bit base64url token.
3. Align Cloudflare route regex with the actual generated alphabet and length.
4. Decide whether old 6-char links need compatibility support.

### P2 - Local repo hygiene: tracked `.claude/settings.local.json`

Evidence:

- `.claude/settings.local.json` is tracked.
- It contains local absolute paths and broad command permissions including GitHub secret operations.
- Signing credentials themselves appear ignored, which is good.

Risk:

- Local machine paths and broad tool permissions should not be shared as repository state.
- Future commits may accidentally widen local automation permissions.

Recommendation:

1. Add `.claude/settings.local.json` to `.gitignore`.
2. Remove it from the Git index with `git rm --cached .claude/settings.local.json` while keeping the local file.
3. Commit a safe template only if the team needs one, for example `.claude/settings.example.json`.

## Performance and Efficiency Findings

### P1 - Friends refresh is N+1 and mostly sequential

Evidence:

- `ios-native/Sources/App/FriendsStore.swift:79` refreshes friend state.
- Accepted, incoming, and outgoing friend records are hydrated by fetching user profiles one by one.
- Per-profile failures are largely swallowed.

Risk:

- Friend list refresh will become slow and quota-heavy as social usage grows.
- Users may see incomplete friend lists without any explanation.

Recommendation:

1. Batch profile fetches by record ID using CloudKit batch APIs or bounded concurrency.
2. Cache profile snapshots with freshness metadata.
3. Record soft errors for debug UI/logs so "partial refresh" is observable.
4. Keep UI resilient, but avoid silent failure as the only behavior.

### P1 - Cloud photo fetch path can create high memory pressure

Evidence:

- `ios-native/Sources/Lib/CloudKitService.swift:242` allows 10 MB per cloud photo.
- Share/friend recipe cloud fetch paths can load up to 20 photos, then base64-inflate them into share envelopes.
- `CloudKitPublishedRecipe` follows a similar photo asset reinjection pattern for friend recipe details.

Risk:

- 20 x 10 MB assets can peak around or above 200 MB before base64 overhead and object duplication.
- Friend recipe detail or import could become a crash vector on older devices or malicious/malformed public records.

Recommendation:

1. Add a total photo payload cap per recipe, not just per-photo cap.
2. Lower per-photo cap for network-delivered assets unless full-resolution originals are truly needed.
3. Avoid base64 reinjection for CloudKit-only paths. Carry asset bytes as sidecar data into the materializer.
4. Add a manual stress test with max photo count and over-limit assets.

### P2 - NotificationCenter observer can be registered repeatedly

Evidence:

- `ios-native/Sources/App/FriendsStore.swift:286` registers remote push observers.
- `ios-native/Sources/App/FriendsStore.swift:292` uses block-based `NotificationCenter.default.addObserver`.
- The observer token is not stored or removed.

Risk:

- If `observeRemotePushes()` is called more than once over the app lifecycle, refreshes can duplicate.
- Block observers are retained by NotificationCenter until removed.

Recommendation:

1. Store the observer token in `FriendsStore`.
2. Guard with `isObservingPushes`.
3. Remove the observer in `deinit`, or use a Combine/async sequence pattern owned by a view lifecycle.

## DRY, Consistency, and Maintainability Findings

### P2 - Large SwiftUI files should be split by stable feature boundaries

Evidence from line count:

- `ios-native/Sources/Views/Detail/RecipeDetailView.swift`: 1482 lines
- `ios-native/Sources/Views/Cook/CookModeView.swift`: 1197 lines
- `ios-native/Sources/Lib/RecipeImporter.swift`: 1188 lines
- `ios-native/Sources/Lib/RecipeShare.swift`: 819 lines
- `ios-native/Sources/App/RootView.swift`: 787 lines
- `ios-native/Sources/Views/Components/PhotoCarouselView.swift`: 766 lines
- `ios-native/Sources/Views/Editor/RecipeEditorView.swift`: 716 lines
- `ios-native/Sources/Views/Profile/ProfileView.swift`: 661 lines
- `ios-native/Sources/Views/Library/LibraryView.swift`: 597 lines
- `ios-native/Sources/Views/Friends/FriendRecipeDetailView.swift`: 586 lines

Risk:

- More state and side effects are concentrated in a few files than necessary.
- SwiftUI body invalidation and accidental dependencies become harder to reason about.
- Future social/detail/import changes are more likely to duplicate rendering or subtly diverge.

Recommendation:

1. Prioritize splitting:
   - `RecipeDetailView`
   - `FriendRecipeDetailView`
   - `ProfileView`
   - `RootView`
2. Prefer small dedicated `View` types with explicit input models over many computed `some View` helpers.
3. Move async side effects and data shaping out of view bodies where practical.
4. Keep splits behavior-preserving and avoid broad restyling in the same PR.

### P2 - Friend recipe detail duplicates import/share rendering logic

Evidence:

- `ios-native/Sources/Views/Friends/FriendRecipeDetailView.swift` comments repeatedly mirror `RecipeImportPreviewView`.
- Ingredient formatting and read-only recipe section rendering exist in multiple places.

Risk:

- Share import preview, friend recipe detail, photo import preview, and future web/import surfaces can drift in layout, formatting, and import behavior.

Recommendation:

1. Extract a shared read-only recipe renderer for share envelopes, for example `RecipeEnvelopeRenderer` or `SharedRecipePreviewContent`.
2. Extract ingredient formatting into a shared helper used by:
   - `RecipeImportPreviewView`
   - `FriendRecipeDetailView`
   - `PhotoImportPreviewView`
   - Any future cloud/share preview surfaces.
3. Keep toolbar/navigation differences in the host screens.

### P2 - CloudKit asset upload/fetch code should be centralized

Evidence:

- Recipe share upload and published recipe upload both flatten recipe photos into CKAsset slots.
- Fetch paths both rehydrate assets and inject data back into envelope-like structures.

Risk:

- Future changes to caps, temp-file cleanup, image slot conventions, or stripping inline data must be made in multiple places.
- Security/memory fixes are easier to miss in one path.

Recommendation:

1. Extract a shared `CloudRecipeAssetPayload` or `CloudKitRecipeAssetBundle`.
2. Centralize:
   - Photo slot naming.
   - Temp-file creation and cleanup.
   - Per-photo and total payload caps.
   - Stripped-envelope creation.
   - Asset rehydration.
3. Have both direct share and friend-library publishing use the same helper.

### P2 - Detached fire-and-forget tasks should be reviewed

Evidence:

- `ios-native/Sources/Views/Friends/FriendRecipeDetailView.swift:595` writes import audit rows in `Task.detached`.
- `ios-native/Sources/App/UserAccount.swift` uses detached tasks for sign-in/profile/deletion cleanup paths.

Risk:

- Detached tasks can outlive view/account state and lose structured cancellation or retry guarantees.
- Some operations should be durable jobs, not best-effort background tasks.

Recommendation:

1. Replace import audit writes with a small persistent outbox if the count/attribution chip matters.
2. Reserve `Task.detached` for work that truly does not depend on current actor/context and can be safely lost.
3. Use structured tasks or service queues for user-visible persistence/mutation.

## Product and Docs Drift

### P1 - Portal/schema blockers can make shipped social behavior silently incomplete

Evidence:

- `ROADMAP.md` lists push notification portal setup and provisioning profile updates as required for friend request notifications.
- `ROADMAP.md` lists `RecipeImport` Dev to Prod schema/index deployment as required.
- `CLAUDE.md` notes schema/portal items still pending.

Risk:

- Friend push notifications may not arrive.
- Import audit writes/count chips can fail or remain stale.
- Users experience inconsistent social behavior even if app code is correct.

Recommendation:

1. Complete Apple portal push capability/profile regeneration before relying on friend notifications.
2. Deploy `RecipeImport` schema/indexes from Development to Production.
3. Add a release checklist item that verifies CloudKit schema and subscriptions in the production container.

### P2 - Social implementation differs from handoff docs in small places

Examples:

- `implement-social.md` says import audit writes should queue offline; code is fire-and-forget.
- Some UI placement/details differ from the doc, such as sheet vs inline popover and toolbar placement.
- `CLAUDE.md` still calls out a temporary cloud-share diagnostic alert/logging that should be removed before broad shipping.

Risk:

- Future agents may implement against stale assumptions.
- Temporary diagnostics can leak noisy user-facing errors.

Recommendation:

1. After fixes, update `CLAUDE.md`, `STATE.md`, `ROADMAP.md`, and `implement-social.md` to match live behavior.
2. Keep `implement-social.md` as historical context if desired, but mark outdated sections.
3. Wrap release diagnostics in debug-only logging or remove them.

## Positive Findings

These are worth preserving:

- The app has a clear product center: personal, offline-first recipe management.
- SwiftData is local-first, with CloudKit sync disabled for the primary recipe store. That keeps the core library independent from social/cloud failures.
- Share/import code includes useful size checks and data minimization. Local cook history is not included in share envelopes.
- Sign in with Apple requests full name only, not email.
- App Group share-extension handoff validates UUID-shaped filenames and caps inbound size.
- User profile mirroring and recipe publishing use debounce patterns to reduce unnecessary CloudKit writes.
- Image processing uses ImageIO thumbnailing and avoids pulling full-size images into the UI path where possible.
- Comments are unusually helpful. Many explain why a shape exists, not just what it does.

## Recommended Implementation Sequence

### Phase 0 - Privacy contract

Decision is now made: public/unlisted sharing. Remaining work:

1. Keep app copy aligned with public/unlisted sharing.
2. Update privacy policy/App Store labels to describe shared/social data.
3. Keep auto-publish-on-first-friend behavior unless product direction changes.
4. Do not introduce backend/CloudKit-share/encryption work unless the product later moves to true friend-private sharing.

### Phase 1 - Security and deletion hardening

1. Verify and document CloudKit public DB roles.
2. Add defensive participant/owner checks to client mutation paths.
3. Add durable account deletion outbox for all public/social record types.
4. Add deterministic friendship dedupe or server-side friendship mutation.
5. Complete CloudKit Production schema/index deployment for `RecipeImport`.

### Phase 2 - Correctness and scaling

1. Add shared CloudKit cursor pagination helper.
2. Replace friend/profile N+1 refresh with batch or bounded-concurrency fetch.
3. Add retry/outbox for `RecipeImport` audit writes if the UI depends on them.
4. Store/remove NotificationCenter observer tokens.

### Phase 3 - DRY and memory cleanup

1. Extract shared CloudKit recipe asset upload/fetch helpers.
2. Add total cloud photo payload caps.
3. Extract shared read-only recipe preview/rendering components.
4. Split largest SwiftUI files along stable feature boundaries.

### Phase 4 - Docs, labels, and release checklist

1. Update App Store privacy labels and privacy policy/copy.
2. Update root docs to match implementation.
3. Remove or debug-gate temporary diagnostics.
4. Add CloudKit schema/role/push verification to release checklist.

## Validation Checklist for the Implementing Agent

Security/privacy:

- Verify CloudKit Dashboard roles for all social record types.
- Attempt friend request approve/delete from wrong participant in a test build or modified local harness.
- Confirm app copy does not promise strict friend-only access while the product uses public/unlisted sharing.
- Confirm account deletion eventually removes profile, friendships, published recipes, import records, and share records after offline/interrupted scenarios.
- Review App Store Connect privacy labels against actual data flows.

Correctness:

- Create 101+ friendships and confirm full friend list loads.
- Create 101+ published recipes and confirm full friend cookbook loads.
- Create 101+ import records and confirm count/list/delete paths work.
- Send simultaneous cross friend requests and confirm one stable friendship state.
- Import the same friend recipe offline and confirm audit outbox behavior.

Performance/memory:

- Load a friend recipe with max photo count and near-cap assets.
- Verify memory does not spike dangerously during detail view and import.
- Confirm friend list refresh remains responsive with a large friend set.

Cloudflare/web:

- Request `/img/<id>` for a valid image record and a non-image/malformed record.
- Confirm non-image content is rejected or redirected.
- Confirm `nosniff` and desired security headers are present.
- Confirm old and new share-token lengths route as intended.

UX/release:

- Verify friend notifications on a real device after push capability/profile work.
- Verify `RecipeImport` counts in the production CloudKit container.
- Walk sign-in, sign-out, account deletion, add friend, accept friend, remove friend, import friend recipe.
- Re-run share extension and cloud share flows after asset helper refactors.

## No Local Build/Test Run

No iOS build or test suite was run as part of this audit. The project docs state this Windows development machine cannot build the iOS app locally; archive/TestFlight validation happens through GitHub Actions/macOS. This audit is based on repo docs plus static code review.
