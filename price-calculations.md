# Subscription Pricing Analysis

_Last updated: 2026-05-14 · Decision: $4.99/month · $39.99/year_

---

## AI Cost Per Photo Import (Sonnet 4.6)

Image token cost drives the majority of per-import spend.

**How Anthropic counts vision tokens:**
- Images are broken into ~512px tiles
- A 1568 × 1050px image (our `.aiVision` cap) ≈ 9 tiles × ~1,600 tokens/tile = **~14,400 image tokens**
- At $3/MTok input: ~$0.043 per page just for the image
- System prompt + output tokens add ~$0.015–0.025
- **Single-page recipe: ~$0.06. Two-page recipe: ~$0.10–0.12**

| Component | Tokens (est.) | Rate | Cost |
|---|---|---|---|
| Image (1 page, 1568px) | ~14,400 | $3/MTok | ~$0.043 |
| System prompt (cache read) | ~2,000 | $0.30/MTok | ~$0.0006 |
| Output (structured recipe) | ~400 | $15/MTok | ~$0.006 |
| **Single-page total** | | | **~$0.050** |
| **Two-page total** | | | **~$0.095–0.12** |

Prompt caching (`cache_control: ephemeral`) on the system prompt reduces repeat costs to ~$0.0006 vs. ~$0.006 for a cache miss — meaningful at scale but not the main cost driver.

---

## Free Tier Cost (Hidden Drain)

Free users get 5 photo imports/month.

- 5 imports × $0.10 = **$0.50/month per active free user**
- This is a real cost. If 1,000 users are active free users who use their full allotment, that's $500/month with $0 revenue.
- Mitigation: the OCR preflight gate (`localPhotoParseConfident`) skips the Anthropic call for clean, well-formatted recipe photos — reducing average cost below $0.10 for free-tier users.

---

## Pro Usage Scenarios

Pro cap: 30 imports/month. Realistic steady-state after initial library setup: 5–10/month.

| Monthly imports | AI cost |
|---|---|
| 5 (minimal) | $0.50 |
| 10 (realistic post-setup) | $1.00 |
| 20 (active) | $2.00 |
| 30 (cap, max) | $3.00 |

---

## Pricing Decision

### $4.99/month · $39.99/year

| | Monthly | Annual |
|---|---|---|
| Gross | $4.99 | $39.99 |
| After App Store cut (30%) | $3.49 | $27.99 |
| Effective monthly net | $3.49 | **$2.33** |
| AI cost (10 imports/month avg) | $1.00 | $12.00/yr |
| **Net margin (avg usage)** | **$2.49/mo** | **$15.99/yr** |
| AI cost (30 imports/month max) | $3.00 | $36.00/yr |
| **Net margin (max usage)** | **$0.49/mo** | **-$8.01/yr** |

At $4.99/month, even max-usage Pro users (30 imports/month) are profitable on the monthly plan. Max-usage annual users are slightly underwater, but steady-state usage is 5–10 imports/month post-burst — not 30.

### Annual discount note
$39.99/year vs $4.99/month × 12 = $59.88 — saves ~$20/year (**~33%, "4 months free"**). Clean story for App Store positioning. Monthly subscribers who don't convert to annual pay more over time, which is fine — monthly churn is the real risk, not annual cannibalization.

### Competitive context
| App | Monthly | Annual | AI tech |
|---|---|---|---|
| **Llamas Cookbook** | **$4.99** | **$39.99** | Claude Sonnet 4.6 (frontier) |
| ReciMe | $9.99 | $39.99 | Undisclosed |
| Crouton | — | $8.99 | Undisclosed (likely on-device) |
| Pestle | — | $20.00 | Apple Vision (on-device) |
| Feedr | $9.99/wk | $39.99 | Undisclosed, link-import focused |

Llamas Cookbook is priced below ReciMe while using a publicly superior model (Sonnet 4.6 vs. unknown). Crouton and Pestle are cheaper but rely on on-device OCR — no structured extraction cascade.

---

## What Would Change This Analysis

- **Haiku routing** (Phase 3 from `reducing-cost.md`): route single-page, low-complexity imports to Haiku 4.5 ($1/MTok input vs. $3/MTok). Could cut per-import cost to ~$0.02–0.04 for easy recipes, shifting the break-even point significantly.
- **Anthropic price changes**: rates as of 2026-05-14. Cache read rate drops have historically been the friendly direction.
- **Real usage data**: once Worker logs are live, actual median imports/month per Pro user should replace the 10-import assumption.
