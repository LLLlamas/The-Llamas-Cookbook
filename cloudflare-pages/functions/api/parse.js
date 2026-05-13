// /api/parse — Anthropic API proxy for recipe parsing.
//
// Phase 1: Added per-user quota enforcement and KV parse-result caching
// for photo imports. Text/link/paste imports are unchanged (no quota).
//
// Photo import flow:
//   1. Compute SHA-256 content hash of image data for cache key.
//   2. Cache hit  → run monthly quota pre-check; return cached response
//      with x-llamas-cache: hit header (no parse counter tick, no API cost).
//   3. Cache miss → increment daily parse counter, check daily limit (429),
//      check monthly quota (402), forward to Anthropic, cache on success.
//
// Cloudflare Pages env vars required:
//   ANTHROPIC_API_KEY  (encrypted)
//   LLAMAS_QUOTA       (KV namespace binding)

const ANTHROPIC_URL  = 'https://api.anthropic.com/v1/messages';
const PROMPT_VERSION = 'v1'; // Bump when RecipeAIParser.instructions changes
const DAILY_LIMIT    = 5;
const FREE_CAP       = 5;
const PRO_CAP        = 30;

export async function onRequestPost(context) {
  const { request, env } = context;

  const apiKey = env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return new Response('Service unavailable', { status: 503 });
  }

  const importKind = request.headers.get('x-llamas-import-kind') ?? 'text';

  if (importKind !== 'photo') {
    // Text / link / paste imports: forward unchanged, no quota.
    const body = await request.arrayBuffer();
    const upstream = await fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers: buildAnthropicHeaders(request, apiKey),
      body,
    });
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { 'content-type': 'application/json' },
    });
  }

  // ── Photo import path ──────────────────────────────────────────────────────

  const userId = request.headers.get('x-llamas-user');
  if (!userId) {
    return Response.json({ error: 'auth_required' }, { status: 401 });
  }

  const tz    = request.headers.get('x-llamas-tz') ?? 'UTC';
  const quota = env.LLAMAS_QUOTA;

  if (!quota) {
    // KV not bound (dev environment without wrangler binding) — allow through.
    console.warn('LLAMAS_QUOTA KV not bound; skipping quota enforcement');
    const body = await request.arrayBuffer();
    const upstream = await fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers: buildAnthropicHeaders(request, apiKey),
      body,
    });
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { 'content-type': 'application/json', 'x-llamas-cache': 'miss' },
    });
  }

  // Parse request body once — we need it for image hashes and to re-forward.
  const rawBody = await request.arrayBuffer();
  let requestBody;
  try {
    requestBody = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    return Response.json({ error: 'invalid_request' }, { status: 400 });
  }

  // ── 1. Cache lookup ────────────────────────────────────────────────────────

  const imageHashes  = await extractImageHashes(requestBody);
  const contentHash  = imageHashes.length ? await computeContentHash(imageHashes) : null;
  const cacheKey     = contentHash ? `parseCache:${PROMPT_VERSION}:${contentHash}` : null;

  if (cacheKey) {
    const cached = await quota.get(cacheKey);
    if (cached) {
      // Cache hit: quota pre-check only, no parse counter tick.
      const quotaCheck = await checkMonthlyQuota(quota, userId, tz);
      if (quotaCheck.exhausted) {
        return Response.json(quotaCheck.errorBody, { status: 402 });
      }
      return new Response(cached, {
        status: 200,
        headers: { 'content-type': 'application/json', 'x-llamas-cache': 'hit' },
      });
    }
  }

  // ── 2. Cache miss: increment daily counter, then check limits ─────────────

  const localDate  = getLocalDate(tz);
  const parseKey   = `parseAttempts:${userId}:${localDate}`;
  const parsesUsed = parseInt((await quota.get(parseKey)) ?? '0', 10);

  // Increment BEFORE checking so rejected attempts still burn the counter.
  await quota.put(parseKey, String(parsesUsed + 1), { expirationTtl: 36 * 60 * 60 });

  if (parsesUsed >= DAILY_LIMIT) {
    const resetAt = nextLocalMidnightUTC(tz);
    return Response.json(
      { error: 'daily_parse_limit', limit: DAILY_LIMIT, resetAt: resetAt.toISOString() },
      { status: 429 },
    );
  }

  // Monthly quota pre-check (fails fast before burning Anthropic tokens).
  const quotaCheck = await checkMonthlyQuota(quota, userId, tz);
  if (quotaCheck.exhausted) {
    return Response.json(quotaCheck.errorBody, { status: 402 });
  }

  // ── 3. Forward to Anthropic ────────────────────────────────────────────────

  const upstream = await fetch(ANTHROPIC_URL, {
    method: 'POST',
    headers: buildAnthropicHeaders(request, apiKey),
    body: rawBody,
  });

  if (upstream.status !== 200 || !cacheKey) {
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { 'content-type': 'application/json', 'x-llamas-cache': 'miss' },
    });
  }

  // ── 4. Cache successful responses ─────────────────────────────────────────

  const responseText = await upstream.text();
  let responseBody;
  try { responseBody = JSON.parse(responseText); } catch { responseBody = null; }

  // Only cache responses that contain a valid structured_recipe tool_use block.
  if (responseBody && hasValidToolUse(responseBody)) {
    await quota.put(cacheKey, responseText, { expirationTtl: 7 * 24 * 60 * 60 });
  }

  return new Response(responseText, {
    status: 200,
    headers: { 'content-type': 'application/json', 'x-llamas-cache': 'miss' },
  });
}

