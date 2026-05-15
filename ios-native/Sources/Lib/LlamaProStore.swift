import Foundation
import StoreKit
import CryptoKit

@MainActor
@Observable
final class LlamaProStore {

    static let productID = "com.llamascookbook.app.pro.monthly"

    private(set) var isPro:          Bool     = false
    private(set) var product:        Product? = nil
    private(set) var isPurchasing:   Bool     = false
    private(set) var purchaseError:  String?  = nil

    nonisolated(unsafe) private var transactionUpdateTask: Task<Void, Never>?

    init() {
        transactionUpdateTask = listenForTransactionUpdates()
    }

    deinit {
        transactionUpdateTask?.cancel()
    }

    // MARK: - Startup

    /// Load the App Store product and verify existing entitlements.
    /// Call once from LlamasCookbookApp on first appear.
    func start() async {
        async let productLoad: Void  = loadProduct()
        async let entitlements: Void = checkCurrentEntitlements()
        _ = await (productLoad, entitlements)
    }

    /// Called on sign-out — clears local Pro status without touching StoreKit.
    func signOut() {
        isPro = false
        purchaseError = nil
    }

    // MARK: - Product

    func loadProduct() async {
        do {
            let loaded = try await Product.products(for: [Self.productID])
            product = loaded.first
        } catch {
            // Product unavailable until App Store Connect setup is complete.
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product else {
            purchaseError = "Subscription unavailable — please try again in a moment."
            return
        }
        isPurchasing   = true
        purchaseError  = nil
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
                isPro = true
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
        var hasPro = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.productID {
                hasPro = true
                await activateOnServer(jws: result.jwsRepresentation)
            }
        }
        isPro = hasPro
    }

    // MARK: - Transaction listener

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { break }
                guard case .verified(let transaction) = result else { continue }
                guard transaction.productID == Self.productID else { continue }
                let active = transaction.revocationDate == nil &&
                             (transaction.expirationDate.map { $0 > Date.now } ?? true)
                await self.activateOnServer(jws: result.jwsRepresentation)
                await MainActor.run { self.isPro = active }
                await transaction.finish()
            }
        }
    }

    // MARK: - Server sync

    /// Notifies the Cloudflare Worker so the server-side KV pro flag is kept
    /// in sync. Fire-and-forget — local StoreKit entitlement is authoritative
    /// on the client; the server flag gates quota enforcement.
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

    /// Deterministic UUID from the SIWA sub for `.appAccountToken`.
    /// SHA-256 the sub UTF-8, take first 16 bytes, apply UUID v4 variant bits
    /// so the result is a structurally valid UUID. The server re-derives this
    /// to verify the token in the JWS payload matches the calling user.
    static func appAccountToken(for siwaSubOrNil: String?) -> UUID? {
        guard let sub = siwaSubOrNil, !sub.isEmpty else { return nil }
        var bytes = Array(SHA256.hash(data: Data(sub.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40  // version 4
        bytes[8] = (bytes[8] & 0x3f) | 0x80  // RFC 4122 variant
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
