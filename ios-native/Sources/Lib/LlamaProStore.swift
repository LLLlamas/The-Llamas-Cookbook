import Foundation
import StoreKit
import CryptoKit

@MainActor
@Observable
final class LlamaProStore {

    enum Plan {
        case none, monthly, yearly
        var isPro: Bool { self != .none }
        var displayLabel: String {
            switch self {
            case .none:    return ""
            case .monthly: return "Llama Pro Monthly"
            case .yearly:  return "Llama Pro Yearly"
            }
        }
    }

    static let monthlyProductID = "com.llamascookbook.app.pro.monthly"
    static let yearlyProductID  = "com.llamascookbook.app.pro.yearly"

    private(set) var plan:           Plan     = .none
    private(set) var monthlyProduct: Product? = nil
    private(set) var yearlyProduct:  Product? = nil
    private(set) var isPurchasing:   Bool     = false
    private(set) var purchaseError:  String?  = nil

    var isPro: Bool { plan.isPro }

    nonisolated(unsafe) private var transactionUpdateTask: Task<Void, Never>?

    // MARK: - Plan cache

    private static let planCacheKey = "llamaPro.cachedPlan"

    // Persist plan to UserDefaults so crown surfaces are correct at the
    // first rendered frame on every cold start, not after StoreKit responds.
    // StoreKit's checkCurrentEntitlements() still runs async in start() and
    // silently corrects stale values (e.g. an expired subscription).
    private func setPlan(_ newPlan: Plan) {
        plan = newPlan
        let raw: String
        switch newPlan {
        case .none:    raw = "none"
        case .monthly: raw = "monthly"
        case .yearly:  raw = "yearly"
        }
        UserDefaults.standard.set(raw, forKey: Self.planCacheKey)
    }

    init() {
        // Demo mode (App Store Review path) overrides the cached plan
        // so the reviewer can flip between Free / Monthly / Yearly
        // from the in-app demo controls without touching StoreKit.
        // The override is consulted on every relaunch so the chosen
        // tier survives cold start. See `DemoMode.planOverride`.
        if DemoMode.isActive() {
            plan = DemoMode.planOverride()
        } else if let raw = UserDefaults.standard.string(forKey: Self.planCacheKey) {
            switch raw {
            case "monthly": plan = .monthly
            case "yearly":  plan = .yearly
            default:        break
            }
        }
        transactionUpdateTask = listenForTransactionUpdates()
    }

    /// Reviewer-facing plan tier flip. Only respects the call when
    /// demo mode is active — outside demo, all plan changes flow
    /// through the StoreKit transaction listener. Updates the
    /// observed `plan` immediately so crown surfaces re-render in
    /// place.
    func applyDemoPlan(_ newPlan: Plan) {
        guard DemoMode.isActive() else { return }
        DemoMode.setPlanOverride(newPlan)
        plan = newPlan
    }

    deinit {
        transactionUpdateTask?.cancel()
    }

    // MARK: - Startup

    func start() async {
        // In demo mode the plan is sourced from `DemoMode.planOverride`
        // and the reviewer hasn't (and can't) actually purchased
        // anything. Skip StoreKit so a `checkCurrentEntitlements`
        // round-trip doesn't overwrite the synthetic tier.
        if DemoMode.isActive() {
            plan = DemoMode.planOverride()
            return
        }
        async let productLoad: Void  = loadProduct()
        async let entitlements: Void = checkCurrentEntitlements()
        _ = await (productLoad, entitlements)
    }

    func signOut() {
        // Demo exit clears the override via `DemoMode.exit`; calling
        // `setPlan(.none)` here would persist `"none"` to the regular
        // cache key and stick after the reviewer leaves demo mode.
        if DemoMode.isActive() { return }
        setPlan(.none)
        purchaseError = nil
    }

    // MARK: - Product

    func loadProduct() async {
        do {
            let loaded = try await Product.products(for: [Self.monthlyProductID, Self.yearlyProductID])
            monthlyProduct = loaded.first(where: { $0.id == Self.monthlyProductID })
            yearlyProduct  = loaded.first(where: { $0.id == Self.yearlyProductID })
        } catch {
            // Products unavailable until App Store Connect setup is complete.
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        isPurchasing  = true
        purchaseError = nil
        defer { isPurchasing = false }

        do {
            var options: Set<Product.PurchaseOption> = []
            if let token = Self.appAccountToken(for: KeychainStore.read(.appleSub)) {
                options.insert(.appAccountToken(token))
            }
            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await activateOnServer(jws: verification.jwsRepresentation)
                setPlan(transaction.productID == Self.yearlyProductID ? .yearly : .monthly)
                await transaction.finish()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Restore

    func restore() async {
        isPurchasing  = true
        purchaseError = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await checkCurrentEntitlements()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Entitlements

    func checkCurrentEntitlements() async {
        // Demo mode bypasses StoreKit — see `start()`. Without this
        // early-return, an entitlements check fired by RootView's
        // `onChange(isSignedIn)` immediately after `enterDemoMode`
        // would clobber the synthetic yearly tier with `.none`.
        if DemoMode.isActive() {
            plan = DemoMode.planOverride()
            return
        }
        var detected: Plan = .none
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            switch transaction.productID {
            case Self.yearlyProductID:
                detected = .yearly
                await activateOnServer(jws: result.jwsRepresentation)
            case Self.monthlyProductID:
                if detected == .none { detected = .monthly }
                await activateOnServer(jws: result.jwsRepresentation)
            default:
                break
            }
        }
        setPlan(detected)
    }

    // MARK: - Transaction listener

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { break }
                guard case .verified(let transaction) = result else { continue }
                let isYearly = transaction.productID == Self.yearlyProductID
                let isMonthly = transaction.productID == Self.monthlyProductID
                guard isYearly || isMonthly else { continue }
                let active = transaction.revocationDate == nil &&
                             (transaction.expirationDate.map { $0 > Date.now } ?? true)
                await self.activateOnServer(jws: result.jwsRepresentation)
                await MainActor.run {
                    if active {
                        self.setPlan(isYearly ? .yearly : .monthly)
                    } else {
                        let currentPlan = self.plan
                        if (isYearly && currentPlan == .yearly) || (isMonthly && currentPlan == .monthly) {
                            self.setPlan(.none)
                        }
                    }
                }
                await transaction.finish()
            }
        }
    }

    // MARK: - Server sync

    private func activateOnServer(jws: String) async {
        guard let userId = KeychainStore.read(.appleSub) else { return }
        var req = URLRequest(url: URL(string: "https://llamascookbook.pages.dev/api/usage/activate-pro")!)
        req.httpMethod  = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json",              forHTTPHeaderField: "Content-Type")
        req.setValue(userId,                          forHTTPHeaderField: "x-llamas-user")
        req.setValue(TimeZone.current.identifier,     forHTTPHeaderField: "x-llamas-tz")
        req.httpBody = try? JSONEncoder().encode(["signedTransaction": jws])
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Helpers

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let value):      return value
        }
    }

    static func appAccountToken(for siwaSubOrNil: String?) -> UUID? {
        guard let sub = siwaSubOrNil, !sub.isEmpty else { return nil }
        var bytes = Array(SHA256.hash(data: Data(sub.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
