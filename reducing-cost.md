# Reducing Photo Import Cost and Latency

Status: research only, no implementation changes.
Date: 2026-05-14

This document reviews the current Llamas Cookbook photo import implementation and outlines ways to reduce usage-token cost and processing time without weakening the import feature.

## Executive summary

The current photo path optimizes for quality first:

1. Prepare up to 3 page images.
2. Send image(s) to Claude Sonnet 4.6 vision through the Cloudflare proxy.
3. If the vision draft is not confident, run on-device OCR and send the OCR text through `parseBestOf(..., preferHighQuality: true)`, which also uses Sonnet.
4. If both fail, let the user edit OCR text manually.

That explains the observed cost of about `$0.04` per typical photo import and the 6-8 second latency. A single Sonnet cache-miss vision call with the current long prompt, tool schema, one image, and a structured output lands around `$0.035-$0.045`. A fallback OCR-text Sonnet call can make a difficult import cost materially more.

The best near-term plan is not to remove Sonnet. It is to make Sonnet the final escalation path instead of the default for every photo:

1. Add usage/latency instrumentation first.
2. Fix image sizing so Claude does not server-resize common portrait images.
3. Validate prompt caching with real `usage` fields.
4. Add a local OCR/regex confidence gate for clean printed pages.
5. Add an optional title-entry moment while processing: "What are we cookin'?"
6. Use Claude Haiku 4.5 vision or OCR-text only when the import looks easy enough.
7. Route hard-looking pages directly to Sonnet instead of forcing a Haiku-then-Sonnet serial path.

Expected outcome if the benchmark confirms quality:

- Clean printed photos: `$0.00` to `$0.005`, often faster than current.
- Average AI-assisted photo: `$0.006-$0.015` when routed to local/Haiku for easy cases.
- Hard handwriting/two-column cases: keep current Sonnet quality, still around `$0.02-$0.05` depending on cache/fallback.
- Overall blended savings likely 50-80% if even half of photo imports avoid Sonnet.

The title-entry idea mostly improves perceived speed and confidence. By itself, a user-entered title adds only a few input tokens and does not materially reduce API cost. It saves money only when it lets the app safely accept a local/OCR/Haiku result that would otherwise have escalated to Sonnet because the title was missing or ambiguous.

Provider switching may reduce cost further. OpenAI GPT-5 nano/GPT-5.4 nano and Gemini 2.5 Flash-Lite are dramatically cheaper on paper, but that should be treated as a separate bake-off because accuracy on handwritten cards, cookbook layout, and no-fabrication behavior is the real product requirement.

## Current repository findings

### Source-of-truth docs

- `CLAUDE.md` is the source of truth and supersedes older plans where they conflict.
- `picture-import-implementation.md` is stale in one important way: it says photo import is OCR-first and that photos are never sent to an API. Current code sends prepared JPEG page images to Claude vision first.
- `implement-new-ai-import.md` is useful background, but several items have already shipped: Cloudflare proxy, prompt caching, quota enforcement, image vision, and KV result caching.

### Current code path

Relevant files:

- `ios-native/Sources/Views/Library/ImportFromPhotoView.swift`
- `ios-native/Sources/Lib/ImageProcessing.swift`
- `ios-native/Sources/Lib/RecipeAIParser.swift`
- `ios-native/Sources/Lib/AnthropicRecipeParser.swift`
- `ios-native/Sources/Lib/RecipeOCRImporter.swift`
- `cloudflare-pages/functions/api/parse.js`
- `ios-native/Sources/Lib/QuotaService.swift`
- `cloudflare-pages/functions/api/usage.js`
- `cloudflare-pages/functions/api/usage/consume.js`

Current photo flow in `ImportFromPhotoView.runImport`:

1. `preparePages` creates two image versions per page in parallel:
   - `.aiVision`: 1568px long-edge JPEG.
   - `.ocr`: 2560px OCR image.
2. `RecipeAIParser.parseImages` sends the `.aiVision` JPEGs to Anthropic.
3. `RecipeAIParser.parseImages` hardcodes `AnthropicRecipeParser.Model.sonnet`.
4. If Sonnet image vision returns a confident draft, the preview opens.
5. Otherwise, the app runs Vision OCR locally and calls `RecipeAIParser.parseBestOf(ocrText, preferHighQuality: true)`, which also routes to Sonnet.

Current text/link path:

- JSON-LD recipe schema skips AI.
- TikTok captions and weak OpenGraph summaries may use `parseBestOf` with the default model, which is Haiku.
- Text/link imports do not send photo quota headers and are not gated.

Current Worker behavior in `cloudflare-pages/functions/api/parse.js`:

- Non-photo imports forward directly to Anthropic.
- Photo imports require `x-llamas-user`.
- Photo cache key is `parseCache:<PROMPT_VERSION>:<contentHash>`.
- `contentHash` is derived from exact image bytes in the request body.
- Cache hits skip the daily parse counter but still pre-check monthly quota.
- Cache misses increment daily parse attempts, check monthly quota, forward to Anthropic, then cache valid tool-use responses for 7 days.

