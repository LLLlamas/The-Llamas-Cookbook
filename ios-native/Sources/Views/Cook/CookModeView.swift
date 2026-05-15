import SwiftUI
import SwiftData
import UIKit

struct CookModeView: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(CookingSession.self) private var session

    let recipe: Recipe
    /// Identity of the cook this view is rendering. Captured at init
    /// time from `CookingSession.foregroundedCookID` and stable for
    /// the view's lifetime — PR 2 will rebuild the view via `.id` on
    /// switcher changes, so each instance always represents one cook.
    /// Routed into every persisted `CookingSessionState` snapshot so
    /// the session's array can find-and-replace the right element.
    let cookID: UUID
    /// End the app-level cook session. Called from the close button,
    /// Mark-as-cooked, and the exit confirm dialog. The sheet is
    /// driven by `CookingSession.foregroundedCookID +
    /// isCookModeVisible` at the RootView level, so we don't use
    /// `@Environment(\.dismiss)` — tearing down the session handles
    /// both dismissal and state cleanup in one place.
    let onClose: () -> Void

    @State private var phase: Phase
    @State private var currentServings: Int
    @State private var struckIngredients: Set<UUID>
    @State private var struckSteps: Set<UUID>

    @State private var timerEndsAt: Date?
    @State private var timerStepId: UUID?
    @State private var timerLabel: String
    @State private var timerExpired: Bool
    @State private var now = Date()
    /// Length the timer was started with, in minutes. Drives the upper
    /// bound of the running-timer adjust picker so the user can subtract
    /// the full original duration even on long timers (>60 min).
    @State private var timerOriginalMinutes: Int

    @State private var showingExitConfirm = false
    @State private var showingTimerSheet = false
    /// Glow intensity for the recipe title (0…1). Spun up on every
    /// entry into Cook Mode (start, pill switch, restore) and faded
    /// back to 0, so the title softly highlights to greet the user.
    @State private var titleGlow: Double = 0
    /// Tapped step's photo bytes, wrapped so `.sheet(item:)` drives
    /// the viewer. Nil = no viewer; non-nil = present the read-only
    /// carousel with that step's photos.
    @State private var viewingStepImages: ViewingCookStepImages?

    private enum Phase { case prep, cook }

    init(
        recipe: Recipe,
        cookID: UUID,
        restoration: CookingSessionState? = nil,
        onClose: @escaping () -> Void
    ) {
        self.recipe = recipe
        self.cookID = cookID
        self.onClose = onClose

        if let r = restoration, r.recipeID == recipe.id {
            _phase = State(initialValue: r.phase == .cook ? .cook : .prep)
            _currentServings = State(initialValue: r.currentServings)
            _struckIngredients = State(initialValue: Set(r.struckIngredientIDs))
            _struckSteps = State(initialValue: Set(r.struckStepIDs))
            _timerLabel = State(initialValue: r.timerLabel)
            _timerOriginalMinutes = State(initialValue: r.timerOriginalMinutes)
            _timerStepId = State(initialValue: r.timerStepID)

            // Timer-while-killed: if the saved end date is already past,
            // surface the ready overlay on first render rather than ticking
            // toward a date that's already gone. The alarm doesn't auto-
            // restart (timerExpired starts true, so onChange won't fire)
            // — re-opening to a screaming app would be hostile.
            if let end = r.timerEndsAt, end <= Date() {
                _timerEndsAt = State(initialValue: nil)
                _timerExpired = State(initialValue: true)
            } else {
                _timerEndsAt = State(initialValue: r.timerEndsAt)
                _timerExpired = State(initialValue: false)
            }
        } else {
            _phase = State(initialValue: recipe.ingredients.isEmpty ? .cook : .prep)
            _currentServings = State(initialValue: recipe.servings ?? 0)
            _struckIngredients = State(initialValue: [])
            _struckSteps = State(initialValue: [])
            _timerEndsAt = State(initialValue: nil)
            _timerStepId = State(initialValue: nil)
            _timerLabel = State(initialValue: "cook")
            _timerExpired = State(initialValue: false)
            _timerOriginalMinutes = State(initialValue: 0)
        }
    }

    // MARK: Derived

    /// Recipe title with a `(N)` suffix when this exact recipe is being
    /// cooked more than once in parallel — keeps duplicate-recipe pills
    /// + headers visually distinguishable. Order matches `activeCooks`
    /// (earliest → 1, next → 2, …).
    private var displayTitle: String {
        let base = StringCase.titleCase(recipe.title)
        guard let n = session.duplicateIndex(for: cookID) else { return base }
        return "\(base) (\(n))"
    }

    private var sortedIngredients: [Ingredient] { recipe.sortedIngredients }
    private var sortedSteps: [RecipeStep] { recipe.sortedSteps }
    private var originalServings: Int { recipe.servings ?? 0 }
    private var canScale: Bool { originalServings > 0 }
    private var scaleFactor: Double {
        guard originalServings > 0, currentServings > 0 else { return 1 }
        return Double(currentServings) / Double(originalServings)
    }
    /// Default if the recipe didn't set Cook time but a step still wants a timer.
    /// User can extend on the fly via the running-timer sheet.
    private static let defaultTimerMinutes = 5

    private var cookMins: Int {
        let raw = recipe.cookTimeMinutes ?? 0
        return raw > 0 ? raw : Self.defaultTimerMinutes
    }
    /// Per-step timer is always available now — `cookMins` falls back to a
    /// default when `cookTimeMinutes` isn't set, so toggling the clock on a
    /// step always produces a usable timer.
    private var canTimer: Bool { true }

    private var currentStepId: UUID? {
        sortedSteps.first(where: { !struckSteps.contains($0.id) })?.id
    }

    private var secondsLeft: Int {
        guard let end = timerEndsAt else { return 0 }
        return max(0, Int(end.timeIntervalSince(now).rounded(.up)))
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .bottom) {
            AppColor.cookModeBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                phaseHeader

                if timerEndsAt != nil {
                    floatingTimerBar
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.bottom, AppSpacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ScrollView {
                    VStack(spacing: AppSpacing.md) {
                        if phase == .prep {
                            if canScale { scalerView }
                            if !sortedIngredients.isEmpty { ingredientList }
                        } else {
                            stepList
                        }
                    }
                    .padding(AppSpacing.lg)
                    .padding(.bottom, 120)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: timerEndsAt)

            bottomBar
        }
        .statusBarHidden(false)
        .navigationBarHidden(true)
        .task(id: timerEndsAt) { await tickTimer() }
        .onChange(of: timerExpired) { _, expired in
            if expired {
                showingTimerSheet = false
                // AlarmKit fires the alert (sound + haptic) on its own
                // in foreground and on the lock screen — we only flip
                // the in-app `TimerReadyOverlay` for visual feedback.
            }
        }
        // Persist on every meaningful change so a kill / crash / forced
        // relaunch from a Live Activity tap can resume here. `now` is
        // deliberately not in this list — it ticks every second and the
        // snapshot it would produce is identical to the previous one.
        .onChange(of: phase) { _, _ in persistSnapshot() }
        .onChange(of: currentServings) { _, _ in persistSnapshot() }
        .onChange(of: struckIngredients) { _, _ in persistSnapshot() }
        .onChange(of: struckSteps) { _, _ in persistSnapshot() }
        .onChange(of: timerEndsAt) { _, _ in persistSnapshot() }
        .onChange(of: timerStepId) { _, _ in persistSnapshot() }
        .onChange(of: timerLabel) { _, _ in persistSnapshot() }
        .onChange(of: timerOriginalMinutes) { _, _ in persistSnapshot() }
        .onAppear {
            // First-touch AlarmKit auth prompt — idempotent; iOS only
            // shows the dialog the first time. Cached after that, so
            // re-entering Cook Mode doesn't nag.
            TimerNotifications.requestPermission()
            // If the timer already expired while the app was killed
            // (timer-while-killed init path sets timerExpired = true
            // directly, so onChange never fires for that initial value),
            // cancel any leftover alarm so its alert doesn't fire on
            // top of the in-app ready overlay.
            if timerExpired {
                TimerNotifications.cancel(cookID: cookID)
            }
            // One-shot title glow on every entry — start, restore, and
            // pill-switch all rebuild this view via `.id(cookID)` so
            // the highlight plays cleanly on each foregrounding. Spin
            // up fast, hold briefly, then fade out softly.
            titleGlow = 0
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.45)) { titleGlow = 1 }
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeIn(duration: 0.85)) { titleGlow = 0 }
            }
            // Keep the screen awake while Cook Mode is foregrounded —
            // hands are usually wet, the user isn't tapping every few
            // seconds, and a screen lock mid-recipe means scrubbing
            // back to the right step. Reset on disappear so the
            // setting doesn't leak when the user minimizes / closes.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // Live Activity + notification cleanup is owned by
            // `CookingSession.remove(cookID:)` (and `endAll()`), so the
            // view doesn't need to detect "cook removed vs. just
            // minimized / switched" anymore. Minimize and pill-tap
            // switch leave the cook in `activeCooks`, the session
            // doesn't tear anything down, and the lock-screen widget
            // keeps ticking until the user explicitly stops/closes.
        }
        .fullScreenCover(isPresented: $timerExpired) {
            TimerReadyOverlay(
                label: timerLabel,
                onExtend: { minutes in extendTimer(by: minutes) },
                onStop: {
                    // Confirming Stop = confirming this step is done.
                    // That's why handleStepTap deliberately doesn't check
                    // the step off when starting the timer — it waits for
                    // this moment.
                    if let id = timerStepId {
                        struckSteps.insert(id)
                    }
                    timerStepId = nil
                    timerExpired = false
                    TimerNotifications.cancel(cookID: cookID)
                }
            )
        }
        .sheet(isPresented: $showingTimerSheet) {
            RunningTimerSheet(
                secondsLeft: secondsLeft,
                label: timerLabel,
                originalMinutes: timerOriginalMinutes,
                onExtend: { minutes in
                    extendTimer(by: minutes)
                    showingTimerSheet = false
                },
                onCancel: {
                    cancelTimer()
                    showingTimerSheet = false
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("Mark as cooked?", isPresented: $showingExitConfirm) {
            Button("Not this time", role: .cancel) { onClose() }
            Button("Mark cooked") {
                recipe.markCooked()
                // Cloud-side last-cooked update for the Profile screen
                // and the friends-list "Last cooked: …" line. Captured
                // by value so the Task body is Sendable around the
                // SwiftData @Model.
                let recipeID = recipe.id
                let recipeTitle = recipe.title
                Task { await UserProfileMirror.recordCookCompleted(recipeID: recipeID, recipeTitle: recipeTitle) }
                onClose()
            }
        } message: {
            Text("Record this as a time you cooked this recipe.")
        }
        // View-only carousel for tapped step photos. No closures =
        // PhotoCarouselView hides the Add and long-press-Delete
        // affordances, so this is a pure viewer in Cook Mode.
        // Captions render read-only beneath each photo when present.
        .sheet(item: $viewingStepImages) { wrapper in
            PhotoCarouselView(
                photoData: wrapper.images,
                captions: wrapper.captions
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: AppSpacing.md) {
            Button {
                handleExit()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .accentTextOutline()
                    .frame(width: 40, height: 40)
                    .background(AppColor.surface)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Exit cook mode")

            // Minimize: hide the cover but keep the timer + Live Activity
            // running. The user can resume from the Library's cooking
            // pill or by tapping the Live Activity.
            Button {
                Haptics.selection()
                session.minimize()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .accentTextOutline()
                    .frame(width: 40, height: 40)
                    .background(AppColor.surface)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Minimize cook mode")

            Text(displayTitle)
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(appearance.accentColor)
                .accentTextOutline()
                // Two stacked accent shadows scale from 0 → full radius
                // with `titleGlow`, producing a soft halo when the view
                // appears. The base contact shadow is still drawn last
                // so the title keeps its grounding regardless of glow.
                .shadow(color: appearance.accentColor.opacity(titleGlow * 0.32), radius: 7 * titleGlow)
                .shadow(color: appearance.accentColor.opacity(titleGlow * 0.18), radius: 13 * titleGlow)
                .shadow(color: AppColor.shadow, radius: 1.5, x: 0, y: 1)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            LlamaLogo(size: 72, shadowColor: appearance.accentColor)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    // MARK: Phase header

    private var phaseHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            phaseToggle
            Text(phase == .prep ? "Got everything?" : "Let's cook")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(AppColor.textPrimary)
            Text(phaseSubtitle)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.lg)
        .padding(.bottom, AppSpacing.md)
    }

    @ViewBuilder
    private var phaseToggle: some View {
        if phase == .cook, !sortedIngredients.isEmpty {
            phasePill(systemImage: "list.bullet", label: "Ingredients", trailingChevron: false) {
                Haptics.selection()
                phase = .prep
            }
        } else if phase == .prep, !sortedSteps.isEmpty {
            phasePill(systemImage: "fork.knife", label: "Jump to steps", trailingChevron: true) {
                Haptics.selection()
                phase = .cook
            }
        }
    }

    private func phasePill(systemImage: String, label: String, trailingChevron: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xs) {
                if !trailingChevron {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .accentTextOutline()
                }
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .accentTextOutline()
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .accentTextOutline()
                if trailingChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .accentTextOutline()
                }
            }
            .foregroundStyle(appearance.accentColor)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(AppColor.surface)
            .overlay(
                Capsule().stroke(appearance.accentColor, lineWidth: 1.5)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.lifted)
    }

    private var phaseSubtitle: String {
        if phase == .prep { return "Check off each ingredient as you line it up." }
        if sortedSteps.isEmpty { return "No steps listed — cook freestyle and mark it done when finished." }
        return "Tap each step as you finish it."
    }

    // MARK: Scaler

    private var scalerView: some View {
        HStack(spacing: AppSpacing.md) {
            scalerButton(systemName: "minus", disabled: currentServings <= 1) {
                if canScale {
                    currentServings = max(1, currentServings - 1)
                    Haptics.selection()
                }
            }
            VStack(spacing: 2) {
                Text("\(currentServings)")
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.textPrimary)
                    .monospacedDigit()
                Text(scalerLabel)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            scalerButton(systemName: "plus", disabled: currentServings >= 99) {
                if canScale {
                    currentServings = min(99, currentServings + 1)
                    Haptics.selection()
                }
            }
        }
        .padding(AppSpacing.md)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
    }

    private func scalerButton(systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(disabled ? AppColor.divider : AppColor.textPrimary)
                .frame(width: 44, height: 44)
                .background(AppColor.background)
                .clipShape(Circle())
        }
        .disabled(disabled)
    }

    private var scalerLabel: String {
        let plural = currentServings == 1 ? "" : "s"
        if scaleFactor == 1 { return "serving\(plural)" }
        let rounded = (scaleFactor * 100).rounded() / 100
        let factorText: String
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            factorText = "\(Int(rounded))"
        } else {
            factorText = String(format: "%.2g", rounded)
        }
        return "serving\(plural)  ·  \(factorText)x"
    }

    // MARK: Ingredients (prep phase)

    private var ingredientList: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(sortedIngredients) { ingredient in
                let struck = struckIngredients.contains(ingredient.id)
                Button {
                    toggleIngredient(ingredient.id)
                } label: {
                    HStack(spacing: AppSpacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppRadius.sm)
                                .stroke(struck ? AppColor.success : appearance.accentColor, lineWidth: 2)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.sm)
                                        .fill(struck ? AppColor.success : AppColor.background)
                                )
                                .frame(width: 24, height: 24)
                            if struck {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(AppColor.onAccent)
                            }
                        }
                        Text(ingredientDisplay(ingredient))
                            .font(AppFont.ingredientCook)
                            .foregroundStyle(struck ? AppColor.textSecondary : AppColor.textPrimary)
                            .strikethrough(struck)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(AppSpacing.md)
                    .background(struck ? AppColor.background : AppColor.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.md)
                            .stroke(struck ? AppColor.success : AppColor.divider, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                    .liftedCard()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func ingredientDisplay(_ ingredient: Ingredient) -> String {
        ingredient.display(scaledBy: scaleFactor).fullLine
    }

    // MARK: Steps (cook phase)

    private var stepList: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(Array(sortedSteps.enumerated()), id: \.element.id) { idx, step in
                let struck = struckSteps.contains(step.id)
                let isCurrent = step.id == currentStepId
                let label = Self.extractTimerKeyword(step.text) ?? "cook"
                let thisTiming = timerStepId == step.id && timerEndsAt != nil
                let anotherTiming = timerEndsAt != nil && timerStepId != step.id

                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        stepBadge(idx: idx, struck: struck)
                        Text(step.text)
                            .font(AppFont.ingredientCook)
                            .foregroundStyle(struck ? AppColor.textSecondary : AppColor.textPrimary)
                            .strikethrough(struck)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(AppSpacing.md)

                    let displayableStepPhotos = step.sortedStepPhotos.filter { $0.image != nil }
                    let stepPhotoBytes = displayableStepPhotos.compactMap(\.image)
                    let stepPhotoCaptions = displayableStepPhotos.map(\.caption)
                    if !stepPhotoBytes.isEmpty {
                        cookPhotosButton(bytes: stepPhotoBytes, captions: stepPhotoCaptions)
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.bottom, AppSpacing.md)
                    }

                    if let note = step.specialNote?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !note.isEmpty {
                        specialNoteCallout(note)
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.bottom, AppSpacing.md)
                    }

                    if step.needsTimer, canTimer, !thisTiming, !anotherTiming {
                        timerStartChip(keyword: label, step: step)
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.bottom, AppSpacing.md)
                    }
                }
                .background(struck ? AppColor.background : AppColor.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .stroke(
                            struck ? AppColor.success
                                : (isCurrent ? appearance.accentColor : AppColor.divider),
                            lineWidth: 2
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                .liftedCard()
                .contentShape(Rectangle())
                .onTapGesture {
                    handleStepTap(step)
                }
            }
        }
    }

    private func stepBadge(idx: Int, struck: Bool) -> some View {
        ZStack {
            Circle()
                .fill(struck ? AppColor.success : AppColor.background)
                .overlay(Circle().stroke(struck ? AppColor.success : appearance.accentColor, lineWidth: 2))
                .frame(width: 30, height: 30)
            if struck {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppColor.onAccent)
            } else {
                Text("\(idx + 1)")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(appearance.accentColor)
                    .accentTextOutline()
                    .monospacedDigit()
            }
        }
        .accentTextOutline()
    }

    /// Per-step photos affordance in Cook Mode. The image isn't
    /// rendered inline — the user explicitly asked for the photos to
    /// stay hidden until they tap the button. The button itself is
    /// only present when the step actually has photos; steps without
    /// photos render no extra chrome at all (no ghost button taking
    /// up vertical space). Tap opens the same view-only carousel
    /// Detail uses.
    private func cookPhotosButton(bytes: [Data], captions: [String?]) -> some View {
        Button {
            Haptics.selection()
            viewingStepImages = ViewingCookStepImages(images: bytes, captions: captions)
        } label: {
            HStack(spacing: AppSpacing.xs + 2) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .accentTextOutline()
                Text(bytes.count == 1 ? "View photo" : "View photos · \(bytes.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .accentTextOutline()
            }
            .foregroundStyle(appearance.accentColor)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 3)
            .background(AppColor.surface)
            .overlay(
                Capsule().stroke(appearance.accentColor.opacity(0.5), lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bytes.count == 1
            ? "View step photo"
            : "View \(bytes.count) step photos"
        )
    }

    /// Inline reminder rendered directly under a step whenever the user
    /// attached a `specialNote` in the editor. Lightbulb + tinted box use
    /// the user's accent so the same callout shape reads consistently
    /// from editor preview → detail view → cook mode.
    private func specialNoteCallout(_ note: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(appearance.accentColor)
                .accentTextOutline()
                .padding(.top, 2)
            Text(note)
                .font(.system(size: 15, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(AppColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(AppSpacing.sm + 2)
        .background(appearance.accentColor.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(appearance.accentColor.opacity(0.30), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func timerStartChip(keyword: String, step: RecipeStep) -> some View {
        let seconds = timerSeconds(for: step)
        return Button {
            startTimer(stepId: step.id, label: keyword, durationSeconds: seconds)
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .accentTextOutline()
                Text("Start \(StringCase.capitalizeFirst(keyword)) Timer (\(formatDuration(seconds)))")
                    .font(.system(size: 14, weight: .semibold))
                    .accentTextOutline()
            }
            .foregroundStyle(appearance.accentColor)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(AppColor.background)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(appearance.accentColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .accentTextOutline()
        }
        .buttonStyle(.lifted)
    }

    private var floatingTimerBar: some View {
        let stepIndex = sortedSteps.firstIndex(where: { $0.id == timerStepId }).map { $0 + 1 }
        let title = stepIndex.map { "Step \($0) · \(StringCase.capitalizeFirst(timerLabel))" }
            ?? "\(StringCase.capitalizeFirst(timerLabel)) timer"

        return Button {
            Haptics.selection()
            showingTimerSheet = true
        } label: {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "timer")
                    .font(.system(size: 22, weight: .bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.9)
                    Text(ClockFormat.mmss(secondsLeft))
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .monospacedDigit()
                }
                Spacer()
                HStack(spacing: 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("adjust")
                        .font(.system(size: 11, weight: .semibold))
                }
                .opacity(0.9)
            }
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(appearance.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.lifted)
        .accessibilityLabel("Timer running, \(ClockFormat.mmss(secondsLeft)) left, tap to adjust or cancel")
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack {
            if phase == .prep, !sortedSteps.isEmpty {
                Button {
                    phase = .cook
                    Haptics.impact(.light)
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Text(startCookingLabel)
                            .font(.system(size: 17, weight: .semibold))
                            .accentTextOutline()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .bold))
                            .accentTextOutline()
                    }
                    .foregroundStyle(AppColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(appearance.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(.lifted)
            } else {
                Button {
                    recipe.markCooked()
                    Haptics.success()
                    // Cloud-side last-cooked update — same pattern as
                    // the Mark-cooked alert path above. Capture by
                    // value for Sendable.
                    let recipeID = recipe.id
                    let recipeTitle = recipe.title
                    Task { await UserProfileMirror.recordCookCompleted(recipeID: recipeID, recipeTitle: recipeTitle) }
                    onClose()
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                        Text("Mark as cooked")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(AppColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColor.success)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                }
                .buttonStyle(.lifted)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(AppColor.cookModeBackground.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(AppColor.divider).frame(height: 1)
        }
    }

    private var startCookingLabel: String {
        let ready = struckIngredients.count
        let total = sortedIngredients.count
        if total > 0 {
            return "Start cooking  ·  \(ready)/\(total)"
        }
        return "Start cooking"
    }

    // MARK: Actions

    /// Write the current cook progress through the session. Cheap
    /// (UserDefaults + JSON encode of a small struct) so we can call
    /// it on every meaningful state change without worrying about
    /// cost. Routes through `CookingSession.persistForegroundedSnapshot`
    /// so the session's in-memory `activeCooks` array stays in sync
    /// with disk — PR 2's switcher reads from that array, not from
    /// disk on every render.
    private func persistSnapshot() {
        let snapshot = CookingSessionState(
            cookID: cookID,
            recipeID: recipe.id,
            phase: phase == .cook ? .cook : .prep,
            currentServings: currentServings,
            struckIngredientIDs: Array(struckIngredients),
            struckStepIDs: Array(struckSteps),
            timerEndsAt: timerEndsAt,
            timerStepID: timerStepId,
            timerLabel: timerLabel,
            timerOriginalMinutes: timerOriginalMinutes
        )
        session.persistForegroundedSnapshot(snapshot)
    }

    private func handleExit() {
        let didAnything = !struckIngredients.isEmpty || !struckSteps.isEmpty
        if didAnything {
            showingExitConfirm = true
        } else {
            onClose()
        }
    }

    private func toggleIngredient(_ id: UUID) {
        Haptics.selection()
        if struckIngredients.contains(id) {
            struckIngredients.remove(id)
        } else {
            struckIngredients.insert(id)
        }
    }

    /// Tap handler for a step in the cook-phase list. The rule:
    /// - Already struck → always un-strike. Easy undo.
    /// - Needs a timer and no timer running → start the timer.
    ///   The step stays unchecked; check-off waits for Stop on the ready
    ///   overlay, so users don't get "done" early by tapping to kick off a
    ///   countdown.
    /// - This step's timer is running → open the adjust sheet (same as
    ///   tapping the floating banner).
    /// - Anything else → strike the step.
    private func handleStepTap(_ step: RecipeStep) {
        Haptics.selection()

        if struckSteps.contains(step.id) {
            struckSteps.remove(step.id)
            return
        }

        if step.needsTimer, canTimer, timerEndsAt == nil {
            let label = Self.extractTimerKeyword(step.text) ?? "cook"
            startTimer(stepId: step.id, label: label, durationSeconds: timerSeconds(for: step))
            return
        }

        if step.needsTimer, timerStepId == step.id, timerEndsAt != nil {
            showingTimerSheet = true
            return
        }

        struckSteps.insert(step.id)
    }

    private func startTimer(stepId: UUID, label: String, durationSeconds: TimeInterval) {
        timerStepId = stepId
        timerLabel = label
        timerOriginalMinutes = Int((durationSeconds / 60).rounded(.up))
        let endsAt = Date().addingTimeInterval(durationSeconds)
        timerEndsAt = endsAt
        now = Date()
        Haptics.impact(.medium)

        let stepNumber = (sortedSteps.firstIndex(where: { $0.id == stepId }) ?? 0) + 1
        let stepText = sortedSteps.first(where: { $0.id == stepId })?.text
        // AlarmKit owns both the lock-screen alert and the Live
        // Activity countdown — one schedule call handles both.
        TimerNotifications.schedule(
            cookID: cookID,
            endDate: endsAt,
            label: label,
            recipeID: recipe.id,
            recipeTitle: recipe.title,
            stepNumber: stepNumber,
            stepText: stepText
        )
    }

    /// Initial timer duration for a step. Priority:
    /// 1. Time mention in the step text ("…for 10 mins", "…30 sec")
    /// 2. Recipe-level `cookTimeMinutes`
    /// 3. Hard fallback (5 min)
    /// User can always extend via the running-timer sheet from there.
    private func timerSeconds(for step: RecipeStep) -> TimeInterval {
        if let parsed = Self.extractDurationSeconds(step.text), parsed > 0 {
            return TimeInterval(parsed)
        }
        if let recipeMins = recipe.cookTimeMinutes, recipeMins > 0 {
            return TimeInterval(recipeMins * 60)
        }
        return TimeInterval(Self.defaultTimerMinutes * 60)
    }

    /// Render seconds as "5 min", "30 sec", "1 min 15 sec" — for chip labels.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) sec" }
        let mins = total / 60
        let rem = total % 60
        if rem == 0 { return "\(mins) min" }
        return "\(mins) min \(rem) sec"
    }

    private func cancelTimer() {
        timerEndsAt = nil
        timerStepId = nil
        TimerNotifications.cancel(cookID: cookID)
    }

    /// Shift the current timer by `minutes` — positive extends, negative
    /// subtracts. If the timer already expired, only positive values
    /// restart a fresh countdown (can't subtract time from nothing).
    /// Subtraction is clamped so the timer can't be pushed into the past
    /// and trigger the ready overlay unintentionally.
    private func extendTimer(by minutes: Int) {
        guard minutes != 0 else { return }
        let delta = TimeInterval(minutes * 60)
        if let end = timerEndsAt {
            let proposed = end.addingTimeInterval(delta)
            timerEndsAt = max(proposed, Date().addingTimeInterval(1))
        } else if minutes > 0 {
            timerEndsAt = Date().addingTimeInterval(delta)
        }
        now = Date()
        timerExpired = false
        Haptics.impact(.medium)
        // Reschedule the AlarmKit alarm to match the new end time.
        // `schedule(...)` cancels the existing alarm under this cookID
        // first, so the rewrite covers both the lock-screen alert and
        // the Live Activity countdown.
        if let end = timerEndsAt {
            let stepNumber = timerStepId
                .flatMap { id in sortedSteps.firstIndex(where: { $0.id == id }) }
                .map { $0 + 1 } ?? 0
            let stepText = timerStepId.flatMap { id in
                sortedSteps.first(where: { $0.id == id })?.text
            }
            TimerNotifications.schedule(
                cookID: cookID,
                endDate: end,
                label: timerLabel,
                recipeID: recipe.id,
                recipeTitle: recipe.title,
                stepNumber: stepNumber,
                stepText: stepText
            )
        }
    }

    // Timer ticker — runs while timerEndsAt is set, updates `now` every second.
    private func tickTimer() async {
        while let end = timerEndsAt, Date() < end {
            try? await Task.sleep(for: .seconds(1))
            now = Date()
        }
        // Expired. Keep timerStepId around so a subsequent Extend stays tied
        // to the step that triggered the timer — Stop clears it explicitly.
        if timerEndsAt != nil {
            timerEndsAt = nil
            timerExpired = true
        }
    }

    // MARK: Timer keyword detection

    private static let timerKeywords = [
        "oven", "bake", "grill", "skillet", "stove", "pan", "pot", "simmer", "boil"
    ]

    static func extractTimerKeyword(_ text: String) -> String? {
        let lower = text.lowercased()
        for kw in timerKeywords where lower.contains(kw) {
            return kw
        }
        return nil
    }

    /// Pull the most prominent duration out of step text.
    /// Matches `<number><opt. space><unit>` where unit is one of:
    /// hour(s)/hr(s), minute(s)/min(s), second(s)/sec(s).
    /// Single-letter aliases (h/m/s) intentionally excluded — they false-match
    /// too easily inside ordinary words.
    ///
    /// Range handling: `"3-4 hours"` / `"30 to 45 minutes"` resolve to the
    /// **smaller** number (3 hours, 30 min). Rationale: the user can extend
    /// the running timer if they need more, but they can't take time back
    /// once it's elapsed past the food's done point.
    ///
    /// When multiple separate times appear ("stir 30 sec then bake 10 min"),
    /// the longest wins — usually the main cooking action, not the prep beat.
    static func extractDurationSeconds(_ text: String) -> Int? {
        let rangePattern = #/(\d+(?:\.\d+)?)\s*(?:[-–—]|to)\s*(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b/#
        let singlePattern = #/(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b/#
        let lower = text.lowercased()

        // Pass 1: ranges. Use the smaller endpoint and remember the byte
        // ranges we've consumed so the single-pattern pass below doesn't
        // re-count the upper endpoint as its own duration ("3-4 hours" =>
        // 3 hours total, not max(3 hours, 4 hours)).
        var maxSeconds: Double = 0
        var consumed: [Range<String.Index>] = []
        for match in lower.matches(of: rangePattern) {
            guard let lo = Double(match.output.1),
                  let hi = Double(match.output.2)
            else { continue }
            let unit = String(match.output.3)
            let smaller = min(lo, hi)
            let seconds = secondsFor(value: smaller, unit: unit)
            if seconds > maxSeconds { maxSeconds = seconds }
            consumed.append(match.range)
        }

        // Pass 2: standalone durations not already swallowed by a range.
        for match in lower.matches(of: singlePattern) {
            if consumed.contains(where: { $0.overlaps(match.range) }) { continue }
            guard let value = Double(match.output.1) else { continue }
            let unit = String(match.output.2)
            let seconds = secondsFor(value: value, unit: unit)
            if seconds > maxSeconds { maxSeconds = seconds }
        }

        return maxSeconds > 0 ? Int(maxSeconds.rounded()) : nil
    }

    private static func secondsFor(value: Double, unit: String) -> Double {
        switch unit {
        case "hour", "hours", "hr", "hrs": return value * 3600
        case "minute", "minutes", "min", "mins": return value * 60
        case "second", "seconds", "sec", "secs": return value
        default: return 0
        }
    }
}

/// Wrapper so `.sheet(item:)` can drive the step-photos viewer with
/// arbitrary byte arrays. `[Data]` itself isn't `Identifiable`; the
/// wrapper supplies the required id. File-private — same shape as
/// `RecipeDetailView.ViewingStepImages`, kept separate to avoid
/// cross-file coupling for one trivial type.
private struct ViewingCookStepImages: Identifiable {
    let id = UUID()
    let images: [Data]
    let captions: [String?]
}

// MARK: - Timer-ready full-screen overlay

private struct TimerReadyOverlay: View {
    @Environment(AppearanceSettings.self) private var appearance
    let label: String
    let onExtend: (Int) -> Void
    let onStop: () -> Void

    @State private var extendMinutes: Int = 5

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: AppSpacing.xl)
            VStack(spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .stroke(AppColor.onAccent, lineWidth: 3)
                        .frame(width: 112, height: 112)
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(AppColor.onAccent)
                }
                Text("\(StringCase.capitalizeFirst(label)) timer ready!")
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.onAccent)
                    .multilineTextAlignment(.center)
                Text("Check on your food — time's up.")
                    .font(.system(size: 17))
                    .foregroundStyle(AppColor.onAccent.opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: AppSpacing.lg)

            VStack(spacing: AppSpacing.sm) {
                Text("Need more time?")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(AppColor.onAccent.opacity(0.85))

                MinutePicker(selection: $extendMinutes, tint: AppColor.onAccent)
                    .frame(height: 120)

                Button {
                    Haptics.impact(.medium)
                    onExtend(extendMinutes)
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                        Text("Extend by \(extendMinutes) min")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(appearance.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColor.onAccent)
                    .clipShape(Capsule())
                }
            }
            .padding(AppSpacing.lg)
            .background(Color.black.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
            .padding(.horizontal, AppSpacing.lg)

            Spacer(minLength: AppSpacing.md)

            Button {
                Haptics.impact(.heavy)
                onStop()
            } label: {
                Text("Stop")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md + 2)
                    .overlay(
                        Capsule().stroke(AppColor.onAccent, lineWidth: 2)
                    )
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appearance.accentColor.ignoresSafeArea())
    }
}

// MARK: - Running-timer adjust sheet

private struct RunningTimerSheet: View {
    @Environment(AppearanceSettings.self) private var appearance
    let secondsLeft: Int
    let label: String
    /// Length the timer was started with, in minutes. Stretches the
    /// picker's upper bound so the user can subtract the full timer
    /// duration in one shot on longer timers (>60 min).
    let originalMinutes: Int
    let onExtend: (Int) -> Void
    let onCancel: () -> Void

    @State private var extendMinutes: Int = 5

    /// Upper bound — at least 60 to keep the dial useful for short timers;
    /// stretches to `originalMinutes` for longer originals (90-min bread)
    /// so the user can dial in big extensions in one move.
    private var pickerMax: Int { max(60, originalMinutes) }

    /// Lower bound — capped at how much time is actually left so the user
    /// can scroll right down to "stop now" but not into negative territory.
    /// `extendTimer(by:)` clamps too, but bounding the wheel itself keeps
    /// the displayed selection honest. Round up so a 4:30 remaining timer
    /// still offers -5 (i.e., "zero out").
    private var pickerMin: Int {
        guard secondsLeft > 0 else { return -1 }
        return -Int(ceil(Double(secondsLeft) / 60.0))
    }

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            VStack(spacing: AppSpacing.xs) {
                Text("\(StringCase.capitalizeFirst(label)) timer")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(AppColor.textSecondary)
                Text(ClockFormat.mmss(secondsLeft))
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .foregroundStyle(appearance.accentColor)
                    .accentTextOutline()
                    .monospacedDigit()
            }
            .padding(.top, AppSpacing.md)

            VStack(spacing: AppSpacing.sm) {
                Text("Adjust time")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)

                MinutePicker(
                    selection: $extendMinutes,
                    tint: AppColor.textPrimary,
                    range: pickerMin...pickerMax
                )
                .frame(height: 120)

                Button {
                    onExtend(extendMinutes)
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: extendMinutes < 0 ? "minus" : "plus")
                            .font(.system(size: 14, weight: .bold))
                        Text("\(abs(extendMinutes)) min")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(AppColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(appearance.accentColor)
                    .clipShape(Capsule())
                }
                .disabled(extendMinutes == 0)
            }

            Button(role: .destructive) {
                Haptics.impact(.light)
                onCancel()
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Cancel timer")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(AppColor.destructive)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.sm + 2)
                .overlay(
                    Capsule().stroke(AppColor.destructive, lineWidth: 1)
                )
            }

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.lg)
        .background(AppColor.background)
    }
}

// MARK: - Scrollable minute picker

private struct MinutePicker: View {
    @Binding var selection: Int
    let tint: Color
    /// Inclusive range of selectable minute values. Defaults to `1...60`
    /// for the post-expiry extend overlay where there's no original
    /// duration to scale from. The running-timer adjust sheet passes a
    /// signed range so the user can scroll to a negative value to
    /// subtract instead of needing a separate minus button.
    var range: ClosedRange<Int> = 1...60

    var body: some View {
        Picker("Minutes", selection: $selection) {
            ForEach(Array(range), id: \.self) { m in
                Text(label(for: m))
                    .foregroundStyle(tint)
                    .tag(m)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }

    private func label(for m: Int) -> String {
        // Only prefix "+" when the wheel can also reach negatives — keeps
        // the post-expiry overlay (positive-only) reading "5 min" while
        // the running-timer sheet's signed wheel reads "+5 min" / "-5 min".
        let showSign = range.lowerBound < 0
        if m < 0 { return "\(m) min" }
        if m == 0 { return "0 min" }
        return showSign ? "+\(m) min" : "\(m) min"
    }
}
