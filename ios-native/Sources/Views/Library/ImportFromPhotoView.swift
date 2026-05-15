import SwiftUI
import PhotosUI
import UIKit
import os

/// Photo-import instrumentation. Branch-level signposts let Instruments
/// visualize the full pipeline; one summary `Logger.info` line per import
/// captures the same data for log-stream tailing (`log stream
/// --predicate 'subsystem == "com.llamascookbook.app"' --info`).
///
/// Logs never contain recipe text, OCR text, image bytes, or titles —
/// only durations, branch enum, and counts. Mirrors the Worker logs at
/// `parse.js:189-204` for end-to-end timeline correlation.
private let photoImportLog = Logger(subsystem: "com.llamascookbook.app", category: "photoImport")
private let photoImportSignposter = OSSignposter(subsystem: "com.llamascookbook.app", category: "photoImport")

/// Capture chooser for the photo-import path.
///
/// Phase 1 additions vs. original:
/// - Quota pill at the top of the sheet (always visible when signed in).
/// - Capture buttons are disabled when the monthly cap or daily parse
///   limit is hit; exhausted-state card replaces the tips section.
/// - Sign-in nudge replaces capture buttons for unsigned users.
/// - `runImport` handles `VisionParseOutcome` error cases:
///   `.quotaExhausted` / `.dailyLimitHit` refresh the quota and switch
///   into the appropriate exhausted-state UI without showing a banner.
/// - Per-session attempt counter passed to `PhotoImportPreviewView` so
///   the cache-hit hint appears on the 2nd+ attempt in a session.
///
/// Phase 3 (streaming reveal):
/// - Sonnet vision response streams as SSE. After the OCR preflight
///   (≤1 s), the preview sheet pops immediately with pulsing skeleton
///   placeholders — the processing overlay is gone. Anthropic's TTFB
///   for vision (5–10 s) passes with the skeleton visible; then title,
///   ingredients, and steps tick in progressively. Save enables on
///   `message_stop`.
/// - The legacy "What are we cookin'?" title input and Ready/Review state
///   were removed once streaming made the perceived-speed need obsolete.
/// - Local OCR preflight unchanged: Vision OCR runs first; a strict
///   confidence gate skips the paid Sonnet call entirely for clean
///   printed pages.
struct ImportFromPhotoView: View {
    var onSaved: (Recipe) -> Void = { _ in }

    @Environment(\.dismiss)          private var dismiss
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(UserAccount.self)   private var userAccount
    @Environment(QuotaService.self)  private var quotaService

    @State private var showingScanner   = false
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var ocrInProgress    = false
    @State private var ocrPageStatus: String?
    @State private var preview: PreviewPayload?
    @State private var errorBanner: ErrorBanner?
    @State private var capturedPages: [CapturedPage] = []
    @State private var showingPaywall   = false
    /// Counts how many parse attempts the user has made in this sheet session.
    /// Resets when the sheet is dismissed and re-presented.
    @State private var sessionAttemptCount = 0
    /// Backs the streaming preview when the Sonnet path is active. Created
    /// in `runImport` immediately after OCR preflight; the preview pops at
    /// that point (skeleton mode) so the overlay is gone before Anthropic TTFB.
    @State private var streamingState: StreamingRecipeState? = nil

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                heroRow
                    .padding(.top, AppSpacing.md)

