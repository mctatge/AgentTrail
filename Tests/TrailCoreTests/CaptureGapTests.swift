import XCTest
@testable import TrailCore

final class CaptureGapTests: XCTestCase {
    func testIntentionalExclusionsAreNotPresentedAsFailures() {
        for reason in ["Recorder controls excluded", "Application excluded by capture settings", "Secure input is active", "Password field focused"] {
            var event = TrailEvent(sessionID: "test", kind: "gap")
            event.fields["reason"] = reason
            let action = ActionBuilder().consume(event).first!
            XCTAssertTrue(action.summary.hasPrefix("Not recorded"))
            XCTAssertEqual(action.kind, "gap")
            XCTAssertEqual(CaptureGap.normalizeLegacySummary("Capture gap · \(reason)"), action.summary)
        }
    }

    func testActualCaptureFailureRemainsVisible() {
        let reason = "Input listener timed out; re-enabled. Some inputs may be missing."
        XCTAssertFalse(CaptureGap.isIntentional(reason))
        XCTAssertEqual(CaptureGap.summary(reason), "Capture gap · \(reason)")
        XCTAssertEqual(CaptureGap.normalizeLegacySummary("Bookmark · review this"), "Bookmark · review this")
    }

    func testLegacyDisplayNormalizationDoesNotRewriteRawEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrailStore(root: root)
        let session = Session(title: "Legacy exclusion")
        try store.saveSession(session)
        var event = TrailEvent(sessionID: session.id, kind: "gap")
        event.fields["reason"] = "Recorder controls excluded"
        let saved = try store.append(event)
        try store.append(TrailAction(event: saved, kind: "gap", summary: "Capture gap · Recorder controls excluded"))
        XCTAssertEqual(try store.actions(sessionID: session.id).first?.summary, "Not recorded · AgentTrail controls (intentional)")
        XCTAssertEqual(try store.events(sessionID: session.id).first, saved)
    }
}
