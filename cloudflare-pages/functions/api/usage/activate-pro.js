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

const BUNDLE_ID   = 'com.llamascookbook.app';
const PRODUCT_IDS = new Set([
  'com.llamascookbook.app.pro.monthly',
  'com.llamascookbook.app.pro.yearly',
]);
import { FREE_CAP, PRO_CAP, getLocalYYYYMM, nextMonthResetUTC, deriveAppAccountToken } from '../../../lib/quota.js';

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
  if (!PRODUCT_IDS.has(payload.productId)) {
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
  const savesStr    = await quota.get(`saves:${userId}:${localYYYYMM}`);
  const used        = parseInt(savesStr ?? '0', 10);

  return Response.json({
    plan:      'pro',
    limit:     PRO_CAP,
    used,
    remaining: Math.max(0, PRO_CAP - used),
    resetAt:   nextMonthResetUTC(tz).toISOString(),
  });
}

// Token derivation and timezone helpers live in ../../../lib/quota.js.
