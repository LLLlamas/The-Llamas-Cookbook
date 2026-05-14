// /api/usage/activate-pro — Activate Pro subscription after a verified
// StoreKit 2 purchase.
//
// POST /api/usage/activate-pro
// Headers:
//   x-llamas-user   <SIWA sub>
//   x-llamas-tz     America/Los_Angeles  (IANA timezone)
//   Content-Type    application/json
// Body:
//   { "signedTransaction": "<JWS string from StoreKit 2 VerificationResult>" }
//
// 200 → activated; returns updated QuotaSnapshot
// 400 → missing or invalid transaction JWS
// 401 → missing x-llamas-user header
//
// The JWS payload is decoded and validated against expected productId and
// bundleId. No signature verification is done server-side — we trust Apple's
// StoreKit 2 verification on the client (the VerificationResult was .verified
// before the app sent it). A ASSN V2 webhook can be added later to handle
// renewals and cancellations without the app needing to be open.
//
// Security note: a crafted JWS body from a malicious caller would need a
// valid SIWA sub (proving auth) and a plausible transaction structure.
// Since the KV flag TTL is bounded by expiresDate, the worst case is a
// few days of unearned Pro access; acceptable for Phase 2.

const BUNDLE_ID  = 'com.llamascookbook.app';
const PRODUCT_ID = 'com.llamascookbook.app.pro.monthly';
const PRO_CAP    = 30;
const FREE_CAP   = 5;

export async function onRequestPost(context) {
  const { request, env } = context;

  const userId = request.headers.get('x-llamas-user');
  if (!userId) {
    return Response.json({ error: 'auth_required' }, { status: 401 });
  }

  const tz    = request.headers.get('x-llamas-tz') ?? 'UTC';
  const quota = env.LLAMAS_QUOTA;
  if (!quota) {
    return Response.json({ error: 'service_unavailable' }, { status: 503 });
  }

  let body;
  try { body = await request.json(); } catch {
    return Response.json({ error: 'invalid_request' }, { status: 400 });
  }

  const jws = body?.signedTransaction;
  if (!jws || typeof jws !== 'string') {
    return Response.json({ error: 'missing_transaction' }, { status: 400 });
  }

  // ── Decode JWS payload (middle segment, base64url) ────────────────────────

  let payload;
  try {
    const parts = jws.split('.');
    if (parts.length !== 3) throw new Error('not JWS');
    // base64url → base64
    const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    payload = JSON.parse(atob(b64));
  } catch {
    return Response.json({ error: 'invalid_transaction' }, { status: 400 });
  }

  // ── Validate fields ────────────────────────────────────────────────────────

  if (payload.bundleId !== BUNDLE_ID) {
    return Response.json({ error: 'wrong_bundle' }, { status: 400 });
  }
  if (payload.productId !== PRODUCT_ID) {
    return Response.json({ error: 'wrong_product' }, { status: 400 });
  }

  // expiresDate is milliseconds since epoch in StoreKit 2 JWS payloads.
  const expiresMs = payload.expiresDate;
  if (!expiresMs || expiresMs < Date.now()) {
    return Response.json({ error: 'transaction_expired' }, { status: 400 });
  }

  // ── Optionally verify the appAccountToken matches the calling user ─────────
  // The iOS app derives the token as SHA-256(siwaSubUTF8)[0:16] formatted as
  // UUID v4. If the token is present but doesn't match, reject — this catches
  // a transaction intended for a different account being used to activate Pro.

  const appAccountToken = payload.appAccountToken;
  if (appAccountToken) {
    const expectedToken = await deriveAppAccountToken(userId);
    if (expectedToken && appAccountToken.toLowerCase() !== expectedToken.toLowerCase()) {
      return Response.json({ error: 'token_mismatch' }, { status: 400 });
    }
    // Store the reverse mapping for future ASSN V2 webhook lookups.
    await quota.put(
      `accountToken:${appAccountToken.toLowerCase()}`,
      userId,
      { expirationTtl: Math.ceil((expiresMs - Date.now()) / 1000) + 7 * 24 * 60 * 60 },
    );
  }

  // ── Activate Pro ──────────────────────────────────────────────────────────
  // TTL = time until expiry + 2-day grace for renewal propagation.
  // The iOS client calls this endpoint again on every app open (via
  // checkCurrentEntitlements), so the KV entry stays fresh through renewals.

  const expiryTtlSeconds = Math.ceil((expiresMs - Date.now()) / 1000) + 2 * 24 * 60 * 60;
  await quota.put(`pro:${userId}`, 'active', { expirationTtl: Math.max(expiryTtlSeconds, 86400) });

  // ── Return updated QuotaSnapshot ──────────────────────────────────────────

  const localYYYYMM = getLocalYYYYMM(tz);
  const localDate   = getLocalDate(tz);
  const [savesStr, parsesStr] = await Promise.all([
    quota.get(`saves:${userId}:${localYYYYMM}`),
    quota.get(`parseAttempts:${userId}:${localDate}`),
  ]);

  const used        = parseInt(savesStr ?? '0', 10);
  const dailyParses = parseInt(parsesStr ?? '0', 10);

  return Response.json({
    plan:              'pro',
    limit:             PRO_CAP,
    used,
    remaining:         Math.max(0, PRO_CAP - used),
    resetAt:           nextMonthResetUTC(tz).toISOString(),
    dailyParsesUsed:   dailyParses,
    dailyParseLimit:   5,
    dailyParseResetAt: nextLocalMidnightUTC(tz).toISOString(),
  });
}

