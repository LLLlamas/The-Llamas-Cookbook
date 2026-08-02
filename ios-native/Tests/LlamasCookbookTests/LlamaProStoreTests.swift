import XCTest
import CryptoKit
@testable import LlamasCookbook

@MainActor
final class LlamaProStoreTests: XCTestCase {

    // MARK: - Plan.isPro

    func testPlanNoneIsNotPro() {
        XCTAssertFalse(LlamaProStore.Plan.none.isPro)
    }

    func testPlanMonthlyIsPro() {
        XCTAssertTrue(LlamaProStore.Plan.monthly.isPro)
    }

    func testPlanYearlyIsPro() {
        XCTAssertTrue(LlamaProStore.Plan.yearly.isPro)
    }

    // MARK: - Plan.displayLabel

    func testPlanNoneDisplayLabelIsEmpty() {
        XCTAssertEqual(LlamaProStore.Plan.none.displayLabel, "")
    }

    func testPlanMonthlyDisplayLabel() {
        XCTAssertEqual(LlamaProStore.Plan.monthly.displayLabel, "Llama Pro Monthly")
    }

    func testPlanYearlyDisplayLabel() {
        XCTAssertEqual(LlamaProStore.Plan.yearly.displayLabel, "Llama Pro Yearly")
    }

    // MARK: - appAccountToken

    func testNilSubReturnsNil() {
        XCTAssertNil(LlamaProStore.appAccountToken(for: nil))
    }

    func testEmptySubReturnsNil() {
        XCTAssertNil(LlamaProStore.appAccountToken(for: ""))
    }

    func testValidSubReturnsNonNilUUID() {
        XCTAssertNotNil(LlamaProStore.appAccountToken(for: "apple.siwa.sub.001"))
    }

    func testTokenIsVersion4() {
        let token = LlamaProStore.appAccountToken(for: "apple.siwa.sub.001")!
        // UUID version is encoded in the high nibble of byte 7 (third group, first char = "4")
        let uuidString = token.uuidString.lowercased()
        let thirdGroup = uuidString.split(separator: "-")[2]
        XCTAssertEqual(thirdGroup.first, "4")
    }

    func testTokenRFC4122Variant() {
        let token = LlamaProStore.appAccountToken(for: "apple.siwa.sub.001")!
        let uuidString = token.uuidString.lowercased()
        let fourthGroup = String(uuidString.split(separator: "-")[3])
        let nibble = Int(String(fourthGroup.first!), radix: 16)!
        XCTAssertGreaterThanOrEqual(nibble, 8)
        XCTAssertLessThanOrEqual(nibble, 11)
    }

    func testTokenIsDeterministic() {
        let sub = "fixed-determinism-sub"
        let t1 = LlamaProStore.appAccountToken(for: sub)
        let t2 = LlamaProStore.appAccountToken(for: sub)
        XCTAssertEqual(t1, t2)
    }

    func testDifferentSubsProduceDifferentTokens() {
        let t1 = LlamaProStore.appAccountToken(for: "user-aaa")
        let t2 = LlamaProStore.appAccountToken(for: "user-bbb")
        XCTAssertNotEqual(t1, t2)
    }

    func testTokenMatchesManualSHA256Derivation() {
        // Independently derive expected UUID from the same algorithm to pin against drift.
        let sub = "pinned-test-sub"
        var bytes = Array(SHA256.hash(data: Data(sub.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let expected = UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        XCTAssertEqual(LlamaProStore.appAccountToken(for: sub), expected)
    }
}
