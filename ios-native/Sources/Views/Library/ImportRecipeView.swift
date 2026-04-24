import SwiftUI

struct ImportRecipeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText = ""
    @State private var parsedDraft: DraftRecipe?
    @State private var showEditor = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        let checks = checklist

        VStack(alignment: .leading, spacing: AppSpacing.md) {
            heroRow
                .padding(.top, AppSpacing.md)
            formatHint(checks: checks)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $pastedText)
                    .focused($editorFocused)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(AppSpacing.sm)

                if pastedText.isEmpty {
                    Text("Paste a recipe here…")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(AppSpacing.md)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 280)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

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
                    parsedDraft = RecipeImporter.parse(pastedText)
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
                    .opacity(pastedText.trimmed.isEmpty ? 0.4 : 1)
                }
                .disabled(pastedText.trimmed.isEmpty)
            }

            Spacer()
        }
        .padding(AppSpacing.lg)
        .background(AppColor.background)
        .navigationTitle("Import recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(AppColor.textPrimary)
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            if let draft = parsedDraft {
                RecipeEditorView(recipe: nil, initialDraft: draft) {
                    // Save inside the import flow should dismiss the whole
                    // sheet, not just pop the editor back to this view.
                    dismiss()
                }
            }
        }
    }

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

    private func formatHint(checks: Checklist) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Format")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(AppColor.textSecondary)

            HStack(spacing: AppSpacing.xs + 2) {
                checkPill(label: "Title", done: checks.title)
                separator
                checkPill(label: "Ingredients", done: checks.ingredients)
                separator
                checkPill(label: "Steps", done: checks.steps)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm + 2)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: checks)
    }

    private func checkPill(label: String, done: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(done ? AppColor.success : AppColor.textSecondary.opacity(0.6))
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(done ? AppColor.textPrimary : AppColor.textSecondary)
        }
        .contentTransition(.symbolEffect(.replace))
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 12))
            .foregroundStyle(AppColor.divider)
    }

    private struct Checklist: Equatable {
        let title: Bool
        let ingredients: Bool
        let steps: Bool
    }

    private var checklist: Checklist {
        let draft = RecipeImporter.parse(pastedText)
        return Checklist(
            title: hasTitleKeyword && !draft.title.trimmed.isEmpty,
            ingredients: !draft.ingredients.isEmpty,
            steps: !draft.steps.isEmpty
        )
    }

    /// The title check only ticks when the user has explicitly typed the
    /// `Title` keyword on the first non-empty line — matching the pattern
    /// used for `Ingredients` and `Steps`. The parser itself still accepts
    /// a keyword-less first line as a fallback so saved recipes don't end
    /// up titleless, but the checklist mirrors the *format*, not the parse.
    private var hasTitleKeyword: Bool {
        let firstLine = pastedText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        return (try? #/^[Tt]itle\b/#.firstMatch(in: firstLine)) != nil
    }
}
