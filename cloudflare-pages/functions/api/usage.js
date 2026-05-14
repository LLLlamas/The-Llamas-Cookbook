// /api/usage — Read-only quota snapshot for the current user.
//
// GET /api/usage
// Headers:
//   x-llamas-user  <SIWA sub>
//   x-llamas-tz    America/Los_Angeles  (IANA timezone)
//
// Response 200:
//   { plan, limit, used, remaining, resetAt, dailyParsesUsed, dailyParseLimit, dailyParseResetAt }
//
// iOS client calls this on import-sheet open and after each consume call.
// 60-second client-side cache prevents chatter; no auth beyond x-llamas-user.

const FREE_CAP    = 5;
const PRO_CAP     = 30;
const DAILY_LIMIT = 999; // TEMP: disabled for testing — restore to 5 before App Store submission

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
  const localDate   = getLocalDate(tz);

  const [savesStr, parsesStr] = await Promise.all([
    quota.get(`saves:${userId}:${localYYYYMM}`),
    quota.get(`parseAttempts:${userId}:${localDate}`),
  ]);

  const used            = parseInt(savesStr ?? '0', 10);
  const remaining       = Math.max(0, cap - used);
  const dailyParsesUsed = parseInt(parsesStr ?? '0', 10);

  return Response.json({
    plan:               isPro ? 'pro' : 'free',
    limit:              cap,
    used,
    remaining,
    resetAt:            nextMonthResetUTC(tz).toISOString(),
    dailyParsesUsed,
    dailyParseLimit:    DAILY_LIMIT,
    dailyParseResetAt:  nextLocalMidnightUTC(tz).toISOString(),
  });
}

function freeStub() {
  return {
    plan: 'free', limit: FREE_CAP, used: 0, remaining: FREE_CAP,
    resetAt: new Date().toISOString(),
    dailyParsesUsed: 0, dailyParseLimit: DAILY_LIMIT,
    dailyParseResetAt: new Date().toISOString(),
  };
}

// ── Shared timezone helpers (duplicated from parse.js — no shared module) ────

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
  const localDate         = getLocalDate(tz);
  const [y, m, d]         = localDate.split('-').map(Number);
  const tomorrowLocal     = Date.UTC(y, m - 1, d + 1, 0, 0, 0);
  const candidate         = new Date(tomorrowLocal);
  const offsetMs          = getTimezoneOffsetMs(tz, candidate);
  return new Date(tomorrowLocal - offsetMs);
}

function nextMonthResetUTC(tz) {
  const localYM           = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit',
  }).format(new Date());
  const [y, m]            = localYM.split('-').map(Number);
  const nextYear          = m === 12 ? y + 1 : y;
  const nextMonth         = m === 12 ? 1 : m + 1;
  const firstOfNextLocal  = Date.UTC(nextYear, nextMonth - 1, 1, 0, 0, 0);
  const candidate         = new Date(firstOfNextLocal);
  const offsetMs          = getTimezoneOffsetMs(tz, candidate);
  return new Date(firstOfNextLocal - offsetMs);
}