Important caveat for future work:

- The parse-result cache key does not include model ID. That is safe today because photo vision always uses Sonnet. If a future implementation tests Haiku vision and Sonnet vision through the same endpoint, include `model` in the cache key or keep separate cache namespaces.

### Current prompt and token footprint

Rough local estimate using `chars / 4`:

| Piece | Approx chars | Approx tokens |
|---|---:|---:|
| `RecipeAIParser.instructions` | 22,334 | 5,584 |
| Anthropic tool schema | 3,051 | 763 |
| Vision user prompt | 773 | 193 |

The stable cached prefix is roughly `6.3k` tokens before image/text input. Exact counts should be measured with Anthropic's `/v1/messages/count_tokens` endpoint because Anthropic tokenization and tool overhead can differ from the rough estimate.

The prompt is long because it encodes many real failure modes:

- No fabrication.
- Step splitting.
- Reverse-form metadata.
- OCR repairs.
- Two-column cookbook interleaving.
- Alternative methods.
- Sidebars and decorative cookbook content.
- Four worked examples.

This prompt probably contributes to accuracy, so do not blindly trim it before benchmarking.

## Why the current cost is around $0.04

Official Anthropic pricing as of this research:

| Model | Input | 5m cache write | Cache hit/read | Output |
|---|---:|---:|---:|---:|
| Claude Sonnet 4.6 | $3 / MTok | $3.75 / MTok | $0.30 / MTok | $15 / MTok |
| Claude Haiku 4.5 | $1 / MTok | $1.25 / MTok | $0.10 / MTok | $5 / MTok |

Assumptions for a one-page import:

- Static prefix: about 6,300 tokens.
- Vision prompt text: about 200 tokens.
- Image: up to about 1,600 tokens if sized according to Anthropic guidance.
- Output: about 700-1,200 tokens for a structured recipe.

Estimated one-page Sonnet cost:

| Scenario | Estimated cost |
|---|---:|
| Sonnet cache miss, 700 output tokens | about $0.035 |
| Sonnet cache miss, 1,200 output tokens | about $0.043 |
| Sonnet cache hit, 700 output tokens | about $0.018 |
| Sonnet cache hit, 1,200 output tokens | about $0.025 |

This lines up with the reported `$0.04` typical import. It suggests typical imports are probably cache misses, high-output calls, multi-page calls, or occasionally double-calling Sonnet through the OCR fallback.

Estimated one-page Haiku cost with the same prompt:

| Scenario | Estimated cost |
|---|---:|
| Haiku cache miss, 700 output tokens | about $0.013 |
| Haiku cache miss, 1,200 output tokens | about $0.016 |
| Haiku cache hit, 700 output tokens | about $0.005 |
| Haiku cache hit, 1,200 output tokens | about $0.008 |

Haiku is roughly 3x cheaper than Sonnet on both input and output, and Anthropic describes Haiku 4.5 as the fastest current Claude model.

## Biggest cost and speed opportunities

### 1. Instrument before optimizing

Priority: highest.
Risk: low.
Expected benefit: makes every other decision measurable.

Right now the Worker forwards Anthropic responses but does not record enough cost details for model, prompt cache, output tokens, fallback branch, or latency. Before changing the model cascade, log the following in the Worker, with no recipe text or image bytes:

- `request_id`
- `user_hash`
- `import_kind`
- `model`
- `page_count`
- prepared image dimensions and byte sizes
- `cache_key_version`
- Worker KV cache hit/miss
- upstream status
- upstream duration_ms
- total Worker duration_ms
- `usage.input_tokens`
- `usage.cache_creation_input_tokens`
- `usage.cache_read_input_tokens`
- `usage.output_tokens`
- estimated cost_usd
- whether response had valid `structured_recipe`
- app outcome if available later: preview opened, saved, edited, abandoned

Why this matters:

- Anthropic prompt caching failures are silent if the cacheable prefix is under the model minimum or the prompt changes.
- Anthropic exposes cache usage in response `usage` fields.
- Current `$0.04` observed cost is consistent with cache misses.
- Future Haiku/Sonnet A/B work needs hard data, not vibes.

Implementation note for a future agent:

- Parse `responseText` in `parse.js` after upstream returns.
- Extract `responseBody.usage`.
- Do not log raw `content`, image base64, OCR text, or recipe text.
- Consider Cloudflare Analytics Engine, Logpush, Workers Logs, or a compact KV rolling aggregate.
- Cloudflare AI Gateway is also worth evaluating because it can add provider-level logs, token usage, duration, cache status, and cost dashboards.

### 2. Verify prompt caching is actually working

Priority: highest.
Risk: low.
Expected benefit: 35-55% lower Sonnet cost on repeated imports within the TTL.

