# Cloudflare Pages

Universal Link host + rich-link preview for recipe sharing.

## Routes

- `/` static landing page.
- `/r/<id>` recipe preview HTML + Open Graph tags.
- `/img/<id>` first-photo proxy (image sniffing + 10 MB cap).
- `/list/<recordName>` shared grocery list, read-only. Renders a
  `GroceryListShare` record grouped by aisle with check state. Ships **zero
  JavaScript** (CSP `default-src 'none'`, no `script-src`); the web
  write-back endpoints (`/api/list-check`, `/api/list-note`) are a
  follow-up. **Not yet reachable from the app** — nothing generates this URL
  (only `/r/<id>` recipe links exist), so it needs a "Copy link" affordance
  before it's a real user-facing surface.
- `/.well-known/apple-app-site-association` Universal Links file.
- `/llama-icon.png` fallback image.

## Tests

`npm test` (Vitest v3, Node ≥ 20) — 115 tests across `quota`, `moderation`,
`grocery`, and `list-page`. `lib/grocery.js` and `lib/moderation.js` are pure
and carry the bulk of the coverage.

## Env (Production + Preview)

- `CLOUDKIT_CONTAINER_ID = iCloud.com.llamascookbook.app`
- `CLOUDKIT_KEY_ID`
- `CLOUDKIT_PRIVATE_KEY` (encrypted secret)
- `CLOUDKIT_ENVIRONMENT = production`

## Security

- `RecipeShare` is public/unlisted.
- `/r` and `/img` accept legacy 6-char and current 12-char IDs only.
- `/img` validates image bytes, not just `content-type`.
- `_headers` supplies baseline security headers + AASA content type.
- **Every field rendered from CloudKit is untrusted.** Any signed-in iCloud
  user can write these public records, so `/r` and `/list` HTML-escape every
  user-controlled value AND screen names through `lib/moderation.js`
  (`sanitizedOr`). On `/list` that means the list title, every item name,
  each substitution, and `ownerName`. Keep the JS word list in sync with
  `ios-native/Sources/Lib/ContentModeration.swift`.

## Known issue

`functions/r/[id].js` sets `<meta name="apple-itunes-app"
content="app-id=com.llamascookbook.app">`. The Smart App Banner needs the
**numeric** App Store id (`6762527184`) — Safari silently drops a
non-numeric one, so that banner has never rendered. `functions/list/[id].js`
was fixed 2026-08-09; `/r` still needs the same change.

## Verify

- `https://llamascookbook.pages.dev/.well-known/apple-app-site-association`
- `https://llamascookbook.pages.dev/r/<id>`
- `https://llamascookbook.pages.dev/img/<id>`
- `https://llamascookbook.pages.dev/list/<recordName>`
- Universal Link opens the app on a real iPhone.
