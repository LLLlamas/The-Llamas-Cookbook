import Foundation
import CloudKit
import CryptoKit
import os
import UIKit
import UserNotifications

/// Coordinator for the slice 6 CKQuerySubscription registrations
/// that turn the social slice's foreground-poll model into a
/// near-real-time push model.
///
/// **Subscription groups, all on the public DB:**
///
/// 1. `friendship-events-<me>` — fires on creation/update of any
///    `Friendship` record where I'm `userA` or `userB`. Covers
///    both inbound flows (someone sent me a request → record
///    created with me as participant) and the requester's
///    accepted-callback (my own pending record flips to
///    `accepted` → record updated with me as participant).
///
/// 2. `recipe-import-events-<me>` — fires on creation of any
///    `RecipeImport` record where I'm the chain-root creator.
///    Covers "Y imported your recipe" — bumps the importer count
///    on my own recipe detail and lets a foregrounded
///    `RecipeDetailView` re-fetch the importers list without
///    waiting for the user to leave + re-open the screen.
///
/// 3. `grocery-list-events-*` — fires for shared grocery list records
///    where I'm the owner or a recipient, so open list screens reconcile
///    in place.
///
/// 4. `grocery-list-alerts-<me>` — fires on creation of a
///    `GroceryListAlert` row when a shopper taps `!` on a list I own.
///
/// **Push payload shape.** Silent subscriptions use
/// `shouldSendContentAvailable = true` with no `alertBody`; grocery
/// recipient updates and out-of-stock alerts also include a visible title /
/// body / sound. iOS delivers the payload to
/// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
/// while the app is foregrounded or background-suspended; force-
/// killed apps don't get pushes (the user picks up changes via
/// the existing foreground-refresh path on next launch). Friendship and
/// recipe-import pushes stay silent; rendering "X accepted your friend
/// request" would need more denormalized schema than those flows currently
/// carry.
///
/// **Idempotency.** `save(subscription)` upserts by
/// `subscriptionID`, so calling `registerIfNeeded` on every
/// cold launch is safe — the second call replaces the first
/// with identical content. A local UserDefaults flag
/// short-circuits the registration after the first success per
/// `userRecordName` so we don't burn a CK round-trip on every
/// launch when nothing's changed; the flag is keyed by record
/// ID so a sign-in on a different Apple ID re-registers.
///
/// **Cleanup.** `unregisterAll(userRecordName:)` is called from
/// `UserAccount.signOut()` and `UserAccount.deleteAccount()` to
/// stop pushes against this device's APNs token after the user
/// goes away. Best-effort — orphaned subscriptions cost nothing
/// server-side and CloudKit eventually GCs them.
///
/// **Notification delivery.** When a push lands, the AppDelegate
/// hands the payload to `dispatchRemoteNotification(...)`, which
/// posts a `Notification.Name.cloudKitSubscriptionFired` to
/// `NotificationCenter.default` carrying the subscription ID.
/// `FriendsStore` and `RecipeDetailView` observe and refresh
/// their respective state — no direct coupling between
/// subscriptions and any specific consumer.
enum CloudKitSubscriptions {
    /// Registration is best-effort and used to be entirely silent, which
    /// made "no pushes arrive" indistinguishable from "pushes arrive and
    /// something downstream drops them" — the failure that cost the most
    /// time on the 2026-08 two-device run. Every save failure now names the
    /// subscription and the `CKError`, and `diagnostics()` reads the same
    /// state back on-device.
    private static let log = Logger(subsystem: "com.llamascookbook.app", category: "CloudKitSubscriptions")

    /// Outcome of the most recent `registerForRemoteNotifications()` round
    /// trip, written by `AppDelegate`. APNs registration failing is the one
    /// push precondition the app cannot infer from anything else — without
    /// a token, every CKSubscription is inert no matter how cleanly it saved.
    private static let apnsOutcomeKey = "cloudKitSubscriptions.lastAPNsOutcome.v1"

