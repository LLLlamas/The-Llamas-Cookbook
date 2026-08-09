import SwiftUI

/// In-app banner for "a friend just shared a grocery list with you".
///
/// Deliberately NOT the `SavedToast` centered-badge idiom: that one confirms
/// something *you* just did and can afford to be icon-only and transient.
/// This one announces something someone *else* did, arrives unprompted, and
/// has to carry two facts (who, and which list) plus a choice — so it's a
/// top banner in the system-notification idiom, which is also what the user
/// has just been trained on by the push that may have preceded it.
///
/// Two exits, both explicit:
///  - the row itself opens the list (`onOpen`)
///  - the trailing ✕ dismisses and leaves you exactly where you were
///    (`onDismiss`)
///
/// The ✕ is a sibling button with its own bounded hit area rather than an
/// overlay on the tappable row — the grocery row's separated check/?/!
/// targets set that precedent, and a dismiss that accidentally navigates is
/// the most annoying possible bug in an unprompted banner.
struct SharedListToast: View {
    let share: IncomingShare
    let accent: Color
    let onOpen: () -> Void
    let onDismiss: () -> Void

    /// Drives the drop-in. Starts false so the banner animates from above
    /// the safe area on mount rather than popping into place.
    @State private var presented = false

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            // Everything except the ✕ is one Button. Two sibling buttons
            // with disjoint hit areas — NOT a parent `.onTapGesture` with a
            // nested button, where precedence between the two is a SwiftUI
            // implementation detail rather than something we control.
            Button(action: onOpen) {
                HStack(spacing: AppSpacing.sm) {
                    ZStack {
                        Circle().fill(accent.opacity(0.16))
                        Image(systemName: "basket.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(share.headline)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(share.listName)
                            .font(.system(size: 16, weight: .bold, design: .serif))
                            .foregroundStyle(AppColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("View")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppColor.textTertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, AppSpacing.sm)
        .padding(.trailing, AppSpacing.xs)
        .padding(.vertical, AppSpacing.sm)
        // Floating chrome → Liquid Glass, per the app-wide convention for
        // anything painted over content rather than docked into it.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: AppColor.shadow, radius: 14, y: 6)
        .padding(.horizontal, AppSpacing.lg)
        .offset(y: presented ? 0 : -140)
        .opacity(presented ? 1 : 0)
        .onAppear {
            withAnimation(.spring(duration: 0.45, bounce: 0.28)) { presented = true }
        }
        // One accessibility element with both actions, so VoiceOver reads
        // the announcement and offers open/dismiss without the user having
        // to hunt for a 12pt glyph.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(share.headline). \(share.listName)")
        .accessibilityHint("Double tap to open the list")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Dismiss", onDismiss)
    }
}

#Preview {
    VStack {
        SharedListToast(
            share: IncomingShare(
                recordName: "abc",
                listName: "Weekend Shop",
                ownerName: "Dad"
            ),
            accent: AppColor.accent,
            onOpen: {},
            onDismiss: {}
        )
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppColor.surface)
}
