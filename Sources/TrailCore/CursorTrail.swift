import Foundation

public struct CursorSample: Identifiable, Equatable {
    public let id: Int64
    public let timestamp: Double
    public let elapsed: Double
    public let x: Double
    public let y: Double
    public let kind: String
    public let button: Int?
    public let app: String
    public let startsSegment: Bool

    public var isDrag: Bool { kind == "mouse_drag" }
    public var isClick: Bool { kind == "mouse_down" }
}

public struct CursorBounds: Equatable {
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct CursorProjection {
    public let scale: Double
    public let offsetX: Double
    public let offsetY: Double
    public let bounds: CursorBounds

    public init(bounds: CursorBounds, width: Double, height: Double, padding: Double = 28) {
        self.bounds = bounds
        let availableWidth = max(1, width - padding * 2)
        let availableHeight = max(1, height - padding * 2)
        scale = min(availableWidth / bounds.width, availableHeight / bounds.height)
        offsetX = (width - bounds.width * scale) / 2
        offsetY = (height - bounds.height * scale) / 2
    }

    public func project(x: Double, y: Double) -> (x: Double, y: Double) {
        ((x - bounds.minX) * scale + offsetX, (y - bounds.minY) * scale + offsetY)
    }
}

public struct CursorTrail {
    public let samples: [CursorSample]
    public let bounds: CursorBounds
    public let breakCount: Int
    public var duration: Double { samples.last?.elapsed ?? 0 }
    public var clickCount: Int { samples.filter(\.isClick).count }
    public var dragCount: Int { samples.filter(\.isDrag).count }

    public init(events: [TrailEvent]) {
        var samples: [CursorSample] = []
        var shouldBreak = true
        var previousBundle: String?
        var previousSession: String?
        var previousMonotonic: UInt64?
        var previousTimestamp: Double?
        var elapsed = 0.0
        var breaks = 0
        let discontinuities: Set<String> = ["gap", "pause", "resume", "app_focus", "session_start", "session_end"]
        let pointerKinds: Set<String> = ["mouse_move", "mouse_drag", "mouse_down", "mouse_up", "scroll"]
        for event in events {
            if discontinuities.contains(event.kind) { shouldBreak = true; continue }
            guard pointerKinds.contains(event.kind) else { continue }
            guard let horizontal = event.x, let vertical = event.y,
                  horizontal.isFinite, vertical.isFinite, event.timestamp.isFinite,
                  abs(horizontal) < 1_000_000_000, abs(vertical) < 1_000_000_000 else {
                shouldBreak = true
                continue
            }
            var delta = 0.0
            if let previousTimestamp {
                if let previousMonotonic, event.monotonicNS >= previousMonotonic, event.sessionID == previousSession {
                    delta = Double(event.monotonicNS - previousMonotonic) / 1_000_000_000
                } else { delta = max(0, event.timestamp - previousTimestamp) }
                elapsed += delta
            }
            let startsSegment = shouldBreak || event.bundleID != previousBundle || event.sessionID != previousSession || delta > 2
            if startsSegment, !samples.isEmpty { breaks += 1 }
            samples.append(CursorSample(id: event.id, timestamp: event.timestamp, elapsed: elapsed,
                                        x: horizontal, y: vertical, kind: event.kind, button: event.button,
                                        app: event.app, startsSegment: startsSegment))
            shouldBreak = false
            previousBundle = event.bundleID
            previousSession = event.sessionID
            previousMonotonic = event.monotonicNS
            previousTimestamp = event.timestamp
        }
        self.samples = samples
        breakCount = breaks
        let minX = samples.map(\.x).min() ?? 0
        let maxX = samples.map(\.x).max() ?? 0
        let minY = samples.map(\.y).min() ?? 0
        let maxY = samples.map(\.y).max() ?? 0
        let width = max(80, maxX - minX)
        let height = max(80, maxY - minY)
        bounds = CursorBounds(minX: (minX + maxX - width) / 2, minY: (minY + maxY - height) / 2, width: width, height: height)
    }

    public func sampleIndex(at elapsed: Double) -> Int? {
        guard let first = samples.first, elapsed.isFinite, elapsed >= first.elapsed else { return nil }
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].elapsed <= elapsed { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, lower - 1)
    }
}

public struct CursorPage {
    public let events: [TrailEvent]
    public let hasMore: Bool
    public let lastEventID: Int64?

    public init(events: [TrailEvent], hasMore: Bool) {
        self.events = events
        self.hasMore = hasMore
        lastEventID = events.last?.id
    }
}
