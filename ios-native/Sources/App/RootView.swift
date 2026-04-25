import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.modelContext) private var modelContext
    @State private var session = CookingSession()
    @State private var editor = EditorCoordinator()

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .tint(appearance.accentColor)
        .environment(session)
        .environment(editor)
        .task {
            // Cold launch (or relaunch after iOS killed us) — pull any
            // saved cook session back into memory before the first frame
            // settles so the user lands directly in Cook Mode if they
            // were mid-cooking when the app went away.
            session.restore(using: lookupRecipe)
        }
        .onOpenURL { url in
            // Live Activity tap → `llamascookbook://cook/<uuid>`. We
            // re-run `restore` first so persisted struck-step state is
            // re-attached when this is the cold-launch path that beat
            // `.task` to the punch. Falls through to opening the URL's
            // recipe directly if the persisted session is for something
            // else (or got cleared).
            guard let recipeID = parseCookDeepLink(url) else { return }
            session.restore(using: lookupRecipe)
            if session.activeRecipe == nil, let recipe = lookupRecipe(recipeID) {
                session.activeRecipe = recipe
            }
        }
        .fullScreenCover(isPresented: cookingSheetPresented) {
            if let recipe = session.activeRecipe {
                CookModeView(
                    recipe: recipe,
                    restoration: session.pendingRestoration
                ) {
                    session.end()
                }
                // Cook Mode owns the entire screen — no sheet chrome,
                // no swipe-to-dismiss, no rounded corners. Exit goes
                // through the in-view close (X) or Mark-as-cooked.
                // Explicit environment re-injection: @Observable values
                // don't always propagate through covers reliably, and the
                // children of cook mode may read them. Cheap to be safe.
                .environment(appearance)
                .environment(session)
                .environment(editor)
            }
        }
        .sheet(item: editorBinding) { sheet in
            EditorSheetHost(sheet: sheet, onClose: { editor.end() })
                .environment(appearance)
                .environment(editor)
                .environment(session)
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

    private func lookupRecipe(_ id: UUID) -> Recipe? {
        let descriptor = FetchDescriptor<Recipe>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    /// Parses `llamascookbook://cook/<uuid>` and returns the UUID, or
    /// nil if the URL doesn't match (other scheme, missing host, malformed
    /// path). Defensive — anything unparseable just no-ops the deep link
    /// rather than crashing, since this runs from `onOpenURL` which iOS
    /// can deliver at any moment with arbitrary input.
    private func parseCookDeepLink(_ url: URL) -> UUID? {
        guard url.scheme == "llamascookbook", url.host == "cook" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first else { return nil }
        return UUID(uuidString: first)
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
        .environment(AppearanceSettings())
}
