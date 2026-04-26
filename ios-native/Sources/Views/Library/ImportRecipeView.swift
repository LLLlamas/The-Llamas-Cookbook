import SwiftUI
import UIKit

struct ImportRecipeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorCoordinator.self) private var editor

    @State private var pastedText = ""
    @State private var parsedDraft: DraftRecipe?
    @State private var showEditor = false
    @State private var showHelp = false
    @FocusState private var pasteFocused: Bool
    @AppStorage("hasSeenImportHelp") private var hasSeenImportHelp = false

    // Link-import state. `urlEnrichment` carries fields the URL fetch
    // resolved (sourceUrl, title, tags, …) that the text parser can't
    // produce on its own; it gets merged into the preview draft on Save.
    @State private var urlText = ""
    @State private var urlFetchState: URLFetchState = .idle
    @State private var urlBanner: URLBanner?
    @State private var urlEnrichment: DraftRecipe?
    @FocusState private var urlFocused: Bool

    var body: some View {
        let parsed = mergedDraft(from: pastedText)
        let checks = Checks(
            title: !parsed.title.trimmed.isEmpty,
            ingredients: !parsed.ingredients.isEmpty,
            steps: !parsed.steps.isEmpty
        )
        let canPreview = checks.title || checks.ingredients || checks.steps

        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                heroRow
                    .padding(.top, AppSpacing.md)

                linkImportSection

                pasteImportSection(checks: checks, parsed: parsed)

                actionRow(canPreview: canPreview)
            }
            .padding(AppSpacing.lg)
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboards() }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(AppColor.background)
        .navigationTitle("Import recipe")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(AppColor.textPrimary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.selection()
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColor.accent)
                }
                .accessibilityLabel("How import works")
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            if let draft = parsedDraft {
                RecipeEditorView(recipe: nil, initialDraft: draft) {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showHelp) {
            ImportHelpView { showHelp = false }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            if !hasSeenImportHelp {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    showHelp = true
                    hasSeenImportHelp = true
                }
            }
            updateDirty()
        }
        .onChange(of: pastedText) { _, _ in updateDirty() }
        .onChange(of: urlEnrichment) { _, _ in updateDirty() }
        .onDisappear {
            editor.hasUnsavedChanges = false
        }
    }

    // MARK: - Subviews

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaMascot(size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("Import a recipe")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Paste a link or recipe text — I'll do my best to fill it in for you.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var linkImportSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("From a link").eyebrowStyle()

            HStack(spacing: AppSpacing.sm) {
                urlField
                fetchButton
            }

            if let banner = urlBanner {
                bannerView(banner)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: urlBanner)
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
                    urlBanner = nil
                    urlEnrichment = nil
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
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .opacity(canFetch ? 1 : 0.4)
        }
        .disabled(!canFetch)
    }

    private func bannerView(_ banner: URLBanner) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: banner.kind.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(banner.kind.tint)
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
                .stroke(banner.kind.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func pasteImportSection(checks: Checks, parsed: DraftRecipe) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("From text").eyebrowStyle()

            formatHint(checks: checks, parsed: parsed)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $pastedText)
                    .focused($pasteFocused)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(AppSpacing.sm)

                if pastedText.isEmpty {
                    Text("Paste a recipe here…")
                        .font(AppFont.body)
                        .foregroundStyle(AppColor.textTertiary)
                        .padding(AppSpacing.md)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 280)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    private func formatHint(checks: Checks, parsed: DraftRecipe) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs + 2) {
            HStack(spacing: AppSpacing.sm) {
                checkPill(label: "Title", done: checks.title, secondary: parsed.title.trimmed.isEmpty ? nil : parsed.title.trimmed)
            }
            HStack(spacing: AppSpacing.sm) {
                checkPill(label: "Ingredients", done: checks.ingredients, secondary: checks.ingredients ? "\(parsed.ingredients.count) detected" : nil)
            }
            HStack(spacing: AppSpacing.sm) {
                checkPill(label: "Steps", done: checks.steps, secondary: checks.steps ? "\(parsed.steps.count) detected" : nil)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: checks)
    }

    private func checkPill(label: String, done: Bool, secondary: String?) -> some View {
        HStack(spacing: AppSpacing.xs + 2) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(done ? AppColor.success : AppColor.textSecondary.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
            Text(label)
                .font(.system(size: 12, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(done ? AppColor.textPrimary : AppColor.textSecondary)
            if let secondary {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.divider)
                Text(secondary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
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
                .foregroundStyle(AppColor.accent)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColor.surface)
                .overlay(Capsule().stroke(AppColor.accent, lineWidth: 1))
                .clipShape(Capsule())
            }

            Spacer()

            Button {
                Haptics.impact(.light)
                dismissKeyboards()
                parsedDraft = mergedDraft(from: pastedText)
                showEditor = true
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
                .background(AppColor.accent)
                .clipShape(Capsule())
                .opacity(canPreview ? 1 : 0.4)
            }
            .disabled(!canPreview)
        }
    }

    // MARK: - URL fetch flow

    @MainActor
    private func fetchURL() async {
        let candidate = urlText.trimmed
        guard !candidate.isEmpty, urlFetchState != .fetching else { return }
        Haptics.selection()
        urlFocused = false
        pasteFocused = false
        urlFetchState = .fetching
        urlBanner = nil

        let outcome = await RecipeURLImporter.fetch(candidate)
        urlFetchState = .idle

        switch outcome {
        case .full(let draft):
            Haptics.success()
            urlEnrichment = draft
            parsedDraft = draft
            urlBanner = URLBanner(
                kind: .success,
                message: "Found a structured recipe. Opening preview…"
            )
            showEditor = true

        case .partial(let enrichment, let seedText, let hint):
            Haptics.success()
            urlEnrichment = enrichment
            if !seedText.isEmpty {
                pastedText = seedText
                pasteFocused = true
            }
            urlBanner = URLBanner(kind: .info, message: hint)

        case .blocked(let enrichment, let hint):
            Haptics.warning()
            urlEnrichment = enrichment
            urlBanner = URLBanner(kind: .warning, message: hint)
            pasteFocused = true

        case .failed(let message):
            Haptics.warning()
            urlBanner = URLBanner(kind: .error, message: message)
        }
    }

    // MARK: - Merge + helpers

    /// Run the text parser, then layer on whatever the URL fetch
    /// produced so the editor sees a single, complete draft. URL
    /// fields lose to text fields when both are present — the user's
    /// pasted text is treated as the more recent intent.
    private func mergedDraft(from text: String) -> DraftRecipe {
        var draft = RecipeImporter.parse(text)
        guard let enrichment = urlEnrichment else { return draft }

        if draft.title.trimmed.isEmpty { draft.title = enrichment.title }
        if draft.summary.trimmed.isEmpty { draft.summary = enrichment.summary }
        if draft.sourceUrl.trimmed.isEmpty { draft.sourceUrl = enrichment.sourceUrl }
        if draft.servings.trimmed.isEmpty { draft.servings = enrichment.servings }
        if draft.cookTimeMinutes.trimmed.isEmpty {
            draft.cookTimeMinutes = enrichment.cookTimeMinutes
        }
        if draft.ingredients.isEmpty { draft.ingredients = enrichment.ingredients }
        if draft.steps.isEmpty { draft.steps = enrichment.steps }

        // Tags merge (de-duped) rather than replace — gives the user
        // any keyword tags from the schema plus anything the text
        // parser pulled from a hashtag run.
        var seen = Set(draft.tags.map { $0.lowercased() })
        for tag in enrichment.tags {
            let key = tag.lowercased()
            if !seen.contains(key) {
                draft.tags.append(tag)
                seen.insert(key)
            }
        }
        return draft
    }

    private var canFetch: Bool {
        !urlText.trimmed.isEmpty && urlFetchState != .fetching
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
            !pastedText.trimmed.isEmpty || urlEnrichment != nil
    }

    // MARK: - Local types

    private struct Checks: Equatable {
        let title: Bool
        let ingredients: Bool
        let steps: Bool
    }

    private enum URLFetchState {
        case idle, fetching
    }

    private struct URLBanner: Equatable {
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
            var tint: Color {
                switch self {
                case .info: return AppColor.accent
                case .warning: return AppColor.accentDeep
                case .error: return AppColor.destructive
                case .success: return AppColor.success
                }
            }
            var border: Color {
                switch self {
                case .info: return AppColor.accent.opacity(0.4)
                case .warning: return AppColor.accentDeep.opacity(0.45)
                case .error: return AppColor.destructive.opacity(0.45)
                case .success: return AppColor.success.opacity(0.45)
                }
            }
        }
        let kind: Kind
        let message: String
    }
}
