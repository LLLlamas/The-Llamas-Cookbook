# 🦙 Llamas CookBook — Build Spec & Planning Document

> **Owner:** Lorenzo
> **Target Platform:** iOS (via Expo / React Native)
> **Doc purpose:** Single source of truth for Claude Code to scaffold and build the app.
> **Status:** Planning — confirm open questions in §13 before build.

---

## 1. Vision & Product Summary

**Llamas CookBook** is a personal, offline-first iOS recipe keeper designed to eliminate the messy, fragmented way people currently manage recipes (Google tabs, screenshots, bookmarks, Notes app scraps, printed pages). It is a **personal cookbook that lives in your pocket**, with a dedicated in-the-moment **Cook Mode** for when the user is actually at the stove.

It is explicitly **not** a social recipe discovery app. It is a **private, focused tool** for storing, viewing, and cooking from *your own* recipe collection.

**Elevator pitch:**
> *Llamas CookBook is your personal iOS cookbook. Save any recipe once, see it all in one place, and follow along hands-free while you cook. No more 12 open tabs.*

---

## 2. Goals & Non-Goals

### 2.1 Goals (MVP)

1. **Fast recipe capture** — Adding a new recipe takes <60 seconds for a simple dish.
2. **Clean browsing** — Recipes are easy to scan, search, and open.
3. **In-the-moment utility** — Cook Mode keeps the screen awake, enlarges text, and lets users tap to cross off ingredients/steps as they go.
4. **Memory of use** — Users can see when they last cooked a dish (`Last cooked: 04/12/2026`) and how many times.
5. **Full control** — Edit, delete, and annotate any recipe freely.
6. **Offline-first** — Works with zero connectivity. No sign-in required for MVP.

### 2.2 Non-Goals (for v1)

- Recipe discovery / social feed
- AI-generated recipes
- Grocery delivery integrations
- Multi-user sharing / collaboration
- Android (may come later)
- Cloud sync (stretch for v1.1 — see §12 Phase 4)

### 2.3 Success Criteria

- A user can capture a recipe from a website in under 2 minutes using copy/paste.
- A user can open Cook Mode and follow a recipe without ever locking their screen or losing their place.
- 100% of recipe data persists locally across app restarts and reinstalls (within device backup scope).

---

## 3. Target User & User Intent

### 3.1 Primary persona — "The Home Cook Re-Organizer"

Someone who cooks a handful of recipes on rotation plus occasional new ones. They already have their recipes — they're just scattered. They want *one clean place*.

### 3.2 Core user intents (jobs-to-be-done)

| When I'm... | I want to... | So that... |
|---|---|---|
| Discovering a recipe online | Save it to my cookbook | I can find it later without bookmarking |
| Deciding what to cook tonight | Browse my saved recipes | I can pick from what I already trust |
| Actually cooking | See the recipe huge, screen-on, hands-free-ish | I don't lose my place or burn the onions |
| Tweaking a recipe | Edit it or add a note | My cookbook reflects how *I* actually make it |
| Checking rotation | See when I last made something | I don't cook the same thing three times this week |

---

## 4. Core Features (MVP)

### 4.1 Recipe Library (Home)
- Grid or list of all recipes (user-toggleable)
- Search bar (title, ingredient, tag)
- Sort: Recently added / Recently cooked / A–Z / Most cooked
- Filter chips: Favorites, Tags
- Empty state: friendly llama illustration + "Add your first recipe" CTA
- Floating **+** button (FAB) to add a new recipe

### 4.2 Add / Edit Recipe
- Title (required)
- Optional hero image (camera or photo library via `expo-image-picker`)
- Short description
- Servings, prep time, cook time
- **Ingredients** — quick-add input pattern (see §4.3)
- **Steps** — quick-add input pattern (see §4.3)
- Tags (freeform chips: e.g. `dinner`, `pasta`, `quick`)
- Notes field (freeform, markdown-lite)
- Save / Delete / Cancel

### 4.3 Ingredient & Step Input UX (🔑 critical feature)

This is the UX the user explicitly asked us to nail. The pattern:

**For ingredients:**
- One always-visible input row at the top with three thoughtful touch targets:
  - **Qty** (numeric-first keyboard, but allows `1/2`, `½`, etc.)
  - **Unit** (tap opens a scrollable suggestion list: cup, tbsp, tsp, oz, lb, g, ml, clove, pinch, — and free-type is allowed)
  - **Name** (text, e.g. "yellow onion, diced")
