import XCTest
@testable import LlamasCookbook

final class InstagramExtractorTests: XCTestCase {

    // MARK: - canonicalURL

    func testCanonicalURLStripsIGSH() {
        let url = URL(string: "https://www.instagram.com/reel/ABC123/?igsh=MWloOXFzY3Uz")!
        let cleaned = InstagramExtractor.canonicalURL(url)
        XCTAssertNil(cleaned.query, "Expected igsh tracking param stripped, got: \(cleaned.absoluteString)")
    }

    func testCanonicalURLStripsUTM() {
        let url = URL(string: "https://www.instagram.com/p/XYZ/?utm_source=share&utm_medium=copy_link")!
        let cleaned = InstagramExtractor.canonicalURL(url)
        XCTAssertNil(cleaned.query)
    }

    func testCanonicalURLKeepsUnknownQueryParams() {
        let url = URL(string: "https://www.instagram.com/reel/ABC/?lang=es")!
        let cleaned = InstagramExtractor.canonicalURL(url)
        XCTAssertEqual(cleaned.query, "lang=es")
    }

    // MARK: - parseCaptionSnippet

    func testCaptionSnippetTypicalIGFormat() {
        let og = "162K likes, 155 comments - chefjohnsmith on August 5, 2025: \"BEST chocolate chip cookies you'll ever make!\""
        XCTAssertEqual(
            InstagramExtractor.parseCaptionSnippet(ogDescription: og),
            "BEST chocolate chip cookies you'll ever make!"
        )
    }

    func testCaptionSnippetCurlyQuotes() {
        let og = "162K likes, 155 comments - chefjohnsmith on August 5, 2025: \u{201C}Banana bread for the weekend\u{201D}"
        XCTAssertEqual(
            InstagramExtractor.parseCaptionSnippet(ogDescription: og),
            "Banana bread for the weekend"
        )
    }

    func testCaptionSnippetReturnsNilForUnexpectedFormat() {
        let og = "Random meta description with no quote wrapper"
        XCTAssertNil(InstagramExtractor.parseCaptionSnippet(ogDescription: og))
    }

    func testCaptionSnippetStripsTrailingPunctuation() {
        let og = "10 likes - user on date: \"Hello world.\""
        XCTAssertEqual(
            InstagramExtractor.parseCaptionSnippet(ogDescription: og),
            "Hello world"
        )
    }

    // MARK: - parseOwnerFromOGTitle / OGDescription

    func testParseOwnerFromOGTitle() {
        let title = "chefjohnsmith on Instagram: \"BEST cookies\""
        XCTAssertEqual(InstagramExtractor.parseOwnerFromOGTitle(title), "chefjohnsmith")
    }

    func testParseOwnerFromOGTitleStripsAtPrefix() {
        let title = "@chef.john on Instagram: …"
        XCTAssertEqual(InstagramExtractor.parseOwnerFromOGTitle(title), "chef.john")
    }

    func testParseOwnerFromOGTitleRejectsLongNoise() {
        // Defensive guard against pathological titles
        let title = String(repeating: "x", count: 200) + " on Instagram: …"
        XCTAssertNil(InstagramExtractor.parseOwnerFromOGTitle(title))
    }

    func testParseOwnerFromOGDescription() {
        let desc = "162K likes, 155 comments - chefjohnsmith on August 5, 2025: \"recipe\""
        XCTAssertEqual(InstagramExtractor.parseOwnerFromOGDescription(desc), "chefjohnsmith")
    }

    // MARK: - metaContent

    func testMetaContentExtractsOGTitle() {
        let html = #"<html><head><meta property="og:title" content="user on Instagram: hi" /></head></html>"#
        XCTAssertEqual(
            InstagramExtractor.metaContent(html: html, property: "og:title"),
            "user on Instagram: hi"
        )
    }

    func testMetaContentTolerantToAttributeOrder() {
        let html = #"<meta content="value-here" property="og:description">"#
        XCTAssertEqual(
            InstagramExtractor.metaContent(html: html, property: "og:description"),
            "value-here"
        )
    }

    func testMetaContentDecodesEntities() {
        let html = #"<meta property="og:description" content="A &amp; B &quot;quoted&quot;" />"#
        XCTAssertEqual(
            InstagramExtractor.metaContent(html: html, property: "og:description"),
            "A & B \"quoted\""
        )
    }

    // MARK: - parseOpenGraph

    func testParseOpenGraphHappyPath() {
        let html = """
        <html><head>
        <meta property="og:title" content="chefjohn on Instagram: my reel" />
        <meta property="og:description" content="100 likes, 5 comments - chefjohn on Aug 5, 2025: &quot;Banana bread recipe&quot;" />
        <meta property="og:image" content="https://scontent.cdninstagram.com/v/thumb.jpg" />
        <meta property="og:video" content="https://scontent.cdninstagram.com/v/video.mp4" />
        </head></html>
        """
        let result = InstagramExtractor.parseOpenGraph(html: html)
        XCTAssertEqual(result.ownerHandle, "chefjohn")
        XCTAssertEqual(result.captionText, "Banana bread recipe")
        XCTAssertEqual(result.thumbnailURL?.absoluteString, "https://scontent.cdninstagram.com/v/thumb.jpg")
        XCTAssertEqual(result.videoURL?.absoluteString, "https://scontent.cdninstagram.com/v/video.mp4")
        XCTAssertFalse(result.capturedFullCaption)
    }

