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
            TextField("Add tag (e.g. dinner)", text: $draft)
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

    private func tagPill(_ tag: String) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Text(StringCase.capitalizeFirst(tag))
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

    private func commit() {
        let cleaned = draft
            .trimmed
            .lowercased()
            .replacingOccurrences(of: "^#", with: "", options: .regularExpression)
        defer { draft = "" }
        guard !cleaned.isEmpty, !tags.contains(cleaned) else { return }
        tags.append(cleaned)
    }
}
