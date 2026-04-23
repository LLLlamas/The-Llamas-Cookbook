import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .tint(AppColor.accent)
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self], inMemory: true)
}
