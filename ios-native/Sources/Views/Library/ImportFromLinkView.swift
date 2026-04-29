import SwiftUI
import UIKit

/// URL-only recipe import path. Reachable from two places:
///
/// 1. **"Import From Link" FAB entry** — `prefilledURL` is nil, the
///    field starts empty, the user pastes or types a URL and taps
///    Fetch.
/// 2. **Share-extension URL handoff** — Safari / Reddit / blog
///    reader, `prefilledURL` carries the URL the user shared and we
///    auto-fetch on appear so the user lands on the parsed preview.
///
/// On a successful fetch the parser emits a `DraftRecipe`; we hand
/// it to the editor (same pattern as the text-paste path) so the
/// user can review and adjust before saving.
struct ImportFromLinkView: View {
    /// URL string the share extension extracted from another app's
    /// share sheet (Safari, Reddit, recipe-blog readers). When
    /// non-nil, `onAppear` populates the URL field with this value
    /// and kicks off the URL fetch immediately so the user lands on
    /// the parsed preview instead of an empty form. Nil for the
    /// plain "Import From Link" entry from the Library FAB.
    let prefilledURL: String?

    init(prefilledURL: String? = nil) {
        self.prefilledURL = prefilledURL
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance

    @State private var urlText = ""
    @State private var urlFetchState: URLFetchState = .idle
    @State private var urlBanner: URLBanner?
    @State private var urlEnrichment: DraftRecipe?
    @State private var parsedDraft: DraftRecipe?
    @State private var showEditor = false
    @State private var showHelp = false
    @FocusState private var urlFocused: Bool
    @AppStorage("hasSeenImportHelp") private var hasSeenImportHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                heroRow
                    .padding(.top, AppSpacing.md)

                linkImportSection

                actionRow(canPreview: canPreview)

                Color.clear.frame(height: 32)
            }
            .padding(AppSpacing.lg)
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboards() }
        }
        .background(AppColor.background)
        .navigationTitle("Import From Link")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(true)
        .tint(appearance.accentColor)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(appearance.accentColor)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.selection()
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(appearance.accentColor)
                }
                .accessibilityLabel("How import works")
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
                }
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
            // Share extension handoff: prefill the URL field and
            // kick off the fetch so the user lands on the parsed
            // preview, not an empty form. The help sheet still pops
            // for first-time users — share-extension users have at
            // least already seen the share-sheet UX, so the help
            // overlay isn't load-bearing here.
            if let prefill = prefilledURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prefill.isEmpty,
               urlText.isEmpty {
                urlText = prefill
                Task { await fetchURL() }
            } else if !hasSeenImportHelp {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    showHelp = true
                    hasSeenImportHelp = true
                }
            }
            updateDirty()
        }
        .onChange(of: urlEnrichment) { _, _ in updateDirty() }
        .onDisappear {
            editor.hasUnsavedChanges = false
        }
    }

    // MARK: - Subviews

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaLogo(size: 72, shadowColor: appearance.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from a link")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Paste a recipe link — I'll fetch it.")
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

    private func bannerView(_ banner: URLBanner) -> some View {
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

    /// Resolves a banner kind to a concrete tint. `.info` follows the
    /// user-chosen accent (it's primary chrome); status colors stay
    /// semantic so a custom accent doesn't accidentally turn warnings
    /// invisible.
    private func bannerTint(for kind: URLBanner.Kind) -> Color {
        switch kind {
        case .info: return appearance.accentColor
        case .warning: return AppColor.accentDeep
        case .error: return AppColor.destructive
        case .success: return AppColor.success
        }
    }

    private func actionRow(canPreview: Bool) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Spacer()

            Button {
                Haptics.impact(.light)
                dismissKeyboards()
                guard parsedDraft != nil else { return }
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
                .background(appearance.accentColor)
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
                message: "Found a structured recipe. Tap Preview to review."
            )

        case .partial(let enrichment, let seedText, let hint):
            // Link-only path — no in-place text editor here. Surface
            // the partial parse via the banner and offer a one-tap
            // handoff to the text-import sheet with the seed text
            // pre-loaded. The user can clean up the imported text in
            // the dedicated text editor instead of working from a
            // tiny inline preview.
            Haptics.success()
            urlEnrichment = enrichment
            parsedDraft = enrichment
            let combined = seedText.isEmpty
                ? hint
                : "\(hint)\n\nWe'll open the text editor with what we found."
            urlBanner = URLBanner(kind: .info, message: combined)
            // Auto-handoff if there's seedText: dismiss this sheet
            // and open the text-import sheet with the OCR'd seed
            // pre-loaded. Same pattern as the photo-import partial-
            // OCR fallback.
            if !seedText.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    editor.startImportFromText(seedText: seedText)
                }
            }

        case .blocked(let enrichment, let hint):
            Haptics.warning()
            urlEnrichment = enrichment
            parsedDraft = enrichment
            urlBanner = URLBanner(kind: .warning, message: hint)

        case .failed(let message):
            Haptics.warning()
            urlBanner = URLBanner(kind: .error, message: message)
        }
    }

    // MARK: - Helpers

    private var canFetch: Bool {
        !urlText.trimmed.isEmpty && urlFetchState != .fetching
    }

    private var canPreview: Bool {
        guard let draft = parsedDraft else { return false }
        return !draft.title.trimmed.isEmpty
            || !draft.ingredients.isEmpty
            || !draft.steps.isEmpty
    }

    private func dismissKeyboards() {
        urlFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func updateDirty() {
        editor.hasUnsavedChanges =
            !urlText.trimmed.isEmpty || urlEnrichment != nil
    }

    // MARK: - Local types

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
        }
        let kind: Kind
        let message: String
    }
}
