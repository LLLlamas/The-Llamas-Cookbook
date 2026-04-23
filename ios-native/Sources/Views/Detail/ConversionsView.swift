import SwiftUI
import UIKit

struct ConversionsView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var calcFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.lg) {
                    header
                    ConversionCalculator(focused: $calcFocused)
                    ForEach(Conversions.sections) { section in
                        sectionCard(section)
                    }
                }
                .padding(AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(AppColor.background)
            .navigationTitle("Conversions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppColor.accent)
                        .font(.system(size: 16, weight: .semibold))
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if calcFocused {
                        Spacer()
                        Button("Done") { calcFocused = false }
                            .foregroundStyle(AppColor.accent)
                            .font(.system(size: 16, weight: .semibold))
                    }
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

// MARK: - Live calculator

private struct ConversionCalculator: View {
    var focused: FocusState<Bool>.Binding

    @State private var inputText: String = "1"
    @State private var fromUnit: ConvertibleUnit = .cup
    @State private var toUnit: ConvertibleUnit = .ml

    private var inputValue: Double? {
        let cleaned = inputText
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    private var convertedValue: Double? {
        guard let v = inputValue else { return nil }
        return ConversionEngine.convert(v, from: fromUnit, to: toUnit)
    }

    private var crossCategoryNote: String? {
        guard fromUnit.category != toUnit.category else { return nil }
        return "Having trouble with this one — \(fromUnit.category.rawValue) and \(toUnit.category.rawValue) don't convert directly without an ingredient. Try Common Ingredients below."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Calculator").eyebrowStyle()

            HStack(alignment: .center, spacing: AppSpacing.sm) {
                inputCard
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppColor.accent)
                outputCard
            }

            if let note = crossCategoryNote {
                HStack(alignment: .top, spacing: AppSpacing.xs + 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.destructive.opacity(0.85))
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(AppColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, AppSpacing.xs)
            }
        }
        .padding(AppSpacing.md)
        .background(
            LinearGradient(
                colors: [AppColor.surfaceRaised, AppColor.surface],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: AppColor.shadowSoft, radius: 4, x: 0, y: 1)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            TextField("1", text: $inputText)
                .keyboardType(.decimalPad)
                .focused(focused)
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(AppColor.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            unitMenu(selection: $fromUnit)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.background)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(convertedValue.map(formatNumber) ?? "—")
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(convertedValue == nil ? AppColor.textTertiary : AppColor.accentDeep)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy, value: convertedValue)
            unitMenu(selection: $toUnit)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func unitMenu(selection: Binding<ConvertibleUnit>) -> some View {
        Menu {
            menuSection(title: "Volume", category: .volume, selection: selection)
            menuSection(title: "Weight", category: .weight, selection: selection)
            menuSection(title: "Temperature", category: .temperature, selection: selection)
        } label: {
            HStack(spacing: 4) {
                Text(selection.wrappedValue.label)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(AppColor.accent)
            .padding(.horizontal, AppSpacing.sm + 2)
            .padding(.vertical, 4)
            .background(AppColor.accentSoft.opacity(0.6))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func menuSection(title: String, category: ConvertibleUnit.Category, selection: Binding<ConvertibleUnit>) -> some View {
        Section(title) {
            ForEach(ConvertibleUnit.allCases.filter { $0.category == category }) { u in
                Button {
                    Haptics.selection()
                    selection.wrappedValue = u
                } label: {
                    HStack {
                        Text(u.label)
                        if selection.wrappedValue == u {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    private func formatNumber(_ v: Double) -> String {
        if abs(v) >= 1000 { return String(format: "%.0f", v) }
        if abs(v) >= 100 { return String(format: "%.1f", v) }
        if abs(v) >= 10 { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
            .trimmingTrailingZeroes()
    }
}

private extension String {
    func trimmingTrailingZeroes() -> String {
        guard contains(".") else { return self }
        var s = self
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
