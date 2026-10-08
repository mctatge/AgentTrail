import AppKit
import XCTest
import TrailCore
@testable import AgentTrail

final class DraftRecordingTests: XCTestCase {
    private var root: URL!
    private var library: TrailStore!
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agenttrail-draft-model-\(UUID().uuidString)")
        library = try TrailStore(root: root)
        suite = "agenttrail-draft-model-\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        preferences.removePersistentDomain(forName: suite)
        library = nil
        try FileManager.default.removeItem(at: root)
    }

    func testStartPauseAndStopStayUnsavedUntilExplicitSave() throws {
        let input = SyntheticRecordingInput()
        let model = try makeModel(input)
        let reader = try TrailStore(root: root, readOnly: true)
        model.title = "Synthetic draft"
        model.start()
        let id = try XCTUnwrap(model.currentSession?.id)
        XCTAssertTrue(model.hasUnsavedRecording)
        XCTAssertTrue(model.selectedStore.isInMemory)
        XCTAssertEqual(input.startCount, 1)
        XCTAssertTrue(try reader.sessions().isEmpty)
        var rejectedActiveSave: Bool?
        model.saveRecording { rejectedActiveSave = $0 }
        XCTAssertEqual(rejectedActiveSave, false)
        model.markerText = "Synthetic evidence"
        model.addMarker()
        model.togglePause()
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(try reader.sessions().isEmpty)
        model.togglePause()
        input.deliverBookmarkOnStop = true
        model.stop()
        waitUntil { !model.isFinalizing && model.currentSession == nil }
        XCTAssertEqual(model.draftSession?.status, "complete")
        XCTAssertTrue(try reader.sessions().isEmpty, "Stop must not save into the durable library")
        XCTAssertEqual(try model.selectedStore.events(sessionID: id).filter { $0.kind == "marker" }.count, 2,
                       "Stopping must drain pending input before finishing the draft")
        model.start()
        model.createDemo()
        XCTAssertEqual(input.startCount, 1, "A draft must be saved or discarded before another recording")
        XCTAssertEqual(model.draftSession?.id, id)
        var saved: Bool?
        model.saveRecording { saved = $0 }
        waitUntil { saved != nil }
        XCTAssertEqual(saved, true)
        XCTAssertFalse(model.hasUnsavedRecording)
        XCTAssertFalse(model.selectedStore.isInMemory)
        XCTAssertEqual(try reader.sessions().map(\.id), [id])
        XCTAssertEqual(try reader.session(id).status, "complete")
        XCTAssertEqual(try reader.events(sessionID: id).last?.kind, "session_end")
        let reopened = try TrailStore(root: root, readOnly: true)
        XCTAssertEqual(try reopened.session(id).title, "Synthetic draft")
    }

    func testDiscardDoesNotDeleteExistingSavedSessionsOrResurrectDraftOnRefresh() throws {
        let saved = try DemoSession.create(in: library)
        let model = try makeModel()
        model.createDemo()
        waitUntil { model.hasUnsavedRecording && !model.isFinalizing }
        let draftID = try XCTUnwrap(model.draftSession?.id)
        XCTAssertNotEqual(saved.id, draftID)
        XCTAssertEqual(try library.sessions().map(\.id), [saved.id])
        model.query = "drag"
        model.refresh()
        model.discardRecording()
        waitUntil { model.sessions.map(\.id) == [saved.id] && model.selectedSessionID == saved.id }
        model.refresh()
        pumpMainLoop(for: 0.1)
        XCTAssertFalse(model.hasUnsavedRecording)
        XCTAssertFalse(model.sessions.contains { $0.id == draftID })
        XCTAssertFalse(model.actions.contains { $0.sessionID == draftID })
        let reopened = try makeModel()
        waitUntil { !reopened.sessions.isEmpty }
        XCTAssertEqual(reopened.sessions.map(\.id), [saved.id])
        XCTAssertFalse(reopened.hasUnsavedRecording)
    }

    func testFailedSaveRetainsDraftAndRetryPreservesScreenshots() throws {
        let model = try makeModel()
        model.createDemo()
        waitUntil { model.hasUnsavedRecording && !model.isFinalizing }
        let draft = model.selectedStore
        let id = try XCTUnwrap(model.draftSession?.id)
        let path = "sessions/\(id)/frames/synthetic.jpg"
        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        try draft.writeAttachment(bytes, relativePath: path)
        var frame = TrailEvent(sessionID: id, kind: "screenshot")
        frame.attachment = path
        frame.relatedEventID = try draft.events(sessionID: id).first?.id
        _ = try draft.append(frame)
        let obstacle = root.appendingPathComponent("sessions")
        try Data("test-only obstacle".utf8).write(to: obstacle)
        var first: Bool?
        model.saveRecording { first = $0 }
        waitUntil { first != nil }
        XCTAssertEqual(first, false)
        XCTAssertTrue(model.hasUnsavedRecording)
        XCTAssertFalse(model.isSaving)
        XCTAssertTrue(try library.sessions().isEmpty)
        XCTAssertEqual(try draft.attachmentData(relativePath: path), bytes)
        try FileManager.default.removeItem(at: obstacle)
        var second: Bool?
        model.saveRecording { second = $0 }
        waitUntil { second != nil }
        XCTAssertEqual(second, true)
        XCTAssertFalse(model.hasUnsavedRecording)
        XCTAssertEqual(try library.attachmentData(relativePath: path), bytes)
        XCTAssertEqual(try library.sessions().map(\.id), [id])
    }

    func testInputStartFailureDoesNotLeaveDraftOrSavedSession() throws {
        let input = SyntheticRecordingInput()
        input.startFailure = TrailError.message("Synthetic input unavailable")
        let model = try makeModel(input)
        model.start()
        XCTAssertNil(model.currentSession)
        XCTAssertFalse(model.hasUnsavedRecording)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(try library.sessions().isEmpty)
    }

    private func makeModel(_ input: SyntheticRecordingInput = SyntheticRecordingInput()) throws -> RecordingModel {
        try RecordingModel(store: library, captureDefaults: preferences, input: input, observesWorkspace: false)
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate(), "Timed out waiting for recorder transition", file: file, line: line)
    }

    private func pumpMainLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

private final class SyntheticRecordingInput: RecordingInput {
    var onEvent: ((TrailEvent) -> Void)?
    var sessionID = ""
    var includeText = false
    var startCount = 0
    var startFailure: Error?
    var deliverBookmarkOnStop = false
    private var paused = false

    func start() throws {
        startCount += 1
        if let startFailure { throw startFailure }
    }
    func stop(deliverPending: Bool) {
        if deliverPending && deliverBookmarkOnStop {
            onEvent?(TrailEvent(sessionID: sessionID, kind: "marker_shortcut"))
        }
    }
    func togglePause() {
        paused.toggle()
        onEvent?(TrailEvent(sessionID: sessionID, kind: paused ? "pause" : "resume"))
    }
    func drain() {}
    func updateForeground(_ app: NSRunningApplication?) {}
}
