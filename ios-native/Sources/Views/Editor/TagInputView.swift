import SwiftUI

struct TagInputView: View {
    @Binding var tags: [String]

    @Environment(AppearanceSettings.self) private var appearance
    @State private var draft = ""
    /// The cleaned custom tag the user just submitted, awaiting their
    /// confirmation in the alert. Nil = no pending confirmation.
    @State private var pendingCustomTag: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if !tags.isEmpty {
                FlowRow(spacing: AppSpacing.xs) {
                    // Selected tags also render alphabetically. Underlying
                    // `tags` is sorted on mutation (see commitPending /
                    // togglePreset), but sorting here too means any
                    // legacy unsorted seed data still displays correctly.
                    ForEach(tags.sorted(), id: \.self) { tag in
                        tagPill(tag)
                    }
                }
            }

            presetGrid

            TextField("Add a custom category…", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit { requestCustomCommit() }
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
        }
        .alert(
            "Add new category?",
            isPresented: pendingTagBinding,
            presenting: pendingCustomTag
        ) { tag in
            Button("Add") { commitPending(tag) }
            Button("Cancel", role: .cancel) {
                // Cancel keeps the draft in the TextField so the user
                // can fix a typo rather than retype from scratch.
                Haptics.selection()
                pendingCustomTag = nil
            }
        } message: { tag in
            Text("Add \"\(StringCase.titleCase(tag))\" to this recipe's categories?")
        }
    }

    // MARK: - Subviews

    private func tagPill(_ tag: String) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Text(StringCase.titleCase(tag))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColor.textPrimary)
            Button {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppColor.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.xs + 2)
        .background(AppColor.surface)
        .overlay(Capsule().stroke(AppColor.divider, lineWidth: 1))
        .clipShape(Capsule())
    }

    /// Wrapping grid of all preset chips. Replaces the previous
    /// horizontal scroller — `FlowRow` lets every preset show up at
    /// once, no horizontal swipe required.
    private var presetGrid: some View {
        FlowRow(spacing: AppSpacing.xs) {
            ForEach(TagPresets.all, id: \.self) { preset in
                let isActive = tags.contains(preset.lowercased())
                Button {
                    togglePreset(preset)
                } label: {
                    Text(StringCase.titleCase(preset))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isActive ? AppColor.onAccent : AppColor.textPrimary)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.xs + 2)
                        .background(isActive ? appearance.accentColor : AppColor.surface)
                        .overlay(
                            Capsule().stroke(isActive ? appearance.accentColor : AppColor.divider, lineWidth: 1)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    /// Stage the typed draft for confirmation. Empty / duplicate inputs
    /// just clear the field — confirmation is reserved for the case
    /// where a real new category would actually land.
    private func requestCustomCommit() {
        let cleaned = normalize(draft)
        guard !cleaned.isEmpty else {
            draft = ""
            return
        }
        if tags.contains(cleaned) {
            // Already added — no need to re-confirm; just clear the
            // field so the user knows their input was understood.
            draft = ""
            return
        }
        pendingCustomTag = cleaned
    }

    /// Commit the alert-confirmed custom tag. Sorted insertion keeps
    /// the displayed and stored arrays alphabetical at all times.
    private func commitPending(_ cleaned: String) {
        guard !cleaned.isEmpty, !tags.contains(cleaned) else {
            draft = ""
            pendingCustomTag = nil
            return
        }
        Haptics.selection()
        tags.append(cleaned)
        tags.sort()
        draft = ""
        pendingCustomTag = nil
    }

    /// Bridge between the optional `pendingCustomTag` and the alert's
    /// `Bool` `isPresented` binding.
    private var pendingTagBinding: Binding<Bool> {
        Binding(
            get: { pendingCustomTag != nil },
            set: { presented in
                if !presented { pendingCustomTag = nil }
            }
        )
    }

    private func togglePreset(_ preset: String) {
        let cleaned = normalize(preset)
        Haptics.selection()
        if let idx = tags.firstIndex(of: cleaned) {
            tags.remove(at: idx)
        } else if !cleaned.isEmpty, !tags.contains(cleaned) {
            tags.append(cleaned)
            tags.sort()
        }
    }

    /// Normalize to the canonical stored form: trim whitespace, drop leading
    /// `#`, lowercase. Lowercasing is the dedup key — "Dessert" and "dessert"
    /// stored as a single `"dessert"` tag, displayed as "Dessert" via
    /// `StringCase.titleCase`.
    private func normalize(_ raw: String) -> String {
        raw
            .trimmed
            .replacingOccurrences(of: #"^#"#, with: "", options: .regularExpression)
            .lowercased()
    }
}