The code marks the system prompt with:

```json
"cache_control": {"type": "ephemeral"}
```

That should cache a prefix including tools plus system prompt. The current prefix is above current model minimums:

- Sonnet 4.6 cache minimum: 2,048 tokens.
- Haiku 4.5 cache minimum: 4,096 tokens.
- Current estimated prefix: about 6,300 tokens.

If cache reads are not happening, likely causes:

- Calls are spaced more than 5 minutes apart.
- The prompt or tool schema bytes differ across calls.
- JSON key ordering changes enough to break exact matching.
- The beta/header behavior changed and the request shape should move to the current documented top-level `cache_control` or stable explicit breakpoints.
- The app is measuring first imports or cold imports only.

Recommended checks:

1. Add usage logging.
2. Confirm `cache_creation_input_tokens` is non-zero on first call.
3. Confirm `cache_read_input_tokens` is non-zero on the next identical-shape call within 5 minutes.
4. Test both text and image requests.
5. Test Haiku and Sonnet separately.

Do not assume prompt caching is saving money until this is visible in logs.

### 3. Fix `.aiVision` image sizing

Priority: high.
Risk: low if benchmarked visually.
Expected benefit: lower upload bytes and lower time-to-first-token; possible token savings depending on provider accounting.

`ImageProcessing.Target.aiVision` currently caps the long edge at 1568px. The code comment says this avoids Anthropic server-side downscaling, but Anthropic's current vision docs include a second constraint: keep images around 1.15 megapixels / about 1,600 image tokens. A common 3:4 portrait image at 1176x1568 is about 1.84 MP and roughly 2,459 image tokens by Anthropic's `width * height / 750` estimate, so Anthropic may still downscale it server-side.

Anthropic says oversized images increase time-to-first-token without improving model performance. The app should resize client-side to satisfy both constraints:

- long edge <= 1568
- total pixels <= about 1,200,000
- no upscaling

Formula:

```swift
let maxPixels = 1_200_000.0
let scale = min(
    1.0,
    1568.0 / Double(max(width, height)),
    sqrt(maxPixels / Double(width * height))
)
```

Expected common targets:

| Aspect ratio | Current long-edge-only output | Better target |
|---|---:|---:|
| 1:1 | 1568x1568 | about 1092x1092 |
| 3:4 | 1176x1568 | about 951x1268 |
| 2:3 | 1045x1568 | about 896x1344 |
| 1:2 | 784x1568 | about 784x1568 |

Keep OCR images at 2560px. This recommendation is only for the remote vision payload.

Also consider testing JPEG quality `0.75-0.80` for `.aiVision`. Anthropic bills image tokens by dimensions, not bytes, so JPEG quality mainly affects upload latency and bandwidth, not token cost. Do not lower quality unless small text and handwriting accuracy stay flat.

### 4. Add a local/free confidence gate before paid AI

Priority: high.
Risk: medium if the confidence gate is too lax.
Expected benefit: zero-cost imports for clean printed pages.

The app already has a strong on-device OCR pipeline and deterministic parser. Current photo flow only runs OCR after Sonnet vision fails. For clean printed pages, this means the app may pay Sonnet even when local OCR plus regex could have produced a good draft.

Recommended future cascade:

1. Prepare images.
2. Run Vision OCR locally.
3. Run `RecipeImporter.parse(ocrText)`.
4. If local draft is highly confident, return it without any API call.
5. Otherwise continue to paid AI.

The confidence gate must be stricter than `photoImportConfident`, which only checks title + ingredients + steps. Suggested local accept criteria:

- title is non-empty
- ingredients count >= 3
- steps count >= 2
- no step longer than 220 chars
- at least one ingredient has quantity or unit
- source text has section signals like `ingredients`, `directions`, `instructions`, or strong line/block structure
- OCR confidence average above threshold if available from Vision observations
- no obvious decorative/page-number-only draft

This should be benchmarked. If it accepts only obvious wins, it cannot harm the hard cases because those still escalate.

Speed trade-off:

- Local OCR may complete much faster than current 6-8 second Sonnet calls for clean pages.
- For hard pages, serial OCR-first can add latency before AI. Mitigate by using a short local preflight deadline or only accepting fast/high-confidence OCR. Avoid starting an expensive AI call in parallel if the goal is cost reduction, because cancellation may not prevent billing.

### 5. Add UX-assisted title capture while processing

Priority: high.
Risk: low for UX, medium if the title is over-trusted.
Expected benefit: better perceived speed, fewer title failures, and more safe local/cheap accepts.

Proposed user-facing flow:

```text
User taps Process Recipe
  -> processing starts immediately in the background
  -> glowing processing llama stays visible
  -> title field appears:

     What are we cookin'?
     [ Banana bread ]

  -> when processing finishes:

     Ready!
     [Review Recipe]
```

