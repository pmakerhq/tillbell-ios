import Foundation
import XCTest
@testable import Tillbell

/// Checks the replies against the JSON Schemas and examples of the bridge contract, copied from
/// tillbell-rails into Resources/contract.
@MainActor
final class ContractTests: XCTestCase {
    func testRequestExamplesDecodeIgnoringTheBridgeMetadata() throws {
        let products: ProductsRequest = try decodeExample("products.request")
        XCTAssertEqual(products.products, [Plan(productId: "premium", basePlanId: "monthly"), Plan(productId: "premium", basePlanId: "yearly")])

        let purchase: PurchaseRequest = try decodeExample("purchase.request")
        XCTAssertEqual(purchase.obfuscatedAccountId, "6f1c2a8e-3b7d-4e59-9a0c-2d4f8b1e7c35")
        XCTAssertNil(purchase.oldPurchaseToken)

        let change: PurchaseRequest = try decodeExample("purchase.request.plan_change")
        XCTAssertNotNil(change.oldPurchaseToken)
        XCTAssertEqual(change.replacementMode, .CHARGE_PRORATED_PRICE)
    }

    func testRepliesMatchTheContractExamples() throws {
        try assertMatches(ProductsReply(result: .ok, products: [
            PricedPlan(productId: "premium", basePlanId: "monthly", formattedPrice: "€4.99"),
            PricedPlan(productId: "premium", basePlanId: "yearly", formattedPrice: "€49.99"),
        ]), "products.reply.ok")
        try assertMatches(ProductsReply(result: .unavailable, message: "BILLING_UNAVAILABLE"), "products.reply.unavailable")
        try assertMatches(PurchaseReply(result: .purchased, productId: "premium", purchaseToken: "purchase-token"), "purchase.reply.purchased")
        try assertMatches(PurchaseReply(result: .pending, productId: "premium", purchaseToken: "purchase-token"), "purchase.reply.pending")
        try assertMatches(PurchaseReply(result: .pending, productId: "premium.monthly"), "purchase.reply.pending_approval")
        try assertMatches(PurchaseReply(result: .canceled), "purchase.reply.canceled")
        try assertMatches(PurchaseReply(result: .alreadyOwned), "purchase.reply.already_owned")
        try assertMatches(PurchaseReply(result: .unavailable), "purchase.reply.unavailable")
        try assertMatches(PurchaseReply(result: .error, message: "DEVELOPER_ERROR"), "purchase.reply.error")
        try assertMatches(RestoreReply(result: .ok, purchases: [OwnedPurchase(productId: "premium", purchaseToken: "purchase-token")]), "restore.reply.ok")
        try assertMatches(RestoreReply(result: .ok, purchases: []), "restore.reply.empty")
    }

    func testANullBasePlanIsEncodedAsNull() throws {
        let json = try jsonObject(encoded(PricedPlan(productId: "premium", basePlanId: nil, formattedPrice: "€4.99")))
        XCTAssertTrue((json as? [String: Any])?["basePlanId"] is NSNull)
    }

