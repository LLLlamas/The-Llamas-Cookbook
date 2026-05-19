import SwiftUI

/// Vertical A–Z strip used by alphabetically-sorted lists. Renders the
/// whole alphabet (+ `#`) for a consistent full look; letters that
/// match at least one item in `populated` are fully opaque, the rest
/// dimmed. Tap or drag to scrub through letters — while scrubbing, a
/// magnified accent-tinted badge floats just to the left of the strip
/// showing the current letter at a clearly readable size.
///
/// Originally lived inside `LibraryView`. Lifted here so the new
/// Friends list in `ProfileView` can reuse the exact same scrub
/// behavior — both lists are sort-by-display-name surfaces and the
/// component is generic enough to handle any string-keyed list.
struct LetterIndex: View {
    let letters: [String]
    let populated: Set<String>
    let accent: Color
    let glowActive: Bool
    /// Letter to flash the magnify badge on when no scrub gesture is
    /// active — driven by external highlight signals (e.g. RootView's
    /// post-save library highlight). `nil` at all other times.
    let externalHighlightLetter: String?
    /// Section letter of the topmost visible row while the user is
    /// FREE-SCROLLING the list (no scrubber touch). Each change pulses
    /// the compact magnify badge — a quick fade-in / brief hold /
    /// fade-out — synced one-to-one with the scroll-haptic tick. A
    /// separate channel from `externalHighlightLetter` so the transient
    /// scroll pulse and the persistent post-save flash never clobber
    /// each other; the scrubber drag and post-save flash both outrank
    /// it (see `displayedActiveIndex` / `pulseIsVisible`). `nil` when
    /// the list isn't being free-scrolled.
    let scrollFocusLetter: String?
    let onSelect: (String) -> Void

    @State private var activeIndex: Int? = nil
    /// Holds the letter during fade-out after `externalHighlightLetter`
    /// clears, keeping the badge in the view tree while opacity → 0.
    @State private var fadingHighlightLetter: String? = nil
    @State private var highlightBadgeOpacity: Double = 1.0

    /// Letter currently rendered by the free-scroll pulse, including its
    /// fade-out tail. Distinct from `scrollFocusLetter` so the badge
    /// survives in the view tree while animating to opacity 0.
    @State private var pulseLetter: String? = nil
    @State private var pulseOpacity: Double = 0
    /// Generation token — each new crossing bumps it so a stale
    /// fade-out task can't dismiss a fresher pulse.
    @State private var pulseGeneration = 0

    init(
        letters: [String],
        populated: Set<String>,
        accent: Color,
        glowActive: Bool = false,
        externalHighlightLetter: String?,
        scrollFocusLetter: String? = nil,
        onSelect: @escaping (String) -> Void
    ) {
        self.letters = letters
        self.populated = populated
        self.accent = accent
        self.glowActive = glowActive
        self.externalHighlightLetter = externalHighlightLetter
        self.scrollFocusLetter = scrollFocusLetter
        self.onSelect = onSelect
    }

    private let rowHeight: CGFloat = 11
    private let stripWidth: CGFloat = 14
    private let verticalPadding: CGFloat = 4
    /// Compact badge for regular drag-scrub — clearly readable without
    /// dominating the screen.
    private let defaultBadgeSize: CGFloat = 80
    private let defaultBadgeFontSize: CGFloat = 44
    /// Large badge reserved for the post-save library-scroll animation —
    /// needs to register instantly in the ~750ms before Detail covers the
    /// screen. Big enough to read from a glance, still within the narrowest
    /// iPhone screen minus strip and edge padding.
    private let highlightBadgeSize: CGFloat = 132
    private let highlightBadgeFontSize: CGFloat = 72

    /// True when the badge is showing due to the external post-save signal
    /// (including while it is fading out).
    private var isExternalHighlight: Bool {
        activeIndex == nil && (externalHighlightLetter != nil || fadingHighlightLetter != nil)
    }

    private var currentBadgeSize: CGFloat {
        isExternalHighlight ? highlightBadgeSize : defaultBadgeSize
    }

