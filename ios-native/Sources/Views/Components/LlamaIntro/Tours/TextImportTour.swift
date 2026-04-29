import Foundation

/// 5-step tour for `ImportFromTextView`. Adapted from the original
/// 7-step plan to match the post-FAB-split scope of the screen —
/// URL fetch lives in `ImportFromLinkView` now, so the URL/Fetch
/// steps moved to that tour.
///
/// Re-entry is the question-mark icon in the toolbar.
enum TextImportTour {
    static let steps: [LlamaIntroStep] = [
        LlamaIntroStep(
            id: 1,
            target: .textImportHero,
            headline: "Hi, I'm here to help!",
            body: "Paste a recipe in plain text and I'll fill it in for you. Let me show you how.",
            waveOnEnter: true
        ),
        LlamaIntroStep(
            id: 2,
            target: .formatHint,
            headline: "Watch the checklist",
            body: "Title, first ingredient, first step — they light up here when I find them. If something's off, tweak the text below.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 3,
            target: .pasteEditor,
            headline: "Paste plain text",
            body: "Three blocks separated by blank lines: title, ingredients, steps. Bullets and fractions parse automatically.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 4,
            target: .previewButton,
            headline: "Hit Preview",
            body: "I'll show you exactly what I parsed. You can fix anything before saving to your library.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 5,
            target: .textImportHelpIcon,
            headline: "Need a refresher?",
            body: "Tap the question mark anytime to see this walkthrough again.",
            waveOnEnter: false
        )
    ]
}
