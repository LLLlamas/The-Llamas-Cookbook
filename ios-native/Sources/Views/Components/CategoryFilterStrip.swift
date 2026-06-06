import SwiftUI

/// Horizontal "All  ·  N  |  Tag  ·  N  |  Tag  ·  N" filter strip.
/// Mirrors the visual rhythm of the home `LibraryView`'s filter strip
/// — leading "All" pill pinned outside a horizontal scroller with the
/// category pills behind it — minus the home-only affordances (sort
/// context menu, favorites filter, "go home" routing). Designed for
/// surfaces like `FriendLibraryView` where the user is browsing
/// someone else's cookbook and needs a category cut without the full
/// library toolset.
///
/// `selection == nil` means "All". Tap a category to set it; tap the
/// active category again to clear back to All. The accent color is
/// passed in so the friend library can render this strip in the
/// friend's accent rather than the local user's appearance accent —
/// matches the CLAUDE.md UX guardrail that friend surfaces tint in
/// the friend's color.
struct CategoryFilterStrip: View {
    let categories: [String]
    let totalCount: Int
    let countFor: (String) -> Int
    @Binding var selection: String?
    let accent: Color

    /// Fires the letter-scrubber tick as the user drags the horizontal
    /// chip strip, so it feels consistent with scrolling the recipe
    /// list. Owned by the strip and never shared with a list ticker.
    /// Reset when the available category set changes wholesale.
    @State private var stripTicker = ScrollSectionTicker()

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            allPill

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xs) {
                    ForEach(categories, id: \.self) { tag in
                        let isActive = selection == tag
                        let label = "\(StringCase.titleCase(tag))  ·  \(countFor(tag))"
                        pill(label: label, isActive: isActive) {
                            Haptics.selection()
                            selection = isActive ? nil : tag
                        }
                        .scrollSectionHaptic(section: tag, ticker: stripTicker)
                    }
                }
                .padding(.trailing, AppSpacing.lg)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .onChange(of: categories) { _, _ in
                // Category set changed wholesale — clear the ticker so
                // the re-laid-out strip settles silently.
                stripTicker.reset()
            }
        }
        .padding(.leading, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    private var allPill: some View {
        let isActive = selection == nil
        return Button {
            Haptics.selection()
            selection = nil
        } label: {
            Text("All  ·  \(totalCount)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? AppColor.onAccent : AppColor.textPrimary)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.xs + 2)
                .modifier(ChipBackground(isActive: isActive, accent: accent))
                .overlay(
                    Capsule().stroke(isActive ? accent : AppColor.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.scaleOnly)
    }

    private func pill(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? AppColor.onAccent : AppColor.textPrimary)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.xs + 2)
                .modifier(ChipBackground(isActive: isActive, accent: accent))
                .overlay(
                    Capsule().stroke(isActive ? accent : AppColor.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.scaleOnly)
    }
}

/// Active = solid accent fill; inactive = LG glass capsule.
/// Mirrors LibraryView.ChipBackground so FriendLibraryView's category
/// strip matches the home filter strip visually.
private struct ChipBackground: ViewModifier {
    let isActive: Bool
    let accent: Color

    func body(content: Content) -> some View {
        if isActive {
            content.background(accent, in: Capsule())
        } else {
            content.glassEffect(.regular, in: Capsule())
        }
    }
}
