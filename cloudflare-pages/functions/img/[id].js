// /img/<recordName> — recipe-photo proxy.
//
// Why proxy instead of pointing og:image straight at the CloudKit
// downloadURL: CKAsset downloadURLs are signed with tokens that
// rotate / expire, but Messages caches the og:image URL string
// (not the bytes) for the lifetime of the bubble. Proxying through
// our own host gives a stable URL that Cloudflare can edge-cache,
// and we re-resolve the CKAsset URL on every cache miss so the
// freshness problem belongs to us, not Apple.
//
// Falls back to /llama-icon.png on any failure (record not found,
// CloudKit error, asset missing, network blip) so the OG preview
// always renders something rather than a broken image.

import { fetchShareRecord, extractPreviewFields } from '../../lib/cloudkit.js';

const SHARE_RECORD_NAME_RE = /^(?:[A-HJ-NP-Z2-9]{6}|[A-HJ-NP-Z2-9]{12})$/;
const MAX_PROXY_IMAGE_BYTES = 10_000_000;

// Apple / iCloud hosts the proxy will fetch (and follow redirects to).
// Includes `icloud-content.com` — the actual CKAsset download CDN — plus
// the broader Apple CDN domains, so legitimate recipe photos always load
// while the proxy can't be steered into a blind fetch-relay against an
// arbitrary third-party host. Broad on purpose (every value is Apple), so
// it hardens the SSRF/redirect vector without risking a photo regression.
const ALLOWED_IMAGE_HOST = /(^|\.)(icloud-content|icloud|apple-cloudkit|cdn-apple|mzstatic|apple)\.com$/;
const MAX_REDIRECT_HOPS = 3;

function isAllowedImageURL(urlString) {
  try {
    const u = new URL(urlString);
    return u.protocol === 'https:' && ALLOWED_IMAGE_HOST.test(u.hostname);
  } catch {
    return false;
  }
}

export async function onRequest(context) {
  const { request, env, params } = context;
  const recordName = (params.id || '').trim();

  const requestURL = new URL(request.url);
  const fallbackURL = `${requestURL.origin}/llama-icon.png`;

  if (!recordName || !SHARE_RECORD_NAME_RE.test(recordName)) {
    return Response.redirect(fallbackURL, 302);
  }

  let photoURL = null;
  try {
    const record = await fetchShareRecord(recordName, env);
    if (record) {
      photoURL = extractPreviewFields(record).photoURL;
    }
  } catch (err) {
    console.error('CloudKit lookup failed for image proxy:', err);
  }

  if (!photoURL) {
    return Response.redirect(fallbackURL, 302);
  }

  // The downloadURL is Apple-minted, but we still refuse a non-Apple /
  // non-https initial target as defense in depth (the public DB is
  // world-writable).
  if (!isAllowedImageURL(photoURL)) {
    console.error(`Image proxy refusing non-allowlisted photo URL for ${recordName}`);
    return Response.redirect(fallbackURL, 302);
  }

  // Fetch the bytes from CloudKit's CDN. We cap by Content-Length
  // before reading, then sniff the first bytes instead of trusting
  // CloudKit's content-type (CKAsset temp files may be served as
  // application/octet-stream). Redirects are followed MANUALLY and only
  // to allowlisted Apple hosts — this closes the blind redirect-relay
  // SSRF vector while still working with assets that 30x to the iCloud CDN.
  let upstream;
  try {
    let nextURL = photoURL;
    let hops = 0;
    upstream = await fetch(nextURL, { redirect: 'manual' });
    while (upstream.status >= 300 && upstream.status < 400 && hops < MAX_REDIRECT_HOPS) {
      const location = upstream.headers.get('location');
      if (!location) break;
      nextURL = new URL(location, nextURL).toString();
      if (!isAllowedImageURL(nextURL)) {
        console.error(`Image proxy refusing redirect to non-allowlisted host for ${recordName}`);
        return Response.redirect(fallbackURL, 302);
      }
      upstream = await fetch(nextURL, { redirect: 'manual' });
      hops += 1;
    }
  } catch (err) {
    console.error('Photo fetch failed:', err);
    return Response.redirect(fallbackURL, 302);
  }

  if (!upstream.ok) {
    console.error(`Photo fetch returned ${upstream.status} for ${recordName}`);
    return Response.redirect(fallbackURL, 302);
  }

  const contentLength = parseContentLength(upstream.headers.get('content-length'));
  if (!contentLength || contentLength > MAX_PROXY_IMAGE_BYTES) {
    console.error(`Photo fetch returned invalid content-length ${contentLength || 'missing'} for ${recordName}`);
    return Response.redirect(fallbackURL, 302);
  }

  const imageBytes = await upstream.arrayBuffer();
  if (imageBytes.byteLength > MAX_PROXY_IMAGE_BYTES) {
    console.error(`Photo fetch exceeded byte cap for ${recordName}`);
    return Response.redirect(fallbackURL, 302);
  }

  const contentType = detectImageContentType(imageBytes);
  if (!contentType) {
    console.error(`Photo fetch returned non-image bytes for ${recordName}`);
    return Response.redirect(fallbackURL, 302);
  }

  // Cache aggressively at the edge — RecipeShare records are
  // immutable. 1-day max-age + stale-while-revalidate covers the
  // delete-account window without re-hitting CloudKit on every
  // preview scrape.
  return new Response(imageBytes, {
    headers: {
      'content-type': contentType,
      'cache-control': 'public, max-age=86400, stale-while-revalidate=604800',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
    },
  });
}

function parseContentLength(value) {
  if (!value) return null;
  const n = Number(value);
  return Number.isSafeInteger(n) && n > 0 ? n : null;
}

function detectImageContentType(buffer) {
  const bytes = new Uint8Array(buffer);

  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg';
  }

  if (
    bytes.length >= 8
    && bytes[0] === 0x89
    && bytes[1] === 0x50
    && bytes[2] === 0x4e
    && bytes[3] === 0x47
    && bytes[4] === 0x0d
    && bytes[5] === 0x0a
    && bytes[6] === 0x1a
    && bytes[7] === 0x0a
  ) {
    return 'image/png';
  }

  if (
    bytes.length >= 12
    && ascii(bytes, 0, 4) === 'RIFF'
    && ascii(bytes, 8, 12) === 'WEBP'
  ) {
    return 'image/webp';
  }

  if (bytes.length >= 12 && ascii(bytes, 4, 8) === 'ftyp') {
    const brand = ascii(bytes, 8, 12);
    if (['heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1'].includes(brand)) {
      return 'image/heic';
    }
  }

  return null;
}

function ascii(bytes, start, end) {
  return String.fromCharCode(...bytes.slice(start, end));
}
