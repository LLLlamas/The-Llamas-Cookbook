// /api/parse — Anthropic API proxy for recipe parsing.
//
// Phase 1: Per-user quota enforcement + KV parse-result caching for
// photo imports. Text/link/paste imports are unchanged (no quota).
//
// Phase 2: Added model to photo cache key (prep for Haiku routing),
// upstream timing, and structured usage logging via console.log so
// Cloudflare Workers Logs captures cost/cache/latency per request.
// Logs never contain recipe text, image bytes, or raw user IDs.
//
// Phase 3 (streaming): Photo vision requests with `"stream": true` in
// the body are forwarded with stream:true and the SSE response is
// tee'd — one branch streams to the client, the other accumulates so
// we can parse the final tool_use block and write it to KV on success.
// Cache hits remain non-streaming (we serve the assembled JSON).
//
// Photo import flow:
//   1. Compute SHA-256 content hash of image data for cache key.
//   2. Cache hit  → run monthly quota pre-check; return cached response
//      with x-llamas-cache: hit header (no parse counter tick, no API cost,
//      non-streaming JSON body).
//   3. Cache miss + non-streaming → increment counters, forward, cache.
//   4. Cache miss + streaming     → increment counters, forward with
//      stream:true, tee SSE to client + accumulator, cache assembled
//      response on message_stop.
//
// Cloudflare Pages env vars required:
//   ANTHROPIC_API_KEY  (encrypted)
//   LLAMAS_QUOTA       (KV namespace binding)

