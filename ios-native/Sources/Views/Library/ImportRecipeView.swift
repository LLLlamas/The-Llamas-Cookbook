import SwiftUI
import UIKit

struct ImportRecipeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var titleText = ""
    @State private var ingredientsText = ""
    @State private var stepsText = ""
    @State private var parsedDraft: DraftRecipe?
    @State private var showEditor = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case title, ingredients, steps }

    private var ingredientCount: Int { RecipeImporter.countIngredients(in: ingredientsText) }
    private var stepCount: Int { RecipeImporter.countSteps(in: stepsText) }

    private var titleDone: Bool { !titleText.trimmed.isEmpty }
    private var ingredientsDone: Bool { ingredientCount > 0 }
    private var stepsDone: Bool { stepCount > 0 }

    private var canPreview: Bool {
        titleDone || ingredientsDone || stepsDone
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                heroRow
                    .padding(.top, AppSpacing.md)

                inputSection(
                    prompt: "What are we cooking?",
                    done: titleDone,
                    field: .title
                ) {
                    TextField("", text: $titleText, prompt: Text("What are we cooking?")
                        .foregroundStyle(AppColor.textTertiary))
                        .focused($focused, equals: .title)
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(AppColor.textPrimary)
                        .submitLabel(.next)
                        .onSubmit { focused = .ingredients }
                }

                dottedDivider

                inputSection(
                    prompt: "List the ingredients here",
                    done: ingredientsDone,
                    field: .ingredients,
                    secondary: ingredientCount > 0 ? "\(ingredientCount) detected" : nil
                ) {
                    editor(text: $ingredientsText, placeholder: "List the ingredients here\n(one per line)", field: .ingredients)
                        .frame(minHeight: 140)
                }

                dottedDivider

                inputSection(
                    prompt: "List the steps here!",
                    done: stepsDone,
                    field: .steps,
                    secondary: stepCount > 0 ? "\(stepCount) detected" : nil
                ) {
                    editor(text: $stepsText, placeholder: "List the steps here!\n(one per line)", field: .steps)
                        .frame(minHeight: 160)
                }

                actionRow
                    .padding(.top, AppSpacing.md)
            }
            .padding(AppSpacing.lg)
            .contentShape(Rectangle())
            .onTapGesture {
                focused = nil
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(AppColor.background)
        .navigationTitle("Import recipe")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(AppColor.textPrimary)
            }
            ToolbarItemGroup(placement: .keyboard) {
                if focused != nil {
                    Spacer()
                    Button("Done") { focused = nil }
                        .foregroundStyle(AppColor.accent)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            if let draft = parsedDraft {
                RecipeEditorView(recipe: nil, initialDraft: draft) {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Subviews

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaMascot(size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("From notes")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Paste a recipe, type in the key words, and we'll pre-fill everything for you!")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func inputSection<Content: View>(
        prompt: String,
        done: Bool,
        field: Field,
        secondary: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
            HStack(spacing: AppSpacing.xs + 2) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(done ? AppColor.success : AppColor.textSecondary.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                Text(prompt)
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(done ? AppColor.textPrimary : AppColor.textSecondary)
                Spacer(minLength: 0)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColor.textTertiary)
                        .monospacedDigit()
                        .transition(.opacity)
                }
            }
            content()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: done)
    }

    private func editor(text: Binding<String>, placeholder: String, field: Field) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .focused($focused, equals: field)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(AppSpacing.xs)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textTertiary)
                    .padding(AppSpacing.sm + 4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var dottedDivider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 1)
            .overlay(
                GeometryReader { geo in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0.5))
                        path.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
                    }
                    .stroke(
                        AppColor.dividerStrong.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 5])
                    )
                }
            )
            .padding(.vertical, AppSpacing.xs)
    }

    private var actionRow: some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                if let clipboard = UIPasteboard.general.string {
                    pasteIntoFocused(clipboard)
                    Haptics.selection()
                }
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Paste")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(AppColor.accent)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColor.surface)
                .overlay(Capsule().stroke(AppColor.accent, lineWidth: 1))
                .clipShape(Capsule())
            }

            Spacer()

            Button {
                Haptics.impact(.light)
                focused = nil
                parsedDraft = RecipeImporter.build(
                    title: titleText,
                    ingredientsText: ingredientsText,
                    stepsText: stepsText
                )
                showEditor = true
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Text("Preview")
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.sm + 2)
                .background(AppColor.accent)
                .clipShape(Capsule())
                .opacity(canPreview ? 1 : 0.4)
            }
            .disabled(!canPreview)
        }
    }

    /// When user taps Paste, route clipboard content into the currently
    /// focused field. If nothing is focused, assume they mean ingredients
    /// (the most common paste target).
    private func pasteIntoFocused(_ text: String) {
        switch focused ?? .ingredients {
        case .title: titleText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .ingredients: ingredientsText = text
        case .steps: stepsText = text
        }
    }
}
