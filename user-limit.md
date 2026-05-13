# Per-User Photo Import Quota & Llama Pro

Spec for an implementing agent. Code wins when this disagrees, but
file this as the source-of-truth for *intent*.

Author: Lorenzo + Claude (planning session 2026-05-13)
**Phase 1 implemented: 2026-05-13 (session 6)**

## Phase 1 implementation status

✅ Cloudflare Worker `/api/parse.js` — identity + TZ + daily parse limit + monthly quota pre-check + KV parse-result cache  
✅ Cloudflare Worker `/api/usage.js` (new) — read-only quota snapshot  
✅ Cloudflare Worker `/api/usage/consume.js` (new) — save-confirm increment  
✅ `QuotaService.swift` — `@MainActor @Observable` iOS quota state  
✅ `AnthropicRecipeParser.swift` — `x-llamas-user`, `x-llamas-tz`, `x-llamas-import-kind: photo` headers; `VisionParseOutcome` typed result; 401/402/429 handling; `x-llamas-cache` detection  
✅ `RecipeAIParser.parseImages` — returns `VisionParseOutcome`  
✅ `ImportFromPhotoView.swift` — quota pill, blocked states (monthly free / monthly Pro / daily), sign-in nudge, paywall sheet wire  
✅ `PhotoImportPreviewView.swift` — consume after save, race banner, cache-hit hint  
✅ `LlamaProStore.swift` — Phase 1 stub (`isPro = false`)  
✅ `PaywallView.swift` — "Coming soon" stub  
✅ `LlamasCookbookApp.swift` — `QuotaService` + `LlamaProStore` injected into environment  

**Still required before shipping Phase 1:**  
⬜ Create `LLAMAS_QUOTA` KV namespace in Cloudflare dashboard and bind it to the Pages project (Lorenzo, manual)  
⬜ Manually set quota states in KV dashboard to verify all UI state paths (acceptance criteria)

---

---

## Goal

1. Cap free users at **5 successfully-saved photo imports per calendar
   month** (user-local timezone). "Successful" means the user tapped
   Save in `PhotoImportPreviewView` after a vision parse — not just
   that the parse ran. If the AI parsed badly and the user cancelled,
   it doesn't count.
2. Surface remaining quota in the photo-import sheet so the user always
   knows what they have left.
3. When the cap is hit, present **Llama Pro** — a $2.99/month paid
   subscription that raises the cap to **30 successfully-saved photo
   imports per month**.
4. Enforce server-side so the cap actually protects API spend, not just
   nudges normal users.
5. Block photo import entirely for unsigned users (no free trial).
6. Bound abuse via a separate **daily parse-attempt rate limit** (5
   attempts/user/day) — independent of the monthly save quota.

Out of scope for this feature:
- Quota on link / paste imports — too cheap to be worth gating.
- OCR-only fallback when vision is gated. Photo import is fully gated;
  user can paste/type if they're at the cap.

---

## Decisions log

These were settled during planning (2026-05-13). Spec uses these as
fixed inputs; do not re-litigate during implementation.

| Decision | Choice | Why |
|---|---|---|
| Storage / enforcement | Cloudflare Worker (KV) | Real server-side enforcement, can't be bypassed by reinstall |
| User identity | SIWA `sub` from `KeychainStore` | Stable across reinstalls, anonymous to Anthropic, already in app |
| Llama Pro pricing | $2.99/month | Sustainable margin at ~3¢/parse API cost (15% Apple cut → $2.54 net) |
| Free cap | 5 saved imports/month | Honest pricing — only "spend" when user kept the recipe |
| Pro cap | 30 saved imports/month | 6× the free tier, ~$1.35 worst-case API cost (30 × 1.5 parses × 3¢), ~47% margin |
| Annual plan | None for v1 | Keep App Store Connect setup minimal; can add later |
| Free trial | None | Lorenzo's call — no trial period offered |
| Quota model | Save-confirms (not parse-confirms) | Failed parses don't punish the user; charges them only when AI gave them value |
| Daily parse rate limit | 5 attempts/user/day | Bounds abuse from modified-app users who parse without saving; honest users never hit this |
| Worker parse-result cache | KV-cached responses keyed by exact image-hash, 7-day TTL | Network-glitch retries are free and instant; popular shared photos benefit globally; never affects different-bytes retries (those re-parse) |
| Multi-page counting | 1 saved import = 1 quota unit | Matches user mental model ("I saved one recipe") |
| Scope | Photo only | Vision is the cost driver; link/paste stay free |
| Reset boundary | User-local timezone, 1st of month | Friendlier than UTC; spec includes TZ propagation to Worker |
| Unsigned users | Blocked entirely | No identity → no quota → no imports |
| Future Pro pitch | "Grocery List with Instacart integration coming soon" | Real upcoming feature; honest pitch |

