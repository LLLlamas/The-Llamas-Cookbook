import Foundation

extension Recipe {
    /// Plain-text form suitable for the iOS share sheet → Notes, Messages,
    /// email, etc. Readable without app-specific rendering.
    ///
    /// Notes are surfaced as italic-style text in-app via the
    /// `noteCallout` views, but plain text has no styling — we prefix
    /// each note with `Note:` so the share-sheet output reads
    /// unambiguously when round-tripped through Notes / Messages.
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

        if let preface = prefaceNote.trimmedIfNonEmpty {
            lines.append("Note: \(preface)")
            lines.append("")
        }

        let orderedSteps = sortedSteps
        if !orderedSteps.isEmpty {
            lines.append("Steps")
            for (idx, s) in orderedSteps.enumerated() {
                lines.append("\(idx + 1). \(s.text)")
                // Per-step special note rides indented under the step
                // it belongs to so the structure stays obvious in
                // plain text.
                if let stepNote = s.specialNote.trimmedIfNonEmpty {
                    lines.append("   Note: \(stepNote)")
                }
            }
            lines.append("")
        }

        if let epilogue = epilogueNote.trimmedIfNonEmpty {
            lines.append("Note: \(epilogue)")
            lines.append("")
        }

        if let general = generalNote.trimmedIfNonEmpty {
            lines.append("Note: \(general)")
            lines.append("")
        }

        if let url = sourceUrl, !url.isEmpty {
            lines.append("Source: \(url)")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
