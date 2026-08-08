// /list/<recordName> — public web page for a shared grocery list.
//
// A friend without the app taps the share link and gets a clean, mobile
// shopping list (grouped by aisle, with check state + substitutions). The
// record is one `GroceryListShare` row in the world-readable public DB;
// we fetch it with the same server-to-server CloudKit client the recipe
// preview uses, parse it with the shared `lib/grocery.js` helpers, and
// render static HTML.
//
// Read-only for now: the app + in-app friends drive live check-offs; the
// web write-back endpoints (/api/list-check, /api/list-note) are a
// follow-up. The page therefore ships ZERO JavaScript (CSP `default-src
// 'none'`, no `script-src`).
//
// SECURITY: the public DB is world-WRITABLE, so every field here is
// untrusted. The list title + each item name are screened through
// `lib/moderation.js` (a profane title/name renders as a neutral
// placeholder), and EVERY user-controlled value is HTML-escaped before it
// reaches the markup.

import { fetchShareRecord } from '../../lib/cloudkit.js';
import { parseGroceryRecord, groupByAisle, measureText, displayName } from '../../lib/grocery.js';
import { sanitizedOr } from '../../lib/moderation.js';

// CloudKit record names are short server-issued tokens; bound the shape so
// obvious garbage never reaches the lookup.
const RECORD_NAME_RE = /^[A-Za-z0-9._-]{1,128}$/;

// Fallback origin for absolute URLs (og:image / og:url) when the caller
// doesn't supply one — matches `CloudKitService.shareLinkHost`.
const CANONICAL_ORIGIN = 'https://llamascookbook.pages.dev';

// Numeric App Store id (NOT the bundle id — a Smart App Banner with a
// non-numeric `app-id` is silently dropped by Safari).
const APP_STORE_ID = '6762527184';

export async function onRequest(context) {
  const { env, params, request } = context;
  const recordName = (params.id || '').trim();

  if (!recordName || !RECORD_NAME_RE.test(recordName)) {
    return notFound();
  }

  let parsed = null;
  try {
    const record = await fetchShareRecord(recordName, env);
    if (record) parsed = parseGroceryRecord(record);
  } catch (err) {
    console.error('CloudKit lookup failed for grocery list:', err);
    return errorPage();
  }

  if (!parsed) return notFound();

  let origin = CANONICAL_ORIGIN;
  try {
    origin = new URL(request.url).origin;
  } catch {
    // Keep the canonical fallback.
  }

  const html = renderListHTML(parsed, {
    origin,
    url: `${origin}/list/${recordName}`,
    now: Date.now(),
  });
  return new Response(html, {
    headers: {
      'content-type': 'text/html;charset=UTF-8',
      // A shared list changes as items are checked off, so keep the cache
      // short — a stale render for ~30s is fine, an hour is not.
      'cache-control': 'public, max-age=30, must-revalidate',
      ...securityHeaders(),
    },
  });
}