### Cost math behind the caps

| Tier | Saves/mo | Avg parses/save | Parse calls/mo | API cost/mo | Net revenue | Margin |
|---|---|---|---|---|---|---|
| Free (worst case) | 5 | 1.5 | ~7-8 | ~$0.23 | $0 | -$0.23 (subsidized) |
| Free (abuse: max parses, no saves) | 0 | — | 5/day × 30 = 150 | ~$4.50 | $0 | -$4.50 (capped by daily rate limit) |
| Pro (typical) | 5-10 | 1.5 | ~10-15 | ~$0.30-0.45 | $2.54 | ~85% |
| Pro (worst case) | 30 | 1.5 | ~45 | ~$1.35 | $2.54 | ~47% |

---

## User-facing behavior

### Photo import sheet (`ImportFromPhotoView`)

**Always visible at the top of the sheet** (replaces or accompanies the
existing hero row): a quota pill.

| State | Pill copy | Pill style |
|---|---|---|
| Pro user, ≥ 10 left | "Llama Pro — 25 of 30 left" | Accent-tinted, small llama logo |
| Pro user, 1-9 left | "Llama Pro — 5 of 30 left this month" | Warning tint |
| Pro user, 0 left | "Llama Pro — 0 left, resets Jun 1" | Destructive tint |
| Free, ≥ 3 left | "4 free imports left this month" | Subtle, accent text |
| Free, 1-2 left | "1 free import left — resets Jun 1" | Warning tint |
| Free, 0 left | "0 imports left — resets Jun 1" | Destructive tint |
| Daily parse cap hit (regardless of monthly quota) | "Try again tomorrow — daily limit reached" | Warning tint |
| Not signed in | "Sign in with Apple to start importing" | Accent CTA chip |

The pill phrasing makes clear that the count is **saves**, not
attempts: "X imports left" reads as "you can save X more." We
deliberately don't expose the daily parse limit to the user as a
counter — it's an abuse-protection guardrail, not a budget the user
should be tracking.

The reset date is the first of next month **in the user's local
timezone** (e.g. May 13 PST → "resets Jun 1"). The iOS client formats
the `resetAt` UTC timestamp the server returns into local time for
display.

### When monthly quota is exhausted

For **free users** at 0:
- "Take a Photo" / "Choose from Library" / "Add Another Page" buttons
  are visually disabled (`.disabled(true)`, opacity 0.4, no haptic).
- The existing "Tips for a clean read" section is **replaced** with the
  upsell card:

  ```
  ┌──────────────────────────────────────────────┐
  │  🦙  Out of free imports                      │
  │                                              │
  │  You've saved 5 photo imports this month —   │
  │  resets Jun 1.                               │
  │                                              │
  │  Upgrade to Llama Pro for 30 photo imports   │
  │  per month, or paste / type recipes for free.│
  │                                              │
  │  Coming soon to Pro: Grocery list with       │
  │  Instacart integration.                      │
  │                                              │
  │       [   Upgrade to Llama Pro   ]           │
  │       [   Maybe later             ]          │
  └──────────────────────────────────────────────┘
  ```

  - **Upgrade to Llama Pro** → presents the IAP paywall sheet.
  - **Maybe later** → dismisses the photo-import sheet entirely.

For **Pro users** at 0:
- Same greying behavior.
- Tips section replaced with a softer message:

  ```
  ┌──────────────────────────────────────────────┐
  │  🦙  You've hit your monthly Pro limit        │
  │                                              │
  │  You've saved 30 photos this month —         │
  │  resets Jun 1.                               │
  │                                              │
  │  In the meantime, paste or type recipes      │
  │  for free, no limit.                         │
  └──────────────────────────────────────────────┘
  ```

### When daily parse limit is hit

Hit when the user has made 5 parse attempts today regardless of
outcome (saved, cancelled, failed). All capture buttons greyed:

```
┌──────────────────────────────────────────────┐
│  🦙  Daily limit reached                      │
│                                              │
│  You've made 5 photo imports today.          │
│  Try again tomorrow, or paste / type recipes │
│  for free in the meantime.                   │
└──────────────────────────────────────────────┘
```