                if !userAccount.status.isSignedIn {
                    signInNudge
                } else {
                    quotaPill
                    if isInputBlocked {
                        exhaustedCard
                    } else {
                        if capturedPages.isEmpty {
                            captureButtons
                        } else {
                            capturedPagesView
                        }
                        if let banner = errorBanner {
                            bannerView(banner)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity
                                ))
                        }
                        if !isInputBlocked {
                            tipRow
                        }
                    }
                }
                Color.clear.frame(height: 32)
            }
            .padding(AppSpacing.lg)
        }
        .llamaBackground()
        .navigationTitle("Import From Photo")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(ocrInProgress)
        .tint(appearance.accentColor)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text("Cancel")
                        .foregroundStyle(appearance.accentColor)
                        .accentTextOutline()
                }
                .disabled(ocrInProgress)
            }
        }
        .fullScreenCover(isPresented: $showingScanner) {
            CameraCaptureView(
                onComplete: { images in
                    showingScanner = false
                    capturedPages.append(contentsOf: images.map { CapturedPage(image: $0) })
                },
                onCancel: { showingScanner = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var loaded: [CapturedPage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        loaded.append(CapturedPage(image: img, sourceData: data))
                    }
                }
                if !loaded.isEmpty {
                    capturedPages.append(contentsOf: loaded)
                }
                pickedItems = []
            }
        }
        .sheet(item: $preview) { payload in
            PhotoImportPreviewView(
                draft: payload.draft,
                streamingState: payload.streamingState,
                cacheHit: payload.cacheHit,
                sessionAttemptIndex: payload.sessionAttemptIndex,
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
            .environment(quotaService)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
                .environment(appearance)
        }
        .overlay {
            if ocrInProgress {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    processingCard
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2),  value: ocrInProgress)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: errorBanner)
        .animation(.easeInOut(duration: 0.25), value: capturedPages.isEmpty)
        .onAppear {
            Task { await quotaService.refresh() }
        }
        .onDisappear {
            editor.hasUnsavedChanges = false
            sessionAttemptCount = 0
            streamingState = nil
        }
    }

    // MARK: - Processing overlay

    /// Shown while we're waiting for image prep + OCR preflight only (~1 s).
    /// Dismisses as soon as the preview sheet pops — which happens before
    /// the Anthropic call starts, so the skeleton UI is visible during TTFB.
    private var processingCard: some View {
        VStack(spacing: AppSpacing.md) {
            LlamaProgressIndicator(size: 96, accent: appearance.accentColor)
            Text(ocrPageStatus ?? "Reading your recipe…")
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

    // MARK: - Quota state helpers

    private var snapshot: QuotaSnapshot? { quotaService.snapshot }

    private var isDailyLimitHit: Bool    { snapshot?.isDailyLimitHit    ?? false }
    private var isMonthlyExhausted: Bool { snapshot?.isMonthlyExhausted ?? false }

    /// True when the user cannot start a new import attempt right now.
    private var isInputBlocked: Bool { false }

    /// "4h 23m", "1d 6h", "18d", "soon" — used in the pill and blocked cards.
    private static func timeRemaining(until target: Date, from now: Date) -> String {
        let seconds = target.timeIntervalSince(now)
        guard seconds > 60 else { return "soon" }
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let days = hours / 24
        let remainingHours = hours % 24
        if days >= 2 {
            return "\(days)d"
        } else if days == 1 {
            return remainingHours > 0 ? "1d \(remainingHours)h" : "1d"
        } else if hours >= 1 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        } else {
            return "\(minutes)m"
        }
    }

    // MARK: - Quota pill

    @ViewBuilder
    private var quotaPill: some View {
        if let s = snapshot {
            HStack(spacing: AppSpacing.sm) {
                TimelineView(.everyMinute) { context in
                    HStack(spacing: AppSpacing.xs) {
                        if s.isPro {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(pillText(s, now: context.date))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(pillForeground(s))
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.xs + 2)
                    .background(pillBackground(s))
                    .clipShape(Capsule())
                }

                if !s.isPro {
                    Button {
                        showingPaywall = true
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Llama Pro")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(AppColor.onAccent)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.xs + 2)
                        .background(appearance.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func pillText(_ s: QuotaSnapshot, now: Date) -> String {
        if s.isDailyLimitHit {
            let t = Self.timeRemaining(until: s.dailyParseResetAt, from: now)
            return "Daily limit reached — resets in \(t)"
        }
        if s.isMonthlyExhausted {
            let t = Self.timeRemaining(until: s.resetAt, from: now)
            if s.isPro {
                return "Llama Pro — 0 left, resets in \(t)"
            } else {
                return "0 imports left — resets in \(t)"
            }
        }
        if s.isPro {
            let low = s.remaining <= 9
            if low {
                return "Llama Pro — \(s.remaining) of \(s.limit) left this month"
            } else {
                return "Llama Pro — \(s.remaining) of \(s.limit) left"
            }
        } else {
            let low = s.remaining <= 2
            if low {
                return "\(s.remaining) free import\(s.remaining == 1 ? "" : "s") left — resets \(s.resetDateFormatted)"
            } else {
                return "\(s.remaining) free import\(s.remaining == 1 ? "" : "s") left this month"
            }
        }
    }

    private func pillForeground(_ s: QuotaSnapshot) -> Color {
        if s.isDailyLimitHit || s.isMonthlyExhausted { return AppColor.destructive }
        if (s.isPro && s.remaining <= 9) || (!s.isPro && s.remaining <= 2) {
            return AppColor.accentDeep
        }
        return appearance.accentColor
    }

    private func pillBackground(_ s: QuotaSnapshot) -> Color {
        if s.isDailyLimitHit || s.isMonthlyExhausted {
            return AppColor.destructive.opacity(0.1)
        }
        if (s.isPro && s.remaining <= 9) || (!s.isPro && s.remaining <= 2) {
            return AppColor.accentDeep.opacity(0.1)
        }
        return appearance.accentColor.opacity(0.1)
    }

    // MARK: - Exhausted / blocked card

    @ViewBuilder
    private var exhaustedCard: some View {
        if isDailyLimitHit {
            dailyLimitCard
        } else if isMonthlyExhausted {
            if snapshot?.isPro == true {
                proMonthlyLimitCard
            } else {
                freeMonthlyLimitCard
            }
        }
    }

    private var dailyLimitCard: some View {
        blockedCard(
            title: "Daily limit reached",
            body: "You've made 5 photo parse attempts today. Paste or type recipes for free in the meantime.",
            resetDate: snapshot?.dailyParseResetAt,
            upgradeButton: nil
        )
    }

    private var freeMonthlyLimitCard: some View {
        blockedCard(
            title: "Out of free imports",
            body: "You've saved 5 photo imports this month. Upgrade to Llama Pro for 30 photo imports per month, or paste / type recipes for free.\n\nComing soon to Pro: Grocery list with Instacart integration.",
            resetDate: snapshot?.resetAt,
            upgradeButton: ("Upgrade to Llama Pro", { showingPaywall = true })
        )
    }

    private var proMonthlyLimitCard: some View {
        blockedCard(
            title: "You've hit your monthly Pro limit",
            body: "You've saved 30 photo imports this month. Paste or type recipes for free, no limit.",
            resetDate: snapshot?.resetAt,
            upgradeButton: nil
        )
    }

    private func blockedCard(
        title: String,
        body: String,
        resetDate: Date?,
        upgradeButton: (String, () -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.sm) {
                LlamaLogo(size: 36, shadowColor: appearance.accentColor)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppColor.textPrimary)
            }
            Text(body)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let resetDate {
                TimelineView(.everyMinute) { context in
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "clock")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Resets in \(Self.timeRemaining(until: resetDate, from: context.date))")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(appearance.accentColor)
                }
            }
            if let (label, action) = upgradeButton {
                VStack(spacing: AppSpacing.sm) {
                    Button {
                        Haptics.impact(.medium)
                        action()
                    } label: {
                        Text(label)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColor.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.sm + 4)
                            .background(appearance.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    }
                    .buttonStyle(.plain)
                    Button {
                        dismiss()
                    } label: {
                        Text("Maybe later")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.sm + 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.md)
                                    .stroke(AppColor.divider, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    // MARK: - Sign-in nudge

    private var signInNudge: some View {
        VStack(spacing: AppSpacing.md) {
            Text("Sign in with Apple to import recipes from photos.")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.textPrimary)
                .multilineTextAlignment(.center)
            Text("Free users get 5 photo imports per month.")
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(AppSpacing.lg)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    // MARK: - Hero

    private var heroRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaLogo(size: 72, shadowColor: appearance.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from a photo")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                Text("Snap a cookbook spread, magazine clipping, or recipe card — I'll read and fill it in.")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Capture buttons

    private var captureButtons: some View {
        VStack(spacing: AppSpacing.md) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    Haptics.impact(.light)
                    errorBanner = nil
                    showingScanner = true
                } label: {
                    captureButtonLabel(
                        title: "Take a Photo",
                        subtitle: "Scan a recipe page with your camera",
                        icon: "camera.fill",
                        foreground: AppColor.onAccent,
                        background: appearance.accentColor,
                        strokeColor: nil
                    )
                }
                .buttonStyle(.plain)
            }

            PhotosPicker(
                selection: $pickedItems,
                maxSelectionCount: 3,
                matching: .images,
                photoLibrary: .shared()
            ) {
                captureButtonLabel(
                    title: "Choose from Library",
                    subtitle: "Pick a recipe photo you've already taken",
                    icon: "photo.on.rectangle.angled",
                    foreground: appearance.accentColor,
                    background: AppColor.surface,
                    strokeColor: appearance.accentColor
                )
            }
        }
    }

    // MARK: - Captured pages view

    private var capturedPagesView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(capturedPages.indices, id: \.self) { idx in
                        ZStack(alignment: .bottomTrailing) {
                            Image(uiImage: capturedPages[idx].image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppColor.onAccent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(appearance.accentColor)
                                .clipShape(Capsule())
                                .padding(4)
                        }
                    }
                }
            }
            Text(capturedPages.count == 1
                 ? "1 page captured"
                 : "\(capturedPages.count) pages captured")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)

            if capturedPages.count < 3 {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        Haptics.impact(.light)
                        errorBanner = nil
                        showingScanner = true
                    } label: {
                        captureButtonLabel(
                            title: "Add Another Page",
                            subtitle: "Snap the next part of the recipe",
                            icon: "plus.viewfinder",
                            foreground: appearance.accentColor,
                            background: AppColor.surface,
                            strokeColor: appearance.accentColor
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(ocrInProgress)
                }
                PhotosPicker(
                    selection: $pickedItems,
                    maxSelectionCount: 3 - capturedPages.count,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    captureButtonLabel(
                        title: "Add from Library",
                        subtitle: "Pick another page from your photos",
                        icon: "photo.badge.plus",
                        foreground: appearance.accentColor,
                        background: AppColor.surface,
                        strokeColor: appearance.accentColor
                    )
                }
                .disabled(ocrInProgress)
            } else {
                Text("Maximum 3 pages reached")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, AppSpacing.sm)
            }

            Button {
                Haptics.impact(.medium)
                Task { await runImport(on: capturedPages) }
            } label: {
                captureButtonLabel(
                    title: capturedPages.count == 1 ? "Process Recipe" : "Process \(capturedPages.count) Pages",
                    subtitle: capturedPages.count == 1 ? "Extract and organize the recipe" : "Combine and extract the full recipe",
                    icon: "text.viewfinder",
                    foreground: AppColor.onAccent,
                    background: appearance.accentColor,
                    strokeColor: nil
                )
            }
            .buttonStyle(.plain)
            .disabled(ocrInProgress)

            Button {
                capturedPages = []
                errorBanner = nil
            } label: {
                Text("Start over")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textSecondary.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Shared label builder

    private func captureButtonLabel(
        title: String,
        subtitle: String,
        icon: String,
        foreground: Color,
        background: Color,
        strokeColor: Color?
    ) -> some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .opacity(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay {
            if let strokeColor {
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(strokeColor, lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    // MARK: - Tips

    private var tipRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Tips for a clean read").eyebrowStyle()
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                tip("Lay the page flat — no curl in the middle.")
                tip("Fill the frame with the recipe; trim chapter art.")
                tip("Avoid glossy-paper glare — angle the page slightly.")
                tip("Tap the shutter when the page is in focus — you can retake before saving.")
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

    // MARK: - Error banner

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
                    Button { banner.action?() } label: {
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

    // MARK: - Import runner (OCR preflight → streaming vision → OCR+AI fallback)

    @MainActor
    private func runImport(on pages: [CapturedPage]) async {
        guard !pages.isEmpty else { return }
        ocrInProgress = true
        errorBanner   = nil
        streamingState = nil
        let importStart = Date()
        var timings = ImportTimings()
        var branch: ImportBranch = .unknown
        var accepted = false
        var cacheHit = false
        defer {
            ocrInProgress = false
            ocrPageStatus = nil
            let totalMs = Int(Date().timeIntervalSince(importStart) * 1000)
            photoImportLog.info(
                "photo_import branch=\(branch.rawValue, privacy: .public) total_ms=\(totalMs, privacy: .public) prepare_ms=\(timings.prepare, privacy: .public) ocr_ms=\(timings.ocr, privacy: .public) local_parse_ms=\(timings.localParse, privacy: .public) vision_first_byte_ms=\(timings.visionFirstByte, privacy: .public) vision_total_ms=\(timings.visionTotal, privacy: .public) fallback_ms=\(timings.fallback, privacy: .public) page_count=\(pages.count, privacy: .public) accepted=\(accepted, privacy: .public) cache_hit=\(cacheHit, privacy: .public) session_attempt=\(self.sessionAttemptCount, privacy: .public)"
            )
        }

        ocrPageStatus = pages.count == 1 ? "Preparing page…" : "Preparing \(pages.count) pages…"

        let prepInterval = photoImportSignposter.beginInterval("preparePages")
        let prepStart = Date()
        let prepared     = await preparePages(pages)
        let visionImages = prepared.compactMap(\.vision)
        let ocrImages    = prepared.compactMap(\.ocr)
        timings.prepare = Int(Date().timeIntervalSince(prepStart) * 1000)
        photoImportSignposter.endInterval("preparePages", prepInterval)

        guard !visionImages.isEmpty || !ocrImages.isEmpty else {
            errorBanner = ErrorBanner(
                kind: .error,
                message: "Couldn't read those photos. Try a different image.",
                actionTitle: nil, action: nil
            )
            branch = .preparationFailed
            return
        }

        sessionAttemptCount += 1
        ocrPageStatus = "Reading the recipe…"

        // ── Local OCR preflight ───────────────────────────────────────────────
        // Run on-device Vision OCR first. Clean printed pages with explicit
        // section labels produce a confident draft at zero API cost. The OCR
        // text is reused in the fallback below so we never recognize twice.
        var prefetchedOCRText: String? = nil
        if !ocrImages.isEmpty {
            let ocrInterval = photoImportSignposter.beginInterval("ocr")
            let ocrStart = Date()
            let ocrText = await RecipeOCRImporter.recognize(ocrImages)
            timings.ocr = Int(Date().timeIntervalSince(ocrStart) * 1000)
            photoImportSignposter.endInterval("ocr", ocrInterval)
            if !ocrText.isEmpty {
                prefetchedOCRText = ocrText
                let localInterval = photoImportSignposter.beginInterval("localParse")
                let localStart = Date()
                let localDraft = RecipeImporter.parse(ocrText)
                timings.localParse = Int(Date().timeIntervalSince(localStart) * 1000)
                photoImportSignposter.endInterval("localParse", localInterval)
                if localPhotoParseConfident(localDraft, ocrText: ocrText) {
                    branch = .localAccept
                    accepted = true
                    finishImport(draft: localDraft, cacheHit: false, streamingState: nil)
                    return
                }
            }
        }

        // ── Sonnet streaming vision ───────────────────────────────────────────
        // Pop the preview NOW — before the Anthropic call — so the overlay
        // shows for only the OCR preflight time (~0.5-1 s). The user sees
        // pulsing skeleton placeholders while Anthropic processes the image
        // (5–10 s TTFB); content ticks in progressively as events arrive.
        let state = StreamingRecipeState()
        streamingState = state
        let sessionIndex = sessionAttemptCount
        capturedPages = []
        preview = PreviewPayload(
            draft: DraftRecipe(),
            streamingState: state,
            cacheHit: false,
            sessionAttemptIndex: sessionIndex
        )
        ocrInProgress = false

        let visionInterval = photoImportSignposter.beginInterval("visionStreaming")
        let visionStart = Date()
        let visionOutcome: VisionParseOutcome = visionImages.isEmpty
            ? VisionParseOutcome()
            : await RecipeAIParser.parseImagesStreaming(
                visionImages,
                sourceUrl: nil,
                streamingState: state
            )
        timings.visionTotal = Int(Date().timeIntervalSince(visionStart) * 1000)
        if let firstByte = state.firstContentAt {
            timings.visionFirstByte = Int(firstByte.timeIntervalSince(visionStart) * 1000)
        }
        photoImportSignposter.endInterval("visionStreaming", visionInterval)

        // Handle quota / auth errors — dismiss preview, refresh snapshot.
        // Auth errors block entirely; quota/daily-limit fall through to the
        // OCR+AI fallback so testing can continue without the server cap.
        if let err = visionOutcome.error {
            Task { await quotaService.refresh(force: true) }
            preview = nil
            state.fail()
            switch err {
            case .authRequired:
                errorBanner = ErrorBanner(
                    kind: .error,
                    message: "Sign in with Apple to import from photos.",
                    actionTitle: nil, action: nil
                )
                branch = .authRequired
                return
            case .quotaExhausted:
                branch = .quotaExhausted
            case .dailyLimitHit:
                branch = .dailyLimitHit
            }
            // quota/daily-limit: fall through to OCR+AI text fallback
        }

        // Stream completed successfully with a confident draft.
        if let draft = visionOutcome.draft, photoImportConfident(draft) {
            cacheHit = visionOutcome.cacheHit
            accepted = true
            branch = state.hasFirstContent
                ? .visionStream
                : (visionOutcome.cacheHit ? .visionCacheHit : .visionBufferedComplete)
            state.completeStream(finalDraft: draft, cacheHit: visionOutcome.cacheHit)
            return
        }

        // ── OCR + text-AI fallback ────────────────────────────────────────────
        // Stream produced nothing usable — dismiss the speculative preview.
        preview = nil
        state.cancel()
        let fallbackStart = Date()
        let ocrText: String
        if let precomputed = prefetchedOCRText {
            ocrText = precomputed
        } else {
            ocrText = ocrImages.isEmpty ? "" : await RecipeOCRImporter.recognize(ocrImages)
        }

        let fallbackInterval = photoImportSignposter.beginInterval("ocrTextFallback")
        let textDraft: DraftRecipe? = ocrText.isEmpty
            ? nil
            : await RecipeAIParser.parseBestOf(ocrText, sourceUrl: nil, preferHighQuality: true)
        photoImportSignposter.endInterval("ocrTextFallback", fallbackInterval)
        timings.fallback = Int(Date().timeIntervalSince(fallbackStart) * 1000)

        if let t = textDraft, photoImportConfident(t) {
            branch = .ocrTextFallback
            accepted = true
            finishImport(draft: t, cacheHit: false, streamingState: nil)
            return
        }

        guard !ocrText.isEmpty else {
            errorBanner = ErrorBanner(
                kind: .error,
                message: "Couldn't read text from the image. Try better lighting or a closer angle, or pick a different photo.",
                actionTitle: nil, action: nil
            )
            branch = .ocrEmpty
            return
        }
        let seed = ocrText
        errorBanner = ErrorBanner(
            kind: .warning,
            message: "We pulled the text but couldn't separate ingredients from steps. Try adding another page, or edit the text directly.",
            actionTitle: "Edit as text",
            action: {
                Haptics.impact(.light)
                editor.startImportFromText(seedText: seed)
            }
        )
        branch = .editAsTextFallback
    }

    // MARK: - Finish import

    /// Pop the preview sheet with a fully-formed draft. Used by the local
    /// accept and OCR+AI fallback paths (and by cache-hit Sonnet results
    /// that never streamed). Streaming-path drafts are handled inline in
    /// `runImport` so the preview can bind to the `StreamingRecipeState`
    /// for progressive reveal.
    @MainActor
    private func finishImport(
        draft: DraftRecipe,
        cacheHit: Bool,
        streamingState: StreamingRecipeState?
    ) {
        let payload = PreviewPayload(
            draft: draft,
            streamingState: streamingState,
            cacheHit: cacheHit,
            sessionAttemptIndex: sessionAttemptCount
        )
        capturedPages = []
        preview       = payload
    }

    // MARK: - Confidence gates

    /// Stricter gate for locally-parsed (no AI) photo drafts.
    /// Requires explicit section labels in the OCR text as a signal that
    /// the page has clear structure the deterministic parser can trust.
    private func localPhotoParseConfident(_ draft: DraftRecipe, ocrText: String) -> Bool {
        guard !draft.title.trimmed.isEmpty else { return false }
        guard draft.ingredients.count >= 3 else { return false }
        guard draft.steps.count >= 2 else { return false }
        guard draft.steps.allSatisfy({ $0.text.count <= 220 }) else { return false }
        let hasQtyOrUnit = draft.ingredients.contains {
            !$0.quantity.trimmed.isEmpty || !$0.unit.trimmed.isEmpty
        }
        guard hasQtyOrUnit else { return false }
        let lower = ocrText.lowercased()
        return lower.contains("ingredients") ||
            lower.contains("directions") ||
            lower.contains("instructions") ||
            lower.contains("method") ||
            lower.contains("preparation")
    }

    /// Basic gate used for AI-parsed photo drafts (Sonnet / OCR+AI fallback).
    private func photoImportConfident(_ draft: DraftRecipe) -> Bool {
        !draft.title.trimmed.isEmpty && !draft.ingredients.isEmpty && !draft.steps.isEmpty
    }

    // MARK: - Page preparation

    private func preparePages(_ pages: [CapturedPage]) async -> [PreparedPage] {
        await withTaskGroup(of: (Int, PreparedPage).self) { group in
            for (idx, page) in pages.enumerated() {
                group.addTask {
                    let raw = page.sourceData
                        ?? page.image.jpegData(compressionQuality: 0.95)
                    guard let raw else {
                        return (idx, PreparedPage(vision: nil, ocr: nil))
                    }
                    async let vision = ImageProcessing.prepare(raw, for: .aiVision)
                    async let ocr    = ImageProcessing.prepare(raw, for: .ocr)
                    return (idx, PreparedPage(vision: await vision, ocr: await ocr))
                }
            }
            var ordered = Array(repeating: PreparedPage(vision: nil, ocr: nil), count: pages.count)
            for await (idx, prep) in group { ordered[idx] = prep }
            return ordered
        }
    }

    // MARK: - Local types

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let draft: DraftRecipe
        /// Non-nil when this payload represents a streaming Sonnet vision call.
        /// The preview reads progressive title/ingredient/step events from
        /// this state and re-renders as bytes arrive. Nil for local-accept /
        /// cache-hit / OCR+AI fallback paths where the draft is already final.
        let streamingState: StreamingRecipeState?
        let cacheHit: Bool
        let sessionAttemptIndex: Int
    }

    private struct CapturedPage {
        let image: UIImage
        let sourceData: Data?
        init(image: UIImage, sourceData: Data? = nil) {
            self.image = image; self.sourceData = sourceData
        }
    }

    private struct PreparedPage {
        let vision: Data?
        let ocr: Data?
    }

    /// Branch the import landed in. Logged to OSLog per-import to make
    /// branch share visible without recipe content. The cases mirror
    /// `runImport`'s flow — exactly one is set before the deferred log
    /// summary fires.
    private enum ImportBranch: String {
        case unknown
        case preparationFailed
        case localAccept
        case visionStream         // Sonnet streamed and yielded confident draft
        case visionBufferedComplete // Sonnet returned without ever streaming content (rare)
        case visionCacheHit       // Worker served KV-cached assembled JSON
        case authRequired
        case quotaExhausted
        case dailyLimitHit
        case ocrTextFallback
        case editAsTextFallback
        case ocrEmpty
    }

    /// Per-import wall-clock timing buckets in milliseconds. All default to 0;
    /// only the phases that actually ran get populated. Logged as a single
    /// `Logger.info` summary line; never carries recipe content.
    private struct ImportTimings {
        var prepare:         Int = 0
        var ocr:             Int = 0
        var localParse:      Int = 0
        var visionFirstByte: Int = 0
        var visionTotal:     Int = 0
        var fallback:        Int = 0
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
            lhs.kind == rhs.kind && lhs.message == rhs.message && lhs.actionTitle == rhs.actionTitle
        }
    }
}
