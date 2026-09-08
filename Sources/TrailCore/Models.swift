import Foundation

public struct CaptureOptions: Codable, Equatable {
    public var captureText = false
    public var captureClipboard = false
    public var captureScreenshots = false
    public var excelContext = false
    public var excludedBundleIDs = ["com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess"]
    public var allowedBundleIDs: [String] = []
    public init() {}

    public func allows(_ bundleID: String) -> Bool {
        !excludedBundleIDs.contains(bundleID) && (allowedBundleIDs.isEmpty || allowedBundleIDs.contains(bundleID))
    }
}

public struct Session: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var startedAt: Double
    public var endedAt: Double?
    public var status: String
    public var options: CaptureOptions
    public var eventCount: Int
    public var actionCount: Int
    public var metadata: [String: String]

    public init(title: String, options: CaptureOptions = CaptureOptions(), metadata: [String: String] = [:]) {
        id = UUID().uuidString.lowercased()
        self.title = title
        startedAt = Date().timeIntervalSince1970
        status = "recording"
        self.options = options
        eventCount = 0
        actionCount = 0
        self.metadata = metadata
    }
}

public struct ElementContext: Codable, Equatable {
    public var observedAt: Double
    public var app: String
    public var bundleID: String
    public var pid: Int32
    public var window: String?
    public var role: String?
    public var label: String?
    public var value: String?
    public var bounds: [Double]?
    public var selection: String?
    public var worksheet: String?
    public var workbook: String?
    public var source: String
    public var secure: Bool
    public var error: String?

    public init(app: String, bundleID: String, pid: Int32 = 0, source: String = "accessibility") {
        observedAt = Date().timeIntervalSince1970
        self.app = app
        self.bundleID = bundleID
        self.pid = pid
        self.source = source
        secure = false
    }

    public var description: String {
        [app, window, role, label, selection, worksheet].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public struct TrailEvent: Codable, Identifiable, Equatable {
    public var id: Int64
    public var sessionID: String
    public var timestamp: Double
    public var monotonicNS: UInt64
    public var kind: String
    public var app: String
    public var bundleID: String
    public var x: Double?
    public var y: Double?
    public var deltaX: Double?
    public var deltaY: Double?
    public var button: Int?
    public var keyCode: Int?
    public var key: String?
    public var modifiers: [String]
    public var text: String?
    public var context: ElementContext?
    public var relatedEventID: Int64?
    public var attachment: String?
    public var fields: [String: String]

    public init(sessionID: String, kind: String, timestamp: Double = Date().timeIntervalSince1970,
                monotonicNS: UInt64 = DispatchTime.now().uptimeNanoseconds, app: String = "", bundleID: String = "") {
        id = 0
        self.sessionID = sessionID
        self.kind = kind
        self.timestamp = timestamp
        self.monotonicNS = monotonicNS
        self.app = app
        self.bundleID = bundleID
        modifiers = []
        fields = [:]
    }
}

public struct TrailAction: Codable, Identifiable, Equatable {
    public var id: Int64
    public var sessionID: String
    public var startedAt: Double
    public var endedAt: Double
    public var kind: String
    public var summary: String
    public var app: String
    public var bundleID: String
    public var firstEventID: Int64
    public var lastEventID: Int64
    public var eventCount: Int
    public var context: ElementContext?
    public var inference: String?

    public init(event: TrailEvent, kind: String, summary: String) {
        id = 0
        sessionID = event.sessionID
        startedAt = event.timestamp
        endedAt = event.timestamp
        self.kind = kind
        self.summary = summary
        app = event.app
        bundleID = event.bundleID
        firstEventID = event.id
        lastEventID = event.id
        eventCount = 1
        context = event.context
    }
}

public enum TrailJSON {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func string<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }
}

public enum TrailError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
