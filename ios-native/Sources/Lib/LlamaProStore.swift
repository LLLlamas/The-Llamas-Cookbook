import Foundation
import StoreKit

// MARK: - LlamaProStore (Phase 1 stub)
//
// Phase 1: `isPro` is always false. The upsell card is wired but the
// "Upgrade to Llama Pro" button opens a "Coming soon" PaywallView stub.
//
// Phase 2 will:
//  - Load the real product from App Store Connect.
//  - Implement `purchase(_:)` and `restore()` with StoreKit 2.
//  - Set up App Store Server Notifications V2 webhook to sync the
//    KV `pro:<userId>` flag server-side.
//  - Wire `appAccountToken(for:)` at purchase time so the server can
//    link the App Store transaction to the SIWA sub.

@MainActor
@Observable
final class LlamaProStore {

    /// Product ID matching App Store Connect setup.
    static let productID = "com.llamascookbook.app.pro.monthly"

    /// Whether the signed-in user has an active Pro subscription.
    /// Phase 1: always false. Phase 2: derived from StoreKit entitlements
    /// and the server-side KV `pro:<userId>` flag.
    private(set) var isPro: Bool = false

    /// The StoreKit product, once loaded. nil until Phase 2 loads it.
    private(set) var product: Product? = nil

    /// True while a purchase or restore is in flight.
    private(set) var isPurchasing: Bool = false

    // MARK: Phase 2 stubs

    /// Derive a deterministic UUID from the SIWA sub for `.appAccountToken`.
    /// SHA-256 the sub, take the first 16 bytes, format as UUID.
    static func appAccountToken(for siwaSubOrNil: String?) -> UUID? {
        // Phase 2: implement SHA-256 derivation.
        return nil
    }

    func purchase(_ product: Product) async throws -> Bool {
        // Phase 2: implement StoreKit 2 purchase.
        return false
    }

    func restore() async throws {
        // Phase 2: implement StoreKit 2 restore.
    }
}
