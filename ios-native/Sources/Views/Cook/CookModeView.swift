import SwiftUI
import SwiftData
import UIKit
import AudioToolbox

struct CookModeView: View {
    let recipe: Recipe
    /// End the app-level cook session. Called from the close button,
    /// Mark-as-cooked, and the exit confirm dialog. The sheet is driven
    /// by `CookingSession.activeRecipe` at the RootView level, so we
    /// don't use `@Environment(\.dismiss)` — tearing down the session
    /// handles both dismissal and state cleanup in one place.
    let onClose: () -> Void

    @State private var phase: Phase
    @State private var currentServings: Int
    @State private var struckIngredients: Set<UUID> = []
    @State private var struckSteps: Set<UUID> = []

    @State private var timerEndsAt: Date?
    @State private var timerStepId: UUID?
    @State private var timerLabel = "cook"
    @State private var timerExpired = false
    @State private var now = Date()

    @State private var alarmTask: Task<Void, Never>?
    @State private var alarmPlayer = AlarmPlayer()
    @State private var liveActivity = TimerLiveActivityController()

    @State private var showingExitConfirm = false
    @State private var showingTimerSheet = false

    private enum Phase { case prep, cook }

    init(recipe: Recipe, onClose: @escaping () -> Void) {
        self.recipe = recipe
        self.onClose = onClose
        _phase = State(initialValue: recipe.ingredients.isEmpty ? .cook : .prep)
        _currentServings = State(initialValue: recipe.servings ?? 0)
    }

    // MARK: Derived

    private var sortedIngredients: [Ingredient] {
        recipe.ingredients.sorted { $0.order < $1.order }
    }
    private var sortedSteps: [RecipeStep] {
        recipe.steps.sorted { $0.order < $1.order }
    }
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
                startAlarm()
            } else {
                stopAlarm()
            }
        }
        .onDisappear {
            stopAlarm()
            // Tear down the Live Activity when the user leaves Cook Mode —
            // otherwise an orphan countdown keeps ticking in the Dynamic
            // Island with no corresponding in-app state.
            liveActivity.end()
            TimerNotifications.cancel()
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
                    TimerNotifications.cancel()
                    liveActivity.end()
                }
            )
        }
        .sheet(isPresented: $showingTimerSheet) {
            RunningTimerSheet(
                secondsLeft: secondsLeft,
                label: timerLabel,
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
                onClose()
            }
        } message: {
            Text("Record this as a time you cooked this recipe.")
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
                    .frame(width: 40, height: 40)
                    .background(AppColor.surface)
                    .clipShape(Circle())
            }

            Text(recipe.title)
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            LlamaMascot(size: 32)
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
                }
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                if trailingChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(AppColor.accent)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .background(AppColor.surface)
            .overlay(
                Capsule().stroke(AppColor.accent, lineWidth: 1.5)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
                                .stroke(struck ? AppColor.success : AppColor.accent, lineWidth: 2)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.sm)
                                        .fill(struck ? AppColor.success : AppColor.background)
                                )
                                .frame(width: 24, height: 24)
                            if struck {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
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
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func ingredientDisplay(_ ingredient: Ingredient) -> String {
        let scaled = Quantity.scale(ingredient.quantity, by: scaleFactor) ?? ingredient.quantity ?? ""
        let qty = Quantity.displayFormat(scaled)
        let unit = Plural.unit(ingredient.unit ?? "", for: scaled)
        let connector = (!unit.isEmpty && Plural.needsConnector(unit)) ? "of" : ""
        return [qty, unit, connector, ingredient.name]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
                                : (isCurrent ? AppColor.accent : AppColor.divider),
                            lineWidth: 2
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
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
                .overlay(Circle().stroke(struck ? AppColor.success : AppColor.accent, lineWidth: 2))
                .frame(width: 30, height: 30)
            if struck {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
            } else {
                Text("\(idx + 1)")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.accent)
                    .monospacedDigit()
            }
        }
    }

    private func timerStartChip(keyword: String, step: RecipeStep) -> some View {
        let seconds = timerSeconds(for: step)
        return Button {
            startTimer(stepId: step.id, label: keyword, durationSeconds: seconds)
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                Text("Start \(StringCase.capitalizeFirst(keyword)) timer (\(formatDuration(seconds)))")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(AppColor.accent)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(AppColor.background)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.accent, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
        .buttonStyle(.plain)
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
                    Text(formatClock(secondsLeft))
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
            .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Timer running, \(formatClock(secondsLeft)) left, tap to adjust or cancel")
    }

    private func formatClock(_ secs: Int) -> String {
        let m = secs / 60
        let s = secs % 60
        return String(format: "%d:%02d", m, s)
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
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                }
            } else {
                Button {
                    recipe.markCooked()
                    Haptics.success()
                    onClose()
                } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                        Text("Mark as cooked")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(AppColor.success)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
                }
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
        let endsAt = Date().addingTimeInterval(durationSeconds)
        timerEndsAt = endsAt
        now = Date()
        Haptics.impact(.medium)
        TimerNotifications.schedule(endDate: endsAt, label: label)

        let stepNumber = (sortedSteps.firstIndex(where: { $0.id == stepId }) ?? 0) + 1
        liveActivity.end() // clear any lingering activity from a prior step
        liveActivity.start(
            recipeTitle: recipe.title,
            endDate: endsAt,
            label: label,
            stepNumber: stepNumber
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
        TimerNotifications.cancel()
        liveActivity.end()
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
        // Reschedule the background notification + Live Activity to match
        // the new end time.
        if let end = timerEndsAt {
            TimerNotifications.schedule(endDate: end, label: timerLabel)
            let stepNumber = timerStepId
                .flatMap { id in sortedSteps.firstIndex(where: { $0.id == id }) }
                .map { $0 + 1 } ?? 0
            liveActivity.update(endDate: end, label: timerLabel, stepNumber: stepNumber)
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

    private func startAlarm() {
        alarmPlayer.start()
        alarmTask?.cancel()
        alarmTask = Task { @MainActor in
            while !Task.isCancelled {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                Haptics.warning()
                try? await Task.sleep(for: .milliseconds(1200))
            }
        }
    }

    private func stopAlarm() {
        alarmPlayer.stop()
        alarmTask?.cancel()
        alarmTask = nil
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
    /// When multiple times appear ("stir 30 sec then bake 10 min"), the
    /// longest wins — usually the main cooking action, not the prep beat.
    static func extractDurationSeconds(_ text: String) -> Int? {
        let pattern = #/(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b/#
        let lower = text.lowercased()
        var maxSeconds: Double = 0
        for match in lower.matches(of: pattern) {
            guard let value = Double(match.output.1) else { continue }
            let unit = String(match.output.2)
            let seconds: Double
            switch unit {
            case "hour", "hours", "hr", "hrs":
                seconds = value * 3600
            case "minute", "minutes", "min", "mins":
                seconds = value * 60
            case "second", "seconds", "sec", "secs":
                seconds = value
            default:
                continue
            }
            if seconds > maxSeconds { maxSeconds = seconds }
        }
        return maxSeconds > 0 ? Int(maxSeconds.rounded()) : nil
    }
}

// MARK: - Timer-ready full-screen overlay

private struct TimerReadyOverlay: View {
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
                        .stroke(Color(red: 1, green: 0.992, blue: 0.972), lineWidth: 3)
                        .frame(width: 112, height: 112)
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                }
                Text("\(StringCase.capitalizeFirst(label)) timer ready!")
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                    .multilineTextAlignment(.center)
                Text("Check on your food — time's up.")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972).opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: AppSpacing.lg)

            VStack(spacing: AppSpacing.sm) {
                Text("Need more time?")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972).opacity(0.85))

                MinutePicker(selection: $extendMinutes, tint: Color(red: 1, green: 0.992, blue: 0.972))
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
                    .foregroundStyle(AppColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md)
                    .background(Color(red: 1, green: 0.992, blue: 0.972))
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
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.md + 2)
                    .overlay(
                        Capsule().stroke(Color(red: 1, green: 0.992, blue: 0.972), lineWidth: 2)
                    )
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.accent.ignoresSafeArea())
    }
}

