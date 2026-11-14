import Foundation
import XCTest
@testable import Tillbell

/// A StoreKit stand-in that records what the store asks for.
@MainActor
final class FakeStoreClient: StoreClient {
    var canMakePayments = true
    var catalog: [StoreProduct] = []
    var productsError: StoreError?
    var entitlements: [StoreTransaction] = []
    var outcome: StorePurchaseOutcome = .canceled

    private(set) var queriedIds: [[String]] = []
    private(set) var purchases: [(productId: String, appAccountToken: UUID)] = []

    func products(ids: [String]) async throws -> [StoreProduct] {
        queriedIds.append(ids)
        if let productsError { throw productsError }
        return catalog.filter { ids.contains($0.id) }
    }

    func purchase(productId: String, appAccountToken: UUID) async -> StorePurchaseOutcome {
        purchases.append((productId, appAccountToken))
        return outcome
    }

    func subscriptions() async -> [StoreTransaction] { entitlements }
}

@MainActor
final class TillbellStoreTests: XCTestCase {
    private let accountId = "6f1c2a8e-3b7d-4e59-9a0c-2d4f8b1e7c35"
    private var client: FakeStoreClient!
    private var store: TillbellStore!

    override func setUp() async throws {
        client = FakeStoreClient()
        client.catalog = [
            StoreProduct(id: "premium.monthly", displayPrice: "€4.99"),
            StoreProduct(id: "premium.yearly", displayPrice: "€49.99"),
        ]
        store = TillbellStore(client: client)
    }

    // MARK: allowed hosts

