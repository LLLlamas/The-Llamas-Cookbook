# Picture Import Implementation

A third path into the import flow, alongside paste-text and paste-link: the user points the camera at a recipe page (cookbook spread, magazine clipping, handwritten card, printed sheet), the app OCRs it, and the result rides the existing parser pipeline into a read-only preview screen styled like the share-recipient flow.

Last updated 2026-04-29 — incorporates Lorenzo's clarifications on FAB shape, Import-From-Text screen redesign, and the share-style preview screen for photo imports.

## TL;DR

Three changes ship together as one feature:

1. **FAB Menu redesign.** The Library `+` button grows from two entries to four — the existing two get clearer labels and two new entries appear:
   - "Write Down Your Recipe" (was: "New Recipe")
   - "Import From Text" (was: "Import from text")
   - "Import From Link" *(new)*
   - "Import From Photo" *(new)*

2. **Import From Text screen redesign.** `ImportRecipeView` is renamed `ImportFromTextView` and stripped of the link-import section (the link path moves to its own `ImportFromLinkView`, reachable both from the new FAB entry and from the share-extension URL handoff). The pickup-check panel is rewritten so each row asks the user to verify what the parser interpreted — the goal is to catch the "I forgot the blank line and my title got merged into ingredients" failure mode before it reaches the editor.

3. **Import From Photo screen and preview.** New `ImportFromPhotoView` exposes two capture buttons (live document scan via `VNDocumentCameraViewController`; photo library via `PhotosPicker`). After capture, Vision OCR runs each page, the existing `aiParse` best-of pipeline produces a `DraftRecipe`, and the user lands on a new `PhotoImportPreviewView` — formatted exactly like the share-recipient `RecipeImportPreviewView`, with title "Import From Photo", read-only Save/Cancel chrome, and the same duplicate-title rename alert. Save inserts a fresh `Recipe` into SwiftData and navigates to its Detail page (same hand-off pattern the share-recipient flow uses).

**No new SPM/Cocoapods dependencies.** Vision and VisionKit ship in the iOS 18 SDK. Only portal/plist gate is `NSCameraUsageDescription` (camera permission string) — no provisioning-profile churn.

## Why this shape (after Lorenzo's clarifications)

Three of the most common "how do I get this recipe in the app" cases the URL importer can't reach: a paper cookbook on the kitchen counter, a magazine recipe a friend tore out, a handwritten family card from a grandparent. Pasting them by hand is the kind of input friction that kills the flow ("input friction = death" — UX principle 2). OCR collapses 3-5 minutes of typing into a 2-second photo + a 1-second parse.

**Why split write/text/link/photo into four explicit FAB entries** instead of one "Import" entry that branches inside: discoverability. Users don't know what's possible until they see the verbs. Four labelled entries on the FAB advertise the capabilities; collapsing them into one "Import" with internal sub-pickers buries the photo path.

**Why the photo preview mirrors the share-recipient screen** rather than dropping into the editor: the photo path produces a *complete* parsed draft when OCR + AI succeed. Sending the user to the full editor would imply they need to do work; the share-recipient preview screen says "this is what we got, save it or cancel." Same content, less perceived friction. If they want to edit, they save and tap the recipe in Library — which is one tap to the editor. Match the metaphor: imported = preview-and-accept, written = full editor.

**Why the Import-From-Text check panel asks "is this the first ingredient?"** — the existing checkmark-and-content panel only confirmed *that* the parser found something. The new copy makes the user a reviewer, not a passive observer: if they pasted with the title accidentally glued to the first ingredient line, the panel will say `Ingredients - Same day sourdough — is this the first ingredient?` and the user instantly sees the mistake. The bullets/checkmarks were redundant decoration; without them the rows read more naturally.

## Source-layout changes

| New / Modified / Renamed | File | Role |
|---|---|---|
| **Renamed** | `Sources/Views/Library/ImportRecipeView.swift` → `ImportFromTextView.swift` | Pure text-paste import. Link section removed. Check panel redesigned (see §3). |
| **New** | `Sources/Views/Library/ImportFromLinkView.swift` | URL-only import path. Lifts the existing link-fetch block out of `ImportRecipeView` verbatim — same `urlText`, `urlFetchState`, `urlEnrichment`, `URLBanner` plumbing — and presents in its own sheet. Reachable from **both** the new "Import From Link" FAB entry (no prefill) and the share-extension URL handoff (URL prefilled, auto-fetches on appear). Same view, two entry points distinguished by the `prefilledURL: String?` initializer arg. |
| **New** | `Sources/Views/Library/ImportFromPhotoView.swift` | Capture chooser. Two buttons: "Take a Photo" (presents `DocumentScannerView` as a fullScreenCover) and "Choose from Library" (`PhotosPicker`). Runs OCR + AI parse with a `LlamaProgressIndicator` overlay. On success → presents `PhotoImportPreviewView`; on failure → graceful inline message with retry. |
| **New** | `Sources/Views/Library/PhotoImportPreviewView.swift` | Read-only preview of an OCR'd `DraftRecipe`, modeled on `RecipeImportPreviewView`. Toolbar: principal "Import From Photo", Cancel left, Save right. Save calls `Recipe.new(from: draft)` + inserts into `modelContext`; on duplicate-title detection, surfaces the same rename TextField alert pattern the share-recipient view uses. Calls back to a parent with the saved `Recipe` so the parent can navigate to Detail. |
| **New** | `Sources/Lib/RecipeOCRImporter.swift` | Vision wrapper. Takes `[Data]` (one entry per scanned page), returns concatenated, de-hyphenated text. Owns the cooking-vocabulary custom-words list. |
| **New** | `Sources/Views/Components/DocumentScannerView.swift` | `UIViewControllerRepresentable` around `VNDocumentCameraViewController`. Returns `[UIImage]` via callback. |
| **Modified** | `Sources/Lib/RecipeAIParser.swift` | Lift the existing private `aiParse` best-of-LLM-vs-regex helper out of `RecipeURLImporter` and into a new public `RecipeAIParser.parseBestOf(_:sourceUrl:) async -> DraftRecipe?` so both the URL importer and the new OCR importer call one shared helper instead of duplicating the picker. |
| **Modified** | `Sources/Lib/RecipeURLImporter.swift` | `aiParse` becomes a one-line wrapper around `RecipeAIParser.parseBestOf` (or just deleted, with its three call sites pointing directly at the lifted helper). `pickBetterDraft` and `makeRegexDraft` move with it. |
| **Modified** | `Sources/Views/Library/LibraryView.swift` | FAB Menu: four entries with new labels. Order: Write Down → Import From Text → Import From Link → Import From Photo. |
| **Modified** | `Sources/App/EditorCoordinator.swift` | `ActiveSheet` enum gets three new cases: `.importFromText` (no parameters), `.importFromLink(prefilledURL: String?)` (nil from FAB, URL from share extension), `.importFromPhoto`. The old `.importFromText(prefilledURL:)` shape is broken — call sites migrate. New helpers: `startImportFromText()`, `startImportFromLink(url: String? = nil)`, `startImportFromPhoto()`. |
| **Modified** | `Sources/App/RootView.swift` | `EditorSheetHost`'s switch grows three cases. `routeShareExtensionURL` calls `editor.startImportFromLink(url:)` instead of `editor.startImport(prefilledURL:)`. |
| **Modified** | `Resources/AppInfo.plist` | Adds `NSCameraUsageDescription`. |
| **Modified** | `CLAUDE.md` | Capability map entries, Tech Stack OCR row, Architectural Pattern note, CI gotcha for camera permission. |

