import SwiftUI
import UIKit

/// Text-paste import path. The user pastes recipe text, the parser
/// produces a `DraftRecipe`, and the user lands on the existing
/// editor with the parsed result pre-populated. The link path lives
/// in `ImportFromLinkView` (split out so each FAB entry maps to one
/// dedicated screen — see CLAUDE.md "Four-way FAB import split").
///
/// `seedText` is set when the photo-import path's quality gate fails
/// — OCR pulled text but the parser couldn't separate ingredients
/// from steps. The user gets a "Continue in text editor" handoff
/// with the OCR text already in the paste box, ready to clean up.
struct ImportFromTextView: View {
    /// OCR-derived text seed from the photo-import partial-fallback
    /// path. When non-nil, populates the paste editor on appear so
    /// the user lands on a pre-filled box with the OCR result rather
    /// than a blank one. Nil for the plain "Import From Text" entry
    /// from the Library FAB.
    let seedText: String?

    /// Called by the inner `RecipeEditorView` after a successful
    /// Save with the freshly-persisted `Recipe`. RootView wires this
    /// to dismiss the editor sheet and push Detail via
    /// `libraryPath.append` after a 350ms delay (so the dismiss
    /// animation doesn't race the navigation push). Defaults to a
    /// no-op for previews / standalone usage.
    var onSaved: (Recipe) -> Void = { _ in }

