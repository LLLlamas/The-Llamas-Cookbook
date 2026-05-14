// /api/usage/consume — Increment the monthly save quota after a successful
// photo import save. Called fire-and-forget by the iOS client immediately
// after Recipe.new(from:) is inserted into SwiftData.
//
// POST /api/usage/consume
// Headers:
//   x-llamas-user  <SIWA sub>
//   x-llamas-tz    America/Los_Angeles
// Body: empty
//
// 200 → incremented; returns updated QuotaSnapshot.
// 402 → race-condition cap hit (recipe already saved locally — client shows
//        "this one's on us" banner and keeps the recipe).
// 401 → missing user header.

const FREE_CAP    = 5;
const PRO_CAP     = 30;
const DAILY_LIMIT = 999; // TEMP: disabled for testing — restore to 5 before App Store submission

export async function onRequestPost(context) {
  const { request, env } = context;

  const userId = request.headers.get('x-llamas-user');
  if (!userId) {
    return Response.json({ error: 'auth_required' }, { status: 401 });
  }

  const tz    = request.headers.get('x-llamas-tz') ?? 'UTC';
  const quota = env.LLAMAS_QUOTA;

  if (!quota) {
    // KV not bound — return a safe success stub so the save isn't blocked.
    return Response.json(freeStub(), { status: 200 });
  }

  const isPro       = (await quota.get(`pro:${userId}`)) === 'active';
  const cap         = isPro ? PRO_CAP : FREE_CAP;
  const localYYYYMM = getLocalYYYYMM(tz);
  const savesKey    = `saves:${userId}:${localYYYYMM}`;

  const currentCount = parseInt((await quota.get(savesKey)) ?? '0', 10);

  if (currentCount >= cap) {
    // Race condition: the user hit the cap between the pre-check (in /api/parse)
    // and the save. The recipe already persisted locally — we return 402 and the
    // iOS client shows a one-time "this one's on us" banner.
    const resetAt = nextMonthResetUTC(tz);
    return Response.json({
      error:   'quota_exhausted',
      plan:    isPro ? 'pro' : 'free',
      limit:   cap,
      used:    currentCount,
      resetAt: resetAt.toISOString(),
    }, { status: 402 });
  }

  const newCount = currentCount + 1;
  // TTL: ~70 days (current month + ~40-day grace so month-boundary entries
  // stay readable during timezone rollover windows).
  await quota.put(savesKey, String(newCount), { expirationTtl: 70 * 24 * 60 * 60 });

  const localDate   = getLocalDate(tz);
  const parsesStr   = await quota.get(`parseAttempts:${userId}:${localDate}`);
  const dailyParses = parseInt(parsesStr ?? '0', 10);

  return Response.json({
    plan:              isPro ? 'pro' : 'free',
    limit:             cap,
    used:              newCount,
    remaining:         Math.max(0, cap - newCount),
    resetAt:           nextMonthResetUTC(tz).toISOString(),
    dailyParsesUsed:   dailyParses,
    dailyParseLimit:   DAILY_LIMIT,
    dailyParseResetAt: nextLocalMidnightUTC(tz).toISOString(),
  });
}

function freeStub() {
  return {
    plan: 'free', limit: FREE_CAP, used: 1, remaining: FREE_CAP - 1,
    resetAt: new Date().toISOString(),
    dailyParsesUsed: 1, dailyParseLimit: DAILY_LIMIT,
    dailyParseResetAt: new Date().toISOString(),
  };
}

// ── Shared timezone helpers ───────────────────────────────────────────────────

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
  const offsetMs      = getTimezoneOffsetMs(tz, candidate);
  return new Date(tomorrowLocal - offsetMs);
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
  const offsetMs         = getTimezoneOffsetMs(tz, candidate);
  return new Date(firstOfNextLocal - offsetMs);
}
