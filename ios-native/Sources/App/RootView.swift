import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.modelContext) private var modelContext
    @State private var session = CookingSession()
    @State private var editor = EditorCoordinator()
    @State private var navContext = NavigationContext()

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .tint(appearance.accentColor)
        .environment(session)
        .environment(editor)
        .environment(navContext)
        .overlay(alignment: .bottom) {
            // Floats above Library / Detail / any pushed nav screens
            // while a cook session is minimized. Plural-aware:
            //   • 1 cook, no Detail-eligible add → single full pill
            //   • 1 cook + Detail of a different recipe → small green
            //     "Add to Cook Mode" button on the left + pill on the
            //     right (~1/4 + 3/4 split)
            //   • 2+ cooks → equally-sized pills, each tappable to
            //     foreground that cook
            if !session.activeCooks.isEmpty && !session.isCookModeVisible {
                CookingPillsBar(
                    session: session,
                    navContext: navContext,
                    accent: appearance.accentColor,
                    lookupRecipe: lookupRecipe
                )
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
            // Live Activity / notification tap → `llamascookbook://cook/<uuid>`
            // where <uuid> is the recipeID. Multi-cook routing: find
            // the cook whose recipe matches and foreground it directly,
            // so tapping cook B's lock-screen activity lands the user
            // in cook B's view (not whichever cook was foregrounded
            // last).
            //
            // Edge cases:
            //   1. Cold launch with persisted cooks → `restore` first,
            //      then route by recipeID.
            //   2. No persisted session and no live cook for that
            //      recipe → start a fresh cook for it (Live Activity
            //      outlived the session).
            //   3. Persisted cook for that recipe but a different cook
            //      currently foregrounded → `foreground(cookID:)`
            //      switches and re-presents the cover.
            guard let recipeID = parseCookDeepLink(url) else { return }
            if session.activeCooks.isEmpty {
                session.restore(using: lookupRecipe)
            }
            if let cook = session.activeCooks.first(where: { $0.recipe.id == recipeID }) {
                session.foreground(cookID: cook.id)
            } else if session.activeCooks.isEmpty, let recipe = lookupRecipe(recipeID) {
                session.start(recipe)
            } else {
                // Active cooks exist but none matches this recipeID —
                // edge case (stale Live Activity from a deleted recipe,
                // probably). Surface whatever's already in the session
                // rather than no-oping.
                session.resume()
            }
        }
        .fullScreenCover(isPresented: cookingSheetPresented) {
            if let recipe = session.foregroundedRecipe,
               let cookID = session.foregroundedCookID {
                CookModeView(
                    recipe: recipe,
                    cookID: cookID,
                    restoration: session.pendingRestoration
                ) {
                    // Multi-cook close: drop *just this cook* from the
                    // session. If it was the last one, `remove` falls
                    // through to `endAll` and dismisses the cover; if
                    // others remain, `remove` hands off the foreground
                    // and the cover swaps to the next cook via
                    // `.id(cookID)` recreation below.
                    session.remove(cookID: cookID)
                }
                // .id(cookID) forces SwiftUI to tear down + recreate
                // CookModeView when the foregrounded cook changes,
                // so each cook's @State (strikes, timer, phase) seeds
                // fresh from its own pendingRestoration instead of
                // bleeding the previous cook's values.
                .id(cookID)
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
        // have any active cooks?" — minimize hides the cover without
        // tearing down the session, and the resume pill / Live Activity
        // tap can flip it back on. SwiftUI may write `false` here when
        // the user dismisses (which we have disabled for cook mode), so
        // we route through `minimize()` to keep the session alive.
        Binding(
            get: { session.isCookModeVisible && !session.activeCooks.isEmpty },
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

/// Floating pills bar shown when Cook Mode is minimized. Renders one
/// pill per active cook; when the user is viewing the Detail page of a
/// recipe that *isn't* in the session yet (and there's room under the
/// 4-cook cap), prepends a small green "Add to Cook Mode" button so
/// they can spawn a parallel cook without re-entering Cook Mode.
///
/// Layout transitions:
///   • 1 cook, no Detail-eligible add → 1 full-width accent pill
///   • 1 cook + green add button → ~1/4 green + ~3/4 accent pill
///   • 2+ cooks → equally-sized accent pills, no add button if at cap
///
/// Spring-animated on `activeCooks.count` and on `canShowAdd` so the
/// transitions feel cohesive when the user adds a parallel cook.
private struct CookingPillsBar: View {
    let session: CookingSession
    let navContext: NavigationContext
    let accent: Color
    let lookupRecipe: (UUID) -> Recipe?

    private var detailRecipe: Recipe? {
        guard let id = navContext.detailedRecipeID else { return nil }
        return lookupRecipe(id)
    }

    /// True when the green add button should appear: there's a Detail
    /// recipe in scope, it isn't already cooking, and we're under cap.
    private var canShowAdd: Bool {
        guard let id = navContext.detailedRecipeID else { return false }
        guard !session.activeCooks.contains(where: { $0.recipe.id == id }) else { return false }
        return session.canAddCook
    }

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if canShowAdd, let recipe = detailRecipe {
                AddToCookButton {
                    Haptics.impact(.light)
                    session.addParallel(recipe)
                }
                // Roughly 1/4 of a typical phone width; works without a
                // GeometryReader and degrades gracefully on small
                // devices since the pill side uses maxWidth: .infinity.
                .frame(maxWidth: 92)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ForEach(session.activeCooks) { cook in
                CookPill(cook: cook, accent: accent) {
                    Haptics.selection()
                    session.foreground(cookID: cook.id)
                }
                .frame(maxWidth: .infinity)
                .transition(
                    .scale(scale: 0.85).combined(with: .opacity)
                )
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.85),
                   value: session.activeCooks.count)
        .animation(.spring(response: 0.42, dampingFraction: 0.85),
                   value: canShowAdd)
    }
}

/// One cook's resume pill. Same accent-on-cream visual language as the
/// pre-multi `CookingResumePill`, but compacted for the 2-up case
/// where two pills share the bottom row. The "COOKING" eyebrow drops
/// when the pill goes plural — the title + chevron alone read clearly
/// at half-width.
private struct CookPill: View {
    let cook: ActiveCook
    let accent: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 15, weight: .bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(StringCase.titleCase(cook.recipe.title))
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .lineLimit(1)
                    if let endsAt = cook.timerEndsAt, endsAt > Date() {
                        // System-driven countdown — no app-side ticking.
                        Text(timerInterval: Date()...endsAt, countsDown: true)
                            .font(.system(size: 11, weight: .bold, design: .serif))
                            .monospacedDigit()
                            .opacity(0.92)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            .shadow(color: AppColor.shadow, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume cooking \(cook.recipe.title)")
    }
}

/// Small green "Add to Cook Mode" button. Same `fork.knife` glyph as
/// the cooking pill — same affordance language — but tinted with the
/// success green so it visually reads as "spawn another cook" rather
/// than "resume what's already running."
private struct AddToCookButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 15, weight: .bold))
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .heavy))
            }
            .foregroundStyle(AppColor.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(AppColor.success)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            .shadow(color: AppColor.shadow, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add this recipe to Cook Mode")
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self, RecipePhoto.self, RecipeStepPhoto.self], inMemory: true)
        .environment(AppearanceSettings())
}
