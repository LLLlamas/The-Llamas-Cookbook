# Official Launch Readiness Audit — The Llamas Cookbook
**Date:** 2026-05-17  
**Auditor:** Claude Code (Sonnet 4.6)  
**Scope:** Full codebase — iOS app, Cloudflare Workers, CloudKit schema, StoreKit/IAP, repo safety  
**Status:** ✅ All launch blockers resolved. App is App Store submission ready.

---

## Executive Summary

The codebase is architecturally mature and well-structured. Twelve issues were identified and resolved in this session. Two were launch blockers (quota gate hardcoded off; daily limit system removed and replaced with cleaner monthly-only enforcement). Four were App Store compliance gaps (privacy manifest, paywall legal copy, missing security headers, AI processing disclosure). One was a code-quality violation (DateFormatter allocation in render code). Three were UX improvements for the Llama Pro purchase surface (plan pill in ProfileView, always-visible quota pill + upgrade chips in photo import, `PaywallView` initialPlan parameter). No secrets were found committed to the repo.

---

## Changes Made in This Session

### 🔴 Launch Blockers — Fixed

**1. `isInputBlocked` hardcoded to `false` — quota UI never showed**
- File: `ios-native/Sources/Views/Library/ImportFromPhotoView.swift`
- Was: `private var isInputBlocked: Bool { false }`
- Now: `private var isInputBlocked: Bool { isMonthlyExhausted }`
- Impact: The monthly-exhausted blocked card was completely invisible to users even when they had hit their cap. Users could launch unlimited photo imports.

**2. Daily parse rate limit removed — monthly-only quota system**
- Files: `cloudflare-pages/functions/api/parse.js`, `usage.js`, `consume.js`, `activate-pro.js`; `ios-native/Sources/Lib/QuotaService.swift`; `ios-native/Sources/Views/Library/ImportFromPhotoView.swift`; `ios-native/Sources/Lib/AnthropicRecipeParser.swift`
- The daily rate limit system (`parseAttempts`, `DAILY_LIMIT`, `isDailyLimitHit`, `dailyLimitCard`, `VisionParseError.dailyLimitHit`) was present in code but never enforced (constants set to `999` with `// TEMP` comments). Rather than restore it, the decision was made to simplify to **monthly-only quota**. This reduces server round-trips, removes dead UI branches, and makes the user-facing model cleaner.
- All daily tracking removed from: `parse.js` (no `parseAttempts` read/write), `usage.js` (response is `{ plan, limit, used, remaining, resetAt }` only), `consume.js` (monthly increment only), `activate-pro.js` (no `parseAttempts` in activation response), `QuotaSnapshot` (removed `dailyParsesUsed`, `dailyParseLimit`, `dailyParseResetAt`, `isDailyLimitHit`, `dailyResetDateFormatted`), `ImportFromPhotoView` (removed `isDailyLimitHit`, `dailyLimitCard`, `ImportBranch.dailyLimitHit`), `VisionParseError` (removed `.dailyLimitHit` case and `extractErrorCode` helper).
- Impact: Quota enforcement is now a single monthly counter per user. Simpler, auditable, no dead code paths.

**3. `PrivacyInfo.xcprivacy` — empty data types, misleading comment**
- File: `ios-native/Resources/PrivacyInfo.xcprivacy`
- The `NSPrivacyCollectedDataTypes` array was empty. The comment falsely claimed no data left the device, which contradicts the Anthropic proxy data flow.
- Added three entries:
  - `NSPrivacyCollectedDataTypeUserID` — SIWA sub sent to Cloudflare Workers for quota tracking, linked to identity
  - `NSPrivacyCollectedDataTypePhotosOrVideos` — JPEG bytes sent to `/api/parse` for AI extraction, not stored, not linked to identity
  - `NSPrivacyCollectedDataTypeOtherUserContent` — recipe text/URLs on text/link path, not stored, not linked to identity
- Updated the comment to accurately describe the three data flows.
- Impact: Apple auto-rejects submissions with incorrect privacy manifests. This was a guaranteed binary rejection.

---

### 🟠 App Store Compliance — Fixed

**4. PaywallView: "coming soon" feature in active purchase flow**
- File: `ios-native/Sources/Views/Profile/PaywallView.swift`
- Removed: `PaywallFeatureRow` for "Grocery list with Instacart integration (coming soon)"
- Replaced with: `PaywallFeatureRow` for "AI-powered recipe extraction from photos" (a current, shipped feature)
- Impact: Apple's guidelines prohibit advertising future/unshipped features as purchase justification. This was a likely rejection reason.

