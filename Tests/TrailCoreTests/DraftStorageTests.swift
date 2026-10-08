import Foundation
import XCTest
@testable import TrailCore

final class DraftStorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agenttrail-draft-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testDraftAndScreenshotsNeverCreateFilesAndDiscardLeavesNothing() throws {
        var draft: TrailStore? = try TrailStore(root: root, inMemory: true)
        XCTAssertTrue(try XCTUnwrap(draft).isInMemory)
        let session = Session(title: "Synthetic unsaved demonstration")
        try draft?.saveSession(session)
        _ = try draft?.append(TrailEvent(sessionID: session.id, kind: "marker"))
        let path = "sessions/\(session.id)/frames/example.jpg"
        let data = Data("synthetic image bytes".utf8)
        try draft?.writeAttachment(data, relativePath: path)
        XCTAssertEqual(try draft?.attachmentData(relativePath: path), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try TrailStore(root: root, readOnly: true))
        draft = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let freshDraft = try TrailStore(root: root, inMemory: true)
        XCTAssertTrue(try freshDraft.sessions().isEmpty)
        XCTAssertThrowsError(try freshDraft.attachmentData(relativePath: path))
        XCTAssertThrowsError(try TrailStore(root: root, readOnly: true, inMemory: true))
    }

    func testDraftIsInvisibleToReadOnlyLibraryAndMCPUntilExplicitSave() throws {
        let library = try TrailStore(root: root)
        let reader = try TrailStore(root: root, readOnly: true)
        let server = MCPServer(store: reader)
        let draft = try TrailStore(root: root, inMemory: true)
        let session = try completedSession(in: draft)
        XCTAssertTrue(try reader.sessions().isEmpty)
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions"}}"#.utf8)
        func listedSessions() throws -> [Session] {
            let response = try XCTUnwrap(server.handle(request))
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let json = try XCTUnwrap(content.first?["text"] as? String)
            return try JSONDecoder().decode([Session].self, from: Data(json.utf8))
        }
        XCTAssertTrue(try listedSessions().isEmpty)
        try library.saveRecording(from: draft, sessionID: session.id)
        XCTAssertEqual(try reader.sessions().map(\.id), [session.id])
        XCTAssertEqual(try listedSessions().map(\.id), [session.id])
    }

    func testSaveRemapsRawLinksAndActionEvidenceAndPersistsAttachments() throws {
        let library = try TrailStore(root: root)
        let existing = try DemoSession.create(in: library)
        let oldEvents = try library.events(sessionID: existing.id)
        let oldActions = try library.actions(sessionID: existing.id)
        let draft = try TrailStore(root: root, inMemory: true)
        var session = Session(title: "Synthetic explicit save", metadata: ["synthetic": "true"])
        session.status = "complete"
        session.endedAt = session.startedAt + 5
        try draft.saveSession(session)
        var input = TrailEvent(sessionID: session.id, kind: "key_down", timestamp: 10, monotonicNS: 42, app: "Example App", bundleID: "test.example")
        input.key = "S"
        input.modifiers = ["command"]
        input.fields = ["origin": "synthetic", "unicode": "Résumé 🧪"]
        let savedInput = try draft.append(input)
        var context = TrailEvent(sessionID: session.id, kind: "context", timestamp: 10.4, app: input.app, bundleID: input.bundleID)
        context.relatedEventID = savedInput.id
        context.context = ElementContext(app: input.app, bundleID: input.bundleID, source: "synthetic_example")
        _ = try draft.append(context)
        let path = "sessions/\(session.id)/frames/example.jpg"
        let image = Data("synthetic screenshot bytes".utf8)
        try draft.writeAttachment(image, relativePath: path)
        var frame = TrailEvent(sessionID: session.id, kind: "screenshot", timestamp: 10.6, app: input.app, bundleID: input.bundleID)
        frame.relatedEventID = savedInput.id
        frame.attachment = path
        _ = try draft.append(frame)
        _ = try draft.append(frame) // Reused references must not attempt to overwrite the copied file.
        // Forward references are unusual but must survive promotion as faithfully as backreferences.
        var forward = TrailEvent(sessionID: session.id, kind: "context", timestamp: 10.7)
        forward.relatedEventID = 6
        _ = try draft.append(forward)
        _ = try draft.append(TrailEvent(sessionID: session.id, kind: "marker", timestamp: 11))
        try draft.rebuildActions(sessionID: session.id)
        let rawDraft = try draft.events(sessionID: session.id)
        let saved = try library.saveRecording(from: draft, sessionID: session.id)
        XCTAssertEqual(saved.id, session.id)
        XCTAssertEqual(saved.title, session.title)
        XCTAssertEqual(saved.endedAt, session.endedAt)
        XCTAssertEqual(saved.metadata, session.metadata)
        let reopened = try TrailStore(root: root, readOnly: true)
        let rawSaved = try reopened.events(sessionID: session.id)
        XCTAssertEqual(saved.eventCount, rawDraft.count)
        XCTAssertEqual(rawSaved.count, rawDraft.count)
        XCTAssertGreaterThan(rawSaved[0].id, rawDraft[0].id)
        let remapping = Dictionary(uniqueKeysWithValues: zip(rawDraft, rawSaved).map { ($0.id, $1.id) })
        for (original, persisted) in zip(rawDraft, rawSaved) {
            var expected = original
            expected.id = try XCTUnwrap(remapping[original.id])
            expected.relatedEventID = original.relatedEventID.flatMap { remapping[$0] }
            XCTAssertEqual(persisted, expected)
        }
        let action = try XCTUnwrap(reopened.actions(sessionID: session.id).first)
        XCTAssertEqual(action.firstEventID, rawSaved[0].id)
        XCTAssertEqual(action.lastEventID, rawSaved[0].id)
        XCTAssertEqual(try reopened.evidence(for: action).map(\.kind), ["key_down", "context", "screenshot", "screenshot"])
        XCTAssertEqual(try reopened.attachmentData(relativePath: path), image)
        XCTAssertEqual(try draft.events(sessionID: session.id), rawDraft)
        XCTAssertEqual(try library.events(sessionID: existing.id), oldEvents)
        XCTAssertEqual(try library.actions(sessionID: existing.id), oldActions)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertThrowsError(try library.saveRecording(from: draft, sessionID: session.id))
        XCTAssertEqual(try reopened.events(sessionID: session.id), rawSaved)
    }

    func testSaveCopiesAllEventPages() throws {
        let library = try TrailStore(root: root)
        let draft = try TrailStore(root: root, inMemory: true)
        var session = Session(title: "Synthetic paginated save")
        session.status = "complete"
        try draft.saveSession(session)
        for index in 0..<1103 {
            _ = try draft.append(TrailEvent(sessionID: session.id, kind: "marker", timestamp: Double(index)))
        }
        let saved = try library.saveRecording(from: draft, sessionID: session.id)
        XCTAssertEqual(saved.eventCount, 1103)
        XCTAssertEqual(saved.actionCount, 1103)
        XCTAssertEqual(try library.events(sessionID: session.id, afterID: 1000).count, 103)
    }

    func testFailedSaveRollsBackRowsAndNewFilesKeepsPriorSessionsAndAllowsRetry() throws {
        let library = try TrailStore(root: root)
        let prior = try DemoSession.create(in: library)
        let priorEvents = try library.events(sessionID: prior.id)
        let priorActions = try library.actions(sessionID: prior.id)
        let draft = try TrailStore(root: root, inMemory: true)
        let session = try completedSession(in: draft)
        let first = "sessions/\(session.id)/frames/first.jpg"
        let missing = "sessions/\(session.id)/frames/missing.jpg"
        let bytes = Data("synthetic bytes".utf8)
        try draft.writeAttachment(bytes, relativePath: first)
        for path in [first, missing] {
            var frame = TrailEvent(sessionID: session.id, kind: "screenshot")
            frame.attachment = path
            _ = try draft.append(frame)
        }
        let originalDraft = try draft.events(sessionID: session.id)
        XCTAssertThrowsError(try library.saveRecording(from: draft, sessionID: session.id))
        XCTAssertEqual(try library.sessions().map(\.id), [prior.id])
        XCTAssertTrue(try library.events(sessionID: session.id).isEmpty)
        XCTAssertTrue(try library.actions(sessionID: session.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/\(session.id)").path))
        XCTAssertEqual(try library.events(sessionID: prior.id), priorEvents)
        XCTAssertEqual(try library.actions(sessionID: prior.id), priorActions)
        XCTAssertEqual(try draft.events(sessionID: session.id), originalDraft)
        XCTAssertEqual(try draft.attachmentData(relativePath: first), bytes)
        try draft.writeAttachment(bytes, relativePath: missing)
        XCTAssertNoThrow(try library.saveRecording(from: draft, sessionID: session.id))
        XCTAssertEqual(try library.attachmentData(relativePath: first), bytes)
        XCTAssertEqual(try library.attachmentData(relativePath: missing), bytes)
    }

    func testSaveNeverOverwritesAnExistingAttachment() throws {
        let library = try TrailStore(root: root)
        let draft = try TrailStore(root: root, inMemory: true)
        let session = try completedSession(in: draft)
        let path = "sessions/\(session.id)/frames/existing.jpg"
        let old = Data("existing bytes".utf8)
        try library.writeAttachment(old, relativePath: path)
        try draft.writeAttachment(Data("new bytes".utf8), relativePath: path)
        var frame = TrailEvent(sessionID: session.id, kind: "screenshot")
        frame.attachment = path
        _ = try draft.append(frame)
        XCTAssertThrowsError(try library.saveRecording(from: draft, sessionID: session.id))
        XCTAssertTrue(try library.sessions().isEmpty)
        XCTAssertEqual(try library.attachmentData(relativePath: path), old)
    }

    func testOnlyFinishedDraftsCanBeSavedAndReadOnlyStoreCannotWriteAttachments() throws {
        let library = try TrailStore(root: root)
        let draft = try TrailStore(root: root, inMemory: true)
        var session = Session(title: "Synthetic lifecycle")
        for status in ["recording", "paused", "unknown"] {
            session.status = status
            try draft.saveSession(session)
            XCTAssertThrowsError(try library.saveRecording(from: draft, sessionID: session.id))
        }
        session.status = "interrupted"
        try draft.saveSession(session)
        XCTAssertEqual(try library.saveRecording(from: draft, sessionID: session.id).status, "interrupted")
        XCTAssertThrowsError(try draft.saveRecording(from: draft, sessionID: session.id))
        XCTAssertThrowsError(try library.saveRecording(from: library, sessionID: session.id))
        let reader = try TrailStore(root: root, readOnly: true)
        XCTAssertThrowsError(try reader.writeAttachment(Data(), relativePath: "sessions/example/image.jpg"))
    }

    func testAttachmentPathsRejectTraversalAbsoluteAndSymlinkTargets() throws {
        let library = try TrailStore(root: root)
        let draft = try TrailStore(root: root, inMemory: true)
        for store in [library, draft] {
            for path in ["", "../outside.jpg", "/outside.jpg", "sessions/../../outside.jpg", "sessions/./frame.jpg", "sessions//frame.jpg", "sessions\\outside.jpg", "sessions/evil\0.jpg", "library.sqlite"] {
                XCTAssertThrowsError(try store.writeAttachment(Data(), relativePath: path), path)
                XCTAssertThrowsError(try store.attachmentData(relativePath: path), path)
            }
        }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        XCTAssertThrowsError(try library.writeAttachment(Data(), relativePath: "linked/image.jpg"))
        XCTAssertThrowsError(try library.attachmentData(relativePath: "linked/image.jpg"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testScreenshotBudgetRejectsGrowthButDraftCanStillFinish() throws {
        let draft = try TrailStore(root: root, inMemory: true)
        var session = Session(title: "Synthetic memory budget")
        try draft.saveSession(session)
        let path = "sessions/\(session.id)/frames/budget.jpg"
        try draft.writeAttachment(Data(count: TrailStore.draftAttachmentLimitBytes), relativePath: path)
        XCTAssertThrowsError(try draft.writeAttachment(Data([1]), relativePath: "sessions/\(session.id)/frames/extra.jpg"))
        XCTAssertEqual(try draft.attachmentData(relativePath: path).count, TrailStore.draftAttachmentLimitBytes)
        session.status = "interrupted"
        try draft.saveSession(session)
        XCTAssertEqual(try draft.session(session.id).status, "interrupted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func completedSession(in store: TrailStore) throws -> Session {
        var session = Session(title: "Synthetic finished draft", metadata: ["synthetic": "true"])
        session.status = "complete"
        session.endedAt = session.startedAt + 1
        try store.saveSession(session)
        _ = try store.append(TrailEvent(sessionID: session.id, kind: "marker"))
        return session
    }
}
