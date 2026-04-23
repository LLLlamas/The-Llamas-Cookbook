import SwiftUI

struct ConversionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    header
                    ForEach(Conversions.sections) { section in
                        sectionCard(section)
                    }
                }
                .padding(AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl)
            }
            .background(AppColor.background)
            .navigationTitle("Conversions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppColor.accent)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaMascot(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kitchen reference")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Volumes, weights, oven temps — the stuff you forget mid-cook.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, AppSpacing.xs)
    }

    private func sectionCard(_ section: Conversions.Section) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                if let subtitle = section.subtitle {
                    Text(subtitle)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { idx, row in
                    conversionRow(row)
                    if idx < section.rows.count - 1 {
                        Rectangle()
                            .fill(AppColor.divider)
                            .frame(height: 1)
                    }
                }
            }
            .background(AppColor.background)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func conversionRow(_ row: Conversions.Row) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            Text(row.lhs)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppColor.accent.opacity(0.7))
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.rhs)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.accent)
                    .monospacedDigit()
                if let note = row.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(AppColor.textSecondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm + 2)
    }
}

#Preview { ConversionsView() }
