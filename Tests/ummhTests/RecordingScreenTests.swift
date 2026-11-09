import AppKit
import XCTest
@testable import ummh

final class RecordingScreenTests: XCTestCase {
    private let primary = RecordingScreenSelection.Display(
        id: 1, frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: NSRect(x: 0, y: 30, width: 1000, height: 750))
    private let secondary = RecordingScreenSelection.Display(
        id: 2, frame: NSRect(x: -900, y: 0, width: 900, height: 700),
        visibleFrame: NSRect(x: -900, y: 30, width: 900, height: 650))

    func testCursorChoosesDisplayAndLaterRefreshesRetainItWithFreshGeometry() {
        var selection = RecordingScreenSelection()
        let displays = [primary, secondary]
        XCTAssertEqual(selection.resolve(displays, cursor: NSPoint(x: -50, y: 50), mainID: 1)?.id, 2)

        let updated = RecordingScreenSelection.Display(
            id: 2, frame: secondary.frame, visibleFrame: secondary.visibleFrame.offsetBy(dx: 0, dy: 12))
        let retained = selection.resolve([primary, updated], cursor: NSPoint(x: 50, y: 50), mainID: 1)
        XCTAssertEqual(retained?.id, 2)
        XCTAssertEqual(retained?.visibleFrame, updated.visibleFrame)
    }

    func testDisconnectedDisplayFallsBackAndDoesNotJumpBackWhenReconnected() {
        var selection = RecordingScreenSelection()
        let cursor = NSPoint(x: -50, y: 50)
        XCTAssertEqual(selection.resolve([primary, secondary], cursor: cursor, mainID: 1)?.id, 2)
        XCTAssertEqual(selection.resolve([primary], cursor: cursor, mainID: 1)?.id, 1)
        XCTAssertEqual(selection.resolve([primary, secondary], cursor: cursor, mainID: 1)?.id, 1)

        selection.reset()
        XCTAssertEqual(selection.resolve([primary, secondary], cursor: cursor, mainID: 1)?.id, 2)
    }

    func testFallbackUsesMainThenFirstAvailableDisplay() {
        var selection = RecordingScreenSelection()
        let cursor = NSPoint(x: 1500, y: 50)
        XCTAssertNil(selection.resolve([], cursor: cursor, mainID: 1))
        XCTAssertEqual(selection.resolve([secondary, primary], cursor: cursor, mainID: 1)?.id, 1)
        selection.reset()
        XCTAssertEqual(selection.resolve([secondary, primary], cursor: cursor, mainID: nil)?.id, 2)
    }
}
