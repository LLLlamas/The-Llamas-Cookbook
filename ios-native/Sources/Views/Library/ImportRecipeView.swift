import SwiftUI
import UIKit

struct ImportRecipeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText = ""
    @State private var parsedDraft: DraftRecipe?
    @State private var showEditor = false
    @State private var showHelp = false
    @FocusState private var editorFocused: Bool
    @AppStorage("hasSeenImportHelp") private var hasSeenImportHelp = false

    var body: some View {
        let parsed = RecipeImporter.parse(pastedText)
        let checks = Checks(
            title: !parsed.title.trimmed.isEmpty,
            ingredients: !parsed.ingredients.isEmpty,
            steps: !parsed.steps.isEmpty
        )

        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                heroRow
                    .padding(.top, AppSpacing.md)

                formatHint(checks: checks, parsed: parsed)

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
                            .foregroundStyle(AppColor.textTertiary)
                            .padding(AppSpacing.md)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 320)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))

                actionRow(canPreview: !pastedText.trimmed.isEmpty)
            }
            .padding(AppSpacing.lg)
            .contentShape(Rectangle())
            .onTapGesture {
                editorFocused = false
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.selection()
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColor.accent)
                }
                .accessibilityLabel("How import works")
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            if let draft = parsedDraft {
                RecipeEditorView(recipe: nil, initialDraft: draft) {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showHelp) {
            ImportHelpView { showHelp = false }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            if !hasSeenImportHelp {
                // Delay slightly so the sheet-presentation animation finishes
                // before the nested help sheet slides up.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    showHelp = true
                    hasSeenImportHelp = true
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

    private func formatHint(checks: Checks, parsed: DraftRecipe) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
            HStack(spacing: AppSpacing.sm) {
                checkPill(label: "Title", done: checks.title, secondary: parsed.title.trimmed.isEmpty ? nil : parsed.title.trimmed)
            }
            HStack(spacing: AppSpacing.sm) {
                checkPill(label: "Ingredients", done: checks.ingredients, secondary: checks.ingredients ? "\(parsed.ingredients.count) detected" : nil)
            }
            HStack(spacing: AppSpacing.sm) {
                checkPill(label: "Steps", done: checks.steps, secondary: checks.steps ? "\(parsed.steps.count) detected" : nil)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: checks)
    }

    private func checkPill(label: String, done: Bool, secondary: String?) -> some View {
        HStack(spacing: AppSpacing.xs + 2) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(done ? AppColor.success : AppColor.textSecondary.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
            Text(label)
                .font(.system(size: 12, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(done ? AppColor.textPrimary : AppColor.textSecondary)
            if let secondary {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.divider)
                Text(secondary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
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
                editorFocused = false
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
                .opacity(canPreview ? 1 : 0.4)
            }
            .disabled(!canPreview)
        }
    }

    private struct Checks: Equatable {
        let title: Bool
        let ingredients: Bool
        let steps: Bool
    }
}
