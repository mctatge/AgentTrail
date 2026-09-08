import Foundation
import XCTest
@testable import TrailCore

final class CursorTrailTests: XCTestCase {
    private func event(_ identifier: Int64, kind: String = "mouse_move", time: Double = 0, x: Double? = 10, y: Double? = 20, bundle: String = "app") -> TrailEvent {
        var event = TrailEvent(sessionID: "session", kind: kind, timestamp: 1000 + time, monotonicNS: UInt64(max(0, time) * 1_000_000_000), bundleID: bundle)
        event.id = identifier
        event.x = x
        event.y = y
        return event
    }

    func testTrailPreservesCoordinatesAndStartsNewPathsAtGaps() {
        let events = [event(1, x: -200), event(2, time: 0.1, x: -180), event(3, kind: "gap", time: 0.2), event(4, time: 0.3, x: 400)]
        let trail = CursorTrail(events: events)
        XCTAssertEqual(trail.samples.map(\.id), [1, 2, 4])
        XCTAssertEqual(trail.samples.map(\.x), [-200, -180, 400])
        XCTAssertEqual(trail.samples.map(\.startsSegment), [true, false, true])
        XCTAssertEqual(trail.breakCount, 1)
    }

    func testPauseAppSwitchIdleAndInvalidCoordinatesBreakPath() {
        let events = [
            event(1), event(2, kind: "pause", time: 0.1), event(3, time: 0.2),
            event(4, time: 0.3, bundle: "other"), event(5, time: 3, bundle: "other"),
            event(6, time: 3.1, x: .infinity, bundle: "other"), event(7, time: 3.2, bundle: "other"),
            event(8, time: 3.3, x: nil, bundle: "other"), event(9, time: 3.4, bundle: "other")
        ]
        let trail = CursorTrail(events: events)
        XCTAssertEqual(trail.samples.map(\.id), [1, 3, 4, 5, 7, 9])
        XCTAssertTrue(trail.samples.allSatisfy(\.startsSegment))
        XCTAssertEqual(trail.breakCount, 5)
    }

    func testClickDragAndScrollSamplesRemainDistinguishable() {
        var down = event(1, kind: "mouse_down")
        down.button = 1
        let trail = CursorTrail(events: [down, event(2, kind: "mouse_drag", time: 0.1), event(3, kind: "mouse_up", time: 0.2), event(4, kind: "scroll", time: 0.3)])
        XCTAssertEqual(trail.clickCount, 1)
        XCTAssertEqual(trail.dragCount, 1)
        XCTAssertEqual(trail.samples.first?.button, 1)
        XCTAssertEqual(trail.samples.count, 4)
    }

    func testProjectionPreservesAspectRatioAndNegativeCoordinates() {
        let bounds = CursorBounds(minX: -200, minY: -100, width: 400, height: 200)
        let projection = CursorProjection(bounds: bounds, width: 800, height: 600, padding: 20)
        let first = projection.project(x: -200, y: -100)
        let last = projection.project(x: 200, y: 100)
        XCTAssertEqual(first.x, 20, accuracy: 0.001)
        XCTAssertEqual(first.y, 110, accuracy: 0.001)
        XCTAssertEqual(last.x, 780, accuracy: 0.001)
        XCTAssertEqual(last.y, 490, accuracy: 0.001)
        XCTAssertEqual((last.x - first.x) / (last.y - first.y), 2, accuracy: 0.001)
    }

    func testEmptyStationaryAndVerticalTrailsHaveUsableBounds() {
        for events in [[], [event(1)], [event(1), event(2, time: 1, y: 200)]] {
            let trail = CursorTrail(events: events)
            XCTAssertGreaterThanOrEqual(trail.bounds.width, 80)
            XCTAssertGreaterThanOrEqual(trail.bounds.height, 80)
            let projection = CursorProjection(bounds: trail.bounds, width: 800, height: 400)
            XCTAssertTrue(projection.scale.isFinite)
        }
        XCTAssertNil(CursorTrail(events: []).sampleIndex(at: 0))
    }

    func testPlaybackUsesMonotonicTimeAndHandlesEqualTimestamps() {
        var later = event(3, time: 1)
        later.timestamp = 900
        let trail = CursorTrail(events: [event(1), event(2), later])
        XCTAssertEqual(trail.duration, 1, accuracy: 0.000001)
        XCTAssertEqual(trail.sampleIndex(at: 0), 1)
        XCTAssertEqual(trail.sampleIndex(at: 0.5), 1)
        XCTAssertEqual(trail.sampleIndex(at: 1), 2)
        XCTAssertEqual(trail.sampleIndex(at: 10), 2)
        XCTAssertNil(trail.sampleIndex(at: -1))
        XCTAssertNil(trail.sampleIndex(at: .nan))
        XCTAssertEqual(trail.samples.last?.timestamp, 900)
    }

    func testPointerPagingRespectsActionRangeAndSessionIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenttrail-cursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrailStore(root: root)
        let session = Session(title: "Pointer paging")
        let other = Session(title: "Other")
        try store.saveSession(session)
        try store.saveSession(other)
        for identifier in 1...6 {
            var record = event(Int64(identifier), kind: identifier == 3 ? "key_down" : identifier == 5 ? "gap" : "mouse_move")
            record.sessionID = session.id
            _ = try store.append(record)
        }
        _ = try store.append(TrailEvent(sessionID: other.id, kind: "mouse_move"))
        let first = try store.cursorPage(sessionID: session.id, limit: 2)
        XCTAssertEqual(first.events.map(\.id), [1, 2])
        XCTAssertTrue(first.hasMore)
        let second = try store.cursorPage(sessionID: session.id, afterID: first.lastEventID!, throughID: 5, limit: 2)
        XCTAssertEqual(second.events.map(\.id), [4, 5])
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(try store.cursorPage(sessionID: session.id, afterID: 5).events.map(\.id), [6])
    }

    func testRawLogStreamsEveryPageAndCanResumeWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenttrail-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrailStore(root: root)
        let session = Session(title: "Raw output")
        try store.saveSession(session)
        try store.transaction {
            for _ in 0..<1102 { _ = try store.append(TrailEvent(sessionID: session.id, kind: "mouse_move")) }
        }
        var records: [TrailEvent] = []
        let cursor = try RawLog.write(store: store, sessionID: session.id) { data in
            XCTAssertEqual(data.last, 10)
            records.append(try JSONDecoder().decode(TrailEvent.self, from: data))
        }
        XCTAssertEqual(records.count, 1102)
        XCTAssertEqual(cursor, records.last?.id)
        _ = try store.append(TrailEvent(sessionID: session.id, kind: "marker"))
        var resumed: [TrailEvent] = []
        try RawLog.write(store: store, sessionID: session.id, afterID: cursor) { data in
            resumed.append(try JSONDecoder().decode(TrailEvent.self, from: data))
        }
        XCTAssertEqual(resumed.count, 1)
        XCTAssertEqual(resumed[0].kind, "marker")
        XCTAssertThrowsError(try RawLog.write(store: store, sessionID: session.id) { _ in throw TrailError.message("output closed") })
        XCTAssertEqual(try store.session(session.id).eventCount, 1103)
    }
}