No `project.yml` changes (Vision and VisionKit are stdlib). No `PrivacyInfo.xcprivacy` changes (Vision text recognition is on-device and not on Apple's Required Reason API list; camera permission is gated by the regular plist key, not the privacy manifest).

## §1 — FAB Menu changes

```swift
// LibraryView.swift, addButton Menu body:
Menu {
    Button {
        Haptics.impact(.light)
        editor.startNew()
    } label: {
        Label("Write Down Your Recipe", systemImage: "square.and.pencil")
    }
    Button {
        Haptics.impact(.light)
        editor.startImportFromText()
    } label: {
        Label("Import From Text", systemImage: "doc.on.clipboard")
    }
    Button {
        Haptics.impact(.light)
        editor.startImportFromLink()
    } label: {
        Label("Import From Link", systemImage: "link")
    }
    Button {
        Haptics.impact(.light)
        editor.startImportFromPhoto()
    } label: {
        Label("Import From Photo", systemImage: "doc.viewfinder")
    }
} label: { /* existing FAB visual */ }
```

EditorCoordinator additions:

```swift
enum ActiveSheet: Identifiable, Hashable {
    case new
    case edit(Recipe)
    case importFromText                        // ← FAB
    case importFromLink(prefilledURL: String?) // ← FAB (nil) OR share extension (URL)
    case importFromPhoto                       // ← FAB

    var id: String {
        switch self {
        case .new:                return "new"
        case .edit(let recipe):   return "edit-\(recipe.id.uuidString)"
        case .importFromText:     return "import-text"
        case .importFromLink:     return "import-link"
        case .importFromPhoto:    return "import-photo"
        }
    }
    /* Equatable / Hashable use id, same pattern as today.
       The associated value on .importFromLink is intentionally
       NOT folded into id, so switching between FAB-no-prefill and
       share-extension-prefilled forms of the same logical sheet
       does NOT trip the dirty-state discard alert. */
}

// Swift enums can't carry default values on associated types, so
// the optional default lives on the helper instead:
func startImportFromText()                   { attemptSwitch(to: .importFromText) }
func startImportFromLink(url: String? = nil) { attemptSwitch(to: .importFromLink(prefilledURL: url)) }
func startImportFromPhoto()                  { attemptSwitch(to: .importFromPhoto) }

// (Old `startImport(prefilledURL:)` is deleted — four call sites
//  migrate: LibraryView's four FAB entries call the corresponding
//  helpers; RootView's routeShareExtensionURL calls
//  startImportFromLink(url: urlString).)
```

`RootView.EditorSheetHost` switch:

```swift
switch sheet {
case .new:                              RecipeEditorView(recipe: nil, onSaved: onClose)
case .edit(let recipe):                 RecipeEditorView(recipe: recipe, onSaved: onClose)
case .importFromText:                   ImportFromTextView()
case .importFromLink(let prefilledURL): ImportFromLinkView(prefilledURL: prefilledURL)
case .importFromPhoto:                  ImportFromPhotoView()
}
```

## §2 — Splitting `ImportRecipeView` into Text + Link

The current `ImportRecipeView` body has three sections stacked: hero row → linkImportSection → pasteImportSection → actionRow. The split is mechanical:

- **Move `linkImportSection` + `urlField` + `fetchButton` + `bannerView` + `bannerTint` + the URL state (`urlText`, `urlFetchState`, `urlBanner`, `urlEnrichment`, `urlFocused`) + the `fetchURL()` async + the `URLBanner`/`URLFetchState` types** → new `ImportFromLinkView.swift`. Keep the `prefilledURL: String?` initializer parameter that drives the `onAppear` auto-fetch (existing logic — already handles nil-vs-set, so it works for both the FAB entry point with no prefill and the share-extension entry with a prefilled URL). The `mergedDraft` helper logic becomes one-shot since there's no paste box to merge with — the URL fetch outcome alone determines the draft.

- **What stays in the renamed `ImportFromTextView`**: `pastedText` state, the paste editor, the redesigned check panel, the placeholder, the action row (paste from clipboard + Preview button), the navigationDestination into RecipeEditorView, the help sheet, the dirty tracking, the keyboard accessory.

- **Hero row** stays in both, with different copy. Text: "Paste a recipe — I'll fill it in for you." Link: "Paste a recipe link — I'll fetch it." Photo: handled separately (see §4).

- **Help sheet**: `ImportHelpView` is shared today and stays shared. Update its copy to cover all four import paths — text, link, photo, and the existing "Write Down Your Recipe" empty-editor entry. The existing "From a link" copy block stays useful (now covers both the FAB entry and the share-extension passthrough). Add a "From a photo" block calling out lighting/framing tips.

The share-extension route in `RootView`:

```swift
// before:
private func routeShareExtensionURL(_ url: URL) {
    /* … extract URL string from base64url … */
    editor.startImport(prefilledURL: urlString)
}

// after:
private func routeShareExtensionURL(_ url: URL) {
    /* … same extraction … */
    editor.startImportFromLink(url: urlString)
}
```

## §3 — Redesigned check panel in `ImportFromTextView`

Three rows. **No bullet/checkmark icons.** Each row is a single horizontal line with a label, an em-dash separator, the parsed value, and a verification prompt for the second and third rows.

| Label | Detail (when content is parsed) | Detail (when nothing parsed) |
|---|---|---|
| Title | `{parsed title}` | `(nothing yet — paste your recipe below)` |
| Ingredients | `{first ingredient text} — is this the first ingredient?` | `(nothing yet)` |
| Steps | `{first step text} — is this the first step for the recipe?` | `(nothing yet)` |

Visual treatment:
- Label (`Title`, `Ingredients`, `Steps`): same eyebrow style as today (`.system(size: 12, weight: .heavy)`, `tracking(0.6)`, `AppColor.textPrimary`).
- The `—` separators are em-dashes in `AppColor.divider` to match how the existing rows visually break label from detail.
- The parsed value (`{first ingredient text}`): `AppColor.textPrimary`, `.system(size: 13, weight: .medium)`. Truncate after 1 line with `.lineLimit(1) .truncationMode(.tail)` so a long step doesn't wrap and break the panel layout.
- The verification prompt (` — is this the first ingredient?`): `AppColor.textTertiary`, italicized, `.system(size: 12, weight: .regular)`. Reads as a question, not an assertion. Drops out completely when the row's value is empty (the `(nothing yet)` placeholder replaces both the value AND the prompt).
- Empty-state placeholder: rendered in `AppColor.textTertiary`, italicized, `.system(size: 12)`. Communicates "this row will populate when you paste below."
- Same `.id(detail)` + `.transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity))` animation the existing rows use, so the value swaps animate smoothly when the user edits the paste box.

The panel container chrome (`AppColor.surface` background, `AppColor.divider` stroke, `AppRadius.md` corner) stays unchanged.

Concretely, the new `checkRow` builder:

```swift
private func textCheckRow(label: String, detail: String?, prompt: String?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs + 2) {
        Text(label)
            .font(.system(size: 12, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(AppColor.textPrimary)

        Text("—")
            .font(.system(size: 11))
            .foregroundStyle(AppColor.divider)

        if let detail, !detail.isEmpty {
            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let prompt {
                Text(prompt)
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(AppColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text("(nothing yet)")
                .font(.system(size: 12))
                .italic()
                .foregroundStyle(AppColor.textTertiary)
        }
        Spacer(minLength: 0)
    }
    .id(detail)
    .transition(
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .leading)),
            removal: .opacity
        )
    )
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detail)
}

// Usage in formatHint:
textCheckRow(
    label: "Title",
    detail: parsed.title.trimmed.isEmpty ? nil : parsed.title.trimmed,
    prompt: nil   // title doesn't need verification — it's just line 1
)
textCheckRow(
    label: "Ingredients",
    detail: formatFirstIngredient(parsed),
    prompt: " — is this the first ingredient?"
)
textCheckRow(
    label: "Steps",
    detail: parsed.steps.first?.text,
    prompt: " — is this the first step for the recipe?"
)
```

The title row deliberately gets *no* verification prompt — there's no ambiguity about which line we picked (it's always line 1). Ingredients and Steps need verification because the section split is the failure-prone bit.