    /// Last `userRecordName` we successfully registered
    /// subscriptions for. Stops re-registration on every cold
    /// launch when nothing's changed; flips through whenever
    /// the user signs into a different Apple ID.
    /// Bumped `.v1` → `.v2` when the grocery-list-share subscriptions were
    /// added: existing users had already stamped `.v1` for their record ID
    /// and would otherwise skip re-registration and never pick up the new
    /// grocery streams. The version bump forces one re-register pass.
    /// Bumped `.v2` → `.v3` when the out-of-stock grocery alert subscription
    /// was added.
    /// Bumped `.v3` → `.v4` when the alert's push body switched to the
    /// localized "%@ couldn't find %@" form interpolating the
    /// `GroceryListAlert` record fields — the payload shape is baked into
    /// the saved subscription, so existing installs must re-register.
    /// Bumped `.v4` → `.v5` when the recipient stream split into a
    /// creation-only "X just shared a new grocery list with you" push and an
    /// update-only "the list changed" push. Both payloads are baked into the
    /// saved subscriptions, so existing installs must re-register to stop
    /// getting the old generic body on a first share.
    private static let registeredForKey = "cloudKitSubscriptions.registeredForRecordID.v5"

    /// Notification category on the "a friend shared a list with you" push.
    /// Carries the View / Close actions registered in `AppDelegate`, and is
    /// what `didReceive` matches on to route the tap to the list.
    static let groceryShareCategory = "GROCERY_SHARE_NEW"

    /// Action identifier for the push's "View List" button.
    static let groceryViewListAction = "GROCERY_VIEW_LIST"

    /// Action identifier for the push's explicit "Close" button. Handled as
    /// a no-op — it exists so the banner offers a symmetric choice rather
    /// than relying on the system swipe-to-clear alone.
    static let groceryDismissAction = "GROCERY_DISMISS"

    /// SHA-256 of the most recent APNs device token we observed at
    /// registration time. CKQuerySubscription delivery is bound to
    /// the APNs token captured server-side at subscription save —
    /// when iOS rotates the token (rare, but happens after privacy
    /// resets and some iCloud account state changes), the previously
    /// saved subscription's pushes go to the stale token and silently
    /// stop firing. We detect the rotation by hashing the token here
    /// (avoid persisting the token bytes themselves) and clearing
    /// `registeredForKey` so the next `registerIfNeeded` re-saves
    /// against the current token. Hash, not the raw token, because
    /// UserDefaults persistence of an APNs token has no upside and
    /// adds a small footprint of a per-device identifier.
    private static let lastTokenHashKey = "cloudKitSubscriptions.lastAPNsTokenHash.v1"

    // MARK: - Subscription identifiers

    /// Stable per-user subscription identifier for the friendship
    /// stream's userA half. CloudKit doesn't support `OR` across
    /// different fields in subscription predicates, so the symmetric
    /// "fire for any friendship I'm in" semantic requires two
    /// subscriptions — one matching `userA == me`, one matching
    /// `userB == me`. Both fire into the same NotificationCenter
    /// event so consumers don't need to know which half triggered.
    static func friendshipSubscriptionIDA(for me: String) -> String {
        "friendship-events-A-\(me)"
    }

    /// Stable per-user subscription identifier for the friendship
    /// stream's userB half. Pair with `friendshipSubscriptionIDA`.
    static func friendshipSubscriptionIDB(for me: String) -> String {
        "friendship-events-B-\(me)"
    }

    /// Stable per-user subscription identifier for the
    /// recipe-import stream. Same per-user scoping rationale as
    /// the friendship subscription above.
    static func recipeImportSubscriptionID(for me: String) -> String {
        "recipe-import-events-\(me)"
    }

    /// Per-user identifier for the FIRST-share half of the recipient stream
    /// (`recipientIDs CONTAINS me`, creation only). Visible, and the one
    /// push in the app that names names: "Sam just shared a new grocery list
    /// with you! “Weekend Shop”". Split out from the update half because a
    /// CKSubscription's payload is fixed at save time — one subscription
    /// covering create+update can only ever have one body, and "a list
    /// shared with you changed" is wrong for a list you're hearing about for
    /// the first time.
    static func groceryShareCreatedSubscriptionID(for me: String) -> String {
        "grocery-list-shared-\(me)"
    }

