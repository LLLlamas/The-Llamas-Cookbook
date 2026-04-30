# Cloudflare Pages

Rich-link preview and Universal Link host for recipe sharing.

## Routes

- `/` static landing page.
- `/r/<id>` recipe preview HTML and Open Graph tags.
- `/img/<id>` first-photo proxy with image sniffing and size cap.
- `/.well-known/apple-app-site-association` Universal Links file.
- `/llama-icon.png` fallback image.

## Environment

Set in Cloudflare Pages for Production and Preview:

- `CLOUDKIT_CONTAINER_ID=iCloud.com.llamascookbook.app`
- `CLOUDKIT_KEY_ID`
- `CLOUDKIT_PRIVATE_KEY` as encrypted secret
- `CLOUDKIT_ENVIRONMENT=production`

## Security Notes

- Share records are public/unlisted.
- `/r` and `/img` accept legacy 6-char and current 12-char IDs only.
- `img` route validates image bytes, not just `content-type`.
- `_headers` supplies baseline security headers and AASA content type.

## Verify

- `https://llamascookbook.pages.dev/.well-known/apple-app-site-association`
- `https://llamascookbook.pages.dev/r/<real-id>`
- `https://llamascookbook.pages.dev/img/<real-id>`
- Universal Link opens the app on a real iPhone.
