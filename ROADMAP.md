# Roadmap

`CLAUDE.md` carries the active priorities. This file is the longer backlog only.

## Next

- `TimerLiveActivityRegistry` keyed by `cookID` so backgrounded cooks keep managed Live Activities.
- Fan-out `FriendsStore.refresh()` profile fetches via `withTaskGroup` (currently serial).
- Aesthetic/type pass; adopt Liquid Glass before iOS 27.
- Review App Store privacy labels against actual CloudKit / Cloudflare sharing.
- Durable deletion outbox for stranded social records if account-deletion testing finds any.
- Server-side uniqueness for `Friendship(userA,userB)` (currently client-deduped only).

## Later

- Settings beyond accent / sign-out / delete.
- Dark mode.
- iPad layout.
- Live Activity App Intents.
- Tooling for inspecting CloudKit roles in-app.
- Optional per-recipe share controls if product direction changes.
