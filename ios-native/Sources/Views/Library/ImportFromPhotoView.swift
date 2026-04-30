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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                heroRow
                    .padding(.top, AppSpacing.md)
                captureButtons
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
                Button("Cancel") { dismiss() }
                    .foregroundStyle(appearance.accentColor)
                    .disabled(ocrInProgress)
            }
        }
        .fullScreenCover(isPresented: $showingScanner) {
            CameraCaptureView(
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
                maxSelectionCount: 5,
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
    private func runOCR(on images: [UIImage]) async {
        guard !images.isEmpty else { return }
        ocrInProgress = true
        errorBanner = nil
        defer {
            ocrInProgress = false
            ocrPageStatus = nil
            pickedItems = []
        }

        // 1. Encode each UIImage to Data + run through ImageProcessing.
        // Resize to the OCR target. It keeps more pixels and less JPEG
        // loss than saved gallery photos, which helps handwriting and
        // tiny fractions without storing a larger image anywhere.
        var prepared: [Data] = []
        for (idx, img) in images.enumerated() {
            ocrPageStatus = "Preparing page \(idx + 1) of \(images.count)…"
            guard let raw = img.jpegData(compressionQuality: 0.95),
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
        ocrPageStatus = images.count > 1
            ? "Reading text from \(images.count) pages…"
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
                message: "We pulled the text from your photo but couldn't tell ingredients from steps. Edit it as text?",
                actionTitle: "Continue in text editor",
                action: {
                    Haptics.impact(.light)
                    editor.startImportFromText(seedText: seed)
                }
            )
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

    // MARK: - Local types

    /// Wraps the parsed draft so `.sheet(item:)` can drive
    /// presentation. `Identifiable` conformance via a fresh UUID per
    /// payload keeps SwiftUI from re-identifying the same draft on
    /// state churn.
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