// Exported for tests (the Pages router only invokes `onRequest`).
//
// `opts.now` is injected rather than read from the clock so the
// "updated N minutes ago" line is deterministic under test.
export function renderListHTML(
  { title, items, ownerName = '', updatedAt = null },
  { origin = CANONICAL_ORIGIN, url = '', now = Date.now() } = {}
) {
  const safeTitle = escapeHTML(sanitizedOr(title, 'Grocery List'));
  const sections = groupByAisle(items);
  const showAisles = sections.length > 1;

  const total = items.length;
  const checked = items.reduce((n, it) => n + (it.checked ? 1 : 0), 0);
  const remaining = total - checked;
  const progressLabel = total === 0
    ? 'No items yet'
    : remaining === 0
      ? `All set — ${total} ${plural(total, 'item')} ✓`
      : `${remaining} of ${total} still to buy`;

  // Provenance line: who shared it + how fresh the render is. The page is
  // edge-cached for 30s, so "updated just now" is the honest ceiling.
  const owner = sanitizedOr(String(ownerName).trim(), '');
  const freshness = relativeTime(updatedAt, now);
  const subheadParts = [];
  if (owner) subheadParts.push(`Shared by ${escapeHTML(owner)}`);
  if (freshness) subheadParts.push(escapeHTML(freshness));
  const subheadHTML = subheadParts.length
    ? `<p class="subhead">${subheadParts.join(' &middot; ')}</p>`
    : '';

  const sectionsHTML = sections.map((section, i) => {
    const headingID = `aisle-${i}`;
    const header = showAisles
      ? `<h2 class="aisle" id="${headingID}">${escapeHTML(section.aisle)}</h2>`
      : '';
    const rows = section.items.map(renderItem).join('');
    // Each aisle is its own landmark so a screen reader announces
    // "Produce, list, 4 items" instead of one undifferentiated run.
    const labelledBy = showAisles ? ` aria-labelledby="${headingID}"` : '';
    return `<section${labelledBy}>${header}<ul class="items">${rows}</ul></section>`;
  }).join('');

  const body = total === 0
    ? `<p class="empty">This list doesn't have any items yet.</p>`
    : sectionsHTML;

  const ogImage = `${origin}/llama-icon.png`;
  const ogDescription = total === 0
    ? 'A shared grocery list from Llamas Cookbook.'
    : `${progressLabel} — tap to shop it.`;
  const canonical = url ? `\n  <link rel="canonical" href="${escapeHTML(url)}">` : '';
  const ogURL = url ? `\n  <meta property="og:url" content="${escapeHTML(url)}">` : '';

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${safeTitle} — Llamas Cookbook</title>
  <meta name="description" content="${escapeHTML(ogDescription)}">
  <meta name="theme-color" content="#faf7f2" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#1f1a14" media="(prefers-color-scheme: dark)">
  <meta property="og:title" content="${safeTitle}">
  <meta property="og:description" content="${escapeHTML(ogDescription)}">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="Llamas Cookbook">
  <meta property="og:image" content="${escapeHTML(ogImage)}">${ogURL}
  <meta name="twitter:card" content="summary">
  <meta name="twitter:title" content="${safeTitle}">
  <meta name="twitter:description" content="${escapeHTML(ogDescription)}">
  <meta name="twitter:image" content="${escapeHTML(ogImage)}">
  <meta name="apple-itunes-app" content="app-id=${APP_STORE_ID}">
  <link rel="icon" type="image/png" href="/llama-icon.png">${canonical}
  <style>
    :root {
      color-scheme: light dark;
      --bg: #faf7f2; --bg-alt: #fffdf8; --line: #ece3d6;
      --text: #3a2d1e; --text-soft: #6b5d4a; --text-mute: #9b8d78;
      --accent: #c2755d; --accent-soft: rgba(194,117,93,.12);
      --done: #6f8f6f; --done-soft: rgba(111,143,111,.14);
      --warn: #b5613c; --shadow: rgba(58,45,30,.08);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1f1a14; --bg-alt: #29221b; --line: #3a3026;
        --text: #f3eee5; --text-soft: #b8a892; --text-mute: #8a7c68;
        --accent: #e89379; --accent-soft: rgba(232,147,121,.16);
        --done: #9bbd9b; --done-soft: rgba(155,189,155,.18);
        --warn: #e0875f; --shadow: rgba(0,0,0,.5);
      }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro", "Segoe UI", Roboto, sans-serif;
      background: var(--bg); color: var(--text);
      padding: 28px 16px 64px; line-height: 1.4;
    }
    main { max-width: 480px; margin: 0 auto; }
    header { text-align: center; margin-bottom: 22px; }
    .logo { width: 44px; height: 44px; margin: 0 auto 10px; display: block; }
    h1 { font-size: 26px; margin: 0 0 6px; letter-spacing: -.01em;
      overflow-wrap: anywhere; }
    .progress {
      display: inline-block; font-size: 13px; font-weight: 600;
      color: var(--accent); background: var(--accent-soft);
      padding: 5px 12px; border-radius: 999px;
    }
    .progress.done { color: var(--done); background: var(--done-soft); }
    .subhead {
      margin: 10px 0 0; font-size: 13px; color: var(--text-mute);
      overflow-wrap: anywhere;
    }
    section { margin: 0; }
    .aisle {
      font-size: 12px; font-weight: 700; text-transform: uppercase;
      letter-spacing: .06em; color: var(--text-mute);
      margin: 22px 4px 8px;
    }
    section:first-of-type .aisle { margin-top: 0; }
    ul.items { list-style: none; margin: 0; padding: 0;
      background: var(--bg-alt); border-radius: 16px;
      box-shadow: 0 8px 24px var(--shadow); overflow: hidden; }
    li.item {
      display: flex; align-items: flex-start; gap: 12px;
      padding: 13px 16px; border-top: 1px solid var(--line);
    }
    li.item:first-child { border-top: none; }
    .check {
      flex: 0 0 auto; width: 22px; height: 22px; margin-top: 1px;
      border-radius: 50%; border: 2px solid var(--line);
      display: flex; align-items: center; justify-content: center;
      font-size: 13px; font-weight: 700; color: #fff; line-height: 1;
    }
    /* Green, matching the app's in-cart check — the accent is reserved
       for interactive/brand chrome. */
    .check.on { background: var(--done); border-color: var(--done); }
    .body { flex: 1 1 auto; min-width: 0; }
    /* Break anywhere so a pasted 60-character item name wraps instead of
       forcing the card wider than the viewport. */
    .name { font-size: 16px; font-weight: 600; overflow-wrap: anywhere; }
    .measure { color: var(--text-mute); font-weight: 500; }
    li.checked .name, li.checked .measure { color: var(--text-mute); text-decoration: line-through; }
    .note { font-size: 13px; font-weight: 600; margin-top: 2px;
      overflow-wrap: anywhere; }
    .note.swap { color: var(--done); }
    .note.oos { color: var(--warn); }
    .empty { text-align: center; color: var(--text-soft); padding: 40px 0; }
    footer { text-align: center; margin-top: 28px; color: var(--text-mute); font-size: 13px; }
    footer a { color: var(--accent); text-decoration: none; font-weight: 600; }
    /* Screen-reader-only check state — the ✓ glyph is decorative. */
    .sr { position: absolute; width: 1px; height: 1px; padding: 0;
      margin: -1px; overflow: hidden; clip: rect(0 0 0 0);
      white-space: nowrap; border: 0; }
  </style>
