# Llamas Cookbook — SDK Update Plan (iOS 26)

> **Purpose:** unblock TestFlight uploads after Apr 28, 2026 by moving the build
> from iOS 18.5 SDK → iOS 26 SDK, while protecting the current visual design
> from the auto-applied Liquid Glass redesign.
>
> **Deadline:** Tuesday, **April 28, 2026** — Apple stops accepting new uploads
> built with anything older than iOS 26 SDK / Xcode 26.
> **Today:** Sunday, April 26, 2026. Two days. One CI cycle ≈ 20 min.
>
> **Companion to:** [Llamas-Cookbook-Master.md](./Llamas-Cookbook-Master.md),
> [PROJECT.md §7–8](./PROJECT.md), [ROADMAP.md §0](./ROADMAP.md).

---

## 0. TL;DR — three changes, one CI run

1. **Switch CI runner** from `macos-latest` → `macos-26` in
   [`.github/workflows/ios-native-ci.yml`](./.github/workflows/ios-native-ci.yml).
   This pulls Xcode 26 and the iOS 26 SDK.
2. **Add `UIDesignRequiresCompatibility = YES`** to the app target's
   Info.plist via [`ios-native/project.yml`](./ios-native/project.yml) so we
   keep the old visual design while we audit what Liquid Glass would do to
   our terracotta + cream system.
3. **Bump the existing `IPHONEOS_DEPLOYMENT_TARGET`** — leave at 18.0. We are
   not changing what iOS versions we support; we're only changing what SDK
   we **build against**. Those are different things.

Push, dispatch the workflow, watch TestFlight for the ITMS-90725 warning to
disappear. If it doesn't, see §8.

---

## 1. What ITMS-90725 actually means

> "ITMS-90725: SDK version issue – This app was built with the iOS 18.5 SDK.
> Starting April 28, 2026, all iOS and iPadOS apps must be built with the iOS
> 26 SDK or later, included in Xcode 26 or later, in order to be uploaded to
> App Store Connect or submitted for distribution."

Two distinct concepts that the warning conflates:

| Concept | What it controls | Our value |
| --- | --- | --- |
| **Build SDK** (the thing the warning is about) | What APIs we compile against, and how the OS treats us at runtime (Liquid Glass auto-opt-in lives here) | **Must become iOS 26.** Currently iOS 18.5. |
| **Deployment target** (`IPHONEOS_DEPLOYMENT_TARGET`) | Minimum iOS we run on | **Stays iOS 18.0.** Not changing. |

So this is **not** a forced minimum-OS bump. We can still target iOS 18+
phones — we just have to compile with the new SDK to do it.

The warning becomes a **rejection** on Apr 28. It's a soft warning today.

---

## 2. The Liquid Glass landmine

The thing nobody talks about until they ship: **building with the iOS 26
SDK automatically opts the app into Liquid Glass on iOS 26 devices.** All
system-supplied UI components (navigation bars, tab bars, toolbars, sheets,
form controls) get the new translucent / glassy treatment by default. No
flag to flip on; the rebuild itself is the opt-in.

For us, that hits:

- **Detail view's nav bar + toolbar** (favorite heart, ShareLink). Liquid
  Glass turns these translucent over content.
- **Editor sheet chrome.** Sheets get new corner / blur treatment.
- **Cook Mode's full-screen cover + the 80pt tuck detent.** Detent rendering
  changes shape under the new design.
- **Floating timer banner** pinned between phase header and scroll view —
  any system blur layer it relies on will shift.
- **Tab/segment-style controls** (the Prep ↔ Cook pill, tag chip filter row,
  servings scaler).

And our themed bits — accent terracotta, the `onAccent` cream, the four-tier
cream surface system, the warmer `cookModeBackground` — were tuned against
the *current* iOS chrome. They have not been visually QA'd against Liquid
Glass. **There is no way to test that on a Windows dev machine.**

The pragmatic call:

> **Opt out for this deadline-driven build. Adopt deliberately during the
> aesthetic pass that's already queued up next.**

