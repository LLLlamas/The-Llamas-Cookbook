# Social

## Shipped

- Sign in with Apple identity.
- Public `UserProfile` mirror (display name / accent / presence hints).
- Name search + friend request flow.
- Friends + requests in Profile.
- `PublishedRecipe` mirror for friend cookbook browsing.
- Friend recipe detail + import into local library.
- Chain attribution + `RecipeImport` audit rows.
- CloudKit subscription plumbing for friend / import events.

## Privacy decision

Social sharing is public/unlisted. UI controls discovery; CloudKit public DB and Cloudflare previews intentionally allow recipe links to work for non-friend recipients. Do not write copy that promises only friends can read shared records.

## Record types

`UserProfile`, `Friendship`, `PublishedRecipe`, `RecipeImport`, `RecipeShare`. `PublishedRecipe` and `RecipeShare` carry `photo0`-`photo19` CKAsset fields.

## Open

- Verify CloudKit Console roles match expected mutation behavior; gate `UserProfile` queries to registered users.
- Push Notifications capability + main provisioning profile regeneration still needed for delivery.
- `RecipeImport` indexes still need Dev to Prod deployment.
- Account-deletion cascade should be re-tested under offline / interrupted conditions.
- `Friendship(userA,userB)` dedupe is client-only; consider server-side uniqueness.