The `Checks` struct still drives the `canPreview` button-enabled state; only the visual rendering changes. Three of any-content gates the Preview button.

## §4 — `ImportFromPhotoView` (capture chooser + OCR runner)

```swift
import SwiftUI
import PhotosUI

struct ImportFromPhotoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance

    @State private var showingScanner = false
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var ocrInProgress = false
    @State private var ocrPageStatus: String?     // "Reading page 2 of 3…"
    @State private var preview: DraftRecipe?      // non-nil drives the preview sheet
    @State private var errorBanner: ErrorBanner?  // empty-text / camera-denied / etc.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                heroRow              // LlamaLogo + "Import a recipe from a photo"
                captureButtons       // Take a Photo / Choose from Library
                if let banner = errorBanner { bannerView(banner) }
                tipRow               // brief copy on lighting / framing
            }
            .padding(AppSpacing.lg)
        }
        .background(AppColor.background)
        .navigationTitle("Import From Photo")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(ocrInProgress)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(ocrInProgress)
            }
        }
        .fullScreenCover(isPresented: $showingScanner) {
            DocumentScannerView(
                onComplete: { images in
                    showingScanner = false
                    Task { await runOCR(on: images) }
                },
                onCancel: { showingScanner = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await runOCRFromPicker(items) }
        }
        .sheet(item: $preview) { draft in
            PhotoImportPreviewView(draft: draft) { /* onSaved: callback to parent */ }
                .environment(appearance)
        }
        .overlay {
            if ocrInProgress {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: AppSpacing.md) {
                        LlamaProgressIndicator(size: 96, accent: appearance.accentColor)
                        Text(ocrPageStatus ?? "Reading your recipe…")
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textPrimary)
                    }
                    .padding(AppSpacing.xl)
                    .background(AppColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                }
            }
        }
    }

    // MARK: capture buttons

    private var captureButtons: some View {
        VStack(spacing: AppSpacing.md) {
            // Primary button — accent fill — for live capture
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showingScanner = true } label: {
                    captureButtonLabel(
                        title: "Take a Photo",
                        subtitle: "Scan a recipe page with your camera",
                        icon: "camera.fill"
                    )
                    .foregroundStyle(AppColor.onAccent)
                    .background(appearance.accentColor)
                }
            }

            // Secondary button — outlined — for picking from library
            PhotosPicker(
                selection: $pickedItems,
                maxSelectionCount: 5,
                matching: .images
            ) {
                captureButtonLabel(
                    title: "Choose from Library",
                    subtitle: "Pick a recipe photo you've already taken",
                    icon: "photo.on.rectangle.angled"
                )
                .foregroundStyle(appearance.accentColor)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(appearance.accentColor, lineWidth: 1)
                )
            }
        }
    }

    /* captureButtonLabel: HStack with icon + text VStack */
    /* heroRow / tipRow / bannerView: standard styled components */

    // MARK: OCR runner

    @MainActor
    private func runOCR(on images: [UIImage]) async {
        ocrInProgress = true
        defer { ocrInProgress = false; ocrPageStatus = nil; pickedItems = [] }

        // 1. Encode each UIImage to Data + run through ImageProcessing
        var prepared: [Data] = []
        for (idx, img) in images.enumerated() {
            ocrPageStatus = "Preparing page \(idx + 1) of \(images.count)…"
            guard let raw = img.jpegData(compressionQuality: 0.95),
                  let resized = await ImageProcessing.prepare(raw, for: .gallery)
            else { continue }
            prepared.append(resized)
        }
        guard !prepared.isEmpty else {
            errorBanner = .ocrEmpty
            return
        }

        // 2. OCR per page
        ocrPageStatus = images.count > 1
            ? "Reading text from \(images.count) pages…"
            : "Reading text…"
        let text = await RecipeOCRImporter.recognize(prepared)
        guard !text.isEmpty else {
            errorBanner = .ocrEmpty
            return
        }

        // 3. AI parse (best-of LLM+regex)
        ocrPageStatus = "Organizing your recipe…"
        let draft = await RecipeAIParser.parseBestOf(text, sourceUrl: nil)

        // 4. Branch: confident draft → preview; partial → fall back through
        //    the text-import flow with the OCR text seeded; empty → error
        if let draft, !draft.title.trimmed.isEmpty,
           !draft.ingredients.isEmpty || !draft.steps.isEmpty {
            preview = draft
        } else {
            // Fall back: route the user to ImportFromTextView with the OCR
            // text pre-loaded so they can clean it up. Implementation
            // option: dismiss this sheet and call
            // editor.startImportFromText(seedText: text) — but that
            // requires extending startImportFromText with a seedText
            // parameter. Alternative: keep the user here, surface a
            // banner explaining the OCR text is still useful, and offer
            // a "Continue in text editor" button that does the handoff.
            errorBanner = .partialOCR(seedText: text)
        }
    }

    private func runOCRFromPicker(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                images.append(img)
            }
        }
        await runOCR(on: images)
    }
}
```