Do not ask the user whether the page is easy or cheap to process. The routing decision should stay internal. The user should only see a friendly optional title field while the app is already working.

Do not auto-navigate away when processing completes. If the user is typing, auto-navigation would feel like the app interrupted them. Prefer a calm `Ready!` state with a `Review Recipe` button. This keeps user agency, gives the app a natural place to wait for the final title text, and still hides part of the 6-8 second processing time.

How to use the user title safely:

- If the extracted title is empty or weak and ingredients/steps are strong, use the user title to satisfy the title part of the confidence gate.
- If the extracted title and user title roughly agree, increase confidence in the local/cheap result.
- If they strongly conflict, do not blindly overwrite. Escalate to Sonnet or carry both values to the review screen.
- Do not inject the title into the model as "the recipe is definitely X." At most, treat it as a low-weight hint. The safest first implementation is post-parse validation/override only.

This is especially valuable because the current `photoImportConfident` check requires title + ingredients + steps. Many local/OCR parses may have good ingredients and steps but a missing or ugly title. A user-provided title can turn those into zero-cost accepts without compromising recipe content.

Raw token impact of the title field:

- User title length: usually 2-8 words, about 5-20 input tokens.
- Sonnet cost for 20 extra input tokens: about `$0.00006`.
- Haiku cost for 20 extra input tokens: about `$0.00002`.

So the title field does not save meaningful money by reducing prompt tokens. It saves money only by helping the app skip or avoid Sonnet calls.

### 6. Use Haiku selectively before Sonnet

Priority: high.
Risk: medium, requires benchmark.
Expected benefit: roughly 60-75% lower paid-call cost in accepted cases, likely lower latency.

Current code already has both model IDs:

- `AnthropicRecipeParser.Model.haiku = "claude-haiku-4-5-20251001"`
- `AnthropicRecipeParser.Model.sonnet = "claude-sonnet-4-6"`

All current Claude models support image input, so Haiku can be tested on the same vision request shape.

Recommended paid cascade:

1. OCR text + Haiku for clean-enough OCR text.
2. Haiku vision for easy-looking layout candidates.
3. Hard-looking pages should go directly to Sonnet.
4. Sonnet vision only after Haiku when the page looked easy enough for Haiku but the output failed a strict support/confidence check.
5. Avoid a second Sonnet OCR-text fallback unless there is evidence it recovers cases Sonnet vision misses.

Important latency caveat:

- An unconditional Haiku-first strategy can make hard cases slower, because the app pays the Haiku latency and then the Sonnet latency.
- The correct strategy is routing, not always-on serial fallback.
- Signals like low OCR confidence, handwriting, multi-page scans, two-column layout, glare, curled pages, or very low local parse confidence should skip Haiku and go straight to Sonnet.

Acceptance for a cheap model should be stricter than for Sonnet:

- Draft passes title + ingredients + steps.
- Ingredient and step counts are plausible relative to OCR/regex.
- Title and step tokens are supported by OCR text when OCR text exists.
- No suspicious unsupported verbs or invented dish names.
- No extreme compression, such as one huge step.

This preserves functionality because Sonnet remains the fallback for uncertain cases.

Potential cost impact:

- If Haiku handles 50% of paid photo imports, blended AI cost can drop roughly 30-40%.
- If local OCR handles 25% and Haiku handles another 50%, blended cost can drop roughly 60%+.
- If Sonnet still handles the hard 25%, quality for hard cases remains unchanged.

### 7. Stop untracked/double-paid fallback patterns

Priority: high.
Risk: low.
Expected benefit: prevents surprise cost and makes quota truthful.

When Sonnet image vision returns no usable draft but no quota error, `ImportFromPhotoView` runs OCR and then calls:

```swift
RecipeAIParser.parseBestOf(ocrText, sourceUrl: nil, preferHighQuality: true)
```

That sends a second Sonnet request through the text path. It does not send `x-llamas-import-kind: photo`, so the Worker treats it as unmetered text/link usage:

- no photo quota classification
- no photo KV parse-result cache
- no daily/monthly photo accounting
- likely no app-level visibility as part of photo import cost

Future implementation should classify OCR fallback as a photo fallback in the Worker, even if it does not increment the daily attempt twice. At minimum, log it as `photo_ocr_fallback` and include it in cost accounting.

Recommended cascade change:

- If image vision fails quality, try OCR local parse.
- If OCR local parse is not enough, try OCR text with Haiku.
- Escalate to Sonnet only once per attempt unless a benchmark proves the double-Sonnet strategy is worth the cost.

### 8. Improve parse-result cache keys

Priority: medium.
Risk: low.
Expected benefit: correctness for future model experiments; modest cost savings.

Current photo result cache:

```js
parseCache:<PROMPT_VERSION>:<contentHash>
```

Future cache key should include:

- prompt version
- model ID
- tool schema version
- vision prompt version
- normalized page count
- image content hash

Suggested:

