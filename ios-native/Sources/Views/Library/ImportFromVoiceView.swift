import SwiftUI
import UIKit

/// Record-and-transcribe import path. The user dictates a recipe out
/// loud; we surface a live transcript preview, soft-cap the recording
/// at 5 minutes, and on Done feed the cleaned transcript through
/// `RecipeAIParser.parseBestOf` (same path as OCR / pasted text).
///
/// On success the parsed `DraftRecipe` surfaces in the read-only
/// `PhotoImportPreviewView` (reused — same accept-or-cancel metaphor
/// as the photo flow). On the partial-fallback path (transcript
/// captured but parser couldn't separate ingredients from steps) we
/// show a banner with a "Continue in text editor" handoff — same
/// `EditorCoordinator.startImportFromText(seedText:)` pattern used
/// by the photo flow.
struct ImportFromVoiceView: View {
    /// Called by RootView with the saved `Recipe` after the user taps
    /// Save on the inner preview. Same shape as `ImportFromPhotoView`.
    var onSaved: (Recipe) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance

    @State private var session = VoiceImportSession()
    @State private var elapsed: TimeInterval = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var processing = false
    @State private var preview: PreviewPayload?
    @State private var errorBanner: ErrorBanner?
    /// Frozen copy of the live transcript captured at the moment the
    /// user tapped Stop. The session tears down its own copy during
    /// finalize, so we hold the snapshot for the on-screen review
    /// state and the parser handoff.
    @State private var finalTranscript: String = ""

    /// Soft cap matching the spec — visible countdown, auto-stop on
    /// hit. Keeps recordings under the size where transcription
    /// latency outpaces the user's patience.
    private let maxDuration: TimeInterval = 5 * 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                heroRow
                    .padding(.top, AppSpacing.md)

                if !RecipeVoiceImporter.isAvailable && !session.isRecording {
                    unavailableBanner
                } else {
                    recordingSection
                    transcriptSection
                }

                if let banner = errorBanner {
                    bannerView(banner)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }

                tipRow

