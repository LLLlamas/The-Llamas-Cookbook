import SwiftUI

/// Per-step reminder editor. Sits under the Notes section of the recipe
/// editor. Three states:
///   1. idle — shows existing notes (if any) + "+ Special Note" button
///   2. pickingStep — user picked the button; chips for each step appear
///   3. typing(stepId:) — user picked a step; text field + Save/Cancel
///
/// Data is written straight into the bound `[DraftStep]`: each step's
/// `specialNote` is nil (no note) or a non-empty string. Empty strings
/// are normalized to nil on save so they don't persist as "has note".
struct SpecialNotesEditor: View {
    @Binding var steps: [DraftStep]

    @State private var mode: Mode = .idle
    @State private var draftText: String = ""
    @FocusState private var noteFieldFocused: Bool

    enum Mode: Equatable {
        case idle
        case pickingStep
        case typing(stepId: UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            header

            if !stepsWithNotes.isEmpty {
                VStack(spacing: AppSpacing.xs) {
                    ForEach(stepsWithNotes, id: \.id) { step in
                        existingRow(for: step)
                    }
                }
                .transition(.opacity)
            }

            switch mode {
            case .idle:
                addButton
            case .pickingStep:
                stepPicker
            case .typing(let stepId):
                typingRow(stepId: stepId)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: mode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: stepsWithNotes.map(\.id))
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Special Notes")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(AppColor.textPrimary)
            Text("Pin a reminder to a specific step — it appears in Cook Mode when you reach that step.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, AppSpacing.sm)
    }

    private var addButton: some View {
        Button {
            Haptics.selection()
            mode = .pickingStep
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("Special Note")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppColor.accent)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(AppColor.surface)
            .overlay(Capsule().stroke(AppColor.accent, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(availableSteps.isEmpty)
        .opacity(availableSteps.isEmpty ? 0.4 : 1)
    }

    private var stepPicker: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("Which step?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                Spacer()
                Button("Cancel") {
                    Haptics.selection()
                    mode = .idle
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColor.textSecondary)
            }

            if availableSteps.isEmpty {
                Text("Every step already has a note — remove one to reassign.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.xs) {
                        ForEach(availableSteps, id: \.step.id) { entry in
                            stepChip(number: entry.number, stepId: entry.step.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.accent.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .transition(.opacity)
    }

    private func stepChip(number: Int, stepId: UUID) -> some View {
        Button {
            Haptics.selection()
            draftText = ""
            mode = .typing(stepId: stepId)
            noteFieldFocused = true
        } label: {
            Text("Step \(number)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColor.onAccent)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.xs + 2)
                .background(AppColor.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func typingRow(stepId: UUID) -> some View {
        let number = (steps.firstIndex(where: { $0.id == stepId }) ?? 0) + 1
        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.xs) {
                Text("Step \(number)")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(AppColor.accentDeep)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 3)
                    .background(AppColor.accentSoft)
                    .clipShape(Capsule())
                Spacer()
            }

            TextField(
                "e.g. Don't forget to cut vertically",
                text: $draftText,
                axis: .vertical
            )
            .lineLimit(2...4)
            .focused($noteFieldFocused)
            .padding(AppSpacing.sm + 2)
            .background(AppColor.background)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            .font(AppFont.body)
            .foregroundStyle(AppColor.textPrimary)

            HStack(spacing: AppSpacing.sm) {
                Button("Cancel") {
                    Haptics.selection()
                    noteFieldFocused = false
                    draftText = ""
                    mode = .idle
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppColor.textSecondary)

                Spacer()

                Button {
                    saveNote(forStep: stepId)
                } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColor.onAccent)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.xs + 2)
                        .background(AppColor.accent)
                        .clipShape(Capsule())
                        .opacity(draftText.trimmed.isEmpty ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(draftText.trimmed.isEmpty)
            }
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.accent.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .transition(.opacity)
    }

    private func existingRow(for step: DraftStep) -> some View {
        let number = (steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1
        let note = step.specialNote ?? ""
        return Button {
            Haptics.selection()
            draftText = note
            mode = .typing(stepId: step.id)
            noteFieldFocused = true
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Text("Step \(number)")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(AppColor.accentDeep)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 3)
                    .background(AppColor.accentSoft)
                    .clipShape(Capsule())

                Text(note)
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                Button {
                    Haptics.impact(.light)
                    clearNote(forStep: step.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AppColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(AppSpacing.sm + 2)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived

    /// Steps that currently carry a note, in recipe order.
    private var stepsWithNotes: [DraftStep] {
        steps.filter { !(($0.specialNote ?? "").trimmed.isEmpty) }
    }

    /// Step-picker candidates. Excludes steps with blank text (nothing to
    /// reference) and — when adding fresh — excludes steps that already
    /// have a note. When *editing* an existing note, that step stays
    /// selectable via its row, so we don't need it in the picker.
    private var availableSteps: [(number: Int, step: DraftStep)] {
        steps.enumerated()
            .filter { _, step in
                !step.text.trimmed.isEmpty && (step.specialNote ?? "").trimmed.isEmpty
            }
            .map { (number: $0.offset + 1, step: $0.element) }
    }

    // MARK: - Actions

    private func saveNote(forStep stepId: UUID) {
        let trimmed = draftText.trimmed
        guard !trimmed.isEmpty else { return }
        if let idx = steps.firstIndex(where: { $0.id == stepId }) {
            steps[idx].specialNote = trimmed
        }
        Haptics.success()
        noteFieldFocused = false
        draftText = ""
        mode = .idle
    }

    private func clearNote(forStep stepId: UUID) {
        if let idx = steps.firstIndex(where: { $0.id == stepId }) {
            steps[idx].specialNote = nil
        }
    }
}
