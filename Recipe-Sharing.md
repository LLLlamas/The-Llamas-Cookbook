# Recipe Sharing Summary

Historical plan, condensed after implementation. Use `CLAUDE.md` and code for current behavior.

## Current Behavior

- Direct share path uploads a `RecipeShare` record to CloudKit public DB.
- Sender shares `https://llamascookbook.pages.dev/r/<id>`.
- Cloudflare renders Open Graph preview and proxies the first image.
- Receiver imports through existing share-preview UI.
- Local fallback remains `llamascookbook://recipe/v2/<base64url>` with no photos.

## Important Constraints

- Sharing is public/unlisted, not strict-private.
- New IDs are 12 chars; legacy 6-char links still route.
- Local cook history is not included in share envelopes.
- Photo payloads must remain capped to protect memory.
- Account deletion should remove authored cloud shares via outbox/pending delete.

## Main Files

- `ios-native/Sources/Lib/RecipeShare.swift`
- `ios-native/Sources/Lib/CloudKitService.swift`
- `ios-native/Sources/Views/Components/ShareSheet.swift`
- `ios-native/Sources/Views/Library/RecipeImportPreviewView.swift`
- `cloudflare-pages/functions/r/[id].js`
- `cloudflare-pages/functions/img/[id].js`

## Keep

- Universal Links plus custom-scheme fallback.
- Open Graph preview via HTTPS, not `customscheme://`.
- Size guards and schema-version checks before materializing imported recipes.
