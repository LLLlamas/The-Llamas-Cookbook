# Llamas Cookbook — Photo Capability Plan (v2)

> **Goal:** add a multi-photo gallery on each recipe + per-step images, sharing
> one set of helpers across both. Pure SwiftUI, no UIKit, no SPM.
>
> **Companion to:** [Llamas-Cookbook-Master.md](./Llamas-Cookbook-Master.md),
> [STATE.md](./STATE.md), [PROJECT.md](./PROJECT.md).
>
> **Audience:** Claude Code session, picking up to implement.

---

## 0. What changed from v1 (read this first)

The original plan had a single edge-to-edge **hero image** at the top of
Detail and the editor. We replaced that with a **gallery model**:

- **No hero region** anywhere. Detail's chrome is unchanged for recipes
  without photos.
- **Gallery button** sits below the times row in Detail and Editor —
  same shape, same position, same modal. Tap → carousel + `+` to add.
- **Step images stay in scope** as their own per-step photo slot inside
  the editor, surfaced inline in Detail steps and full-width in Cook Mode.
- **No Library card cover.** Cards keep the existing placeholder. Photos
  only show up inside Detail (gallery + step images).

Why this is more DRY than v1:

- Gallery + step images **share** `ImageProcessing`, `RecipeImageView`,
  the `NSCache` keying, and the `PhotosPicker` flow.
- Two storage homes (relationship `Recipe.photos` + per-step `image`) but
  one storage *mechanism* — `@Attribute(.externalStorage)` everywhere.
- One viewer component services both the gallery carousel and step image
  zoom.
- The `Recipe.imageUri: String?` field stays vestigial; we don't use it
  and we don't add a new hero field. Removed in a follow-up cleanup.

If you've read v1, you can skim §1, §2, §6.1 (the editor hero is gone),
and the Library section in §7. The rest is genuinely new shape.

---

## 1. The 60-second summary

**Two slots for photos on a recipe:**

| Slot | Where it lives | Where it shows |
| --- | --- | --- |
| **Gallery** | One-to-many `Recipe.photos: [RecipePhoto]` | Gallery button in Detail/Editor → carousel modal. Not on Library card. Not in Cook Mode. |
| **Step image** | `RecipeStep.image: Data?` (one per step) | Inline thumbnail in Detail's step rows; full-width in Cook Mode. |

Storage is SwiftData with `@Attribute(.externalStorage)` for both — bytes
live in sidecar files inside the SwiftData container, cleaned up
automatically on cascade-delete.

PhotosPicker handles the Camera Roll integration. No `Info.plist`
permission keys needed. No camera capture in v1 (Camera → Photos
→ Picker → Recents covers the flow without UIKit).

**Effort:** ~1 dev-day for the gallery (model + button + modal + editor
wiring), ~0.5 day for step images (model + editor toggle + display in
Detail/Cook), ~0.5 day for layout polish + tests. Three CI cycles
minimum.

---

## 2. Schema changes

### 2.1 New `@Model` — `RecipePhoto`

Add to `ios-native/Sources/Models/Recipe.swift` next to `Ingredient`
and `RecipeStep`:

```swift
@Model
final class RecipePhoto {
    var id: UUID
    @Attribute(.externalStorage) var image: Data?
    var order: Int
    var recipe: Recipe?

    init(image: Data?, order: Int) {
        self.id = UUID()
        self.image = image
        self.order = order
    }
}
```

### 2.2 `Recipe` updates

```swift
@Relationship(deleteRule: .cascade, inverse: \RecipePhoto.recipe)
var photos: [RecipePhoto] = []

// Mirror the existing sortedIngredients / sortedSteps pattern.
var sortedPhotos: [RecipePhoto] {
    photos.sorted { $0.order < $1.order }
}
```

`Recipe.imageUri: String?` stays declared. Don't read or write it.
Remove in a follow-up release once we know nothing on disk is using it.

### 2.3 `RecipeStep` updates

```swift
@Attribute(.externalStorage) var image: Data?
```

Add to the init signature with a `nil` default. Existing call sites
(`Recipe.apply(_:)`, currently the only one constructing
`RecipeStep`) get one new arg passed through.

### 2.4 Will SwiftData migrate this safely?

