import SwiftUI
import SwiftData
import UIKit
import AudioToolbox

struct CookModeView: View {
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

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

    @State private var showingExitConfirm = false

    private enum Phase { case prep, cook }

    init(recipe: Recipe) {
        self.recipe = recipe
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
    private var cookMins: Int {
        recipe.cookTimeMinutes ?? 0
    }
    private var canTimer: Bool { cookMins > 0 }

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
            if expired { startAlarm() } else { stopAlarm() }
        }
        .onDisappear { stopAlarm() }
        .fullScreenCover(isPresented: $timerExpired) {
            TimerReadyOverlay(label: timerLabel) {
                timerExpired = false
            }
        }
        .alert("Mark as cooked?", isPresented: $showingExitConfirm) {
            Button("Not this time", role: .cancel) { dismiss() }
            Button("Mark cooked") {
                recipe.markCooked()
                dismiss()
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
        return [qty, unit, ingredient.name]
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
                    Button {
                        toggleStep(step.id)
                    } label: {
                        HStack(alignment: .top, spacing: AppSpacing.md) {
                            stepBadge(idx: idx, struck: struck)
                            Text(step.text)
                                .font(AppFont.ingredientCook)
                                .foregroundStyle(struck ? AppColor.textSecondary : AppColor.textPrimary)
                                .strikethrough(struck)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(AppSpacing.md)
                    }
                    .buttonStyle(.plain)

                    if step.needsTimer, canTimer, !thisTiming, !anotherTiming {
                        timerStartChip(keyword: label, stepId: step.id)
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

    private func timerStartChip(keyword: String, stepId: UUID) -> some View {
        Button {
            startTimer(stepId: stepId, label: keyword)
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                Text("Start \(StringCase.capitalizeFirst(keyword)) timer (\(cookMins) min)")
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
            Haptics.impact(.light)
            cancelTimer()
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
                Text("tap to cancel")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.85)
            }
            .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Timer running, \(formatClock(secondsLeft)) left, tap to cancel")
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
                    dismiss()
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
            dismiss()
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

    private func toggleStep(_ id: UUID) {
        Haptics.selection()
        let wasStruck = struckSteps.contains(id)
        if wasStruck {
            struckSteps.remove(id)
        } else {
            struckSteps.insert(id)
        }
        if !wasStruck, canTimer, timerEndsAt == nil,
           let step = sortedSteps.first(where: { $0.id == id }),
           step.needsTimer {
            let label = Self.extractTimerKeyword(step.text) ?? "cook"
            startTimer(stepId: id, label: label)
        }
    }

    private func startTimer(stepId: UUID, label: String) {
        guard canTimer else { return }
        timerStepId = stepId
        timerLabel = label
        timerEndsAt = Date().addingTimeInterval(TimeInterval(cookMins * 60))
        now = Date()
        Haptics.impact(.medium)
    }

    private func cancelTimer() {
        timerEndsAt = nil
        timerStepId = nil
    }

    // Timer ticker — runs while timerEndsAt is set, updates `now` every second.
    private func tickTimer() async {
        while let end = timerEndsAt, Date() < end {
            try? await Task.sleep(for: .seconds(1))
            now = Date()
        }
        // Expired
        if timerEndsAt != nil {
            timerEndsAt = nil
            timerStepId = nil
            timerExpired = true
        }
    }

    private func startAlarm() {
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
}

// MARK: - Timer-ready full-screen overlay

private struct TimerReadyOverlay: View {
    let label: String
    let onStop: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: AppSpacing.lg) {
                ZStack {
                    Circle()
                        .stroke(Color(red: 1, green: 0.992, blue: 0.972), lineWidth: 3)
                        .frame(width: 128, height: 128)
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                }
                Text("\(StringCase.capitalizeFirst(label)) timer ready!")
                    .font(.system(size: 36, weight: .bold, design: .serif))
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
                    .multilineTextAlignment(.center)
                Text("Check on your food — time's up.")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972).opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button {
                Haptics.impact(.heavy)
                onStop()
            } label: {
                Text("Stop")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(AppColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.lg)
                    .background(Color(red: 1, green: 0.992, blue: 0.972))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.accent.ignoresSafeArea())
    }
}