Apple provides exactly one knob:

```
UIDesignRequiresCompatibility = YES   (Info.plist)
```

When set, iOS 26 renders the app using the legacy design. The flag is
explicitly **temporary** — Apple says it'll be removed in iOS 27. So we
have one major version to do the proper adoption pass. That is fine and
matches our existing roadmap.

---

## 3. The actual changes — file by file

### 3.1 `.github/workflows/ios-native-ci.yml`

Two edits:

**Edit A — change the runner.**
Find:
```yaml
runs-on: macos-latest
```
Replace with:
```yaml
runs-on: macos-26
```

> `macos-26` went GA on GitHub Actions on Feb 26, 2026. It's arm64-only,
> includes Xcode 26 + Xcode Command Line Tools 26.4, and ships with the iOS
> 26 SDK. `macos-latest` currently still points at macOS 15 / Xcode 16 — it
> will *not* satisfy the new requirement. Pin to `macos-26` explicitly so a
> later `latest` rotation can't surprise us.

**Edit B — pin Xcode (belt and suspenders).**
Right after the `actions/checkout@v4` step, add:
```yaml
      - name: Select Xcode 26
        run: sudo xcode-select -s /Applications/Xcode_26.app/Contents/Developer
```

> The `macos-26` image already defaults to Xcode 26, but if Apple ships
> Xcode 26.x point releases that the image carries side-by-side, this makes
> the choice explicit. Adjust the path if `actions/runner-images` releases
> show a different default app name for the version on the image at run
> time. Sanity-check with `xcodebuild -version` immediately after.

**Edit C — add a version sanity step (optional but cheap).**
Right after the xcode-select step:
```yaml
      - name: Print toolchain
        run: |
          xcodebuild -version
          xcrun --sdk iphoneos --show-sdk-version
          xcrun --sdk iphoneos --show-sdk-path
```

> First push after the SDK bump, this paid-for itself instantly: the
> `iphoneos --show-sdk-version` line is the single fastest way to confirm
> we are actually compiling against iOS 26 and not against an older SDK
> still present on the image.

### 3.2 `ios-native/project.yml`

Add the Liquid Glass opt-out under the app target's `INFOPLIST_KEY_*` /
`info.plist` settings. XcodeGen's syntax for these varies a bit by repo
convention; pick whichever path matches how `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`
is currently declared and add the new key alongside it.

Pattern A — if existing keys are listed under `settings.base`:

```yaml
targets:
  LlamasCookbook:
    settings:
      base:
        # ...existing keys...
        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
        INFOPLIST_KEY_UIDesignRequiresCompatibility: YES   # ← new
```

Pattern B — if the project uses an explicit `info.plist` block:

```yaml
targets:
  LlamasCookbook:
    info:
      path: ios-native/Sources/App/Info.plist
      properties:
        # ...existing properties...
        UIDesignRequiresCompatibility: true                # ← new
```

> Use Pattern A if the existing encryption-export key
> (`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO` from PROJECT.md §7) is
> declared under `settings.base`. Match the file's existing convention —
> don't introduce a second style.

**Do NOT** change `IPHONEOS_DEPLOYMENT_TARGET`. It stays at `18.0`. The SDK
bump and the deployment target are independent.

**Widget target.** The `LlamasCookbookTimerWidget` extension does not need
the Liquid Glass flag — the Live Activity / Dynamic Island UIs are
system-skinned by Apple, not by us, and they look right under Liquid Glass
by definition. Leave the widget target alone.

### 3.3 No code changes required — but a quick audit anyway

Most of what we wrote should keep working unchanged. Quick checklist of
things that are technically API-stable but worth eyeballing on the first
build:

- `presentationDetents([.large, .height(80)])` on Cook Mode — same API,
  cosmetic only.
- `ShareLink` in Detail — unchanged.
- `ActivityKit.Activity.request / update / end` (in
  `TimerLiveActivityController`) — unchanged through iOS 26.
- `UIApplication.shared.isIdleTimerDisabled` (planned, still pending) —
  unchanged.
