import Foundation

/// Best-effort real-photo lookup for the grocery item "?" helper.
/// Queries Wikimedia Commons for a relevant ingredient photo, then hands
/// SwiftUI a thumbnail URL to render with `AsyncImage`.
enum IngredientPhotoLookup {
    struct Result: Equatable, Sendable {
        let imageURL: URL
        let sourceURL: URL?
    }

    private static let endpoint = URL(string: "https://commons.wikimedia.org/w/api.php")!

    private static let droppedSearchWords: Set<String> = [
        "a", "an", "and", "bag", "bunch", "can", "clove", "cloves",
        "cup", "cups", "dash", "fresh", "g", "gram", "grams", "large",
        "lb", "lbs", "medium", "oz", "ounce", "ounces", "package", "pinch",
        "small", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon",
        "teaspoons", "whole"
    ]

    static func fetch(for itemName: String) async -> Result? {
        let term = searchTerm(for: itemName)
        guard !term.isEmpty, let url = requestURL(for: term) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(
            "LlamasCookbook/1.2 (https://llamascookbook.pages.dev/support)",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }

        return decoded.query?.pages?
            .compactMap(result(from:))
            .first
    }

    private static func requestURL(for term: String) -> URL? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "8"),
            URLQueryItem(name: "gsrsearch", value: "\(term) food ingredient"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url"),
            URLQueryItem(name: "iiurlwidth", value: "900"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]
        return components?.url
    }

    private static func searchTerm(for itemName: String) -> String {
        let normalized = GroceryKeyword.normalize(itemName)
        let words = normalized
            .split(separator: " ")
            .map(String.init)
            .filter { word in
                !word.allSatisfy(\.isNumber) && !droppedSearchWords.contains(word)
            }
        let cleaned = words.joined(separator: " ")
        return cleaned.isEmpty ? normalized : cleaned
    }

    private static func result(from page: Page) -> Result? {
        guard let info = page.imageinfo?.first else { return nil }
        let rawImageURL = info.thumburl ?? info.url
        guard let rawImageURL,
              !rawImageURL.lowercased().hasSuffix(".svg"),
              let imageURL = URL(string: rawImageURL) else {
            return nil
        }
        return Result(
            imageURL: imageURL,
            sourceURL: info.descriptionurl.flatMap(URL.init(string:))
        )
    }
}

private struct Response: Decodable {
    let query: Query?
}

private struct Query: Decodable {
    let pages: [Page]?
}

private struct Page: Decodable {
    let imageinfo: [ImageInfo]?
}

private struct ImageInfo: Decodable {
    let thumburl: String?
    let url: String?
    let descriptionurl: String?
}
