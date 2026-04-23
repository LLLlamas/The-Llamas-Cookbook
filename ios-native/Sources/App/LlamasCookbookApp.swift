import SwiftUI
import SwiftData
import UIKit

@main
struct LlamasCookbookApp: App {
    init() {
        // Propagate accent to UIKit surfaces (keyboard Return key, text cursors,
        // selection handles) that read UIView.tintColor before SwiftUI's .tint()
        // reaches them.
        UIView.appearance().tintColor = UIColor(AppColor.accent)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self])
    }
}
