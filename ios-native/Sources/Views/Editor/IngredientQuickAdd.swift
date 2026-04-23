import SwiftUI

struct IngredientQuickAdd: View {
    @State private var quantity = ""
    @State private var unit = ""
    @State private var name = ""

    let onAdd: (DraftIngredient) -> Void

    @FocusState private var focused: Field?
    private enum Field { case qty, unit, name }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .bottom, spacing: AppSpacing.sm) {
                field("Qty", placeholder: "2", text: $quantity, keyboard: .decimalPad, flex: 1, focus: .qty)
                field("Unit", placeholder: "cup", text: $unit, keyboard: .default, flex: 1.2, focus: .unit, autocap: false)
                field("Ingredient", placeholder: "flour", text: $name, keyboard: .default, flex: 3, focus: .name) {
                    submit()
                }
            }
            QuantityChips(value: $quantity)
            UnitChips(value: $unit)
        }
    }

    @ViewBuilder
    private func field(_ label: String,
                       placeholder: String,
                       text: Binding<String>,
                       keyboard: UIKeyboardType,
                       flex: CGFloat,
                       focus: Field,
                       autocap: Bool = true,
                       onSubmit: (() -> Void)? = nil) -> some View {
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
                .onSubmit { onSubmit?() }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .frame(minHeight: 44)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .layoutPriority(flex)
    }

    private func submit() {
        let trimmedName = name.trimmed
        guard !trimmedName.isEmpty else {
            if quantity.trimmed.isEmpty && unit.trimmed.isEmpty {
                focused = nil
            } else {
                focused = .name
            }
            return
        }
        Haptics.impact(.light)
        onAdd(DraftIngredient(
            quantity: quantity.trimmed,
            unit: unit.trimmed,
            name: trimmedName
        ))
        quantity = ""
        unit = ""
        name = ""
        focused = .qty
    }
}
