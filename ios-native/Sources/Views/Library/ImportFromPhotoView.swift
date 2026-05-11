import SwiftUI
import PhotosUI
import UIKit

/// Capture chooser for the photo-import path. Two entry points:
/// manual single-shot capture via `CameraCaptureView` (a wrapper
/// around `UIImagePickerController` with the system shutter +
/// confirm-or-retake screen), or one or more pictures from the
/// photo library via `PhotosPicker`.
///
/// On capture, the image runs through `RecipeOCRImporter.recognize`
/// (Vision text recognition + cleanup pipeline) and then through
/// `RecipeAIParser.parseBestOf` (LLM + regex best-of). On success
/// the parsed `DraftRecipe` surfaces in the read-only
/// `PhotoImportPreviewView`. On the partial-OCR fallback path
/// (text recognized but parser couldn't separate ingredients from
/// steps) we show a banner with a "Continue in text editor" handoff
/// — same `EditorCoordinator.startImportFromText(seedText:)`
/// pattern used elsewhere.
struct ImportFromPhotoView: View {
    /// Called by RootView with the saved `Recipe` after the user
    /// taps Save on the inner preview. RootView uses it to dismiss
    /// the editor sheet and push Detail via `libraryPath.append`
    /// after a brief delay (the share-recipient flow uses the same
    /// pattern, since pushing immediately races the sheet dismiss).
    /// Defaults to a no-op for previews / future call sites that
    /// don't want the navigation hand-off.
    var onSaved: (Recipe) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(EditorCoordinator.self) private var editor
    @Environment(AppearanceSettings.self) private var appearance

    @State private var showingScanner = false
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var ocrInProgress = false
    @State private var ocrPageStatus: String?
    @State private var preview: PreviewPayload?
    @State private var errorBanner: ErrorBanner?
    @State private var capturedPages: [CapturedPage] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                heroRow
                    .padding(.top, AppSpacing.md)
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
                tipRow
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
                onSaved: { savedRecipe in
                    // Photo preview saved & dismissed — hand the recipe
                    // up to RootView (which dismisses the editor sheet
                    // then pushes Detail via libraryPath.append after
                    // the animation), and collapse this sheet too.
                    onSaved(savedRecipe)
                    dismiss()
                },
                onSavedForEdit: { savedRecipe in
                    // Edit-tap takes the same persist path as Save so
                    // the user sees the standard post-save Library
                    // scroll + letter-magnify animation (no flicker
                    // of the photo-import camera/library buttons,
                    // which the previous "open editor with seed"
                    // path produced as a brief visible frame between
                    // the inner-preview dismiss and the editor sheet
                    // re-presenting). After the animation lands the
                    // user on Detail, we open the editor on top so
                    // they can fix OCR typos directly. The 1500ms
                    // delay covers `runPostSaveHighlight`'s 150 +
                    // 750 + 400 = 1300ms sequence plus a small
                    // buffer for the Detail push to settle.
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
            if ocrInProgress {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
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
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: ocrInProgress)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: errorBanner)
        .animation(.easeInOut(duration: 0.25), value: capturedPages.isEmpty)
        .onDisappear {
            editor.hasUnsavedChanges = false
        }
    }

    // MARK: - Subviews

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

    private var captureButtons: some View {
        VStack(spacing: AppSpacing.md) {
            // Primary — accent fill — for live capture. Only shown
            // when a camera is available; the simulator hides it
            // automatically. The system camera UI handles its own
            // permission prompt.
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

    private var capturedPagesView: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            // Thumbnail strip with page-number badges
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

            // Primary CTA
            Button {
                Haptics.impact(.medium)
                Task { await runOCR(on: capturedPages) }
            } label: {
                captureButtonLabel(
                    title: capturedPages.count == 1
                        ? "Process Recipe"
                        : "Process \(capturedPages.count) Pages",
                    subtitle: capturedPages.count == 1
                        ? "Extract and organize the recipe"
                        : "Combine and extract the full recipe",
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

    // MARK: - OCR runner

    @MainActor
    private func runOCR(on pages: [CapturedPage]) async {
        guard !pages.isEmpty else { return }
        ocrInProgress = true
        errorBanner = nil
        defer {
            ocrInProgress = false
            ocrPageStatus = nil
        }

        // 1. Prepare page bytes for OCR. Photo-library picks keep their
        // original bytes, avoiding a UIImage -> JPEG round-trip before
        // ImageIO resizes/orients for Vision. Camera captures still
        // arrive as UIImage, so those fall back to a one-time JPEG
        // encode here.
        var prepared: [Data] = []
        for (idx, page) in pages.enumerated() {
            ocrPageStatus = "Preparing page \(idx + 1) of \(pages.count)…"
            guard let raw = page.sourceData ?? page.image.jpegData(compressionQuality: 0.95),
                  let resized = await ImageProcessing.prepare(raw, for: .ocr)
            else { continue }
            prepared.append(resized)
        }
        guard !prepared.isEmpty else {
            errorBanner = ErrorBanner(
                kind: .error,
                message: "Couldn't read those photos. Try a different image.",
                actionTitle: nil,
                action: nil
            )
            return
        }

        // 2. OCR per page.
        ocrPageStatus = pages.count > 1
            ? "Reading text from \(pages.count) pages…"
            : "Reading text…"
        let text = await RecipeOCRImporter.recognize(prepared)
        guard !text.isEmpty else {
            errorBanner = ErrorBanner(
                kind: .error,
                message: "Couldn't read text from the image. Try better lighting or a closer angle, or pick a different photo.",
                actionTitle: nil,
                action: nil
            )
            return
        }

        // 3. AI parse (best-of LLM + regex). `parseBestOf` returns
        // nil only when *both* parsers produce nothing usable.
        ocrPageStatus = "Organizing your recipe…"
        let draft = await RecipeAIParser.parseBestOf(text, sourceUrl: nil)

        // 4. Stricter quality gate for the photo flow: title +
        // ingredients + steps. A photo preview that only got half
        // the recipe is more confusing than a soft fallback to the
        // text editor with the OCR text seeded.
        let hasTitle = !(draft?.title.trimmed.isEmpty ?? true)
        let hasIngredients = !(draft?.ingredients.isEmpty ?? true)
        let hasSteps = !(draft?.steps.isEmpty ?? true)
        let confident = hasTitle && hasIngredients && hasSteps

        if confident, let draft {
            capturedPages = []
            preview = PreviewPayload(draft: draft)
        } else {
            // Partial OCR — surface the text in the text editor so
            // the user can clean it up. The continue button hands
            // off via the EditorCoordinator (swaps the active sheet
            // from photo-import to text-import with the seed pre-
            // loaded; same pattern as the URL-importer's partial
            // path). The seed text is captured directly in the
            // closure so the action retains exactly the OCR result
            // surfaced in the banner.
            let seed = text
            errorBanner = ErrorBanner(
                kind: .warning,
                message: "We pulled the text but couldn't separate ingredients from steps. Try adding another page, or edit the text directly.",
                actionTitle: "Edit as text",
                action: {
                    Haptics.impact(.light)
                    editor.startImportFromText(seedText: seed)
                }
            )
        }
    }

    // MARK: - Local types

    /// Wraps the parsed draft so `.sheet(item:)` can drive
    /// presentation. `Identifiable` conformance via a fresh UUID per
    /// payload keeps SwiftUI from re-identifying the same draft on
    /// state churn.
    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let draft: DraftRecipe
    }

    private struct CapturedPage {
        let image: UIImage
        let sourceData: Data?

        init(image: UIImage, sourceData: Data? = nil) {
            self.image = image
            self.sourceData = sourceData
        }
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