This message is intentionally brief — the daily limit isn't a "feature"
to advertise, just a guardrail. Honest users will essentially never see
this; it shows up only after 5 attempts in 24 hours.

### When user is not signed in

Photo import requires sign-in. Show a sign-in CTA instead of capture
buttons:

```
Sign in with Apple to import recipes from photos.
Free users get 5 photo imports per month.
            [ Sign in with Apple ]
```

### What counts (and what doesn't)

**Counts as 1 quota unit consumed** — happens at exactly one moment:

- User taps Save in `PhotoImportPreviewView` → recipe persists locally
  → iOS client fires-and-forgets `POST /api/usage/consume` → Worker
  increments KV.

**Does NOT count toward quota:**

- Vision call ran but returned a non-confident draft (banner mode).
- User opened `PhotoImportPreviewView` but tapped Cancel.
- User tapped "Edit as text" on the fallback banner — even if they
  later save the recipe via the text editor (because the AI failed
  enough that they did the work themselves).
- User saved a recipe but the consume call failed (network drop) —
  see "race conditions" in edge cases.
- Multi-page imports still count as 1 unit per saved recipe regardless
  of page count.

**Counts toward the daily parse rate limit (separate counter):**

- Every call to `/api/parse` for photo import, regardless of outcome.

### Edit-after-save

If the user saves a heavily-edited draft (AI got it 60% right, user
fixed the rest, then tapped Save), it still counts as 1 unit. The user
got value from the AI; that's the contract.

### Cache-hit hint

When the Worker returns a cached parse result (via the
`x-llamas-cache: hit` response header) AND this is the user's 2nd or
later photo-import attempt within the current app session, surface a
small inline hint above the preview:

> 🦙 Same photo as before — same result. Try a clearer or
> differently-angled photo for a fresh parse.

Suppressed on the user's first attempt, even when the result came from
the global cache (e.g. another user previously imported the same
widely-shared photo, or the user themselves cached it in a previous
session). They've never seen the result before; treat it as fresh from
their perspective.

The session attempt counter resets when `ImportFromPhotoView` is
dismissed and re-presented.

### Pro user behavior

Same as free users above with a 30-instead-of-5 cap. No changes to the
"daily parse rate limit" — it applies to Pro users too at 5/day. (Pro
is monthly headroom, not "you can spam attempts." If a Pro user ever
needs >5 attempts in a single day, that's a signal to look at their
photos rather than raise the limit.)

---

## Architecture

### Identity

- **User ID**: SIWA `sub` from `KeychainStore.appleUserID()`
  (`Sources/Lib/KeychainStore.swift`). Stable across reinstalls,
  device-bound, anonymous to Anthropic.
- iOS client sends the SIWA sub in a custom header `x-llamas-user`
  on every photo-import vision call AND on the consume call. Worker
  rejects (HTTP 401) when the header is missing for either.
