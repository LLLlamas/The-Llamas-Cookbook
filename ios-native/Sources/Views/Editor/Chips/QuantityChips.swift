import SwiftUI

struct QuantityChips: View {
    @Binding var value: String

    @Environment(AppearanceSettings.self) private var appearance

    private let wholes = ["1", "2", "3", "4", "5", "6", "8", "10", "12"]
    private let fracs = ["1/8", "1/4", "1/3", "1/2", "2/3", "3/4"]

    var body: some View {
        VStack(spacing: 2) {
            row(items: wholes, isWhole: true)
            row(items: fracs, isWhole: false)
        }
    }

    private func row(items: [String], isWhole: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.xs) {
                ForEach(items, id: \.self) { item in
                    let parsed = Quantity.splitForChips(value)
                    let active = !parsed.isFreeform && (isWhole ? parsed.whole == item : parsed.frac == item)

                    Button {
                        Haptics.selection()
                        tap(item, isWhole: isWhole)
                    } label: {
                        Text(item)
                            .font(.system(size: isWhole ? 16 : 14,
                                          weight: isWhole ? .semibold : .medium))
                            .monospacedDigit()
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.xs + 2)
                            .frame(minWidth: isWhole ? 44 : 40)
                            .foregroundStyle(active ? AppColor.onAccent : AppColor.textPrimary)
                            .background(active ? appearance.accentColor : AppColor.surface)
                            .overlay(
                                Capsule().stroke(active ? appearance.accentColor : AppColor.divider, lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.vertical, AppSpacing.xs)
        }
    }

    private func tap(_ item: String, isWhole: Bool) {
        let parsed = Quantity.splitForChips(value)
        if parsed.isFreeform {
            value = item
            return
        }
        if isWhole {
            let next = parsed.whole == item ? nil : item
            value = Quantity.combine(whole: next, frac: parsed.frac)
        } else {
            let next = parsed.frac == item ? nil : item
            value = Quantity.combine(whole: parsed.whole, frac: next)
        }
    }
}
