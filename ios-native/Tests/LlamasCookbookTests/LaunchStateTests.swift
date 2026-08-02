import XCTest
@testable import LlamasCookbook

/// Covers the pure first-run / first-launch-after-update decision logic in
/// `LaunchState`. The UserDefaults/Bundle-backed wrappers are integration
/// concerns (not tested by design); the `evaluate*` functions are pure and
/// carry the actual routing/nudge rules.
final class LaunchStateTests: XCTestCase {

    // MARK: - evaluateRoute

    func testFreshInstallOnDefaultRoutes() {
        // First-ever run, no stored version, still on default accent.
        XCTAssertTrue(LaunchState.evaluateRoute(
            isOnDefaultAccent: true,
            isFirstEverRun: true,
            lastSeenVersion: nil,
            currentVersion: "1.1.0"
        ))
    }

    func testFirstLaunchAfterUpdateOnDefaultRoutes() {
        // Existing install, version bumped, still on default accent.
        XCTAssertTrue(LaunchState.evaluateRoute(
            isOnDefaultAccent: true,
            isFirstEverRun: false,
            lastSeenVersion: "1.0.0",
            currentVersion: "1.1.0"
        ))
    }

    func testSameVersionRelaunchDoesNotRoute() {
        XCTAssertFalse(LaunchState.evaluateRoute(
            isOnDefaultAccent: true,
            isFirstEverRun: false,
            lastSeenVersion: "1.1.0",
            currentVersion: "1.1.0"
        ))
    }

    func testCustomAccentNeverRoutes_evenOnUpdate() {
        // User has picked a color — never pull them to Profile, ever.
        XCTAssertFalse(LaunchState.evaluateRoute(
            isOnDefaultAccent: false,
            isFirstEverRun: false,
            lastSeenVersion: "1.0.0",
            currentVersion: "1.1.0"
        ))
    }

    func testCustomAccentNeverRoutes_evenOnFreshInstall() {
        XCTAssertFalse(LaunchState.evaluateRoute(
            isOnDefaultAccent: false,
            isFirstEverRun: true,
            lastSeenVersion: nil,
            currentVersion: "1.1.0"
        ))
    }

    func testNilLastSeenWithNotFirstRunDoesNotDoubleCountAsUpdate() {
        // Defensive: a non-first run with no stored version is treated as
        // "not an update" so it doesn't route on a stale/cleared key.
        XCTAssertFalse(LaunchState.evaluateRoute(
            isOnDefaultAccent: true,
            isFirstEverRun: false,
            lastSeenVersion: nil,
            currentVersion: "1.1.0"
        ))
    }

    // MARK: - evaluateColorNudge

    func testNudgeShownOnDefaultWhenNotDismissed() {
        XCTAssertTrue(LaunchState.evaluateColorNudge(
            isOnDefaultAccent: true,
            dismissedVersion: nil,
            currentVersion: "1.1.0"
        ))
    }

    func testNudgeHiddenWhenDismissedForCurrentVersion() {
        XCTAssertFalse(LaunchState.evaluateColorNudge(
            isOnDefaultAccent: true,
            dismissedVersion: "1.1.0",
            currentVersion: "1.1.0"
        ))
    }

    func testNudgeReappearsAfterVersionBump() {
        // Dismissed on an older version, then the app updated.
        XCTAssertTrue(LaunchState.evaluateColorNudge(
            isOnDefaultAccent: true,
            dismissedVersion: "1.0.0",
            currentVersion: "1.1.0"
        ))
    }

    func testNudgeNeverShownOnCustomAccent() {
        XCTAssertFalse(LaunchState.evaluateColorNudge(
            isOnDefaultAccent: false,
            dismissedVersion: nil,
            currentVersion: "1.1.0"
        ))
    }
}
