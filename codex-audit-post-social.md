# Codex Audit (post-social, 2026-04-30)

Decision: friend cookbook sharing uses public/unlisted CloudKit. Messages/Universal Links must work for non-friend recipients. Copy must not promise strict friend-only privacy.

Hardened during this audit:

- Cloudflare preview validates token shape, sets `nosniff` / referrer / CSP / permissions-policy, sniffs image bytes, caps image proxy at 10 MB.
- New CloudKit share/import IDs are 12 chars from `[A-Z2-9]` minus `I/O/0/1`.
- CloudKit cursor pagination on social queries.
- Defensive participant checks on friend approve/delete.
- Friend push observer is idempotent.
- Total receive-side cloud photo cap (40 MB).
- Removed tracked `.claude/settings.local.json`; gitignored locally.
- Copy aligned with public/unlisted model.

Open (track in `ROADMAP.md`):

- Verify CloudKit Console roles for `UserProfile`, `Friendship`, `PublishedRecipe`, `RecipeImport`, `RecipeShare`.
- Finish Push Notifications portal/profile work.
- Deploy `RecipeImport` Production schema/indexes.
- Re-test account deletion under offline/interrupted social cleanup.
- Review App Store privacy labels + privacy policy language.
- Add durable social deletion outbox if records can strand during account deletion.
- Batch / cache friend profile fetches (`FriendsStore.refresh()` is still serial).
- Extract shared CloudKit photo asset upload/fetch helpers.
