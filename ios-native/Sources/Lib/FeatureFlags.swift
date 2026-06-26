import Foundation

/// Small compile-time feature switches. Kept tiny and central so flipping a
/// flag is a one-line change, not a scavenger hunt.
enum FeatureFlags {
    /// Retailer cart hand-off (Instacart / Kroger / Walmart). **Off** — no
    /// self-serve retailer API is available: Instacart closed new
    /// applications, and Kroger/Walmart/Whisk are B2B-partnership-gated
    /// (see `md_files/grocery-lists-design.md`). The grocery "need" list is
    /// already shaped as `{name, quantity, unit}` line items, so enabling
    /// this later is a Cloudflare Worker endpoint + a key in Worker env —
    /// no iOS data-model changes.
    static let retailerCartEnabled = false
}
