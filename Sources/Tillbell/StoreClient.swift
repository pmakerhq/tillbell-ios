import Foundation
import StoreKit

/// A subscription product of the App Store, with its price formatted for the storefront.
struct StoreProduct: Equatable, Sendable {
    let id: String
    let displayPrice: String
}

/// A verified StoreKit transaction, reduced to what the contract reports. [jws] is the signed
/// transaction (`VerificationResult.jwsRepresentation`), sent to the server as the purchase
/// token: the server verifies its signature and reads every detail of the purchase from it.
struct StoreTransaction: Equatable, Sendable {
    let productId: String
    let jws: String
}

/// Outcome of the App Store purchase sheet.
enum StorePurchaseOutcome: Equatable, Sendable {
    case purchased(StoreTransaction)
    /// Waiting for approval (Ask to Buy, Strong Customer Authentication). StoreKit gives no
    /// transaction until then.
    case pending
    case canceled
    case unavailable(String)
    case failed(String)
}

/// A failed App Store query. [unavailable] means the App Store cannot be used here.
struct StoreError: Error, Equatable {
    let unavailable: Bool
    let message: String
}

/// The few StoreKit calls Tillbell makes. It exists so [TillbellStore] can be tested without
/// the App Store; [AppStoreClient] is the only production implementation.
@MainActor
protocol StoreClient {
    /// Whether the account can pay (`AppStore.canMakePayments`), false under parental controls.
    var canMakePayments: Bool { get }

    /// The auto-renewable subscriptions with the given product identifiers. Throws a [StoreError].
    func products(ids: [String]) async throws -> [StoreProduct]

    /// Opens the purchase sheet and returns its outcome. A purchased transaction is finished.
    func purchase(productId: String, appAccountToken: UUID) async -> StorePurchaseOutcome

    /// The auto-renewable subscriptions the account is entitled to (`Transaction.currentEntitlements`).
    func subscriptions() async -> [StoreTransaction]
}

/// [StoreClient] backed by StoreKit 2.
@MainActor
final class AppStoreClient: StoreClient {
    private let updates: Task<Void, Never>

    init() {
        // Purchases completed outside the purchase sheet (Ask to Buy approved, renewals, a
        // purchase interrupted by the app being killed) arrive here, unfinished ones once at
        // launch. The server hears about them from App Store Server Notifications; the device
        // only finishes them, or StoreKit would deliver them again on every launch.
        updates = Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
            }
        }
    }

    deinit { updates.cancel() }

    var canMakePayments: Bool { AppStore.canMakePayments }

    func products(ids: [String]) async throws -> [StoreProduct] {
        do {
            return try await Product.products(for: ids)
                .filter { $0.type == .autoRenewable }
                .map { StoreProduct(id: $0.id, displayPrice: $0.displayPrice) }
        } catch {
            throw StoreError(unavailable: Self.isUnavailable(error), message: String(describing: error))
        }
    }

    func purchase(productId: String, appAccountToken: UUID) async -> StorePurchaseOutcome {
        do {
            guard let product = try await Product.products(for: [productId]).first(where: { $0.type == .autoRenewable }) else {
                return .failed("Unknown App Store subscription: \(productId)")
            }
            switch try await product.purchase(options: [.appAccountToken(appAccountToken)]) {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    return .failed("StoreKit could not verify the transaction")
                }
                // Finishing tells StoreKit the purchase was delivered. It does not grant access:
                // the server does, after verifying the signed transaction. Access is never lost
                // by finishing, since currentEntitlements (restore) still lists the subscription.
                await transaction.finish()
                return .purchased(StoreTransaction(productId: transaction.productID, jws: verification.jwsRepresentation))
            case .pending:
                return .pending
            case .userCancelled:
                return .canceled
            @unknown default:
                return .failed("Unknown StoreKit purchase result")
            }
        } catch {
            if case StoreKitError.userCancelled = error { return .canceled }
            let message = String(describing: error)
            return Self.isUnavailable(error) ? .unavailable(message) : .failed(message)
        }
    }

    func subscriptions() async -> [StoreTransaction] {
        var owned: [StoreTransaction] = []
        for await result in Transaction.currentEntitlements {
            // An unverified transaction is not reported: the server would reject it anyway.
            guard case .verified(let transaction) = result, transaction.productType == .autoRenewable else { continue }
            owned.append(StoreTransaction(productId: transaction.productID, jws: result.jwsRepresentation))
        }
        return owned
    }

    // The contract's "unavailable": the App Store cannot sell this here, as opposed to an error.
    private static func isUnavailable(_ error: Error) -> Bool {
        switch error {
        case StoreKitError.notAvailableInStorefront,
             Product.PurchaseError.productUnavailable,
             Product.PurchaseError.purchaseNotAllowed:
            return true
        default:
            return false
        }
    }
}