```js
parseCache:v2:model=<model>:schema=<schemaVersion>:prompt=<promptVersion>:hash=<contentHash>
```

The current cache also hashes exact prepared JPEG bytes. That is good for same-session retries but weak for re-photographed pages. Later options:

- OCR text hash cache for OCR fallback.
- Perceptual image hash for same page with slight crop/rotation differences.
- URL-level result cache for link imports.

Keep this modest. Exact byte hash is simple and safe; perceptual or semantic cache can return wrong results if too aggressive.

### 9. Prompt compaction, but only after measuring

Priority: medium.
Risk: medium to high.
Expected benefit: lower cold-cache cost and lower latency.

The current prompt is around 5.6k tokens by rough estimate, and the tool schema adds around 0.8k. This is a large part of each cache miss.

Possible optimizations:

- Remove duplicate guidance between the system prompt and `visionUserPrompt`.
- Move some edge-case repairs out of the prompt and into deterministic post-processing.
- Split prompts by source:
  - compact text prompt for OCR/social captions
  - layout prompt for image vision
  - full prompt only for Sonnet fallback
- Reduce worked examples from 4 to 2 for the first-pass Haiku prompt.
- Keep the full prompt for Sonnet fallback if accuracy depends on it.

Important caching warning:

- Haiku 4.5 requires a 4,096-token minimum cacheable prefix.
- If the prompt is compacted below that, Haiku prompt caching may silently stop.
- This may still be fine because Haiku is cheap, but it should be intentional.

Do not trim the no-fabrication and support-check guidance casually. The app's user trust depends more on not inventing recipe details than on saving a fraction of a cent.

### 10. Lower `max_tokens` carefully

Priority: low to medium.
Risk: medium for long recipes.
Expected benefit: lower worst-case output and lower rate-limit reservation, not necessarily lower normal cost.

Current calls use:

```json
"max_tokens": 4096
```

Anthropic bills actual output tokens, not the `max_tokens` ceiling, so lowering this does not save much on normal successful calls. It can still help:

- cap pathological output
- reduce output-token-per-minute reservation
- reduce the blast radius of prompt drift

Suggested benchmark values:

- 1536 for one-page recipes
- 2048 for multi-page recipes
- 3072 only for unusually long multi-page recipes

If this is changed, inspect `stop_reason` and treat `max_tokens` truncation as a retry/escalation condition.

## Recommended future implementation plan

### Phase 0: Measurement baseline

Goal: know exact current cost and latency before changing behavior.

Tasks:

- Add Worker usage logging for Anthropic `usage`.
- Add branch labels:
  - `sonnet_vision`
  - `ocr_local`
  - `ocr_haiku`
  - `ocr_sonnet`
  - `haiku_vision`
  - `sonnet_fallback`
- Log page count, image dimensions, image bytes, Worker cache hit/miss, prompt cache read/write tokens, model, duration.
- Add a debug-only way to surface request IDs in the app for manual QA.
- Verify prompt caching within 5 minutes.

Success criteria:

- Can calculate cost per import from logs.
- Can separate user-facing successful saves from failed attempts.
- Can see prompt cache hit rate.

### Phase 1: Safe mechanical wins

Goal: reduce latency and validate caching without changing parser decisions.

Tasks:

- Update `.aiVision` sizing to satisfy both 1568px long edge and about 1.2MP max.
- Keep `.ocr` sizing unchanged.
- Add `model` to future parse cache keys before any Haiku photo test.
- Confirm `PROMPT_VERSION` is bumped whenever instructions/tool schema/vision prompt changes.
- Consider stable JSON request encoding if logs show prompt cache misses despite identical calls.

Success criteria:

- No accuracy regression on the sample set.
- Lower upload bytes.
- Lower or equal upstream latency.
- Prompt cache hit behavior visible.

### Phase 2: Title-assisted local/free preflight

Goal: improve perceived speed and skip remote AI for obvious clean pages.

Tasks:

- Start import processing immediately after the user taps `Process Recipe`.
- Keep the glowing processing llama visible while showing an optional title field: `What are we cookin'?`
- When processing finishes, show `Ready!` and a `Review Recipe` button instead of auto-navigating away.
- Run OCR before paid AI for photo import.
- Add strict `localPhotoParseConfident(draft, ocrText, ocrStats)` gate.
- Let a user-entered title satisfy the title requirement only when ingredients and steps are already strong.
- Treat title conflicts as uncertainty: escalate or carry both values to review.
- If confident, preview local draft and mark cache/model metadata as local.
- If not confident, proceed to AI.

Success criteria:

- Zero paid calls for accepted local imports.
- User-entered title reduces title-related local parse failures.
- No auto-navigation interrupts title typing/editing.
- No accepted local drafts fail manual QA relative to current Sonnet.
- Hard cases still escalate.

### Phase 3: Routed Haiku/Sonnet cascade

Goal: use Sonnet only for cases that need it.

