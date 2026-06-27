import SwiftUI

/// The per-item "?" helper. Recognition only: an actual searched photo when
/// one is available, an on-device blurb for a shopper who doesn't recognize
/// the item, and a web image search fallback. Out-of-stock lives only in the
/// row's separate "!" button.
struct ItemHelperSheet: View {
    @Bindable var item: GroceryItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppearanceSettings.self) private var appearance

    @State private var blurb: String?
    @State private var loadingBlurb = true
    @State private var photo: IngredientPhotoLookup.Result?
    @State private var loadingPhoto = true

    private var accent: Color { appearance.cookbookTitleAccentColor }

    var body: some View {
        NavigationStack {
            List {
                whatIsItSection
            }
            .navigationTitle(item.name.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .tint(accent)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(accent)
                }
            }
            .task(id: item.id) { await loadContent() }
        }
    }

    // MARK: - What is this?

    private var whatIsItSection: some View {
        Section("What is it?") {
            photoCard
            if loadingBlurb {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView().tint(accent)
                    Text("Asking the llama…")
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textSecondary)
                }
            } else if let blurb {
                Text(blurb)
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textPrimary)
            } else {
                Text("Tap below to see what \(item.name.lowercased()) looks like.")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textSecondary)
            }

            Button {
                Haptics.selection()
                openURL(imageSearchURL)
            } label: {
                Label(photo == nil ? "Search photos" : "More photos", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    @ViewBuilder
    private var photoCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(AppColor.surface)
            if let photo {
                AsyncImage(url: photo.imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        photoPlaceholder
                    case .empty:
                        ProgressView()
                            .tint(accent)
                    @unknown default:
                        photoPlaceholder
                    }
                }
            } else if loadingPhoto {
                ProgressView()
                    .tint(accent)
            } else {
                photoPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(alignment: .bottomTrailing) {
            if let sourceURL = photo?.sourceURL {
                Button {
                    Haptics.selection()
                    openURL(sourceURL)
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppColor.onAccent)
                        .frame(width: 30, height: 30)
                        .background(accent.opacity(0.9), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(AppSpacing.sm)
                .accessibilityLabel("Open photo source")
            }
        }
        .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.lg, bottom: AppSpacing.sm, trailing: AppSpacing.lg))
    }

    private var photoPlaceholder: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: "photo")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(accent.opacity(0.65))
            Text("Photo unavailable")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadContent() async {
        loadingBlurb = true
        loadingPhoto = true
        async let fetchedBlurb = IngredientAssistant.describe(item.name)
        async let fetchedPhoto = IngredientPhotoLookup.fetch(for: item.name)
        blurb = await fetchedBlurb
        photo = await fetchedPhoto
        loadingBlurb = false
        loadingPhoto = false
    }

    private var imageSearchURL: URL {
        let query = "\(item.name) food"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "https://www.google.com/search?tbm=isch&q=\(encoded)")
            ?? URL(string: "https://www.google.com")!
    }
}