Note the open question on the partial-OCR fallback (also flagged as Q3 below): when OCR succeeds but parse fails, the cleanest UX is to dismiss the photo sheet and re-open the text-import sheet with the OCR text pre-filled. Implementation requires extending `EditorCoordinator.startImportFromText` to accept an optional `seedText`. Alternative is a soft banner that asks the user to retry or switch paths — fewer code changes, slightly worse UX.

## §5 — `PhotoImportPreviewView` (the share-style preview screen)

Modeled directly on `RecipeImportPreviewView`. The single architectural difference: this view consumes a `DraftRecipe` (plain Swift), not an `LCRecipeShareV1` envelope (Codable JSON wrapper). All the sender provenance, base64 photo decoding, and `RecipeShare.materialize` plumbing is irrelevant here — we just persist a fresh `Recipe` from the draft using the existing `Recipe.new(from: draft)` initializer.

```swift
struct PhotoImportPreviewView: View, Identifiable {
    var id = UUID()
    let draft: DraftRecipe
    var onSaved: (Recipe) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppearanceSettings.self) private var appearance

    @State private var isSaving = false
    @State private var showingDuplicateAlert = false
    @State private var duplicateRenameText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    titleBlock        // draft.title + (no provenance line)
                    metaLine          // Serves / Cook from draft
                    if !draft.summary.isEmpty {
                        Text(draft.summary)
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    ingredientsSection  // formatted from draft.ingredients
                    stepsSection        // formatted from draft.steps
                    notesSection        // preface/epilogue/general notes
                    Color.clear.frame(height: AppSpacing.xxl)
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.lg)
            }
            .background(AppColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .tint(appearance.accentColor)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(appearance.accentColor)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .principal) {
                    Text("Import From Photo")
                        .font(AppFont.eyebrow)
                        .foregroundStyle(AppColor.textTertiary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveToLibrary()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                                .foregroundStyle(appearance.accentColor)
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .alert(
            "Recipe already saved",
            isPresented: $showingDuplicateAlert
        ) {
            TextField("Recipe name", text: $duplicateRenameText)
                .textInputAutocapitalization(.words)
            Button("Save") {
                let trimmed = duplicateRenameText.trimmed
                guard !trimmed.isEmpty else { return }
                performSave(withOverrideTitle: trimmed)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You already have a recipe titled \"\(draft.title)\". Save this one with a different name?")
        }
    }

    // MARK: subsections (mostly copies of RecipeImportPreviewView with
    // DraftRecipe types substituted for the LCRecipeShareV1.* types)
    /* titleBlock, metaLine, ingredientsSection, stepsSection,
       notesSection, sectionHeading, formatIngredient, collectedNotes */

    // MARK: save

    private func saveToLibrary() {
        guard !isSaving else { return }
        let baseTitle = draft.title.trimmed

        // Duplicate-title detection. Use the existing
        // `RecipeShare.libraryContainsRecipe(withTitle:in:)` helper —
        // it's not really share-specific, just a SwiftData fetch by
        // title. Keep it where it is, expose if needed.
        if RecipeShare.libraryContainsRecipe(withTitle: baseTitle, in: modelContext) {
            duplicateRenameText = RecipeShare.resolveImportTitle(
                base: baseTitle,
                in: modelContext
            )
            Haptics.warning()
            showingDuplicateAlert = true
            return
        }
        performSave(withOverrideTitle: nil)
    }

    private func performSave(withOverrideTitle overrideTitle: String?) {
        guard !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            // Apply override title onto the draft if needed, then persist.
            var final = draft
            if let overrideTitle, !overrideTitle.isEmpty {
                final.title = overrideTitle
            }
            let recipe = Recipe.new(from: final)
            modelContext.insert(recipe)
            try? modelContext.save()

            isSaving = false
            Haptics.success()
            onSaved(recipe)
            dismiss()
        }
    }
}
```

The two helpers `RecipeShare.libraryContainsRecipe(withTitle:in:)` and `RecipeShare.resolveImportTitle(base:in:)` are reused as-is. They live in the share-handling module today but aren't share-specific — both just touch SwiftData by title. If their type membership feels wrong, lift them to a small `RecipeTitleResolver` enum in `Lib/`; not required for v1.

**Navigation hand-off:** the parent (whichever spawned the photo preview) gets the saved `Recipe` back through `onSaved`. The cleanest place for that is `ImportFromPhotoView.preview`'s `.sheet(item:)` content — when Save fires, the photo preview dismisses, and `ImportFromPhotoView` calls `dismiss()` on itself + posts the recipe up to RootView so the library nav stack pushes Detail. Same `.libraryPath.append(savedRecipe)` pattern the share-recipient flow already uses, with the same ~350ms deferred push to let the dismiss animation finish.

## §6 — `RecipeOCRImporter.swift` (Vision wrapper)

