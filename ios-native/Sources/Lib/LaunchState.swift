import Foundation

/// First-run / first-launch-after-update tracking.
///
/// Drives two coupled behaviors aimed at getting the user to set the two
/// fields friends actually see — their display name and accent color:
///   1. RootView opens on the Profile tab on a fresh install OR the first
///      launch after a version bump (so they notice they can set a name).
///   2. ProfileView shows a one-time "pick your color for your friends to
///      see!" callout.
///
/// Both are gated on the user still being on the **default accent**, so a
/// user who has already chosen a color is never re-routed or nagged.
///
/// All state is device-local `UserDefaults` — purely additive, no
/// migration. Existing installs upgrading from a build without these keys
/// read the absent keys as "first run", which is exactly what we want: an
/// upgrade to the version that introduces this feature routes the user to
/// Profile once.
///
/// The pure decision logic lives in `evaluateRoute` / `evaluateColorNudge`
/// (no `UserDefaults` / `Bundle` dependency) so it can be unit-tested; the
/// computed-property wrappers feed those the persisted values.
enum LaunchState {
    private static let hasCompletedFirstRunKey = "launch.hasCompletedFirstRun"
    private static let lastSeenAppVersionKey = "launch.lastSeenAppVersion"
    private static let colorNudgeDismissedVersionKey = "nudge.colorDismissedVersion"

    private static var defaults: UserDefaults { .standard }

    // MARK: - Pure decision logic (unit-tested)

    /// Open the app on Profile when the user is still on the default accent
    /// AND this is either a fresh install or the first launch after a
    /// version change. `lastSeenVersion == nil` is treated as "not an
    /// update" — a nil version is a fresh/upgraded install already covered
    /// by `isFirstEverRun`, so we don't double-count it as an update.
    static func evaluateRoute(
        isOnDefaultAccent: Bool,
        isFirstEverRun: Bool,
        lastSeenVersion: String?,
        currentVersion: String
    ) -> Bool {
        guard isOnDefaultAccent else { return false }
        let isFirstRunAfterUpdate = lastSeenVersion != nil && lastSeenVersion != currentVersion
        return isFirstEverRun || isFirstRunAfterUpdate
    }

    /// Show the color nudge while on the default accent and the nudge hasn't
    /// been dismissed for the current version. Picking any color flips
    /// `isOnDefaultAccent` false and closes the callout automatically.
    static func evaluateColorNudge(
        isOnDefaultAccent: Bool,
        dismissedVersion: String?,
        currentVersion: String
    ) -> Bool {
        guard isOnDefaultAccent else { return false }
        return dismissedVersion != currentVersion
    }

    // MARK: - Persisted signals

    /// True while the user has never committed a custom accent color.
    /// Delegates to `AppearanceSettings` so the underlying UserDefaults
    /// key lives in exactly one place.
    static var isOnDefaultAccent: Bool {
        !AppearanceSettings.hasUserPickedAccent
    }

    private static var isFirstEverRun: Bool {
        !defaults.bool(forKey: hasCompletedFirstRunKey)
    }

    /// Read once at RootView init (so there's no visible Home→Profile flip
    /// on launch). Deep-link cold-launches still present their content over
    /// whatever tab is selected, so routing here never breaks an import.
    static var shouldRouteToProfileOnLaunch: Bool {
        evaluateRoute(
            isOnDefaultAccent: isOnDefaultAccent,
            isFirstEverRun: isFirstEverRun,
            lastSeenVersion: defaults.string(forKey: lastSeenAppVersionKey),
            currentVersion: AppMetadata.currentAppVersion
        )
    }

    /// Whether to surface the "pick your color" callout in Profile.
    static var shouldShowColorNudge: Bool {
        evaluateColorNudge(
            isOnDefaultAccent: isOnDefaultAccent,
            dismissedVersion: defaults.string(forKey: colorNudgeDismissedVersionKey),
            currentVersion: AppMetadata.currentAppVersion
        )
    }

    // MARK: - Mutations

    /// Record that the current version has launched. Call once per cold
    /// launch, AFTER `shouldRouteToProfileOnLaunch` has been read.
    /// Idempotent — safe to call again on a SwiftUI re-init.
    static func markLaunched() {
        defaults.set(true, forKey: hasCompletedFirstRunKey)
        defaults.set(AppMetadata.currentAppVersion, forKey: lastSeenAppVersionKey)
    }

    /// Suppress the color nudge until the next version bump.
    static func dismissColorNudgeForThisVersion() {
        defaults.set(AppMetadata.currentAppVersion, forKey: colorNudgeDismissedVersionKey)
    }
}