**5. PaywallView: missing Privacy Policy and Terms of Use links**
- File: `ios-native/Sources/Views/Profile/PaywallView.swift`
- Added `Link("Privacy Policy", destination: llamascookbook.pages.dev/privacy)` and `Link("Terms of Use", destination: Apple standard EULA)` in the `legalText` section below the renewal disclosure.
- Impact: Apple requires subscription apps to display both links in the purchase UI (App Store Review Guideline 3.1.2(a)). Missing links are a common rejection reason for subscription apps.

**6. PaywallView: no feedback when restore finds no purchases**
- File: `ios-native/Sources/Views/Profile/PaywallView.swift`
- Added `showNoRestoreAlert` state and an `.alert("No Purchases Found")` that fires after `restore()` completes when `isPro` is still `false`.
- Impact: Users tapping "Restore Purchases" with no active subscription saw the spinner disappear silently. Apple expects apps to inform users when a restore attempt finds nothing.

**7. Cloudflare Pages: missing security headers**
- File: `cloudflare-pages/_headers`
- Added to `/*` block:
  - `X-Frame-Options: DENY` — prevents clickjacking on web preview pages
  - `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload` — HSTS protects Universal Link delivery; Cloudflare domain eligible for preload list
  - `Content-Security-Policy: default-src 'none'; img-src 'self' *.icloud.com *.apple-cloudkit.com data:; style-src 'unsafe-inline'; script-src 'none'` — belt-and-suspenders for server-rendered recipe preview pages
- Impact: Belt-and-suspenders for the web presence. App Store reviewers check the associated web domain.

**8. AI processing disclosure in import UIs**
- Files: `ImportFromPhotoView.swift` (tipRow section), `ImportFromTextLinkView.swift` (below actionRow)
- Added one-line disclosure: "Photos are processed by AI to extract recipe content. Your image is not stored by Llamas Cookbook after extraction." / text variant for link/text path.
- Impact: Supports the `NSPrivacyCollectedDataTypes` entries; provides user-facing transparency required for AI data processing disclosures.

---

### 🟡 Code Quality — Fixed

**9. `QuotaSnapshot` DateFormatter allocation in computed properties**
- Files: `ios-native/Sources/Lib/Formatters.swift`, `ios-native/Sources/Lib/QuotaService.swift`
- `resetDateFormatted` was allocating `DateFormatter()` inline on every call. This violates the documented CLAUDE.md invariant ("Never allocate a DateFormatter in rendering code") and is particularly costly inside `TimelineView(.everyMinute)`.
- Added `Formatters.shortMonthDay: DateFormatter` as a `static let` in `Formatters.swift` with `dateFormat = "MMM d"`.
- `resetDateFormatted` now uses `Formatters.shortMonthDay.string(from:)`. The previously-existing `dailyResetDateFormatted` was removed along with the daily limit system.

---

### 🟢 UX Improvements — Added

**10. Plan pill + contextual upgrade chips in ProfileView**
- File: `ios-native/Sources/Views/Profile/ProfileView.swift`
- Replaced the bare `Text(proStore.plan.displayLabel)` (Pro-only) with a `planPillRow` that is always visible:
  - **Pill**: filled Capsule — "Llamas Free" (accent-tinted background), "Llama Pro Monthly" / "Llama Pro Yearly" (accent fill, onAccent text).
  - **Upgrade chips**: Free users see "Monthly" + "Yearly" chips; monthly users see "Switch to Yearly"; yearly users see no chips.
  - Chips open `PaywallView(initialPlan:)` with the matching plan pre-selected.
- ProfileView now injects `quotaService` and all three environments into the paywall sheet.

**11. Tier-aware upgrade chips and always-visible quota pill in ImportFromPhotoView**
- File: `ios-native/Sources/Views/Library/ImportFromPhotoView.swift`
- `pillText` now always renders remaining import count for all users:
  - Free users under cap: "X of 5 free" → "1 of 5 free"
  - Pro users under cap: "X of 30 left"
  - Exhausted: "0 of Y left — resets in T"
- Added `upgradeChips` @ViewBuilder below the pill for free users (Monthly + Yearly buttons) and monthly users (Yearly button) — tapping opens the paywall with the appropriate plan pre-selected.
- Paywall sheet now injects `proStore` and `quotaService` (were missing; iOS 26 `@Observable` drops across `sheet` boundaries).

