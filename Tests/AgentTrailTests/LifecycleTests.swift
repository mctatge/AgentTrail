import AppKit
import XCTest
import TrailCore
@testable import AgentTrail

final class LifecycleTests: XCTestCase {
    func testReviewAndSettingsSheetsDoNotVetoQuit() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertTrue(window.preventsApplicationTerminationWhenModal)
        window.contentView = SheetTerminationView()
        XCTAssertFalse(window.preventsApplicationTerminationWhenModal)
    }

    func testTimerContinuesInTerminationModalMode() {
        XCTAssertTrue(Thread.isMainThread)
        var fired = false
        let timer = AppRunLoopTimer.schedule(interval: 0.01, repeats: false) { _ in fired = true }
        defer { timer.invalidate() }
        let deadline = Date().addingTimeInterval(0.25)
        while !fired && Date() < deadline { RunLoop.main.run(mode: .modalPanel, before: deadline) }
        XCTAssertTrue(fired, "Permission refresh and Quit must not depend on the default run-loop mode")
    }

    func testTimerStillRunsNormallyAndCanBeCancelled() {
        var count = 0
        let timer = AppRunLoopTimer.schedule(interval: 0.01) { _ in count += 1 }
        let deadline = Date().addingTimeInterval(0.25)
        while count == 0 && Date() < deadline { RunLoop.main.run(mode: .default, before: deadline) }
        timer.invalidate()
        XCTAssertGreaterThan(count, 0)
        XCTAssertFalse(timer.isValid)
    }

    func testCaptureChoicesPersistWithoutStartingRecording() throws {
        let suite = "agenttrail-preferences-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrailStore(root: root)
        let model = try RecordingModel(store: store, captureDefaults: defaults)
        XCTAssertEqual(model.options, CaptureOptions())
        model.options.captureText = true
        model.options.captureClipboard = true
        model.options.captureScreenshots = true
        model.options.excelContext = true
        model.options.allowedBundleIDs = ["com.example.demo"]
        let restored = try RecordingModel(store: store, captureDefaults: defaults)
        XCTAssertEqual(restored.options, model.options)
        XCTAssertNil(model.currentSession)
        XCTAssertNil(restored.currentSession)
        XCTAssertTrue(try store.sessions().isEmpty)
        model.options.captureText = false
        let saved = try JSONDecoder().decode(CaptureOptions.self, from: XCTUnwrap(defaults.data(forKey: "captureOptions")))
        XCTAssertFalse(saved.captureText)
        XCTAssertTrue(saved.captureScreenshots)
    }
}