// MARK: - Running-timer adjust sheet

private struct RunningTimerSheet: View {
    let secondsLeft: Int
    let label: String
    let onExtend: (Int) -> Void
    let onCancel: () -> Void

    @State private var extendMinutes: Int = 5

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            VStack(spacing: AppSpacing.xs) {
                Text("\(StringCase.capitalizeFirst(label)) timer")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(AppColor.textSecondary)
                Text(formatClock(secondsLeft))
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.accent)
                    .monospacedDigit()
            }
            .padding(.top, AppSpacing.md)

            VStack(spacing: AppSpacing.sm) {
                Text("Adjust time")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)

                MinutePicker(selection: $extendMinutes, tint: AppColor.textPrimary)
                    .frame(height: 120)

                HStack(spacing: AppSpacing.sm) {
                    Button {
                        onExtend(-extendMinutes)
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "minus")
                                .font(.system(size: 14, weight: .bold))
                            Text("\(extendMinutes) min")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(AppColor.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.md)
                        .background(AppColor.surface)
                        .overlay(Capsule().stroke(AppColor.accent, lineWidth: 1.5))
                        .clipShape(Capsule())
                    }

                    Button {
                        onExtend(extendMinutes)
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .bold))
                            Text("\(extendMinutes) min")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.md)
                        .background(AppColor.accent)
                        .clipShape(Capsule())
                    }
                }
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

    private func formatClock(_ secs: Int) -> String {
        let m = secs / 60
        let s = secs % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Scrollable minute picker

private struct MinutePicker: View {
    @Binding var selection: Int
    let tint: Color

    private let range: ClosedRange<Int> = 1...60

    var body: some View {
        Picker("Minutes", selection: $selection) {
            ForEach(range, id: \.self) { m in
                Text("\(m) min")
                    .foregroundStyle(tint)
                    .tag(m)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }
}
