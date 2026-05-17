# Accent Color Picker — Technical Handoff

## What it does

User picks any color (hex grid, spectrum, sliders, or eyedropper via iOS system UI). The entire app's accent — titles, buttons, icons, FAB, nav chrome — updates to that color. Change is persisted across launches. Auth-gated: unsigned users see a locked card instead.

---

## Core pattern: local state, deferred commit

The single most important design decision: **the picker color is local state; it never writes to the global settings object mid-session.**

```swift
@State private var pickerColor: Color = AppColor.accent

// on disappear — one write, after the system picker is gone
func commitSelection() {
    guard isSignedIn else { return }
    settings.accentColor = pickerColor
    settings.syncToUIKit()
}
```

**Why:** iOS's `UIColorPickerViewController` (which backs SwiftUI's `ColorPicker`) re-snapshots its `selectedColor` any time `UIView.appearance().tintColor` changes. If you write to the global tint mid-session, every pick after the first is silently overwritten by the picker re-reading the just-applied tint. Deferring to `onDisappear` sidesteps this entirely.

The live preview inside the sheet follows `pickerColor` continuously via SwiftUI's `.tint(pickerColor)` — no UIKit involved during the session.

---

## Persistence

Stored as a hex string in `UserDefaults`:

```swift
private static let storageKey = "userAccentHex"

func persist() {
    UserDefaults.standard.set(accentColor.toHex, forKey: storageKey)
}

init() {
    if let hex = UserDefaults.standard.string(forKey: storageKey),
       let color = Color(hex: hex) {
        self.accentColor = color
    }
    applyToUIKit()
}
```

On first launch, falls back to the default (terracotta `#C97C5D`).

---

## UIKit sync

SwiftUI's `.tint()` covers the SwiftUI hierarchy. UIKit chrome (keyboard return key, nav back chevron, selection handles) needs a separate push:

```swift
private func applyToUIKit() {
    UIView.appearance().tintColor = UIColor(accentColor)
}
```

Only called: at init, on explicit reset, and in `syncToUIKit()` post-picker-dismiss. **Never** called while the picker is on screen.

---

## Auth gate

Unsigned users see a locked card (no picker rendered). `commitSelection()` early-returns if not signed in — the picker color can't be set even programmatically.

---

## Sign-out / sign-in cycle

- **Sign-out** (`applySignedOut()`): forces visible accent back to terracotta using an `isForcingDefault` flag that skips `persist()` and the CloudKit mirror push — the stored UserDefaults preference is untouched.
- **Sign-in** (`restoreFromDefaults()`): re-reads UserDefaults and reapplies. No relaunch needed.

---

## Ripple cascade on color change

When accent changes, two independent ripples fire in parallel — one across the library UI (left-to-right), one through the recipe detail (top-to-bottom). Each zone temporarily holds the old color until its turn arrives, then glows in with the new one.

**Library cascade** (5 stages, 0–880ms):
| Stage | Delay |
|---|---|
| header | 0ms |
| categories | 220ms |
| recipeList | 440ms |
| plusButton | 660ms |
| bottomNav | 880ms |

**Detail cascade** (9 stages, 0–860ms):
nav → title → provenance → ingredients heading → chips → ingredient rows → steps heading → step numbers → cook bar

Implemented via `DispatchQueue.main.asyncAfter` chained off a `generation` counter (increments on each new change; stale callbacks no-op if the generation doesn't match).

Each zone reads its color from a computed property (`transitionColor(for:)`) that returns the old color until the stage has been reached, then the new color — creating the rolling-wave effect without animation libraries.

Cleanup fires at 1.15s: `previousAccentColor`, `accentTransitionStage`, and `detailTransitionStage` all nil'd.

---

## Glow effect on each zone

```swift
func accentGlow(when active: Bool, color: Color) -> some View {
    self
        .shadow(color: color.opacity(active ? 0.16 : 0), radius: active ? 7  : 0)
        .shadow(color: color.opacity(active ? 0.07 : 0), radius: active ? 14 : 0)
        .animation(.easeInOut(duration: 0.14), value: active)
}
```

Applied to each zone's container. `active` is driven by `AppearanceSettings.isAccentGlowActive(_:)`.

**Important:** glow must be applied to the section container, outside any `.drawingGroup()`. Shadows inside a drawing group are clipped to the texture bounds and won't render.

---

## Letterpress outline on accent text

Four sub-pixel cardinal shadows at 0.22 opacity, radius 0, offset 0.4pt — lifts accent-tinted text off cream backgrounds without reading as a stroke.

```swift
struct AccentTextOutline: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: textColor.opacity(0.22), radius: 0, x: -0.4, y: 0)
            .shadow(color: textColor.opacity(0.22), radius: 0, x:  0.4, y: 0)
            .shadow(color: textColor.opacity(0.22), radius: 0, x: 0, y: -0.4)
            .shadow(color: textColor.opacity(0.22), radius: 0, x: 0, y:  0.4)
    }
}
```

Don't apply below ~13pt — at small sizes the offset reads as a smudge. Not applied to tab bar items (UIKit strips SwiftUI modifiers in `.tabItem`).

---

## Live preview card

Sheet opens with a preview section showing the mascot, a sample title, and icons all tinted with `pickerColor`. Flattened into a Metal texture via `.drawingGroup()` so live color-pick updates re-rasterize one surface instead of recompositing ~16 shadow/gradient layers per frame. Shadow applied outside the drawing group.

---

## CloudKit mirror

On every real user-driven accent change (not init rehydrate, not forced sign-out reset), the hex is pushed to the user's `UserProfile` CloudKit record via `UserProfileMirror.updateAccent(hex)` — debounced.

---

## Shopify / web adaptation notes

| iOS concept | Web equivalent |
|---|---|
| `UserDefaults` hex string | `localStorage` / `sessionStorage` |
| `UIView.appearance().tintColor` | CSS custom property (`--accent`) on `:root` |
| SwiftUI `.tint()` modifier | CSS `color: var(--accent)` on scoped container |
| `DispatchQueue.main.asyncAfter` cascade | `setTimeout` chain or `@keyframes` with per-element delay |
| `UIColorPickerViewController` | `<input type="color">` or a custom swatch grid |
| CloudKit mirror | Shopify customer metafield write via Storefront API |
| Auth gate | Shopify customer login state check |

The deferred-commit pattern translates directly: bind the color picker to local component state, write to localStorage and update `--accent` only on close/confirm. This avoids re-triggering CSS transitions on every drag tick.
