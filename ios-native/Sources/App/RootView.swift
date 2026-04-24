import SwiftUI

struct RootView: View {
    @State private var session = CookingSession()
    @State private var editor = EditorCoordinator()

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .tint(AppColor.accent)
        .environment(session)
        .environment(editor)
        .sheet(isPresented: cookingSheetPresented) {
            if let recipe = session.activeRecipe {
                CookModeView(recipe: recipe) {
                    session.end()
                }
                // `.large` first so SwiftUI starts the sheet fully expanded.
                // Tab-sized `.height(80)` lets the user tuck it to the
                // bottom of the screen, keep cooking state, and browse
                // Library / other recipes underneath.
                .presentationDetents([.large, .height(80)])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(80)))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
            }
        }
        .sheet(item: editorBinding) { sheet in
            EditorSheetHost(sheet: sheet, onClose: { editor.end() })
        }
        .alert(
            "Discard changes?",
            isPresented: discardAlertPresented,
            presenting: editor.pendingSwitch
        ) { _ in
            Button("Keep editing", role: .cancel) { editor.cancelDiscard() }
            Button("Discard", role: .destructive) { editor.confirmDiscard() }
        } message: { _ in
            Text("You have unsaved changes. Leaving will lose them.")
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

    /// The editor sheet's binding only writes on dismiss — and because
    /// `.interactiveDismissDisabled()` is applied inside the sheet host,
    /// the user can't accidentally drag it away; only Save / Cancel paths
    /// call `editor.end()` explicitly.
    private var editorBinding: Binding<EditorCoordinator.ActiveSheet?> {
        Binding(
            get: { editor.active },
            set: { newValue in
                if newValue == nil { editor.end() }
            }
        )
    }

    private var discardAlertPresented: Binding<Bool> {
        Binding(
            get: { editor.pendingSwitch != nil },
            set: { if !$0 { editor.cancelDiscard() } }
        )
    }
}

/// Wraps the editor/import/new-recipe flow in its own detent-managed
/// sheet content. Owns a local `@State` for the selected detent so each
/// fresh presentation starts at `.large` — and stays at whatever detent
/// the user drags it to during a single session.
private struct EditorSheetHost: View {
    let sheet: EditorCoordinator.ActiveSheet
    let onClose: () -> Void

    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            switch sheet {
            case .new:
                RecipeEditorView(recipe: nil, onSaved: onClose)
            case .edit(let recipe):
                RecipeEditorView(recipe: recipe, onSaved: onClose)
            case .importFromText:
                ImportRecipeView()
            }
        }
        .presentationDetents([.large, .height(80)], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(80)))
        .presentationDragIndicator(.visible)
        // Full swipe-down is blocked — the only way to fully close the
        // editor is Save, Cancel (with the existing discard alert), or
        // confirming the switch-discard alert at RootView.
        .interactiveDismissDisabled()
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self], inMemory: true)
}