    func testParseOpenGraphFallsBackToSecureVideoURL() {
        let html = """
        <meta property="og:video:secure_url" content="https://secure.example.com/v.mp4" />
        """
        let result = InstagramExtractor.parseOpenGraph(html: html)
        XCTAssertEqual(result.videoURL?.absoluteString, "https://secure.example.com/v.mp4")
    }

    // MARK: - scriptJSONBlocks

    func testScriptJSONBlocksFindsLDJSON() {
        let html = """
        <html><head>
        <script type="application/ld+json">{"@type":"VideoObject","description":"hello"}</script>
        <script type="application/json">{"foo":1}</script>
        </head></html>
        """
        let ldBlocks = InstagramExtractor.scriptJSONBlocks(html: html, type: "application/ld+json")
        XCTAssertEqual(ldBlocks.count, 1)
        XCTAssertTrue(ldBlocks[0].contains("VideoObject"))

        let jsonBlocks = InstagramExtractor.scriptJSONBlocks(html: html, type: "application/json")
        XCTAssertEqual(jsonBlocks.count, 1)
        XCTAssertTrue(jsonBlocks[0].contains("foo"))
    }

    // MARK: - parseInlineJSON

    func testParseInlineJSONVideoObjectFullCaption() {
        let captionBody = """
        Banana bread recipe!\n\nIngredients:\n- 3 bananas\n- 1 cup flour\n\nSteps:\n1. Mash bananas\n2. Mix and bake
        """
        let html = """
        <html><head>
        <script type="application/ld+json">
        {
          "@context": "https://schema.org",
          "@type": "VideoObject",
          "name": "Reel by chefjohn",
          "description": "\(captionBody.replacingOccurrences(of: "\n", with: "\\n"))",
          "thumbnailUrl": "https://scontent.cdninstagram.com/thumb.jpg",
          "contentUrl": "https://scontent.cdninstagram.com/video.mp4",
          "author": { "@type": "Person", "alternateName": "chefjohn" }
        }
        </script>
        </head></html>
        """
        let result = InstagramExtractor.parseInlineJSON(html: html)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.ownerHandle, "chefjohn")
        XCTAssertTrue(result?.captionText.contains("Banana bread recipe") ?? false)
        XCTAssertTrue(result?.captionText.contains("3 bananas") ?? false,
                      "Expected full caption (not truncated): \(result?.captionText ?? "")")
        XCTAssertEqual(result?.thumbnailURL?.absoluteString,
                       "https://scontent.cdninstagram.com/thumb.jpg")
        XCTAssertEqual(result?.videoURL?.absoluteString,
                       "https://scontent.cdninstagram.com/video.mp4")
    }

    func testParseInlineJSONIGHydrationCaptionTextShape() {
        // Simulates the "caption":{"text":"…"} shape IG has shipped in
        // hydration blobs. The walker should pluck the text out
        // regardless of how deeply nested it is.
        let html = """
        <script type="application/json">
        {
          "result": {
            "data": {
              "xdt_shortcode_media": {
                "caption": { "text": "Full caption from IG hydration" },
                "video_url": "https://example.com/v.mp4",
                "display_url": "https://example.com/t.jpg",
                "owner": { "username": "chefjohn" }
              }
            }
          }
        }
        </script>
        """
        let result = InstagramExtractor.parseInlineJSON(html: html)
        XCTAssertEqual(result?.captionText, "Full caption from IG hydration")
        XCTAssertEqual(result?.ownerHandle, "chefjohn")
        XCTAssertEqual(result?.videoURL?.absoluteString, "https://example.com/v.mp4")
        XCTAssertEqual(result?.thumbnailURL?.absoluteString, "https://example.com/t.jpg")
    }

    func testParseInlineJSONReturnsNilWhenNothingUseful() {
        let html = """
        <script type="application/ld+json">{"@type":"Person","name":"Someone"}</script>
        """
        XCTAssertNil(InstagramExtractor.parseInlineJSON(html: html))
    }

    // MARK: - decodeHTMLEntities

    func testDecodeHTMLEntitiesCommonSet() {
        XCTAssertEqual(
            InstagramExtractor.decodeHTMLEntities("Tom &amp; Jerry &quot;rule&quot;"),
            "Tom & Jerry \"rule\""
        )
        XCTAssertEqual(
            InstagramExtractor.decodeHTMLEntities("&lt;span&gt;hi&lt;/span&gt;"),
            "<span>hi</span>"
        )
        XCTAssertEqual(
            InstagramExtractor.decodeHTMLEntities("a&nbsp;b"),
            "a b"
        )
    }
}