Tasks:

- Add model parameter to `RecipeAIParser.parseImages`.
- Add an internal routing classifier for easy vs hard photo imports.
- Try Haiku vision only on easy-looking photo inputs.
- Add strict support/confidence gate for Haiku outputs.
- Route hard-looking pages directly to Sonnet.
- Use Sonnet vision fallback when Haiku was attempted but uncertain.
- Change OCR fallback from Sonnet-first to Haiku-first.
- Track fallback rates and final save/edit outcomes.

Success criteria:

- Same or better save rate.
- No noticeable increase in user edits on benchmark samples.
- Median cost lower by at least 50%.
- Median latency lower or equal for accepted Haiku/local cases.
- P95 latency no worse for hard-looking cases because they skip Haiku and go directly to Sonnet.

### Phase 4: Provider bake-off

Goal: see whether a cheaper provider can replace or augment Claude.

Candidates:

- Claude Haiku 4.5
- Claude Sonnet 4.6 current baseline
- OpenAI GPT-5 nano
- OpenAI GPT-5.4 nano
- OpenAI GPT-5 mini
- Gemini 2.5 Flash-Lite
- Gemini 2.5 Flash

Test each on the same frozen sample set. Do not switch providers based only on price.

Success criteria:

- No-fabrication behavior comparable to Sonnet.
- Ingredient and step extraction comparable to Sonnet.
- Layout/handwriting performance acceptable.
- Structured output integration is reliable.
- Privacy disclosures and vendor terms are acceptable.

## Benchmark design

Use a fixed set of real import samples. Save the raw images and expected outputs in a private test fixture outside public source if the photos are user/private content.

Suggested sample mix:

| Category | Count | Notes |
|---|---:|---|
| Clean printed cookbook one-page | 20 | Likely local OCR wins |
| Handwritten recipe cards | 20 | Sonnet likely still valuable |
| Two-column cookbook/magazine pages | 15 | Layout challenge |
| Multi-page recipes | 10 | Page ordering and continuation |
| Low-light/glare/curled pages | 10 | Robustness |
| Screenshots from recipe posts | 10 | Maybe cheap model handles |
| Non-recipe/noisy pages | 10 | Must reject or route to edit |

Metrics:

- total elapsed time from tapping Process to preview
- perceived wait: time user spends typing/editing before `Ready!`
- Worker upstream latency
- model
- routing branch: local, Haiku, direct Sonnet, Sonnet fallback
- whether user provided title
- whether user title filled an empty/weak extracted title
- whether user title conflicted with extracted title
- prompt cache hit/miss
- KV result cache hit/miss
- input/output/cache tokens
- estimated cost
- title exact/acceptable
- ingredient count delta
- step count delta
- fabricated fields
- longest step length
- timer flags
- special notes correctness
- user-visible confidence outcome

Manual QA rubric:

- Pass: save-ready with only minor cosmetic edits.
- Soft pass: usable but requires a few edits.
- Fail: missing major ingredients or steps.
- Hard fail: fabricated content, wrong recipe, or dangerous cooking instruction.

## External provider notes

### Anthropic Claude

Pros:

- Current integration already exists.
- Strong vision/layout behavior.
- Tool-use schema already implemented.
- Haiku offers a low-risk first optimization because it keeps the same provider and request shape.

Cons:

- Sonnet output tokens are expensive.
- Prompt caching must be measured and can silently miss.
- 5-minute cache TTL only helps bursts unless using 1-hour cache writes.

Best use:

- Haiku for easy-looking cheap/fast attempts.
- Sonnet fallback for hard handwriting/layout and uncertain drafts.

### OpenAI

Relevant official prices as of this research:

| Model | Input | Cached input | Output | Vision |
|---|---:|---:|---:|---|
| GPT-5 nano | $0.05 / MTok | $0.005 / MTok | $0.40 / MTok | image input supported |
| GPT-5.4 nano | $0.20 / MTok | $0.02 / MTok | $1.25 / MTok | image input supported |
| GPT-5 mini | $0.25 / MTok | $0.025 / MTok | $2.00 / MTok | image input supported |
| GPT-4.1 mini | $0.40 / MTok | $0.10 / MTok | $1.60 / MTok | image input supported |

On paper, OpenAI small/nano models are much cheaper than Sonnet and cheaper than Haiku. They support image input and structured outputs/function calling. The unknown is quality on recipe images, especially handwriting, two-column pages, and strict no-fabrication behavior.

Best use:

- Benchmark as a possible cheap first pass or replacement for Haiku.
- Do not switch the production photo path until the benchmark shows no accuracy regression.

### Google Gemini

Relevant official prices as of this research:

| Model | Input | Output | Notes |
|---|---:|---:|---|
| Gemini 2.5 Flash-Lite | $0.10 / MTok | $0.40 / MTok | text/image/video input |
| Gemini 2.5 Flash | $0.30 / MTok | $2.50 / MTok | stronger, still cheaper than Sonnet |

