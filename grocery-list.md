# Grocery List + Instacart Handoff
Research notes. Do not implement until explicitly decided.
Last updated: 2026-05-12.

---

## Decision so far

- **Feature**: Instacart handoff (not internal-only list, not Amazon Fresh, not DoorDash)
- **Scope**: Per-recipe, with serving size scaling
- **Missing ingredients style**: Lightweight, per-session checklist — user taps off what they already have, remaining items go to Instacart
- **Revenue**: Instacart affiliate program (5% commission on completed orders, 7-day attribution window, tracked via Impact)
- **Timeline**: Post-launch addition (don't block App Store submission)

---

## Why only Instacart

| Service | Public API? | Recipe-to-cart? | Revenue model |
|---|---|---|---|
| **Instacart** | Yes — full developer platform | Yes — POST ingredients → deep link | 5% affiliate via Impact |
| **Amazon Fresh** | No — AWS confirmed no public API | No | Amazon Associates (links only, no cart) |
| **DoorDash** | No (their "recipes" = restaurant menu config) | No | N/A |

Amazon Fresh had one documented third-party integration (Allrecipes, 2017) — that was a special deal, not a public API. DoorDash's developer platform is entirely for restaurant merchants managing kitchen display systems, not consumer grocery carts. **Instacart is the only viable option without a custom partnership deal.**

---

## How the Instacart API works

**Developer Platform**: docs.instacart.com/developer_platform_api
**Approval time**: 30–40 days from application to production keys (not self-serve)

### The flow

1. App POSTs a `line_items` array to the Create Recipe Page endpoint
2. Each line item has: `name` (generic, no brand or weight), optional `measurements` (quantity + unit pairs), optional `filters` (brand, health attributes like `ORGANIC`, `VEGAN`, `GLUTEN_FREE`)
3. Instacart returns a unique URL to a generated recipe page on their marketplace
4. App opens that URL — on mobile it **deep-links directly into the Instacart app** (iOS + Android both supported)
5. User lands in Instacart with a pre-populated cart, picks their store, checks out
6. Instacart requires minimum 40% inventory match to show the recipe page

### Ingredient matching notes
- Instacart matches ingredients fuzzy from the `name` field — use generic names ("all-purpose flour", not "King Arthur Flour")
- Multiple measurement pairs improve matching (e.g., send both grams and cups for the same ingredient)
- Cannot target specific retailers or stores — Instacart determines defaults by user location
- SKU-level targeting is not supported

### Affiliate / revenue
- Program runs through **Impact** (impact.com) — separate signup after API approval
- **5% commission** on the total cart value from orders completed within the attribution window
- Attribution tracked via URL parameters appended to the recipe page URL
- Payment and payout schedules shared privately with partners, not in public docs
- Example math: $80 average cart × 5% = $4/order. Meaningful at scale, negligible early.

---

## What's already built (relevant to implementation)

### `Quantity.scale(_:by:)` — already exists
Located at `ios-native/Sources/Lib/Quantity.swift:66`.

```swift
static func scale(_ original: String?, by factor: Double) -> String? {
    guard let original, !original.isEmpty else { return original }
    if factor == 1 { return original }
    guard let parsed = parse(original) else { return original }
    return format(parsed * factor)
}
```

This already handles: whole numbers, fractions ("1/4"), mixed numbers ("2 & 1/3"), and snaps results to measurable fractions (1/8, 1/4, 1/3, 1/2, 2/3, 3/4). Freeform strings like "a pinch" pass through unchanged.

### `Recipe.servings: Int?` — already exists
Located at `ios-native/Sources/Models/Recipe.swift:20`. The base serving count is already stored per recipe.

### `Ingredient.quantity: String?` and `Ingredient.unit: String?` — already exist
Located at `ios-native/Sources/Models/Recipe.swift:165–166`. Ingredients are already structured — name, quantity string, unit string. No parsing work needed to build the Instacart `line_items` payload.

---

## Implementation breakdown

### Difficulty: Moderate-low overall

The infra is largely in place. The hard parts are the approval wait and unit normalization.

### Phase 1 — In-app checklist UI (no API, ships immediately)
**Effort: 3–5 days**

- Sheet/view triggered from `RecipeDetailView` (a "Shop" or "Grocery List" button)
- Lists all `recipe.ingredients` as checkable rows
- Serving size stepper at the top: default to `recipe.servings ?? 1`, user adjusts up/down
- Each ingredient quantity dynamically rescaled using `Quantity.scale(ingredient.quantity, by: scaleFactor)` where `scaleFactor = newServings / baseServings`
- User unchecks items they already have
- State is ephemeral — no persistence, resets when sheet is dismissed
- "Order on Instacart" button at the bottom (disabled/grayed out if Instacart not yet integrated)
- Zero new dependencies, zero API cost, zero ongoing cost

### Phase 2 — Instacart handoff (requires API keys)
**Effort: 1–2 weeks of dev + 30–40 day approval wait**

- Apply for Instacart Developer Platform access
- Build `InstacartService.swift` in `Sources/Lib/`:
  - Takes `[Ingredient]` + `scaleFactor: Double`
  - Scales quantities, normalizes unit strings (see unit map below)
  - POSTs to Create Recipe Page endpoint
  - Returns URL
- Replace the disabled "Order on Instacart" button with the real handoff: `UIApplication.shared.open(instacartURL)`
- Handle loading state and API errors gracefully (fall back to "Instacart not available" message)

### Phase 3 — Affiliate tracking
**Effort: 1 day**

- Sign up for Impact affiliate program (after API approval)
- Append Impact partner URL parameters to the recipe page URL before opening
- No user-visible change

---

## Unit normalization

Instacart expects standard unit names. Will need a small mapping table:

| Our unit | Instacart name |
|---|---|
| tbsp, tablespoon | tablespoon |
| tsp, teaspoon | teaspoon |
| oz, ounce | ounce |
| lb, pound | pound |
| g, gram | gram |
| kg, kilogram | kilogram |
| ml, mL | milliliter |
| L, liter | liter |
| cup | cup |
| pt, pint | pint |
| qt, quart | quart |
| (blank / freeform) | omit measurements, send name only |

---

## Serving size scaling — design decisions

- Stepper min: 1, max: probably 20 (or uncapped — decide at implementation time)
- If `recipe.servings` is nil, treat base as 1 (scale factor still works, quantities just go 1× → 2× etc.)
- Freeform quantities ("a pinch", "to taste") pass through `Quantity.scale` unchanged — good behavior, no special casing needed
- Display scaled quantities inline in the checklist rows, same format as the recipe editor uses

---

## Open questions (decide before implementing)

1. **Where does the "Shop" entry point live?** Options: button in `RecipeDetailView` toolbar, item in the share/options sheet (`ImportersListSheet`), or dedicated row in the ingredient section.
2. **What happens when `recipe.servings` is nil?** Stepper still works (base = 1), but the label should say something neutral like "Servings: –" vs "Servings: 4".
3. **Privacy disclosure**: Sending ingredient data to Instacart (a third party) likely requires a privacy manifest entry and possibly an in-app disclosure before first use. Confirm with App Store review guidelines before Phase 2.
4. **Instacart not installed**: If user doesn't have the Instacart app, the deep link opens in a browser (Instacart web). Acceptable behavior — no special handling needed.
5. **App Store timing**: Apply for Instacart API access now (30–40 day wait) even if Phase 1 ships first, so keys are ready when we want them.

---

## Competitive landscape

| App | Instacart integration | Personal cookbook | Social layer | Cook Mode |
|---|---|---|---|---|
| **Llamas Cookbook** | Planned | Yes | Yes (CloudKit) | Yes |
| Pepper | Yes | Yes | Yes | No |
| NYT Cooking | Yes | No | No | No |
| WeightWatchers | Yes | No | No | No |
| Feedr | No | Yes (import only) | No | No |
| Crouton | No | Yes | No | No |

Pepper is the closest comp — social + personal cookbook + Instacart. Our differentiation is Cook Mode, friends-following-friends (vs. celebrity chefs), and a deeper editor.

---

## Sources
- [Instacart Developer Platform](https://www.instacart.com/company/business/developers)
- [Instacart Docs — Recipe Page API](https://docs.instacart.com/developer_platform_api/guide/concepts/recipe/)
- [Instacart Docs — Conversions & Affiliate](https://docs.instacart.com/developer_platform_api/guide/concepts/launch_activities/conversions_and_payments/)
- [Instacart Docs — Get Started](https://docs.instacart.com/developer_platform_api/get_started/overview/)
- [AWS re:Post — Amazon Fresh has no public API](https://repost.aws/questions/QUAWoPILDhS_6j458Ih6zAzQ/is-there-an-api-for-amazon-fresh-or-whole-foods)
- [DoorDash — "Recipes" is restaurant menu config only](https://developer.doordash.com/en-US/docs/marketplace/how_to/recipes/)
- [Pepper x Instacart partnership](https://www.supermarketnews.com/grocery-technology/podcast-meet-instacart-s-new-shoppable-recipes-partner-pepper)
