import SwiftUI

/// Modal sheet for the sourdough feeding calculator. User enters how
/// much active starter they want (grams), picks a ratio from the table,
/// and confirms — the parent inserts three ingredients (starter, water,
/// flour) into the recipe at the chosen amounts.
///
/// Surfaced from `RecipeDetailView` only when the recipe is tagged
/// "sourdough"; sits next to the Conversions chip on the Ingredients
/// section header.
struct SourdoughCalculatorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance

    /// Called once the user confirms a row. The parent owns the SwiftData
    /// write — this view stays purely presentational.
    let onAdd: (SourdoughCalculator.Row) -> Void

    @State private var totalText: String = "100"
    @State private var selectedRatio: Int = 5
    @FocusState private var totalFocused: Bool

    private var total: Double {
        let cleaned = totalText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned) ?? 0
    }

    private var rows: [SourdoughCalculator.Row] {
        SourdoughCalculator.table(forTotal: total)
    }

    private var selectedRow: SourdoughCalculator.Row? {
        rows.first { $0.ratio == selectedRatio }
    }

    private var canAdd: Bool {
        total > 0 && selectedRow != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    header
                    totalCard
                    table
                }
                .padding(AppSpacing.lg)
                // Runway under the bottom add bar so the last row is
                // never tucked behind it.
                .padding(.bottom, AppSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColor.background)
            .navigationTitle("Sourdough")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { addBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(AppColor.textPrimary)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if totalFocused {
                        Spacer()
                        Button("Done") { totalFocused = false }
                            .foregroundStyle(appearance.accentColor)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaMascot(size: 44, color: appearance.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Feeding calculator")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Pick how much active starter you want, then a 1 : N : N ratio. Approximate times assume a warm 75–80°F room.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
            Text("Total active starter")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(AppColor.textSecondary)
            HStack(spacing: AppSpacing.sm) {
                TextField("100", text: $totalText)
                    .keyboardType(.decimalPad)
                    .focused($totalFocused)
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                    .monospacedDigit()
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.sm)
                    .background(AppColor.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(AppColor.divider, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .frame(maxWidth: 130)
                Text("g")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColor.textSecondary)
                Spacer()
            }
        }
        .padding(AppSpacing.md)
        .background(
            LinearGradient(
                colors: [AppColor.surfaceRaised, AppColor.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
            Text("Pick a ratio")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(AppColor.textSecondary)

            VStack(spacing: 0) {
                tableHeader
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    if idx > 0 {
                        Rectangle()
                            .fill(AppColor.divider.opacity(0.7))
                            .frame(height: 0.5)
                    }
                    ratioRow(row)
                }
            }
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    private var tableHeader: some View {
        HStack(spacing: AppSpacing.xs) {
            Text("Ratio")
                .frame(width: 56, alignment: .leading)
            Text("Starter")
                .frame(width: 50, alignment: .trailing)
            Text("Water")
                .frame(width: 50, alignment: .trailing)
            Text("Flour")
                .frame(width: 50, alignment: .trailing)
            Text("Time")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .heavy))
        .tracking(0.4)
        .foregroundStyle(AppColor.textTertiary)
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(AppColor.surfaceSunken.opacity(0.5))
    }

    private func ratioRow(_ row: SourdoughCalculator.Row) -> some View {
        let isSelected = row.ratio == selectedRatio
        return Button {
            Haptics.selection()
            selectedRatio = row.ratio
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Text(row.label)
                    .font(.system(size: 14, weight: isSelected ? .heavy : .semibold))
                    .foregroundStyle(isSelected ? appearance.accentColor : AppColor.textPrimary)
                    .frame(width: 56, alignment: .leading)
                Text(SourdoughCalculator.formatGrams(row.starter))
                    .frame(width: 50, alignment: .trailing)
                Text(SourdoughCalculator.formatGrams(row.water))
                    .frame(width: 50, alignment: .trailing)
                Text(SourdoughCalculator.formatGrams(row.flour))
                    .frame(width: 50, alignment: .trailing)
                Text(row.compactTimeRange)
                    .foregroundStyle(isSelected ? appearance.accentColor.opacity(0.85) : AppColor.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(AppColor.textPrimary)
            .monospacedDigit()
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(isSelected ? appearance.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var addBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AppColor.divider).frame(height: 1)
            VStack(spacing: AppSpacing.sm) {
                if let row = selectedRow, total > 0 {
                    Text(summary(for: row))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    guard let row = selectedRow, total > 0 else { return }
                    Haptics.success()
                    onAdd(row)
                    dismiss()
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                        Text("Add to recipe")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(AppColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(appearance.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .opacity(canAdd ? 1 : 0.4)
                }
                .disabled(!canAdd)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background(AppColor.background)
        }
    }

    private func summary(for row: SourdoughCalculator.Row) -> String {
        "Adds \(SourdoughCalculator.formatGrams(row.starter)) starter · \(SourdoughCalculator.formatGrams(row.water)) water · \(SourdoughCalculator.formatGrams(row.flour)) flour. ≈ \(row.timeRange) to peak."
    }
}

#Preview {
    SourdoughCalculatorView { _ in }
        .environment(AppearanceSettings())
}
