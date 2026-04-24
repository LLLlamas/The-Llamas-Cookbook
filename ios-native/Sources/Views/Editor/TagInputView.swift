import SwiftUI

struct TagInputView: View {
    @Binding var tags: [String]

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if !tags.isEmpty {
                FlowRow(spacing: AppSpacing.xs) {
                    ForEach(tags, id: \.self) { tag in
                        tagPill(tag)
                    }
                }
            }

            presetScroller

            TextField("Add a custom category…", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit { commit() }
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

    private var presetScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.xs) {
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
                            .background(isActive ? AppColor.accent : AppColor.surface)
                            .overlay(
                                Capsule().stroke(isActive ? AppColor.accent : AppColor.divider, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Actions

    private func commit() {
        let cleaned = normalize(draft)
        defer { draft = "" }
        guard !cleaned.isEmpty, !tags.contains(cleaned) else { return }
        Haptics.selection()
        tags.append(cleaned)
    }

    private func togglePreset(_ preset: String) {
        let cleaned = normalize(preset)
        Haptics.selection()
        if let idx = tags.firstIndex(of: cleaned) {
            tags.remove(at: idx)
        } else if !cleaned.isEmpty, !tags.contains(cleaned) {
            tags.append(cleaned)
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