- Pressing **Return** on the Name field adds the row and refocuses Qty for rapid entry. Keyboard stays up.
- Added rows appear below, each with:
  - Tap to edit inline
  - Swipe-left to delete
  - Long-press to drag-reorder
- Optional **Paste block** button: user pastes a raw ingredient list (copied from a website), and the app best-effort parses each line into rows. User reviews/edits.

**For steps:**
- Same quick-add pattern: one text field, Return adds and refocuses for the next step.
- Steps are auto-numbered.
- Swipe to delete, long-press to reorder.

### 4.4 Recipe Detail (Read view)
- Hero image (if any)
- Title, description, servings, times, tags
- Ingredients (clean list with checkable dots — but NOT functional outside Cook Mode)
- Steps (numbered)
- Notes block
- Metadata footer: `Added 03/10/2026 · Last cooked 04/12/2026 · Cooked 7 times`
- Actions: `Start Cooking` (primary), `Edit` (secondary), `Favorite` (heart), `Delete` (in menu)

### 4.5 Cook Mode (🔑 the star feature)
- Dedicated full-screen mode, distinct visual treatment (slightly larger type, warm accent background)
- **Screen stays awake** (`expo-keep-awake`)
- Ingredients section: tap any ingredient to **strikethrough** it (state persists only for that cooking session, not across sessions)
- Steps section: same — tap to strike through. Steps also have a subtle "current step" highlight you can advance manually.
- Scaling control: tap servings to scale ingredient quantities in real time (e.g. "Make 2x")
- Timer chips: if a step contains text like "15 minutes," a **Start timer** chip appears next to it (nice-to-have, v1.1 if tight)
- Exit button (top-left) with confirm: *"Mark as cooked?"* — tapping Yes updates `lastCookedAt = now` and increments `cookCount`.

### 4.6 Notes (per-recipe)
- Always available on the recipe detail screen
- Multi-line, auto-saving
- Intended for things like *"use less salt next time"*, *"double the garlic"*, *"grandma's tip: rest the dough overnight"*

---

## 5. Data Model

All data stored locally (AsyncStorage for MVP; migration path to SQLite in §10.3).

```ts
// TypeScript types — canonical source of truth

type ID = string; // uuid v4

interface Recipe {
  id: ID;
  title: string;
  description?: string;
  imageUri?: string; // local file:// path from expo-image-picker
  servings?: number;
  prepTimeMinutes?: number;
  cookTimeMinutes?: number;
  ingredients: Ingredient[];
  steps: Step[];
  notes: string; // default ""
  tags: string[]; // default []
  favorite: boolean; // default false
  lastCookedAt?: string; // ISO 8601
  cookCount: number; // default 0
  createdAt: string; // ISO 8601
  updatedAt: string; // ISO 8601
}

interface Ingredient {
  id: ID;
  quantity?: string; // string to support "1/2", "a pinch", "to taste"
  unit?: string; // "cup", "tbsp", free-form allowed
  name: string; // "yellow onion, diced"
  order: number;
}

interface Step {
  id: ID;
  order: number;
  text: string;
}
```

---

## 6. Screens & Navigation

**Navigator:** React Navigation — Native Stack at root.

```
RootStack
├── Library          (Home — list/grid of recipes)
├── RecipeDetail     (read view)
├── RecipeEditor     (create + edit — same screen, different mode)
├── CookMode         (fullscreen, own visual treatment)
└── Settings         (minimal for MVP: about, data export)
```

- `Library` is the default root.
- `RecipeEditor` is presented as a **full-screen modal** when creating; as a **push** when editing from detail.
- `CookMode` is presented as a **full-screen modal** with a custom slide-up animation.

---

## 7. Key User Flows

### 7.1 Add a new recipe
1. User taps FAB on Library → `RecipeEditor` opens in Create mode.
2. Types title → moves to ingredients → uses quick-add to enter each one.
3. Adds steps via quick-add.
4. (Optional) adds image, tags, notes.
5. Taps **Save** → returns to Library, new recipe at top.

### 7.2 Cook a recipe
1. From Library, user taps a recipe → `RecipeDetail`.
2. Taps **Start Cooking** → `CookMode` slides up.
3. Screen stays awake. User taps each ingredient as they add it (strikethrough).
4. User works through steps, striking through as they complete.
5. Taps **Done** → prompt "Mark as cooked?" → confirms → `lastCookedAt` and `cookCount` update. Returns to detail view.

