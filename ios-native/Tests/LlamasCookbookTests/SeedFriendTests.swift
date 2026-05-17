import XCTest
@testable import LlamasCookbookNative

final class SeedFriendTests: XCTestCase {

    // MARK: - Sentinel record name

    func testSentinelRecordName() {
        XCTAssertEqual(SeedFriend.sentinelRecordName, "your-llama-seed")
    }

    // MARK: - isSeed predicate

    func testIsSeedReturnsTrueForSeedProfile() {
        XCTAssertTrue(SeedFriend.isSeed(SeedFriend.profile))
    }

    func testIsSeedReturnsFalseForRealUser() {
        let realUser = UserProfileSnapshot(
            userRecordName: "profile_realCloudKitUserID",
            displayName: "Alice",
            accentHex: nil,
            createdAt: Date(),
            lastCookedAt: nil,
            lastCookedRecipeID: nil,
            lastCookedTitle: nil,
            cookingStartedAt: nil
        )
        XCTAssertFalse(SeedFriend.isSeed(realUser))
    }

    // MARK: - profile snapshot fields

    func testProfileUserRecordName() {
        XCTAssertEqual(SeedFriend.profile.userRecordName, SeedFriend.sentinelRecordName)
    }

    func testProfileDisplayName() {
        XCTAssertEqual(SeedFriend.profile.displayName, "Your Llama")
    }

    func testProfileAccentHex() {
        XCTAssertEqual(SeedFriend.profile.accentHex, "#C97C5D")
    }

    func testProfileIsStableAcrossAccesses() {
        // Ensures the lazy static let returns the same instance each time
        // (no fatalError from loadPayload being triggered).
        let p1 = SeedFriend.profile
        let p2 = SeedFriend.profile
        XCTAssertEqual(p1, p2)
    }
}