    func testEveryReplyTheStoreBuildsValidates() async throws {
        let client = FakeStoreClient()
        client.catalog = [StoreProduct(id: "premium.monthly", displayPrice: "€4.99")]
        client.entitlements = [StoreTransaction(productId: "premium.monthly", jws: "jws")]
        let store = TillbellStore(client: client)
        let validPurchase = #"{"productId":"premium.yearly","basePlanId":null,"obfuscatedAccountId":"6f1c2a8e-3b7d-4e59-9a0c-2d4f8b1e7c35"}"#

        var replies: [(String, String?)] = []
        replies.append(("products", await store.answer(event: "products", jsonData: #"{"products":[{"productId":"premium.monthly","basePlanId":null}]}"#)))
        replies.append(("products", await store.answer(event: "products", jsonData: "not json")))
        replies.append(("restore", await store.answer(event: "restore", jsonData: "{}")))
        replies.append(("purchase", await store.answer(event: "purchase", jsonData: "{}")))
        for outcome: StorePurchaseOutcome in [.purchased(StoreTransaction(productId: "premium.yearly", jws: "jws")), .pending, .canceled, .unavailable("x"), .failed("x")] {
            client.outcome = outcome
            replies.append(("purchase", await store.answer(event: "purchase", jsonData: validPurchase)))
        }
        client.productsError = StoreError(unavailable: true, message: "x")
        replies.append(("products", await store.answer(event: "products", jsonData: #"{"products":[{"productId":"premium.monthly","basePlanId":null}]}"#)))

        for (event, reply) in replies {
            let reply = try XCTUnwrap(reply, event)
            try validate(jsonObject(Data(reply.utf8)), against: schema("\(event).reply"), path: "\(event): \(reply)")
        }
    }

    func testManageAndUnknownEventsGetNoReply() async {
        let store = TillbellStore(client: FakeStoreClient())
        let manage = await store.answer(event: "manage", jsonData: #"{"productId":"premium"}"#)
        let unknown = await store.answer(event: "unknown", jsonData: "{}")
        XCTAssertNil(manage)
        XCTAssertNil(unknown)
    }

    // MARK: Helpers

    private func assertMatches<T: Encodable>(_ reply: T, _ example: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try jsonObject(encoded(reply)) as? NSDictionary
        let expected = try jsonObject(Data(contentsOf: contractURL("examples/\(example).json"))) as? NSDictionary
        XCTAssertEqual(actual, expected, example, file: file, line: line)
        try validate(XCTUnwrap(actual), against: schema(String(example.split(separator: ".").prefix(2).joined(separator: "."))), path: example)
    }

    private func decodeExample<T: Decodable>(_ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: contractURL("examples/\(name).json")))
    }

    private func schema(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(jsonObject(Data(contentsOf: contractURL("\(name).json"))) as? [String: Any])
    }

    private func contractURL(_ path: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "contract", withExtension: nil)).appendingPathComponent(path)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    private func jsonObject(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }

    // The subset of JSON Schema the contract uses: type, enum, const, minLength, maxLength,
    // required, properties, additionalProperties: false, items, and if/then (also inside allOf).
    private func validate(_ value: Any, against schema: [String: Any], path: String) throws {
        if let types = schema["type"] {
            let allowed = (types as? [String]) ?? [types as! String]
            XCTAssertTrue(allowed.contains(typeName(value)), "\(path): \(typeName(value)) is not \(allowed)")
        }
        if let values = schema["enum"] as? [String] { XCTAssertTrue(values.contains(value as? String ?? ""), "\(path): \(value) not in \(values)") }
        if let string = value as? String {
            if let min = schema["minLength"] as? Int { XCTAssertGreaterThanOrEqual(string.count, min, path) }
            if let max = schema["maxLength"] as? Int { XCTAssertLessThanOrEqual(string.count, max, path) }
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for item in array { try validate(item, against: items, path: path) }
        }
        guard let object = value as? [String: Any] else { return }
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        for key in schema["required"] as? [String] ?? [] { XCTAssertNotNil(object[key], "\(path): missing \(key)") }
        if schema["additionalProperties"] as? Bool == false {
            for key in object.keys { XCTAssertNotNil(properties[key], "\(path): unexpected \(key)") }
        }
        for (key, child) in object { if let property = properties[key] { try validate(child, against: property, path: "\(path).\(key)") } }
        for rule in [schema] + (schema["allOf"] as? [[String: Any]] ?? []) {
            if let condition = rule["if"] as? [String: Any], let then = rule["then"] as? [String: Any], matches(object, condition) {
                try validate(object, against: then, path: path)
            }
        }
    }

    private func matches(_ object: [String: Any], _ condition: [String: Any]) -> Bool {
        let properties = condition["properties"] as? [String: [String: Any]] ?? [:]
        return properties.allSatisfy { key, rule in
            let value = object[key] as? String
            if let constant = rule["const"] as? String { return value == constant }
            if let values = rule["enum"] as? [String] { return value.map(values.contains) ?? false }
            return true
        }
    }

    private func typeName(_ value: Any) -> String {
        switch value {
        case is NSNull: "null"
        case is String: "string"
        case is [Any]: "array"
        case is [String: Any]: "object"
        default: "other"
        }
    }
}
