import SwiftUI

// Presentational chrome around the grocery item list — the live-sync banner,
// the empty state, and the triage scrim. Split out of
// `GroceryListDetailView`: each is a pure function of a few values, holds no
// list state, and is edited independently of the list itself.

/// Slim live-status banner. Owner sees who they shared with; a recipient
/// sees who shared it to them — both with a pulsing dot to signal the list
/// is syncing live.
struct GroceryShareStatusBanner: View {
    let isOwner: Bool
    let sharedWithName: String?
    let ownerName: String?
    let accent: Color

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Circle()
                .fill(AppColor.success)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity)
        // Slim floating status banner — LG glass per the floating-chrome
        // convention (full-width edge bar, so `Rectangle()` like the photo
        // keyboard bar, not a capsule).
        .glassEffect(.regular, in: Rectangle())
    }

    private var statusText: String {
        if isOwner {
            let who = sharedWithName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let who, !who.isEmpty { return "Shared with \(who) · syncing live" }
            return "Shared · syncing live"
        }
        let who = ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let who, !who.isEmpty { return "Shared by \(who) · check items off as you shop" }
        return "Shared with you · check items off as you shop"
    }
}

/// Empty-list state. Owners get the "add it yourself" instructions; a
/// recipient viewing an empty shared mirror has no add bar, so those
/// instructions would be impossible to follow — give them a passive
/// "nothing here yet" instead.
struct GroceryEmptyState: View {
    let isOwner: Bool
    let ownerName: String?
    let accent: Color

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "basket")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(accent.opacity(0.85))
                .accentTextOutline()
                .llamaFloat()
            Text("This list is empty")
                .font(AppFont.sectionHeading)
                .foregroundStyle(accent)
                .accentTextOutline()
            Text(detail)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detail: String {
        if isOwner {
            return "Add items below, or open a recipe and tap the basket on its ingredients to fill this list."
        }
        let who = ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let who, !who.isEmpty {
            return "Nothing on this list yet — \(who) hasn't added items, or everything's been checked off."
        }
        return "Nothing on this list yet — the owner hasn't added items, or everything's been checked off."
    }
}

/// "Asking the llama…" scrim shown only when a manual aisle sort takes long
/// enough to matter (1 s debounce inside `sortByAisle`). The silent
/// auto-triage on appear never shows it. The caller owns the `isTriaging`
/// gate and the `.transition(.opacity)` it animates with.
struct GroceryTriagingOverlay: View {
    let accent: Color

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: AppSpacing.md) {
                LlamaProgressIndicator(size: 96, accent: accent)
                Text("Asking the llama…")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .padding(AppSpacing.xl)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.lg))
        }
        .transition(.opacity)
    }
}