- `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` — unchanged.
- `UIView.appearance().tintColor = UIColor(AppColor.accent)` — still works,
  though Liquid Glass when we eventually adopt it changes how this
  propagates. Fine for the opt-out build.

If the compiler emits new deprecation warnings in the build log, **don't
fix them in the deadline push.** Note them, defer them. Yellow warnings
don't block the upload.

---

## 4. Sequence — do this in this order

| # | Action | Where | ~Cost |
| - | --- | --- | --- |
| 1 | Branch off `main`: `sdk-bump-ios26` | local | 30 sec |
| 2 | Apply 3.1 edits A + B + C | `ios-native-ci.yml` | 2 min |
| 3 | Apply 3.2 edit | `project.yml` | 1 min |
| 4 | Commit, push branch | git | 30 sec |
| 5 | Open PR with title `chore(ci): build with iOS 26 SDK + opt out of Liquid Glass` | GitHub | 1 min |
| 6 | Manually dispatch `ios-native-ci.yml` against the branch (uncheck "Upload to TestFlight" the first run — produce `.ipa` only) | GitHub Actions | ~20 min wait |
| 7 | Confirm in the build log that `xcrun --sdk iphoneos --show-sdk-version` reports `26.x` | Actions log | 1 min |
| 8 | If clean: dispatch again, this time **with** Upload to TestFlight checked | GitHub Actions | ~20 min wait |
| 9 | App Store Connect → Builds: confirm ITMS-90725 is **gone** | ASC | 2 min after upload |
| 10 | Install via TestFlight, walk through every screen, confirm no visual regressions | iPhone | 10–15 min |
| 11 | Merge PR | GitHub | 30 sec |

If the deadline is uncomfortably close after step 8, you can ship the
upload from the branch — the merge is just bookkeeping.

---

## 5. Test plan after install on iPhone

Walk these in order, noting anything that looks different from the previous
TestFlight build:

1. **Launch + Library.** A–Z scrub, mascot watermark, FAB menu (New / Import).
2. **Detail.** Open a recipe with ingredients, steps, notes, and a source
   URL. Tap favorite heart. Tap Conversions chip → both reference cards
   *and* the live calculator. Tap ShareLink → share to Notes, paste back
   into a new recipe via Import to round-trip.
3. **Editor.** Add ingredient (qty + unit + name). Force a validation
   error (empty name) → confirm the red-border flash + horizontal shake +
   warning haptic still play. Add a step. Toggle the per-step timer clock.
   Drag-to-reorder steps. Add a tag from presets. Add a tag via custom
   text. Save. Cancel from a dirty draft → confirm discard alert appears.
4. **Cook Mode.** Start cooking. Toggle Prep ↔ Cook. Bump servings up and
   down — confirm `Quantity.format` is still snapping to measurable
   fractions (no "0.42 tsp"). Check off a `needsTimer` step → timer
   auto-starts. Tap floating timer banner → adjust sheet → wheel picker
   1–60 min works. Let timer expire → confirm full-screen ready overlay
   + vibration loop + alarm CAF. Stop. Tuck Cook Mode to 80pt detent →
   browse Library → re-expand. Mark as cooked → `cookCount` increments.
5. **Live Activity** (only meaningful on iPhone 14 Pro+). Lock the device
   while the timer is running → Lock Screen row visible? Dynamic Island
   compact + minimal + expanded all render?
6. **Editor again.** Quick numeric Done button at the editor root only
   appears when a numeric (qty / cook-time / servings) field is focused?
   Tap-away on whitespace dismisses?
7. **Import.** Paste a known-good recipe blob. Live format checklist
   ticks? Editor opens pre-filled?
8. **Color audit.** Eyeball every screen for terracotta + cream looking
   right. The opt-out flag should keep these stable; if anything looks
   foggy / glassy, the flag isn't being applied — see §8.

Hold the bar for "shipping": **steps 1–5 must pass.** If 6–8 wobble
slightly, log and ship anyway, fix in the next cycle.

