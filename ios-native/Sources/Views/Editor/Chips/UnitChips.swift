import SwiftUI

struct UnitChips: View {
    @Binding var value: String

    private let units = [
        "cup", "tbsp", "tsp", "oz", "lb",
        "g", "kg", "ml", "l",
        "piece", "clove", "pinch", "slice", "can", "stick"
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.xs) {
                ForEach(units, id: \.self) { unit in
                    let active = value.trimmed.lowercased() == unit
                    Button {
                        Haptics.selection()
                        value = active ? "" : unit
                    } label: {
                        Text(unit)
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.xs + 2)
                            .foregroundStyle(active ? AppColor.onAccent : AppColor.textPrimary)
                            .background(active ? AppColor.accent : AppColor.surface)
                            .overlay(
                                Capsule().stroke(active ? AppColor.accent : AppColor.divider, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.vertical, AppSpacing.xs)
        }
    }
}
