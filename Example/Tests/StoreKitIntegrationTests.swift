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
    private var session: SKTestSession!
    private var store: TillbellStore!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Tillbell")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        store = TillbellStore(client: AppStoreClient())
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

        // The transaction was finished on the device. StoreKitTest updates Transaction.unfinished
        // a moment after finish() returns, so wait for it, up to 5 seconds.
        var unfinished = await unfinishedTransactions()
        for _ in 0..<50 where !unfinished.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
            unfinished = await unfinishedTransactions()
        }
        XCTAssertTrue(unfinished.isEmpty, "Unfinished: \(unfinished.map(\.productID))")

        let restored = await store.restore()
        XCTAssertEqual(restored.result, .ok)
        XCTAssertEqual(restored.purchases?.map(\.productId), ["premium.monthly"])

        let again = await store.purchase(PurchaseRequest(productId: "premium.monthly", obfuscatedAccountId: accountId))
        XCTAssertEqual(again.result, .alreadyOwned)
    }

    func testAPlanChangeRepliesWithTheNewProduct() async throws {
        _ = await store.purchase(PurchaseRequest(productId: "premium.monthly", obfuscatedAccountId: accountId))
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

    func testAskToBuyIsPendingWithoutAToken() async {
        session.askToBuyEnabled = true

        let reply = await store.purchase(PurchaseRequest(productId: "premium.monthly", obfuscatedAccountId: accountId))

        XCTAssertEqual(reply, PurchaseReply(result: .pending, productId: "premium.monthly"))
    }

    func testAnUnknownProductIsAnError() async {
        let reply = await store.purchase(PurchaseRequest(productId: "missing", obfuscatedAccountId: accountId))

        XCTAssertEqual(reply.result, .error)
    }

    private func unfinishedTransactions() async -> [Transaction] {
        var transactions: [Transaction] = []
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result { transactions.append(transaction) }
        }
        return transactions
    }

    private func jwsPayload(_ jws: String) throws -> [String: Any] {
        var part = String(jws.split(separator: ".")[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        part += String(repeating: "=", count: (4 - part.count % 4) % 4)
        let data = try XCTUnwrap(Data(base64Encoded: part))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
