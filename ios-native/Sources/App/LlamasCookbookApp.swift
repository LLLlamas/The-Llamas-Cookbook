import SwiftUI
import SwiftData
import UIKit
import UserNotifications

@main
struct LlamasCookbookApp: App {
    @State private var appearance = AppearanceSettings()
    /// Owns the UNUserNotificationCenter delegate. SwiftUI keeps this
    /// alive for the app lifetime so foreground notification handling
    /// (sound + banner while Cook Mode is minimized) keeps working.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Propagate accent to UIKit surfaces (keyboard Return key, text cursors,
        // selection handles) that read UIView.tintColor before SwiftUI's .tint()
        // reaches them. Stays at the default terracotta — keyboard tint follows
        // the design baseline rather than the user's pick to avoid an extra
        // UIKit refresh dance on every color change.
        UIView.appearance().tintColor = UIColor(AppColor.accent)

        // Ask for notification permission up front so the first cooking
        // timer can schedule its background alert without an extra round-trip.
        TimerNotifications.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appearance)
                // The cream + terracotta palette has no dark-mode variant
                // (AppColor values are hard sRGB, not asset-catalog system
                // colors). Locking to light keeps SwiftUI's default fills
                // and sheet backgrounds rendering consistently — without
                // this, a tester whose phone is in dark mode sees the
                // Library scroll area fall through to system black.
                .preferredColorScheme(.light)
        }
        .modelContainer(for: [Recipe.self, Ingredient.self, RecipeStep.self])
    }
}

/// Routes UNUserNotificationCenter callbacks. The interesting one is
/// `willPresent` — by default iOS swallows local notifications when the
/// app is foregrounded, which made the cook timer fall completely silent
/// when the user had Cook Mode minimized and was browsing other recipes.
/// Returning `[.banner, .sound, .list]` here re-enables the alert + ding
/// + lock-screen-style vibration while in-app.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Tap on a delivered timer notification → re-open the relevant
    /// Cook Mode session. Routes through the `llamascookbook://cook/<uuid>`
    /// scheme that the Live Activity widget already uses, so a single
    /// `onOpenURL` handler in RootView covers both entry points.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let raw = info[TimerNotifications.recipeIDUserInfoKey] as? String,
           let id = UUID(uuidString: raw),
           let url = URL(string: "llamascookbook://cook/\(id.uuidString)") {
            // Defer to the next runloop tick — by the time the system
            // hands us this callback the scene is settling, and opening
            // the URL synchronously can race with that. async-on-main
            // schedules it after the foreground transition completes.
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
        completionHandler()
    }
}
