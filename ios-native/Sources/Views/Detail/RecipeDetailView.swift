import SwiftUI
import SwiftData
import UIKit

struct RecipeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    @State private var showingEditor = false
    @State private var showingDeleteAlert = false
    @State private var showingCookMode = false
    @State private var showingConversions = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text(recipe.title)
                        .font(AppFont.recipeTitle)
                        .foregroundStyle(AppColor.textPrimary)

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
                                TagPill(label: StringCase.capitalizeFirst(tag))
                            }
                        }
                    }

                    if !sortedIngredients.isEmpty {
                        section("Ingredients", accessory: { conversionsChip }) {
                            VStack(spacing: 3) {
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
                                    stepRow(idx: idx, step: step)
                                }
                            }
                        }
                    }

                    if !recipe.notes.trimmed.isEmpty {
                        section("Notes") {
                            HStack(alignment: .top, spacing: AppSpacing.md) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(AppColor.accent)
                                    .frame(width: 3)
                                Text(recipe.notes)
                                    .font(AppFont.body)
                                    .foregroundStyle(AppColor.textPrimary)
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(AppSpacing.md)
                            .background(AppColor.surfaceSunken)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
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
                        showingEditor = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AppColor.textPrimary)
                    }
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                RecipeEditorView(recipe: recipe)
            }
        }
        .fullScreenCover(isPresented: $showingCookMode) {
            CookModeView(recipe: recipe)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(AppFont.sectionHeading)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer(minLength: AppSpacing.sm)
                    accessory()
                }
                Capsule()
                    .fill(AppColor.accent.opacity(0.55))
                    .frame(width: 32, height: 2)
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
        let qty = Quantity.displayFormat(ingredient.quantity)
        let unit = Plural.unit(ingredient.unit ?? "", for: ingredient.quantity)
        let measure = [qty, unit].filter { !$0.isEmpty }.joined(separator: " ")
        let takesOf = !unit.isEmpty && Plural.needsConnector(unit)

        return HStack(alignment: .center, spacing: AppSpacing.sm + 2) {
            Circle()
                .fill(AppColor.accent)
                .frame(width: 6, height: 6)

            Text(measure)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(AppColor.accentDeep)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 120, alignment: .leading)

            Group {
                if takesOf {
                    Text("of")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColor.textSecondary)
                } else {
                    Text("—")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(AppColor.dividerStrong)
                        .opacity(measure.isEmpty ? 0 : 1)
                }
            }

            Text(ingredient.name)
                .font(AppFont.ingredient)
                .foregroundStyle(AppColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppSpacing.sm - 1)
        .padding(.horizontal, AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .shadow(color: AppColor.shadowSoft, radius: 3, x: 0, y: 1)
    }

    private func stepRow(idx: Int, step: RecipeStep) -> some View {
        // Width of the step-number column + spacing — the small accent rule
        // below extends from the leading edge to where the step text begins.
        let numberColumnWidth: CGFloat = 28 + AppSpacing.md

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
                Text("\(idx + 1).")
                    .font(AppFont.sectionHeading)
                    .foregroundStyle(AppColor.accent)
                    .frame(minWidth: 28, alignment: .leading)
                    .monospacedDigit()
                Text(step.text)
                    .font(AppFont.body)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if step.needsTimer {
                    Image(systemName: "timer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.accent.opacity(0.8))
                }
            }
            Capsule()
                .fill(AppColor.accent.opacity(0.35))
                .frame(width: numberColumnWidth, height: 1.5)
        }
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
                showingCookMode = true
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "fork.knife")
                    Text("Start Cooking")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Color(red: 1, green: 0.992, blue: 0.972))
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

    private var sortedIngredients: [Ingredient] {
        recipe.ingredients.sorted { $0.order < $1.order }
    }

    private var sortedSteps: [RecipeStep] {
        recipe.steps.sorted { $0.order < $1.order }
    }

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