---

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| `macos-26` runner has known Xcode 26 CI hang reports (random ~30-min stalls) | Low–Med | Build wastes a cycle | Re-dispatch. If it persists across 2 retries, fall back to `macos-26-large` (paid) for one push to get over the line. |
| Liquid Glass flag not being read because XcodeGen merges into Info.plist differently than expected | Med | App ships with auto-Liquid-Glass on first build — visual regressions on iOS 26 phones | After CI, dump the generated `Info.plist` from inside the built `.app` (use the upload artifact). Verify `UIDesignRequiresCompatibility = true`. If missing, switch the project.yml syntax pattern (3.2 A vs B). |
| Widget signing breaks under Xcode 26 | Med | Archive fails | The pending widget provisioning profile work in [ROADMAP §0](./ROADMAP.md) is on the same path — if signing fails, do that setup first, then re-run. |
| New deprecation warnings flood the build log | High | Just noise | Ignore for this push. Triage later. |
| `actool` placeholder icon generation step (ImageMagick → 1024×1024) behaves differently on `macos-26` | Low | Build fails on icon | The icon is generated fresh per CI run. If `actool` complains, regenerate locally / commit a static placeholder PNG and remove the generation step temporarily. Keep moving. |
| `CFBundleVersion = date -u +%s` build numbering breaks under new TestFlight validators | Very Low | TestFlight rejects upload | Implausible — Unix timestamps are still strictly monotonic. If somehow it does, prepend an offset. |
| First device-install reveals Liquid Glass *did* leak through | Med | Visual regression in production for one TestFlight cycle | The opt-out flag is the safety net. If something still looks glassy, that surface is custom-styled (we built it), not system chrome — bug live, fix at leisure. |

---

## 7. What this does NOT do

- **Does not bump deployment target.** Still iOS 18.0.
- **Does not adopt Liquid Glass.** That's its own design pass — see §9.
- **Does not change SwiftData schema.** Models untouched. No migration risk.
- **Does not change signing identities or bundle ids.** Same cert, same
  provisioning profiles (modulo the widget profile that ROADMAP §0 still
  owes regardless).
- **Does not touch the RN/Expo archive.** [`outdated/rn-expo/`](./outdated/rn-expo/)
  is dead code. Its workflow is disabled. Leave it there.

---

## 8. If the deadline build fails

Triage in this order. Each step is one CI cycle.

1. **`xcrun --sdk iphoneos --show-sdk-version` doesn't say 26.x.**
   The xcode-select path is wrong for whatever Xcode version the image is
   currently shipping. Open the
   [`actions/runner-images` macos-26 readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md),
   find the exact Xcode app name listed under "Xcode → Installed Versions,"
   and update the path in 3.1 Edit B.
2. **Archive succeeds, ITMS-90725 still appears.**
   Means an embedded binary (the widget) was built against the old SDK
   while the app target got the new one. Confirm both targets in
   `project.yml` inherit the same `IPHONEOS_DEPLOYMENT_TARGET` and that
   no per-target setting pins an old SDK explicitly. There should be no
   `SDKROOT` override anywhere.
3. **App boots, but Liquid Glass leaked through.**
   The opt-out flag isn't reaching the bundled Info.plist. Open the
   generated `.ipa` (rename to `.zip`, extract), inspect
   `Payload/LlamasCookbook.app/Info.plist`, confirm the key is present and
   set to `true`. If absent, switch project.yml syntax (3.2 A↔B) and push
   again.
4. **Widget archive fails to sign.**
   Almost certainly the missing
   `IOS_WIDGET_PROVISIONING_PROFILE_BASE64` repo secret from
   [ROADMAP §0](./ROADMAP.md). That's a 10-minute Apple Developer portal
   task — do it, then re-dispatch.
5. **CI hangs > 45 min in `xcodebuild` test/archive phase.**
   Known Xcode 26 issue per `actions/runner-images` issue tracker. Cancel
   the run, retry. If it recurs across 3 retries on `macos-26`, switch to
   `macos-26-large` for one push.

