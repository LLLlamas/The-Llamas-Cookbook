import SwiftUI
import SwiftData

@main
struct LlamasCookbookApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self])
    }
}
