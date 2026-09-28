import XCTest
@testable import Core

final class CoreInfoTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(CoreInfo.version.isEmpty)
    }
}
