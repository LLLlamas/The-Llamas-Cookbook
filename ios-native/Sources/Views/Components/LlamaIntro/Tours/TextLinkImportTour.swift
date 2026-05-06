import Foundation

/// 6-step tour for `ImportFromTextLinkView`. Replaces the separate
/// text-only and link-only tours after the FAB merged the two paths
/// into one sheet. Re-entry is the question-mark icon in the toolbar.
enum TextLinkImportTour {
    static let steps: [LlamaIntroStep] = [
        LlamaIntroStep(
            id: 1,
            target: .textLinkImportHero,
            headline: "Hi, I'm Here to Help!",
            body: "Two ways to import: paste a recipe link, or paste plain text. Use whichever you have.",
            waveOnEnter: true
        ),
        LlamaIntroStep(
            id: 2,
            target: .urlField,
            headline: "Paste a Recipe Link",
            body: "Blog URLs, Pinterest pins, TikTok captions — I'll pull what I can. IG and FB block previews; for those, paste the caption in the text box below.",
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
            target: .formatHint,
            headline: "Watch the Checklist",
            body: "Title, first ingredient, first step — they light up here when I find them. If something's off, tweak the text below.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 5,
            target: .pasteEditor,
            headline: "Paste Plain Text",
            body: "Three blocks separated by blank lines: title, ingredients, steps. Bullets and fractions parse automatically.",
            waveOnEnter: false
        ),
        LlamaIntroStep(
            id: 6,
            target: .previewButton,
            headline: "Hit Preview",
            body: "I'll show you exactly what I parsed. You can fix anything before saving to your library.",
            waveOnEnter: false
        )
    ]
}
