import XCTest
@testable import TrailCore

final class WindowGeometryTests: XCTestCase {
    func testTrackerSeedsDeduplicatesAndReportsOnlySizeChanges() {
        let tracker = WindowGeometryTracker()
        let first = snapshot(identity: "window", x: 10, y: 20, width: 800, height: 600)
        XCTAssertNil(tracker.observe(first))
        XCTAssertNil(tracker.observe(first))

        let moved = snapshot(identity: "window", x: 30, y: 40, width: 800, height: 600)
        XCTAssertNil(tracker.observe(moved), "A move is not a resize event")

        let resized = snapshot(identity: "window", x: 30, y: 40, width: 1024, height: 700)
        let change = XCTAssertNotNilAndReturn(tracker.observe(resized))
        XCTAssertEqual(change.previous.frame, moved.frame)
        XCTAssertEqual(change.current.frame, resized.frame)

        let otherWindow = snapshot(identity: "other-window", x: 0, y: 0, width: 1200, height: 900)
        XCTAssertNil(tracker.observe(otherWindow), "A new window establishes a new baseline")
    }

    func testResizeEventRoundTripsAndBuildsReadableAction() throws {
        let event = TrailEvent(sessionID: "session", kind: "window_resize", timestamp: 42,
                               monotonicNS: 99, app: "Safari", bundleID: "com.apple.Safari")
        var populated = event
        populated.windowTitle = "Example"
        populated.previousWindowFrame = WindowFrame(x: 10, y: 20, width: 800, height: 600)
        populated.windowFrame = WindowFrame(x: 10, y: 20, width: 1024, height: 700)
        populated.fields["source"] = "accessibility_poll"

        let roundTripped = try JSONDecoder().decode(TrailEvent.self, from: TrailJSON.encode(populated))
        XCTAssertEqual(roundTripped, populated)

        let action = ActionBuilder().consume(populated)[0]
        XCTAssertEqual(action.kind, "window_resize")
        XCTAssertEqual(action.summary, "Resize window · Example · 800×600 → 1024×700")
    }

    private func snapshot(identity: String, x: Double, y: Double, width: Double, height: Double) -> WindowGeometrySnapshot {
        WindowGeometrySnapshot(identity: identity, app: "Demo", bundleID: "com.example.demo", pid: 42,
                               windowTitle: "Demo", frame: WindowFrame(x: x, y: y, width: width, height: height))
    }
}

private extension XCTestCase {
    func XCTAssertNotNilAndReturn<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        XCTAssertNotNil(value, file: file, line: line)
        return value!
    }
}
