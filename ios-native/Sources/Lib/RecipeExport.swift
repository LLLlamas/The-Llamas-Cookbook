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

        let orderedIngredients = sortedIngredients
        if !orderedIngredients.isEmpty {
            lines.append("Ingredients")
            for i in orderedIngredients {
                lines.append("• " + i.display().fullLine)
            }
            lines.append("")
        }

        let orderedSteps = sortedSteps
        if !orderedSteps.isEmpty {
            lines.append("Steps")
            for (idx, s) in orderedSteps.enumerated() {
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
