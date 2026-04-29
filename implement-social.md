# implement-social.md

Cost analysis for adding a Friends feature: search by handle, browse a friend's library, copy recipes into your own book. Drafted 2026-04-29 by Claude. Not committed scope — decision doc only.

## TL;DR

Roughly **3–5 weeks of focused engineering work** plus ongoing social-surface maintenance. CloudKit infrastructure cost is **~$0** under Apple's free tier at any reasonable scale. The non-obvious costs are App Store review (social features get more scrutiny), privacy policy updates, and the permanent moderation surface area you take on the moment users can see each other's content.

The cheapest piece is import — `RecipeShare.materialize` already deep-copies a recipe with fresh UUIDs and rewritten photo references. The expensive pieces are friend discovery, the publishing model, and everything that becomes mandatory once content is social (block, report, account-deletion cascade extended).

## Engineering cost

Sliced for incremental shipping. Days are working-days for a single developer already context-loaded on the codebase.

| Slice | Scope | Days |
|---|---|---|
| 1. Profile + handle | `UserProfile` CK record (handle, displayName, avatar). Handle picker in `ProfileView`, uniqueness check via CK query, reserved-handle list. | 3–4 |
| 2. Friend search + requests | `Friendship` CK record (sender, recipient, status). Search-by-handle UI, send/accept/decline, friends list. CKSubscription for incoming-request push. | 4–5 |
| 3. Shelf publishing | `RecipeShelfEntry` CK record per published recipe per user. Per-recipe "share to friends" toggle in editor + detail. Re-publish on edit, tombstone on unpublish. | 3–4 |
| 4. Browse + import | Friend's library view (read-only, cached), recipe preview, "Add to my book" calling existing `RecipeShare.materialize`. | 3–4 |
| 5. Block / report / cascade | Block list (hide friend, prevent re-friending), in-app report flow, extend account-deletion outbox to wipe `UserProfile` + `Friendship` + `RecipeShelfEntry`. | 2–3 |
| 6. Polish + notifications | CKSubscription for new-from-friend, badge counts, settings, empty states, error UX. | 2–3 |
| **Total** | | **17–23 days** |

Add ~25% slip buffer for CloudKit schema fights (Dev→Prod deploys, manual photo-field-add gotcha already documented in CLAUDE.md), real-device Universal-Link-style verification, and TestFlight cycles. **Realistic calendar: 4–6 weeks** including review.

## CloudKit infrastructure cost

Apple's free CloudKit quota scales with active users. Per the published model, every additional iCloud user adds ~100 MB asset storage and ~1 MB DB storage to your free tier, capped at 1 PB / 10 TB respectively. Concretely:

- **`UserProfile`** — one tiny record per user. Negligible.
- **`Friendship`** — two records per friendship pair (or one with both userRecordNames; one-record design preferred). Tens of bytes each. Negligible.
- **`RecipeShelfEntry`** — one record per (publisher, recipe). Photos as `CKAsset` like existing `RecipeShare`. **This is the only meaningful storage line.** A user publishing 50 recipes with 5 photos each at ~500 KB/photo = ~125 MB. Well under per-user free quota.
- **CKSubscription pushes** — free, rate-limited by Apple, no concern at this scale.

**Expected bill at any plausible scale for a personal-app-with-friends: $0/month.** Only watch-out is if a user goes truly wild (publishes their entire library + raw uncompressed photos) — already mitigated by `ImageProcessing` resize pipeline.

## App Store review cost

Social features cross thresholds in App Review Guideline 1.2 ("user-generated content") that the app currently doesn't trigger. New requirements:

- **Block users** — must be in-app, not just a website.
- **Report objectionable content** — in-app flow with 24-hour response SLA committed in the policy.
- **EULA acknowledging UGC rules** — Apple's standard EULA covers this; no custom legal needed but must be linked.
- **Privacy policy update** — declare collection of handles, friend graph, published recipe content. Update App Store Connect privacy questionnaire.
- **Possible re-categorization** — currently "Food & Drink"; adding social does not force a category change but Apple may flag it during review.