// ── Quota helpers ─────────────────────────────────────────────────────────────

async function checkMonthlyQuota(quota, userId, tz) {
  const isPro     = (await quota.get(`pro:${userId}`)) === 'active';
  const cap       = isPro ? PRO_CAP : FREE_CAP;
  const savesKey  = `saves:${userId}:${getLocalYYYYMM(tz)}`;
  const used      = parseInt((await quota.get(savesKey)) ?? '0', 10);

  if (used >= cap) {
    const resetAt = nextMonthResetUTC(tz);
    return {
      exhausted: true,
      errorBody: {
        error: 'quota_exhausted',
        plan:  isPro ? 'pro' : 'free',
        limit: cap,
        used,
        resetAt: resetAt.toISOString(),
      },
    };
  }
  return { exhausted: false };
}

// ── Request builder ───────────────────────────────────────────────────────────

function buildAnthropicHeaders(request, apiKey) {
  return {
    'content-type':    'application/json',
    'x-api-key':       apiKey,
    'anthropic-version': request.headers.get('anthropic-version') ?? '2023-06-01',
    'anthropic-beta':  request.headers.get('anthropic-beta') ?? '',
  };
}

// ── Image hash helpers ────────────────────────────────────────────────────────

async function sha256Hex(data) {
  const buf   = await crypto.subtle.digest('SHA-256', data);
  const bytes = new Uint8Array(buf);
  return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function extractImageHashes(requestBody) {
  try {
    const content = requestBody?.messages?.[0]?.content;
    if (!Array.isArray(content)) return [];
    const hashes = [];
    for (const block of content) {
      if (block?.type === 'image' && block?.source?.type === 'base64' && block?.source?.data) {
        const bytes = Uint8Array.from(atob(block.source.data), c => c.charCodeAt(0));
        hashes.push(await sha256Hex(bytes));
      }
    }
    return hashes;
  } catch {
    return [];
  }
}

async function computeContentHash(imageHashes) {
  const joined  = imageHashes.join(':');
  const encoded = new TextEncoder().encode(joined);
  return sha256Hex(encoded);
}

// ── Cache validation ──────────────────────────────────────────────────────────

function hasValidToolUse(responseBody) {
  try {
    return Array.isArray(responseBody?.content) &&
      responseBody.content.some(
        b => b?.type === 'tool_use' && b?.name === 'structured_recipe' && b?.input != null,
      );
  } catch {
    return false;
  }
}

// ── Timezone / date helpers ───────────────────────────────────────────────────

function getLocalDate(tz) {
  // Returns "YYYY-MM-DD" in the given IANA timezone.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date());
}

function getLocalYYYYMM(tz) {
  // Returns "YYYYMM" in the given IANA timezone.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit',
  }).format(new Date()).replace('-', '');
}

function getTimezoneOffsetMs(tz, date) {
  // Compute the UTC offset (in ms) for a timezone at a specific date by
  // comparing the ISO representation at UTC vs. the given zone.
  const fmt = t => new Intl.DateTimeFormat('en-CA', {
    timeZone: t,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
    hour12: false,
  }).formatToParts(date);

  const toParts = parts => {
    const g = type => parseInt(parts.find(p => p.type === type)?.value ?? '0', 10);
    return Date.UTC(g('year'), g('month') - 1, g('day'), g('hour'), g('minute'), g('second'));
  };

  return toParts(fmt(tz)) - toParts(fmt('UTC'));
}

function nextLocalMidnightUTC(tz) {
  // Returns a Date for the next local midnight in the given timezone.
  const now       = new Date();
  const localDate = getLocalDate(tz); // "2026-05-13"
  // Build "start of tomorrow local" as a UTC Date approximation.
  const [y, m, d] = localDate.split('-').map(Number);
  const tomorrowLocal = Date.UTC(y, m - 1, d + 1, 0, 0, 0);
  const candidate     = new Date(tomorrowLocal);
  const offsetMs      = getTimezoneOffsetMs(tz, candidate);
  return new Date(tomorrowLocal - offsetMs);
}

function nextMonthResetUTC(tz) {
  // Returns a Date for the 1st of next month at 00:00 in the given timezone.
  const localYM   = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit',
  }).format(new Date());
  const [y, m]    = localYM.split('-').map(Number);
  const nextYear  = m === 12 ? y + 1 : y;
  const nextMonth = m === 12 ? 1 : m + 1;
  const firstOfNextLocal = Date.UTC(nextYear, nextMonth - 1, 1, 0, 0, 0);
  const candidate        = new Date(firstOfNextLocal);
  const offsetMs         = getTimezoneOffsetMs(tz, candidate);
  return new Date(firstOfNextLocal - offsetMs);
}
