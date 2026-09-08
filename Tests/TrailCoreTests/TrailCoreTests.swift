import Foundation
import XCTest
@testable import TrailCore

final class TrailCoreTests: XCTestCase {
    private var root: URL!
    private var store: TrailStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agenttrail-test-\(UUID().uuidString)")
        store = try TrailStore(root: root)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: root)
    }

    func testDragPreservesButtonBoundariesAndRawCoordinates() throws {
        let session = Session(title: "Drag")
        try store.saveSession(session)
        let builder = ActionBuilder()
        var output: [TrailAction] = []
        for index in 0...101 {
            var event = TrailEvent(sessionID: session.id, kind: index == 0 ? "mouse_down" : index == 101 ? "mouse_up" : "mouse_drag", timestamp: Double(index) / 60)
            event.x = -120 + Double(index)
            event.y = 200
            event.button = 0
            output += builder.consume(try store.append(event))
        }
        output += builder.flush()
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].kind, "drag")
        XCTAssertEqual(output[0].eventCount, 102)
        XCTAssertEqual(output[0].firstEventID, 1)
        XCTAssertEqual(output[0].lastEventID, 102)
        XCTAssertTrue(output[0].summary.contains("(-120, 200) → (-19, 200)"))
        XCTAssertEqual(try store.events(sessionID: session.id).count, 102)
    }

    func testShortcutIsObservedAndExcelOutcomeIsOnlyAnInference() {
        let builder = ActionBuilder()
        var event = TrailEvent(sessionID: "session", kind: "key_down", app: "Excel", bundleID: "com.microsoft.Excel")
        event.key = "D"
        event.keyCode = 2
        event.modifiers = ["command"]
        let action = builder.consume(event)[0]
        XCTAssertEqual(action.summary, "⌘D")
        XCTAssertTrue(action.inference!.contains("not verified"))
        XCTAssertNil(action.context?.selection)
        event.bundleID = "com.apple.Safari"
        XCTAssertNil(builder.consume(event)[0].inference)
    }

    func testTypingBreaksAtPauseAndAppSwitch() {
        let builder = ActionBuilder()
        var event = TrailEvent(sessionID: "session", kind: "key_down", timestamp: 1, bundleID: "app.a")
        event.fields["printable"] = "true"
        event.keyCode = 0
        XCTAssertTrue(builder.consume(event).isEmpty)
        event.timestamp = 1.1
        XCTAssertTrue(builder.consume(event).isEmpty)
        event.kind = "pause"
        let output = builder.consume(event)
        XCTAssertEqual(output.map(\.kind), ["typing", "pause"])
        XCTAssertEqual(output[0].eventCount, 2)
        XCTAssertTrue(output[0].summary.contains("text not collected"))
        event.kind = "key_down"
        _ = builder.consume(event)
        event.bundleID = "app.b"
        XCTAssertEqual(builder.consume(event).first?.bundleID, "app.a")
        XCTAssertEqual(builder.flush().first?.bundleID, "app.b")
    }

    func testContextDoesNotBecomeAClaimedAction() {
        let builder = ActionBuilder()
        var event = TrailEvent(sessionID: "session", kind: "context")
        event.context = ElementContext(app: "Excel", bundleID: "com.microsoft.Excel")
        event.context?.selection = "B2:B10"
        XCTAssertEqual(builder.consume(event), [])
        XCTAssertEqual(builder.flush(), [])
    }

    func testCoalescingKeepsRawEventsAndDoesNotCrossSession() throws {
        let first = Session(title: "First")
        let second = Session(title: "Second")
        try store.saveSession(first)
        try store.saveSession(second)
        for index in 0..<1500 {
            var event = TrailEvent(sessionID: first.id, kind: "mouse_move", timestamp: Double(index) / 120)
            event.x = Double(index)
            event.y = 200
            _ = try store.append(event)
        }
        _ = try store.append(TrailEvent(sessionID: second.id, kind: "marker"))
        try store.rebuildActions(sessionID: first.id)
        XCTAssertEqual(try store.actions(sessionID: first.id).count, 1)
        XCTAssertEqual(try store.actions(sessionID: first.id)[0].eventCount, 1500)
        XCTAssertEqual(try store.events(sessionID: first.id, afterID: 1000, limit: 1000).count, 500)
        XCTAssertEqual(try store.events(sessionID: second.id).count, 1)
        XCTAssertEqual(try store.events(sessionID: first.id, limit: Int.max).count, 1000)
    }

    func testTransactionRollsBackPartialWrites() throws {
        let session = Session(title: "Rollback")
        try store.saveSession(session)
        XCTAssertThrowsError(try store.transaction {
            _ = try store.append(TrailEvent(sessionID: session.id, kind: "marker"))
            throw TrailError.message("Disk simulation")
        })
        XCTAssertEqual(try store.events(sessionID: session.id).count, 0)
    }

    func testSearchTreatsQuotesAndWildcardsAsLiteralData() throws {
        let session = try DemoSession.create(in: store)
        XCTAssertEqual(try store.actions(sessionID: session.id, query: "fill-down").count, 2)
        XCTAssertTrue(try store.actions(sessionID: session.id, query: "' OR 1=1 --").isEmpty)
        XCTAssertTrue(try store.actions(sessionID: session.id, query: "%").isEmpty)
        XCTAssertEqual(try store.actions(sessionID: session.id, query: "⌘D").count, 1)
    }

    func testReadOnlyConnectionCannotWriteAndReadsCommittedEvents() throws {
        let session = Session(title: "Read-only")
        try store.saveSession(session)
        let reader = try TrailStore(root: root, readOnly: true)
        XCTAssertThrowsError(try reader.append(TrailEvent(sessionID: session.id, kind: "marker")))
        _ = try store.append(TrailEvent(sessionID: session.id, kind: "marker"))
        XCTAssertEqual(try reader.events(sessionID: session.id).count, 1)
    }

    func testCrashRecoveryRebuildsActionsAndMarksInterrupted() throws {
        let session = Session(title: "Interrupted")
        try store.saveSession(session)
        var event = TrailEvent(sessionID: session.id, kind: "key_down")
        event.fields["printable"] = "true"
        _ = try store.append(event)
        XCTAssertTrue(try store.actions(sessionID: session.id).isEmpty)
        try store.recoverInterruptedSessions()
        XCTAssertEqual(try store.session(session.id).status, "interrupted")
        XCTAssertNil(try store.session(session.id).endedAt)
        XCTAssertEqual(try store.actions(sessionID: session.id).count, 1)
        try store.recoverInterruptedSessions()
        XCTAssertEqual(try store.actions(sessionID: session.id).count, 1)
    }

    func testExportIncludesAllPagesAndRejectsExistingDestination() throws {
        var session = Session(title: "Complete | export")
        try store.saveSession(session)
        try store.transaction {
            for index in 0..<1103 {
                var event = TrailEvent(sessionID: session.id, kind: "marker", timestamp: Double(index))
                event.text = "Bookmark \(index)"
                _ = try store.append(event)
            }
        }
        try store.rebuildActions(sessionID: session.id)
        session.status = "complete"
        try store.saveSession(session)
        let destination = root.appendingPathComponent("dataset")
        try SessionExport.write(store: store, sessionID: session.id, destination: destination)
        for name in ["events.jsonl", "actions.jsonl", "training.jsonl"] {
            let content = try String(contentsOf: destination.appendingPathComponent(name))
            XCTAssertEqual(content.split(separator: "\n").count, 1103)
        }
        let markdown = try String(contentsOf: destination.appendingPathComponent("timeline.md"))
        XCTAssertTrue(markdown.contains("Bookmark 1102"))
        XCTAssertTrue(markdown.contains("Complete \\| export"))
        XCTAssertThrowsError(try SessionExport.write(store: store, sessionID: session.id, destination: destination))
    }

    func testExportRejectsLiveSessionAndUnsafeAttachment() throws {
        var session = Session(title: "Unsafe")
        try store.saveSession(session)
        let destination = root.appendingPathComponent("dataset")
        XCTAssertThrowsError(try SessionExport.write(store: store, sessionID: session.id, destination: destination))
        session.status = "complete"
        try store.saveSession(session)
        var event = TrailEvent(sessionID: session.id, kind: "screenshot")
        event.attachment = "../outside.jpg"
        _ = try store.append(event)
        XCTAssertThrowsError(try SessionExport.write(store: store, sessionID: session.id, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testEvidenceIncludesDelayedContextWithItsOwnTimestamp() throws {
        let session = Session(title: "Evidence")
        try store.saveSession(session)
        let input = try store.append(TrailEvent(sessionID: session.id, kind: "key_down", timestamp: 10))
        let action = TrailAction(event: input, kind: "shortcut", summary: "⌘D")
        for _ in 0..<4 { _ = try store.append(TrailEvent(sessionID: session.id, kind: "mouse_move")) }
        var context = TrailEvent(sessionID: session.id, kind: "context", timestamp: 10.75)
        context.relatedEventID = input.id
        _ = try store.append(context)
        let evidence = try store.evidence(for: action)
        XCTAssertEqual(evidence.map(\.kind), ["key_down", "context"])
        XCTAssertEqual(evidence.last?.timestamp, 10.75)
    }

    func testMCPInitializationToolsSearchAndNotifications() throws {
        let session = try DemoSession.create(in: store)
        let server = MCPServer(store: try TrailStore(root: root, readOnly: true))
        func request(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": method, "params": params])
            return try XCTUnwrap(server.handle(data))
        }
        let initialized = try request("initialize", params: ["protocolVersion": "2025-03-26"])
        XCTAssertEqual((initialized["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
        let tools = try request("tools/list")
        XCTAssertEqual(((tools["result"] as? [String: Any])?["tools"] as? [Any])?.count, 3)
        let result = try request("tools/call", params: ["name": "search_actions", "arguments": ["session_id": session.id, "query": "⌘D", "limit": 10]])
        let content = ((result["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        let actions = try JSONDecoder().decode([TrailAction].self, from: Data(try XCTUnwrap(content).utf8))
        XCTAssertEqual(actions.count, 1)
        let notification = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)
        XCTAssertNil(server.handle(notification))
        let unknown = try request("tools/call", params: ["name": "delete_session", "arguments": ["session_id": session.id]])
        XCTAssertEqual((unknown["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testCaptureAllowlistAndExclusions() {
        var options = CaptureOptions()
        XCTAssertTrue(options.allows("com.microsoft.Excel"))
        XCTAssertFalse(options.allows("com.1password.1password"))
        options.allowedBundleIDs = ["com.microsoft.Excel"]
        XCTAssertFalse(options.allows("com.apple.Safari"))
        XCTAssertTrue(options.allows("com.microsoft.Excel"))
        options.excludedBundleIDs.append("com.microsoft.Excel")
        XCTAssertFalse(options.allows("com.microsoft.Excel"))
    }

    func testSingleWriterLeasePreventsSecondRecorder() throws {
        var first: WriterLease? = try WriterLease(root: root)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try WriterLease(root: root))
        first = nil
        XCTAssertNoThrow(try WriterLease(root: root))
    }

    func testRawEventRoundTripPreservesTimestampModifiersAndUnicode() throws {
        let session = Session(title: "Round trip")
        try store.saveSession(session)
        var event = TrailEvent(sessionID: session.id, kind: "key_down", timestamp: 100.123456, monotonicNS: 9_999_000_777)
        event.keyCode = 2
        event.modifiers = ["shift", "command"]
        event.text = "日本語🙂\n"
        let saved = try store.append(event)
        XCTAssertEqual(try store.events(sessionID: session.id).first, saved)
    }
}