**Expected review impact: one extra rejection cycle is likely** on first submission with social features. Budget +1 week for review back-and-forth on the launch build. After that, normal cadence resumes.

Account-deletion compliance is already in place via the cloud-share outbox; extending it is a small lift, not a new requirement.

## Privacy / legal cost

- **Privacy policy** — needs a section on social data (handle, friend graph, published recipes are visible to friends). Boilerplate, but needs writing once and hosting on `llamascookbook.pages.dev`.
- **App Store Connect privacy labels** — add "Identifiers / User ID", "User Content / Other User Content" linked to identity.
- **GDPR / data export** — already need this for account deletion; add friend graph + published recipes to the wipe list. No new export endpoint needed since CloudKit is per-user.
- **Minor users** — Apple's standard "13+" age gate via SIWA is sufficient; no extra COPPA work as long as the app remains 4+ rated. Adding social may force a rating bump to 12+ (Apple's auto-rating logic flags "Infrequent/Mild Mature/Suggestive Themes" risk for any UGC app). **Likely outcome: 12+ rating.**

No external legal review required for an indie app at this scale, but worth one careful pass through Apple's UGC guidelines before submission.

## Operational cost (recurring)

This is the cost most easily underestimated. Once shipped:

- **Moderation queue** — even with no abuse, you'll get reports. Honoring the 24-hour response commitment means checking a queue daily. Realistic load for a personal-scale app: 0–2 reports/week.
- **Support load** — "I can't find my friend", "my handle was taken", "I blocked someone and they can still see X". Roughly 2–3x current support volume.
- **Schema evolution risk** — every CloudKit schema change requires Dev→Prod deploy and the manual-photo-field-add ritual documented in CLAUDE.md. More record types = more chances to forget a field.
- **Privacy incident exposure** — a bug that leaks one user's library to a non-friend is a much bigger deal than a bug in the current single-user app. Test surface widens significantly.

## User-onboarding cost

Soft cost but real:

- New tab/section in primary nav competes with Library, Profile.
- Handle selection adds a step to first-run for users who want social (acceptable if optional).
- "Why does this app want my friends?" — a privacy-conscious user may bounce. Mitigate by making social entirely opt-in and gated behind sign-in.

## What you get for the cost

- Recipe discovery from people you trust (the actual product value).
- Network effect — gives users a reason to invite others, which is otherwise absent.
- Reuses ~80% of the sharing infrastructure already built (CloudKit, `RecipeShare.materialize`, photo asset handling, account-deletion outbox).

## What's the cheapest viable version

If the full plan feels heavy, a **"shelf-only, no friend graph" MVP** is ~1–1.5 weeks:

- Skip `Friendship` record entirely.
- User picks handle, can publish recipes to a public shelf at `llamascookbook.pages.dev/u/<handle>`.
- Sharing is "send your handle to a friend" — same UX as Instagram pre-friending.
- "Add to book" still works the same way (deep link → existing import path).

Loses: privacy (anyone with the handle can browse), push notifications, request/accept ceremony. Gains: ships in a week, no App Review surprises beyond what's already in flight, easy to layer friending on later if it's wanted.

## Decision points before starting

1. **Friend graph or shelf-only?** Big architectural fork — pick before slice 1.
2. **Handle uniqueness** — first-come-first-served, or moderated reservation list for trademark-style names?
3. **Discovery** — handle-only, or also QR / share-code / nearby?
4. **Library mirroring** — explicit per-recipe publish (recommended), or auto-publish all and hide on opt-out?
5. **Where social lives in nav** — new tab, or nested under Profile?

## Not in scope of this estimate

- In-app messaging / chat.
- Comments or ratings on friends' recipes.
- Public "explore" feed beyond friends.
- Multi-device handle sync edge cases beyond what SIWA + CloudKit already provide.

Each of these is its own multi-week project and would push the timeline accordingly.