    func testEveryPageIsTrustedWithoutAllowedHosts() async {
        let reply = await store.answer(event: "restore", jsonData: #"{"metadata":{"url":"https://elsewhere.test/page"}}"#)
        XCTAssertTrue(reply?.contains(#""result":"ok""#) ?? false)
        XCTAssertTrue(store.isTrusted(jsonData: "{}"))
    }

    func testOnlyPagesOnAnAllowedHostReachTheStore() async {
        store.allowedHosts = ["Example.com"]

        XCTAssertTrue(store.isTrusted(jsonData: #"{"metadata":{"url":"https://example.com/paywall"}}"#))
        XCTAssertFalse(store.isTrusted(jsonData: #"{"metadata":{"url":"https://evil.test/example.com"}}"#))
        XCTAssertFalse(store.isTrusted(jsonData: #"{"metadata":{"url":"https://example.com.evil.test/"}}"#))
        XCTAssertFalse(store.isTrusted(jsonData: "{}"))

        let purchase = #"{"productId":"premium.monthly","obfuscatedAccountId":"\#(accountId)","metadata":{"url":"https://evil.test/"}}"#
        let reply = await store.answer(event: "purchase", jsonData: purchase)
        XCTAssertTrue(reply?.contains(#""result":"error""#) ?? false)
        XCTAssertTrue(client.purchases.isEmpty)
        let restore = await store.answer(event: "restore", jsonData: #"{"metadata":{"url":"https://evil.test/"}}"#)
        XCTAssertTrue(restore?.contains(#""result":"error""#) ?? false)
    }

    // MARK: products

    func testPricesComeFromTheAppStoreInTheRequestedOrder() async {
        let reply = await store.products([Plan(productId: "premium.yearly"), Plan(productId: "premium.monthly")])
        XCTAssertEqual(reply, ProductsReply(result: .ok, products: [
            PricedPlan(productId: "premium.yearly", basePlanId: nil, formattedPrice: "€49.99"),
            PricedPlan(productId: "premium.monthly", basePlanId: nil, formattedPrice: "€4.99"),
        ]))
    }

    func testUnknownProductsAndPlansWithABasePlanAreLeftOut() async {
        let reply = await store.products([
            Plan(productId: "premium.monthly"), Plan(productId: "missing"), Plan(productId: "premium.yearly", basePlanId: "yearly"),
        ])
        XCTAssertEqual(reply.products, [PricedPlan(productId: "premium.monthly", basePlanId: nil, formattedPrice: "€4.99")])
        XCTAssertEqual(client.queriedIds, [["premium.monthly", "missing"]])
    }

    func testDuplicatePlansAreQueriedOnceAndPricedEach() async {
        let reply = await store.products([Plan(productId: "premium.monthly"), Plan(productId: "premium.monthly")])
        XCTAssertEqual(reply.products?.count, 2)
        XCTAssertEqual(client.queriedIds, [["premium.monthly"]])
    }

    func testAnEmptyRequestDoesNotCallTheAppStore() async {
        let reply = await store.products([])
        XCTAssertEqual(reply, ProductsReply(result: .ok, products: []))
        XCTAssertTrue(client.queriedIds.isEmpty)
    }

    func testProductsAreUnavailableWhenTheAccountCannotPay() async {
        client.canMakePayments = false
        let reply = await store.products([Plan(productId: "premium.monthly")])
        XCTAssertEqual(reply.result, .unavailable)
        XCTAssertTrue(client.queriedIds.isEmpty)
    }

    func testProductQueryFailuresMapToUnavailableOrError() async {
        client.productsError = StoreError(unavailable: true, message: "notAvailableInStorefront")
        let unavailable = await store.products([Plan(productId: "premium.monthly")])
        XCTAssertEqual(unavailable, ProductsReply(result: .unavailable, message: "notAvailableInStorefront"))

        client.productsError = StoreError(unavailable: false, message: "networkError")
        let error = await store.products([Plan(productId: "premium.monthly")])
        XCTAssertEqual(error, ProductsReply(result: .error, message: "networkError"))
    }

    // MARK: purchase

    func testPurchasePassesTheAccountIdUnchangedAsTheAppAccountToken() async {
        client.outcome = .purchased(StoreTransaction(productId: "premium.monthly", jws: "signed"))
        let reply = await store.purchase(request("premium.monthly"))
        XCTAssertEqual(reply, PurchaseReply(result: .purchased, productId: "premium.monthly", purchaseToken: "signed"))
        XCTAssertEqual(client.purchases.map(\.appAccountToken), [UUID(uuidString: accountId)!])
        XCTAssertEqual(client.purchases.first?.appAccountToken.uuidString.lowercased(), accountId)
    }

    func testEachOutcomeMapsToOneReply() async {
        let cases: [(StorePurchaseOutcome, PurchaseReply)] = [
            (.canceled, PurchaseReply(result: .canceled)),
            (.unavailable("productUnavailable"), PurchaseReply(result: .unavailable, message: "productUnavailable")),
            (.failed("networkError"), PurchaseReply(result: .error, message: "networkError")),
        ]
        for (outcome, expected) in cases {
            client.outcome = outcome
            let reply = await store.purchase(request("premium.monthly"))
            XCTAssertEqual(reply, expected)
        }
    }

    func testAPurchaseWaitingForApprovalIsPendingWithoutAToken() async {
        client.outcome = .pending
        let reply = await store.purchase(request("premium.monthly"))
        XCTAssertEqual(reply, PurchaseReply(result: .pending, productId: "premium.monthly"))
    }

    func testAProductAlreadySubscribedIsAlreadyOwnedWithoutTheSheet() async {
        client.entitlements = [StoreTransaction(productId: "premium.monthly", jws: "signed")]
        let reply = await store.purchase(request("premium.monthly"))
        XCTAssertEqual(reply, PurchaseReply(result: .alreadyOwned))
        XCTAssertTrue(client.purchases.isEmpty)
    }

    func testAPlanChangeGoesToTheSheetAndRepliesWithTheNewTransaction() async {
        client.entitlements = [StoreTransaction(productId: "premium.monthly", jws: "old")]
        client.outcome = .purchased(StoreTransaction(productId: "premium.yearly", jws: "new"))
        var change = request("premium.yearly")
        change.oldPurchaseToken = "old"
        change.replacementMode = .CHARGE_PRORATED_PRICE
        let reply = await store.purchase(change)
        XCTAssertEqual(reply, PurchaseReply(result: .purchased, productId: "premium.yearly", purchaseToken: "new"))
        XCTAssertEqual(client.purchases.map(\.productId), ["premium.yearly"])
    }

    func testMalformedRequestsAreRefusedBeforeTheSheet() async {
        var tokenOnly = request("premium.yearly")
        tokenOnly.oldPurchaseToken = "old"
        var modeOnly = request("premium.yearly")
        modeOnly.replacementMode = .DEFERRED
        var basePlan = request("premium")
        basePlan.basePlanId = "monthly"
        let notUUID = PurchaseRequest(productId: "premium.monthly", obfuscatedAccountId: "not-a-uuid")

        for bad in [tokenOnly, modeOnly, basePlan, notUUID] {
            let reply = await store.purchase(bad)
            XCTAssertEqual(reply.result, .error)
            XCTAssertNotNil(reply.message)
        }
        XCTAssertTrue(client.purchases.isEmpty)
    }

    func testPurchaseIsUnavailableWhenTheAccountCannotPay() async {
        client.canMakePayments = false
        let reply = await store.purchase(request("premium.monthly"))
        XCTAssertEqual(reply.result, .unavailable)
        XCTAssertTrue(client.purchases.isEmpty)
    }

    func testAMalformedPurchaseMessageGetsAnErrorReply() async {
        let reply = await store.answer(event: "purchase", jsonData: #"{"productId":"premium.monthly"}"#)
        let json = try? JSONSerialization.jsonObject(with: Data((reply ?? "").utf8)) as? NSDictionary
        XCTAssertEqual(json, ["result": "error", "message": "Malformed purchase request"])
        XCTAssertTrue(client.purchases.isEmpty)
    }

    // MARK: restore

    func testRestoreReturnsEverySubscriptionEntitlement() async {
        client.entitlements = [StoreTransaction(productId: "premium.monthly", jws: "a"), StoreTransaction(productId: "family", jws: "b")]
        let reply = await store.restore()
        XCTAssertEqual(reply, RestoreReply(result: .ok, purchases: [
            OwnedPurchase(productId: "premium.monthly", purchaseToken: "a"), OwnedPurchase(productId: "family", purchaseToken: "b"),
        ]))
    }

    private func request(_ productId: String) -> PurchaseRequest {
        PurchaseRequest(productId: productId, obfuscatedAccountId: accountId)
    }
}
