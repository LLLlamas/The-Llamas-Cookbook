# Recipe Sharing

- Direct share path uploads a `RecipeShare` to CloudKit public DB.
- Sender shares `https://llamascookbook.pages.dev/r/<id>`.
- Cloudflare renders Open Graph preview and proxies the first image.
- Receiver imports through `RecipeImportPreviewView`.
- Local fallback: `llamascookbook://recipe/v2/<base64url>` (no photos).

## Constraints

- Public/unlisted, not strict-private.
- New IDs are 12 chars; legacy 6-char links still route.
- Local cook history is NOT included in share envelopes.
- Photo payloads stay capped (per-photo + total).
- Account deletion cascades authored shares.

## Files

- `ios-native/Sources/Lib/RecipeShare.swift`
- `ios-native/Sources/Lib/CloudKitService.swift`
- `ios-native/Sources/Views/Components/ShareSheet.swift`
- `ios-native/Sources/Views/Library/RecipeImportPreviewView.swift`
- `cloudflare-pages/functions/r/[id].js`
- `cloudflare-pages/functions/img/[id].js`

## Keep

- Universal Links + custom-scheme fallback.
- Open Graph preview via HTTPS, not `customscheme://`.
- Size guards + schema-version checks before materializing imports.