const ANTHROPIC_URL  = 'https://api.anthropic.com/v1/messages';
const PROMPT_VERSION = 'v2'; // Bump when RecipeAIParser.instructions changes
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

  // Test bypass: skip all quota enforcement when the request presents the
  // correct secret. Set BYPASS_SECRET in Cloudflare Pages env vars (dev only).
  const bypassSecret = env.BYPASS_SECRET;
  if (bypassSecret && request.headers.get('x-llamas-bypass') === bypassSecret) {
    const body = await request.arrayBuffer();
    const upstream = await fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers: buildAnthropicHeaders(request, apiKey),
      body,
    });
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        'content-type': upstream.headers.get('content-type') ?? 'application/json',
        'x-llamas-cache': 'bypass',
      },
    });
  }

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

  const model           = requestBody?.model ?? 'unknown';
  const streamRequested = requestBody?.stream === true;

  // ── 1. Cache lookup ────────────────────────────────────────────────────────
  // Model is included in the key so Haiku and Sonnet responses are stored
  // separately — prevents a cheap-model result being served for a Sonnet call.
  // Cache entries are always stored as the assembled non-streaming JSON
  // (`messages.create` shape), regardless of whether the request that
  // populated them was streaming. Cache hits are returned non-streaming.

  const imageHashes  = await extractImageHashes(requestBody);
  const contentHash  = imageHashes.length ? await computeContentHash(imageHashes) : null;
  const cacheKey     = contentHash
    ? `parseCache:${PROMPT_VERSION}:model=${model}:${contentHash}`
    : null;

  if (cacheKey) {
    const cached = await quota.get(cacheKey);
    if (cached) {
      // Cache hit: quota pre-check only, no parse counter tick.
      const quotaCheck = await checkMonthlyQuota(quota, userId, tz);
      if (quotaCheck.exhausted) {
        return Response.json(quotaCheck.errorBody, { status: 402 });
      }
      const userHash = await truncatedHash(userId);
      console.log(JSON.stringify({
        import_kind: 'photo',
        model,
        page_count: countImageBlocks(requestBody),
        worker_cache: 'hit',
        user_hash: userHash,
      }));
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

  const upstreamStart = Date.now();
  const upstream = await fetch(ANTHROPIC_URL, {
    method: 'POST',
    headers: buildAnthropicHeaders(request, apiKey),
    body: rawBody,
  });
  const upstreamDurationMs = Date.now() - upstreamStart;

  const userHash = await truncatedHash(userId);
  const pageCount = countImageBlocks(requestBody);

  if (upstream.status !== 200) {
    console.log(JSON.stringify({
      import_kind: 'photo',
      model,
      page_count: pageCount,
      worker_cache: 'miss',
      upstream_status: upstream.status,
      upstream_duration_ms: upstreamDurationMs,
      stream_requested: streamRequested,
      has_valid_recipe: false,
      user_hash: userHash,
    }));
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { 'content-type': 'application/json', 'x-llamas-cache': 'miss' },
    });
  }

  // ── 4a. Streaming path: tee SSE → client + accumulator ────────────────────
  // The accumulator parses delta events to assemble the final tool_use
  // input as JSON. On message_stop we materialize the assembled response
  // in the same shape Anthropic returns for non-streaming calls and (on
  // valid tool_use) write it to KV. The accumulator runs in `waitUntil`
  // so cache writes don't block the streamed response to the client.

  if (streamRequested) {
    const [toClient, toCache] = upstream.body.tee();

    const cacheTask = (async () => {
      const assembled = await assembleStreamedResponse(toCache);
      if (!assembled) return;
      const hasRecipe = hasValidToolUse(assembled.body);
      if (hasRecipe && cacheKey) {
        await quota.put(
          cacheKey,
          JSON.stringify(assembled.body),
          { expirationTtl: 7 * 24 * 60 * 60 },
        );
      }
      console.log(JSON.stringify({
        import_kind: 'photo',
        model,
        page_count: pageCount,
        worker_cache: 'miss',
        upstream_status: 200,
        upstream_duration_ms: upstreamDurationMs,
        stream_requested: true,
        input_tokens: assembled.usage.input_tokens ?? 0,
        cache_creation_tokens: assembled.usage.cache_creation_input_tokens ?? 0,
        cache_read_tokens: assembled.usage.cache_read_input_tokens ?? 0,
        output_tokens: assembled.usage.output_tokens ?? 0,
        has_valid_recipe: hasRecipe,
        estimated_cost_usd: estimateCost(model, assembled.usage),
        user_hash: userHash,
      }));
    })();
    context.waitUntil(cacheTask);

    return new Response(toClient, {
      status: 200,
      headers: {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        'x-llamas-cache': 'miss',
      },
    });
  }

  // ── 4b. Non-streaming path: buffer, cache, return ─────────────────────────

  const responseText = await upstream.text();
  let responseBody;
  try { responseBody = JSON.parse(responseText); } catch { responseBody = null; }

  const hasRecipe = responseBody ? hasValidToolUse(responseBody) : false;

  if (hasRecipe && cacheKey) {
    await quota.put(cacheKey, responseText, { expirationTtl: 7 * 24 * 60 * 60 });
  }

  const usage = responseBody?.usage ?? {};
  console.log(JSON.stringify({
    import_kind: 'photo',
    model,
    page_count: pageCount,
    worker_cache: 'miss',
    upstream_status: 200,
    upstream_duration_ms: upstreamDurationMs,
    stream_requested: false,
    input_tokens: usage.input_tokens ?? 0,
    cache_creation_tokens: usage.cache_creation_input_tokens ?? 0,
    cache_read_tokens: usage.cache_read_input_tokens ?? 0,
    output_tokens: usage.output_tokens ?? 0,
    has_valid_recipe: hasRecipe,
    estimated_cost_usd: estimateCost(model, usage),
    user_hash: userHash,
  }));

  return new Response(responseText, {
    status: 200,
    headers: { 'content-type': 'application/json', 'x-llamas-cache': 'miss' },
  });
}

// ── Stream accumulator ────────────────────────────────────────────────────────

