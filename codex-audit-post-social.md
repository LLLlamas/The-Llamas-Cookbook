# Codex Audit: Post-Social

Audit started 2026-04-30. This is now a compact handoff.

## Decision

Social/friend cookbook sharing uses **public/unlisted** CloudKit records. This is intentional so Messages/Universal Links work for non-friend recipients. App copy must not promise strict friend-only privacy.

## Completed Touchups

- Removed tracked `.claude/settings.local.json`; kept it ignored locally.
- Hardened Cloudflare preview routes:
  - exact token validation for legacy 6-char and current 12-char IDs
  - `nosniff`, referrer policy, CSP, permissions policy
  - image magic-byte sniffing
  - 10 MB image proxy cap
- Increased new CloudKit share/import IDs to 12 chars.
- Added CloudKit cursor pagination helper for social queries.
- Added defensive participant checks for friend approve/delete.
- Made friend push observer idempotent.
- Added total receive-side cloud photo cap.
- Updated docs and remove-friend copy to match public/unlisted sharing.

## Remaining High-Value Work

1. Verify CloudKit Dashboard roles for `UserProfile`, `Friendship`, `PublishedRecipe`, `RecipeImport`, `RecipeShare`.
2. Complete Push Notifications portal/profile work.
3. Deploy `RecipeImport` Production schema/indexes.
4. Test account deletion with offline/interrupted social cleanup.
5. Review App Store privacy labels and privacy policy language.
6. Add durable social deletion outbox if records can strand during account deletion.
7. Batch or cache friend profile fetches if refresh gets slow.
8. Extract shared CloudKit photo asset upload/fetch helpers.

## Verification Run

- Cloudflare functions passed `node --check`.
- `git diff --check` passed, with normal Windows CRLF warnings.
- Secret scan found docs/workflow placeholders, not committed private key material.
