import Foundation

/// Runs the App Store side of the bridge contract and answers with its replies. It reports what
/// the App Store says and decides nothing: the server verifies every purchase and grants access.
@MainActor
final class TillbellStore {
    /// The process-wide instance. Its transaction listener and any purchase in flight outlive
    /// the screen that started them, so a purchase is never lost when the page goes away.
    static let shared = TillbellStore(client: AppStoreClient())

    private let client: StoreClient

    /// Hosts of the pages allowed to talk to the store, or nil to accept every page. See
    /// `TillbellComponent.allowedHosts`.
    var allowedHosts: Set<String>?

    init(client: StoreClient) {
        self.client = client
    }

    /// True when the page that sent `jsonData` may talk to the store: its `metadata.url`, added
    /// by the bridge, is on one of `allowedHosts` (any page without them). A message without a
    /// readable URL is refused once hosts are set.
    func isTrusted(jsonData: String) -> Bool {
        guard let allowedHosts else { return true }
        guard let message: MessageMetadata = decode(jsonData),
              let host = URLComponents(string: message.metadata.url)?.host?.lowercased() else { return false }
        return allowedHosts.contains { $0.lowercased() == host }
    }

    /// Prices of the requested [plans]. Plans the App Store does not know are left out, and so
    /// are plans with a base plan: the App Store has none, each duration is its own product.
    func products(_ plans: [Plan]) async -> ProductsReply {
        let ids = plans.filter { $0.basePlanId == nil }.map(\.productId).uniqued()
        // There is nothing to price, and StoreKit would be asked for nothing.
        if ids.isEmpty { return ProductsReply(result: .ok, products: []) }
        guard client.canMakePayments else { return ProductsReply(result: .unavailable, message: cannotPayMessage) }

        do {
            let found = Dictionary(uniqueKeysWithValues: try await client.products(ids: ids).map { ($0.id, $0) })
            let priced = plans.filter { $0.basePlanId == nil }.compactMap { plan in
                found[plan.productId].map { PricedPlan(productId: plan.productId, basePlanId: nil, formattedPrice: $0.displayPrice) }
            }
            return ProductsReply(result: .ok, products: priced)
        } catch let error as StoreError {
            return ProductsReply(result: error.unavailable ? .unavailable : .error, message: error.message)
        } catch {
            return ProductsReply(result: .error, message: String(describing: error))
        }
    }

    /// Opens the purchase sheet and waits for its outcome. Every call returns exactly one reply.
    func purchase(_ request: PurchaseRequest) async -> PurchaseReply {
        let isPlanChange = request.oldPurchaseToken != nil
        if isPlanChange != (request.replacementMode != nil) {
            return PurchaseReply(result: .error, message: "oldPurchaseToken and replacementMode go together")
        }
        if let basePlanId = request.basePlanId {
            return PurchaseReply(result: .error, message: "App Store products have no base plan: \(request.productId)/\(basePlanId)")
        }
        guard let appAccountToken = UUID(uuidString: request.obfuscatedAccountId) else {
            return PurchaseReply(result: .error, message: "obfuscatedAccountId must be a UUID, the App Store appAccountToken")
        }
        guard client.canMakePayments else { return PurchaseReply(result: .unavailable, message: cannotPayMessage) }

        // The App Store would show its own "already subscribed" sheet. Reply already_owned
        // instead, as Google Play does, so the page restores the purchase. A plan change
        // replaces a subscription of the same group, so it always goes to the sheet.
        if !isPlanChange, await client.subscriptions().contains(where: { $0.productId == request.productId }) {
            return PurchaseReply(result: .alreadyOwned)
        }

        // A plan change needs nothing more: the App Store replaces the subscription of the same
        // subscription group, at once for an upgrade and at the next renewal for a downgrade.
        switch await client.purchase(productId: request.productId, appAccountToken: appAccountToken) {
        case .purchased(let transaction):
            return PurchaseReply(result: .purchased, productId: transaction.productId, purchaseToken: transaction.jws)
        case .pending:
            // Waiting for approval (Ask to Buy): StoreKit has no transaction yet, so the reply has
            // no purchase token. The server records the purchase from App Store Server
            // Notifications once it is approved.
            return PurchaseReply(result: .pending, productId: request.productId)
        case .canceled:
            return PurchaseReply(result: .canceled)
        case .unavailable(let message):
            return PurchaseReply(result: .unavailable, message: message)
        case .failed(let message):
            return PurchaseReply(result: .error, message: message)
        }
    }

    /// Subscriptions the App Store account is entitled to, for the server to check.
    func restore() async -> RestoreReply {
        let purchases = await client.subscriptions().map { OwnedPurchase(productId: $0.productId, purchaseToken: $0.jws) }
        return RestoreReply(result: .ok, purchases: purchases)
    }

    /// The JSON reply to a `products`, `purchase` or `restore` message, or nil for messages that
    /// get no reply. A malformed request gets an `error` reply, so the page never waits forever.
    func answer(event: String, jsonData: String) async -> String? {
        if !isTrusted(jsonData: jsonData) {
            let message = "The page is not on an allowed host"
            switch event {
            case "products": return encode(ProductsReply(result: .error, message: message))
            case "purchase": return encode(PurchaseReply(result: .error, message: message))
            case "restore": return encode(RestoreReply(result: .error, message: message))
            default: return nil
            }
        }
        switch event {
        case "products":
            let reply = if let request: ProductsRequest = decode(jsonData) {
                await products(request.products)
            } else {
                ProductsReply(result: .error, message: "Malformed products request")
            }
            return encode(reply)
        case "purchase":
            let reply = if let request: PurchaseRequest = decode(jsonData) {
                await purchase(request)
            } else {
                PurchaseReply(result: .error, message: "Malformed purchase request")
            }
            return encode(reply)
        case "restore":
            return encode(await restore())
        default:
            return nil
        }
    }
}

private let cannotPayMessage = "AppStore.canMakePayments is false"

// The `metadata` object the bridge adds to every message from the page: the URL of the page.
private struct MessageMetadata: Decodable {
    struct Metadata: Decodable { let url: String }
    let metadata: Metadata
}

// The bridge adds a `metadata` object to every message from the page; decoding requests ignores it.
private func decode<T: Decodable>(_ jsonData: String) -> T? {
    try? JSONDecoder().decode(T.self, from: Data(jsonData.utf8))
}

// Encodes with a plain encoder rather than the host app's Hotwire one, whose settings could
// rename or drop fields the contract's schemas forbid or require. The contract's replies are
// plain strings and arrays, so encoding cannot fail.
private func encode<T: Encodable>(_ reply: T) -> String {
    String(decoding: try! JSONEncoder().encode(reply), as: UTF8.self)
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
