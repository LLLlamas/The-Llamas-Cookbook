import SwiftUI

// Type system. Headings lean serif + heavy + slight tracking for warmth and
// presence; body text stays neutral. Fraunces/Inter custom files can be wired
// in later — for now system .serif is a close-enough placeholder for the
// elegant-cookbook feel without bundle weight.
enum AppFont {
    /// Cookbook-cover scale — used for the Library hero and overlay headlines.
    static let display: Font = .system(size: 34, weight: .heavy, design: .serif)
    /// Recipe title in detail view.
    static let recipeTitle: Font = .system(size: 28, weight: .bold, design: .serif)
    /// Section heading ("Ingredients", "Steps", "Notes").
    static let sectionHeading: Font = .system(size: 20, weight: .bold, design: .serif)
    /// Smaller eyebrow / label text above sections.
    static let eyebrow: Font = .system(size: 11, weight: .heavy, design: .default)

    /// Body copy.
    static let body: Font = .system(size: 16, weight: .regular)
    /// Ingredient row text.
    static let ingredient: Font = .system(size: 16, weight: .regular)
    /// Cook-mode oversized ingredient/step copy.
    static let ingredientCook: Font = .system(size: 19, weight: .medium)
    /// Captions / metadata.
    static let caption: Font = .system(size: 12, weight: .regular)
}

extension Text {
    /// Eyebrow styling — small, all-caps, tracked label above sections.
    func eyebrowStyle(_ color: Color = AppColor.accentDeep) -> some View {
        self
            .font(AppFont.eyebrow)
            .tracking(1.4)
            .foregroundStyle(color)
    }
}
