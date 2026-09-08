import Foundation
import TrailCore

struct CaptureForeground {
    var app = "Unknown application"
    var bundleID = ""
    var observedAt = Date().timeIntervalSince1970
}

final class InputEventBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var events: [TrailEvent] = []
    private var overflow: TrailEvent?
    private var paused = false
    private var foreground = CaptureForeground()
    private var lastGap = ""

    init(capacity: Int = 8000) { self.capacity = max(1, capacity) }

    func updateForeground(_ value: CaptureForeground) {
        lock.lock()
        defer { lock.unlock() }
        foreground = value
    }

    func append(_ event: TrailEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !paused || event.kind == "marker_shortcut" else { return }
        if event.kind == "gap" {
            let reason = event.fields["reason"] ?? ""
            guard lastGap != reason else { return }
            lastGap = reason
        } else { lastGap = "" }
        var captured = event
        captured.app = foreground.app
        captured.bundleID = foreground.bundleID
        captured.fields["foreground_observed_at"] = String(foreground.observedAt)
        captured.fields["app_attribution"] = "last_observed_foreground"
        guard events.count < capacity else {
            if overflow == nil {
                var gap = TrailEvent(sessionID: event.sessionID, kind: "gap", timestamp: event.timestamp, monotonicNS: event.monotonicNS)
                gap.fields["reason"] = "Input delivery buffer capacity reached; some events were dropped"
                gap.fields["dropped_count"] = "0"
                overflow = gap
            }
            let dropped = (Int(overflow?.fields["dropped_count"] ?? "0") ?? 0) + 1
            overflow?.fields["dropped_count"] = String(dropped)
            overflow?.fields["last_dropped_at"] = String(event.timestamp)
            return
        }
        events.append(captured)
    }

    func togglePause(sessionID: String, timestamp: Double = Date().timeIntervalSince1970, monotonicNS: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        defer { lock.unlock() }
        appendOverflow()
        paused.toggle()
        lastGap = ""
        events.append(TrailEvent(sessionID: sessionID, kind: paused ? "pause" : "resume", timestamp: timestamp, monotonicNS: monotonicNS))
    }

    func takeAll() -> [TrailEvent] {
        lock.lock()
        defer { lock.unlock() }
        appendOverflow()
        let batch = events
        events.removeAll(keepingCapacity: true)
        return batch
    }

    private func appendOverflow() {
        if let overflow { events.append(overflow); self.overflow = nil }
    }
}
