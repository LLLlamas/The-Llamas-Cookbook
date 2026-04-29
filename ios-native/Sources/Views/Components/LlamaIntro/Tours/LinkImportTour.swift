import Foundation

/// 4-step tour for `ImportFromLinkView`. Pulled out of the original
/// 7-step Import tour after the FAB split — this one focuses on
/// the URL fetch path; the paste-text path lives in `TextImportTour`.
///
/// Re-entry is the question-mark icon in the toolbar.
enum LinkImportTour {
    static let steps: [LlamaIntroStep] = [
        LlamaIntroStep(
            id: 1,
            target: .linkImportHero,
            headline: "Hi, I'm here to help!",
            body: "Paste a recipe link and I'll fetch what I can. Let me show you the flow.",
            waveOnEnter: true
        ),
        LlamaIntroStep(
            id: 2,
            target: .urlField,
            headline: "Paste a recipe link",
            body: "Blog URLs, Pinterest pins, TikTok captions — I'll pull what I can. IG and FB block previews; for those, paste the caption on the From Text screen instead.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 3,
            target: .fetchButton,
            headline: "Tap Fetch",
            body: "I'll grab the title, ingredients, steps, and times. You can edit anything I get wrong before saving.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 4,
            target: .linkImportHelpIcon,
            headline: "Need a refresher?",
            body: "Tap the question mark anytime to see this walkthrough again.",
            waveOnEnter: false
        )
    ]
}