```swift
import Foundation
import Vision
import UIKit

enum RecipeOCRImporter {
    /// Run text recognition on each scanned page in order, concatenate
    /// per-page outputs (newline-joined within page, double-newline
    /// between pages so the block parser sees natural section breaks),
    /// then run cleanup passes (de-hyphenate, strip repeated headers).
    /// Returns "" if Vision returned nothing — caller treats that as
    /// "ask the user to retry."
    static func recognize(_ pages: [Data]) async -> String {
        var perPage: [[String]] = []
        for data in pages {
            perPage.append(await recognizePage(data))
        }
        let cleaned = stripRepeatedHeaders(perPage)
        let concatenated = cleaned
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
        return deHyphenate(concatenated)
    }

    /// Run a single page through `VNRecognizeTextRequest`. Returns the
    /// recognized strings in approximate top-to-bottom reading order
    /// (Vision's bounding-box Y is bottom-up, so we sort descending).
    private static func recognizePage(_ data: Data) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = makeCGImage(from: data) else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = supportedLanguages()
            request.customWords = customWords
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            let observations = request.results ?? []
            let sorted = observations.sorted {
                $0.boundingBox.origin.y > $1.boundingBox.origin.y
            }
            return sorted.compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Locale-aware language list, intersected with what the current
    /// Vision revision actually supports. Always includes "en-US" as
    /// fallback.
    private static func supportedLanguages() -> [String] {
        let candidates: [String] = {
            var langs: [String] = []
            if let code = Locale.current.language.languageCode?.identifier {
                let region = Locale.current.region?.identifier
                let combined = region.map { "\(code)-\($0)" } ?? code
                langs.append(combined)
            }
            langs.append("en-US")
            return Array(NSOrderedSet(array: langs)) as? [String] ?? langs
        }()
        let request = VNRecognizeTextRequest()
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let filtered = candidates.filter { supported.contains($0) }
        return filtered.isEmpty ? ["en-US"] : filtered
    }

    /// Cooking-domain custom-words list. Biases the recognizer toward
    /// canonical units and common cookbook vocabulary so it stops
    /// misreading "tbsp" as "tbsq" and similar.
    private static let customWords: [String] = {
        var words: [String] = []
        // Units — pulled from RecipeImporter's canonical list. If the
        // public visibility there is internal/private, lift the array
        // to a shared constant in Lib/.
        words += [
            "cup","cups","tbsp","tablespoon","tablespoons",
            "tsp","teaspoon","teaspoons","oz","ounce","ounces",
            "lb","lbs","pound","pounds","g","gram","grams","kg",
            "kilogram","kilograms","mg","milligram","milligrams",
            "ml","milliliter","milliliters","l","liter","liters",
            "pint","pints","quart","quarts","gallon","gallons",
            "clove","cloves","pinch","pinches","dash","dashes",
            "slice","slices","piece","pieces","can","cans",
            "stick","sticks","sprig","sprigs","head","heads",
            "bunch","bunches","handful","handfuls",
        ]
        // Common cookbook nouns + verbs
        words += [
            "flour","sugar","butter","salt","pepper","egg","eggs",
            "yeast","starter","sourdough","baking","powder","soda",
            "vanilla","cinnamon","oregano","basil","garlic","onion",
            "olive","oil","milk","cream","yogurt","cheese","stock",
            "broth","water","oven","skillet","saucepan",
        ]
        words += [
            "Preheat","Combine","Knead","Refrigerate","Bake","Roast",
            "Simmer","Boil","Whisk","Stir","Beat","Fold","Pour",
            "Drizzle","Sprinkle","Place","Remove","Cover","Heat",
            "Cool","Toast","Sear","Reduce","Bring","Allow","Cook",
            "Cut","Chop","Slice","Dice","Mince","Brush","Season",
            "Transfer","Roll","Form","Shape","Stretch",
        ]
        return words
    }()

    /// "ingre-\nients" → "ingredients". OCR's most common artifact on
    /// printed cookbook pages, where right-edge hyphenation breaks
    /// across lines. Conservative pattern: lowercase letter, hyphen,
    /// newline, lowercase letter — collapses to the two letters.
    /// Skip cases where the post-newline letter is uppercase (likely a
    /// new sentence) so we don't accidentally fuse step boundaries.
    private static func deHyphenate(_ s: String) -> String {
        s.replacingOccurrences(
            of: #"([a-z])-\n([a-z])"#,
            with: "$1$2",
            options: .regularExpression
        )
    }

    /// Drop short lines that appear identically across multiple pages —
    /// running headers, page numbers, "Chapter 4" decorations. Only
    /// fires for multi-page inputs; single-page scans pass through
    /// unchanged. Threshold: line ≤ 24 chars (chapter titles, page
    /// numbers, recipe name in header) AND appears in ≥ 2 pages.
    private static func stripRepeatedHeaders(_ pages: [[String]]) -> [[String]] {
        guard pages.count >= 2 else { return pages }
        var counts: [String: Int] = [:]
        for page in pages {
            let unique = Set(page.filter { $0.count <= 24 })
            for line in unique {
                counts[line, default: 0] += 1
            }
        }
        let dropSet = Set(counts.filter { $0.value >= 2 }.keys)
        return pages.map { page in page.filter { !dropSet.contains($0) } }
    }
}
```

## §7 — `DocumentScannerView.swift` (UIViewControllerRepresentable)

```swift
import SwiftUI
import VisionKit

/// SwiftUI wrapper for `VNDocumentCameraViewController`. Returns the
/// scanned pages via `onComplete([UIImage])`; cancellation calls
/// `onCancel`. The system camera UI handles its own permission prompt;
/// no need to gate from outside (denial dismisses with onCancel).
struct DocumentScannerView: UIViewControllerRepresentable {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onComplete: @escaping ([UIImage]) -> Void,
             onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var images: [UIImage] = []
            for i in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: i))
            }
            onComplete(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onCancel()
        }
    }
}
```

## §8 — Plist + permissions

`Resources/AppInfo.plist` adds:

```xml
<key>NSCameraUsageDescription</key>
<string>Llamas Cookbook uses the camera to scan recipe pages. The photos stay on your device.</string>
```

App Reviewer wants the *purpose* and the *honest scope*; both are present. Without this string, presenting `VNDocumentCameraViewController` crashes the app with a privacy violation — Apple Reviewer rejects builds in the same state.

No `PrivacyInfo.xcprivacy` change needed. Vision text recognition isn't on the Required Reason API list. The user-defaults reason already declared in `PrivacyInfo.xcprivacy` (CA92.1) and the file-timestamp reason (C617.1) are unaffected.