Gemini image tokenization is tile-based. Images larger than 384px are scaled/cropped into 768x768 tiles, each counted as 258 tokens. Gemini also exposes `count_tokens` and response `usage_metadata`.

Best use:

- Benchmark Flash-Lite as a very cheap first pass.
- Benchmark Flash as a possible middle tier between Haiku and Sonnet.

### Cloudflare AI Gateway

The app already uses Cloudflare Pages Functions as the proxy. AI Gateway may still be useful for:

- provider observability
- token usage dashboards
- provider cache HIT/MISS headers for exact repeat requests
- dynamic routing and fallbacks
- central cost controls

It should not replace the existing Worker quota logic by itself. Treat it as an observability/control layer behind or inside the Worker.

## Savings model for title-assisted routing

Current quota:

- Free: 5 saved photo imports/month.
- Pro: 30 saved photo imports/month.
- Daily parse attempts: 5/user/day.

Baseline assumption:

- Current average photo import cost: about `$0.04`.
- Baseline path: Sonnet vision first, with occasional Sonnet OCR-text fallback.
- One skipped Sonnet import saves roughly the whole `$0.04`.
- One Haiku-accepted import instead of Sonnet saves roughly `$0.025-$0.030`.
- User title input itself costs effectively nothing: usually 5-20 extra input tokens, less than `$0.0001`.

The title prompt saves money only by changing routing outcomes:

```text
No routing change:
  title field only -> cost stays about $0.04/import

Title-assisted routing:
  strong local/OCR parse + user title -> skip Sonnet -> save about $0.04

Title-assisted cheap parse:
  Haiku result + user title agrees -> accept Haiku -> save about $0.025-$0.030

Hard/uncertain page:
  skip Haiku and go straight to Sonnet -> cost stays about $0.04, accuracy preserved
```

### Per-import savings scenarios

These are planning estimates, not measured results. The first implementation task should still be instrumentation.

| Scenario | Local/title accepted | Haiku accepted | Sonnet needed | Avg cost/import | Savings vs `$0.04` |
|---|---:|---:|---:|---:|---:|
| Title UI only | 0% | 0% | 100% | `$0.040` | 0% |
| Conservative | 15% | 0% | 85% | `$0.034` | 15% |
| Cautious routed cascade | 20% | 30% | 50% | `$0.023` | 43% |
| Balanced | 25% | 35% | 40% | `$0.020` | 51% |
| Optimistic | 35% | 45% | 20% | `$0.013` | 69% |

Cost formula:

```text
avg cost = (local_share * $0.00) + (haiku_share * $0.010) + (sonnet_share * $0.040)
```

The title field mainly increases `local_share` by letting the app accept parses where the content is solid but the extracted title is missing or weak.

### Cost per 1,000 saved photo imports

| Scenario | Avg cost/import | Cost / 1,000 imports | Savings / 1,000 imports |
|---|---:|---:|---:|
| Current baseline | `$0.040` | `$40.00` | - |
| Conservative | `$0.034` | `$34.00` | `$6.00` |
| Cautious routed cascade | `$0.023` | `$23.00` | `$17.00` |
| Balanced | `$0.020` | `$19.50` | `$20.50` |
| Optimistic | `$0.013` | `$12.50` | `$27.50` |

### Cost at user quota caps

| Scenario | Free user max, 5/mo | Pro user max, 30/mo |
|---|---:|---:|
| Current baseline | `$0.20` | `$1.20` |
| Conservative | `$0.17` | `$1.02` |
| Cautious routed cascade | `$0.12` | `$0.69` |
| Balanced | `$0.10` | `$0.59` |
| Optimistic | `$0.06` | `$0.38` |

### Monthly examples

| Usage pattern | Imports/mo | Current baseline | Balanced title+routing | Monthly savings |
|---|---:|---:|---:|---:|
| 100 active users, 3 photo imports each | 300 | `$12.00` | `$5.85` | `$6.15` |
| 1,000 active users, 3 photo imports each | 3,000 | `$120.00` | `$58.50` | `$61.50` |
| 100 Pro users at full 30 import cap | 3,000 | `$120.00` | `$58.50` | `$61.50` |
| 1,000 Pro users at full 30 import cap | 30,000 | `$1,200.00` | `$585.00` | `$615.00` |

### Token usage avoided

For each local/title accept, the app avoids an entire paid model request. Roughly, that means avoiding:

- about 6k-7k static prompt/tool tokens
- about 1.3k-2.5k image tokens for a one-page photo, depending on sizing
- about 700-1,200 output tokens for the structured recipe

For each Haiku-accepted result, token count is similar but token price is lower. Using official Anthropic prices, Haiku 4.5 is one-third of Sonnet 4.6 for base input and output tokens. That is why Haiku acceptance saves money even if token counts are not much lower.

### Speed impact

