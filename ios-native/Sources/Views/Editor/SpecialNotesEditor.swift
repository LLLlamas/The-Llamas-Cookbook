import SwiftUI

/// Reminder editor with four placement slots:
///   • `preface`    — pinned above the first step
///   • `step(id:)`  — pinned to a specific step
///   • `epilogue`   — pinned after the last step
///   • `general`    — free-floating recipe-wide note
///
/// Each slot can carry at most one reminder. The picker only offers
/// slots that are currently empty so users don't accidentally overwrite
/// existing notes via the +Special Note flow — to edit, they tap the
/// existing row, which puts that slot back into typing mode.
struct SpecialNotesEditor: View {
    @Binding var steps: [DraftStep]
    @Binding var prefaceNote: String
    @Binding var epilogueNote: String
    @Binding var generalNote: String

    @Environment(AppearanceSettings.self) private var appearance

    @State private var mode: Mode = .idle
    @State private var draftText: String = ""
    @FocusState private var noteFieldFocused: Bool

    enum Mode: Equatable {
        case idle
        case picking
        case typing(target: NoteTarget)
    }

    /// Where a reminder is attached. `step` carries the step UUID so the
    /// note follows the step through reorderings rather than locking to
    /// a position index.
    enum NoteTarget: Hashable {
        case preface
        case step(UUID)
        case epilogue
        case general
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            header

            if !existingTargets.isEmpty {
                VStack(spacing: AppSpacing.xs) {
                    ForEach(existingTargets, id: \.self) { target in
                        existingRow(for: target)
                    }
                }
                .transition(.opacity)
            }

            switch mode {
            case .idle:
                addButton
            case .picking:
                targetPicker
            case .typing(let target):
                typingRow(target: target)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: mode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: existingTargets)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Special Notes")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.textPrimary)
            Text("Pin a reminder before, after, or to a specific step — or leave a free-floating note.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, AppSpacing.md)
    }

    private var addButton: some View {
        Button {
            Haptics.selection()
            mode = .picking
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                Text("Special Note")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(appearance.accentColor)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(AppColor.surface)
            .overlay(Capsule().stroke(appearance.accentColor, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(availableTargets.isEmpty)
        .opacity(availableTargets.isEmpty ? 0.4 : 1)
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("Where should it go?")
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

            if availableTargets.isEmpty {
                Text("Every slot already has a note — remove one to reassign.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.xs) {
                        ForEach(availableTargets, id: \.self) { target in
                            targetChip(target)
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
                .stroke(appearance.accentColor.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .transition(.opacity)
    }

    private func targetChip(_ target: NoteTarget) -> some View {
        Button {
            Haptics.selection()
            draftText = ""
            mode = .typing(target: target)
            noteFieldFocused = true
        } label: {
            Text(label(for: target))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColor.onAccent)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.xs + 2)
                .background(appearance.accentColor)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func typingRow(target: NoteTarget) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.xs) {
                Text(label(for: target))
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
                placeholder(for: target),
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
                    saveNote(target: target)
                } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColor.onAccent)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.xs + 2)
                        .background(appearance.accentColor)
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
                .stroke(appearance.accentColor.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .transition(.opacity)
    }

    private func existingRow(for target: NoteTarget) -> some View {
        let note = currentText(for: target)
        return Button {
            Haptics.selection()
            draftText = note
            mode = .typing(target: target)
            noteFieldFocused = true
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Text(label(for: target))
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
                    clearNote(target: target)
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

    // MARK: - Targets / labels

    /// Targets currently carrying a non-empty note, in display order:
    /// preface → steps in recipe order → epilogue → general.
    private var existingTargets: [NoteTarget] {
        var out: [NoteTarget] = []
        if !prefaceNote.trimmed.isEmpty { out.append(.preface) }
        for step in steps where !(step.specialNote ?? "").trimmed.isEmpty {
            out.append(.step(step.id))
        }
        if !epilogueNote.trimmed.isEmpty { out.append(.epilogue) }
        if !generalNote.trimmed.isEmpty { out.append(.general) }
        return out
    }

    /// Empty slots offered in the picker. "Before" leads, then steps with
    /// content but no existing note, then "After", then the free-floating
    /// "Note" — matches the order the user dictated.
    private var availableTargets: [NoteTarget] {
        var out: [NoteTarget] = []
        if prefaceNote.trimmed.isEmpty { out.append(.preface) }
        for step in steps {
            if step.text.trimmed.isEmpty { continue }
            if (step.specialNote ?? "").trimmed.isEmpty {
                out.append(.step(step.id))
            }
        }
        if epilogueNote.trimmed.isEmpty { out.append(.epilogue) }
        if generalNote.trimmed.isEmpty { out.append(.general) }
        return out
    }

    private func label(for target: NoteTarget) -> String {
        switch target {
        case .preface: return "Before"
        case .step(let id):
            let n = (steps.firstIndex(where: { $0.id == id }) ?? 0) + 1
            return "Step \(n)"
        case .epilogue: return "After"
        case .general: return "Note"
        }
    }

    private func placeholder(for target: NoteTarget) -> String {
        switch target {
        case .preface: return "e.g. Take eggs and butter out 1 hour before"
        case .step: return "e.g. Don't forget to cut vertically"
        case .epilogue: return "e.g. Let it rest 10 minutes before slicing"
        case .general: return "e.g. Doubles well for a crowd"
        }
    }

    private func currentText(for target: NoteTarget) -> String {
        switch target {
        case .preface: return prefaceNote
        case .step(let id):
            return steps.first(where: { $0.id == id })?.specialNote ?? ""
        case .epilogue: return epilogueNote
        case .general: return generalNote
        }
    }

    // MARK: - Actions

    private func saveNote(target: NoteTarget) {
        let trimmed = draftText.trimmed
        guard !trimmed.isEmpty else { return }
        switch target {
        case .preface:
            prefaceNote = trimmed
        case .step(let id):
            if let idx = steps.firstIndex(where: { $0.id == id }) {
                steps[idx].specialNote = trimmed
            }
        case .epilogue:
            epilogueNote = trimmed
        case .general:
            generalNote = trimmed
        }
        Haptics.success()
        noteFieldFocused = false
        draftText = ""
        mode = .idle
    }

    private func clearNote(target: NoteTarget) {
        switch target {
        case .preface:
            prefaceNote = ""
        case .step(let id):
            if let idx = steps.firstIndex(where: { $0.id == id }) {
                steps[idx].specialNote = nil
            }
        case .epilogue:
            epilogueNote = ""
        case .general:
            generalNote = ""
        }
    }
}
