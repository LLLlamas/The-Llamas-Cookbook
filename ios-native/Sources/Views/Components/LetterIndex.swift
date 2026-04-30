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
    /// Letter to flash the magnify badge on when no scrub gesture is
    /// active — driven by external highlight signals (e.g. RootView's
    /// post-save library highlight). `nil` at all other times.
    let externalHighlightLetter: String?
    let onSelect: (String) -> Void

    @State private var activeIndex: Int? = nil

    private let rowHeight: CGFloat = 11
    private let stripWidth: CGFloat = 14
    private let verticalPadding: CGFloat = 4
    private let badgeSize: CGFloat = 56

    /// Index that should currently render as "active" — gesture-driven
    /// scrub wins (so post-save highlight never fights the user), with
    /// the external highlight as the fallback signal.
    private var displayedActiveIndex: Int? {
        if let activeIndex { return activeIndex }
        if let externalHighlightLetter,
           let idx = letters.firstIndex(of: externalHighlightLetter) {
            return idx
        }
        return nil
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
                    .frame(maxWidth: .infinity)
                    .frame(height: rowHeight)
            }
        }
        .frame(width: stripWidth)
        .padding(.vertical, verticalPadding)
        .background(Capsule().fill(AppColor.surface.opacity(0.35)))
        .overlay(alignment: .topTrailing) {
            if let displayedActiveIndex, letters.indices.contains(displayedActiveIndex) {
                magnifiedBadge(letter: letters[displayedActiveIndex])
                    .offset(
                        x: -stripWidth - 12,
                        y: badgeYOffset(for: displayedActiveIndex)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
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
    }

    private func letterColor(for letter: String, isActive: Bool) -> Color {
        if isActive { return accent }
        return accent.opacity(populated.contains(letter) ? 0.85 : 0.3)
    }

    private func magnifiedBadge(letter: String) -> some View {
        Text(letter)
            .font(.system(size: 30, weight: .heavy, design: .serif))
            .foregroundStyle(AppColor.onAccent)
            .frame(width: badgeSize, height: badgeSize)
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
            .shadow(color: AppColor.shadow, radius: 8, x: 0, y: 3)
    }

    /// Vertically aligns the badge's center on the active letter's
    /// center. `.overlay(alignment: .topTrailing)` plants the badge
    /// with its top at the strip top, so we offset down by
    /// `(letterCenterY - badgeSize/2)`.
    private func badgeYOffset(for index: Int) -> CGFloat {
        let letterCenterY = verticalPadding + CGFloat(index) * rowHeight + rowHeight / 2
        return letterCenterY - badgeSize / 2
    }
}

extension LetterIndex {
    /// Shared alphabet used by both Library and Friends lists. `#`
    /// at the bottom catches anything that doesn't sort under a letter
    /// (numerics, emoji-leading names, etc.) — matches LibraryView's
    /// pre-extraction ordering, so the visual strip stays unchanged.
    static let allLetters: [String] = {
        let az = (0..<26).map { String(UnicodeScalar(UInt8(65 + $0))) }
        return az + ["#"]
    }()

    /// First letter of `name` uppercased, or `#` for non-letter starts
    /// / empty strings. Matches the convention used by both Library
    /// and Friends lists.
    static func bucket(for name: String) -> String {
        guard let first = name.first else { return "#" }
        let upper = String(first).uppercased()
        return upper.range(of: "^[A-Z]$", options: .regularExpression) != nil ? upper : "#"
    }
}