**12. `PaywallView` accepts `initialPlan` parameter**
- File: `ios-native/Sources/Views/Profile/PaywallView.swift`
- Added `init(initialPlan: LlamaProStore.Plan = .yearly)` — the yearly plan is pre-selected by default ("Best value"), but callers from the monthly upgrade chip pre-select `.monthly` so the user lands on the right card.

---

## Architecture Verification (Confirmed Correct)

The following were audited and confirmed to be correctly implemented. No changes needed.

| Area | Status | Notes |
|---|---|---|
| `cloudKitDatabase: .none` | ✅ | Set in `LlamasCookbookApp.swift` with explanatory comment |
| SeedFriend CloudKit short-circuits | ✅ | All 5 fan-out paths check `SeedFriend.isSeed()` before any CK call |
| `@Observable` re-injection into sheets | ✅ | All `fullScreenCover` + sheets that contain social/Pro surfaces re-inject environments |
| `proTabIcon` pattern for tab bar | ✅ | All three Pro crown tab items go through `proTabIcon(named:)` pre-rendering |
| aiVision HEIC → JPEG conversion | ✅ | `forcesJPEGOutput` is true on the `.aiVision` preset; enforced in `preparePages` |
| `FriendsStore.refresh()` re-entrancy | ✅ | `isRefreshing` set synchronously before first `await` |
| `QuotaService` always from `@Environment` | ✅ | No singleton access pattern found anywhere |
| Universal Links (AASA + entitlements + headers) | ✅ | All three legs correct; AASA serves as `application/json` |
| No secrets in git | ✅ | Confirmed: `credentials/` gitignored; no API keys, private keys, or tokens in source |
| `activate-pro.js` product ID coverage | ✅ | Both monthly + yearly IDs in `PRODUCT_IDS` Set; TTL from `expiresDate` |
| `img/[id].js` magic-byte sniff + 10MB cap | ✅ | Covers JPEG, PNG, WebP, HEIC; cap enforced at Content-Length and post-read |
| `aps-environment: production` in entitlements | ✅ | Correct; explanatory comment present |
| `Recipe.apply()` invariant — attribution fields untouched | ✅ | No editor code touches `sharedBy`/`originalCreator*` fields |
| `Formatters.date` used for all medium date display | ✅ | No inline `DateFormatter()` allocation found in view render code (excluding the now-fixed QuotaSnapshot) |

---

## StoreKit / Llama Pro Purchase Safety Audit

### Purchase flow
- Uses StoreKit 2 — the correct modern API. `Product.purchase(options:)` with `appAccountToken` derived from SHA-256(SIWA sub).
- `checkVerified()` properly throws on `.unverified` — only verified transactions activate Pro.
- Plan priority: yearly wins over monthly if both are present in `currentEntitlements`. Correct.
- `transactionUpdateTask` is `nonisolated(unsafe)` so `deinit` can cancel it without a MainActor hop — correct per CLAUDE.md invariant.

### Restore flow
- Uses `AppStore.sync()` — correct StoreKit 2 approach. Falls back to `checkCurrentEntitlements()` which re-iterates the receipt.
- Now shows "No Purchases Found" alert when restore finds no active subscription. ✅

### Server-side activation (`activate-pro.js`)
- Decodes and validates JWS payload: checks `bundleId`, `productId`, `expiresDate` > now.
- `appAccountToken` cross-check: if present, derives expected token from SIWA sub (SHA-256, UUID v4 variant) and rejects mismatches. This catches a transaction being replayed for a different account.
- **Known limitation:** JWS signature is not cryptographically verified server-side. Apple's StoreKit 2 client-side `.verified` result is trusted. Worst-case blast radius: a few days of unearned Pro access (bounded by `expiresDate` TTL). This is an accepted Phase 2 trade-off documented in the file. Recommend adding Apple App Store Server API verification post-launch.
- Stores `accountToken:` → `userId` reverse mapping for future App Store Server Notifications v2 webhook support.
- `pro:${userId}` KV entry TTL = `expiresDate - now + 2 day grace` for renewal propagation window. The iOS client calls `activate-pro` on every app open via `checkCurrentEntitlements`, keeping the entry fresh through renewals.

