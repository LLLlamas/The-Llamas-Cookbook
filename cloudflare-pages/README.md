# Cloudflare Pages

Universal Link host + rich-link preview for recipe sharing.

## Routes

- `/` static landing page.
- `/r/<id>` recipe preview HTML + Open Graph tags.
- `/img/<id>` first-photo proxy (image sniffing + 10 MB cap).
- `/.well-known/apple-app-site-association` Universal Links file.
- `/llama-icon.png` fallback image.

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

## Verify

- `https://llamascookbook.pages.dev/.well-known/apple-app-site-association`
- `https://llamascookbook.pages.dev/r/<id>`
- `https://llamascookbook.pages.dev/img/<id>`
- Universal Link opens the app on a real iPhone.
