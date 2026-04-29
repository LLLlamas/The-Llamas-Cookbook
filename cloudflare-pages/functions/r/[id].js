// /r/<recordName> — recipe-share preview page.
//
// Two audiences:
//   1. iMessage / Mail / AirDrop / Slack / etc. link-preview scrapers.
//      They read the OG meta tags below to render the rich-link bubble
//      on the recipient's side. og:image points at /img/<id> (a sibling
//      Pages Function) so the preview thumbnail is the actual recipe
//      photo when one exists, llama logo otherwise.
//   2. Humans tapping the link without the app installed. They get the
//      same HTML as a friendly landing page with a "Get the app" CTA.
//
// When the recipient HAS the app installed and taps the bubble, iOS
// validates the AASA file (served from /.well-known/) and opens the
// URL directly in the app, bypassing this page entirely. So this
// function is mostly serving link-preview scrapers + non-iOS users.

import { fetchShareRecord, extractPreviewFields } from '../../lib/cloudkit.js';

export async function onRequest(context) {
  const { request, env, params } = context;
  const recordName = (params.id || '').trim();

  // Defensive: record names are 6 chars from a fixed alphanumeric
  // alphabet. Anything else is either a typo or an attacker probing
  // — short-circuit to 404 before hitting CloudKit.
  if (!recordName || !/^[A-Z0-9]{4,32}$/.test(recordName)) {
    return notFoundHTML();
  }

  const requestURL = new URL(request.url);
  const origin = requestURL.origin;

  let title = 'A Recipe';
  let hasPhoto = false;

  try {
    const record = await fetchShareRecord(recordName, env);
    if (record) {
      const fields = extractPreviewFields(record);
      if (fields.title) title = fields.title;
      if (fields.photoURL) hasPhoto = true;
    }
  } catch (err) {
    // Log to Cloudflare's request log but degrade gracefully — a
    // generic preview is better than a hard 500 when CloudKit is
    // having a moment.
    console.error('CloudKit lookup failed:', err);
  }

  // og:image points at the sibling /img/<id> proxy rather than the
  // CloudKit downloadURL directly. Two reasons: (1) downloadURLs are
  // signed with tokens that may expire, and Messages caches the URL
  // not the bytes; (2) Cloudflare can edge-cache the proxied
  // response, so repeated previews don't re-hit CloudKit.
  const ogImageURL = hasPhoto
    ? `${origin}/img/${recordName}`
    : `${origin}/llama-icon.png`;

  const html = renderHTML({
    title,
    description: "A recipe from Llamas Cookbook",
    ogImage: ogImageURL,
    pageURL: requestURL.toString(),
    appURL: `llamascookbook://share/${recordName}`,
  });

  return new Response(html, {
    headers: {
      'content-type': 'text/html;charset=UTF-8',
      // Edge-cache for an hour. RecipeShare records are immutable
      // (we never update them), so the only invalidation event is
      // a delete-account cascade; a stale hour is harmless.
      'cache-control': 'public, max-age=3600',
    },
  });
}

function renderHTML({ title, description, ogImage, pageURL, appURL }) {
  const safeTitle = escapeHTML(title);
  const safeDesc = escapeHTML(description);
  const safeOgImage = escapeHTML(ogImage);
  const safePageURL = escapeHTML(pageURL);
  const safeAppURL = escapeHTML(appURL);

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${safeTitle} — Llamas Cookbook</title>
  <meta name="description" content="${safeDesc}">

  <!-- Open Graph (Messages, Slack, Discord, Facebook, etc.) -->
  <meta property="og:title" content="${safeTitle}">
  <meta property="og:description" content="${safeDesc}">
  <meta property="og:image" content="${safeOgImage}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="1200">
  <meta property="og:type" content="website">
  <meta property="og:url" content="${safePageURL}">
  <meta property="og:site_name" content="Llamas Cookbook">

  <!-- Twitter Card (iMessage rich preview also reads these as fallback) -->
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${safeTitle}">
  <meta name="twitter:description" content="${safeDesc}">
  <meta name="twitter:image" content="${safeOgImage}">

  <!-- iOS Smart App Banner — shows a thin "Open in app" bar on Safari -->
  <!-- when the app is installed. Bundle ID matches the AASA file. -->
  <meta name="apple-itunes-app" content="app-id=com.llamascookbook.app">

  <link rel="icon" type="image/png" href="/llama-icon.png">

  <style>
    :root {
      color-scheme: light dark;
      --bg: #faf7f2;
      --bg-alt: #f3eee5;
      --text: #3a2d1e;
      --text-soft: #6b5d4a;
      --accent: #c2755d;
      --accent-soft: rgba(194, 117, 93, 0.12);
      --shadow: rgba(58, 45, 30, 0.08);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1f1a14;
        --bg-alt: #29221b;
        --text: #f3eee5;
        --text-soft: #b8a892;
        --accent: #e89379;
        --accent-soft: rgba(232, 147, 121, 0.16);
        --shadow: rgba(0, 0, 0, 0.5);
      }
    }

    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro", "Segoe UI", Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 32px 20px;
    }
    .card {
      max-width: 460px;
      width: 100%;
      background: var(--bg-alt);
      border-radius: 24px;
      padding: 32px 28px;
      text-align: center;
      box-shadow: 0 20px 60px var(--shadow), 0 4px 12px var(--shadow);
    }
    .hero {
      width: 200px;
      height: 200px;
      object-fit: cover;
      border-radius: 20px;
      margin: 0 auto 20px;
      display: block;
      background: var(--accent-soft);
      box-shadow: 0 10px 30px var(--shadow);
    }
    h1 {
      font-family: "New York", "Iowan Old Style", Georgia, serif;
      font-size: 28px;
      line-height: 1.2;
      margin: 0 0 8px;
      color: var(--accent);
    }
    .subtitle {
      color: var(--text-soft);
      margin: 0 0 28px;
      font-size: 15px;
    }
    .cta {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 14px 28px;
      background: var(--accent);
      color: white;
      text-decoration: none;
      border-radius: 14px;
      font-weight: 600;
      font-size: 16px;
      box-shadow: 0 6px 20px var(--shadow);
      transition: transform 0.15s ease, box-shadow 0.15s ease;
    }
    .cta:hover { transform: translateY(-1px); box-shadow: 0 8px 24px var(--shadow); }
    .cta:active { transform: translateY(0); }
    .footer {
      margin-top: 32px;
      font-size: 13px;
      color: var(--text-soft);
    }
    .footer a { color: var(--accent); text-decoration: none; }
  </style>
</head>
<body>
  <main class="card">
    <img class="hero" src="${safeOgImage}" alt="${safeTitle}" loading="eager">
    <h1>${safeTitle}</h1>
    <p class="subtitle">A recipe from Llamas Cookbook</p>
    <a class="cta" href="${safeAppURL}">
      Open in app
    </a>
    <p class="footer">
      Don't have the app? Get Llamas Cookbook on the App&nbsp;Store.
    </p>
  </main>
</body>
</html>`;
}

function notFoundHTML() {
  return new Response(
    `<!DOCTYPE html><html><head><title>Recipe not found</title><meta charset="utf-8"></head><body style="font-family:-apple-system,sans-serif;text-align:center;padding:80px 20px;color:#3a2d1e;background:#faf7f2;"><h1>Recipe not found</h1><p>This share link doesn't point at a valid recipe.</p></body></html>`,
    { status: 404, headers: { 'content-type': 'text/html;charset=UTF-8' } }
  );
}

function escapeHTML(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