No `project.yml` change. Vision and VisionKit are both stdlib frameworks; `import Vision` and `import VisionKit` in Swift sources is enough — Xcode auto-links.

No portal capability change. No provisioning profile regeneration. No GitHub Secrets churn.

## §9 — CLAUDE.md updates after merge

Capability-map additions:

```
| Recipe import (text)  | Views/Library/ImportFromTextView.swift + Lib/RecipeImporter.swift | Live "Title / Ingredients / Steps" verification panel; pure text paste, no link section. |
| Recipe import (link)  | Views/Library/ImportFromLinkView.swift + Lib/RecipeURLImporter.swift + Lib/RecipeSchemaParser.swift | URL fetch + JSON-LD/OG parse + AI fallback. Reachable from FAB ("Import From Link") and share-extension URL handoffs. |
| Recipe import (photo) | Views/Library/ImportFromPhotoView.swift + Views/Library/PhotoImportPreviewView.swift + Lib/RecipeOCRImporter.swift + Views/Components/DocumentScannerView.swift | Live VisionKit scan or PhotosPicker → Vision text recognition → existing aiParse pipeline → share-style read-only preview screen with Save/Cancel. On-device only. |
```

Tech-stack table addition:

```
| OCR | Vision (`VNRecognizeTextRequest`) + VisionKit (`VNDocumentCameraViewController`) — both in iOS 18 SDK, on-device |
```

Architectural-pattern note:

```
**OCR is just another text source.** `RecipeOCRImporter.recognize` produces a String; `RecipeAIParser.parseBestOf` (best-of LLM+regex) is the same call the URL flow uses. New input shapes plug in here without touching the parser. The share-style `PhotoImportPreviewView` mirrors `RecipeImportPreviewView`'s read-only preview chrome — same Save/Cancel toolbar, same duplicate-title rename alert — so users get the same accept-or-cancel metaphor for any imported recipe regardless of source (file, URL, or photo).

**Four-way FAB import split.** "Write Down Your Recipe" → empty editor. "Import From Text" → text-only paste. "Import From Link" → URL fetch (also reachable from share-extension URL handoffs via `routeShareExtensionURL` → `editor.startImportFromLink(url:)`). "Import From Photo" → camera + photo library + OCR. Each entry maps to a distinct `EditorCoordinator.ActiveSheet` case so the dirty-state discard alert correctly disambiguates them.
```

CI gotcha:

```
- **`NSCameraUsageDescription`** in `Resources/AppInfo.plist`. Required for `VNDocumentCameraViewController`. Apple Reviewer auto-rejects builds that present a camera UI without a usage description string. The string itself doubles as user-facing copy in the iOS permission prompt — keep it honest about scope ("photos stay on your device").
```

## §10 — Build order (seven small chunks)

Each chunk is individually CI-runnable so a syntactic mistake in chunk 4 doesn't strand 5/6/7. Squash into one PR or land separately — Lorenzo's call.

1. **Lift `aiParse`** from `RecipeURLImporter` into `RecipeAIParser.parseBestOf`. Update the three internal call sites (`fetchHTML`, `fetchPinterest`, `fetchTikTok`) to call the new public helper. No behavior change.
2. **Extend the AI schema** (`ParsedRecipe`) with `servings`, `cookTimeMinutes`, `prepTimeMinutes` fields, plus the cookbook-page worked example in the prompt. **Extend the regex pipeline** with the new header synonyms (Prep:, Bake:, Total time:, Yield:, Makes:) and section synonyms (Preparation, Procedure). Both improvements stand on their own and benefit existing TikTok / Pinterest / blog imports too.
3. **Add `RecipeOCRImporter.swift` + `DocumentScannerView.swift`** with the full text-cleanup pipeline (smart-quote normalize, page-number strip, bullet-glyph normalize, header-on-its-own-line, classic OCR confusion swaps in measurement contexts, multi-space collapse, de-hyphenate, repeated-header strip). Adds the plist permission string. Compile-only validation in CI.
4. **Split `ImportRecipeView.swift`** → rename to `ImportFromTextView.swift`, lift link section into new `ImportFromLinkView.swift`. Update `EditorCoordinator` enum. Update `RootView` switch + share-extension route. Add the four FAB entries. Verify share-extension URL handoff still works.
5. **Redesign the Import From Text check panel** (drop checkmarks, new copy with "is this the first…?" prompts, em-dash separator, italicized prompt text, title row stays bare).
6. **Add `ImportFromPhotoView.swift` + `PhotoImportPreviewView.swift`**. Wire OCR + AI parse → preview → Save → modelContext insert → onSaved navigation hand-off. Implement the partial-OCR fallback as a banner with a "Continue in text editor" button that dismisses the photo sheet and re-opens the text-import sheet with the OCR text pre-loaded (requires `EditorCoordinator.startImportFromText(seedText:)` extension and a corresponding `ImportFromTextView` initializer parameter — see §11.4).
7. **Update CLAUDE.md** + smoke-test on TestFlight.

Steps 1, 2, 3, 4, 5 are independent and can ship serially or as one PR. Step 6 depends on 1, 2, 3, 4. Step 7 depends on all.

## §11 — Failure modes the user can recover from

- **Camera unavailable** (simulator, hypothetical iPad-no-rear-camera): hide "Take a Photo" via `UIImagePickerController.isSourceTypeAvailable(.camera)`. "Choose from Library" stays.
- **Camera permission denied**: `VNDocumentCameraViewController` shows its own native "permission required" message and dismisses; we land back in the Photo Import sheet with no images. Surface a soft inline banner with a "Open Settings" button (`UIApplication.openSettingsURLString`). Don't kill the sheet — user can still pick from library.
- **OCR returns empty text**: error banner "Couldn't read text from the image. Try better lighting or a closer angle, or pick a different photo."
- **OCR returns text but parse fails the quality gate**: surface a banner inside the photo-import sheet ("We pulled the text from your photo but couldn't tell ingredients from steps. Edit it as text?") with a "Continue in text editor" button that dismisses the photo sheet and re-opens the text-import sheet with the OCR text pre-loaded. Implementation: `EditorCoordinator.startImportFromText(seedText: String? = nil)` plus a matching `ImportFromTextView` initializer parameter that pre-populates `pastedText` on appear. The banner-with-button approach (vs. silent auto-swap) keeps the user in control of the screen transition.
- **Multi-page scan, user cancels mid-scan**: scanner returns nothing via `documentCameraViewControllerDidCancel`. Sheet stays on the chooser. Banner: nil.
- **Save fires after the user already inserted a recipe with the same title in another tab/session**: the duplicate-title check at save time catches it; rename alert surfaces.
- **OCR'd handwriting that's too messy for Vision**: lands in the empty-text or quality-gate-fail path. User picks "Choose from Library" with a clearer photo or types it manually via "Write Down Your Recipe."