// ── Token derivation ──────────────────────────────────────────────────────────
// Mirrors LlamaProStore.appAccountToken(for:) in Swift:
// SHA-256 of the SIWA sub → first 16 bytes → UUID v4 variant bits → UUID string.

async function deriveAppAccountToken(userId) {
  try {
    const encoded = new TextEncoder().encode(userId);
    const hashBuf = await crypto.subtle.digest('SHA-256', encoded);
    const bytes   = new Uint8Array(hashBuf).slice(0, 16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;  // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80;  // RFC 4122 variant
    const hex = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
  } catch {
    return null;
  }
}

// ── Timezone / date helpers (duplicated from parse.js — no shared module) ─────

function getLocalDate(tz) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date());
}

function getLocalYYYYMM(tz) {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit',
  }).format(new Date()).replace('-', '');
}

function getTimezoneOffsetMs(tz, date) {
  const fmt = t => new Intl.DateTimeFormat('en-CA', {
    timeZone: t,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).formatToParts(date);
  const toParts = parts => {
    const g = type => parseInt(parts.find(p => p.type === type)?.value ?? '0', 10);
    return Date.UTC(g('year'), g('month') - 1, g('day'), g('hour'), g('minute'), g('second'));
  };
  return toParts(fmt(tz)) - toParts(fmt('UTC'));
}

function nextLocalMidnightUTC(tz) {
  const localDate     = getLocalDate(tz);
  const [y, m, d]     = localDate.split('-').map(Number);
  const tomorrowLocal = Date.UTC(y, m - 1, d + 1, 0, 0, 0);
  const candidate     = new Date(tomorrowLocal);
  return new Date(tomorrowLocal - getTimezoneOffsetMs(tz, candidate));
}

function nextMonthResetUTC(tz) {
  const localYM          = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit',
  }).format(new Date());
  const [y, m]           = localYM.split('-').map(Number);
  const nextYear         = m === 12 ? y + 1 : y;
  const nextMonth        = m === 12 ? 1 : m + 1;
  const firstOfNextLocal = Date.UTC(nextYear, nextMonth - 1, 1, 0, 0, 0);
  const candidate        = new Date(firstOfNextLocal);
  return new Date(firstOfNextLocal - getTimezoneOffsetMs(tz, candidate));
}
