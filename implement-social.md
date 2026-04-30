# Social Feature Summary

Historical build spec, now condensed. Code and `CLAUDE.md` are current.

## Shipped

- Sign in with Apple identity.
- Public `UserProfile` mirror with display name/accent/presence hints.
- Name search and friend request flow.
- Friends list and requests in Profile.
- Published recipe mirror for friend cookbook browsing.
- Friend recipe detail and import into local library.
- Chain attribution and import counter/audit rows.
- CloudKit subscription plumbing for friend/import events.

## Privacy Decision

Product decision on 2026-04-30: social sharing is **public/unlisted**, not strict friend-private storage.

Accepted-friend UI controls discovery in the app. CloudKit public DB and Cloudflare previews intentionally allow recipe links to work for non-friend recipients. Do not use copy that promises only friends can possibly read shared records.

## CloudKit Record Types

- `UserProfile`
- `Friendship`
- `PublishedRecipe`
- `RecipeImport`
- Existing direct-share type: `RecipeShare`

`PublishedRecipe` and `RecipeShare` both use `photo0`-`photo19` asset fields.

## Current Follow-Ups

- Verify CloudKit public DB roles match expected mutation behavior.
- Push Notifications capability/profile still needed for delivery.
- `RecipeImport` indexes still need Dev to Prod deployment.
- Account deletion cleanup should be tested for social records.
- Friend request dedupe is improved but not a server-enforced uniqueness boundary.
