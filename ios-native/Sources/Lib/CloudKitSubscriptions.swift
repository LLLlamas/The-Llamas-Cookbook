import Foundation
import CloudKit
import CryptoKit
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
    private static let registeredForKey = "cloudKitSubscriptions.registeredForRecordID.v3"

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

    /// Per-user identifier for the grocery-share stream where I'm a
    /// **recipient** (`recipientIDs CONTAINS me`). This one carries a
    /// VISIBLE push — the "your shared grocery list was updated" banner
    /// the husband-at-the-store gets when the owner shares or edits.
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

        do {
            try await registerFriendshipSubscription(for: me)
            try await registerRecipeImportSubscription(for: me)
            try await registerGrocerySubscriptions(for: me)
            UserDefaults.standard.set(me, forKey: registeredForKey)
        } catch {
            // Silent — schema not deployed (RecipeImport land in
            // slice 6's deploy ritual), CK throttling, network
            // outage, etc. Next launch hits this path again.
        }
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
    /// - **Recipient** (`recipientIDs CONTAINS me`): fires on create +
    ///   update with a banner ("Your shared grocery list was updated").
    ///   This is the husband-at-the-store getting told the list is ready /
    ///   changed. `shouldSendContentAvailable` is also on so the app
    ///   refreshes the mirror in the same wake-up.
    /// - **Owner** (`ownerID == me`): silent, update-only. Refreshes my
    ///   app so I watch a shopper tick items off live — but no banner,
    ///   since most updates on my own record are my own edits.
    /// - **Owner alert** (`GroceryListAlert.ownerID == me`): visible,
    ///   creation-only. Fires when a shopper flags an item unavailable.
    private static func registerGrocerySubscriptions(for me: String) async throws {
        // Recipient — visible.
        let recipientSub = CKQuerySubscription(
            recordType: CloudGroceryListService.recordType,
            predicate: NSPredicate(format: "recipientIDs CONTAINS %@", me),
            subscriptionID: groceryRecipientSubscriptionID(for: me),
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
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
        alertInfo.alertBody = "Someone couldn't find an item on your shared grocery list."
        alertInfo.soundName = "default"
        alertSub.notificationInfo = alertInfo
        _ = try await CloudKitService.publicDB.save(alertSub)
    }

    // MARK: - Visible notification permission

    /// Visible CloudKit pushes still need normal iOS notification
    /// authorization. Ask lazily from grocery-sharing surfaces instead of at
    /// launch, so the prompt is tied to the feature that needs banners.
    static func requestVisibleNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
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

    // MARK: - Unregister

    /// Cleanup on sign-out / account-deletion. Drops this user's
    /// subscriptions server-side so pushes stop firing against
    /// this device's APNs token after the user leaves. Local
    /// UserDefaults flag clears regardless of network success
    /// so a re-sign-in re-registers cleanly — the cloud-side
    /// orphan (if the network call failed) just consumes a
    /// little quota until CloudKit GCs it.
    static func unregisterAll(userRecordName me: String) async {
        let ids = [
            friendshipSubscriptionIDA(for: me),
            friendshipSubscriptionIDB(for: me),
            recipeImportSubscriptionID(for: me),
            groceryRecipientSubscriptionID(for: me),
            groceryOwnerSubscriptionID(for: me),
            groceryAlertSubscriptionID(for: me),
        ]
        for id in ids {
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
                    subscriptionID.hasPrefix("grocery-list-alerts-") {
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
