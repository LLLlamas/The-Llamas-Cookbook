import XCTest
@testable import LlamasCookbookNative

final class RecipeImporterTests: XCTestCase {

    // MARK: - cleanTitle

    func testCleanTitlePassthrough() {
        XCTAssertEqual(RecipeImporter.cleanTitle("Banana Bread"), "Banana Bread")
    }

    func testCleanTitleStripsColonLabel() {
        XCTAssertEqual(RecipeImporter.cleanTitle("Title: Banana Bread"), "Banana Bread")
    }

    func testCleanTitleStripsRecipeEmoji() {
        // "Recipe👇 Foo" — TikTok-style caption prefix
        XCTAssertEqual(RecipeImporter.cleanTitle("Recipe👇 Sourdough Loaf"), "Sourdough Loaf")
    }

    func testCleanTitleStripsRecipeColon() {
        XCTAssertEqual(RecipeImporter.cleanTitle("Recipe: Banana Bread"), "Banana Bread")
    }

    func testCleanTitleStripsTrailingEmoji() {
        let result = RecipeImporter.cleanTitle("Sourdough!😍🙌")
        XCTAssertFalse(result.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 127 },
                       "Expected trailing emoji stripped from '\(result)'")
        XCTAssertTrue(result.hasPrefix("Sourdough"))
    }

    func testCleanTitleFilePathReturnsEmpty() {
        // A path with "/" and an image extension should signal callers to fall back.
        XCTAssertEqual(RecipeImporter.cleanTitle("/var/tmp/IMG_001.jpg"), "")
    }

    func testCleanTitleNonImagePathPassthrough() {
        // "/" present but not a known image extension — should NOT be treated as filename.
        let result = RecipeImporter.cleanTitle("Chicken/Vegetable Stir Fry")
        XCTAssertFalse(result.isEmpty, "Expected non-empty for '\(result)'")
    }

    func testCleanTitleBioMarkerStripped() {
        // Bio-style markers like "↓" at the start should be stripped.
        let result = RecipeImporter.cleanTitle("↓ Banana Bread")
        XCTAssertFalse(result.hasPrefix("↓"))
    }

    // MARK: - mergeOrphanDurationSteps

    func testMergeGluesPureDurationOntoPreceeding() {
        let step1 = DraftStep(text: "Bake at 425°")
        let step2 = DraftStep(text: "10 mins")
        let merged = RecipeImporter.mergeOrphanDurationSteps([step1, step2])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].text.contains("10 mins"))
        XCTAssertTrue(merged[0].text.contains("Bake at 425°"))
    }

    func testMergePreservesNonDurationSteps() {
        let step1 = DraftStep(text: "Mix the flour and water")
        let step2 = DraftStep(text: "Knead until smooth")
        let merged = RecipeImporter.mergeOrphanDurationSteps([step1, step2])
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeKeepsFirstStepEvenIfPureDuration() {
        // No prior step to merge into — preserve as-is.
        let step1 = DraftStep(text: "30 minutes")
        let step2 = DraftStep(text: "Bake at 350°")
        let merged = RecipeImporter.mergeOrphanDurationSteps([step1, step2])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].text, "30 minutes")
    }

    func testMergeStripsTrailingCommaBeforeGluing() {
        let step1 = DraftStep(text: "Bake at 425°,")
        let step2 = DraftStep(text: "10 mins")
        let merged = RecipeImporter.mergeOrphanDurationSteps([step1, step2])
        XCTAssertEqual(merged.count, 1)
        XCTAssertFalse(merged[0].text.contains(",,"), "Should not double-comma")
        XCTAssertTrue(merged[0].text.contains("Bake at 425°, 10 mins"))
    }

    func testMergeEmptyInputReturnsEmpty() {
        XCTAssertEqual(RecipeImporter.mergeOrphanDurationSteps([]).count, 0)
    }
}
