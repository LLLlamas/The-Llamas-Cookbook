import SwiftUI

struct IngredientQuickAdd: View {
    @State private var quantity = ""
    @State private var unit = ""
    @State private var name = ""
    @State private var errorFields: Set<Field> = []
    @State private var shakeCount: CGFloat = 0

    var numericFocus: FocusState<Bool>.Binding
    let onAdd: (DraftIngredient) -> Void

    @FocusState private var focused: Field?
    enum Field: Hashable { case qty, unit, name }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .bottom, spacing: AppSpacing.sm) {
                field(
                    label: "Qty",
                    placeholder: "2",
                    text: $quantity,
                    keyboard: .decimalPad,
                    focus: .qty
                )
                .frame(width: 84)

                field(
                    label: "Unit",
                    placeholder: "cup",
                    text: $unit,
                    keyboard: .default,
                    focus: .unit,
                    autocap: false
                )
                .frame(width: 96)

                field(
                    label: "Ingredient",
                    placeholder: "flour",
                    text: $name,
                    keyboard: .default,
                    focus: .name,
                    onSubmit: submit
                )
                .frame(maxWidth: .infinity)
            }
            .shake(count: shakeCount)
            QuantityChips(value: $quantity)
            UnitChips(value: $unit)
            Button {
                submit()
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text("Add Ingredient")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(AppColor.accent)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColor.surface)
                .overlay(
                    Capsule().stroke(AppColor.accent, lineWidth: 1)
                )
                .clipShape(Capsule())
            }
            .padding(.top, AppSpacing.xs)
        }
    }

    @ViewBuilder
    private func field(
        label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        focus: Field,
        autocap: Bool = true,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        let isError = errorFields.contains(focus)
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(AppColor.textSecondary)
                .padding(.leading, 2)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocap ? .sentences : .never)
                .autocorrectionDisabled(!autocap)
                .submitLabel(.done)
                .focused($focused, equals: focus)
                .focusedNumeric(numericFocus, when: keyboard == .decimalPad || keyboard == .numberPad)
                .onSubmit { onSubmit?() }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(
                            isError ? AppColor.destructive : AppColor.divider,
                            lineWidth: isError ? 2 : 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .shadow(
                    color: isError ? AppColor.destructive.opacity(0.5) : .clear,
                    radius: isError ? 8 : 0
                )
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .animation(.easeOut(duration: 0.25), value: isError)
        }
    }

    private func submit() {
        var missing: [Field] = []
        if quantity.trimmed.isEmpty { missing.append(.qty) }
        if unit.trimmed.isEmpty { missing.append(.unit) }
        if name.trimmed.isEmpty { missing.append(.name) }

        if !missing.isEmpty {
            flashErrors(missing)
            focused = missing.first
            return
        }

        Haptics.impact(.light)
        onAdd(DraftIngredient(
            quantity: quantity.trimmed,
            unit: unit.trimmed,
            name: name.trimmed
        ))
        quantity = ""
        unit = ""
        name = ""
        focused = .qty
    }

    private func flashErrors(_ fields: [Field]) {
        Haptics.warning()
        errorFields = Set(fields)
        shakeCount += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            errorFields = []
        }
    }
}
