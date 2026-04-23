import Foundation

extension Recipe {
    /// Plain-text form suitable for the iOS share sheet → Notes, Messages,
    /// email, etc. Readable without app-specific rendering.
    var exportText: String {
        var lines: [String] = [title, ""]

        var meta: [String] = []
        if let s = servings { meta.append("Serves \(s)") }
        if let c = cookTimeMinutes { meta.append("Cook \(c) min") }
        if !meta.isEmpty {
            lines.append(meta.joined(separator: " · "))
            lines.append("")
        }

        if let summary, !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }

        let sortedIngredients = ingredients.sorted { $0.order < $1.order }
        if !sortedIngredients.isEmpty {
            lines.append("Ingredients")
            for i in sortedIngredients {
                let qty = Quantity.displayFormat(i.quantity)
                let unit = Plural.unit(i.unit ?? "", for: i.quantity)
                let parts = [qty, unit, i.name].filter { !$0.isEmpty }
                lines.append("• " + parts.joined(separator: " "))
            }
            lines.append("")
        }

        let sortedSteps = steps.sorted { $0.order < $1.order }
        if !sortedSteps.isEmpty {
            lines.append("Steps")
            for (idx, s) in sortedSteps.enumerated() {
                lines.append("\(idx + 1). \(s.text)")
            }
            lines.append("")
        }

        if !notes.isEmpty {
            lines.append("Notes")
            lines.append(notes)
            lines.append("")
        }

        if let url = sourceUrl, !url.isEmpty {
            lines.append("Source: \(url)")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
