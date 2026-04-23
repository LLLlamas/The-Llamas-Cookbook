import SwiftUI

// Placeholder typography — uses system fonts with serif design for headings
// to approximate the Fraunces look from the RN version. Custom font files
// (Fraunces.ttf, Inter.ttf) can be bundled later and wired through here.
enum AppFont {
    static let recipeTitle: Font = .system(.title, design: .serif).weight(.semibold)
    static let sectionHeading: Font = .system(.headline, design: .serif).weight(.semibold)
    static let body: Font = .body
    static let ingredient: Font = .system(.body, design: .default)
    static let ingredientCook: Font = .system(.title3, design: .default)
    static let caption: Font = .caption
}
