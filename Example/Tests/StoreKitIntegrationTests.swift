import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import Tillbell

/// Runs the real StoreKit 2 code (AppStoreClient) against the local App Store of StoreKitTest,
/// with the products of Tillbell.storekit. StoreKitTest needs a host app, so these tests live
/// in the example app rather than in the package:
/// `cd Example && xcodebuild test -scheme TillbellExample -destination 'platform=iOS Simulator,name=<device>'`.
@MainActor
final class StoreKitIntegrationTests: XCTestCase {
    private let accountId = "6f1c2a8e-3b7d-4e59-9a0c-2d4f8b1e7c35"
    // One client for every test, as in an app: each client starts a Transaction.updates
    // listener that lives as long as it does.
    private static let client = AppStoreClient()
    private var session: SKTestSession!
    private var store: TillbellStore!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Tillbell")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        store = TillbellStore(client: Self.client)
    }

    override func tearDown() async throws {
        session.clearTransactions()
    }

    func testPricesComeFromTheAppStore() async {
        let reply = await store.products([Plan(productId: "premium.monthly"), Plan(productId: "premium.yearly"), Plan(productId: "missing")])

        XCTAssertEqual(reply.result, .ok)
        XCTAssertEqual(reply.products?.map(\.productId), ["premium.monthly", "premium.yearly"])
        XCTAssertEqual(reply.products?.map(\.formattedPrice), ["$4.99", "$49.99"])
    }

    func testPurchaseRestoreAndAlreadyOwned() async throws {
        let reply = await store.purchase(PurchaseRequest(productId: "premium.monthly", obfuscatedAccountId: accountId))

        XCTAssertEqual(reply.result, .purchased, reply.message ?? "")
        XCTAssertEqual(reply.productId, "premium.monthly")

        // The token is the signed transaction tillbell-rails verifies: check it carries every
        // field the server reads (Tillbell::AppStore and Pay::AppStore::Subscription).
        let payload = try jwsPayload(XCTUnwrap(reply.purchaseToken))
        XCTAssertEqual((payload["appAccountToken"] as? String)?.lowercased(), accountId)
        XCTAssertEqual(payload["productId"] as? String, "premium.monthly")
        XCTAssertEqual(payload["type"] as? String, "Auto-Renewable Subscription")
        for key in ["transactionId", "originalTransactionId", "bundleId", "purchaseDate", "expiresDate", "signedDate", "environment"] {
            XCTAssertNotNil(payload[key], key)
        }

        // Not checked: that the transaction is finished. StoreKitTest keeps listing transactions in
        // Transaction.unfinished after finish() once others were bought in the same simulator,
        // with plain StoreKit code too, so the check fails at random. AppStoreClient.purchase
        // calls finish() on every verified purchase.

        let restored = await store.restore()
        XCTAssertEqual(restored.result, .ok)
        XCTAssertEqual(restored.purchases?.map(\.productId), ["premium.monthly"])

        let again = await store.purchase(PurchaseRequest(productId: "premium.monthly", obfuscatedAccountId: accountId))
        XCTAssertEqual(again.result, .alreadyOwned)
    }

    func testAPlanChangeRepliesWithTheNewProduct() async throws {
        let first = await store.purchase(PurchaseRequest(productId: "premium.monthly", obfuscatedAccountId: accountId))
        XCTAssertEqual(first.result, .purchased, first.message ?? "")
        let restored = await store.restore()
        let oldToken = try XCTUnwrap(restored.purchases?.first?.purchaseToken)

        // premium.yearly is the higher level of the group: an upgrade, effective at once.
        var change = PurchaseRequest(productId: "premium.yearly", obfuscatedAccountId: accountId)
        change.oldPurchaseToken = oldToken
        change.replacementMode = .CHARGE_PRORATED_PRICE
        let reply = await store.purchase(change)

        XCTAssertEqual(reply.result, .purchased, reply.message ?? "")
        XCTAssertEqual(reply.productId, "premium.yearly")
        let old = try jwsPayload(oldToken)
        let new = try jwsPayload(XCTUnwrap(reply.purchaseToken))
        XCTAssertEqual(new["originalTransactionId"] as? String, old["originalTransactionId"] as? String)
    }

    func testADowngradeRepliesWithTheCurrentProductUntilTheRenewal() async throws {
        let first = await store.purchase(PurchaseRequest(productId: "premium.yearly", obfuscatedAccountId: accountId))
        XCTAssertEqual(first.result, .purchased, first.message ?? "")

        // premium.monthly is the lower level: the App Store moves to it at the next renewal.
        var change = PurchaseRequest(productId: "premium.monthly", obfuscatedAccountId: accountId)
        change.oldPurchaseToken = try XCTUnwrap(first.purchaseToken)
        change.replacementMode = .DEFERRED
        let reply = await store.purchase(change)

        XCTAssertEqual(reply.result, .purchased, reply.message ?? "")
        let old = try jwsPayload(XCTUnwrap(first.purchaseToken))
        let new = try jwsPayload(XCTUnwrap(reply.purchaseToken))
        XCTAssertEqual(new["originalTransactionId"] as? String, old["originalTransactionId"] as? String)
        // Until the renewal the subscription stays on the current product; the server reads the
        // pending change from the renewal information of App Store Server Notifications.
        XCTAssertEqual(reply.productId, "premium.yearly")
    }

    func testAskToBuyIsPendingWithoutAToken() async {
        session.askToBuyEnabled = true

        let reply = await store.purchase(PurchaseRequest(productId: "premium.monthly", obfuscatedAccountId: accountId))

        XCTAssertEqual(reply, PurchaseReply(result: .pending, productId: "premium.monthly"))
    }

    func testAnUnknownProductIsAnError() async {
        let reply = await store.purchase(PurchaseRequest(productId: "missing", obfuscatedAccountId: accountId))

        XCTAssertEqual(reply.result, .error)
    }

    private func jwsPayload(_ jws: String) throws -> [String: Any] {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw URLError(.cannotDecodeContentData, userInfo: [NSLocalizedDescriptionKey: "Not a JWS: \(jws)"]) }
        var part = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        part += String(repeating: "=", count: (4 - part.count % 4) % 4)
        let data = try XCTUnwrap(Data(base64Encoded: part))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
