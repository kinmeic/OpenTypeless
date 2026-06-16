import XCTest
@testable import OpenTypeless

final class PipelineStateTests: XCTestCase {

    func testPhaseIconName() {
        XCTAssertEqual(Pipeline.Phase.idle.iconName, "waveform")
        XCTAssertEqual(Pipeline.Phase.recording.iconName, "waveform")
        XCTAssertEqual(Pipeline.Phase.processing(action: .dictate).iconName, "waveform.circle")
    }

    func testActionRawValues() {
        XCTAssertEqual(Pipeline.Action.dictate.rawValue, "A")
        XCTAssertEqual(Pipeline.Action.translate.rawValue, "B")
        XCTAssertEqual(Pipeline.Action.assist.rawValue, "C")
    }
}