    private var currentBadgeFontSize: CGFloat {
        isExternalHighlight ? highlightBadgeFontSize : defaultBadgeFontSize
    }

    /// Index that should currently render as "active" — gesture-driven
    /// scrub wins (so post-save highlight never fights the user), with
    /// the external highlight (or its fading echo) as the fallback.
    private var displayedActiveIndex: Int? {
        if let activeIndex { return activeIndex }
        let letter = externalHighlightLetter ?? fadingHighlightLetter
        if let letter, let idx = letters.firstIndex(of: letter) {
            return idx
        }
        return nil
    }

    /// The free-scroll pulse only shows when neither the scrubber drag
    /// nor the post-save flash owns the badge — those two outrank it,
    /// so the transient scroll feedback never fights a deliberate
    /// gesture or the louder post-save animation.
    private var pulseIndex: Int? {
        guard activeIndex == nil,
              externalHighlightLetter == nil,
              fadingHighlightLetter == nil,
              let letter = pulseLetter
        else { return nil }
        return letters.firstIndex(of: letter)
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            strip
            Spacer(minLength: 0)
        }
    }

    private var strip: some View {
        VStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.element) { index, letter in
                Text(letter)
                    .font(.system(size: 9, weight: .bold, design: .serif))
                    .foregroundStyle(letterColor(for: letter, isActive: index == displayedActiveIndex))
                    .accentTextOutline()
                    .shadow(color: accent.opacity(glowActive ? 0.12 : 0), radius: glowActive ? 5 : 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: rowHeight)
            }
        }
        .frame(width: stripWidth)
        .padding(.vertical, verticalPadding)
        .background(Capsule().fill(AppColor.surface.opacity(0.35)))
        .shadow(color: accent.opacity(glowActive ? 0.10 : 0), radius: glowActive ? 7 : 0)
        .overlay(alignment: .topTrailing) {
            if let displayedActiveIndex, letters.indices.contains(displayedActiveIndex) {
                magnifiedBadge(
                    letter: letters[displayedActiveIndex],
                    size: currentBadgeSize,
                    fontSize: currentBadgeFontSize
                )
                .opacity(isExternalHighlight ? highlightBadgeOpacity : 1.0)
                .offset(
                    x: -stripWidth - 12,
                    y: badgeYOffset(for: displayedActiveIndex, badgeSize: currentBadgeSize)
                )
                // Pronounced grow-in (0.4 → 1.0) so the badge feels
                // like it leaps into view when the post-save signal lands.
                .transition(.opacity.combined(with: .scale(scale: 0.4)))
                .allowsHitTesting(false)
            }
        }
        // Free-scroll pulse — its own overlay layer so it never shares
        // state with the scrub / post-save badge above. Uses the compact
        // `defaultBadge*` sizes (matching the scrubber's own magnify) and
        // a self-driven opacity fade rather than a transition.
        .overlay(alignment: .topTrailing) {
            if let pulseIndex, letters.indices.contains(pulseIndex) {
                magnifiedBadge(
                    letter: letters[pulseIndex],
                    size: defaultBadgeSize,
                    fontSize: defaultBadgeFontSize
                )
                .opacity(pulseOpacity)
                .offset(
                    x: -stripWidth - 12,
                    y: badgeYOffset(for: pulseIndex, badgeSize: defaultBadgeSize)
                )
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let raw = (value.location.y - verticalPadding) / rowHeight
                    let idx = max(0, min(letters.count - 1, Int(raw)))
                    if idx != activeIndex {
                        activeIndex = idx
                        onSelect(letters[idx])
                    }
                }
                .onEnded { _ in activeIndex = nil }
        )
        .animation(.easeOut(duration: 0.25), value: displayedActiveIndex)
        .animation(.easeInOut(duration: 0.14), value: glowActive)
        .onChange(of: externalHighlightLetter) { old, new in
            if old != nil && new == nil {
                // External highlight is ending — keep the badge alive in
                // `fadingHighlightLetter` while we animate it to opacity 0,
                // then clean up after the animation completes.
                fadingHighlightLetter = old
                highlightBadgeOpacity = 1.0
                withAnimation(.easeOut(duration: 0.35)) {
                    highlightBadgeOpacity = 0
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    fadingHighlightLetter = nil
                    highlightBadgeOpacity = 1.0
                }
            } else if new != nil {
                fadingHighlightLetter = nil
                highlightBadgeOpacity = 1.0
            }
        }
        .onChange(of: scrollFocusLetter) { _, new in
            // One pulse per section crossing — the same event that fires
            // the scroll haptic. Quick fade-in, very brief hold, fade-out.
            guard let new else { return }
            pulseGeneration += 1
            let generation = pulseGeneration
            pulseLetter = new
            withAnimation(.easeOut(duration: 0.12)) {
                pulseOpacity = 1.0
            }
            Task { @MainActor in
                // Hold briefly at full opacity, then fade out.
                try? await Task.sleep(for: .milliseconds(160))
                guard generation == pulseGeneration else { return }
                withAnimation(.easeIn(duration: 0.28)) {
                    pulseOpacity = 0
                }
                try? await Task.sleep(for: .milliseconds(300))
                // Only retire the letter if no fresher crossing arrived —
                // otherwise the live pulse would blank mid-animation.
                guard generation == pulseGeneration else { return }
                pulseLetter = nil
            }
        }
    }

    private func letterColor(for letter: String, isActive: Bool) -> Color {
        if isActive { return accent }
        return accent.opacity(populated.contains(letter) ? 0.85 : 0.3)
    }

    private func magnifiedBadge(letter: String, size: CGFloat, fontSize: CGFloat) -> some View {
        Text(letter)
            .font(.system(size: fontSize, weight: .heavy, design: .serif))
            .foregroundStyle(AppColor.onAccent)
            .frame(width: size, height: size)
            .background(
                Circle().fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.95),
                            accent.opacity(0.80)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .shadow(color: AppColor.shadow, radius: 14, x: 0, y: 6)
    }

    private func badgeYOffset(for index: Int, badgeSize: CGFloat) -> CGFloat {
        let letterCenterY = verticalPadding + CGFloat(index) * rowHeight + rowHeight / 2
        return letterCenterY - badgeSize / 2
    }
}

