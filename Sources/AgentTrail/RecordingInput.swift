import AppKit
import TrailCore

/// The recorder lifecycle can be exercised without capturing real computer input.
protocol RecordingInput: AnyObject {
    var onEvent: ((TrailEvent) -> Void)? { get set }
    var sessionID: String { get set }
    var includeText: Bool { get set }
    func start() throws
    func stop(deliverPending: Bool)
    func togglePause()
    func drain()
    func updateForeground(_ app: NSRunningApplication?)
}

extension InputCapture: RecordingInput {}
