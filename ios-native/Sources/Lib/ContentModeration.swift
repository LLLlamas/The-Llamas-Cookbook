import Foundation

/// Lightweight, offline profanity/slur screen for user-chosen NAMES —
/// recipe titles, grocery-list names, the display name friends see, and
/// custom tags. These are short, world-readable, and rendered on public web
/// pages, so an abusive name reaches other people. The owner's ask: "don't
/// allow bad words for naming."
///
/// **Policy.** BLOCK-at-commit for names (a friendly inline nudge, the user
/// picks something else). Long-form body prose (steps, notes) is
/// deliberately NOT run through this — blocking paragraphs on a single word
/// causes too many false positives; that path is handled with a softer
/// publish-time posture elsewhere.
///
/// **Why a curated in-repo list, not a dependency:** predictable for App
/// Store review, and it lets the Cloudflare Worker (`lib/moderation.js`)
/// mirror the EXACT same vocabulary so server-side checks (the
/// non-bypassable backstop, since the CloudKit public DB is world-writable)
/// stay in lockstep. Keep the two lists identical when editing either.
///
/// **Matching** is deliberately conservative to dodge the Scunthorpe
/// problem: we match whole tokens (and a few evasion-normalized forms),
/// never raw substrings — so "shiitake", "bass", "Scunthorpe", "cumin"
/// pass cleanly while "f.u.c.k", "sh1t", and "fuuuck" do not.
enum ContentModeration {
    enum Result: Equatable {
        case clean
        case blocked(matched: String)
    }

    /// Shown inline when a name is rejected. Friendly, non-accusatory.
    static let blockedMessage = "Let's keep names friendly — please pick another."

    /// `true` when the text carries no blocked term.
    static func isClean(_ text: String) -> Bool {
        if case .clean = check(text) { return true }
        return false
    }

    static func check(_ text: String) -> Result {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return .clean }

        // Three views of the input, each catching a different evasion:
        //  • tokens of the normalized text  → "my <slur> list"
        //  • tokens with runs collapsed     → "fuuuck" → "fuck"
        //  • the whole string, letters only → "f u c k" / "f.u.c.k" → "fuck"
        let candidateTokenSets = [tokens(of: normalized), tokens(of: collapseRuns(normalized))]
        for tokenSet in candidateTokenSets {
            for token in tokenSet where !allowlist.contains(token) {
                if blockedTerms.contains(token) { return .blocked(matched: token) }
            }
        }
        let squashed = String(normalized.filter { $0.isLetter })
        if blockedTerms.contains(squashed), !allowlist.contains(squashed) {
            return .blocked(matched: squashed)
        }
        return .clean
    }

    // MARK: - Normalization

    /// Fold diacritics, lowercase, and de-leet so "Fück" / "sh1t" / "a$$"
    /// reduce to their plain-letter forms before matching.
    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        var out = ""
        out.reserveCapacity(folded.count)
        for ch in folded { out.append(leet[ch] ?? ch) }
        return out
    }

    private static let leet: [Character: Character] = [
        "@": "a", "4": "a", "3": "e", "1": "i", "!": "i",
        "0": "o", "$": "s", "5": "s", "7": "t",
    ]

    private static func tokens(of s: String) -> Set<String> {
        Set(s.split { !$0.isLetter }.map(String.init))
    }

    /// Collapse every run of a repeated character to one, so padded-out
    /// evasions ("fuuuuck") still match. Clean words that collapse to
    /// non-words ("cool" → "col") simply won't be in `blockedTerms`.
    private static func collapseRuns(_ s: String) -> String {
        var out = ""
        var prev: Character?
        for ch in s where ch != prev {
            out.append(ch)
            prev = ch
        }
        return out
    }

    // MARK: - Vocabulary
    //
    // Curated, intentionally NON-exhaustive: clear obscenity + slurs only,
    // biased away from mild words ("damn", "hell") that appear in real
    // recipe names. Keep IN SYNC with cloudflare-pages/lib/moderation.js.
    // Stored as normalized base forms (lowercase, no separators).

    private static let blockedTerms: Set<String> = [
        // Obscenity
        "fuck", "fucker", "fucking", "motherfucker", "fuk", "fuckface",
        "shit", "shitty", "bullshit", "dipshit",
        "bitch", "asshole", "asshat", "dumbass", "jackass",
        "cunt", "dick", "dickhead", "pussy", "bastard", "prick",
        "twat", "wank", "wanker", "slut", "whore", "douchebag",
        "bollocks", "arsehole",
        // Slurs (racial / homophobic / ableist) — represented stems
        "nigger", "nigga", "faggot", "fag", "retard", "tranny",
        "chink", "spic", "kike", "coon", "wetback", "gook",
    ]

    /// Legit culinary / place terms that must never be flagged. With
    /// whole-token matching most of these can't false-positive anyway, but
    /// the allowlist is an explicit safety net + documents the decision.
    private static let allowlist: Set<String> = [
        "shiitake", "shitake", "bass", "seabass", "cumin", "scunthorpe",
        "sussex", "mussel", "cockle", "coq", "hummus", "sake", "dewberry",
    ]
}