Adding a new optional attribute and a new `@Model` type with an inverse
relationship is a lightweight migration — handled automatically. **First
push, dispatch CI, then nuke and reinstall the app on the phone before
testing**, then install once more *over* a build that has real data, to
confirm migration works on an existing TestFlight install. If the
second install crashes on launch, see §13.

---

## 3. The `apply(_:)` gotcha — applies twice now

Looking at the actual current
[`DraftRecipe.swift`](./ios-native/Sources/Models/DraftRecipe.swift),
`Recipe.apply(_:)` calls:

```swift
ingredients.removeAll()
// ...rebuild from draft...

steps.removeAll()
// ...rebuild from draft...
```

**Photos and step images both fall into this same trap.** On every Save:

1. `steps.removeAll()` will cascade-delete each step's external-storage
   `image` sidecar. If the editor doesn't carry `image: Data?` through
   `DraftStep`, every save loses every step image.
2. The new `photos.removeAll()` (which we're adding in §2) will
   cascade-delete each photo sidecar. Same fix needed for `DraftPhoto`.

The fix is the same pattern in both places:

> **Carry the bytes through the draft.** `DraftStep.image: Data?`,
> `DraftPhoto.image: Data?`. `toDraft()` copies bytes in. `apply(_:)`
> copies bytes back out into the recreated `RecipeStep` /
> `RecipePhoto`.

This is the single most important thing to test (§14, test #6 + #11).
The regression mode is silent and fatal.

---

## 4. New file — `Lib/ImageProcessing.swift`

Pure functions, no state, no filesystem access. Used by **both** the
gallery and step images. **One implementation, two callers.**

```swift
enum ImageProcessing {
    enum Target {
        case gallery   // 1920px max long edge, ~300–500KB
        case step      // 1280px max long edge, ~150–300KB
    }

    /// Resize + re-encode for storage. Run from `Task.detached` so the
    /// editor doesn't hitch on a 12MP photo. Returns nil on decode failure.
    static func prepare(_ source: Data, for target: Target) async -> Data?
}
```

Implementation (Code session: write the body, not just the signature):

- Use `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceCreateThumbnailFromImageAlways = true` and
  `kCGImageSourceCreateThumbnailWithTransform = true` (bakes EXIF
  orientation into the bytes — no `UIImage` round-trip needed).
- Use `ImageIO`'s `CGImageDestination` to write directly to HEIC
  (`UTType.heic`) or JPEG (`UTType.jpeg`).
- **Format preservation:** sniff source format. HEIC source → HEIC out,
  JPEG → JPEG out. PNG/other → JPEG @ 0.85.
- **Bytes guard:** if re-encoded output is *larger* than source (rare —
  small images don't benefit from re-encode), keep the source bytes.
- **Memory:** thumbnails are decoded at target resolution, not source.
  Footprint stays under ~30MB for a 12MP source.

**Tests:** feed it (a) 12MP HEIC, (b) 4MP JPEG, (c) 200KB PNG
screenshot. Output should be smaller-or-equal in all three. Portrait
shots should not flip sideways.

---

## 5. New file — `Views/Components/RecipeImageView.swift`

The single SwiftUI component every photo display goes through.
**One implementation, four callers** (gallery thumbnails, gallery
carousel, step thumbnails in Detail, step full-width in Cook Mode).

```swift
struct RecipeImageView<Placeholder: View>: View {
    let data: Data?
    let contentMode: ContentMode  // .fill for thumbnails, .fit for carousel
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View { ... }
}
```

Behavior:

- `data == nil` → renders the placeholder closure.
- Decodable bytes → renders `Image(uiImage:)` with the requested
  `contentMode` + `.clipped()`.
- Undecodable bytes (corrupt) → renders the placeholder silently.
  Never crashes, never shows a broken-image glyph.
- Reads through a module-scoped `NSCache<NSData, UIImage>` keyed on
  `data.hashValue`. Module-scope means the cache is shared across all
  call sites, not per-instance.

Why a cache when SwiftData lazy-loads? Two callers benefit:

1. **Gallery carousel paging** — swiping back and forth between photos
   would re-decode the same `Data` repeatedly without it.
2. **Future Library card** — when (if) we ever swap the placeholder for
   a card cover, list scrolling will need this. Cheap insurance.

---

## 6. New file — `Views/Components/PhotoCarouselView.swift`

The reusable modal body. **Used in both contexts** (Detail-quick-edit
and Editor-full-edit) via the binding pattern below — same view, same
gestures, same UX, two different data sources.

```swift
struct PhotoCarouselView: View {
    let photoData: [Data]                                   // current photos in order
    var onAdd:    ([Data]) async -> Void = { _ in }         // user picked N photos
    var onDelete: (Int) -> Void          = { _ in }         // user deleted at index
    var onReorder: (IndexSet, Int) -> Void = { _, _ in }    // drag-reorder

    var body: some View { ... }
}
```

Why closures, not bindings: the two callers store photos in different
shapes (live `@Model RecipePhoto` rows in Detail; plain-struct
`DraftPhoto` in Editor). Asking the carousel to know about either
type couples it to the model. Closures decouple it cleanly. The
caller adapts.

UI shape:

- `.fullScreenCover` presentation (matches Cook Mode's existing
  full-screen pattern; photos benefit from edge-to-edge space).
- `TabView` with `.page` style for swipeable carousel.
- Page indicator dots at bottom, matching `AppColor.accent`.
- Top toolbar: `Done` (left), `Add` (right, opens `PhotosPicker`
  multi-select up to 10 photos at once).
- Long-press on a photo → confirm sheet → `onDelete(index)`. Matches
  Library's existing long-press-Delete pattern (UX principle 4).
- Empty state (no photos): centered "Add photos" button + the
  `photo.stack` SF Symbol in `AppColor.textTertiary`. Tap opens
  PhotosPicker.

**No reorder UI in v1.** The closure is plumbed but unused. Defer
drag-to-reorder to a follow-up — it's a non-trivial gesture in a
TabView and we don't need it for personal use.

**No captions, no metadata.** Just the image.

---

## 7. Editor wiring

### 7.1 `DraftRecipe` — new fields

```swift
struct DraftRecipe {
    // ... existing fields ...
    var photos: [DraftPhoto] = []
}

struct DraftPhoto: Identifiable, Equatable {
    let id: UUID
    var image: Data?
    init(id: UUID = UUID(), image: Data? = nil) {
        self.id = id
        self.image = image
    }
}

struct DraftStep {
    // ... existing fields ...
    var image: Data?
}
```

Update `Recipe.toDraft()` to copy bytes:

```swift
photos: sortedPhotos.map { DraftPhoto(id: $0.id, image: $0.image) },
steps: sortedSteps.map { DraftStep(
    id: $0.id, text: $0.text, needsTimer: $0.needsTimer,
    specialNote: $0.specialNote,
    image: $0.image                              // ← new
) },
```

Update `Recipe.apply(_:)` — **this is where the gotcha lives**. After
the existing `steps.removeAll()` loop, add a sibling block for photos:

```swift
// (additions inside the existing apply method)

// Pass image: through when rebuilding steps
steps.removeAll()
for (idx, item) in draft.steps.enumerated() where !item.text.trimmed.isEmpty {
    steps.append(RecipeStep(
        text: item.text.trimmed,
        order: idx,
        needsTimer: item.needsTimer,
        specialNote: item.specialNote?.trimmed.nilIfEmpty,
        image: item.image                         // ← new
    ))
}

// New: rebuild photos
photos.removeAll()
for (idx, item) in draft.photos.enumerated() where item.image != nil {
    photos.append(RecipePhoto(image: item.image, order: idx))
}
```

The `where item.image != nil` filter drops empty draft slots that
ended up with no bytes (e.g. picker cancel mid-add).

### 7.2 Gallery button — `RecipeEditorView`

Position: after the times row (servings + cook time), before tags.
Same row-style as the existing toolbar/section buttons — left-aligned
glyph + text, full-width tappable area.

```
┌──────────────────────────────────────┐
│ 📚 Photos (3)                        │  ← AppFont.body, AppColor.textPrimary
└──────────────────────────────────────┘
```

- Icon: `photo.stack` SF Symbol.
- Label: `"Photos"` when count == 0, `"Photos (\(count))"` when > 0.
- Tap → presents `PhotoCarouselView` bound to `draft.photos`:
  - `onAdd`: process each picked `Data` through
    `ImageProcessing.prepare(_, for: .gallery)`, append `DraftPhoto`s.
  - `onDelete`: `draft.photos.remove(at: index)`.
  - `onReorder`: stub.

### 7.3 Step images — `StepRowEditor` and `StepQuickAdd`

Today both step row editors render: `[step text field] [TimerToggleButton]`.
We add a third trailing affordance: `[PhotoToggleButton]`.

```swift
// New shared component: Views/Editor/PhotoToggleButton.swift
struct PhotoToggleButton: View {
    @Binding var image: Data?
    var body: some View {
        // photo SF Symbol when nil; photo.fill in AppColor.accent when set.
        // Tap: nil → PhotosPicker, set → action sheet (Replace / Remove)
    }
}
```

This component is **reused** by both `StepQuickAdd` and `StepRowEditor`
— same component, two call sites. DRY.

Layout sizing:

- Tappable area ≥ 44×44pt (matches `TimerToggleButton`).
- Step text field gets `lineLimit(2...)` so the row grows rather than
  truncates. Row may grow ~8pt taller.

Pick flow:
1. `PhotosPickerItem.loadTransferable(type: Data.self)`.
2. `await ImageProcessing.prepare(data, for: .step)` on `Task.detached`.
3. `step.image = processed` on main actor.

### 7.4 Where new files in the Editor live

```
ios-native/Sources/Views/Editor/PhotoToggleButton.swift   ← §7.3
```

That's it for Editor — the rest are modifications to existing files
(see §10).

---

## 8. Detail wiring

### 8.1 Gallery button — `RecipeDetailView`

**Same shape as the editor button (§7.2)**, in the same vertical
position (below times row, above tags). Identical UX — tap → carousel.

The difference is what the carousel binds to:

- **In Detail:** binds to `recipe.photos` directly. Add/remove ops
  mutate the live `@Model` Recipe. Persists immediately, like the
  favorite-toggle does today.
- **In Editor:** binds to `draft.photos`. Persists on Save, discards on
  Cancel.

Two call sites, one component. The `PhotoCarouselView` doesn't know or
care which mode it's in.

In Detail, the closures look like:

```swift
PhotoCarouselView(
    photoData: recipe.sortedPhotos.compactMap(\.image),
    onAdd: { dataArray in
        let processed = await dataArray.asyncMap {
            await ImageProcessing.prepare($0, for: .gallery)
        }
        for (offset, data) in processed.compactMap({ $0 }).enumerated() {
            recipe.photos.append(RecipePhoto(
                image: data,
                order: recipe.photos.count + offset
            ))
        }
        recipe.updatedAt = .now
    },
    onDelete: { index in
        let sorted = recipe.sortedPhotos
        guard sorted.indices.contains(index) else { return }
        modelContext.delete(sorted[index])
        recipe.updatedAt = .now
    }
)
```

(`asyncMap` is a small extension on `Sequence` — write once, use
elsewhere too.)

### 8.2 Step image thumbnails

In the numbered-step rows of Detail, when `step.image != nil`:

```
1.  Heat the oven to 425°F.
2.  Cube the squash into 1-inch pieces.
    ┌────────────┐
    │   100×100  │   ← AppColor.surfaceRaised behind, AppRadius.md corner
    └────────────┘
3.  Toss with olive oil and salt.
```

Thumbnail sits below the step text, indented to the text column.
Tappable: opens an image viewer (next section).

Use `RecipeImageView(data: step.image, contentMode: .fill) { EmptyView() }`.
No placeholder needed — when there's no image, the wrapping check
omits the entire region.

### 8.3 Image viewer for step images

Same `PhotoCarouselView` component, **single-photo mode**:

```swift
PhotoCarouselView(
    photoData: [step.image].compactMap { $0 }
    // no callbacks — view-only
)
```

The carousel collapses to a single page with no add button (no `onAdd`
handler). Long-press to delete is also gone (no `onDelete` handler).
**Same component, three call sites:** editor gallery, detail gallery,
step image viewer. Strong DRY.

If the gallery's `Add` button shouldn't render when no `onAdd` is
provided, the view checks `onAdd` for a non-default value internally.
Same for delete. Implementation detail for the Code session.

---

## 9. Cook Mode wiring

`step.image != nil` → render full-width below the step text:

- `RecipeImageView(data: step.image, contentMode: .fit)` so the user
  sees the whole image without crop.
- ~240pt tall, capped — never blocks the next-step button.
- `AppRadius.lg` corner.
- `AppColor.surfaceRaised` background for letterboxing when aspect
  doesn't match.
- No tap-to-zoom in Cook Mode. The cook is busy, not browsing.

The gallery is **not** shown in Cook Mode. Cook Mode is the cooking
flow, not the recipe's identity (UX principle 3).

---

## 10. File inventory

### New files (4)

```
ios-native/Sources/Lib/ImageProcessing.swift                     ← §4
ios-native/Sources/Views/Components/RecipeImageView.swift        ← §5
ios-native/Sources/Views/Components/PhotoCarouselView.swift      ← §6
ios-native/Sources/Views/Editor/PhotoToggleButton.swift          ← §7.3
```

### Modified files (7)

```
ios-native/Sources/Models/Recipe.swift                ← §2 — add RecipePhoto, photos rel, sortedPhotos, RecipeStep.image
ios-native/Sources/Models/DraftRecipe.swift           ← §3 + §7.1 — DraftPhoto, photos:, image: on DraftStep, apply()
ios-native/Sources/Views/Editor/RecipeEditorView.swift           ← §7.2 — gallery button + sheet binding
ios-native/Sources/Views/Editor/StepQuickAdd.swift               ← §7.3 — PhotoToggleButton
ios-native/Sources/Views/Editor/StepRowEditor.swift              ← §7.3 — PhotoToggleButton
ios-native/Sources/Views/Detail/RecipeDetailView.swift           ← §8 — gallery button + step thumbnails + tap-to-zoom
ios-native/Sources/Views/Cook/CookModeView.swift                 ← §9 — full-width step image
```

### Untouched (verify, don't edit)

- `Lib/RecipeExport.swift` — plain-text export. Photos deliberately
  excluded so round-trip through Notes/Messages stays clean.
- `Lib/RecipeImporter.swift` — text parser. No photo input.
- `Views/Library/RecipeCardView.swift` — **don't add a card cover.**
  User answer: gallery and step images only, no Library card image.
- `WidgetExtension/*` — Live Activity widget doesn't render images.
- `App/RootView.swift` — sheet hoisting unchanged. Coordinators don't
  care about photos.

---

## 11. DRY checklist — what's shared, where

This is the explicit "we don't repeat ourselves" map. If you find
yourself writing a parallel implementation, stop and check this list:

| Concern | Single source of truth | Used by |
| --- | --- | --- |
| Resize + format-preserving re-encode | `ImageProcessing.prepare(_, for:)` | Editor gallery add, Editor step add, Detail gallery quick-add |
| Image rendering + cache + decode-error fallback | `RecipeImageView` | Gallery thumbnails, gallery carousel page, step thumbnails in Detail, step images in Cook Mode |
| Carousel modal UX (swipe, page indicators, add, delete) | `PhotoCarouselView` | Editor gallery (full-edit), Detail gallery (quick-edit), Detail step image viewer (single-photo, view-only) |
| Per-step photo toggle button + picker flow | `PhotoToggleButton` | `StepQuickAdd`, `StepRowEditor` |
| Sorted photos | `Recipe.sortedPhotos` | All callers (mirrors `sortedIngredients` / `sortedSteps`) |
| Storage mechanism | `@Attribute(.externalStorage)` | `RecipePhoto.image`, `RecipeStep.image` |
| Cleanup on delete + replace | SwiftData cascade | All photo deletions |

Three things deliberately **not** unified:

1. **`DraftPhoto` and `RecipePhoto`** are different types. Same shape,
   different concerns (Draft is a transient struct, RecipePhoto is the
   persisted @Model). The closure-based `PhotoCarouselView` is what lets
   them stay separate without forcing a protocol.
2. **`RecipePhoto.image` and `RecipeStep.image`** are two
   `@Attribute(.externalStorage)` declarations, not a shared parent.
   They serve different relationships and have different lifecycles.
3. **Detail-quick-edit gallery and Editor-full-edit gallery** are
   different *bindings* but the same *view* (PhotoCarouselView).

---

## 12. Storage cost

Same as v1 — `.externalStorage` writes blobs as sidecar files inside
the SwiftData container:

| Use | Per-recipe size estimate |
| --- | --- |
| 5 gallery photos | ~2 MB |
| 1 step image × 5 steps | ~1 MB |
| Total: 50 recipes, 5 gallery + 5 step images each | ~150 MB |
| Total: 200 recipes, same density | ~600 MB |

For Lorenzo's actual usage (single user, ~hundreds of recipes), this
is comfortable. iCloud backup includes the SwiftData store, so photos
restore on a device migration — which is correct behavior for a
personal cookbook.

If size becomes an issue, the dial is in `ImageProcessing.Target`:
drop gallery to 1280px and step to 800px would roughly halve the
footprint at the cost of slightly softer images on big screens.
**Don't tune prematurely.**

---

## 13. Risks and mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| `apply(_:)` regression: step images or gallery photos vanish on save | **High** — silent data loss | §3 carry-bytes-through-draft pattern. Tests #6 + #11 in §14 catch it. |
| `loadTransferable(type: Data.self)` returns Live Photo motion + still combined bytes | Storage bloat | Verify with a Live Photo source. If output is suspiciously large, switch to explicit `UIImage.self` transferable + re-encode. |
| `CGImageSource` rejects an exotic HEIC variant from a future iPhone | Falls back to source bytes (~10MB) | The "if re-encoded > source, keep source" guard caps the damage. Add a debug log for source/output sizes during dev. |
| Carousel `.fullScreenCover` collides with Cook Mode's `.fullScreenCover` | Sheet stacking confusion | Carousel only opens from Detail or Editor, not Cook Mode. Different presentation context. |
| First-install over an existing TestFlight build crashes on launch | Migration fail | Adding optional attributes + a new @Model with inverse relationship is a lightweight migration. If crash occurs, the workaround is a clean install (TestFlight build → uninstall → reinstall). Worst case: don't ship photos and existing-data builds simultaneously to non-developer users — but for our single-user case, fine. |
| User adds 10 photos at once, picker hangs while processing | Editor freezes ~5–10s | `Task.detached` for processing + a non-blocking spinner + disable Add button while in-flight. |
| iCloud backup doesn't capture external-storage sidecars | Photos lost on device migration | Out of our hands — relies on iOS SwiftData backup behaving as documented. Document in the master doc rather than code-fix. |

---

## 14. Test plan — must-pass before merge

Walk on real device after each TestFlight install:

1. **Recipe with no photos.** Detail looks identical to today. No
   gallery button "ghost" or empty state weirdness.
2. **Add 1 photo from Editor.** Gallery button appears with "(1)".
   Save, reopen, count persists.
3. **Add 5 photos at once from Detail.** Multi-pick PhotosPicker. After
   processing, count reads "(5)". Photos appear in pick order.
4. **Delete a photo from carousel.** Long-press → confirm. Count decrements
   in real time. Force-quit, reopen — deletion persisted.
5. **Cancel from Editor preserves prior gallery.** Open recipe with 3
   photos. Editor → add 2 more (now 5 in draft). Cancel from dirty
   editor. Reopen — back to 3. Picked bytes never persisted.
6. **🚨 Step images survive an unrelated edit.** Add a step image to
   step 2 of 4. Save. Reopen, change step 1's text only, save. Reopen.
   **Step 2's image must still be present.** §3 regression catch.
7. **Step thumbnail in Detail.** Recipe with one step image renders a
   100×100 thumbnail under that step. Other steps don't. Tap →
   single-photo carousel viewer opens.
8. **Cook Mode step image.** Start cooking. Step with image → full-width
   render below text. Other steps → no image gap. No tap-to-zoom in
   Cook Mode.
9. **Library card unchanged.** Confirm card looks identical to today
   (placeholder + tag chips + dates). No accidental hero leak.
10. **Storage doesn't grow unbounded.** With Settings.app → Storage →
    Llamas Cookbook visible, replace one recipe's photo set 5 times in
    a row. App size should stay roughly flat (one set's worth, not
    five).
11. **🚨 Gallery photos survive an unrelated edit.** Same pattern as
    test #6 but for gallery. Add 3 photos to a recipe. Save. Reopen,
    change title only, save. Reopen. **All 3 photos must still be
    present.** This is the §3 gotcha for `RecipePhoto`.
12. **Memory check on 12MP photo.** Pick the largest photo in the
    library. Editor doesn't hitch visibly. Final stored size is
    reasonable (~400KB, not the source's ~50MB).
13. **Migration from a prior install.** Install previous TestFlight
    build. Create a recipe (no photos — feature didn't exist). Update
    to this build. Old recipe still opens, can be edited, and a photo
    can be added.

Hold the bar at **#1–8 + #11**. If #9, #10, #12, or #13 wobble
slightly, log and ship anyway, fix in the next cycle. **Don't ship
without #6 and #11 passing.**

---

## 15. Sequencing — recommended PR shape

Three pushes minimum, each one CI cycle:

**PR 1 — `feat(model): photo schema + shared image infrastructure`**
- §2 schema additions (RecipePhoto + photos relationship +
  RecipeStep.image).
- §3 + §7.1 DraftRecipe carries bytes; apply() preserves them in BOTH
  loops.
- §4 ImageProcessing.swift (with three-source test).
- §5 RecipeImageView component.
- §6 PhotoCarouselView component (closure-driven, view-only mode
  works with empty closures).
- No UI wiring beyond the new files. Nothing renders yet.
- This is the highest-risk migration push — schema change first, code
  to use it later.

**PR 2 — `feat(gallery): gallery button in Detail + Editor`**
- §7.2 + §8.1 gallery button + carousel binding in both contexts.
- Detail-quick-edit and Editor-full-edit both work.
- Test plan #1–5 + #11.

**PR 3 — `feat(steps): per-step images + thumbnails + Cook Mode`**
- §7.3 PhotoToggleButton in step editors.
- §8.2 Detail step thumbnails + §8.3 single-photo viewer.
- §9 Cook Mode full-width step image.
- Test plan #6–9 + #12.

Why this order:

1. **PR 1 ships infrastructure with no visible change.** Highest risk
   (schema migration), so it gets the most attention. Easy to revert.
2. **PR 2 ships the bigger UX win first** — gallery on every recipe.
3. **PR 3 ships the more complex per-step interaction** with the
   pattern proven.

Plan one retry per PR for the typical "missed an import / needs
`await`" first-pass error, since the dev loop has no Previews.

---

## 16. Out of scope (deliberately deferred)

- **In-app camera capture.** Requires `UIViewRepresentable` —
  violates "no UIKit views" rule. Workflow today: Camera → Photos →
  Picker shows under Recents. One extra app-switch, no code.
- **Drag-to-reorder photos in carousel.** Closure plumbed but unused.
  Add later if needed.
- **Photo captions / metadata.** None in v1.
- **Photo cropping / rotating in-app.** Pick the photo, ship the photo.
- **Library card cover.** Per user direction. Stays placeholder.
- **Photos in Cook Mode.** Per user direction. Step images yes,
  gallery no.
- **Photos in plain-text export.** Plain text round-trips cleanly
  through Notes/Messages/Mail. Don't break that.
- **`Recipe.imageUri` field cleanup.** Stays declared but unused. Drop
  in a follow-up release.
- **Liquid Glass-aware photo overlays** (translucent toolbar over
  carousel page). We're opted out of Liquid Glass for the SDK 26 build —
  see [SDK-Update-Plan.md §2](./SDK-Update-Plan.md). Revisit during
  adoption.

---

## 17. Update these docs after merge

- **STATE.md §1:** add "Gallery (per recipe)" + "Step images" rows.
  Mark "image picker" as no longer pending in §8.
- **STATE.md §3:** update model snippets (RecipePhoto, RecipeStep.image,
  Recipe.photos relationship, sortedPhotos).
- **STATE.md §5:** add `RecipeImageView`, `PhotoCarouselView`,
  `PhotoToggleButton`, `ImageProcessing` to shared-helpers list.
- **Llamas-Cookbook-Master.md §3 / §6 / §7:** flip the placeholder
  rows, list new helpers, document the §3 apply() gotcha so future
  sessions don't regress it.
- **PROJECT.md §9 / §11:** drop "no image picker" from non-goals.
- **ROADMAP.md:** add follow-ups: "remove deprecated `Recipe.imageUri`
  field" + "drag-to-reorder gallery photos" + "captions per photo".
