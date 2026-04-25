import SwiftUI

struct IngredientRowEditor: View {
    @Binding var ingredient: DraftIngredient
    var numericFocus: FocusState<Bool>.Binding
    let onDelete: () -> Void

    @State private var isEditing = false

    var body: some View {
        if isEditing {
            editMode
        } else {
            viewMode
        }
    }

    private var viewMode: some View {
        Button {
            Haptics.selection()
            isEditing = true
        } label: {
            HStack(spacing: AppSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if !ingredient.quantity.trimmed.isEmpty {
                        Text(Quantity.displayFormat(ingredient.quantity))
                            .font(AppFont.ingredient)
                            .foregroundStyle(AppColor.textPrimary)
                            .monospacedDigit()
                    }
                    if !ingredient.unit.trimmed.isEmpty {
                        Text(Plural.unit(ingredient.unit, for: ingredient.quantity))
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                }
                .frame(minWidth: 96, alignment: .leading)

                Text(ingredient.name)
                    .font(AppFont.ingredient)
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Haptics.impact(.light)
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(AppSpacing.xs)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, AppSpacing.md)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .shadow(color: AppColor.shadowSoft, radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var editMode: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .bottom, spacing: AppSpacing.sm) {
                editField(placeholder: "Qty", text: $ingredient.quantity, keyboard: .decimalPad)
                    .frame(width: 84)
                editField(placeholder: "Unit", text: $ingredient.unit, keyboard: .default, autocap: false)
                    .frame(width: 96)
                editField(placeholder: "Ingredient", text: $ingredient.name, keyboard: .default) {
                    isEditing = false
                }
                .frame(maxWidth: .infinity)
            }
            QuantityChips(value: $ingredient.quantity)
            UnitChips(value: $ingredient.unit)
            HStack {
                Spacer()
                Button {
                    Haptics.selection()
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                    isEditing = false
                } label: {
                    Text("Done")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColor.onAccent)
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.sm)
                        .background(AppColor.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, AppSpacing.xs)
        }
        .padding(AppSpacing.sm)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.accent, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    @ViewBuilder
    private func editField(placeholder: String,
                           text: Binding<String>,
                           keyboard: UIKeyboardType,
                           autocap: Bool = true,
                           onSubmit: (() -> Void)? = nil) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocap ? .sentences : .never)
            .autocorrectionDisabled(!autocap)
            .submitLabel(.done)
            .onSubmit { onSubmit?() }
            .focusedNumeric(numericFocus, when: keyboard == .decimalPad || keyboard == .numberPad)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .frame(minHeight: 44)
            .background(AppColor.background)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            .font(AppFont.body)
            .foregroundStyle(AppColor.textPrimary)
    }
}