</head>
<body>
  <main>
    <header>
      <img class="logo" src="/llama-icon.png" alt="" width="44" height="44">
      <h1>${safeTitle}</h1>
      <span class="progress${remaining === 0 && total > 0 ? ' done' : ''}">${escapeHTML(progressLabel)}</span>
      ${subheadHTML}
    </header>
    ${body}
    <footer>
      Shared from <a href="/">Llamas Cookbook</a>
    </footer>
  </main>
</body>
</html>`;
}

function renderItem(item) {
  // Screen the RAW name, then title-case for display, then escape — the
  // moderation check must see the original text, and escaping stays last.
  const safeName = escapeHTML(displayName(sanitizedOr(item.name, 'Item')));
  const measure = escapeHTML(measureText(item));
  const measureHTML = measure ? `<span class="measure">${measure} </span>` : '';

  let noteHTML = '';
  if (item.substitution) {
    noteHTML = `<div class="note swap">→ ${escapeHTML(sanitizedOr(item.substitution, 'a swap'))}</div>`;
  } else if (item.outOfStock) {
    noteHTML = `<div class="note oos">Couldn't find it</div>`;
  }

  // `.body` / `.name` are divs, not spans: `.note` is a block-level child,
  // and a <div> inside a <span> is invalid markup browsers only recover
  // from by accident.
  return `<li class="item${item.checked ? ' checked' : ''}">
    <span class="check${item.checked ? ' on' : ''}" aria-hidden="true">${item.checked ? '✓' : ''}</span>
    <div class="body"><span class="sr">${item.checked ? 'In cart: ' : 'To buy: '}</span><div class="name">${measureHTML}${safeName}</div>${noteHTML}</div>
  </li>`;
}

function plural(n, word) {
  return n === 1 ? word : `${word}s`;
}

/**
 * Coarse "how fresh is this render" label. Exported for tests.
 *
 * Deliberately blunt: the page is edge-cached for 30s and a shopper only
 * needs "is this current or is this yesterday's list", so the buckets stop
 * at day granularity and fall back to an absolute date. Returns '' when
 * there's no usable timestamp (older records predate the field) or when it
 * is implausibly in the future — better to say nothing than to lie.
 */
export function relativeTime(timestampMs, now) {
  if (!Number.isFinite(timestampMs) || !Number.isFinite(now)) return '';
  const deltaSec = Math.round((now - timestampMs) / 1000);
  // Small negative drift (clock skew between CloudKit and the edge) reads
  // as "just now"; anything wildly future-dated is untrustworthy.
  if (deltaSec < -300) return '';
  if (deltaSec < 90) return 'updated just now';
  const minutes = Math.round(deltaSec / 60);
  if (minutes < 60) return `updated ${minutes} min ago`;
  const hours = Math.round(deltaSec / 3600);
  if (hours < 24) return `updated ${hours} ${plural(hours, 'hour')} ago`;
  const days = Math.round(deltaSec / 86400);
  if (days <= 6) return `updated ${days} ${plural(days, 'day')} ago`;
  const date = new Date(timestampMs);
  if (Number.isNaN(date.getTime())) return '';
  return `updated ${date.toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC',
  })}`;
}

function notFound() {
  return new Response(
    `<!DOCTYPE html><html><head><title>List not found</title><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head><body style="font-family:-apple-system,sans-serif;text-align:center;padding:80px 20px;color:#3a2d1e;background:#faf7f2;"><h1>List not found</h1><p>This link doesn't point at a shared grocery list (it may have been deleted).</p></body></html>`,
    { status: 404, headers: { 'content-type': 'text/html;charset=UTF-8', ...securityHeaders() } }
  );
}

function errorPage() {
  return new Response(
    `<!DOCTYPE html><html><head><title>Couldn't load list</title><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head><body style="font-family:-apple-system,sans-serif;text-align:center;padding:80px 20px;color:#3a2d1e;background:#faf7f2;"><h1>Couldn't load this list</h1><p>Something went wrong fetching it. Please try again in a moment.</p></body></html>`,
    { status: 502, headers: { 'content-type': 'text/html;charset=UTF-8', ...securityHeaders() } }
  );
}

function securityHeaders() {
  return {
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'permissions-policy': 'camera=(), microphone=(), geolocation=()',
    'content-security-policy': [
      "default-src 'none'",
      "img-src 'self' data:",
      "style-src 'unsafe-inline'",
      "base-uri 'none'",
      "form-action 'none'",
      "frame-ancestors 'none'",
    ].join('; '),
  };
}

function escapeHTML(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
