import SwiftUI

struct IngredientRowEditor: View {
    @Binding var ingredient: DraftIngredient
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
                VStack(alignment: .leading, spacing: 2) {
                    if !ingredient.quantity.trimmed.isEmpty {
                        Text(Quantity.displayFormat(ingredient.quantity))
                            .font(AppFont.ingredient)
                            .foregroundStyle(AppColor.textPrimary)
                            .monospacedDigit()
                    }
                    if !ingredient.unit.trimmed.isEmpty {
                        Text(ingredient.unit)
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                }
                .frame(minWidth: 72, alignment: .leading)

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
            .padding(.vertical, AppSpacing.sm + 2)
            .padding(.horizontal, AppSpacing.md)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.plain)
    }

    private var editMode: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .bottom, spacing: AppSpacing.sm) {
                editField(placeholder: "Qty", text: $ingredient.quantity, keyboard: .decimalPad, flex: 1) {
                    isEditing = false
                }
                editField(placeholder: "Unit", text: $ingredient.unit, keyboard: .default, flex: 1.2, autocap: false) {
                    isEditing = false
                }
                editField(placeholder: "Ingredient", text: $ingredient.name, keyboard: .default, flex: 3) {
                    isEditing = false
                }
            }
            QuantityChips(value: $ingredient.quantity)
            UnitChips(value: $ingredient.unit)
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
                           flex: CGFloat,
                           autocap: Bool = true,
                           onSubmit: (() -> Void)? = nil) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocap ? .sentences : .never)
            .autocorrectionDisabled(!autocap)
            .submitLabel(.done)
            .onSubmit { onSubmit?() }
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
            .frame(maxWidth: .infinity)
            .layoutPriority(flex)
    }
}
