# Cloudflare Pages — Recipe Share Preview

Static + Functions deployment that powers the rich-link previews
recipients see when someone shares a recipe via the iOS app. Keeps
the iOS app itself out of any backend dependencies — the app only
knows how to upload to CloudKit and mint a `https://llamascookbook.pages.dev/r/<id>`
URL; this Pages project handles everything else.

## Routes

| Path | Served by | Purpose |
|---|---|---|
| `/` | `index.html` | Marketing landing page (anyone navigating to the bare host). |
| `/r/<recordName>` | `functions/r/[id].js` | OG-tagged HTML for link-preview scrapers + fallback web view for non-iOS users. Fetches the recipe from CloudKit. |
| `/img/<recordName>` | `functions/img/[id].js` | Image proxy for `og:image`. Resolves the recipe's first photo from CloudKit and streams it back; falls through to `/llama-icon.png` on any failure. |
| `/.well-known/apple-app-site-association` | static file | Universal Links AASA — tells iOS that `/r/*` URLs belong to the Llamas Cookbook app. |
| `/llama-icon.png` | static file | Brand icon used as the OG image fallback. |

The shared CloudKit client lives at `lib/cloudkit.js` (outside `functions/`) so the Pages bundler picks it up via the relative `import` in each route handler without auto-routing it as `/cloudkit`.

## Required environment variables

Configure all four in **Cloudflare dashboard → Pages → llamascookbook → Settings → Environment Variables**, scoped to **both Production AND Preview**:

| Name | Value | Encrypt? |
|---|---|---|
| `CLOUDKIT_CONTAINER_ID` | `iCloud.com.llamascookbook.app` | No |
| `CLOUDKIT_KEY_ID` | Short alphanumeric from CloudKit Console → Server-to-Server Keys | No |
| `CLOUDKIT_PRIVATE_KEY` | Full PEM (multi-line, includes `-----BEGIN…END-----` headers) | **Yes** (lock icon) |
| `CLOUDKIT_ENVIRONMENT` | `production` *(or `development` for testing against the unsealed schema)* | No |

The private key is read once per request and used by `functions/_lib/cloudkit.js` to sign each CloudKit Web Services request with ECDSA-SHA256 (P-256). The signing logic accepts both PKCS#8 and SEC1 PEM formats — whichever CloudKit Console hands you should work.

## Build settings (one-time, when creating the Pages project)

- **Framework preset**: None
- **Build command**: *(leave blank)*
- **Build output directory**: `cloudflare-pages`
- **Root directory**: *(leave as `/`)*
- **Production branch**: `main` (or your default)

After connecting to git, every push to the production branch redeploys automatically.

## Local testing

```bash
npm install -g wrangler
cd cloudflare-pages
wrangler pages dev --binding CLOUDKIT_CONTAINER_ID=iCloud.com.llamascookbook.app --binding CLOUDKIT_KEY_ID=... --binding CLOUDKIT_PRIVATE_KEY="$(cat private-key.pem)"
```

Then visit `http://localhost:8788/r/<some-real-recordName>`.

## Verification checklist (after first deploy)

1. **AASA file**: `curl -i https://llamascookbook.pages.dev/.well-known/apple-app-site-association` should return `Content-Type: application/json` and the JSON body declaring `GYFN949Q5E.com.llamascookbook.app` against `/r/*`.
2. **Recipe page**: visit `https://llamascookbook.pages.dev/r/<id>` (replace `<id>` with a real `RecipeShare` record name from the app). Should render the recipe title and photo. View source — `og:title` should be the recipe name, not "A Recipe".
3. **Image proxy**: visit `https://llamascookbook.pages.dev/img/<id>` — should return the recipe's first photo (or 302 to `/llama-icon.png` if there's no photo).
4. **Universal Link**: on a real iPhone with the app installed (after the next build with the new entitlement), share a recipe → tap the link in Messages on a different iCloud device → should open directly in the app, NOT Safari.

## Why this exists

iMessage refuses to render rich link previews for `customscheme://` URLs as an anti-spoofing measure. To get the recipient's bubble to show the recipe photo + name, the share URL has to be HTTPS with proper Open Graph tags — which means a hosted page somewhere. Cloudflare Pages free tier (100k requests/day) is plenty for this app's scale and avoids the recurring cost of a domain or paid hosting.