extension LetterIndex {
    /// Shared alphabet used by both Library and Friends lists. `#`
    /// at the top catches anything that doesn't sort under a letter
    /// (numerics, emoji-leading names, etc.). Top-bucket placement so
    /// the non-letter group reads as the "before A" pile rather than
    /// the dangling "after Z" tail — and tapping `#` with no non-letter
    /// items falls through to A via the ordered `firstAtOrAfter` walk.
    static let allLetters: [String] = {
        let az = (0..<26).map { String(UnicodeScalar(UInt8(65 + $0))) }
        return ["#"] + az
    }()

    /// First letter of `name` uppercased, or `#` for non-letter starts
    /// / empty strings. Matches the convention used by both Library
    /// and Friends lists.
    static func bucket(for name: String) -> String {
        guard let first = name.first else { return "#" }
        let upper = String(first).uppercased()
        return upper.range(of: "^[A-Z]$", options: .regularExpression) != nil ? upper : "#"
    }

    /// Walk `letters` forward from `letter` and return the first `item`
    /// whose `bucket` matches the first populated letter at or after
    /// `letter`. Keeps taps on empty/dimmed letters useful — `#` with
    /// no non-letter items falls through to A. Shared by the Library
    /// and Friends scrub strips; pass the caller's own bucketing
    /// function so each list keeps its existing bucket semantics.
    static func firstItem<Item>(
        in items: [Item],
        atOrAfter letter: String,
        letters: [String] = LetterIndex.allLetters,
        bucket: (Item) -> String
    ) -> Item? {
        guard let startIndex = letters.firstIndex(of: letter) else { return nil }
        let populated = Set(items.map(bucket))
        for candidate in letters[startIndex...] where populated.contains(candidate) {
            return items.first { bucket($0) == candidate }
        }
        return nil
    }
}