The title-entry screen helps speed in two different ways:

- Perceived speed: the user is typing while the llama processes, so 2-5 seconds of waiting can feel productive.
- Actual speed: local/title accepts can skip the remote Sonnet call entirely; Haiku accepts should usually return faster than Sonnet.

But an unconditional Haiku-then-Sonnet chain can make hard cases slower. The routing classifier must send hard-looking imports directly to Sonnet.

## Accuracy safeguards for any cost-saving change

Do not accept cheaper model output only because it satisfies:

```swift
!draft.title.trimmed.isEmpty && !draft.ingredients.isEmpty && !draft.steps.isEmpty
```

That is enough to show a preview, but not enough to replace Sonnet.

Use stronger gates for local/cheap stages:

- compare against OCR/regex counts
- reject unsupported titles
- reject unsupported step verbs
- reject very long combined steps
- reject drafts with too few ingredients relative to obvious ingredient lines
- reject drafts with suspiciously generic invented steps
- preserve no-fabrication as the top rule

When in doubt, escalate to Sonnet or user edit.

## Non-cost caveats

### Privacy disclosure is currently important

The current live code sends recipe page images to Anthropic for photo import. Older docs and `cloudflare-pages/privacy.html` still say captured images stay on device. Before App Store submission or wider testing, update privacy disclosures and App Store privacy labels.

Any provider bake-off that adds OpenAI or Google also changes privacy/vendor disclosures.

### Do not count failed attempts only by saves

Quota is based on monthly saves, but cost is incurred on parse attempts. Daily attempt limits help. Usage logs should separate:

- attempts
- successful previews
- saves
- retries
- cache hits
- fallbacks

Otherwise cost per save will look confusing.

## Concrete recommendations ranked

1. Add Worker usage and latency logging.
2. Verify Anthropic prompt cache reads/writes with real usage fields.
3. Fix `.aiVision` resizing to about 1.2MP max, not just 1568px long edge.
4. Add `model` and schema/prompt versions to photo result cache keys before model experiments.
5. Add the processing-title UX: glowing llama, `What are we cookin'?`, `Ready!`, `Review Recipe`.
6. Add local OCR/regex high-confidence preflight for clean printed pages.
7. Let user title rescue otherwise-good local parses with missing/weak titles.
8. Change OCR fallback from Sonnet-first to Haiku-first for easy-looking cases.
9. Test Haiku vision selectively, with strict acceptance gates.
10. Route hard-looking pages directly to Sonnet.
11. Keep Sonnet as final fallback for hard/uncertain cases.
12. Add a benchmark harness with frozen real samples.
13. Only after the Anthropic cascade is measured, run OpenAI/Gemini bake-offs.

## Suggested future target architecture

```text
Photo pages
  -> prepare aiVision image(s) + OCR image(s)
  -> immediately show glowing llama + optional title field:
       "What are we cookin'?"
  -> OCR local text
  -> regex/local parse
      -> if ingredients/steps are strong and title is present or user provided:
           Ready! -> Review Recipe, cost $0
      -> else classify easy vs hard
          -> easy-looking: OCR text + Haiku or Haiku vision
              -> if high confidence and title agrees/user title fills gap:
                   Ready! -> Review Recipe, low cost
              -> else Sonnet vision
          -> hard-looking: Sonnet vision directly
              -> if confident:
                   Ready! -> Review Recipe, current high quality
              -> else Edit as text fallback
```

Optional variation:

```text
If OCR confidence is very low or the page looks handwritten/layout-heavy:
  skip OCR text + Haiku
  go directly to Sonnet
```

This keeps the current feature's quality ceiling while lowering the average cost.

## Source links

- Anthropic pricing: https://platform.claude.com/docs/en/about-claude/pricing
- Anthropic prompt caching: https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- Anthropic vision and image token guidance: https://platform.claude.com/docs/en/build-with-claude/vision
- Anthropic models overview: https://platform.claude.com/docs/en/about-claude/models/overview
- Anthropic token counting API: https://docs.anthropic.com/en/api/messages-count-tokens
- OpenAI GPT-5 nano model/pricing: https://developers.openai.com/api/docs/models/gpt-5-nano
- OpenAI GPT-5.4 nano model/pricing: https://developers.openai.com/api/docs/models/gpt-5.4-nano
- OpenAI GPT-5 mini model/pricing: https://developers.openai.com/api/docs/models/gpt-5-mini
- OpenAI GPT-4.1 mini model/pricing: https://developers.openai.com/api/docs/models/gpt-4.1-mini
- OpenAI image input token guidance: https://developers.openai.com/api/docs/guides/images-vision
- Gemini API pricing: https://ai.google.dev/gemini-api/docs/pricing
- Gemini token counting and image tokenization: https://ai.google.dev/gemini-api/docs/tokens
- Cloudflare AI Gateway caching: https://developers.cloudflare.com/ai-gateway/configuration/caching/
