import XCTest
@testable import Tillbell

final class TillbellTests: XCTestCase {
    func testComponentNameMatchesTheBridgeContract() {
        XCTAssertEqual(Tillbell.componentName, "tillbell")
    }
}