### 7.3 Edit a recipe
1. From `RecipeDetail`, user taps **Edit** (pencil icon).
2. `RecipeEditor` opens in Edit mode pre-filled with current data.
3. Saves → returns to detail view, showing updates.

### 7.4 Delete a recipe
1. From `RecipeDetail`, user taps overflow menu → **Delete**.
2. Destructive confirmation sheet → confirms → removed, returns to Library.

---

## 8. UX/UI Principles

1. **One-thumb operable.** Everything reachable with the thumb on a 6.1" iPhone. Primary actions live in the bottom half of the screen.
2. **Input friction = death.** The moment adding a recipe feels tedious, the app fails its job. Quick-add patterns, smart defaults, return-key-continues.
3. **Cook Mode is its own world.** Visually distinct so the user always knows "I'm cooking now, the rules are different." Larger type. Calm colors. No distractions.
4. **Gestures over buttons where natural.** Swipe-to-delete, long-press-to-reorder, pull-to-refresh. But every gesture has a visible fallback (e.g. an edit button).
5. **Generous whitespace.** Recipes are already dense. The UI shouldn't add to that.
6. **Silent save.** Edits to notes auto-save. The user never loses data to a missing tap.
7. **Forgiving.** Deletions are confirmed. Undo where cheap. Nothing is ever "accidentally" gone.

---

## 9. Visual Design & Aesthetic

### 9.1 Mood
Warm, inviting, **cookbook-on-the-counter** energy. Think: natural light kitchen, worn paper, handwritten notes in the margins — but rendered with modern iOS polish, not skeuomorphism.

### 9.2 Color palette

| Role | Color | Hex |
|---|---|---|
| Background (warm off-white) | Cream paper | `#FAF6EF` |
| Surface (cards) | Soft white | `#FFFDF8` |
| Primary text | Deep espresso | `#2B2320` |
| Secondary text | Warm stone | `#7A6F66` |
| Brand accent (terracotta) | Llama clay | `#C97C5D` |
| Success / cooked | Sage | `#8AA68A` |
| Destructive | Muted brick | `#B54A3C` |
| Divider | Warm grey 10% | `#E8E1D6` |
| Cook Mode background | Deeper cream | `#F3EADB` |

### 9.3 Typography

- **Display / headings:** `Fraunces` (variable serif) — gives the cookbook feel without being precious. Use weights 500–700.
- **Body:** `Inter` or system `SF Pro` — rock-solid legibility.
- **Ingredient quantities:** tabular numerals (`Inter` variant or SF Pro Rounded).

Scale (approximate):
- Recipe title: 28/34 Fraunces 600
- Section heading: 18/24 Fraunces 600
- Body: 16/24 Inter 400
- Ingredients: 17/26 Inter 400 (bumps to 20/30 in Cook Mode)
- Caption / meta: 13/18 Inter 500 warm-stone

### 9.4 Brand & iconography

- **Llama mascot:** A friendly, stylized llama appears as:
  - App icon
  - Splash screen
  - Empty states (e.g., "No recipes yet — let's add one!")
  - Subtle header accent on Library screen
- **Icons:** Use `lucide-react-native` for a consistent, modern line-icon system. No emoji in UI chrome.
- **Cards:** Rounded corners (16 pt), soft shadow (opacity 0.05, y-offset 4, blur 16), no borders.
- **Motion:** Use default iOS feel. Cook Mode slides up with a slightly slower, more intentional spring.

### 9.5 Dark mode (v1.1)

Design with light mode first. Reserve dark mode for v1.1 — palette will invert to deep-warm-brown backgrounds rather than pure black.

---

## 10. Technical Architecture

### 10.1 Stack

| Layer | Choice | Why |
|---|---|---|
| Framework | **Expo (SDK 52+)** with React Native | Fastest path to iOS from a Windows dev machine. You already know RN. |
| Language | TypeScript | Catches data-model bugs early, which matters for a persistence-heavy app. |
| Navigation | `@react-navigation/native` + native-stack | Standard, well-documented. |
| State | **Zustand** with `persist` middleware | Tiny, explicit, no boilerplate. Perfect for this scope. |
| Storage | `@react-native-async-storage/async-storage` (MVP) | Simple, battle-tested. See §10.3 for upgrade path. |
| Images | `expo-image`, `expo-image-picker` | Performant caching + easy capture flow. |
| Keep-awake | `expo-keep-awake` | One line for Cook Mode. |
| Haptics | `expo-haptics` | Subtle confirmation taps on strikethrough, delete, cook-complete. |
| Icons | `lucide-react-native` | Matches the aesthetic. |
| UUIDs | `expo-crypto` (`randomUUID`) | Native, no polyfill. |
| iOS build | **EAS Build** (cloud) | Required because Xcode can't run on Windows. |
| Device testing | **Expo Go** on iPhone during dev; TestFlight for builds | Fastest iteration. |

