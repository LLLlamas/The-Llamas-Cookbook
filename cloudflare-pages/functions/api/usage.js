// /api/usage — Read-only quota snapshot for the current user.
//
// GET /api/usage
// Headers:
//   x-llamas-user  <SIWA sub>
//   x-llamas-tz    America/Los_Angeles  (IANA timezone)
//
// Response 200:
//   { plan, limit, used, remaining, resetAt }
//
// iOS client calls this on import-sheet open and after each consume call.
// 60-second client-side cache prevents chatter; no auth beyond x-llamas-user.

import { FREE_CAP, PRO_CAP, getLocalYYYYMM, nextMonthResetUTC } from '../../lib/quota.js';

export async function onRequestGet(context) {
  const { request, env } = context;

  const userId = request.headers.get('x-llamas-user');
  if (!userId) {
    return Response.json({ error: 'auth_required' }, { status: 401 });
  }

  const tz    = request.headers.get('x-llamas-tz') ?? 'UTC';
  const quota = env.LLAMAS_QUOTA;

  if (!quota) {
    // KV not bound — return a safe free-tier stub so the UI doesn't break.
    return Response.json(freeStub(), { status: 200 });
  }

  const isPro     = (await quota.get(`pro:${userId}`)) === 'active';
  const cap       = isPro ? PRO_CAP : FREE_CAP;

  const localYYYYMM = getLocalYYYYMM(tz);
  const savesStr    = await quota.get(`saves:${userId}:${localYYYYMM}`);
  const used        = parseInt(savesStr ?? '0', 10);
  const remaining   = Math.max(0, cap - used);

  return Response.json({
    plan:    isPro ? 'pro' : 'free',
    limit:   cap,
    used,
    remaining,
    resetAt: nextMonthResetUTC(tz).toISOString(),
  });
}

function freeStub() {
  return { plan: 'free', limit: FREE_CAP, used: 0, remaining: FREE_CAP, resetAt: new Date().toISOString() };
}

// Timezone helpers live in ../../lib/quota.js.
