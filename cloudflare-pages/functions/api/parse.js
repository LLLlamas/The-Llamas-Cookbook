// /api/parse — Anthropic API proxy for recipe parsing.
//
// The app sends the same JSON body it would send directly to Anthropic
// (model, messages, tools, etc.) but without an x-api-key header.
// This Worker injects the key from an env var and forwards the request,
// keeping the API key out of the app binary entirely.
//
// Cloudflare Pages env var required: ANTHROPIC_API_KEY (encrypted).

const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';

export async function onRequestPost(context) {
  const { request, env } = context;

  const apiKey = env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return new Response('Service unavailable', { status: 503 });
  }

  const body = await request.arrayBuffer();

  const upstream = await fetch(ANTHROPIC_URL, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': request.headers.get('anthropic-version') ?? '2023-06-01',
      'anthropic-beta': request.headers.get('anthropic-beta') ?? '',
    },
    body,
  });

  return new Response(upstream.body, {
    status: upstream.status,
    headers: { 'content-type': 'application/json' },
  });
}