- Text/link/paste imports do NOT send the header (they're not gated).

### Timezone

- iOS client sends the user's IANA timezone in a custom header
  `x-llamas-tz` (e.g. `America/Los_Angeles`).
- Worker uses this to compute the local-month KV key
  (`saves:<userId>:<YYYY-MM>` where YYYY-MM is the local month).
- Worker uses this to compute the user-local `resetAt` timestamp
  returned in `/api/usage` responses.
- Spoofing risk: a user could change TZ to harvest extra imports at
  month boundaries. Acceptable; the global cap is still enforced
  per-month, the trick only buys a one-time rollover overlap.

### Cloudflare Worker — `/api/parse` (modified)

Updated for the save-confirms model:

1. **Detect photo-import calls.** Header `x-llamas-import-kind: photo`
   from the iOS client. Text imports send `x-llamas-import-kind: text`
   (or omit the header — treat as text by default).

2. **For photo calls:**
   - Require `x-llamas-user` header. Missing → return 401 with
     `{"error": "auth_required"}`.
   - Require `x-llamas-tz` header (IANA timezone string). Missing →
     fall back to `UTC` and log.
   - **Daily parse limit check.** Read KV
     `parseAttempts:<userId>:<YYYY-MM-DD>` (where YYYY-MM-DD is the
     local date). If ≥ 5, return 429 with body:
     ```json
     {"error": "daily_parse_limit", "limit": 5, "resetAt": "<next local midnight UTC>"}
     ```
   - Increment `parseAttempts` counter (TTL 36h, auto-expires).
     Increment happens **before** quota check so even rejected attempts
     count toward the daily limit (prevents probing).
   - **Monthly quota pre-check.** Look up plan: KV `pro:<userId>` →
     `"active"` or missing. Cap is **30 if Pro, else 5**. Read
     `saves:<userId>:<localYYYYMM>` (default 0). If count ≥ cap,
     return 402 with body:
     ```json
     {
       "error": "quota_exhausted",
       "limit": 30,
       "used": 30,
       "resetAt": "2026-06-01T07:00:00Z"
     }
     ```
     The pre-check fails fast so the user doesn't burn AI tokens just
     to discover at save time that they're capped.
   - Otherwise, forward to Anthropic and return the response unchanged.
   - **Quota counter is NOT incremented here.** Save endpoint owns it.

3. **For text calls:** unchanged — forward straight through.

### Cloudflare Worker — parse-result cache (KV)

Transparent caching of vision parse results, keyed by the exact bytes
of the image(s) sent. Designed to make the network-glitch retry
scenario free and instant: user taps Process, the call appears to fail
on iOS due to a flaky connection, they retry, the second call hits the
cache and returns immediately at zero API cost.

**Cache key shape:**

```
parseCache:<promptVersion>:<contentHash>
```

- `promptVersion` is a string constant in the Worker (`v1` for now).
  Bump this any time `RecipeAIParser.instructions` changes — it
  invalidates all cached entries naturally so the new prompt isn't
  competing with stale results.
- `contentHash` is SHA-256 of: each image's SHA-256 hash, joined by
  `:` in send order. Order-sensitive, so reordering pages produces a
  different cache key (correct — it's a meaningfully different request).

**TTL:** 7 days. Long enough to catch retries within a normal usage
window, short enough that the KV namespace stays small.

**Worker behavior on `/api/parse` for photo calls:**

1. Compute `contentHash` from request body images.
2. Look up `parseCache:<promptVersion>:<contentHash>` in KV.
3. **Cache hit:**
   - Return cached response with `x-llamas-cache: hit` response header.
   - Daily parse limit counter NOT incremented (cache hits cost
     nothing in API spend).
   - Monthly quota pre-check still runs (cache cannot bypass cap).
   - Latency: ~50-100ms vs ~5-10s for a fresh call.
4. **Cache miss:**
   - Daily parse limit + monthly quota pre-check as today.
   - Forward to Anthropic.
   - On 200 response with valid `tool_use` block, store the response
     body in KV before returning. Set `x-llamas-cache: miss` header.
   - On any error response, do NOT cache. (Don't poison the cache
     with failures — the next retry should get a fresh attempt.)

**Cost economics at expected scale:**

| KV operation | Rate | At 1k imports/mo | Notes |
|---|---|---|---|
| Reads | $0.50 / 1M | ~$0.001 | Every parse call does 1 read |
| Writes | $5.00 / 1M | ~$0.005 | One per cache miss |
| Storage | $0.50 / GB-mo | ~$0.001 | ~3KB × 1k entries = 3MB |
| **Total KV overhead** | — | **~$0.10/mo** | At 1k imports/mo |
| **Anthropic savings at 10% hit rate** | — | **~$3/mo** | 100 hits × ~3¢ |

Net: trivially worth it.

**Privacy:**
- Cache is keyed by image content hash, not user identity.
- Two users importing the same widely-shared cookbook photo would
  share one cache entry. Acceptable — the cached value is just
  parsed recipe text, not PII or per-user data.
- App Store privacy disclosure: already covers Anthropic processing;
  KV storage of parsed text for ≤7 days is incidental to that.

### Cloudflare Worker — `/api/usage/consume` (new)

Called by iOS client immediately after a successful Save in
`PhotoImportPreviewView`.

Request:
```
POST /api/usage/consume
Headers:
  x-llamas-user: <SIWA sub>
  x-llamas-tz:   America/Los_Angeles
```

Body: empty (no payload needed; user identity + timezone is enough).

Response on success (200):
```json
{
  "plan": "free",
  "limit": 5,
  "used": 3,
  "remaining": 2,
  "resetAt": "2026-06-01T07:00:00Z"
}
```

Response on race-condition cap-hit (402):
```json
{
  "error": "quota_exhausted",
  "limit": 5,
  "used": 5,
  "resetAt": "2026-06-01T07:00:00Z"
}
```

(See "Race conditions" in edge cases for handling.)

Worker logic:
1. Auth check (`x-llamas-user` required, 401 otherwise).
2. Look up plan (Pro vs Free) and cap.
3. Read `saves:<userId>:<localYYYYMM>` count.
4. If count ≥ cap, return 402 — but the recipe was already saved
   locally by the iOS client; this just signals "we couldn't tick
   your counter." See edge cases.
5. Otherwise, increment count atomically (KV CAS or last-write-wins;
   single-import-per-action means the rare race overshoot is bounded
   to 1).
6. Return updated snapshot.

### Cloudflare Worker — `/api/usage` (new, read-only)

Returns the current quota snapshot. iOS client polls this on launch
and after each consume call (with a small delay for KV propagation).

Request:
```
GET /api/usage
Headers:
  x-llamas-user: <SIWA sub>
  x-llamas-tz:   America/Los_Angeles
```

Response:
```json
{
  "plan": "free",
  "limit": 5,
  "used": 3,
  "remaining": 2,
  "resetAt": "2026-06-01T07:00:00Z",
  "dailyParsesUsed": 1,
  "dailyParseLimit": 5,
  "dailyParseResetAt": "2026-05-14T07:00:00Z"
}
```

(The daily fields are returned but the iOS pill only surfaces them
when the cap is actually hit.)

### KV key lifecycle

- `saves:<userId>:<localYYYYMM>` — integer, incremented per consumed
  save. TTL ~70 days (current month + ~40-day grace).
- `parseAttempts:<userId>:<YYYY-MM-DD>` — integer, incremented per
  parse call attempt. TTL 36h.
- `pro:<userId>` — `"active"` for paying subscribers. Set/cleared by
  ASN V2 webhook. No TTL — managed by Apple's notifications.

### IAP — Llama Pro subscription

#### App Store Connect setup
- Auto-renewable subscription group: `LlamasCookbookPro`
- One product (v1):
  - `com.llamascookbook.app.pro.monthly` — $2.99/month
- **No free trial** (Lorenzo's call).
- **No annual plan** for v1 (can be added later).
- Subscription benefits copy (use verbatim in App Store Connect):
  > **Llama Pro — $2.99/month**
  >
  > 30 photo imports per month (vs 5 on the free plan).
  > Coming soon: Grocery list with Instacart integration.
  >
  > Cancel anytime in your Apple ID settings.

#### iOS — StoreKit 2

New file: `ios-native/Sources/Lib/LlamaProStore.swift`
- `@MainActor` `@Observable` singleton.
- Loads products on first access via `Product.products(for: ...)`.
- Listens to `Transaction.updates` for entitlement changes.
- Exposes `var isPro: Bool` derived from current entitlements.
- `func purchase(_ product: Product) async throws -> Bool`
- `func restore() async throws`

New file: `ios-native/Sources/Views/Profile/PaywallView.swift`
- Sheet shown when user taps "Upgrade to Llama Pro".
- Hero llama, value prop bullets (30 imports/month, Grocery list
  Instacart coming soon), monthly purchase button, restore-purchases
  link, terms/privacy links.
- Purchase button reads "Subscribe — $2.99/month" (no trial framing).

Inject `LlamaProStore` into the environment from `LlamasCookbookApp`.

#### Server-side receipt validation

Use App Store Server Notifications V2 (server-to-server webhook):

1. Set up an App Store Connect webhook → Cloudflare Worker endpoint
   `/api/iap/notifications`.
2. Worker validates the JWS signature using Apple's public keys.
3. On `SUBSCRIBED`, `DID_RENEW`, `OFFER_REDEEMED` → set
   `pro:<userId> = "active"` in KV.
4. On `EXPIRED`, `REVOKE`, `REFUND` → delete `pro:<userId>`.
5. The receipt's `appAccountToken` (set by the iOS client at purchase
   time to the SIWA sub) links App Store transaction → user quota.

#### Client → server linkage at purchase time

```swift
let purchase = try await product.purchase(options: [
    .appAccountToken(siwaSubAsUUID)
])
```

The SIWA sub (a string) needs to be folded into a UUID for
`.appAccountToken`. Recommendation: SHA-256 the sub, take the first 16
bytes, format as UUID. Store this transformation in
`LlamaProStore.appAccountToken(for:)` — deterministic, reversible at
the Worker.

---

## iOS client changes (summary)

| File | Change |
|---|---|
| `Sources/Lib/AnthropicRecipeParser.swift` | Add `x-llamas-user`, `x-llamas-tz`, `x-llamas-import-kind` headers to vision calls. Surface 402 (quota), 429 (daily parse cap), 401 (auth) as typed errors so UI can distinguish. Detect `x-llamas-cache: hit` response header and surface to caller (e.g. via a wrapper struct alongside the returned draft). |
| `Sources/Lib/QuotaService.swift` (new) | `@MainActor @Observable`. Polls `/api/usage` on launch, after each consume call (with 500ms delay for KV propagation), and on import-sheet open. Caches result with 60-second freshness. Exposes `var snapshot: QuotaSnapshot?`. |
| `Sources/Lib/LlamaProStore.swift` (new) | StoreKit 2 wrapper. See IAP section. |
| `Sources/Views/Library/ImportFromPhotoView.swift` | Quota pill at top, gated buttons in three exhausted states (monthly free / monthly Pro / daily parse), replaced tips section per state. Sign-in nudge when unsigned. Handles 402 / 429 from `runImport` by refreshing quota and switching to the matching exhausted-state UI. Tracks per-session attempt counter; passes it (and the cache-hit flag from the parser) to `PhotoImportPreviewView` so the cache-hit hint appears on attempt ≥ 2. |
| `Sources/Views/Library/PhotoImportPreviewView.swift` | After successful local save, fire `await QuotaService.consume()` (which posts to `/api/usage/consume` and refreshes snapshot). On 402 race response, show the "this one's on us" banner. Renders the cache-hit hint above the title block when the parent passes a `cacheHit && attemptCount >= 2` signal. |
| `Sources/Views/Profile/PaywallView.swift` (new) | IAP paywall sheet. |
| `Sources/Views/Profile/ProfileView.swift` | Add "Llama Pro" section showing current plan, manage-subscription link, restore-purchases. |
| `Sources/App/LlamasCookbookApp.swift` | Inject `QuotaService` and `LlamaProStore` into environment. |

---

## Cloudflare Worker changes (summary)

| File | Change |
|---|---|
| `cloudflare-pages/functions/api/parse.js` | Identity + TZ + daily parse rate-limit + monthly quota pre-check before forwarding. KV cache lookup before the Anthropic call; cache write on a successful response. Sets `x-llamas-cache: hit` or `miss` response header. **No quota increment** — that moved to consume. |
| `cloudflare-pages/functions/api/usage/consume.js` (new) | Save-confirms endpoint. Auth + atomic increment + return updated snapshot. |
| `cloudflare-pages/functions/api/usage.js` (new) | Read-only quota snapshot endpoint. |
| `cloudflare-pages/functions/api/iap/notifications.js` (new) | App Store Server Notifications V2 webhook handler. |
| `cloudflare-pages/wrangler.toml` (or Pages dashboard) | Bind KV namespace `LLAMAS_QUOTA` to the Pages project. |

New env vars (Cloudflare Pages dashboard, encrypted where noted):
- `APPLE_BUNDLE_ID = com.llamascookbook.app`
- `APPLE_TEAM_ID = GYFN949Q5E`
- `APPLE_NOTIFICATION_KEY` (encrypted) — for ASN V2 JWS signature verification
- KV binding: `LLAMAS_QUOTA`

---

## Edge cases & decisions

### Race conditions

**User parses at 4/5 saves, by the time they Save, another device already saved a 5th**:
- Local save succeeds (recipe is in their library)
- `consume` call returns 402
- iOS client shows a small banner: *"This one's on us — you're already at your monthly limit. Recipe saved!"*
- Quota counter is at 5/5; user is at 6 effective saves but it's bounded to 1 freebie per cap-hit
- Acceptable. Pursuing strict atomicity (Durable Object) is overkill for this volume.

**User saves but the consume request times out / fails network**:
- Recipe is saved locally (the consume call is fire-and-forget, doesn't block save UX)
- Quota counter doesn't tick — user got a freebie
- Acceptable; rare in practice and self-limiting (next save tries again normally)

**Two parses in flight against quota cap-1**:
- Both pre-checks see count = cap-1, both pass
- Both burn AI tokens, both succeed
- Both consume calls fire — first wins (cap), second gets 402
- Net: 1 freebie (matches the consume race above). Bounded to 1 per cap boundary.

### Identity edges

- **User signs out then signs in with same Apple ID**: same SIWA sub
  → quota and Pro status persist. ✅
- **User changes Apple ID**: different SIWA sub → fresh free-tier quota,
  Pro status doesn't carry. Acceptable; rare.
- **User changes timezone mid-month**: Worker computes KV key from the
  new TZ. Could result in a one-time "extra" or "lost" import at month
  boundaries. Acceptable.
- **Family Sharing**: Pro entitlement propagates via Family Sharing if
  the subscription product is configured for it in App Store Connect.

### Money / API edges

- **Refund**: ASN V2 `REFUND` notification → KV `pro:` deleted → next
  import treats them as free. The current month's save count is NOT
  reset.
- **Anthropic returns 200 but no tool_use block** (model refused or
  produced free-form text): treated as failed parse on the iOS side
  (no preview shown). Daily parse counter still ticked (Worker can't
  distinguish before it forwards). Save counter doesn't tick.
- **Anthropic returns 4xx/5xx due to Lorenzo's monthly billing limit**:
  Worker forwards the failure unchanged. User sees nil → falls back
  through OCR → text-AI → "Edit as text" banner. Daily parse counter
  ticks (Worker tried). Save counter doesn't tick (no save will happen
  through the photo path).
- **Network failure between iOS and Worker on parse**: client sees
  nil. Daily parse counter only ticks if the Worker received the
  request — depends on where in the round-trip the failure happened.

### Cache behavior

- **Cache invalidation on prompt update**: bump `promptVersion` in
  the Worker (e.g. `v1` → `v2`). All old cache entries become
  unreachable; KV TTL eventually expires them naturally. No manual
  cleanup needed.
- **Stale cache after Anthropic model update**: if a model version
  changes meaningfully (Sonnet 4.6 → Sonnet 4.7), bump
  `promptVersion` to invalidate caches. Otherwise old cached results
  could differ from what a fresh call would produce now.
- **Cache poisoning by errors**: only cache responses with a valid
  `tool_use` block carrying a `structured_recipe` payload. Errors,
  free-form text responses, and quality-gate failures are NOT
  cached. Each failure gets a fresh chance on retry.
- **Cache hit on widely-shared photo**: a popular cookbook image
  shared online could have many users hashing to the same cache
  entry. Acceptable — the cached value is just recipe text, and each
  user's monthly quota is still independently tracked via consume.
- **Cache vs daily parse limit**: cache hits do NOT tick the daily
  parse counter (they cost nothing). Cache misses do tick it.
- **Cache vs monthly quota**: cache hits still pre-check the monthly
  quota; a user at cap gets 402 even when their photo is cached
  (they couldn't save it anyway).
- **Edit-as-text fallback path**: the OCR + text-AI fallback runs
  through `/api/parse` with `x-llamas-import-kind: text`. Text calls
  bypass the photo cache entirely (different code path, different
  inputs). No cache cross-contamination between photo and text
  imports.

### Abuse vectors and limits

- **Modified app that bypasses consume endpoint**: user gets unlimited
  free saves to their local library. Bounded by daily parse limit (5
  attempts/day × 30 days × 3¢ = $4.50/user/month worst case).
- **Modified app that spams parse endpoint**: bounded by daily parse
  limit, same $4.50/user/month ceiling.
- **Multiple Apple IDs to farm free tier**: one fresh quota per Apple
  ID. Acceptable; creating Apple IDs is non-trivial and the per-month
  cost per fresh ID is bounded ($0.23/month worst-case).
- **Spoofing SIWA sub of another user**: not an abuse vector against
  Lorenzo (only inflates the victim's counter). The victim sees their
  quota drained; could be a harassment vector but requires knowing the
  victim's SIWA sub, which isn't exposed anywhere.

---

## Telemetry / monitoring

Worker logs (already piped to Cloudflare's analytics):
- `parse_attempt` — userId, plan, count after, outcome (allowed,
  daily_blocked, monthly_blocked)
- `quota_consume` — userId, plan, count after, outcome (incremented,
  cap_race)
- `iap_notification` — type, userId, success/failure

iOS-side: no analytics events for v1.

---

## Implementation phases

The implementing agent should land these in order so each phase ships
something testable independently.

**Phase 1 — Worker quota enforcement (no IAP yet)**
- KV namespace + bindings
- Updated `/api/parse` with identity + TZ + daily parse limit + monthly
  quota pre-check (no increment)
- New `/api/usage/consume` endpoint (increment on save)
- New `/api/usage` read-only endpoint
- iOS: send headers, handle 401/402/429, show quota pill, gate buttons
  per exhausted state, show sign-in nudge for unsigned users
- `PhotoImportPreviewView` calls consume after save, shows freebie
  banner on 402
- Upsell card shows placeholder where the upgrade button will go
  (button disabled / opens "Coming soon" sheet)
- Free users only — Pro path stubbed out (everyone is "free" until
  Phase 2 ships)
- **Manual KV override testing**: dashboard-set quota states to verify
  every UI state path

**Phase 2 — IAP**
- StoreKit 2 product setup in App Store Connect (Lorenzo manual)
- `LlamaProStore.swift` + `PaywallView.swift`
- ASN V2 webhook + KV `pro:` flag
- Wire upgrade button to paywall sheet
- Profile screen Pro section
- Pro users now get 30/month cap instead of 5

**Phase 3 — Polish**
- Family Sharing verification on real device
- Restore-purchases flow
- Edge-case copy (subscription expiring soon, payment issue, etc.)

---

## Acceptance criteria

A successful implementation passes all of:

**Quota model (save-confirms):**
- [ ] Free user with 5 saves remaining can parse and Save a photo;
      counter drops to 4 in the pill within 1.5s of save (covers KV
      propagation).
- [ ] Free user opens preview and taps Cancel → counter does NOT drop.
- [ ] Free user with vision parse fail (banner mode) → counter does
      NOT drop, even after a successful save through the "Edit as
      text" handoff.
- [ ] Free user heavily edits the previewed draft, then Saves →
      counter drops by 1 (edits don't change the contract).

**Monthly cap enforcement:**
- [ ] Free user at 0 monthly saves: greyed buttons, upsell card
      visible. Tapping a button does nothing.
- [ ] Pro user at 0 monthly saves: greyed buttons, soft-cap message
      (no upsell button).
- [ ] Quota auto-resets to cap on the 1st of the next month **in the
      user's local timezone**.

**Daily parse limit enforcement:**
- [ ] User at 5 parse attempts today: greyed buttons, "daily limit
      reached" message.
- [ ] Daily counter resets at local midnight.
- [ ] Daily counter ticks even on parse calls that fail with 402
      (prevents quota-status probing).

**IAP (Phase 2):**
- [ ] Tapping "Upgrade to Llama Pro" presents `PaywallView`.
- [ ] Sandbox purchase → `isPro = true` → quota pill switches to
      "Llama Pro — 30 of 30 left" → capture buttons re-enable within 2s.
- [ ] Cancelling subscription via Settings → `pro:` deleted within
      ASN webhook latency → next import shows free-tier behavior.
- [ ] Restore Purchases on fresh install re-establishes `isPro = true`
      after sign-in.

**Race conditions:**
- [ ] Worker rejects over-quota photo parse with 402 (no AI cost).
- [ ] Worker does NOT increment quota when Anthropic returns 4xx/5xx.
- [ ] Save-with-cap-already-hit (race) returns 402 from consume,
      iOS shows "this one's on us" banner, recipe still saves locally.

**Auth:**
- [ ] Unsigned user sees sign-in nudge instead of capture buttons; no
      photo imports possible without sign-in.

**Caching:**
- [ ] First parse of a unique photo: cache miss, `x-llamas-cache: miss`
      header, full Anthropic call, latency ~5-10s.
- [ ] Second parse of the same exact bytes within 7 days: cache hit,
      `x-llamas-cache: hit` header, no Anthropic call, latency
      <500ms.
- [ ] Cache hit on the user's 2nd+ session attempt shows the "same
      photo, same result" hint above the preview.
- [ ] Cache hit on the user's 1st session attempt (e.g. previously
      cached by another user or by a previous app launch) does NOT
      show the hint — the user has never seen this result before.
- [ ] Different bytes (different photo of the same recipe) → cache
      miss → fresh parse runs.
- [ ] Failed Anthropic responses (4xx/5xx, free-form text without a
      `tool_use` block) are NOT written to cache.
- [ ] Bumping `promptVersion` in the Worker invalidates all prior
      cached entries (verifiable: previously-cached hash returns
      cache miss after bump).
- [ ] Cache hits do NOT increment the daily parse counter.
- [ ] Cache hits DO still pre-check monthly quota — a user at cap
      gets 402 even on a cache hit.

**Out-of-scope unaffected:**
- [ ] Link import (URL paste, TikTok, Pinterest) and text-paste import
      are unaffected — no quota check, no counter, no upsell, no
      daily parse limit, no photo cache.
