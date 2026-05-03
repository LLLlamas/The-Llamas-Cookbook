import SwiftUI
import SwiftData
import UIKit
import UserNotifications

@main
struct LlamasCookbookApp: App {
    @State private var appearance = AppearanceSettings()
    /// Sender display name for app-to-app recipe sharing. Sibling to
    /// `appearance` — both are persisted-preferences Observables, kept
    /// separate per the one-Observable-per-concern pattern. See
    /// Recipe-Sharing.md §7.4.
    @State private var ownerProfile = OwnerProfile()
    /// Sign-in-with-Apple identity + (PR 2+) cloud user binding.
    /// Sibling to `ownerProfile`; `OwnerProfile` continues to power
    /// the file/link share flow's display name until PR 2 routes that
    /// path through `UserAccount` instead. See
    /// Implementing-User-Sign-In.md §3.
    @State private var userAccount = UserAccount()
    /// Cached friends + pending-requests state for the social slice.
    /// Refreshed lazily from `ProfileView`'s `.task` and after every
    /// social mutation. Best-effort with respect to CloudKit
    /// availability — silently no-ops when iCloud is unavailable.
    /// See `FriendsStore` and `implement-social.md` slices 2+.
    @State private var friendsStore = FriendsStore()
    /// Cook-timer alert preferences (sound, in-app volume, vibration
    /// cadence). Sibling pattern to `appearance` — UserDefaults-backed
    /// `@Observable` injected at the top of the view tree so
    /// `CookModeView` (alarm + scheduled notification) and `ProfileView`
    /// (settings sheet) read from the same source.
    @State private var timerSettings = TimerSettings()
    /// Owns the UNUserNotificationCenter delegate. SwiftUI keeps this
    /// alive for the app lifetime so foreground notification handling
    /// (sound + banner while Cook Mode is minimized) keeps working.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // UIKit tint (keyboard Return key, text cursors, selection handles,
        // navigation back chevron when SwiftUI delegates to UIKit chrome)
        // is owned by `AppearanceSettings` — its init+didSet push the
        // current accent into `UIView.appearance().tintColor` so the
        // user's pick propagates to UIKit surfaces alongside SwiftUI's
        // own `.tint()` modifier.

        // Ask for notification permission up front so the first cooking
        // timer can schedule its background alert without an extra round-trip.
        TimerNotifications.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appearance)
                .environment(ownerProfile)
                .environment(userAccount)
                .environment(friendsStore)
                .environment(timerSettings)
                // The cream + terracotta palette has no dark-mode variant
                // (AppColor values are hard sRGB, not asset-catalog system
                // colors). Locking to light keeps SwiftUI's default fills
                // and sheet backgrounds rendering consistently — without
                // this, a tester whose phone is in dark mode sees the
                // Library scroll area fall through to system black.
                .preferredColorScheme(.light)
        }
        // Explicit ModelConfiguration with `cloudKitDatabase: .none` so
        // adding the iCloud entitlement (for the cloud-permalink share
        // path in `Lib/CloudKitService.swift`) doesn't accidentally
        // flip SwiftData into CloudKit-backed sync mode. Our schema
        // uses `.cascade` delete rules and several non-optional
        // properties without defaults, neither of which CloudKit-
        // backed SwiftData accepts — auto-opt-in would silently fail
        // container open and fall back to in-memory storage,
        // surfacing as "no recipes yet" + new recipes vanishing on
        // relaunch. (The app's CloudKit usage is *only* the share-
        // permalink path; SwiftData stays strictly local.)
        .modelContainer(Self.makeModelContainer())
    }

    @MainActor
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            Recipe.self,
            Ingredient.self,
            RecipeStep.self,
            RecipePhoto.self,
            RecipeStepPhoto.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            // Last-resort: in-memory so the app still launches and
            // the user sees a working UI rather than a crash. They'll
            // notice their recipes are missing and can report; we'll
            // see the underlying error on device console. Force-try
            // is OK here because the schema is fully defaulted —
            // in-memory always succeeds.
            let fallback = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            return try! ModelContainer(for: schema, configurations: fallback)
        }
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
        // Slice 6 — kick off the APNs registration handshake so
        // CloudKit's silent CKQuerySubscription pushes can reach
        // the app. iOS calls back through one of the two
        // `didRegister…` / `didFailToRegister…` methods below;
        // CloudKit auto-routes pushes via the device token, so
        // we don't have to do anything with the token ourselves.
        // Idempotent — calling on every launch is the documented
        // pattern (the token can rotate between launches and
        // CloudKit needs the current one).
        application.registerForRemoteNotifications()
        return true
    }

    /// APNs registration succeeded. CloudKit reads the device
    /// token internally for subscription delivery routing — we
    /// don't need to forward it anywhere ourselves. No-op
    /// implementation required because UIKit logs an error
    /// without it.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Intentionally empty — CloudKit handles the token.
    }

    /// APNs registration failed (no entitlement, simulator without
    /// push support, network denied push registration, etc.).
    /// Silent — slice 6's pushes degrade to "user picks up
    /// changes on next foreground refresh," which is the slice
    /// 1-5 baseline behavior. The console log is enough for
    /// post-mortem if a real device fails to register.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[CloudKitSubscriptions] APNs registration failed: \(error.localizedDescription)")
    }

    /// Silent CKQuerySubscription push receipt. The payload's
    /// shape is fully determined by CloudKit (we don't custom-
    /// craft anything in the push); `CloudKitSubscriptions`
    /// inspects the subscriptionID to figure out which of our
    /// two streams fired and posts a NotificationCenter event
    /// for in-app observers (FriendsStore, RecipeDetailView).
    /// Returning `.newData` so iOS knows we acted on the push
    /// (better future-proofing if Apple ever throttles apps
    /// that report `.noData` repeatedly).
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let kind = CloudKitSubscriptions.dispatchRemoteNotification(userInfo: userInfo)
        completionHandler(kind == nil ? .noData : .newData)
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
