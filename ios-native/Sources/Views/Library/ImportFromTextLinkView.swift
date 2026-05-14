import SwiftUI
import SwiftData
import UIKit

/// Merged text-paste + URL-fetch import path. A single sheet with
/// two affordances:
///   • A URL field at the top for "Paste a recipe link".
///   • Below it, a freeform paste area for raw recipe text.
///
/// Routing rules when the user taps Preview:
///   • Link filled, text empty → URL fetch path (`RecipeURLImporter`).
///   • Text filled, link empty → text parse path (`RecipeImporter` +
///     `RecipeAIParser`).
///   • Both filled → link wins (cleanest signal; if the user pasted a
///     URL inside the text body, we also auto-route to link).
///
/// `seedText` carries OCR fallback text. `prefilledURL`
/// carries the share-extension URL handoff. Both seeds set
/// pastedText / urlText on appear and (for the URL case) auto-fetch
/// so the user lands on the parsed preview.
struct ImportFromTextLinkView: View {
    /// OCR-derived text seed from the photo import partial-fallback
    /// path. When non-nil, populates the paste area on appear so the
    /// user lands on a pre-filled box ready to clean up. Nil for the
    /// plain "Import From Text/Link" entry from the Library FAB.
    let seedText: String?

    /// URL string from the share-extension URL handoff (Safari /
    /// Reddit / blog reader). When non-nil, populates the URL field
    /// and kicks off the fetch on appear so the user lands on the
    /// parsed preview instead of an empty form.
    let prefilledURL: String?

    /// Called by the inner `RecipeEditorView` after a successful Save
    /// with the freshly-persisted `Recipe`. RootView dismisses the
    /// editor sheet and pushes Detail. Defaults to a no-op.
    var onSaved: (Recipe) -> Void = { _ in }