## §11.5 — Parse-quality work ("do our best to make this work properly")

Photo input is messier than caption input — OCR will produce typos, page-header noise, fused punctuation, and stray glyphs the existing TikTok-tuned parser doesn't expect. To make the photo path **mostly hit the success branch** (auto-jump to preview-and-save) instead of the partial-OCR fallback, this implementation tunes three layers in parallel.

### 11.5.1 — OCR text post-processing (in `RecipeOCRImporter`)

Run all of these passes after Vision returns observations and before handing text to the parser. Order matters — earlier passes prepare the text for later regex matching.

```swift
private static func cleanup(_ raw: String) -> String {
    var s = raw
    s = normalizeSmartQuotes(s)        // ’ → ', “ → ", etc.
    s = normalizeBullets(s)            // ●, ▪, ◦, ▸ → "•", consistent stripping
    s = stripPageNumbers(s)            // lines that are only digits (1-3 chars)
    s = isolateSectionHeaders(s)       // "INGREDIENTS:" fused into next text → newline before
    s = repairMeasurementOCR(s)        // "I/2 cup", "l/2 tsp" → "1/2 cup" (only in qty contexts)
    s = collapseWhitespace(s)          // multi-space runs → single space
    s = deHyphenate(s)                 // "ingre-\nients" → "ingredients" (already in plan)
    return s
}
```

**`normalizeSmartQuotes`**: smart quotes are common in cookbook printing. `’` (U+2019) blocks regex matches that expect `'` (`don't`, possessives). `“` `”` similarly. One-shot replacement.

**`normalizeBullets`**: cookbooks use ●, ▪, ◦, ▸, ▪ as ingredient bullets. Vision recognizes them as text. The existing `stripLeadingBullet` only handles `• - * – —` — extend it OR pre-normalize all bullet glyphs to `•` here.

**`stripPageNumbers`**: lines that are exclusively 1-3 digits, or `Page \d+`, or `\d+ of \d+`. These appear at the top or bottom of cookbook pages. Drop entirely.

**`isolateSectionHeaders`**: when OCR returns `INGREDIENTS 2 cups flour…` as a single line (it happens when the headline is rendered close to the body text), the labeled-format parser fails because it expects `Ingredients` on its own line. Insert a newline after the recognized header word when it's followed by content on the same line:

```swift
let headers = ["INGREDIENTS", "Ingredients", "DIRECTIONS", "Directions",
               "INSTRUCTIONS", "Instructions", "METHOD", "Method",
               "STEPS", "Steps", "PREPARATION", "Preparation",
               "PROCEDURE", "Procedure"]
for h in headers {
    s = s.replacingOccurrences(
        of: #"(?m)^(\#(h))\s*[:.\-]?\s+(?=\S)"#,
        with: "$1\n",
        options: .regularExpression
    )
}
```

**`repairMeasurementOCR`**: OCR commonly mis-reads `1` as `I` or `l` in tight kerning, and `0` as `O`. Naive global swap would corrupt names ("Italian" → "1talian"). Constrain to *measurement contexts only* — character-class `[Il1]` followed by `/[0-9]` followed by space + known unit:

```swift
let unitClass = "(?:cup|cups|tbsp|tsp|oz|lb|g|kg|ml|l|tablespoon|teaspoon)"
s = s.replacingOccurrences(
    of: #"\b[Il]/(\d)\s+(\#(unitClass))\b"#,
    with: "1/$1 $2",
    options: .regularExpression
)
s = s.replacingOccurrences(
    of: #"\b(\d)/[Il]\s+(\#(unitClass))\b"#,
    with: "$1/1 $2",
    options: .regularExpression
)
```

This is intentionally conservative — only fires when the surrounding context proves it's a measurement. Skip the more dangerous "0 ↔ O" swap unless we see real-world miss reports; risk-of-corruption outweighs the benefit on initial build.

**`collapseWhitespace`**: multi-space runs collapse to single space; multiple blank lines between sections collapse to a single blank line so the block-format parser sees clean separators.

### 11.5.2 — Schema and regex extensions (in `RecipeAIParser` + `RecipeImporter`)

**Extend `ParsedRecipe` schema** with three new fields the existing schema lacks:

```swift
@Generable
private struct ParsedRecipe {
    @Guide(description: "The recipe name. Strip @-handles and hashtags.")
    let title: String
    @Guide(description: "Short blurb if any; empty otherwise.")
    let summary: String
    @Guide(description: "Servings count if stated ('Serves 4', 'Yield: 12 cookies'). Empty otherwise.")
    let servings: String                                      // ← new
    @Guide(description: "Total cook/bake minutes if stated. Empty otherwise.")
    let cookTimeMinutes: String                               // ← new
    @Guide(description: "Prep minutes if stated separately from cook time. Empty otherwise.")
    let prepTimeMinutes: String                               // ← new
    @Guide(description: "Each ingredient broken into pieces.")
    let ingredients: [ParsedIngredient]
    @Guide(description: "Cooking steps in order, one action per step.")
    let steps: [ParsedStep]
    /* … */
}
```

The `toDraft(sourceUrl:)` extension lifts these onto the returned `DraftRecipe`. Cookbook pages routinely state these explicitly — capturing them in the AI pass means the user lands on a Save preview that already has the right serving size and bake time.

**Extend `RecipeImporter.applyHeaderField`** with the cookbook-style synonyms regex doesn't currently match:

```swift
// Before: only "Serves:" → servings, "Cook time:" → cookTimeMinutes, "Source:" → sourceUrl
// Add:
//   "Yield:" → servings (numeric prefix; "Yield: 1 loaf" → "1")
//   "Makes:" → servings
//   "Prep:" / "Prep time:" → prepTimeMinutes
//   "Bake:" / "Bake time:" → cookTimeMinutes (synonym)
//   "Total:" / "Total time:" → cookTimeMinutes (synonym)
//   "Active time:" / "Inactive time:" → ignored (too informational)
```

