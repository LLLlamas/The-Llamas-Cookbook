import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct RecipeEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorCoordinator.self) private var editor

    /// nil when creating a new recipe; the target when editing.
    let recipe: Recipe?
    /// Optional override for the post-save dismissal. When the editor is pushed
    /// inside another sheet (e.g. the Import flow), the parent sets this to
    /// dismiss the *whole* sheet on Save instead of just popping the editor.
    let onSaved: (() -> Void)?

    @State private var draft: DraftRecipe
    @State private var showDiscardAlert = false
    @State private var editingStepId: UUID? = nil
    @State private var draggingStepId: UUID? = nil
    @FocusState private var isNumericFocused: Bool

    init(recipe: Recipe?, initialDraft: DraftRecipe? = nil, onSaved: (() -> Void)? = nil) {
        self.recipe = recipe
        self.onSaved = onSaved
        _draft = State(initialValue: initialDraft ?? recipe?.toDraft() ?? DraftRecipe())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                heroRow
                titleBlock
                summaryField

                sectionHeader("Ingredients")
                sectionHint("Fill in quantity, unit, and ingredient — all three are required before you add the row.")
                IngredientQuickAdd(numericFocus: $isNumericFocused) { draft.ingredients.append($0) }
                if !draft.ingredients.isEmpty {
                    VStack(spacing: 3) {
                        ForEach($draft.ingredients) { $ingredient in
                            IngredientRowEditor(ingredient: $ingredient, numericFocus: $isNumericFocused) {
                                draft.ingredients.removeAll { $0.id == ingredient.id }
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                        }
                    }
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: draft.ingredients.count)
                }

                sectionHeader("Steps")
                sectionHint("List the steps in order, and tap the timer icon if you need to use it for that step. Long press and drag to reorder if you need!")
                StepQuickAdd(nextNumber: draft.steps.count + 1) {
                    draft.steps.append($0)
                }
                if !draft.steps.isEmpty {
                    VStack(spacing: AppSpacing.xs) {
                        ForEach($draft.steps) { $step in
                            let stepId = step.id
                            StepRowEditor(
                                index: draft.steps.firstIndex(where: { $0.id == stepId }) ?? 0,
                                step: $step,
                                isEditing: Binding(
                                    get: { editingStepId == stepId },
                                    set: { newValue in
                                        // No animation — the user wants the
                                        // pill to instantly switch state, not
                                        // spring between view and edit.
                                        editingStepId = newValue ? stepId : nil
                                    }
                                )
                            ) {
                                draft.steps.removeAll { $0.id == stepId }
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                            .onDrag {
                                // Starting a drag should pull every step out
                                // of edit mode so the keyboard gets out of
                                // the way and rows can slide around cleanly.
                                editingStepId = nil
                                draggingStepId = stepId
                                return NSItemProvider(object: stepId.uuidString as NSString)
                            } preview: {
                                stepDragPreview(for: step)
                            }
                            .onDrop(of: [.text], delegate: StepDropDelegate(
                                targetId: stepId,
                                draft: $draft,
                                draggingId: $draggingStepId
                            ))
                        }
                    }
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: draft.steps.count)
                }

                sectionHeader("Categories")
                TagInputView(tags: $draft.tags)

                sectionHeader("Notes")
                // axis: .vertical + no .submitLabel lets the keyboard's
                // return key insert newlines instead of dismissing, so the
                // field grows as the user writes a real paragraph. Keyboard
                // still dismisses via scroll or tap-outside (scrollDismissesKeyboard + outer onTapGesture).
                TextField(
                    "Optional notes — e.g. use less salt next time",
                    text: $draft.notes,
                    axis: .vertical
                )
                .lineLimit(3...12)
                .padding(AppSpacing.md)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)

                SpecialNotesEditor(steps: $draft.steps)

                sectionHeader("Reference Link")
                sectionHint("Optional. Paste a URL if you adapted this from somewhere online.")
                TextField(
                    "",
                    text: $draft.sourceUrl,
                    // `prompt:` lets us style the placeholder directly —
                    // necessary here because the URL keyboard + URL-shaped
                    // placeholder otherwise renders link-styled blue.
                    prompt: Text("https://example.com/recipe")
                        .foregroundStyle(AppColor.textTertiary)
                )
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(AppColor.divider, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)

                optionalDetails
            }
            .padding(AppSpacing.lg)
            // Extra bottom runway so the focused TextField sits well above
            // the keyboard, not crammed right against its top edge.
            .padding(.bottom, 120)
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
                editingStepId = nil
            }
        }
        .simultaneousGesture(
            DragGesture().onChanged { _ in
                // Any scroll gesture collapses step edit mode (paired with
                // scrollDismissesKeyboard, which handles the keyboard itself).
                if editingStepId != nil {
                    editingStepId = nil
                }
            }
        )
        .scrollDismissesKeyboard(.immediately)
        .background(AppColor.background)
        .navigationTitle(headerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { attemptCancel() }
                    .foregroundStyle(AppColor.textPrimary)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    Text("Save")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColor.onAccent)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, 6)
                        .background(AppColor.accent)
                        .clipShape(Capsule())
                        .opacity(draft.canSave ? 1 : 0.4)
                }
                .disabled(!draft.canSave)
            }
            ToolbarItemGroup(placement: .keyboard) {
                if isNumericFocused {
                    Spacer()
                    Button("Done") {
                        isNumericFocused = false
                    }
                    .foregroundStyle(AppColor.accent)
                    .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .alert("Discard changes?", isPresented: $showDiscardAlert) {
            Button("Keep editing", role: .cancel) { }
            Button("Discard", role: .destructive) { dismiss() }
        } message: {
            Text("Your edits will be lost.")
        }
        .onAppear { syncDirty() }
        .onChange(of: draft) { _, _ in syncDirty() }
        .onDisappear { editor.hasUnsavedChanges = false }
    }

    /// Keep EditorCoordinator's dirty flag in sync with the live draft.
    /// The coordinator uses it to gate switch-to-a-different-sheet
    /// attempts behind the discard alert at RootView.
    private func syncDirty() {
        if let existing = recipe {
            editor.hasUnsavedChanges = (existing.toDraft() != draft)
        } else {
            editor.hasUnsavedChanges = draft.hasAnyContent
        }
    }

    // MARK: - Header

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaMascot(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe == nil ? "New Recipe" : "Edit Recipe")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("What are we cookin'?")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                Text("RECIPE NAME")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppColor.textPrimary)
                Text("REQUIRED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppColor.accent)
            }
            TextField("", text: $draft.title)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .padding(AppSpacing.md)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.accent, lineWidth: 2)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .font(AppFont.recipeTitle)
                .foregroundStyle(AppColor.textPrimary)
        }
    }

    private var summaryField: some View {
        TextField("Short description (optional)", text: $draft.summary)
            .submitLabel(.done)
            .padding(AppSpacing.md)
            .frame(minHeight: 56, alignment: .topLeading)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .font(AppFont.body)
            .foregroundStyle(AppColor.textPrimary)
    }

    private var optionalDetails: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Optional Details")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(AppColor.textPrimary)
            Text("Set servings so you can scale ingredients while cooking.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)

            HStack(alignment: .bottom, spacing: AppSpacing.sm) {
                numberField(label: "Servings", text: $draft.servings, placeholder: "4")
                okButton
            }
            .padding(.top, AppSpacing.xs)
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .padding(.top, AppSpacing.xl)
    }

    /// Dismisses the numeric keyboard. Sits next to Servings and pairs
    /// with `numberField`'s label+field vertical rhythm via an invisible
    /// spacer label so both columns align at the bottom.
    private var okButton: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(" ")
                .font(AppFont.caption)
            Button {
                Haptics.selection()
                isNumericFocused = false
            } label: {
                Text("OK")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AppColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func numberField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
            TextField(placeholder, text: text)
                .keyboardType(.numberPad)
                .focused($isNumericFocused)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColor.background)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.sectionHeading)
            .foregroundStyle(AppColor.textPrimary)
            .padding(.top, AppSpacing.md)
    }

    private func sectionHint(_ hint: String) -> some View {
        Text(hint)
            .font(AppFont.caption)
            .foregroundStyle(AppColor.textSecondary)
            .padding(.bottom, AppSpacing.xs)
    }

    // MARK: - Actions

    private var headerTitle: String {
        let trimmed = draft.title.trimmed
        if !trimmed.isEmpty { return StringCase.titleCase(trimmed) }
        return recipe == nil ? "New Recipe" : "Edit Recipe"
    }

    private func attemptCancel() {
        if draft.hasAnyContent && recipe == nil {
            showDiscardAlert = true
        } else if let existing = recipe, existing.toDraft() != draft {
            showDiscardAlert = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard draft.canSave else { return }
        Haptics.success()
        if let existing = recipe {
            existing.apply(draft)
        } else {
            let newRecipe = Recipe.new(from: draft)
            modelContext.insert(newRecipe)
        }
        if let onSaved {
            onSaved()
        } else {
            dismiss()
        }
    }

    // MARK: - Step reordering

    @ViewBuilder
    private func stepDragPreview(for step: DraftStep) -> some View {
        let indexLabel = (draft.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppColor.accent)
            Text("\(indexLabel). \(step.text.isEmpty ? "Step" : step.text)")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.accent, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .shadow(color: AppColor.shadow, radius: 12, x: 0, y: 4)
    }

}

/// Drop delegate that reports `.move` semantics to iOS — which suppresses the
/// green "+" copy indicator on the drag preview. `.dropDestination(for:)`
/// always defaults to `.copy`, so we drop back to `onDrop(delegate:)` here.
private struct StepDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var draft: DraftRecipe
    @Binding var draggingId: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingId = nil }
        guard let fromId = draggingId,
              fromId != targetId,
              let fromIdx = draft.steps.firstIndex(where: { $0.id == fromId }),
              let toIdx = draft.steps.firstIndex(where: { $0.id == targetId })
        else { return false }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            let moved = draft.steps.remove(at: fromIdx)
            draft.steps.insert(moved, at: toIdx)
        }
        Haptics.impact(.medium)
        return true
    }
}