    /// Per-user identifier for the grocery-share stream where I'm a
    /// **recipient** (`recipientIDs CONTAINS me`), update half. Visible —
    /// the "the list you're shopping changed" banner. Creation is handled by
    /// `groceryShareCreatedSubscriptionID` above.
    static func groceryRecipientSubscriptionID(for me: String) -> String {
        "grocery-list-events-recipient-\(me)"
    }

    /// Per-user identifier for the grocery-share stream where I'm the
    /// **owner** (`ownerID == me`). Silent — it just refreshes my app so I
    /// see a shopper's check-offs live, without a banner for my own edits.
    static func groceryOwnerSubscriptionID(for me: String) -> String {
        "grocery-list-events-owner-\(me)"
    }

    /// Creation-only visible alerts when someone shopping one of my shared
    /// lists taps `!` because an item is unavailable.
    static func groceryAlertSubscriptionID(for me: String) -> String {
        "grocery-list-alerts-\(me)"
    }

    // MARK: - Register

    /// Idempotent register. Called from `RootView.task` (cold
    /// launch with persisted sign-in state) and from
    /// `UserAccount.completeSignIn` (immediately after SIWA).
    /// Skips silently when iCloud isn't bound (cached recordID
    /// is nil — same degradation as `LibraryMirrorService`).
    /// Skips fast when already registered for the current
    /// recordID. Re-registers when the recordID changed (e.g.
    /// signed in to a different Apple ID).
    ///
    /// **Best-effort semantics.** Network blip / schema not
    /// deployed yet → silent no-op. Next launch retries.
    /// Failure mode is "real-time pushes don't fire" — the
    /// foreground-refresh path still works, so the social
    /// features degrade rather than break.
    static func registerIfNeeded() async {
        guard let me = UserProfileMirror.cachedRecordID() else { return }
        let already = UserDefaults.standard.string(forKey: registeredForKey)
        if already == me { return }

        // Per-group, not one chained `do` — the groups are independent, and
        // a single chain meant a throw in the friendship group (saves 1-2 of
        // 7) silently starved the four grocery subscriptions that come after
        // it. The gate is only set when every group lands, so a partial
        // failure still retries on the next cold launch.
        var allSucceeded = true
        for (name, register) in registrationGroups(for: me) {
            do {
                try await register()
            } catch {
                allSucceeded = false
                log.error("subscription group \(name, privacy: .public) failed: \(UserProfileMirror.describeCloudKitError(error), privacy: .public)")
            }
        }
        guard allSucceeded else { return }
        UserDefaults.standard.set(me, forKey: registeredForKey)
    }

    /// The three registration groups, in the order they are attempted.
    /// Named so a failure log identifies which half of the push stack is
    /// down without needing a tethered console.
    private static func registrationGroups(
        for me: String
    ) -> [(String, () async throws -> Void)] {
        [
            ("friendship", { try await registerFriendshipSubscription(for: me) }),
            ("recipeImport", { try await registerRecipeImportSubscription(for: me) }),
            ("grocery", { try await registerGrocerySubscriptions(for: me) }),
        ]
    }

    private static func registerFriendshipSubscription(for me: String) async throws {
        // CloudKit subscription predicates don't support `OR` across
        // different fields, so we split into two single-field
        // subscriptions. Both produce identical NotificationInfo so
        // FriendsStore.observeRemotePushes treats them as one stream.
        try await saveFriendshipSubscription(
            id: friendshipSubscriptionIDA(for: me),
            predicate: NSPredicate(format: "userA == %@", me)
        )
        try await saveFriendshipSubscription(
            id: friendshipSubscriptionIDB(for: me),
            predicate: NSPredicate(format: "userB == %@", me)
        )
    }

