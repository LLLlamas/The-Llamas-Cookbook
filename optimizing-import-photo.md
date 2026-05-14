# Optimizing Photo and Link Import Accuracy + Speed

Status: research/planning only. No code changes requested here.
Date: 2026-05-14

---

## Implementation Plan (locked 2026-05-14, **shipped 2026-05-14**)

Scope: four pieces of work centered on **streaming the Sonnet vision response** for a dramatic perceived-speed win, plus instrumentation and a cache TTL bump. "Balanced + bimodal" — speed wins that don't risk accuracy. Hard pages target a <2s time-to-first-content via streaming reveal even though full save-ready completion stays at 6-10s.

**Status: all four pieces shipped this session.** See file references at the bottom of this section. CLAUDE.md has been updated with the new invariants.

### Pieces of work

**E. Streaming Sonnet vision response with progressive preview reveal** (primary user-facing change)
Switch the Sonnet vision call to `stream: true`. iOS uses `URLSession.bytes(for:)` + an SSE parser that emits typed events (`onTitle`, `onIngredient`, `onStep`, `onMetadata`) as Anthropic's `input_json_delta` chunks arrive. When the first content streams (~1.5s after request fires), the processing overlay pops directly into `PhotoImportPreviewView` with the title at the top. Ingredients and steps tick into their final positions as bytes stream. Save button stays disabled until `message_stop`.

iOS components:
- `URLSession.shared.bytes(for:)` AsyncSequence in `AnthropicRecipeParser.callAPIWithImages`
- SSE event parser + progressive JSON state machine (each ingredient/step row emits when its JSON object closes — cleaner than field-by-field flicker)
- `PhotoImportPreviewView` gains a streaming-state mode with shimmer placeholders that fade out as content arrives
- Save button disabled until `message_stop`
- Error path: stream interrupted before viable minimum (title + ≥1 ingredient + ≥1 step) → fall back to OCR text path; interrupted after → keep visible content, let user finish in the editor

Worker components:
- Stream Anthropic's response through `TransformStream`; tee one branch to iOS (live), one branch accumulates for KV cache write on successful `message_stop`
- Cache hits remain non-streaming — full body returned immediately with `x-llamas-cache: hit`
- Error responses bypass cache write

Approximate scope: ~300-400 LOC across iOS + Worker.

**F. Remove `What are we cookin'?` title field and Ready/Review state**
Streaming makes the perceived-speed need the title input was filling obsolete — the user sees Sonnet's title within ~1.5s either way. Drop the title input, focus state, Ready/Review card path, title-rescue logic, and the keyboard-handling complexity that came with them. The processing overlay before the preview pop becomes just the glowing llama + status text. Title is read from Sonnet's output (or the local OCR draft on local accept) and the user edits it inline in the preview if they want to change it.

**Implication:** dropping the title field also drops the previously-planned Piece A title chooser and Piece B title-agreement relaxed-accept gate. Without user-typed title, neither has a signal to operate on. We trade the ~5-15% Sonnet → local shift that B provided for UI simplicity + the larger perceived-speed win from streaming. Net cost stays roughly flat vs. today (lose B's savings, lose title-rescue's free local accepts on hard-OCR titles).

**C. Client-side branch timing** (instrumentation, no behavior change)
`os_signpost` for each phase + one `os_log` summary line per import covering `preparePages_ms`, `ocr_ms`, `local_parse_ms`, `vision_first_byte_ms`, `vision_total_ms`, `fallback_ms`, branch chosen, accepted-or-not, time-from-first-byte-to-viable-preview-ms. Never logs recipe content. Mirrors the Worker logs at `parse.js:189-204` for end-to-end timeline correlation. Required to verify E's perceived-speed wins and to unlock any future benchmark-required work.

