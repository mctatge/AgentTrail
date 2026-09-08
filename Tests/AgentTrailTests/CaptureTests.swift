import Foundation
import XCTest
import TrailCore
@testable import AgentTrail

final class CaptureTests: XCTestCase {
    func testCaptureContinuesWhileMainThreadIsBlocked() throws {
        XCTAssertTrue(Thread.isMainThread)
        let buffer = InputEventBuffer()
        let worker = CaptureRunLoop()
        let captured = DispatchSemaphore(value: 0)
        try worker.start {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertFalse(CFEqual(CFRunLoopGetCurrent(), CFRunLoopGetMain()))
            var count = 0
            let timer = Timer(timeInterval: 0.01, repeats: true) { timer in
                var event = TrailEvent(sessionID: "test", kind: count.isMultiple(of: 2) ? "mouse_drag" : "key_down")
                event.x = Double(count)
                event.keyCode = 2
                buffer.append(event)
                count += 1
                if count == 70 { timer.invalidate(); captured.signal() }
            }
            RunLoop.current.add(timer, forMode: .default)
            return { timer.invalidate() }
        }
        defer { worker.stop() }
        XCTAssertEqual(captured.wait(timeout: .now() + 5), .success)
        let events = buffer.takeAll()
        XCTAssertEqual(events.count, 70)
        XCTAssertEqual(events.filter { $0.kind == "mouse_drag" }.count, 35)
        XCTAssertEqual(events.filter { $0.kind == "key_down" }.count, 35)
        XCTAssertGreaterThan(events.last!.timestamp - events.first!.timestamp, 0.5)
        XCTAssertEqual(events.map(\.x), (0..<70).map { Double($0) })
    }

    func testRunLoopStopsCleansUpAndCanRestartAfterFailure() throws {
        let worker = CaptureRunLoop()
        XCTAssertThrowsError(try worker.start { throw TrailError.message("Permission unavailable") })
        for _ in 0..<3 {
            let cleanup = DispatchSemaphore(value: 0)
            try worker.start { { cleanup.signal() } }
            worker.stop()
            XCTAssertEqual(cleanup.wait(timeout: .now() + 1), .success)
            worker.stop()
        }
    }

    func testPauseDropsInputsImmediatelyBeforeMainThreadDelivery() {
        let buffer = InputEventBuffer()
        buffer.append(TrailEvent(sessionID: "test", kind: "key_down", timestamp: 1))
        buffer.togglePause(sessionID: "test", timestamp: 2)
        for _ in 0..<100 { buffer.append(TrailEvent(sessionID: "test", kind: "key_down", timestamp: 3)) }
        buffer.togglePause(sessionID: "test", timestamp: 4)
        buffer.append(TrailEvent(sessionID: "test", kind: "mouse_drag", timestamp: 5))
        let events = buffer.takeAll()
        XCTAssertEqual(events.map(\.kind), ["key_down", "pause", "resume", "mouse_drag"])
        XCTAssertEqual(events.map(\.timestamp), [1, 2, 4, 5])
        XCTAssertTrue(buffer.takeAll().isEmpty)
    }

    func testOverflowIsBoundedCountedAndOrderedBeforePause() {
        let buffer = InputEventBuffer(capacity: 5)
        for index in 0..<10000 {
            buffer.append(TrailEvent(sessionID: "test", kind: "mouse_move", timestamp: Double(index)))
        }
        buffer.togglePause(sessionID: "test", timestamp: 10000)
        let events = buffer.takeAll()
        XCTAssertEqual(events.count, 7)
        XCTAssertEqual(events[5].kind, "gap")
        XCTAssertEqual(events[5].timestamp, 5)
        XCTAssertEqual(events[5].fields["dropped_count"], "9995")
        XCTAssertEqual(events.last?.kind, "pause")
        buffer.togglePause(sessionID: "test", timestamp: 10001)
        buffer.append(TrailEvent(sessionID: "test", kind: "mouse_down", timestamp: 10002))
        XCTAssertEqual(buffer.takeAll().map(\.kind), ["resume", "mouse_down"])
    }

    func testForegroundIsCapturedBeforeDeliveryNotReadAfterward() {
        let buffer = InputEventBuffer()
        buffer.updateForeground(CaptureForeground(app: "First", bundleID: "first", observedAt: 1))
        buffer.append(TrailEvent(sessionID: "test", kind: "key_down", timestamp: 2))
        buffer.updateForeground(CaptureForeground(app: "Second", bundleID: "second", observedAt: 3))
        buffer.append(TrailEvent(sessionID: "test", kind: "mouse_down", timestamp: 4))
        let events = buffer.takeAll()
        XCTAssertEqual(events.map(\.bundleID), ["first", "second"])
        XCTAssertEqual(events.map { $0.fields["foreground_observed_at"] }, ["1.0", "3.0"])
    }

    func testGapDeduplicationResetsAfterAnInput() {
        let buffer = InputEventBuffer()
        var gap = TrailEvent(sessionID: "test", kind: "gap")
        gap.fields["reason"] = "Secure input is active"
        for _ in 0..<100 { buffer.append(gap) }
        buffer.append(TrailEvent(sessionID: "test", kind: "key_down"))
        buffer.append(gap)
        XCTAssertEqual(buffer.takeAll().map(\.kind), ["gap", "key_down", "gap"])
    }
}