    private static func saveFriendshipSubscription(
        id: String,
        predicate: NSPredicate
    ) async throws {
        let subscription = CKQuerySubscription(
            recordType: CloudKitService.friendshipRecordType,
            predicate: predicate,
            subscriptionID: id,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        // Silent push: wake the app, no banner. The app handler
        // refreshes `FriendsStore`, which the user sees on next
        // Profile open. shouldBadge is off because friend
        // activity isn't urgent enough to bump the home-screen
        // badge — keeping the badge for cooking timers only
        // preserves its signal value.
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
        subscription.notificationInfo = info
        _ = try await CloudKitService.publicDB.save(subscription)
    }

    private static func registerRecipeImportSubscription(for me: String) async throws {
        let predicate = NSPredicate(format: "originalCreatorID == %@", me)
        let subscription = CKQuerySubscription(
            recordType: CloudKitService.recipeImportRecordType,
            predicate: predicate,
            subscriptionID: recipeImportSubscriptionID(for: me),
            // Creation-only — RecipeImport rows don't get
            // updated post-write (audit log is append-only),
            // so listening for updates would just burn cloud
            // quota.
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        info.shouldBadge = false
        subscription.notificationInfo = info
        _ = try await CloudKitService.publicDB.save(subscription)
    }

    /// Grocery-share subscriptions.
    ///
    /// - **Recipient, first share** (`recipientIDs CONTAINS me`, creation):
    ///   visible, and names the friend and the list — "Sam just shared a new
    ///   grocery list with you! “Weekend Shop”". Carries the
    ///   `GROCERY_SHARE_NEW` category so the banner offers View / Close, and
    ///   a tap routes straight to the list.
    /// - **Recipient, later edits** (same predicate, update): visible but
    ///   generic — you already know the list exists.
    /// - **Owner** (`ownerID == me`): silent, update-only. Refreshes my
    ///   app so I watch a shopper tick items off live — but no banner,
    ///   since most updates on my own record are my own edits.
    /// - **Owner alert** (`GroceryListAlert.ownerID == me`): visible,
    ///   creation-only. Fires when a shopper flags an item unavailable.
    private static func registerGrocerySubscriptions(for me: String) async throws {
        let recipientPredicate = NSPredicate(format: "recipientIDs CONTAINS %@", me)

        // Recipient, FIRST share — visible, personalized, actionable.
        let sharedSub = CKQuerySubscription(
            recordType: CloudGroceryListService.recordType,
            predicate: recipientPredicate,
            subscriptionID: groceryShareCreatedSubscriptionID(for: me),
            options: [.firesOnRecordCreation]
        )
        let sharedInfo = CKSubscription.NotificationInfo()
        sharedInfo.shouldSendContentAvailable = true
        sharedInfo.shouldBadge = false
        sharedInfo.title = "New grocery list"
        // Same server-side field interpolation the out-of-stock alert uses:
        // the args are field NAMES on the GroceryListShare record, resolved
        // per push, against a key in Resources/Localizations/en.lproj.
        sharedInfo.alertLocalizationKey = "GROCERY_SHARE_NEW_BODY"
        sharedInfo.alertLocalizationArgs = ["ownerName", "listName"]
        sharedInfo.category = groceryShareCategory
        sharedInfo.soundName = "default"
        sharedSub.notificationInfo = sharedInfo
        _ = try await CloudKitService.publicDB.save(sharedSub)

        // Recipient, subsequent edits — visible but generic.
        let recipientSub = CKQuerySubscription(
            recordType: CloudGroceryListService.recordType,
            predicate: recipientPredicate,
            subscriptionID: groceryRecipientSubscriptionID(for: me),
            options: [.firesOnRecordUpdate]
        )
        let recipientInfo = CKSubscription.NotificationInfo()
        recipientInfo.shouldSendContentAvailable = true
        recipientInfo.shouldBadge = false
        recipientInfo.title = "Grocery list updated"
        recipientInfo.alertBody = "A list shared with you changed — open Lists to see what's left."
        recipientInfo.soundName = "default"
        recipientSub.notificationInfo = recipientInfo
        _ = try await CloudKitService.publicDB.save(recipientSub)

        // Owner — silent live refresh.
        let ownerSub = CKQuerySubscription(
            recordType: CloudGroceryListService.recordType,
            predicate: NSPredicate(format: "ownerID == %@", me),
            subscriptionID: groceryOwnerSubscriptionID(for: me),
            options: [.firesOnRecordUpdate]
        )
        let ownerInfo = CKSubscription.NotificationInfo()
        ownerInfo.shouldSendContentAvailable = true
        ownerInfo.shouldBadge = false
        ownerSub.notificationInfo = ownerInfo
        _ = try await CloudKitService.publicDB.save(ownerSub)

        // Owner alert — visible, creation-only, only for `!` events.
        let alertSub = CKQuerySubscription(
            recordType: CloudGroceryListService.alertRecordType,
            predicate: NSPredicate(format: "ownerID == %@", me),
            subscriptionID: groceryAlertSubscriptionID(for: me),
            options: [.firesOnRecordCreation]
        )
        let alertInfo = CKSubscription.NotificationInfo()
        alertInfo.shouldSendContentAvailable = true
        alertInfo.shouldBadge = false
        alertInfo.title = "Item unavailable"
        // Interpolate the alert record's own fields into the push body so
        // the owner reads "Sam couldn't find “oat milk” on Weekly Groceries."
        // instead of a generic sentence. The key lives in
        // Resources/Localizable.strings; the args are field NAMES on the
        // `GroceryListAlert` record, resolved server-side per push.
        // (`createOutOfStockAlert` guarantees all three are non-empty.)
        alertInfo.alertLocalizationKey = "GROCERY_OOS_ALERT_BODY"
        alertInfo.alertLocalizationArgs = ["shopperName", "itemName", "listName"]
        alertInfo.soundName = "default"
        alertSub.notificationInfo = alertInfo
        _ = try await CloudKitService.publicDB.save(alertSub)
    }

    // MARK: - Visible notification permission

    /// Visible CloudKit pushes still need normal iOS notification
    /// authorization. Ask lazily from grocery-sharing surfaces instead of at
    /// launch, so the prompt is tied to the feature that needs banners.
    /// Returns the status the app ends up with, so callers can surface a
    /// `.denied` — which is otherwise a permanently invisible dead end: the
    /// prompt is never shown twice, iOS silently drops the alert half of
    /// every CloudKit push, and nothing in the UI says why. Cook timers use
    /// AlarmKit's separate authorization, so working alarms are NOT evidence
    /// that this one was ever granted.
    @discardableResult
    static func requestVisibleNotificationAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return settings.authorizationStatus
        }
        // Deliberately not `.provisional`: it auto-grants without prompting
        // and demotes every banner to Notification-Center-only, which looks
        // identical to the bug we're fixing.
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await center.notificationSettings().authorizationStatus
    }