/// Read an Anthropic SSE stream and assemble the equivalent non-streaming
/// response body. Returns `{ body, usage }` on success or null on parse
/// failure. The assembled body matches the shape `messages.create` returns
/// for non-stream calls, so we can cache it once and serve cache hits as
/// plain JSON regardless of how the original was fetched.
async function assembleStreamedResponse(stream) {
  const reader  = stream.getReader();
  const decoder = new TextDecoder();
  let buffer    = '';
  let toolName  = null;
  let toolId    = null;
  let toolJson  = '';
  let stopReason = null;
  const usage   = {};
  let messageMeta = null;

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let idx;
      // SSE events are separated by \n\n. Walk through complete events.
      while ((idx = buffer.indexOf('\n\n')) !== -1) {
        const rawEvent = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);

        // Each event has `event: <name>` and `data: <json>` lines.
        let eventName = null;
        let dataStr   = '';
        for (const line of rawEvent.split('\n')) {
          if (line.startsWith('event:')) {
            eventName = line.slice(6).trim();
          } else if (line.startsWith('data:')) {
            dataStr += line.slice(5).trim();
          }
        }
        if (!eventName || !dataStr) continue;
        let payload;
        try { payload = JSON.parse(dataStr); } catch { continue; }

        switch (eventName) {
          case 'message_start':
            messageMeta = payload.message ?? null;
            Object.assign(usage, messageMeta?.usage ?? {});
            break;
          case 'content_block_start':
            if (payload.content_block?.type === 'tool_use') {
              toolName = payload.content_block.name ?? null;
              toolId   = payload.content_block.id ?? null;
            }
            break;
          case 'content_block_delta':
            if (payload.delta?.type === 'input_json_delta') {
              toolJson += payload.delta.partial_json ?? '';
            }
            break;
          case 'message_delta':
            if (payload.delta?.stop_reason) stopReason = payload.delta.stop_reason;
            if (payload.usage) {
              // Final usage carries the cumulative output_tokens; merge.
              Object.assign(usage, payload.usage);
            }
            break;
          default:
            break;
        }
      }
    }
  } catch (err) {
    return null;
  }

  // Parse the assembled tool_use JSON.
  let toolInput = null;
  if (toolName && toolJson) {
    try { toolInput = JSON.parse(toolJson); } catch { toolInput = null; }
  }
  if (!toolInput) return null;

  // Build the non-streaming response shape.
  const assembled = {
    id:    messageMeta?.id    ?? '',
    type:  'message',
    role:  'assistant',
    model: messageMeta?.model ?? '',
    content: [
      {
        type:  'tool_use',
        id:    toolId ?? '',
        name:  toolName,
        input: toolInput,
      },
    ],
    stop_reason:   stopReason ?? 'tool_use',
    stop_sequence: null,
    usage,
  };
  return { body: assembled, usage };
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

// ── Logging helpers ───────────────────────────────────────────────────────────

/// First 16 hex chars of the SHA-256 of the userId — enough to correlate
/// events for a single user without storing the raw SIWA sub in logs.
async function truncatedHash(value) {
  return (await sha256Hex(new TextEncoder().encode(value))).slice(0, 16);
}

/// Count image blocks in the user message (= number of photo pages).
function countImageBlocks(requestBody) {
  try {
    const content = requestBody?.messages?.[0]?.content;
    if (!Array.isArray(content)) return 0;
    return content.filter(b => b?.type === 'image').length;
  } catch { return 0; }
}

/// Estimate USD cost from Anthropic usage fields and model ID.
/// Uses official Anthropic pricing as of 2026-05-14.
function estimateCost(model, usage) {
  const isHaiku = model.includes('haiku');
  const rates = isHaiku
    ? { input: 1 / 1e6, cacheWrite: 1.25 / 1e6, cacheRead: 0.1 / 1e6, output: 5 / 1e6 }
    : { input: 3 / 1e6, cacheWrite: 3.75 / 1e6, cacheRead: 0.3 / 1e6, output: 15 / 1e6 };
  return (
    (usage.input_tokens ?? 0) * rates.input +
    (usage.cache_creation_input_tokens ?? 0) * rates.cacheWrite +
    (usage.cache_read_input_tokens ?? 0) * rates.cacheRead +
    (usage.output_tokens ?? 0) * rates.output
  );
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