### 10.2 Folder structure

```
llamas-cookbook/
├── app.json
├── package.json
├── tsconfig.json
├── App.tsx
├── src/
│   ├── navigation/
│   │   └── RootStack.tsx
│   ├── screens/
│   │   ├── LibraryScreen.tsx
│   │   ├── RecipeDetailScreen.tsx
│   │   ├── RecipeEditorScreen.tsx
│   │   ├── CookModeScreen.tsx
│   │   └── SettingsScreen.tsx
│   ├── components/
│   │   ├── RecipeCard.tsx
│   │   ├── IngredientRow.tsx
│   │   ├── IngredientQuickAdd.tsx
│   │   ├── StepRow.tsx
│   │   ├── StepQuickAdd.tsx
│   │   ├── TagChip.tsx
│   │   ├── EmptyState.tsx
│   │   └── LlamaMascot.tsx
│   ├── store/
│   │   ├── recipesStore.ts          // Zustand store
│   │   └── persistConfig.ts
│   ├── theme/
│   │   ├── colors.ts
│   │   ├── typography.ts
│   │   └── spacing.ts
│   ├── lib/
│   │   ├── parseIngredientLine.ts   // "2 cups flour" → { qty, unit, name }
│   │   ├── formatDate.ts
│   │   └── ids.ts
│   └── types/
│       └── recipe.ts                 // TS interfaces from §5
└── assets/
    ├── icon.png
    ├── splash.png
    └── llama/
        ├── llama-mascot.svg
        └── llama-empty.svg
```

### 10.3 Persistence strategy & migration path

**MVP:** Zustand + AsyncStorage persist. All recipes kept in a single JSON blob. Fine up to a few hundred recipes.

**v1.1 / later:** If the library grows (500+ recipes or complex queries), migrate to `expo-sqlite` with a thin repository layer. Abstract storage behind a repository interface from day one so this migration is painless:

```ts
// src/store/recipesRepo.ts
export interface RecipesRepo {
  getAll(): Promise<Recipe[]>;
  getById(id: string): Promise<Recipe | null>;
  upsert(recipe: Recipe): Promise<void>;
  delete(id: string): Promise<void>;
}
```

Zustand uses this repo under the hood. Swapping backends later = one file.

### 10.4 State shape (Zustand)

```ts
interface RecipesState {
  recipes: Record<ID, Recipe>;
  hydrated: boolean;

  // selectors
  list: () => Recipe[];
  getById: (id: ID) => Recipe | undefined;

  // mutations
  addRecipe: (input: Omit<Recipe, 'id'|'createdAt'|'updatedAt'|'cookCount'>) => Recipe;
  updateRecipe: (id: ID, patch: Partial<Recipe>) => void;
  deleteRecipe: (id: ID) => void;
  markCooked: (id: ID) => void; // sets lastCookedAt + cookCount++
  toggleFavorite: (id: ID) => void;
}
```

---

## 11. Project Structure & Setup Commands

```bash
# 1. Scaffold
npx create-expo-app@latest llamas-cookbook --template blank-typescript
cd llamas-cookbook

# 2. Install runtime deps
npx expo install expo-image expo-image-picker expo-keep-awake expo-haptics expo-crypto
npm install @react-navigation/native @react-navigation/native-stack
npx expo install react-native-screens react-native-safe-area-context
npm install zustand
npm install @react-native-async-storage/async-storage
npm install lucide-react-native react-native-svg
npx expo install @expo-google-fonts/fraunces @expo-google-fonts/inter expo-font

# 3. iOS build later
npm install -g eas-cli
eas login
eas build --platform ios --profile development
```

---

## 12. Implementation Phases

Each phase is a clean stopping point where the app is shippable.

### Phase 0 — Foundation (0.5 day)
- Scaffold Expo TS project
- Install deps, set up navigation skeleton, theme files, font loading
- Empty screens with placeholder text
- Git repo + initial commit