    /// Current authorization status without ever prompting. For UI that
    /// needs to explain why pushes are silent.
    static func currentNotificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - APNs token rotation

    /// Called from `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`
    /// every time iOS hands us a device token. When the token changes
    /// between launches (privacy reset, iCloud state change, fresh
    /// install on a restored device), CKQuerySubscriptions saved
    /// against the previous token silently stop firing. We detect the
    /// change here by comparing a SHA-256 hash of the current token
    /// against a UserDefaults-cached previous hash. On mismatch, we
    /// clear `registeredForKey` so the next `registerIfNeeded` invokes
    /// `publicDB.save(subscription)` again, which CloudKit upserts and
    /// re-binds the subscription to the current token. Token-stable
    /// launches are a fast no-op (single hash compare, no CK round-
    /// trip).
    static func noteAPNsTokenChanged(_ token: Data) {
        let hash = Data(SHA256.hash(data: token)).base64EncodedString()
        let previous = UserDefaults.standard.string(forKey: lastTokenHashKey)
        UserDefaults.standard.set(hash, forKey: lastTokenHashKey)
        guard let previous, previous != hash else { return }
        // Token rotated — invalidate the registered marker so the
        // next `registerIfNeeded` resaves both subscriptions. Caller
        // (`registerIfNeeded` from `RootView.task`) re-fires shortly
        // after.
        UserDefaults.standard.removeObject(forKey: registeredForKey)
    }

    // MARK: - APNs registration outcome

    /// Record that iOS handed us a device token. Without one, every
    /// CKSubscription is inert regardless of how cleanly it saved.
    static func noteAPNsRegistrationSucceeded() {
        UserDefaults.standard.set("registered", forKey: apnsOutcomeKey)
    }

