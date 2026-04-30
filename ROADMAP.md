# Roadmap

Current source of truth for active work is `CLAUDE.md`. This file is the short backlog.

## Now

1. Verify Universal Links end to end on real iPhones.
2. Remove the temporary cloud-share diagnostic alert after verification.
3. Enable Push Notifications capability on the App ID.
4. Regenerate the main app provisioning profile and update `IOS_PROVISIONING_PROFILE_BASE64`.
5. Deploy `RecipeImport` CloudKit schema/indexes Dev to Prod.

## Next

1. Add `TimerLiveActivityRegistry` keyed by `cookID`.
2. Finish aesthetic/type pass.
3. Adopt Liquid Glass before iOS 27 removes the compatibility opt-out.
4. Review App Store privacy labels against CloudKit/Cloudflare sharing.
5. Add durable deletion/outbox cleanup for all social record types if needed after testing.

## Later

- Settings screen beyond accent/sign-out/delete.
- Dark mode.
- iPad layout.
- Live Activity App Intents.
- More robust social CloudKit role verification tooling.
- Optional per-recipe share controls if product direction changes.