**D. Extend Anthropic prompt cache TTL from 5 minutes to 1 hour** (modest cost win)
Switch `anthropic-beta` header in `AnthropicRecipeParser.callAPI` and `callAPIWithImages` from `prompt-caching-2024-07-31` to `extended-cache-ttl-2025-04-11`; add `"ttl": "1h"` to the `cache_control` block on the system prompt. For clustered meal-planning sessions (user imports 2-5 recipes in succession), turns near-certain 5min-cache misses into 1h-cache hits. Per cache-hit import: ~$0.01-0.02 saved + ~300-800ms faster TTFT. Pays a small extra cache-write premium on first import in the window; net positive when the user does ≥2 imports per hour. Zero accuracy risk — same prompt, same model, same response shape.

### Locked decisions

- **Priority:** Balanced — speed wins that don't cost accuracy. No changes that need benchmark proof.
- **Speed target:** Bimodal. Easy pages (clean printed, screenshots) under 3s. Hard pages (handwriting, glare, curled) 6-10s acceptable, but with **time-to-first-content ≈ 1.5s** via streaming.
- **Real failure clusters:** handwritten/curled/glare pages; cookbook pages with missing/weak titles — both addressed by streaming (user sees Sonnet's title fast, edits if wrong).
- **Reveal UX:** option 1 — pop `PhotoImportPreviewView` early at first content, fill in place. Network failure rate accepted as low.
- **Import mix focus:** Photo. Link import works well today.

### Aesthetic streaming-reveal spec

Driven by Anthropic's actual token rate; no artificial throttling. Each element appears as a whole unit when its JSON object closes.

- **Title:** appears at first `title` close (~1.5s). 0.4s ease-out fade + 0.95→1.0 scale. Soft haptic. `.accentTextOutline()` letterpress settles in.
- **Ingredient rows:** `spring(response: 0.4, damping: 0.75)`; slide in from leading edge 20pt + fade 0→1. Quantity/unit pill background tinted `accentSoft`.
- **Step rows:** `spring(response: 0.5, damping: 0.8)`; slide in from below 12pt + fade. Step number badge in tinted accent circle.
- **Timer / specialNotes chips:** scale 0.7→1.0 with a 4° wobble; arrive with parent step.
- **Skeleton placeholders** for not-yet-arrived sections: subtle 1.4s pulse cycle matching `.llamaFloat()` rhythm. Fade out as content arrives.
- **Save button:** disabled until `message_stop`. Enable transition: 0.3s fade + scale.
- **No sound effects.** Haptic only on title arrival.

### Expected end-state impact

| Piece | Actual speed | Perceived speed | API cost |
|---|---|---|---|
| E. Streaming + progressive reveal | 0 (same Anthropic tokens/sec) | **−4 to −5s to title visible; −3 to −5s to viable preview** | $0 |
| F. Remove title field | 0 | (covered by E pop) | possibly slightly higher (no title-rescue) |
| C. Branch timing | 0 | 0 | $0 |
| D. 1h cache TTL | −0.3 to −0.8s on cache hits | minimal | −$0.01 to −$0.02 per cache hit (≥2 imports/hr) |

### Cost framing — what changed vs. earlier draft

The earlier draft included Pieces A (title chooser) and B (title-agreement relaxed-accept gate) which together estimated a 25-37% average per-import cost reduction. The streaming-first plan **trades that cost lever** for the much larger perceived-speed win and a simpler UI. Net per-import cost is roughly flat vs. today — the bet is that <2s time-to-first-content matters more to users than $5/mo of Anthropic spend at current scale.

### Explicitly deferred (with reasons)

- **Page reorder UX** — not in reported failure clusters.
- **Lower `max_tokens`** — bimodal target wants hard-page Sonnet quality preserved; truncation risk not worth the small speed delta.
- **OCR `.fast` recognition level** — would degrade accuracy enough to push more pages off the local-accept path.
- **Lower JPEG quality 0.85 → 0.75** — bytes save, doesn't affect Anthropic tokens, possible accuracy hit on small/handwritten text.
- **Pre-OCR image classifier / parallel Sonnet firing** — cost regression on easy cases; needs benchmark proof.
- **OCR confidence stats from `RecipeOCRImporter`** — useful eventually for smarter routing; not needed for current scope.
- **Haiku routing / cutting double-Sonnet OCR fallback / provider bake-off** — all require benchmark proof.
- **Q11 server-side URL fetching/caching through Cloudflare** — real link-import speed win, no direct photo benefit. Photo > link priority this session.

### Questions resolved this session

| # | Resolution |
|---|---|
| 1 | Priority: balanced (speed wins that don't cost accuracy) |
| 2 | Failure clusters: handwriting/glare + missing-weak-titles — both addressed by streaming reveal |
| 3 | Auto-advance: replaced entirely by streaming pop (option 1) |
| 4, 5 | Title conflict: editor handles it post-stream; no pre-Sonnet chooser |
| 11 | Server-side URL fetch: deferred (photo > link priority) |
| 12 | Speed target: bimodal — under 3s easy, 6-10s hard acceptable with <2s to first content |

### Questions still open

- **#6** Benchmark corpus — relevant when Haiku routing / provider bake-off becomes scope.
- **#7** Non-English support.
- **#8** Preserve ingredient section labels (Sauce / Dough / Filling).
- **#9, #10** Link-source priorities — only if Q11 revisited.
- **#13** Per-Pro-user AI spend cap — soft-answered in `user-limit.md`.
- **#14** Metadata-only analytics — already done Worker-side; client-side covered in piece C.

### Files touched this session

**iOS**
- `ios-native/Sources/Lib/AnthropicRecipeParser.swift` — `parseImagesStreaming` + `callAPIWithImagesStreaming` + `consumeSSEStream` + SSE event handler. `buildVisionBody(stream:)` parameter. `extended-cache-ttl-2025-04-11` beta header, `"ttl": "1h"` on cache_control blocks (also in text-path `buildBody`). `os_signpost` wrapper around the streaming HTTP call.
- `ios-native/Sources/Lib/RecipeAIParser.swift` — `parseImagesStreaming` wrapper applies the same quality gate as the non-streaming `parseImages`.
- `ios-native/Sources/Lib/StreamingRecipeParser.swift` (new) — `StreamingRecipeState` (`@Observable @MainActor`), `StreamingRecipeEvent` enum, `SSEEventParser`, `StreamingRecipeAccumulator` (partial-JSON parser with auto-close + complete-array-object counter).
- `ios-native/Sources/Views/Library/ImportFromPhotoView.swift` — removed `titleInput` / `titleFieldFocused` / `readyPayload` state + the `withUserTitleApplied` helper + `readyCard` view. `runImport` now creates a `StreamingRecipeState`, wires its `onFirstContent` to pop the preview, and calls `parseImagesStreaming`. Per-import branch + timing logged via `os_signpost` + `Logger.info`.
- `ios-native/Sources/Views/Library/PhotoImportPreviewView.swift` — added `streamingState` parameter, `effectiveDraft` view-model, skeleton placeholders, `TickIn` modifier, spring animations on ingredient/step inserts, soft haptic on title arrival, Save disabled until `message_stop`.

**Worker**
- `cloudflare-pages/functions/api/parse.js` — stream tee via `ReadableStream.tee()` when request body has `"stream": true`; one branch flows to iOS as SSE, one accumulates and parses into the assembled `messages.create` JSON shape for KV cache write via `context.waitUntil`. Cache hits remain non-streaming. `assembleStreamedResponse` helper added.

**Docs**
- `CLAUDE.md` — updated Photo-import flow, AI parser chain, VisionParseOutcome, Parse-result cache invariants; added `StreamingRecipeState` invariant + Streaming reveal invariant; added `StreamingRecipeParser.swift` to feature map.
- `reducing-cost.md` — status callout updated.

---

Short answer: no, we have not done everything possible yet. The current import system is already strong, especially compared with the original OCR-only/photo plan and basic URL parser. But there are still meaningful gains available in both accuracy and speed, mostly from better measurement, routing, test corpora, and source-specific handling.

The shape I would trust most is:

- Keep Sonnet as the high-accuracy ceiling for hard photo imports.
- Use local/OCR/title-assisted parsing only when confidence is genuinely high.
- Keep link import schema-first because that is fast, cheap, and usually more reliable than AI.
- Add measurement before any more model or prompt churn.
- Build a real import benchmark corpus so future changes can prove they help.

## Current State

### Photo Import

Current strengths:

- Uses Cloudflare proxy, so the Anthropic key is not in the app.
- Uses Claude vision for photo imports, which is the right accuracy move for handwriting, two-column cookbook pages, screenshots, sidebars, and visual layout.
- Has quota enforcement and a parse-result KV cache for exact repeated photo payloads.
- Uses a shared structured-output tool schema and deterministic post-processing.
- Runs local Vision OCR and deterministic parser preflight before Sonnet.
- Shows the processing-title UX while importing: glowing llama, "What are we cookin'?", and a Ready/Review state when typing is still active.
- Lets a user-entered title rescue a local parse if the content is strong but the title OCR is missing.
- Reuses OCR text for fallback so the same pages are not OCR'd twice.

Current photo import flow, as seen in `ImportFromPhotoView.swift`:

```text
Prepare images
  -> local OCR preflight
      -> if local parse is confident: finish without API
      -> else Sonnet vision
          -> if confident: finish
          -> else OCR text + parseBestOf(preferHighQuality: true)
              -> if confident: finish
              -> else edit-as-text fallback
```

Current limitations:

- Hard cases now pay local OCR latency before Sonnet, because OCR preflight is serial.
- Paid photo path still defaults to Sonnet after local preflight. This is accurate, but not fastest or cheapest.
- OCR fallback still calls `parseBestOf(..., preferHighQuality: true)`, so fallback can trigger another Sonnet text call.
- Local confidence gate is conservative and depends on explicit section labels. That is safe, but misses clean pages without "Ingredients"/"Directions" labels.
- User title is currently used only when the parsed title is empty. It does not yet compare user title vs extracted title for agreement/conflict.
- No visible instrumentation for model token usage, prompt-cache hits, route branch, latency, local accept rate, or user edit/save outcomes.
- Current `.aiVision` sizing still appears to be long-edge based; Anthropic recommends both a 1568px dimension cap and about 1.15MP to avoid server resizing.

### Link Import

Current strengths:

- JSON-LD schema.org Recipe parsing is the gold path and is implemented well.
- Recipe instructions recurse through `HowToSection` and `HowToStep`.
- Prep time, cook time, servings, ingredients, and steps are handled.
- Pinterest `SocialMediaPosting.sharedContent.url` follow-through exists.
- TikTok uses public oEmbed for caption/title extraction.
- Instagram/Facebook are blocked with a paste-caption fallback instead of pretending the app can fetch private/authenticated captions.
- Caption no-recipe detection exists.
- The deterministic parser has many hard-won fixes: range quantities, bare-count ingredients, orphan duration merging, step splitting, title cleanup, section labels, OCR repairs, and social caption cleanup.
- URL fetch has a 10MB stream cap and Mobile Safari user-agent, which protects performance and improves compatibility.

Current limitations:

- Generic non-schema pages fall back mostly to OpenGraph title/summary. They do not extract readable article text from HTML and then AI-parse it.
- Client-side URLSession fetches will still hit bot walls, script-rendered pages, cookie gates, and paywalls.
- No persistent URL result cache, so repeat imports of the same recipe link still refetch/reparse.
- No committed automated corpus tests in the repo. The previous docs mention harnesses, but the repo only has screenshot artifacts under `testing/`.
- The parser likely still has edge cases: word-number quantities, component labels, grouped ingredients, ambiguous servings/yield formats, and sites with odd JSON-LD.
- Multiple Recipe nodes are not ranked. The parser returns the first discovered Recipe node, which can be wrong on some pages.

## Have We Maxed Out Accuracy?

No. We have done a lot, but "maxed out" would require proof across a representative import corpus.

The biggest missing accuracy piece is not another prompt rule. It is a repeatable benchmark:

```text
fixed samples
  -> current parser output
  -> expected output
  -> score title / ingredients / steps / times / hallucinations
  -> compare every future change against baseline
```

Without that, it is easy to improve one cookbook page and quietly regress TikTok captions, Pinterest pins, or JSON-LD recipe blogs.

### Photo Accuracy Opportunities

1. Build a private photo corpus.

Suggested mix:

| Category | Count |
|---|---:|
| Clean printed cookbook pages | 25 |
| Handwritten recipe cards | 25 |
| Two-column cookbook/magazine pages | 20 |
| Multi-page recipes | 15 |
| Screenshots from social/blog posts | 15 |
| Bad lighting/glare/curled pages | 15 |
| Non-recipe/noisy pages | 10 |

2. Add OCR confidence stats.

`RecipeOCRImporter` currently keeps the top recognized string per observation, but not confidence, bounding boxes, line density, or language/revision metadata. Local preflight would be smarter if it knew:

- average OCR confidence
- low-confidence line count
- text-line count
- ingredient-shaped line count
- section-label confidence
- whether the layout appears single-column or multi-column

3. Improve title agreement logic.

Current behavior only applies the user title if the parsed title is empty. Better:

- If user title and extracted title agree, raise confidence.
- If extracted title is empty/weak, use user title.
- If they conflict strongly, escalate or show a quick title choice in review.
- Do not treat the user title as absolute truth during model prompting.

4. Add hard/easy routing.

Local OCR preflight is great for cost, but a hard handwritten page probably should not wait for full OCR before Sonnet. Signals that should route quickly to Sonnet:

- low OCR confidence
- very few OCR lines
- handwritten-looking text
- multi-column or dense layout
- more than one page
- glare/curl/blur
- no section labels and weak line structure

5. Consider a two-tier OCR path.

Apple Vision exposes a speed/accuracy tradeoff. The app currently uses accurate OCR. A future benchmark could test:

- fast OCR for quick route classification
- accurate OCR only for local parse candidates
- Sonnet direct for hard pages

This is not obviously better; it needs measurement.

6. Add page review/reorder before processing.

For multi-page imports, the app captures pages in order. Accuracy can collapse if pages are out of order. A lightweight reorder affordance before processing may help more than another model tweak.

7. Handle "multiple recipes in one photo."

Cookbook spreads can show two recipes. The current model prompt expects one recipe. Decide whether to:

- parse the most prominent recipe only
- ask the user to crop/retake
- support multi-recipe extraction later

8. Keep improving deterministic post-processing.

The model gets the hard structure call, but deterministic cleanup still matters:

- timers
- title cleanup
- ingredient quantity/unit normalization
- unsupported title detection
- step splitting
- merging duration-only steps

### Link Accuracy Opportunities

1. Rank multiple JSON-LD Recipe nodes.

Instead of returning the first Recipe node, collect all Recipe nodes and pick the one with the best score:

- highest ingredient count
- highest instruction count
- has title
- has `recipeIngredient`
- has `recipeInstructions`
- not a related recipe card

2. Add readable HTML extraction for non-schema pages.

Current generic HTML path does this:

```text
fetch HTML
  -> JSON-LD Recipe?
  -> else OG title/summary
  -> maybe AI on summary
```

There is a gap for recipe pages that do not publish JSON-LD but do have visible recipe text in the HTML. A Readability-style extractor could produce page text, then run the existing parser/AI path.

Risk:

- More CPU.
- More false positives from nav/footer/comments.
- More privacy disclosure if sent to AI.
- More prompt cost if full article text is large.

3. Add URL result caching.

Repeated links should not refetch or re-AI-parse every time. Cache by normalized canonical URL:

- local device cache first
- optional server/Worker KV later
- include parser version in cache key

4. Better canonical/print/AMP handling.

Some recipe sites expose cleaner pages through:

- canonical URL
- AMP URL
- print recipe URL
- recipe-card plugin endpoints

A future resolver could prefer the cleanest version when found.

5. Keep source-specific routing, but stay conservative.

Pinterest and TikTok already have custom handling. More source-specific importers could help, but they create maintenance burden. Add only when the source is common enough:

- YouTube descriptions
- Reddit recipe posts
- Substack/newsletter recipe pages
- Instagram/Facebook paste or screenshot workflows

6. Add CI parser tests.

The link/social docs mention external harnesses, but the repo does not appear to contain a parser corpus. A future implementation should commit a sanitized parser-test corpus and run it in CI or as a local test command.

## Have We Maxed Out Speed?

No. The current app is optimized more for reliable output than raw latency. That is the right default for recipes, but there are still speed wins.

### Photo Speed Opportunities

1. Measure branch latency first.

Need timings for:

- image prep
- local OCR
- local parse
- Sonnet vision request
- OCR text AI fallback
- preview presentation

Without these, we cannot know whether the new OCR preflight helps or hurts median/P95.

2. Fix image sizing to Anthropic's current guidance.

Anthropic recommends images no larger than about 1.15MP and within 1568px in each dimension to avoid server-side resizing. Current `.aiVision` long-edge-only resizing can still produce portrait images larger than 1.15MP. That can increase time-to-first-token without improving model performance.

3. Add route deadlines.

Instead of always waiting for full local OCR before Sonnet:

```text
start OCR preflight
  -> if confident quickly: use local
  -> if not confident by deadline: start Sonnet
```

Caution: once Sonnet starts, cancellation may not save billing. Use this only if speed is more important than cost for hard cases.

4. Avoid second Sonnet fallback by default.

If Sonnet vision fails, OCR-text Sonnet may recover some cases, but it can also double cost and latency. Benchmark whether OCR-text fallback should be:

- Haiku first
- Sonnet only for specific failure modes
- skipped if Sonnet vision clearly saw the page but returned weak structure

5. Verify prompt caching.

The request includes prompt caching metadata, but the Worker should log:

- `cache_creation_input_tokens`
- `cache_read_input_tokens`
- `input_tokens`
- `output_tokens`
- model
- duration

If cache reads are not happening, cold prompt cost and latency remain higher than expected.

6. Dynamic `max_tokens`.

Current Anthropic calls use `max_tokens: 4096`. Normal cost is based on actual output, but a lower cap can reduce worst-case generation time and pathological output.

Possible values:

- 1536 for one-page photo
- 2048 for multi-page photo
- 3072 only for long recipes

This must inspect `stop_reason` to avoid truncating recipes.

### Link Speed Opportunities

1. Cache normalized URL imports.

This is likely the biggest link speed win. JSON-LD parsing is already fast, but network fetches are not. Repeated imports from popular URLs should hit cache.

2. Add canonical URL normalization.

Normalize away tracking parameters:

- `utm_*`
- `fbclid`
- `gclid`
- `igsh`
- `si`
- `mc_cid`
- `mc_eid`

This improves cache hit rate.

3. Add bounded fetch retries by source.

Some recipe sites fail transiently. A single short retry may help, but do not let link import feel stuck.

4. Consider server-side fetch only if needed.

Moving URL fetch to Cloudflare can improve cache and observability, but may make bot-wall behavior better or worse depending on the site. It also changes privacy and infrastructure complexity.

5. Avoid AI on weak OpenGraph summaries.

AI on a short marketing summary can be fast but wrong. It is better to return partial/paste flow than spend time creating a fake recipe.

## Highest-Value Next Steps

1. Instrument import routes.

Log no content, only metadata:

- route branch
- model
- page count
- image dimensions/bytes
- OCR duration
- OCR confidence summary
- local parse accepted/rejected reason
- Sonnet duration
- fallback duration
- token usage
- user title present
- title agreement/conflict
- preview opened
- saved vs abandoned

2. Build photo and link test corpora.

This is the difference between "feels better" and "is better."

3. Resize AI-vision payloads to Anthropic's no-server-resize budget.

This is a safe speed improvement if verified visually.

4. Improve title-assisted confidence.

The current title field is useful, but the next version should compare typed vs extracted titles rather than only filling empty titles.

5. Add hard/easy photo routing.

Current preflight is safe but serial. Route hard pages to Sonnet faster.

6. Add URL caching and canonical normalization.

This improves both speed and cost for link imports.

7. Add JSON-LD Recipe ranking.

Small implementation, useful accuracy improvement on messy pages.

8. Benchmark Haiku/OpenAI/Gemini only after instrumentation.

Cheaper models may be useful for easy cases, but do not swap based on price.

## What I Would Not Do Yet

- I would not replace Sonnet for hard photo imports without benchmark proof.
- I would not ask the user whether the page is "easy" or "hard." Keep that internal.
- I would not auto-accept Haiku output unless it passes strict evidence checks.
- I would not send full raw HTML to AI without size limits, extraction, and privacy review.
- I would not add source-specific hacks for every site until we know which sites users actually import from.
- I would not keep adding prompt rules indefinitely without a regression corpus.

## Questions For You

1. Which matters most for photo import when there is a tradeoff: fastest preview, lowest AI cost, or lowest chance of a wrong recipe?

2. Are your real photo-import failures mostly:
   - handwritten cards
   - cookbook pages
   - screenshots
   - glare/curled pages
   - multi-page recipes
   - missing titles
   - wrong ingredients/steps

3. Do you want the photo import flow to auto-open preview when processing finishes if the user is not typing, or always show `Ready!` with a `Review Recipe` button?

4. Should the user-entered "What are we cookin'?" title override the extracted title, or should it only fill the title when extraction is empty/weak?

5. If the user typed "Banana Bread" but the model extracted "Lemon Chicken," what should happen?
   - show a title choice
   - trust extracted title
   - trust user title
   - escalate to Sonnet / stronger parse

6. Are you willing to keep a private benchmark folder of real import samples, including photos, for QA? This would make future accuracy work much safer.

7. Do we need non-English recipe import support soon?

8. Do you care about preserving ingredient section labels like "Sauce," "Dough," "Filling," or is flattening all ingredients still fine?

9. For link imports, which sources matter most: recipe blogs, TikTok, Pinterest, Instagram, Facebook, YouTube, Reddit, newsletters, or something else?

10. Are Instagram/Facebook caption-paste fallbacks acceptable, or do you want a screenshot/OCR workflow for social posts?

11. Would you accept server-side URL fetching/caching through Cloudflare if it improves speed/cache hit rate, even though it adds infrastructure and privacy disclosure complexity?

12. What is the target user experience for speed: under 3 seconds, under 5 seconds, or is 6-8 seconds acceptable if the glowing llama/title field makes it feel active?

13. What monthly AI spend per active user or per Pro user is acceptable?

14. Should import analytics be allowed if they log only metadata and never recipe text/images?

## Source Links

- Apple Vision text recognition: https://developer.apple.com/documentation/vision/recognizing-text-in-images
- Apple Vision recognition levels: https://developer.apple.com/documentation/vision/recognizetextrequest/recognitionlevel-swift.enum
- Anthropic Claude vision image sizing: https://docs.claude.com/en/docs/build-with-claude/vision
- Anthropic prompt caching: https://docs.claude.com/en/docs/build-with-claude/prompt-caching
- TikTok embed/oEmbed docs: https://developers.tiktok.com/doc/embed-videos
- oEmbed spec: https://oembed.com/
