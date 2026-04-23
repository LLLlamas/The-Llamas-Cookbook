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
                        section("Ingredients") {
                            VStack(spacing: AppSpacing.xs) {
                                ForEach(sortedIngredients) { ingredient in
                                    ingredientRow(ingredient)
                                }
                            }
                        }
                    }

                    if !sortedSteps.isEmpty {
                        section("Steps") {
                            VStack(alignment: .leading, spacing: AppSpacing.md) {
                                ForEach(Array(sortedSteps.enumerated()), id: \.element.id) { idx, step in
                                    stepRow(idx: idx, step: step)
                                }
                            }
                        }
                    }

                    if !recipe.notes.trimmed.isEmpty {
                        section("Notes") {
                            Text(recipe.notes)
                                .font(AppFont.body)
                                .foregroundStyle(AppColor.textPrimary)
                                .padding(AppSpacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppColor.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.md)
                                        .stroke(AppColor.divider, lineWidth: 1)
                                )
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
                        Image(systemName: "pencil")
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
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(title)
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.textPrimary)
                .padding(.top, AppSpacing.lg)
            content()
        }
    }

    private func ingredientRow(_ ingredient: Ingredient) -> some View {
        HStack(spacing: AppSpacing.md) {
            Circle()
                .fill(AppColor.accent)
                .frame(width: 8, height: 8)
            Text(ingredientText(ingredient))
                .font(AppFont.ingredient)
                .foregroundStyle(AppColor.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSpacing.sm + 2)
        .padding(.horizontal, AppSpacing.md)
        .background(AppColor.surface)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .stroke(AppColor.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func stepRow(idx: Int, step: RecipeStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
            Text("\(idx + 1).")
                .font(AppFont.sectionHeading)
                .foregroundStyle(AppColor.accent)
                .frame(minWidth: 28, alignment: .leading)
                .monospacedDigit()
            Text(step.text)
                .font(AppFont.body)
                .foregroundStyle(AppColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func ingredientText(_ ingredient: Ingredient) -> String {
        let qty = Quantity.displayFormat(ingredient.quantity)
        let unit = Plural.unit(ingredient.unit ?? "", for: ingredient.quantity)
        return [qty, unit, ingredient.name]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