### Rollback (last resort, if Apr 28 is hours away and nothing works)

You cannot ship to TestFlight after Apr 28 with the old SDK. There is no
graceful fallback to iOS 18.5 SDK. The SDK bump *must* land. The fallback
plays are:

- **Drop the Liquid Glass opt-out** for the deadline build. App will ship
  Liquid Glass styling automatically. May look different, but ships.
  Re-add the opt-out flag in the very next build.
- **Strip the widget target temporarily** if signing is the blocker.
  Comment out `LlamasCookbookTimerWidget` in `project.yml`, ship the main
  app under iOS 26 SDK, re-add the widget once the provisioning profile
  is in place. Live Activities are deferred for one cycle.

Both are bad outcomes. Both are better than missing the deadline.

---

## 9. The follow-on track — Liquid Glass adoption

This pairs naturally with the aesthetic / UX pass in
[Master §10](./Llamas-Cookbook-Master.md#10-whats-next--the-aesthetic--ux-pass).
Sequence:

1. **Custom typography.** As planned. Independent of Liquid Glass. Drop
   Fraunces + Inter into `Resources/`, wire through `AppFont`.
2. **Real app icon.** As planned.
3. **Liquid Glass audit.** Remove `UIDesignRequiresCompatibility` in a
   throwaway branch. Build, install, walk every screen on an iOS 26
   device. Note every place the new chrome clashes with our terracotta +
   cream. Decide per-component whether to (a) accept Liquid Glass, (b)
   force-style our way back to opaque, or (c) restructure the surface.
4. **Per-component overrides** for the ones we want to keep custom. Apple
   provides per-component opt-outs in addition to the app-wide flag, so
   we can mix.
5. **Ship the adoption** *without* the compatibility flag, before iOS 27.
   Apple has signaled the flag goes away in 27.

The audit can happen any time before iOS 27 ships. There is no rush. The
deadline being addressed in this doc is purely the SDK build version — not
the design system adoption.

---

## 10. Status checkboxes (update as you go)

- [x] §3.1 Edit A — runner switched to `macos-26`
- [x] §3.1 Edit B — `xcode-select` step added
- [x] §3.1 Edit C — toolchain print step added (merged with existing version-print step)
- [x] §3.2 — `UIDesignRequiresCompatibility: true` added to app target's `Resources/AppInfo.plist` (the app uses an explicit Info.plist file via `GENERATE_INFOPLIST_FILE: NO`, so the key lives there alongside `ITSAppUsesNonExemptEncryption` rather than as an `INFOPLIST_KEY_*` setting in `project.yml`)
- [ ] First CI dispatch (no upload) → confirms iOS 26 SDK in build log
- [ ] Second CI dispatch (with upload) → TestFlight upload succeeds
- [ ] App Store Connect: ITMS-90725 warning gone on the new build
- [ ] iPhone install + §5 walkthrough
- [ ] PR merged to `main`
- [ ] STATE.md updated with "iOS 26 SDK live, Liquid Glass opt-out in place"
- [ ] Master doc §3 tech-stack table refreshed (build SDK = iOS 26, deployment target unchanged)

---

## 11. Sources / receipts

- Apple ITMS-90725 warning — confirms Apr 28, 2026 cutoff and Xcode 26
  requirement.
- GitHub Changelog (Feb 26, 2026): `macos-26` runner GA, ships Xcode 26
  + iOS 26 SDK + Xcode Command Line Tools 26.4.
- `actions/runner-images` macos-26 README — current toolchain inventory.
- Apple's `UIDesignRequiresCompatibility` Info.plist key — temporary
  Liquid Glass opt-out, deprecated in iOS 27 per WWDC sessions and
  contemporaneous developer write-ups.
- Reports of intermittent Xcode 26 CI hangs on `macos-26-arm64` — see
  `actions/runner-images` issue tracker. Mostly affects long test suites;
  our archive job is short and unaffected in practice, but mitigation
  noted in §6.
