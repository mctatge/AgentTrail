import AppKit
import XCTest
import TrailCore
@testable import AgentTrail

final class QuitRecordingTests: XCTestCase {
    private var root: URL!
    private var library: TrailStore!
    private var lease: WriterLease!
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agenttrail-quit-\(UUID().uuidString)")
        library = try TrailStore(root: root)
        lease = try WriterLease(root: root)
        suite = "agenttrail-quit-\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        preferences.removePersistentDomain(forName: suite)
        lease = nil
        library = nil
        try FileManager.default.removeItem(at: root)
    }

    func testCancelQuitLeavesRecordingRunningAndUnsaved() throws {
        let input = QuitTestInput()
        let model = try makeModel(input)
        model.start()
        let id = try XCTUnwrap(model.currentSession?.id)
        let delegate = ApplicationDelegate(model: model, lease: lease, confirmQuit: { active in
            XCTAssertTrue(active)
            return .cancel
        }, replyToQuit: { _ in XCTFail("Cancel must return directly, without deferring termination") })

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(model.currentSession?.id, id)
        XCTAssertTrue(model.isRecording)
        XCTAssertTrue(model.hasUnsavedRecording)
        XCTAssertEqual(input.stopCount, 0, "Cancel must not stop active capture")
        XCTAssertTrue(try library.sessions().isEmpty)
        model.stop()
        waitUntil { !model.isFinalizing }
        model.discardRecording()
    }

    func testSaveAndQuitFinalizesThenExplicitlyPersistsRecording() throws {
        let model = try makeModel()
        model.start()
        let id = try XCTUnwrap(model.currentSession?.id)
        var reply: Bool?
        let delegate = ApplicationDelegate(model: model, lease: lease, confirmQuit: { _ in .save }, replyToQuit: { reply = $0 })

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        waitUntil { reply != nil }
        XCTAssertEqual(reply, true)
        XCTAssertFalse(model.hasUnsavedRecording)
        XCTAssertNil(model.currentSession)
        XCTAssertEqual(try library.sessions().map(\.id), [id])
        XCTAssertEqual(try library.events(sessionID: id).last?.kind, "session_end")
    }

    func testDiscardAndQuitFinalizesWithoutSaving() throws {
        let input = QuitTestInput()
        let model = try makeModel(input)
        model.start()
        var reply: Bool?
        let delegate = ApplicationDelegate(model: model, lease: lease, confirmQuit: { _ in .discard }, replyToQuit: { reply = $0 })

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        waitUntil { reply != nil }
        XCTAssertEqual(reply, true)
        XCTAssertEqual(input.stopCount, 1)
        XCTAssertFalse(model.hasUnsavedRecording)
        XCTAssertNil(model.currentSession)
        XCTAssertTrue(try library.sessions().isEmpty)
    }

    func testFailedSaveAndQuitKeepsDraftAndCancelsTermination() throws {
        let model = try makeModel()
        model.createDemo()
        waitUntil { model.hasUnsavedRecording && !model.isFinalizing }
        let draft = try XCTUnwrap(model.draftSession)
        // A duplicate ID forces promotion to fail without damaging the draft.
        try library.saveSession(draft)
        var reply: Bool?
        let delegate = ApplicationDelegate(model: model, lease: lease, confirmQuit: { _ in .save }, replyToQuit: { reply = $0 })

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        waitUntil { reply != nil }
        XCTAssertEqual(reply, false)
        XCTAssertTrue(model.hasUnsavedRecording)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.draftSession?.id, draft.id)
        XCTAssertNotNil(model.errorMessage)
    }

    func testQuitDuringExplicitSaveWaitsAndDoesNotRetryFailedSave() throws {
        let model = try makeModel()
        model.createDemo()
        waitUntil { model.hasUnsavedRecording && !model.isFinalizing }
        try library.saveSession(XCTUnwrap(model.draftSession))
        model.saveRecording()
        XCTAssertTrue(model.isSaving)
        var reply: Bool?
        let delegate = ApplicationDelegate(model: model, lease: lease, confirmQuit: { _ in
            XCTFail("An explicit Save is already in progress")
            return .save
        }, replyToQuit: { reply = $0 })

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        waitUntil { reply != nil }
        XCTAssertEqual(reply, false)
        XCTAssertTrue(model.hasUnsavedRecording)
        XCTAssertFalse(model.isSaving)
    }

    private func makeModel(_ input: QuitTestInput = QuitTestInput()) throws -> RecordingModel {
        try RecordingModel(store: library, captureDefaults: preferences, input: input, observesWorkspace: false)
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate(), "Timed out waiting for quit decision", file: file, line: line)
    }
}

private final class QuitTestInput: RecordingInput {
    var onEvent: ((TrailEvent) -> Void)?
    var sessionID = ""
    var includeText = false
    var stopCount = 0
    func start() throws {}
    func stop(deliverPending: Bool) { stopCount += 1 }
    func togglePause() {}
    func drain() {}
    func updateForeground(_ app: NSRunningApplication?) {}
}