                Color.clear.frame(height: 32)
            }
            .padding(AppSpacing.lg)
        }
        .llamaBackground()
        .navigationTitle("Import From Voice")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(session.isRecording || processing)
        .tint(appearance.accentColor)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    Task {
                        await session.cancel()
                        dismiss()
                    }
                }
                .foregroundStyle(appearance.accentColor)
                .disabled(processing)
            }
        }
        .task {
            // Pre-warm the speech model so the first Record tap
            // doesn't stall on a cold model load.
            await session.prepare()
        }
        .sheet(item: $preview) { payload in
            PhotoImportPreviewView(
                draft: payload.draft,
                onSaved: { savedRecipe in
                    onSaved(savedRecipe)
                    dismiss()
                },
                onSavedForEdit: { savedRecipe in
                    onSaved(savedRecipe)
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1500))
                        editor.startEdit(savedRecipe)
                    }
                }
            )
            .environment(appearance)
        }
        .overlay {
            if processing {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: AppSpacing.md) {
                        LlamaProgressIndicator(size: 96, accent: appearance.accentColor)
                        Text("Organizing your recipe…")
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textPrimary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 240)
                    }
                    .padding(AppSpacing.xl)
                    .background(AppColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
                    .shadow(color: AppColor.shadow, radius: 18, y: 6)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: processing)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: errorBanner)
        .onDisappear {
            timerTask?.cancel()
            editor.hasUnsavedChanges = false
            Task { await session.cancel() }
        }
        .onChange(of: session.errorMessage) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            errorBanner = ErrorBanner(
                kind: .error,
                message: newValue,
                actionTitle: nil,
                action: nil
            )
        }
    }

    // MARK: - Subviews

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaLogo(size: 72, shadowColor: appearance.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from voice")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Read your recipe out loud — title, ingredients, then steps. I'll fill in the rest.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var recordingSection: some View {
        VStack(spacing: AppSpacing.md) {
            Text(timerText)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundStyle(session.isRecording ? appearance.accentColor : AppColor.textPrimary)
                .contentTransition(.numericText())

            recordButton

            if session.isRecording {
                Text("Tap to stop and review")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColor.textTertiary)
            } else if !finalTranscript.isEmpty {
                Text("Tap to record again")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.md)
    }

    private var recordButton: some View {
        Button {
            if session.isRecording {
                Task { await stopRecording() }
            } else {
                Task { await startRecording() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(session.isRecording ? AppColor.destructive : appearance.accentColor)
                    .frame(width: 84, height: 84)
                    .shadow(color: (session.isRecording ? AppColor.destructive : appearance.accentColor).opacity(0.35), radius: 14, y: 6)

                Image(systemName: session.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
            }
        }
        .buttonStyle(.plain)
        .disabled(processing)
        .accessibilityLabel(session.isRecording ? "Stop recording" : "Start recording")
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(transcriptEyebrow).eyebrowStyle()
                Spacer()
                if session.isRecording {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AppColor.destructive)
                            .frame(width: 8, height: 8)
                            .opacity(0.85)
                        Text("LIVE")
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(AppColor.destructive)
                    }
                }
            }

            Text(transcriptDisplay.isEmpty ? "Say a recipe — title, then ingredients, then the steps. I'll listen." : transcriptDisplay)
                .font(AppFont.body)
                .foregroundStyle(transcriptDisplay.isEmpty ? AppColor.textTertiary : AppColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.md)
                .background(AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(AppColor.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    private var unavailableBanner: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.accentDeep)
                    .padding(.top, 2)
                Text("Voice import isn't available on this device. Try Import From Text/Link or Import From Photo instead.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.accentDeep.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var tipRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Tips for a clean read").eyebrowStyle()
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                tip("Start with the recipe title.")
                tip("Pause briefly before listing ingredients, then again before steps.")
                tip("Numbers come through best when said with the unit — \"two cups flour\".")
                tip("Keep it under 5 minutes — you can always edit details after.")
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfaceSunken)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.xs + 2) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .padding(.top, 7)
                .foregroundStyle(appearance.accentColor.opacity(0.65))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func bannerView(_ banner: ErrorBanner) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
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
            if banner.action != nil {
                HStack {
                    Spacer()
                    Button {
                        banner.action?()
                    } label: {
                        Text(banner.actionTitle ?? "Continue")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppColor.onAccent)
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.sm)
                            .background(appearance.accentColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(bannerTint(for: banner.kind).opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func bannerTint(for kind: ErrorBanner.Kind) -> Color {
        switch kind {
        case .info:    return appearance.accentColor
        case .warning: return AppColor.accentDeep
        case .error:   return AppColor.destructive
        }
    }

    // MARK: - Recording flow

    @MainActor
    private func startRecording() async {
        Haptics.impact(.light)
        errorBanner = nil
        finalTranscript = ""
        elapsed = 0
        let started = await session.start()
        guard started else {
            // The session sets `errorMessage` itself; the .onChange
            // observer above promotes that into the banner.
            return
        }
        editor.hasUnsavedChanges = true
        startTimer()
    }

    @MainActor
    private func stopRecording() async {
        Haptics.impact(.light)
        timerTask?.cancel()
        timerTask = nil
        processing = true
        defer { processing = false }

        let result = await session.finish()
        finalTranscript = result ?? ""

        guard let transcript = result, !transcript.isEmpty else {
            errorBanner = ErrorBanner(
                kind: .error,
                message: "Couldn't pick up any speech. Try again — speak a little louder, or check the mic permission in Settings.",
                actionTitle: nil,
                action: nil
            )
            return
        }

        let draft = await RecipeAIParser.parseBestOf(transcript, sourceUrl: nil)

        let hasTitle = !(draft?.title.trimmed.isEmpty ?? true)
        let hasIngredients = !(draft?.ingredients.isEmpty ?? true)
        let hasSteps = !(draft?.steps.isEmpty ?? true)
        let confident = hasTitle && hasIngredients && hasSteps

        if confident, let draft {
            preview = PreviewPayload(draft: draft)
        } else {
            // Partial transcript — surface the text in the text editor
            // so the user can clean it up by hand. Same handoff shape
            // the photo-import partial-OCR fallback uses.
            let seed = transcript
            errorBanner = ErrorBanner(
                kind: .warning,
                message: "We caught what you said but couldn't tell ingredients from steps. Edit it as text?",
                actionTitle: "Continue in text editor",
                action: {
                    Haptics.impact(.light)
                    editor.startImportFromText(seedText: seed)
                }
            )
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled, session.isRecording {
                elapsed = Date().timeIntervalSince(start)
                if elapsed >= maxDuration {
                    await stopRecording()
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: - Derived

    /// Live transcript while recording, frozen final transcript after
    /// stop. Falls back to "" (placeholder copy renders) before the
    /// first tap.
    private var transcriptDisplay: String {
        if session.isRecording {
            return session.transcript
        }
        return finalTranscript
    }

    private var transcriptEyebrow: String {
        session.isRecording ? "LIVE TRANSCRIPT" : (finalTranscript.isEmpty ? "TRANSCRIPT" : "RECORDED")
    }

    private var timerText: String {
        let total = Int(min(elapsed, maxDuration))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Local types

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let draft: DraftRecipe
    }

    private struct ErrorBanner: Equatable {
        enum Kind: Equatable {
            case info, warning, error

            var icon: String {
                switch self {
                case .info:    return "info.circle.fill"
                case .warning: return "exclamationmark.triangle.fill"
                case .error:   return "xmark.octagon.fill"
                }
            }
        }
        let kind: Kind
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?

        static func == (lhs: ErrorBanner, rhs: ErrorBanner) -> Bool {
            lhs.kind == rhs.kind
                && lhs.message == rhs.message
                && lhs.actionTitle == rhs.actionTitle
        }
    }
}