**Extend `RecipeImporter.sectionMatches`** to recognize cookbook-style section headers:

```swift
// Before: ["steps", "instructions", "directions", "method"]
// Add: "preparation", "procedure"
```

These changes benefit *all* import paths, not just the photo path — TikTok and Pinterest captions occasionally use these phrasings too.

### 11.5.3 — AI prompt — second worked example for cookbook input

Append a second worked example to `RecipeAIParser.instructions` showing the cookbook-page shape. Same prompt, two examples — caption *and* cookbook. The model learns from both and routes the right structure for each input shape:

```
Worked example #2 (printed cookbook page, OCR'd):

INPUT:
Classic Banana Bread
Yield: 1 loaf • Prep: 15 min • Bake: 60 min

INGREDIENTS
3 ripe bananas, mashed
1/3 cup melted butter
3/4 cup sugar
1 egg, beaten
1 tsp vanilla extract
1 tsp baking soda
Pinch of salt
1 1/2 cups all-purpose flour

DIRECTIONS
1. Preheat oven to 350°F. Grease a 4x8-inch loaf pan.
2. In a large bowl, mash bananas until smooth.
3. Stir melted butter into bananas. Mix in sugar, egg, and vanilla.
4. Sprinkle baking soda and salt over mixture; mix in.
5. Add flour; mix until just combined.
6. Pour batter into prepared pan. Bake 60 minutes.
7. Cool on rack before slicing.

OUTPUT:
title: "Classic Banana Bread"
summary: ""
servings: "1"
cookTimeMinutes: "60"
prepTimeMinutes: "15"
ingredients:
  - quantity "3", unit "", name "ripe bananas, mashed"
  - quantity "1/3", unit "cup", name "melted butter"
  - quantity "3/4", unit "cup", name "sugar"
  - quantity "1", unit "", name "egg, beaten"
  - quantity "1", unit "tsp", name "vanilla extract"
  - quantity "1", unit "tsp", name "baking soda"
  - quantity "", unit "pinch", name "salt"
  - quantity "1 1/2", unit "cup", name "all-purpose flour"
steps:
  - text "Preheat oven to 350°F", needsTimer false,
    specialNote "Grease a 4x8-inch loaf pan"
  - text "In a large bowl, mash bananas until smooth", needsTimer false, specialNote ""
  - text "Stir melted butter into bananas. Mix in sugar, egg, and vanilla", needsTimer false, specialNote ""
  - text "Sprinkle baking soda and salt over mixture; mix in", needsTimer false, specialNote ""
  - text "Add flour; mix until just combined", needsTimer false, specialNote ""
  - text "Pour batter into prepared pan. Bake 60 minutes", needsTimer true, specialNote ""
  - text "Cool on rack before slicing", needsTimer false, specialNote ""

Notice how "Yield: 1 loaf" became servings "1" (the numeric prefix); "Prep: 15 min"
became prepTimeMinutes "15"; "Bake: 60 min" became cookTimeMinutes "60". Numbered
"1." / "2." prefixes were stripped from each step. The parenthetical-equivalent
"Grease a 4x8-inch loaf pan" stayed grouped with the preheat step as a specialNote
since it's a setup hint, not a separate cooking action.
```

### 11.5.4 — `RecipeOCRImporter.customWords` expansion

The custom-words list in §6 is the right starting point. Expand to include common cookbook publishing vocabulary so Vision biases away from confusable lookalikes:

- Section headers: `INGREDIENTS`, `DIRECTIONS`, `INSTRUCTIONS`, `METHOD`, `PREPARATION`, `PROCEDURE`, `STEPS`
- Time phrases: `minutes`, `hours`, `seconds`, `min`, `hrs`, `°F`, `°C`, `Fahrenheit`, `Celsius`
- Common pan/equipment terms: `skillet`, `saucepan`, `Dutch oven`, `baking sheet`, `parchment`
- Common ingredient-name fragments OCR mis-reads: `paprika`, `cumin`, `turmeric`, `ginger`, `nutmeg`, `cilantro`, `parsley`, `cardamom`

This list won't be exhaustive — keep it focused on words that demonstrably trip Vision's confidence in our test inputs. Adding hundreds of words past a point produces diminishing returns.

### 11.5.5 — Quality-gate threshold

The current quality gate (title + ≥1 ingredient OR ≥1 step) is fine as a minimum, but for the photo path consider raising it to **title + ≥1 ingredient + ≥1 step** to avoid auto-jumping to preview when the parse only got half the recipe. A user who scans a recipe and lands on a preview with only ingredients (or only steps) is more confused than a user who lands on the partial-OCR fallback banner with the full text in the editor.

Option: keep the existing OR gate for URL flow (where partial parses are common from OG-fallback Pinterest pins), tighten to AND gate for OCR flow only:

```swift
// In ImportFromPhotoView.runOCR, after parseBestOf returns a draft:
let hasTitle = !(draft?.title.trimmed.isEmpty ?? true)
let hasIngredients = !(draft?.ingredients.isEmpty ?? true)
let hasSteps = !(draft?.steps.isEmpty ?? true)
let confident = hasTitle && hasIngredients && hasSteps
```

Apply this stricter AND gate to the photo flow's confident-vs-fallback branch.

## §12 — Decisions locked in

Resolved across both rounds of clarification:

- **FAB shape** → four explicit entries with new labels: Write Down Your Recipe / Import From Text / Import From Link / Import From Photo.
- **Multi-page handling** → concatenate top-to-bottom across pages (one recipe spread across pages, not multiple recipes).
- **Auto-attach scans as gallery photos** → not in v1. No-attach default.
- **Partial-OCR fallback** → banner with "Continue in text editor" button that dismisses photo sheet and re-opens text-import sheet with OCR text pre-loaded. Requires `EditorCoordinator.startImportFromText(seedText:)` extension.
- **Handwriting** → no separate mode; same path as printed.
- **Languages** → locale + English fallback; no settings toggle.
- **Lift `aiParse`** → yes, lifting to `RecipeAIParser.parseBestOf`.
- **Title-row verification copy** → leave Title bare. Only Ingredients and Steps get the "is this the first…?" prompt.
- **Parse-quality investment** → see §11.5. OCR text cleanup, AI schema extension with servings/cook/prep, AI prompt second-example for cookbook shape, regex header-synonym extension, customWords expansion, optional stricter quality gate for the photo flow.

## §13 — Status

All decisions locked. This doc is hand-off ready for code.
