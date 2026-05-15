import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import os

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
    @State private var friendsStore  = FriendsStore()
    /// Photo-import quota state. Polls /api/usage and /api/usage/consume via
    /// the Cloudflare Worker. Injected into the environment so any view in
    /// the hierarchy can read quota state or fire a consume call.
    @State private var quotaService  = QuotaService()
    /// StoreKit 2 wrapper for Llama Pro subscriptions. Phase 1: isPro = false.
    @State private var llamaProStore = LlamaProStore()
    /// Owns the UNUserNotificationCenter delegate. SwiftUI keeps this
    /// alive for the app lifetime so foreground notification handling
    /// (sound + banner while Cook Mode is minimized) keeps working.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // No `init()` is needed — the two cold-launch concerns are owned
    // elsewhere:
    //
    // - UIKit tint (keyboard Return key, text cursors, selection
    //   handles, navigation back chevron when SwiftUI delegates to
    //   UIKit chrome) is owned by `AppearanceSettings` — its
    //   init+didSet push the current accent into
    //   `UIView.appearance().tintColor` so the user's pick propagates
    //   to UIKit surfaces alongside SwiftUI's own `.tint()` modifier.
    // - AlarmKit auth is requested lazily from `CookModeView.onAppear`
    //   — prompting at cold launch (before the user has any concept of
    //   a "cooking timer") would feel mysterious. The first time they
    //   open Cook Mode is when the dialog earns its keep.

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appearance)
                .environment(ownerProfile)
                .environment(userAccount)
                .environment(friendsStore)
                .environment(quotaService)
                .environment(llamaProStore)
                .task { await llamaProStore.start() }
                // The cream + terracotta palette has no dark-mode variant
                // (AppColor values are hard sRGB, not asset-catalog system
                // colors). Locking to light keeps SwiftUI's default fills
                // and sheet backgrounds rendering consistently — without
                // this, a tester whose phone is in dark mode sees the
                // Library scroll area fall through to system black.
                .preferredColorScheme(.light)
                .onAppear {
                    // Ensure the accent is terracotta on cold launch when
                    // the user is not signed in (e.g. fresh install or after
                    // a prior sign-out). The stored preference is kept intact
                    // in UserDefaults so `restoreFromDefaults` can recover it.
                    if !userAccount.status.isSignedIn {
                        appearance.applySignedOut()
                    }
                }
                .onChange(of: userAccount.status.isSignedIn) { _, isSignedIn in
                    if isSignedIn {
                        appearance.restoreFromDefaults()
                        Task { await llamaProStore.checkCurrentEntitlements() }
                    } else {
                        appearance.applySignedOut()
                        llamaProStore.signOut()
                    }
                }
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
    private static let logger = Logger(
        subsystem: "com.llamascookbook.app",
        category: "AppDelegate"
    )

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Kick off the APNs registration handshake so CloudKit's
        // silent CKQuerySubscription pushes can reach the app.
        // iOS calls back through one of the two
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
    /// token internally for subscription delivery routing, so we
    /// don't have to forward the bytes anywhere ourselves. We DO
    /// hand the token to `CloudKitSubscriptions.noteAPNsTokenChanged`
    /// which detects rotation across launches — when the token
    /// rotates (privacy reset, iCloud account state change, or a
    /// device-restore reinstall) any previously-saved CKQuerySubscription
    /// keeps delivering to the stale token, silently stopping pushes
    /// until the subscription is re-saved. The helper persists a
    /// hash of the token so a subsequent `registerIfNeeded` call from
    /// `RootView.task` knows to re-save.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        CloudKitSubscriptions.noteAPNsTokenChanged(deviceToken)
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
        Self.logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
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

    /// Tap on a delivered notification → re-open the relevant Cook
    /// Mode session if a recipe id is present. Cooking-timer alerts
    /// route through AlarmKit now (which doesn't deliver via this
    /// callback), so this path is effectively reserved for legacy /
    /// future UN-delivered notifications that piggyback the same
    /// `recipeID` userInfo key.
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