    init(seedText: String? = nil, onSaved: @escaping (Recipe) -> Void = { _ in }) {
        self.seedText = seedText
        self.onSaved = onSaved
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance

    @State private var pastedText = ""
    @State private var parsedDraft: DraftRecipe?
    @State private var showEditor = false
    @State private var showTour = false
    @FocusState private var pasteFocused: Bool
    @AppStorage("hasSeenImportHelp") private var hasSeenImportHelp = false
    @AppStorage("hasSeenTextImportTour") private var hasSeenTextImportTour = false

    var body: some View {
        let parsed = RecipeImporter.parse(pastedText)
        let canPreview =
            !parsed.title.trimmed.isEmpty
            || !parsed.ingredients.isEmpty
            || !parsed.steps.isEmpty

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    heroRow
                        .padding(.top, AppSpacing.md)
                        .tourTarget(.textImportHero)

                    pasteImportSection(parsed: parsed)

                    actionRow(canPreview: canPreview)

                    // Modest buffer so the action row clears the home
                    // indicator. Don't grow this when focused — the
                    // editor itself is the scroll anchor, not the buffer.
                    Color.clear.frame(height: 32)
                }
                .padding(AppSpacing.lg)
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboards() }
            }
            .scrollDismissesKeyboard(.never)
            .onChange(of: pasteFocused) { _, focused in
                if focused {
                    // One scroll, on focus only. Anchor the editor's
                    // bottom edge to the bottom of the visible area
                    // (which already accounts for the keyboard via
                    // safe-area insets) — the editor's full 280pt
                    // frame ends up right above the keyboard. From
                    // there, TextEditor's internal scroll handles
                    // cursor visibility as the user types, so we
                    // don't re-scroll on every keystroke.
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        proxy.scrollTo(LlamaTourTarget.pasteEditor, anchor: .bottom)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(appearance.accentColor)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.selection()
                        showTour = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                    }
                    .accessibilityLabel("Replay walkthrough")
                    .tourTarget(.textImportHelpIcon)
                }
                // Done button above the keyboard — explicit dismiss
                // now that scroll-to-dismiss is off. Themed with the
                // user's accent so it pairs with the other primary
                // actions.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        Haptics.selection()
                        dismissKeyboards()
                    } label: {
                        Text("Done")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                    }
                }
            }
            .navigationDestination(isPresented: $showEditor) {
                if let draft = parsedDraft {
                    RecipeEditorView(recipe: nil, initialDraft: draft) { savedRecipe in
                        // Hand the new recipe up to RootView so it
                        // can close the editor sheet AND push Detail.
                        // No local dismiss() call — the import sheet
                        // closes via `editor.end()` triggered by
                        // RootView.
                        onSaved(savedRecipe)
                    }
                }
            }
            .onAppear {
                // Migration: legacy `hasSeenImportHelp` users have
                // seen the static help once — treat as having seen
                // the walkthrough too so an update doesn't re-trigger
                // first-time chrome.
                if hasSeenImportHelp && !hasSeenTextImportTour {
                    hasSeenTextImportTour = true
                }

                // Photo-import fallback: pre-fill the editor with
                // OCR'd text so the user can clean it up by hand
                // instead of retyping. Skip auto-tour on this entry
                // — the user has already been through one parser,
                // no need to overlay a walkthrough on top.
                if let seed = seedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !seed.isEmpty,
                   pastedText.isEmpty {
                    pastedText = seed
                } else if !hasSeenTextImportTour {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        showTour = true
                    }
                }
                updateDirty()
            }
            .onChange(of: pastedText) { _, _ in updateDirty() }
            .onDisappear {
                editor.hasUnsavedChanges = false
            }
            .overlayPreferenceValue(LlamaTourTargetKey.self) { anchors in
                if showTour {
                    LlamaIntroOverlay(
                        steps: TextImportTour.steps,
                        anchors: anchors,
                        scrollProxy: proxy,
                        onFinish: {
                            showTour = false
                            hasSeenTextImportTour = true
                        }
                    )
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: showTour)
                }
            }
        }
        .llamaBackground()
        .navigationTitle("Import From Text")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(true)
        .tint(appearance.accentColor)
    }

    // MARK: - Subviews

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaLogo(size: 72, shadowColor: appearance.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from text")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Paste a recipe — I'll fill it in for you.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func pasteImportSection(parsed: DraftRecipe) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text("From text").eyebrowStyle()
                Spacer(minLength: 0)
            }

            // The check panel asks the user to verify what the parser
            // interpreted — so they can catch the "title got merged
            // into ingredients" failure mode before reaching the
            // editor. Animates on every change to the parsed values.
            formatHint(parsed: parsed)
                .tourTarget(.formatHint)

            firstLineHint

            ZStack(alignment: .topLeading) {
                TextEditor(text: $pastedText)
                    .focused($pasteFocused)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(AppSpacing.sm)

                if pastedText.isEmpty {
                    placeholderView
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 280)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(pasteFocused ? appearance.accentColor.opacity(0.6) : AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .animation(.easeInOut(duration: 0.15), value: pasteFocused)
            // tourTarget applies `.id(LlamaTourTarget.pasteEditor)`
            // — also serves as the on-focus scroll anchor (see
            // `.onChange(of: pasteFocused)` above).
            .tourTarget(.pasteEditor)
        }
    }

    /// Tip that sits between the check panel and the editor. Spells
    /// out both the blank-line convention and the explicit "Ingredient" /
    /// "Steps" header fallback so users who paste single-line-block
    /// captions know they have a way out.
    private var firstLineHint: some View {
        HStack(alignment: .top, spacing: AppSpacing.xs + 2) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 1)
            Text("First line is your recipe title — leave a blank space before the first ingredient or type 'Ingredient' above the first ingredient, same goes for 'Steps' and we'll handle the rest!")
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AppColor.textTertiary)
    }

    /// Custom placeholder. Renders as a structured layout (title row,
    /// faint divider, ingredients sample, faint divider, steps sample)
    /// so the user picks up the blank-line convention visually instead
    /// of from a sentence of instructions. The dividers stand in for the
    /// blank lines they'll need in the parsed text.
    private var placeholderView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Recipe Title")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textTertiary)

            placeholderDivider

            VStack(alignment: .leading, spacing: 2) {
                Text("2 cups flour")
                Text("1 cup sugar")
                Text("3 eggs")
            }
            .font(AppFont.body)
            .foregroundStyle(AppColor.textTertiary.opacity(0.7))

            placeholderDivider

            VStack(alignment: .leading, spacing: 2) {
                Text("Mix dry ingredients")
                Text("Cream butter and sugar")
                Text("Bake 350° for 12 min")
            }
            .font(AppFont.body)
            .foregroundStyle(AppColor.textTertiary.opacity(0.7))
        }
        .padding(AppSpacing.md)
    }

    private var placeholderDivider: some View {
        Rectangle()
            .fill(AppColor.divider.opacity(0.55))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    /// Verification panel. Each row asks the user a question rather
    /// than asserting that the parser succeeded — if the title got
    /// glued onto the first ingredient line, the row will display
    /// "Ingredients — Same day sourdough — is this the first
    /// ingredient?" and the user spots the mistake instantly.
    private func formatHint(parsed: DraftRecipe) -> some View {
        let titleDetail = parsed.title.trimmed.isEmpty ? nil : parsed.title.trimmed
        let firstIngredient = formatFirstIngredient(parsed)
        let firstStep = parsed.steps.first?.text

        return VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
            textCheckRow(
                label: "Title",
                detail: titleDetail,
                prompt: nil,
                emptyPlaceholder: "(nothing yet — paste your recipe below)"
            )
            textCheckRow(
                label: "Ingredients",
                detail: firstIngredient,
                prompt: " — is this the first ingredient?",
                emptyPlaceholder: "(nothing yet)"
            )
            textCheckRow(
                label: "Steps",
                detail: firstStep,
                prompt: " — is this the first step for the recipe?",
                emptyPlaceholder: "(nothing yet)"
            )
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// One row of the verification panel. Label is the eyebrow,
    /// value is the parsed text, prompt is the italicized question
    /// the user can answer at a glance. When detail is nil/empty the
    /// row falls back to the placeholder copy and drops the prompt
    /// — the panel stays the same height across all states so the
    /// layout doesn't jump as the user types.
    private func textCheckRow(
        label: String,
        detail: String?,
        prompt: String?,
        emptyPlaceholder: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs + 2) {
            Text(label)
                .font(.system(size: 12, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(AppColor.textPrimary)

            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(AppColor.divider)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let prompt {
                    Text(prompt)
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(AppColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text(emptyPlaceholder)
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(AppColor.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .id(detail ?? "")
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .leading)),
                removal: .opacity
            )
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detail)
    }

    /// Render the first parsed ingredient as a single readable line.
    /// Light punctuation — just space-joined qty, unit, name — since
    /// this is a glance-level confirmation, not the editor's formatted
    /// display.
    private func formatFirstIngredient(_ parsed: DraftRecipe) -> String? {
        guard let first = parsed.ingredients.first else { return nil }
        let pieces = [first.quantity, first.unit, first.name]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        let joined = pieces.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private func actionRow(canPreview: Bool) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                if let clipboard = UIPasteboard.general.string {
                    pastedText = clipboard
                    Haptics.selection()
                }
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Paste from clipboard")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(appearance.accentColor)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColor.surface)
                .overlay(Capsule().stroke(appearance.accentColor, lineWidth: 1))
                .clipShape(Capsule())
            }

            Spacer()

            Button {
                Haptics.impact(.light)
                dismissKeyboards()
                parsedDraft = RecipeImporter.parse(pastedText)
                showEditor = true
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Text("Preview")
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(AppColor.onAccent)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.sm + 2)
                .background(appearance.accentColor)
                .clipShape(Capsule())
                .opacity(canPreview ? 1 : 0.4)
            }
            .disabled(!canPreview)
            .tourTarget(.previewButton)
        }
    }

    // MARK: - Helpers

    private func dismissKeyboards() {
        pasteFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func updateDirty() {
        editor.hasUnsavedChanges = !pastedText.trimmed.isEmpty
    }
}
