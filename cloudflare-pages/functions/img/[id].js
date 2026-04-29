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

export async function onRequest(context) {
  const { request, env, params } = context;
  const recordName = (params.id || '').trim();

  const requestURL = new URL(request.url);
  const fallbackURL = `${requestURL.origin}/llama-icon.png`;

  if (!recordName || !/^[A-Z0-9]{4,32}$/.test(recordName)) {
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

  // Fetch the bytes from CloudKit's CDN. Stream the response back
  // so a large photo doesn't materialize fully in Worker memory.
  let upstream;
  try {
    upstream = await fetch(photoURL);
  } catch (err) {
    console.error('Photo fetch failed:', err);
    return Response.redirect(fallbackURL, 302);
  }

  if (!upstream.ok) {
    console.error(`Photo fetch returned ${upstream.status} for ${recordName}`);
    return Response.redirect(fallbackURL, 302);
  }

  const contentType =
    upstream.headers.get('content-type') || 'image/jpeg';

  // Cache aggressively at the edge — RecipeShare records are
  // immutable. 1-day max-age + stale-while-revalidate covers the
  // delete-account window without re-hitting CloudKit on every
  // preview scrape.
  return new Response(upstream.body, {
    headers: {
      'content-type': contentType,
      'cache-control': 'public, max-age=86400, stale-while-revalidate=604800',
    },
  });
}
