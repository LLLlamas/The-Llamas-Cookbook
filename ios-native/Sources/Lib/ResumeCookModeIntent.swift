import AppIntents
import Foundation

/// AlarmKit secondary-button intent: when a cook timer fires on the
/// lock screen, the user taps this button to dismiss the alarm AND
/// foreground the app directly into Cook Mode for the recipe whose
/// timer just rang.
///
/// Why a secondary button and not Stop: AlarmKit's primary "Stop"
/// button is system-controlled — its `AlarmButton` only carries
/// `text` / `textColor` / `systemImageName`, with no `intent` hook.
/// The way to deliver "tap-to-resume-cooking" UX is a custom
/// secondary button with `secondaryButtonBehavior: .custom` and the
/// intent wired through `AlarmConfiguration.secondaryIntent`. See
/// `TimerNotifications.swift` for the wiring.
///
/// `LiveActivityIntent` (from AppIntents) is the protocol AlarmKit
/// recognizes for secondary-button actions. `openAppWhenRun = true`
/// tells iOS to foreground the app on perform — without it, the
/// intent runs in the extension process and the user stays on the
/// lock screen.
///
/// Routing: `perform()` posts an in-process notification carrying the
/// recipeID. `RootView` observes it and re-enters the existing
/// `routeCookDeepLink(_:)` path, so cold-launch restore + multi-cook
/// foregrounding logic stays in one place. Synthesizing a
/// `llamascookbook://cook/<id>` URL and firing it through `onOpenURL`
/// would also work, but `UIApplication.open(_:)` from a non-main
/// actor in an intent context is fragile across iOS 26 betas;
/// NotificationCenter is the same pattern `CloudKitSubscriptions`
/// already uses to bridge AppDelegate-scope events into the SwiftUI
/// graph.
///
/// No struct-level `@available` annotation: `LiveActivityIntent` is
/// iOS 17+ and the deploy target is 26.0, so the type compiles
/// everywhere. The AlarmKit wiring that *uses* the intent
/// (`TimerNotifications.schedule`) gates itself with
/// `#available(iOS 26.1, *)`, so on a 26.0 device the intent is
/// simply never instantiated and never reached.
struct ResumeCookModeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Open Cook Mode"
    static var description = IntentDescription("Returns to Cook Mode for the recipe whose timer just rang.")

    /// AlarmKit invokes the intent in a process where this flag tells
    /// iOS to foreground the main app before `perform()` resolves.
    static var openAppWhenRun: Bool = true

    /// `@Parameter` types are constrained to a small set; `UUID` is
    /// not directly representable, so we pass the `uuidString` and
    /// decode in `perform`. Caller (`TimerNotifications.schedule`)
    /// passes `recipeID.uuidString`.
    @Parameter(title: "Recipe ID")
    var recipeID: String

    init() {
        self.recipeID = ""
    }

    init(recipeID: String) {
        self.recipeID = recipeID
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: recipeID) {
            // Hop to the main actor so the post is observed off the
            // SwiftUI main run loop — `RootView`'s `.onReceive` is
            // wired on the default scheduler.
            await MainActor.run {
                NotificationCenter.default.post(
                    name: ResumeCookModeIntent.didRequestNotification,
                    object: nil,
                    userInfo: [ResumeCookModeIntent.recipeIDUserInfoKey: id]
                )
            }
        }
        return .result()
    }

    /// Posted when the user taps the alarm's "Open" secondary button.
    /// `RootView` observes this and re-enters the existing cook deep-link
    /// routing path.
    static let didRequestNotification = Notification.Name("resumeCookModeRequested")

    /// Key on the notification's `userInfo` carrying the `UUID`
    /// recipe id `RootView` should foreground a cook for.
    static let recipeIDUserInfoKey = "recipeID"
}
