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
        .overlay(alignment: .bottom) {
            // Floats above Library / Detail / any pushed nav screens
            // while a cook session is minimized. Tap to re-present Cook
            // Mode where the user left off (struck steps + running timer
            // re-attach via `pendingRestoration`).
            if session.activeRecipe != nil && !session.isCookModeVisible {
                CookingResumePill(session: session, accent: appearance.accentColor)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.bottom, AppSpacing.md)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.isCookModeVisible)
        .task {
            // Cold launch (or relaunch after iOS killed us) — pull any
            // saved cook session back into memory before the first frame
            // settles so the user lands directly in Cook Mode if they
            // were mid-cooking when the app went away.
            session.restore(using: lookupRecipe)
        }
        .onOpenURL { url in
            // Live Activity tap → `llamascookbook://cook/<uuid>`.
            // Three cases this needs to handle:
            //   1. Cold launch: `restore` rehydrates from disk, sets the
            //      cover visible.
            //   2. Warm app, session minimized: `resume()` brings the
            //      cover back without re-reading disk.
            //   3. No persisted session at all (rare — Live Activity
            //      outlived the cook session) — fall back to opening the
            //      URL's recipe directly.
            guard let recipeID = parseCookDeepLink(url) else { return }
            if session.activeRecipe == nil {
                session.restore(using: lookupRecipe)
            }
            if session.activeRecipe == nil, let recipe = lookupRecipe(recipeID) {
                session.activeRecipe = recipe
                session.isCookModeVisible = true
            } else {
                session.resume()
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
        // The cover follows `isCookModeVisible` rather than just "do we
        // have an active recipe?" — minimize hides the cover without
        // tearing down the session, and the resume pill / Live Activity
        // tap can flip it back on. SwiftUI may write `false` here when
        // the user dismisses (which we have disabled for cook mode), so
        // we route through `minimize()` to keep the session alive.
        Binding(
            get: { session.isCookModeVisible && session.activeRecipe != nil },
            set: { newValue in
                if !newValue { session.minimize() }
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

/// Floating pill shown when Cook Mode is minimized. Surfaces recipe
/// name + live countdown so the user can tell at a glance which recipe
/// is mid-flight. Tapping resumes Cook Mode in place.
private struct CookingResumePill: View {
    let session: CookingSession
    let accent: Color

    var body: some View {
        Button {
            Haptics.selection()
            session.resume()
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 16, weight: .bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text("COOKING")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(0.8)
                        .opacity(0.9)
                    if let title = session.activeRecipe?.title {
                        Text(StringCase.titleCase(title))
                            .font(.system(size: 14, weight: .semibold, design: .serif))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: AppSpacing.sm)
                if let endsAt = CookingSessionStore.load()?.timerEndsAt, endsAt > Date() {
                    // System timer text counts down on its own once a
                    // second without our app pushing updates — same
                    // mechanism the Live Activity widget uses.
                    Text(timerInterval: Date()...endsAt, countsDown: true)
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .monospacedDigit()
                        .frame(maxWidth: 64)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            .shadow(color: AppColor.shadow, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume cooking")
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self], inMemory: true)
        .environment(AppearanceSettings())
}
