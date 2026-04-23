import SwiftUI
import SwiftData
import UIKit

struct RecipeEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// nil when creating a new recipe; the target when editing.
    let recipe: Recipe?

    @State private var draft: DraftRecipe
    @State private var showDiscardAlert = false
    @FocusState private var isNumericFocused: Bool

    init(recipe: Recipe?, initialDraft: DraftRecipe? = nil) {
        self.recipe = recipe
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
                    VStack(spacing: AppSpacing.xs) {
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
                sectionHint("One step per line. They'll be numbered and you'll check them off while cooking.")
                StepQuickAdd(nextNumber: draft.steps.count + 1) {
                    draft.steps.append($0)
                }
                if !draft.steps.isEmpty {
                    VStack(spacing: 2) {
                        ForEach($draft.steps) { $step in
                            StepRowEditor(
                                index: draft.steps.firstIndex(where: { $0.id == step.id }) ?? 0,
                                step: $step
                            ) {
                                draft.steps.removeAll { $0.id == step.id }
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                        }
                    }
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: draft.steps.count)
                }

                sectionHeader("Tags")
                TagInputView(tags: $draft.tags)

                sectionHeader("Notes")
                TextField(
                    "Optional notes — e.g. use less salt next time",
                    text: $draft.notes
                )
                .submitLabel(.done)
                .padding(AppSpacing.md)
                .frame(minHeight: 64, alignment: .topLeading)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)

                sectionHeader("Reference link")
                sectionHint("Optional. Paste a URL if you adapted this from somewhere online.")
                TextField("https://example.com/recipe", text: $draft.sourceUrl)
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
            .padding(.bottom, AppSpacing.xxl)
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        }
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
                        .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
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
    }

    // MARK: - Header

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaMascot(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe == nil ? "New recipe" : "Edit recipe")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Start with a name — the rest is up to you.")
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
            TextField("e.g. Grandma's Sunday pasta", text: $draft.title)
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
            Text("Optional details")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(AppColor.textPrimary)
            Text("Set servings so you can scale ingredients while cooking. Set Cook time to start a timer on the matching step.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)

            HStack(spacing: AppSpacing.sm) {
                numberField(label: "Servings", text: $draft.servings, placeholder: "4")
                numberField(label: "Cook time (min)", text: $draft.cookTimeMinutes, placeholder: "30")
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
        if !trimmed.isEmpty { return trimmed }
        return recipe == nil ? "New recipe" : "Edit recipe"
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
        dismiss()
    }
}