    init(
        seedText: String? = nil,
        prefilledURL: String? = nil,
        onSaved: @escaping (Recipe) -> Void = { _ in }
    ) {
        self.seedText = seedText
        self.prefilledURL = prefilledURL
        self.onSaved = onSaved
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance

    @State private var urlText = ""
    @State private var pastedText = ""
    @State private var urlFetchState: URLFetchState = .idle
    @State private var banner: ImportBanner?
    @State private var parsedDraft: DraftRecipe?
    @State private var showEditor = false
    @State private var showTour = false
    @State private var urlFieldEdited = false
    @State private var textFieldEdited = false
    @State private var previewJiggleCount = 0
    @State private var pendingDraft: DraftRecipe? = nil
    @State private var showDuplicateAlert = false
    @State private var duplicateSuggestedTitle = ""
    @FocusState private var urlFocused: Bool
    @FocusState private var pasteFocused: Bool
    @AppStorage("hasSeenImportHelp") private var hasSeenImportHelp = false
    @AppStorage("hasSeenTextLinkImportTour") private var hasSeenTextLinkImportTour = false

    var body: some View {
        let parsedFromText = RecipeImporter.parse(pastedText)
        let canPreview = computeCanPreview(parsedFromText: parsedFromText)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    heroRow
                        .padding(.top, AppSpacing.md)
                        .tourTarget(.textLinkImportHero)

                    linkSection
                        .opacity(textFieldEdited ? 0.45 : 1.0)
                        .animation(.easeInOut(duration: 0.3), value: textFieldEdited)

                    pasteSection(parsed: parsedFromText)
                        .opacity(urlFieldEdited ? 0.45 : 1.0)
                        .animation(.easeInOut(duration: 0.3), value: urlFieldEdited)

                    actionRow(canPreview: canPreview)

                    Color.clear.frame(height: 32)
                }
                .padding(AppSpacing.lg)
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboards() }
            }
            .scrollDismissesKeyboard(.never)
            .onChange(of: pasteFocused) { _, focused in
                if focused {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        proxy.scrollTo(LlamaTourTarget.pasteEditor, anchor: .bottom)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text("Cancel")
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.selection()
                        showTour = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                    }
                    .accessibilityLabel("Replay walkthrough")
                    .tourTarget(.textLinkImportHelpIcon)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        Haptics.selection()
                        dismissKeyboards()
                    } label: {
                        Text("Done")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(appearance.accentColor)
                            .accentTextOutline()
                    }
                }
            }
            .navigationDestination(isPresented: $showEditor) {
                if let draft = parsedDraft {
                    RecipeEditorView(recipe: nil, initialDraft: draft) { savedRecipe in
                        onSaved(savedRecipe)
                    }
                }
            }
            .onAppear {
                if hasSeenImportHelp && !hasSeenTextLinkImportTour {
                    hasSeenTextLinkImportTour = true
                }

                // Share-extension URL handoff — auto-fetch on appear.
                if let prefill = prefilledURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !prefill.isEmpty,
                   urlText.isEmpty {
                    urlText = prefill
                    hasSeenTextLinkImportTour = true
                    Task { await fetchURL() }
                }
                // OCR fallback seed — pre-fill the paste area.
                if let seed = seedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !seed.isEmpty,
                   pastedText.isEmpty {
                    pastedText = seed
                    hasSeenTextLinkImportTour = true
                } else if prefilledURL == nil && !hasSeenTextLinkImportTour {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        showTour = true
                    }
                }
                updateDirty()
            }
            .onChange(of: pastedText) { _, new in
                updateDirty()
                if pasteFocused && !new.trimmed.isEmpty {
                    textFieldEdited = true
                }
                if new.trimmed.isEmpty {
                    textFieldEdited = false
                }
            }
            .onChange(of: urlText) { _, new in
                updateDirty()
                if urlFocused && !new.trimmed.isEmpty {
                    urlFieldEdited = true
                }
                if new.trimmed.isEmpty {
                    urlFieldEdited = false
                }
            }
            .onChange(of: urlFieldEdited) { old, new in
                if new && !old { previewJiggleCount += 1 }
            }
            .onDisappear {
                editor.hasUnsavedChanges = false
            }
            .alert("Already in Your Cookbook", isPresented: $showDuplicateAlert, presenting: pendingDraft) { draft in
                Button("Cancel", role: .cancel) {
                    pendingDraft = nil
                }
                Button("Save as \"\(duplicateSuggestedTitle)\"") {
                    var updated = draft
                    updated.title = duplicateSuggestedTitle
                    parsedDraft = updated
                    pendingDraft = nil
                    showEditor = true
                }
            } message: { draft in
                Text("\"\(draft.title.trimmed)\" is already in your cookbook.")
            }
            .overlayPreferenceValue(LlamaTourTargetKey.self) { anchors in
                if showTour {
                    LlamaIntroOverlay(
                        steps: TextLinkImportTour.steps,
                        anchors: anchors,
                        scrollProxy: proxy,
                        onFinish: {
                            showTour = false
                            hasSeenTextLinkImportTour = true
                        }
                    )
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: showTour)
                }
            }
        }
        .llamaBackground()
        .navigationTitle("Import From Text/Link")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(true)
        .tint(appearance.accentColor)
    }

    // MARK: - Subviews

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaLogo(size: 72, shadowColor: appearance.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from text or a link")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Paste a link, or paste plain text — I'll fill it in.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("From a link").eyebrowStyle()

            HStack(spacing: AppSpacing.sm) {
                urlField.tourTarget(.urlField)
                fetchButton.tourTarget(.fetchButton)
            }

            if let banner {
                bannerView(banner)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: banner)
    }

    private var urlField: some View {
        HStack(spacing: AppSpacing.xs) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
            TextField("Paste a recipe link…", text: $urlText)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .focused($urlFocused)
                .onSubmit {
                    Task { await fetchURL() }
                }
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
            if !urlText.isEmpty && urlFetchState != .fetching {
                Button {
                    urlText = ""
                    banner = nil
                    parsedDraft = nil
                    Haptics.selection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AppColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm + 2)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var fetchButton: some View {
        Button {
            Task { await fetchURL() }
        } label: {
            Group {
                if urlFetchState == .fetching {
                    ProgressView()
                        .tint(AppColor.onAccent)
                } else {
                    Text("Fetch")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppColor.onAccent)
                }
            }
            .frame(width: 76, height: 44)
            .background(appearance.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .opacity(canFetch ? 1 : 0.4)
        }
        .disabled(!canFetch)
    }

    private func pasteSection(parsed: DraftRecipe) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Or from text").eyebrowStyle()

            formatHint(parsed: parsed)
                .tourTarget(.formatHint)

            firstLineHint

            ZStack(alignment: .topLeading) {
                TextEditor(text: $pastedText)
                    .focused($pasteFocused)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(AppSpacing.sm)

                if pastedText.isEmpty {
                    placeholderView
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 240)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(pasteFocused ? appearance.accentColor.opacity(0.6) : AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .animation(.easeInOut(duration: 0.15), value: pasteFocused)
            .tourTarget(.pasteEditor)
        }
    }

    private var firstLineHint: some View {
        HStack(alignment: .top, spacing: AppSpacing.xs + 2) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 1)
            Text("First line is your recipe title — leave a blank space before the first ingredient or type 'Ingredient' above the first ingredient, same goes for 'Steps' and we'll handle the rest!")
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AppColor.textTertiary)
    }

    private var placeholderView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Recipe Title")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textTertiary)

            placeholderDivider

            VStack(alignment: .leading, spacing: 2) {
                Text("2 cups flour")
                Text("1 cup sugar")
                Text("3 eggs")
            }
            .font(AppFont.body)
            .foregroundStyle(AppColor.textTertiary.opacity(0.7))

            placeholderDivider

            VStack(alignment: .leading, spacing: 2) {
                Text("Mix dry ingredients")
                Text("Cream butter and sugar")
                Text("Bake 350° for 12 min")
            }
            .font(AppFont.body)
            .foregroundStyle(AppColor.textTertiary.opacity(0.7))
        }
        .padding(AppSpacing.md)
    }

    private var placeholderDivider: some View {
        Rectangle()
            .fill(AppColor.divider.opacity(0.55))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private func formatHint(parsed: DraftRecipe) -> some View {
        let titleDetail = parsed.title.trimmed.isEmpty ? nil : parsed.title.trimmed
        let firstIngredient = formatFirstIngredient(parsed)
        let firstStep = parsed.steps.first?.text

        return VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
            textCheckRow(
                label: "Title",
                detail: titleDetail,
                prompt: nil,
                emptyPlaceholder: "(nothing yet — paste your recipe below)"
            )
            textCheckRow(
                label: "Ingredients",
                detail: firstIngredient,
                prompt: " — is this the first ingredient?",
                emptyPlaceholder: "(nothing yet)"
            )
            textCheckRow(
                label: "Steps",
                detail: firstStep,
                prompt: " — is this the first step for the recipe?",
                emptyPlaceholder: "(nothing yet)"
            )
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func textCheckRow(
        label: String,
        detail: String?,
        prompt: String?,
        emptyPlaceholder: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs + 2) {
            Text(label)
                .font(.system(size: 12, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(AppColor.textPrimary)

            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(AppColor.divider)

            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs + 2) {
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
                    Text(emptyPlaceholder)
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
            .id(detail ?? "")
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .leading)),
                    removal: .opacity
                )
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detail)

            Spacer(minLength: 0)
        }
    }

    private func formatFirstIngredient(_ parsed: DraftRecipe) -> String? {
        guard let first = parsed.ingredients.first else { return nil }
        let pieces = [first.quantity, first.unit, first.name]
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        let joined = pieces.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private func bannerView(_ banner: ImportBanner) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: banner.kind.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(bannerTint(for: banner.kind))
                .padding(.top, 2)
            Text(banner.message)
                .font(.system(size: 13))
                .foregroundStyle(AppColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(bannerTint(for: banner.kind).opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func bannerTint(for kind: ImportBanner.Kind) -> Color {
        switch kind {
        case .info: return appearance.accentColor
        case .warning: return AppColor.accentDeep
        case .error: return AppColor.destructive
        case .success: return AppColor.success
        }
    }

    private func actionRow(canPreview: Bool) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                if let clipboard = UIPasteboard.general.string {
                    pastedText = clipboard
                    Haptics.selection()
                }
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Paste from clipboard")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(appearance.accentColor)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColor.surface)
                .overlay(Capsule().stroke(appearance.accentColor, lineWidth: 1))
                .clipShape(Capsule())
            }
            .opacity(urlFieldEdited ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: urlFieldEdited)

            Spacer()

            Button {
                Haptics.impact(.light)
                dismissKeyboards()
                guard let draft = resolvePreviewDraft() else { return }
                let title = draft.title.trimmed
                if let suggested = nextAvailableTitle(base: title) {
                    pendingDraft = draft
                    duplicateSuggestedTitle = suggested
                    showDuplicateAlert = true
                } else {
                    parsedDraft = draft
                    showEditor = true
                }
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Text("Preview")
                        .font(.system(size: 15, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(AppColor.onAccent)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.sm + 2)
                .background(appearance.accentColor)
                .clipShape(Capsule())
                .opacity(canPreview ? 1 : 0.4)
            }
            .disabled(!canPreview)
            .shadow(
                color: urlFieldEdited ? appearance.accentColor.opacity(0.5) : .clear,
                radius: 12, x: 0, y: 4
            )
            .animation(.easeInOut(duration: 0.4), value: urlFieldEdited)
            .keyframeAnimator(initialValue: 0.0, trigger: previewJiggleCount) { view, angle in
                view.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.0, duration: 0.05)
                    CubicKeyframe(4.0, duration: 0.08)
                    CubicKeyframe(-4.0, duration: 0.08)
                    CubicKeyframe(3.0, duration: 0.07)
                    CubicKeyframe(-3.0, duration: 0.07)
                    CubicKeyframe(0.0, duration: 0.08)
                }
            }
            .tourTarget(.previewButton)
        }
    }

    // MARK: - Preview routing

    /// Pick which parser owns the Preview action. Link wins over text
    /// when both are filled — cleanest signal — and a URL pasted into
    /// the text body also routes to the link path so the user doesn't
    /// have to re-paste.
    private func resolvePreviewDraft() -> DraftRecipe? {
        // If we already have a fetched URL draft, prefer it.
        if !urlText.trimmed.isEmpty, let draft = parsedDraft {
            return draft
        }
        let textValue = pastedText.trimmed
        guard !textValue.isEmpty else { return nil }
        return RecipeImporter.parse(textValue)
    }

    private func computeCanPreview(parsedFromText: DraftRecipe) -> Bool {
        if !urlText.trimmed.isEmpty, let draft = parsedDraft {
            return !draft.title.trimmed.isEmpty
                || !draft.ingredients.isEmpty
                || !draft.steps.isEmpty
        }
        return !parsedFromText.title.trimmed.isEmpty
            || !parsedFromText.ingredients.isEmpty
            || !parsedFromText.steps.isEmpty
    }

    // MARK: - URL fetch flow

    @MainActor
    private func fetchURL() async {
        let candidate = urlText.trimmed
        guard !candidate.isEmpty, urlFetchState != .fetching else { return }
        Haptics.selection()
        urlFocused = false
        urlFetchState = .fetching
        banner = nil

        let outcome = await RecipeURLImporter.fetch(candidate)
        urlFetchState = .idle

        switch outcome {
        case .full(let draft):
            Haptics.success()
            parsedDraft = draft
            banner = ImportBanner(
                kind: .success,
                message: "Found a structured recipe. Tap Preview to review."
            )

        case .partial(let enrichment, let seedText, let hint):
            Haptics.success()
            parsedDraft = seedText.isEmpty
                && enrichment.ingredients.isEmpty
                && enrichment.steps.isEmpty
                ? nil
                : enrichment
            // Pre-fill the paste area with whatever seed text the URL
            // path could extract — same screen now, no sheet handoff.
            if !seedText.isEmpty, pastedText.trimmed.isEmpty {
                pastedText = seedText
            }
            let combined = seedText.isEmpty
                ? hint
                : "\(hint)\n\nYou can edit the text below and tap Preview when it's right."
            banner = ImportBanner(kind: .info, message: combined)

        case .blocked(let enrichment, let hint):
            Haptics.warning()
            parsedDraft = enrichment
            banner = ImportBanner(kind: .warning, message: hint)

        case .noRecipeInCaption(let enrichment, let hint):
            Haptics.warning()
            parsedDraft = enrichment
            banner = ImportBanner(kind: .warning, message: hint)

        case .failed(let message):
            Haptics.warning()
            banner = ImportBanner(kind: .error, message: message)
        }
    }

    // MARK: - Helpers

    private var canFetch: Bool {
        !urlText.trimmed.isEmpty && urlFetchState != .fetching
    }

    /// Returns the next available de-duped title if `base` already exists
    /// in the library, or `nil` when no duplicate is found.
    private func nextAvailableTitle(base: String) -> String? {
        let trimmed = base.trimmed
        guard !trimmed.isEmpty else { return nil }
        let descriptor = FetchDescriptor<Recipe>(predicate: #Predicate { $0.title == trimmed })
        guard let existing = try? modelContext.fetch(descriptor), !existing.isEmpty else { return nil }
        var n = 1
        while n < 100 {
            let candidate = "\(trimmed) (\(n))"
            let d = FetchDescriptor<Recipe>(predicate: #Predicate { $0.title == candidate })
            if (try? modelContext.fetch(d))?.isEmpty == true { return candidate }
            n += 1
        }
        return "\(trimmed) (\(n))"
    }

    private func dismissKeyboards() {
        urlFocused = false
        pasteFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func updateDirty() {
        editor.hasUnsavedChanges =
            !urlText.trimmed.isEmpty
            || !pastedText.trimmed.isEmpty
            || parsedDraft != nil
    }

    // MARK: - Local types

    private enum URLFetchState {
        case idle, fetching
    }

    private struct ImportBanner: Equatable {
        enum Kind {
            case info, warning, error, success

            var icon: String {
                switch self {
                case .info: return "info.circle.fill"
                case .warning: return "exclamationmark.triangle.fill"
                case .error: return "xmark.octagon.fill"
                case .success: return "checkmark.circle.fill"
                }
            }
        }
        let kind: Kind
        let message: String
    }
}
