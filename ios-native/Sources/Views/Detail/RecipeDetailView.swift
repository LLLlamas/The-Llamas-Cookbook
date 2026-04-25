import SwiftUI
import SwiftData
import UIKit

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(CookingSession.self) private var session
    @Environment(EditorCoordinator.self) private var editor

    let recipe: Recipe

    @State private var showingDeleteAlert = false
    @State private var showingConversions = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text(StringCase.titleCase(recipe.title))
                        .font(AppFont.recipeTitle)
                        .foregroundStyle(AppColor.accent)
                        .shadow(color: AppColor.shadow, radius: 2, x: 0, y: 1.5)

                    if let summary = recipe.summary, !summary.isEmpty {
                        Text(summary)
                            .font(AppFont.body)
                            .foregroundStyle(AppColor.textSecondary)
                    }

                    if !timeParts.isEmpty {
                        Text(timeParts.joined(separator: "  ·  "))
                            .font(AppFont.caption)
                            .foregroundStyle(AppColor.textSecondary)
                    }

                    if !recipe.tags.isEmpty {
                        FlowRow(spacing: AppSpacing.xs) {
                            ForEach(recipe.tags, id: \.self) { tag in
                                TagPill(label: StringCase.titleCase(tag))
                            }
                        }
                    }

                    if !sortedIngredients.isEmpty {
                        section("Ingredients", accessory: { conversionsChip }) {
                            VStack(spacing: AppSpacing.sm) {
                                ForEach(sortedIngredients) { ingredient in
                                    ingredientRow(ingredient)
                                }
                            }
                        }
                    }

                    if !sortedSteps.isEmpty {
                        section("Steps") {
                            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                ForEach(Array(sortedSteps.enumerated()), id: \.element.id) { idx, step in
                                    StepDetailRow(idx: idx, step: step)
                                }
                            }
                        }
                    }

                    if let url = recipe.sourceUrl, !url.isEmpty {
                        section("Reference") {
                            sourceLink(url: url)
                        }
                    }

                    signatureRow

                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .medium))
                            Text("Delete recipe")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(AppColor.destructive)
                        .padding(AppSpacing.sm)
                    }
                    .padding(.top, AppSpacing.md)
                }
                .padding(AppSpacing.lg)
                .padding(.bottom, 100)
            }
            .background(AppColor.background)

            startCookingBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: AppSpacing.md) {
                    Button {
                        Haptics.selection()
                        recipe.favorite.toggle()
                        recipe.updatedAt = .now
                    } label: {
                        Image(systemName: recipe.favorite ? "heart.fill" : "heart")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AppColor.accent)
                    }
                    ShareLink(
                        item: recipe.exportText,
                        subject: Text(recipe.title),
                        message: Text("Recipe from Llamas Cookbook")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(AppColor.textPrimary)
                    }
                    Button {
                        editor.startEdit(recipe)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AppColor.textPrimary)
                    }
                }
            }
        }
        .sheet(isPresented: $showingConversions) {
            ConversionsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert("Delete recipe?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                modelContext.delete(recipe)
                dismiss()
            }
        } message: {
            Text("\"\(recipe.title)\" will be permanently removed.")
        }
    }

    // MARK: subsections

    @ViewBuilder
    private func section<Content: View, Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(AppColor.textPrimary)
                    // Underline rides the padded bottom of the Text's own
                    // frame, so it stretches to match the word width —
                    // 130pt under "Ingredients", 50pt under "Steps" — rather
                    // than the previous fixed 32pt stub.
                    .padding(.bottom, 6)
                    .background(alignment: .bottom) {
                        Capsule()
                            .fill(AppColor.accent.opacity(0.55))
                            .frame(height: 2)
                    }
                Spacer(minLength: AppSpacing.sm)
                accessory()
            }
            .padding(.top, AppSpacing.lg)
            content()
        }
    }

    private var conversionsChip: some View {
        Button {
            Haptics.selection()
            showingConversions = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ruler")
                    .font(.system(size: 11, weight: .semibold))
                Text("Conversions")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(AppColor.accent)
            .padding(.horizontal, AppSpacing.sm + 2)
            .padding(.vertical, AppSpacing.xs + 1)
            .overlay(Capsule().stroke(AppColor.accent, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open kitchen conversions reference")
    }

    private func ingredientRow(_ ingredient: Ingredient) -> some View {
        let display = ingredient.display()
        let hasMeasure = !display.quantity.isEmpty || !display.unit.isEmpty
        let takesOf = display.takesOf

        return HStack(alignment: .center, spacing: AppSpacing.sm + 2) {
            Circle()
                .fill(AppColor.accent)
                .frame(width: 6, height: 6)

            // Qty + unit on the same line, left-aligned in a fixed-width
            // column so the em-dashes between rows line up.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if !display.quantity.isEmpty {
                    Text(display.quantity)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColor.accentDeep)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if !display.unit.isEmpty {
                    Text(display.unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColor.accentDeep.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .frame(width: 110, alignment: .leading)

            Group {
                if takesOf {
                    Text("of")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColor.textSecondary)
                } else {
                    Text("—")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(AppColor.dividerStrong)
                        .opacity(hasMeasure ? 1 : 0)
                }
            }

            Text(ingredient.name)
                .font(AppFont.ingredient)
                .foregroundStyle(AppColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppSpacing.sm + 2)
        .padding(.horizontal, AppSpacing.md + 2)
        .background(
            LinearGradient(
                colors: [AppColor.surfaceRaised, AppColor.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.divider.opacity(0.6), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: AppColor.shadow, radius: 5, x: 0, y: 2)
        .shadow(color: AppColor.shadowSoft, radius: 1, x: 0, y: 0.5)
    }

    private func sourceLink(url: String) -> some View {
        Button {
            if let parsed = URL(string: url) {
                UIApplication.shared.open(parsed)
            }
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(AppColor.accent)
                Text(url)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm + 2)
            .background(AppColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(AppColor.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        }
    }

    private var signatureRow: some View {
        HStack(spacing: AppSpacing.md) {
            LlamaMascot(size: 36)
            Text(metaFooter)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, AppSpacing.xl)
    }

    private var startCookingBar: some View {
        VStack {
            Button {
                Haptics.impact(.light)
                session.start(recipe)
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "fork.knife")
                    Text("Start Cooking")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(AppColor.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(AppColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .background(AppColor.background.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(AppColor.divider).frame(height: 1)
        }
    }

    // MARK: Computed

    private var sortedIngredients: [Ingredient] { recipe.sortedIngredients }
    private var sortedSteps: [RecipeStep] { recipe.sortedSteps }

    private var timeParts: [String] {
        var parts: [String] = []
        if let s = recipe.servings {
            parts.append("\(s) serving\(s == 1 ? "" : "s")")
        }
        if let cook = recipe.cookTimeMinutes {
            parts.append("Cook \(cook)m")
        }
        return parts
    }

    private var metaFooter: String {
        var parts: [String] = []
        parts.append("Added \(recipe.createdAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year()))")
        if let last = recipe.lastCookedAt {
            parts.append("Last cooked \(last.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year()))")
        }
        if recipe.cookCount > 0 {
            parts.append("Cooked \(recipe.cookCount) time\(recipe.cookCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

}

private struct TagPill: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs + 2)
            .foregroundStyle(AppColor.textPrimary)
            .background(AppColor.surface)
            .overlay(Capsule().stroke(AppColor.divider, lineWidth: 1))
            .clipShape(Capsule())
    }
}

/// A simple wrap layout for pills/chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One step in the detail-view numbered list. The row sits inside a
/// gradient "bubble" pill — cream shading into a soft terracotta on the
/// bottom-trailing corner, with layered shadows to lift it off the page.
/// Number is a fixed size, vertically centered against the wrapping text.
private struct StepDetailRow: View {
    let idx: Int
    let step: RecipeStep

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            Text("\(idx + 1).")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.accent)
                .monospacedDigit()
                .frame(minWidth: 28, alignment: .leading)

            Text(step.text)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if step.needsTimer {
                Image(systemName: "timer")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColor.accent.opacity(0.85))
            }
        }
        .padding(.vertical, AppSpacing.md)
        .padding(.horizontal, AppSpacing.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    AppColor.surfaceRaised,
                    AppColor.accentSoft.opacity(0.55)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .stroke(AppColor.accent.opacity(0.22), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .shadow(color: AppColor.shadow, radius: 6, x: 0, y: 2)
        .shadow(color: AppColor.shadowSoft, radius: 1, x: 0, y: 0.5)
    }
}