### Phase 1 — Core CRUD (2 days)
- `types/recipe.ts` + Zustand store with AsyncStorage persist
- `LibraryScreen`: list of recipes (start with list view), empty state
- `RecipeEditorScreen`: all input fields, quick-add for ingredients & steps
- `RecipeDetailScreen`: read view
- Create, edit, delete flow fully working
- **Milestone:** user can add a recipe, see it, edit it, delete it.

### Phase 2 — Cook Mode (1.5 days)
- `CookModeScreen`: larger type, distinct background
- Strikethrough state (session-local)
- `expo-keep-awake` wired up
- Cook complete → `markCooked` action → metadata updates
- "Last cooked" + cook count on detail screen
- **Milestone:** user can cook from the app end-to-end.

### Phase 3 — Polish (1.5 days)
- Hero images via `expo-image-picker`
- Search (title + ingredient + tag)
- Favorites, sort, tag filter chips
- Haptics on strikethrough and mark-cooked
- Llama mascot on empty state + app icon/splash
- **Milestone:** shippable MVP.

### Phase 4 — Stretch / v1.1 (later)
- Smart ingredient paste-parsing (`parseIngredientLine.ts` robust version)
- Step timer chips (auto-detect "15 minutes" → Start Timer button)
- Recipe import from URL (scrape schema.org/Recipe JSON-LD)
- Shopping list generation from selected recipes
- iCloud or Supabase sync
- Dark mode
- Grid view toggle on Library
- Migrate persistence from AsyncStorage → SQLite (if needed)
- iPad layout
- Android

---

## 13. Open Questions / Decisions for Lorenzo

Please confirm these before Claude Code begins, or let Claude Code pick sensible defaults.

1. **Stack confirmation:** React Native (Expo) is recommended given your Windows dev environment and React Native experience. Alternative is native SwiftUI, but that requires a Mac. **Confirm Expo?**
2. **Recipe image in MVP:** Include from day one (Phase 1), or defer to Phase 3? *Recommendation: defer — don't let image UX block core CRUD.*
3. **Cloud sync:** MVP is local-only. Fine to ship that way, or do you want Supabase sync in v1?
4. **URL import:** Paste a recipe URL, app scrapes it — stretch goal or MVP? *Recommendation: stretch. Real users can copy/paste the ingredient block into the paste-parser.*
5. **Units:** Do you want unit conversion (cups ↔ grams) in v1 or later? *Recommendation: later.*
6. **Sharing:** Export/share a recipe as text or PDF in v1? *Recommendation: simple "Share as text" via iOS share sheet is cheap and valuable.*
7. **App icon / llama mascot:** Do you have artwork or should Claude Code generate a placeholder llama SVG?
8. **Bundle ID / naming:** `com.lorenzo.llamascookbook` okay, or something else? Needed for EAS.

---

## 14. Appendix — Claude Code Kickoff Prompt

Copy-paste this into Claude Code after this doc is in the project root as `PLAN.md`:

> I'm building **Llamas CookBook**, an iOS recipe app. The complete spec is in `PLAN.md` at the repo root — please read it fully before starting.
>
> **First task: Phase 0 — Foundation only.** Scaffold the Expo TypeScript project following the folder structure in §10.2, install every dependency listed in §11, set up:
> - `src/theme/` with the color palette, typography scale, and spacing tokens from §9
> - Google Fonts loading (Fraunces + Inter) with a splash screen that waits for font load
> - `src/navigation/RootStack.tsx` wiring Library, RecipeDetail, RecipeEditor, CookMode, Settings screens as empty stubs
> - `src/types/recipe.ts` with the interfaces from §5
> - `src/store/recipesStore.ts` with the Zustand + persist skeleton from §10.4 (stub the mutations, implement `list` and `getById`)
> - A minimal `LibraryScreen` that reads from the store and shows either the empty state or a placeholder list
>
> Do **not** build any Phase 1+ features yet. When Phase 0 is done, show me the file tree and one screenshot of the running app in Expo Go, then wait for approval before starting Phase 1.
>
> Open decisions from §13 — use these defaults unless I override: Expo confirmed, images in Phase 3, local-only MVP, URL import deferred to stretch, no unit conversion v1, iOS share sheet as share method, placeholder llama SVG is fine, bundle id `com.lorenzo.llamascookbook`.

---

*End of spec. Questions, gaps, or course corrections → edit this doc before handing it to Claude Code.*
