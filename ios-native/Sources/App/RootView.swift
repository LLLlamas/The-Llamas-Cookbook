import SwiftUI

struct RootView: View {
    @State private var session = CookingSession()

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .tint(AppColor.accent)
        .environment(session)
        .sheet(isPresented: cookingSheetPresented) {
            if let recipe = session.activeRecipe {
                CookModeView(recipe: recipe) {
                    session.end()
                }
                // Two detents: full-screen while actively cooking, and a
                // compact strip so the user can peek at / navigate the
                // Library or another recipe without losing cook state.
                .presentationDetents([.large, .medium])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                // Prevents accidental swipe-down-to-dismiss — cook sessions
                // end explicitly via the close button, Mark-as-cooked, or
                // Stop on the timer overlay.
                .interactiveDismissDisabled()
            }
        }
    }

    private var cookingSheetPresented: Binding<Bool> {
        Binding(
            get: { session.activeRecipe != nil },
            set: { newValue in
                if !newValue { session.end() }
            }
        )
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self], inMemory: true)
}