### Quota enforcement (end-to-end)
- **Monthly only:** `parse.js` pre-checks `saves:${userId}:${localYYYYMM}` before forwarding to Anthropic. `consume.js` increments the counter after the user saves the recipe. Free cap: 5 saves/month. Pro cap: 30 saves/month. Resets on the first of the local calendar month (timezone-aware via `x-llamas-tz` header).
- **Cache hits:** Monthly pre-check still runs before returning a cached result (correct — prevents quota exhaustion via repeated hits on the same photo).
- **Client gate:** `ImportFromPhotoView.isInputBlocked` correctly reflects `isMonthlyExhausted`. When exhausted, the `freeMonthlyLimitCard` or `proMonthlyLimitCard` blocked card is shown and the photo picker is disabled. ✅
- **`BYPASS_SECRET`:** Gated on env var being set. Confirm it is NOT set in the production Cloudflare Pages environment (only in local dev / wrangler).

---

## Repo Safety

| Check | Status |
|---|---|
| `credentials/` gitignored | ✅ |
| `*.p8`, `*.p12`, `*.mobileprovision` gitignored | ✅ |
| `.env*` gitignored | ✅ |
| No API keys in Swift source | ✅ |
| No API keys in Cloudflare Workers source | ✅ (`ANTHROPIC_API_KEY` read from env only) |
| `BYPASS_SECRET` not in source | ✅ (read from `env.BYPASS_SECRET` only) |
| `outdated/rn-expo/` committed | ℹ️ Intentional; contains `eas.json` with EAS project ID. Remove before making repo public. |

---

## App Store Connect Checklist

Before submitting the binary, complete the following in App Store Connect:

### Required
- [ ] **Privacy Policy URL** → `https://llamascookbook.pages.dev/privacy` (already authored)
- [ ] **Terms of Use URL** → Apple standard EULA or your own (paywall now links to Apple EULA)
- [ ] **Privacy Nutrition Labels** → Match `NSPrivacyCollectedDataTypes` entries:
  - User ID (linked to identity, app functionality) — for SIWA sub in quota system
  - Photos or Videos (not linked, app functionality) — for AI photo import
  - Other User Content (not linked, app functionality) — for text/link import
- [ ] **App Category** → Food & Drink (primary) recommended
- [ ] **Age Rating** → 4+ (no objectionable content, no location, no social matching)
- [ ] **In-App Purchases** → Both products must be approved in App Store Connect before submission:
  - `com.llamascookbook.app.pro.monthly` — "Llama Pro Monthly"
  - `com.llamascookbook.app.pro.yearly` — "Llama Pro Yearly"
  - Each needs: price, display name, description, promotional image (optional but recommended)
- [ ] **Subscription Group** → Create a subscription group containing both products. Yearly should be marked "Best value."
- [ ] **Review Notes** → Mention that Sign in with Apple is required for social/sharing features; unsigned users can still use the recipe library. Provide a test Apple ID for review.

### Strongly Recommended
- [ ] **Promotional screenshot showing Paywall** — demonstrate the subscription offering clearly to avoid review questions
- [ ] **App Preview video** — especially the photo-import → AI streaming reveal flow; this is the differentiating UX
- [ ] Verify `BYPASS_SECRET` is absent from production Cloudflare Pages env vars
- [ ] Verify `LLAMAS_QUOTA` KV namespace is bound in production Cloudflare Pages

---

## Remaining Open Work (post-launch)

These are not launch blockers but should be addressed after v1.0 ships:

| Item | Priority | Notes |
|---|---|---|
| `activate-pro.js` JWS signature verification | High | Add Apple App Store Server API verification. Current trust model is client-verified StoreKit 2 + TTL bound. |
| Friendship server-side uniqueness | Medium | Race window at `sendRequest`. Existing dedup sweep recovers; document as known limitation. |
| App Store Server Notifications v2 webhook | Medium | Needed for handling cancellations/refunds when app is not open |
| Liquid Glass adoption | Medium | Remove `UIDesignRequiresCompatibility = true` before iOS 27 forces it off |
| `img/[id].js` hostname allowlist | Low | `*.icloud.com` / `*.apple-cloudkit.com` allow list for belt-and-suspenders SSRF protection. Low risk since URL originates from CloudKit. |
| Privacy manifest: third-party SDK section | Low | If any third-party SDK is added (analytics, crash reporting), a separate SDK privacy manifest is required |

---

*Generated by Claude Code — architecture engineering skill. Verified against CLAUDE.md session 15 (2026-05-15).*