    /// Record why iOS refused to register for remote notifications. The
    /// classic cause is an `aps-environment` entitlement that doesn't match
    /// the signing profile, which is otherwise invisible in a TestFlight build.
    static func noteAPNsRegistrationFailed(_ error: Error) {
        UserDefaults.standard.set("failed — \(error.localizedDescription)", forKey: apnsOutcomeKey)
        log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Diagnostics

    /// Everything needed to tell, on-device, which layer of the push stack
    /// is down. Read-only; makes no network writes and never prompts.
    struct PushDiagnostics: Sendable {
        var authorizationStatus: UNAuthorizationStatus
        var alertsEnabled: Bool
        var notificationCenterEnabled: Bool
        var isRegisteredForRemoteNotifications: Bool
        var apnsOutcome: String
        var userRecordName: String?
        var gateIsSetForCurrentUser: Bool
        var expectedSubscriptionIDs: [String]
        var presentSubscriptionIDs: Set<String>
        var lookupError: String?

        var missingSubscriptionIDs: [String] {
            expectedSubscriptionIDs.filter { !presentSubscriptionIDs.contains($0) }
        }

        /// Short lines for a settings row. Ordered so the first failing line
        /// is the one to act on.
        var summaryLines: [String] {
            var lines: [String] = []
            lines.append("Permission: \(Self.describe(authorizationStatus))")
            if authorizationStatus == .authorized || authorizationStatus == .provisional {
                lines.append("Banners: \(alertsEnabled ? "on" : "OFF — check Settings")")
                if !notificationCenterEnabled {
                    lines.append("Notification Centre: off")
                }
            }
            lines.append("APNs: \(isRegisteredForRemoteNotifications ? "registered" : "NOT registered") (\(apnsOutcome))")
            if let me = userRecordName {
                lines.append("iCloud user: …\(String(me.suffix(6)))")
                lines.append("Registration gate: \(gateIsSetForCurrentUser ? "set" : "NOT set — registration is failing")")
            } else {
                lines.append("iCloud user: unavailable — nothing can register")
            }
            if let lookupError {
                lines.append("Subscriptions: lookup failed — \(lookupError)")
            } else {
                let found = expectedSubscriptionIDs.count - missingSubscriptionIDs.count
                lines.append("Subscriptions: \(found) of \(expectedSubscriptionIDs.count) present")
                for id in missingSubscriptionIDs {
                    lines.append("  missing: \(id)")
                }
            }
            return lines
        }

        private static func describe(_ status: UNAuthorizationStatus) -> String {
            switch status {
            case .notDetermined: return "never asked"
            case .denied: return "DENIED — pushes are suppressed"
            case .authorized: return "granted"
            case .provisional: return "provisional (quiet)"
            case .ephemeral: return "ephemeral"
            @unknown default: return "unknown"
            }
        }
    }

    /// The seven subscription IDs this user should have. Single source of
    /// truth for `unregisterAll` and `diagnostics` — AGENTS.md warns these
    /// must move in lockstep, so they now read the same list.
    static func expectedSubscriptionIDs(for me: String) -> [String] {
        [
            friendshipSubscriptionIDA(for: me),
            friendshipSubscriptionIDB(for: me),
            recipeImportSubscriptionID(for: me),
            groceryShareCreatedSubscriptionID(for: me),
            groceryRecipientSubscriptionID(for: me),
            groceryOwnerSubscriptionID(for: me),
            groceryAlertSubscriptionID(for: me),
        ]
    }

    /// Read the live push state back off the device. This is the only way to
    /// see the second tester's subscriptions — CloudKit Console can only show
    /// the account the developer can sign in as.
    static func diagnostics() async -> PushDiagnostics {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let registered = await MainActor.run { UIApplication.shared.isRegisteredForRemoteNotifications }
        let me = UserProfileMirror.cachedRecordID()
        let expected = me.map { expectedSubscriptionIDs(for: $0) } ?? []

        var present: Set<String> = []
        var lookupError: String?
        if me != nil {
            do {
                let subscriptions = try await CloudKitService.publicDB.allSubscriptions()
                present = Set(subscriptions.map(\.subscriptionID))
            } catch {
                lookupError = UserProfileMirror.describeCloudKitError(error)
            }
        }

        return PushDiagnostics(
            authorizationStatus: settings.authorizationStatus,
            alertsEnabled: settings.alertSetting == .enabled,
            notificationCenterEnabled: settings.notificationCenterSetting == .enabled,
            isRegisteredForRemoteNotifications: registered,
            apnsOutcome: UserDefaults.standard.string(forKey: apnsOutcomeKey) ?? "no callback yet",
            userRecordName: me,
            gateIsSetForCurrentUser: me != nil
                && UserDefaults.standard.string(forKey: registeredForKey) == me,
            expectedSubscriptionIDs: expected,
            presentSubscriptionIDs: present,
            lookupError: lookupError
        )
    }

    // MARK: - Unregister

    /// Cleanup on sign-out / account-deletion. Drops this user's
    /// subscriptions server-side so pushes stop firing against
    /// this device's APNs token after the user leaves. Local
    /// UserDefaults flag clears regardless of network success
    /// so a re-sign-in re-registers cleanly — the cloud-side
    /// orphan (if the network call failed) just consumes a
    /// little quota until CloudKit GCs it.
    static func unregisterAll(userRecordName me: String) async {
        for id in expectedSubscriptionIDs(for: me) {
            _ = try? await CloudKitService.publicDB.deleteSubscription(withID: id)
        }
        UserDefaults.standard.removeObject(forKey: registeredForKey)
    }

    // MARK: - Push handler dispatch

    /// Notification fired on `NotificationCenter.default` when
    /// a CloudKit subscription push arrives. Observers
    /// (`FriendsStore.observeRemotePushes`, `RecipeDetailView`'s
    /// `.onReceive`) read the subscription kind from
    /// `userInfo["kind"]` and refresh their respective state.
    ///
    /// Why NotificationCenter and not direct method calls:
    /// AppDelegate sees the push first but doesn't have a
    /// direct reference to the SwiftUI environment Observables
    /// (FriendsStore lives at `LlamasCookbookApp` scope).
    /// Notification fan-out keeps AppDelegate decoupled from
    /// the SwiftUI graph — observers self-register where they
    /// already have the relevant state in scope.
    static let didFireNotification = Notification.Name("cloudKitSubscriptionFired")

    /// Subscription-kind tags broadcast on the
    /// `didFireNotification` userInfo dictionary under the
    /// `kind` key. Observers filter by kind so only the
    /// relevant component re-fetches.
    enum FiredKind: String {
        case friendship
        case recipeImport
        case groceryList
    }

    /// AppDelegate calls this from
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    /// Inspects the CloudKit notification payload to determine
    /// which subscription fired, then posts the corresponding
    /// `didFireNotification` to NotificationCenter for in-app
    /// observers to react. Returns the matched kind (or nil
    /// when the payload isn't a CK push or the subscription
    /// ID doesn't match either of ours).
    @discardableResult
    static func dispatchRemoteNotification(
        userInfo: [AnyHashable: Any]
    ) -> FiredKind? {
        // CKNotification's initializer takes [String: NSObject];
        // bridge-cast the AnyHashable dict, defensively dropping
        // anything that doesn't conform.
        var stringKeyed: [String: NSObject] = [:]
        for (k, v) in userInfo {
            if let key = k as? String, let value = v as? NSObject {
                stringKeyed[key] = value
            }
        }
        guard let notification = CKNotification(fromRemoteNotificationDictionary: stringKeyed) else {
            return nil
        }
        guard let subscriptionID = notification.subscriptionID else { return nil }
        let kind: FiredKind?
        if subscriptionID.hasPrefix("friendship-events-") {
            kind = .friendship
        } else if subscriptionID.hasPrefix("recipe-import-events-") {
            kind = .recipeImport
        } else if subscriptionID.hasPrefix("grocery-list-events-") ||
                    subscriptionID.hasPrefix("grocery-list-alerts-") ||
                    subscriptionID.hasPrefix("grocery-list-shared-") {
            kind = .groceryList
        } else {
            kind = nil
        }
        guard let kind else { return nil }
        NotificationCenter.default.post(
            name: didFireNotification,
            object: nil,
            userInfo: ["kind": kind.rawValue]
        )
        return kind
    }
}
