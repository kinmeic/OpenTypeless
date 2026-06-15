import XCTest
@testable import Typeless

final class PipelineStateTests: XCTestCase {

    func testPhaseIconName() {
        XCTAssertEqual(Pipeline.Phase.idle.iconName, "mic.fill")
        XCTAssertEqual(Pipeline.Phase.recording.iconName, "mic.circle.fill")
        XCTAssertEqual(Pipeline.Phase.processing(action: .dictate).iconName, "gearshape.fill")
    }

    func testActionRawValues() {
        XCTAssertEqual(Pipeline.Action.dictate.rawValue, "A")
        XCTAssertEqual(Pipeline.Action.translate.rawValue, "B")
        XCTAssertEqual(Pipeline.Action.assist.rawValue, "C")
    }
}
