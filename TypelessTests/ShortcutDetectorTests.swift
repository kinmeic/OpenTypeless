import XCTest
@testable import Typeless

final class ShortcutDetectorTests: XCTestCase {

    func testKeyCodeMapping() {
        XCTAssertEqual(KeyCodes.name(for: 0x00), "A")
        XCTAssertEqual(KeyCodes.name(for: 0x09), "V")
        XCTAssertEqual(KeyCodes.name(for: 0x31), "Space")
        XCTAssertEqual(KeyCodes.name(for: 0x24), "Return")
    }

    func testKeyCodeReverseLookup() {
        XCTAssertEqual(KeyCodes.keyCode(for: "A"), 0x00)
        XCTAssertEqual(KeyCodes.keyCode(for: "Space"), 0x31)
        XCTAssertNil(KeyCodes.keyCode(for: "NonExistent"))
    }
}
