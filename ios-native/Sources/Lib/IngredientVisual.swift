import SwiftUI

/// A confident, offline visual for a grocery item — the "show a picture of
/// the ingredient" piece of the shopper's "?" helper.
///
/// **Why curated, not AI-found photos:** reliably finding a *correct*
/// photo of an arbitrary grocery item at high confidence is not something
/// on-device models do dependably, and pulling arbitrary remote images
/// raises licensing + SSRF + safety concerns. A hand-curated glyph table is
/// effectively 100% accurate for the items it covers, costs nothing, works
/// offline, and — crucially — returns `nil` for anything it isn't sure
/// about, so we never show the *wrong* picture. The call sites take a
/// `Glyph?`, so a richer source (a licensed photo API, a bundled photo
/// pack, or an AI image lookup gated on a real confidence score) can slot
/// in behind `glyph(for:)` later without touching any UI.
enum IngredientVisual {
    enum Glyph: Equatable {
        case emoji(String)
        /// SF Symbol fallback (currently unused by the table but kept so a
        /// future entry can prefer a symbol over an emoji).
        case symbol(String)
    }

    /// Emoji are the most recognizable offline "picture" with the broadest
    /// grocery coverage. Keys are singular + lowercase; `GroceryKeyword`
    /// handles plurals and surrounding words. Ambiguous bare keys (e.g. a
    /// lone "pepper" — black vs. bell) are intentionally omitted so we
    /// never show a misleading glyph.
    private static let table: [String: Glyph] = [
        // Produce
        "tomato": .emoji("🍅"), "onion": .emoji("🧅"), "garlic": .emoji("🧄"),
        "carrot": .emoji("🥕"), "potato": .emoji("🥔"), "bell pepper": .emoji("🫑"),
        "broccoli": .emoji("🥦"), "lettuce": .emoji("🥬"), "spinach": .emoji("🥬"),
        "kale": .emoji("🥬"), "corn": .emoji("🌽"), "cucumber": .emoji("🥒"),
        "pickle": .emoji("🥒"), "mushroom": .emoji("🍄"), "avocado": .emoji("🥑"),
        "eggplant": .emoji("🍆"), "lemon": .emoji("🍋"), "lime": .emoji("🍋"),
        "apple": .emoji("🍎"), "banana": .emoji("🍌"), "strawberry": .emoji("🍓"),
        "strawberries": .emoji("🍓"), "blueberry": .emoji("🫐"), "blueberries": .emoji("🫐"),
        "grape": .emoji("🍇"), "orange": .emoji("🍊"), "peach": .emoji("🍑"),
        "cherry": .emoji("🍒"), "cherries": .emoji("🍒"), "pineapple": .emoji("🍍"),
        "mango": .emoji("🥭"), "coconut": .emoji("🥥"), "watermelon": .emoji("🍉"),
        "melon": .emoji("🍈"), "pear": .emoji("🍐"), "kiwi": .emoji("🥝"),
        "olive": .emoji("🫒"), "pea": .emoji("🫛"), "bean": .emoji("🫘"),
        "chickpea": .emoji("🫘"), "lentil": .emoji("🫘"), "ginger": .emoji("🫚"),

        // Dairy & eggs
        "milk": .emoji("🥛"), "cheese": .emoji("🧀"), "cream cheese": .emoji("🧀"),
        "parmesan": .emoji("🧀"), "feta": .emoji("🧀"), "butter": .emoji("🧈"),
        "egg": .emoji("🥚"),

        // Bakery
        "bread": .emoji("🍞"), "baguette": .emoji("🥖"), "bagel": .emoji("🥯"),
        "croissant": .emoji("🥐"), "flour": .emoji("🌾"), "pretzel": .emoji("🥨"),
        "pancake": .emoji("🥞"), "waffle": .emoji("🧇"), "tortilla": .emoji("🫓"),
        "naan": .emoji("🫓"),

        // Meat & seafood
        "chicken": .emoji("🍗"), "beef": .emoji("🥩"), "steak": .emoji("🥩"),
        "pork": .emoji("🥩"), "bacon": .emoji("🥓"), "ham": .emoji("🍖"),
        "fish": .emoji("🐟"), "salmon": .emoji("🐟"), "tuna": .emoji("🐟"),
        "shrimp": .emoji("🦐"), "prawn": .emoji("🦐"), "crab": .emoji("🦀"),
        "lobster": .emoji("🦞"), "squid": .emoji("🦑"), "oyster": .emoji("🦪"),

        // Pantry & prepared
        "rice": .emoji("🍚"), "pasta": .emoji("🍝"), "spaghetti": .emoji("🍝"),
        "noodle": .emoji("🍜"), "ramen": .emoji("🍜"), "salt": .emoji("🧂"),
        "honey": .emoji("🍯"), "peanut butter": .emoji("🥜"), "peanut": .emoji("🥜"),
        "almond": .emoji("🥜"), "cashew": .emoji("🥜"), "chestnut": .emoji("🌰"),
        "soup": .emoji("🥣"), "cereal": .emoji("🥣"), "oat": .emoji("🌾"),
        "oatmeal": .emoji("🥣"), "sushi": .emoji("🍣"), "taco": .emoji("🌮"),
        "burrito": .emoji("🌯"), "pizza": .emoji("🍕"), "popcorn": .emoji("🍿"),

        // Sweets & frozen
        "ice cream": .emoji("🍦"), "ice": .emoji("🧊"), "chocolate": .emoji("🍫"),
        "candy": .emoji("🍬"), "cookie": .emoji("🍪"), "cake": .emoji("🍰"),
        "cupcake": .emoji("🧁"), "pie": .emoji("🥧"), "donut": .emoji("🍩"),
        "doughnut": .emoji("🍩"),

        // Beverages
        "water": .emoji("💧"), "coffee": .emoji("☕"), "tea": .emoji("🍵"),
        "matcha": .emoji("🍵"), "wine": .emoji("🍷"), "beer": .emoji("🍺"),
        "juice": .emoji("🧃"), "soda": .emoji("🥤"),

        // Herbs & spices
        "chili": .emoji("🌶️"), "jalapeno": .emoji("🌶️"), "basil": .emoji("🌿"),
        "parsley": .emoji("🌿"), "cilantro": .emoji("🌿"), "mint": .emoji("🌿"),
        "rosemary": .emoji("🌿"), "thyme": .emoji("🌿"), "herb": .emoji("🌿"),
    ]

    private static let keys = Array(table.keys)

    /// The confident glyph for an item, or `nil` when we have none. The
    /// caller shows a neutral placeholder for `nil` rather than guessing.
    static func glyph(for itemName: String) -> Glyph? {
        guard let key = GroceryKeyword.bestKey(in: itemName, keys: keys) else { return nil }
        return table[key]
    }

    /// True when we have a confident visual for this item.
    static func hasGlyph(for itemName: String) -> Bool {
        glyph(for: itemName) != nil
    }
}

/// Renders an `IngredientVisual.Glyph` (or a neutral placeholder) inside a
/// soft tinted circle. Used by the swap helper; reusable anywhere an item
/// thumbnail is wanted.
struct IngredientGlyphView: View {
    let itemName: String
    var size: CGFloat = 56
    var accent: Color = AppColor.accent

    private var glyph: IngredientVisual.Glyph? { IngredientVisual.glyph(for: itemName) }

    var body: some View {
        ZStack {
            Circle().fill(accent.opacity(0.12))
            switch glyph {
            case .emoji(let value):
                Text(value)
                    .font(.system(size: size * 0.5))
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(accent)
            case nil:
                // No confident picture — a calm placeholder, never a guess.
                Image(systemName: "basket.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
