import Foundation

/// Static cooking-conversion reference. Standard kitchen equivalents — these
/// don't change. Exposed as a list of sections for the Conversions sheet.
enum Conversions {
    struct Row: Identifiable {
        let id = UUID()
        let lhs: String
        let rhs: String
        let note: String?
        init(_ lhs: String, _ rhs: String, note: String? = nil) {
            self.lhs = lhs
            self.rhs = rhs
            self.note = note
        }
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let rows: [Row]
    }

    static let sections: [Section] = [
        Section(
            id: "volume-us",
            title: "Volume (US)",
            subtitle: "Spoons & cups",
            rows: [
                Row("3 tsp", "1 tbsp"),
                Row("2 tbsp", "1 fl oz"),
                Row("4 tbsp", "1/4 cup", note: "2 fl oz"),
                Row("5 tbsp + 1 tsp", "1/3 cup"),
                Row("8 tbsp", "1/2 cup", note: "4 fl oz"),
                Row("12 tbsp", "3/4 cup", note: "6 fl oz"),
                Row("16 tbsp", "1 cup", note: "8 fl oz"),
                Row("2 cups", "1 pint", note: "16 fl oz"),
                Row("2 pints", "1 quart", note: "32 fl oz"),
                Row("4 quarts", "1 gallon", note: "128 fl oz"),
            ]
        ),
        Section(
            id: "volume-metric",
            title: "US → Metric Volume",
            subtitle: "Round numbers — bake by weight when precision matters",
            rows: [
                Row("1 tsp", "5 ml"),
                Row("1 tbsp", "15 ml"),
                Row("1 fl oz", "30 ml"),
                Row("1/4 cup", "60 ml"),
                Row("1/3 cup", "80 ml"),
                Row("1/2 cup", "120 ml"),
                Row("1 cup", "240 ml"),
                Row("1 pint", "475 ml"),
                Row("1 quart", "950 ml", note: "≈ 1 liter"),
                Row("1 gallon", "3.8 liters"),
            ]
        ),
        Section(
            id: "weight",
            title: "Weight",
            subtitle: nil,
            rows: [
                Row("1 oz", "28 g"),
                Row("4 oz", "113 g", note: "1/4 lb"),
                Row("8 oz", "227 g", note: "1/2 lb"),
                Row("16 oz", "454 g", note: "1 lb"),
                Row("1 kg", "2.2 lb"),
            ]
        ),
        Section(
            id: "butter",
            title: "Butter",
            subtitle: "Stick math — comes up constantly",
            rows: [
                Row("1 stick", "1/2 cup", note: "8 tbsp · 4 oz · 113 g"),
                Row("2 sticks", "1 cup", note: "8 oz · 227 g"),
                Row("1 tbsp butter", "14 g"),
            ]
        ),
        Section(
            id: "ingredients",
            title: "Common Ingredients",
            subtitle: "Approximate weights — useful when scaling",
            rows: [
                Row("1 cup all-purpose flour", "125 g", note: "≈ 4.5 oz"),
                Row("1 cup granulated sugar", "200 g", note: "≈ 7 oz"),
                Row("1 cup brown sugar (packed)", "220 g"),
                Row("1 cup powdered sugar", "120 g"),
                Row("1 cup rolled oats", "90 g"),
                Row("1 cup rice (raw)", "200 g"),
                Row("1 cup milk", "240 ml", note: "8 fl oz"),
                Row("1 cup honey", "340 g"),
                Row("1 large egg", "≈ 50 g", note: "≈ 3 tbsp liquid"),
                Row("1 medium lemon", "≈ 3 tbsp juice", note: "1 tbsp zest"),
                Row("1 medium lime", "≈ 2 tbsp juice"),
                Row("1 garlic clove", "≈ 1 tsp minced"),
            ]
        ),
        Section(
            id: "oven",
            title: "Oven Temperatures",
            subtitle: "Fahrenheit · Celsius · Gas Mark",
            rows: [
                Row("250 °F", "120 °C", note: "Gas 1/2 — very low"),
                Row("275 °F", "135 °C", note: "Gas 1"),
                Row("300 °F", "150 °C", note: "Gas 2 — low"),
                Row("325 °F", "165 °C", note: "Gas 3 — warm"),
                Row("350 °F", "175 °C", note: "Gas 4 — moderate"),
                Row("375 °F", "190 °C", note: "Gas 5"),
                Row("400 °F", "205 °C", note: "Gas 6 — moderately hot"),
                Row("425 °F", "220 °C", note: "Gas 7 — hot"),
                Row("450 °F", "230 °C", note: "Gas 8"),
                Row("475 °F", "245 °C", note: "Gas 9 — very hot"),
            ]
        ),
    ]
}
