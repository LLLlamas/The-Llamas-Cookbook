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
                // tab-sized strip at the very bottom so the user can
                // navigate the Library or other recipes with the cook
                // session tucked out of the way. `.large` is listed
                // first so the sheet opens full-height every time.
                .presentationDetents([.large, .height(80)])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(80)))
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
