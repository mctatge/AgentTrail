import Foundation
import CSQLite
import Darwin

public final class TrailStore {
    public let root: URL
    public let isInMemory: Bool
    private let readOnly: Bool
    private var attachments: [String: Data] = [:]
    private var attachmentBytes = 0
    // Limits apply per unsaved draft, independent of the durable library.
    public static let draftDatabaseLimitBytes = 128 * 1024 * 1024
    public static let draftAttachmentLimitBytes = 128 * 1024 * 1024
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentTrail")
    }

    public init(root: URL = TrailStore.defaultRoot, readOnly: Bool = false, inMemory: Bool = false) throws {
        guard !(readOnly && inMemory) else { throw TrailError.message("An unsaved recording cannot be opened read-only.") }
        self.root = root
        self.isInMemory = inMemory
        self.readOnly = readOnly
        if !readOnly && !inMemory {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let path = inMemory ? ":memory:" : root.appendingPathComponent("library.sqlite").path
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &database, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let failure = error()
            sqlite3_close(database)
            database = nil
            throw failure
        }
        sqlite3_busy_timeout(database, 5000)
        if !readOnly {
            if inMemory {
                try execute("PRAGMA page_size=4096; PRAGMA max_page_count=\(Self.draftDatabaseLimitBytes / 4096); PRAGMA journal_mode=MEMORY; PRAGMA temp_store=MEMORY; PRAGMA foreign_keys=ON;")
            } else {
                try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, started REAL NOT NULL, json TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), timestamp REAL NOT NULL, kind TEXT NOT NULL, json TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS events_session_id ON events(session_id, id);
                CREATE INDEX IF NOT EXISTS events_session_time ON events(session_id, timestamp);
                CREATE TABLE IF NOT EXISTS actions (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), timestamp REAL NOT NULL, kind TEXT NOT NULL, search_text TEXT NOT NULL, json TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS actions_session_id ON actions(session_id, id);
                PRAGMA user_version=1;
                """)
            if !inMemory { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        }
    }

    deinit { sqlite3_close(database) }

    public func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func saveSession(_ session: Session) throws {
        try withStatement("INSERT INTO sessions(id, started, json) VALUES(?, ?, ?) ON CONFLICT(id) DO UPDATE SET json=excluded.json") { statement in
            bind(session.id, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, session.startedAt)
            bind(try TrailJSON.string(session), to: statement, at: 3)
            try step(statement)
        }
    }

    public func sessions() throws -> [Session] {
        var results: [Session] = []
        try withStatement("SELECT json, (SELECT COUNT(*) FROM events WHERE session_id=sessions.id), (SELECT COUNT(*) FROM actions WHERE session_id=sessions.id) FROM sessions ORDER BY started DESC") { statement in
            while try hasRow(statement) {
                var session: Session = try decode(statement, column: 0)
                session.eventCount = Int(sqlite3_column_int64(statement, 1))
                session.actionCount = Int(sqlite3_column_int64(statement, 2))
                results.append(session)
            }
        }
        return results
    }

    public func session(_ sessionID: String) throws -> Session {
        guard let session = try sessions().first(where: { $0.id == sessionID }) else {
            throw TrailError.message("Session not found: \(sessionID)")
        }
        return session
    }

    public func append(_ event: TrailEvent) throws -> TrailEvent {
        lock.lock()
        defer { lock.unlock() }
        var saved = event
        let json = try TrailJSON.string(event)
        try checkDraftCapacity(for: json)
        try withStatement("INSERT INTO events(session_id, timestamp, kind, json) VALUES(?, ?, ?, ?)") { statement in
            bind(event.sessionID, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, event.timestamp)
            bind(event.kind, to: statement, at: 3)
            bind(json, to: statement, at: 4)
            try step(statement)
            saved.id = sqlite3_last_insert_rowid(database)
        }
        return saved
    }

    public func append(_ action: TrailAction) throws {
        lock.lock()
        defer { lock.unlock() }
        let json = try TrailJSON.string(action)
        try checkDraftCapacity(for: json)
        try withStatement("INSERT INTO actions(session_id, timestamp, kind, search_text, json) VALUES(?, ?, ?, ?, ?)") { statement in
            bind(action.sessionID, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, action.startedAt)
            bind(action.kind, to: statement, at: 3)
            bind([action.summary, action.app, action.context?.description ?? "", action.inference ?? ""].joined(separator: " "), to: statement, at: 4)
            bind(json, to: statement, at: 5)
            try step(statement)
        }
    }

    public func actions(sessionID: String, query: String = "", afterID: Int64 = 0, limit: Int = 500) throws -> [TrailAction] {
        var results: [TrailAction] = []
        try withStatement("SELECT id, json FROM actions WHERE session_id=? AND id>? AND instr(lower(search_text), lower(?))>0 ORDER BY id LIMIT ?") { statement in
            bind(sessionID, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, afterID)
            bind(query, to: statement, at: 3)
            sqlite3_bind_int(statement, 4, Int32(max(1, min(limit, 1000))))
            while try hasRow(statement) {
                var action: TrailAction = try decode(statement, column: 1)
                action.id = sqlite3_column_int64(statement, 0)
                if action.kind == "gap" { action.summary = CaptureGap.normalizeLegacySummary(action.summary) }
                results.append(action)
            }
        }
        return results
    }

    public func events(sessionID: String, afterID: Int64 = 0, throughID: Int64 = Int64.max, kind: String? = nil, limit: Int = 500) throws -> [TrailEvent] {
        var results: [TrailEvent] = []
        try withStatement("SELECT id, json FROM events WHERE session_id=? AND id>? AND id<=? AND (?='' OR kind=?) ORDER BY id LIMIT ?") { statement in
            bind(sessionID, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, afterID)
            sqlite3_bind_int64(statement, 3, throughID)
            bind(kind ?? "", to: statement, at: 4)
            bind(kind ?? "", to: statement, at: 5)
            sqlite3_bind_int(statement, 6, Int32(max(1, min(limit, 1000))))
            while try hasRow(statement) {
                var event: TrailEvent = try decode(statement, column: 1)
                event.id = sqlite3_column_int64(statement, 0)
                results.append(event)
            }
        }
        return results
    }

    public func rebuildActions(sessionID: String) throws {
        try transaction { try replaceActions(sessionID: sessionID) }
    }

    private func replaceActions(sessionID: String) throws {
        try withStatement("DELETE FROM actions WHERE session_id=?") { statement in
            bind(sessionID, to: statement, at: 1)
            try step(statement)
        }
        let builder = ActionBuilder()
        var cursor: Int64 = 0
        while true {
            let batch = try events(sessionID: sessionID, afterID: cursor, limit: 1000)
            if batch.isEmpty { break }
            for event in batch {
                for action in builder.consume(event) { try append(action) }
            }
            cursor = batch.last!.id
        }
        for action in builder.flush() { try append(action) }
    }

    /// Promotes one finished draft. No draft data is mutated, even if saving fails.
    @discardableResult
    public func saveRecording(from draft: TrailStore, sessionID: String) throws -> Session {
        guard !isInMemory && !readOnly && draft.isInMemory else {
            throw TrailError.message("Save requires an unsaved recording and a writable recording library.")
        }
        draft.lock.lock()
        defer { draft.lock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        let session = try draft.session(sessionID)
        guard session.status == "complete" || session.status == "interrupted" else {
            throw TrailError.message("Stop the recording before saving it.")
        }
        var savedSession = session
        var createdAttachments: [URL] = []
        var createdDirectories: [URL] = []
        do {
            try transaction {
                guard !(try sessions()).contains(where: { $0.id == sessionID }) else {
                    throw TrailError.message("This recording is already saved.")
                }
                try saveSession(session)
                var savedIDs: [Int64: Int64] = [:]
                var copiedAttachments = Set<String>()
                var cursor: Int64 = 0
                while true {
                    let batch = try draft.events(sessionID: sessionID, afterID: cursor, limit: 1000)
                    if batch.isEmpty { break }
                    for event in batch {
                        if let path = event.attachment, copiedAttachments.insert(path).inserted {
                            let data = try draft.attachmentData(relativePath: path)
                            let url = try writeAttachmentFile(data, relativePath: path, createdDirectories: &createdDirectories)
                            createdAttachments.append(url)
                        }
                        var copy = event
                        copy.id = 0
                        savedIDs[event.id] = try append(copy).id
                    }
                    cursor = batch.last!.id
                }
                // A second pass also preserves links to later events, without assuming insertion order.
                cursor = 0
                while true {
                    let batch = try draft.events(sessionID: sessionID, afterID: cursor, limit: 1000)
                    if batch.isEmpty { break }
                    for var event in batch {
                        guard let relatedID = event.relatedEventID else { continue }
                        guard let mappedID = savedIDs[event.id], let mappedRelatedID = savedIDs[relatedID] else {
                            throw TrailError.message("The recording contains a reference to missing event evidence.")
                        }
                        event.id = mappedID
                        event.relatedEventID = mappedRelatedID
                        try withStatement("UPDATE events SET json=? WHERE id=? AND session_id=?") { statement in
                            bind(try TrailJSON.string(event), to: statement, at: 1)
                            sqlite3_bind_int64(statement, 2, mappedID)
                            bind(sessionID, to: statement, at: 3)
                            try step(statement)
                        }
                    }
                    cursor = batch.last!.id
                }
                try replaceActions(sessionID: sessionID)
                savedSession = try self.session(sessionID)
            }
        } catch {
            // Remove only files created by this attempted save, never preexisting library content.
            for url in createdAttachments.reversed() { try? FileManager.default.removeItem(at: url) }
            removeEmptyDirectories(createdDirectories)
            throw error
        }
        return savedSession
    }

    /// Draft attachments remain in memory. Persistent attachments are new, owner-only files.
    public func writeAttachment(_ data: Data, relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !readOnly else { throw TrailError.message("The recording library is read-only.") }
        _ = try attachmentURL(relativePath: relativePath)
        if isInMemory {
            guard attachments[relativePath] == nil else { throw TrailError.message("This recording attachment already exists.") }
            guard data.count <= Self.draftAttachmentLimitBytes - attachmentBytes else {
                throw TrailError.message("This unsaved recording has reached its screenshot memory limit. Stop and save or discard it before recording more.")
            }
            attachments[relativePath] = data
            attachmentBytes += data.count
        } else {
            var createdDirectories: [URL] = []
            do {
                _ = try writeAttachmentFile(data, relativePath: relativePath, createdDirectories: &createdDirectories)
            } catch {
                removeEmptyDirectories(createdDirectories)
                throw error
            }
        }
    }

    public func attachmentData(relativePath: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let url = try attachmentURL(relativePath: relativePath)
        if isInMemory {
            guard let data = attachments[relativePath] else { throw TrailError.message("Recording attachment not found.") }
            return data
        }
        return try Data(contentsOf: url)
    }

    private func attachmentURL(relativePath: String) throws -> URL {
        let components = relativePath.components(separatedBy: "/")
        guard !relativePath.contains("\\"), !relativePath.contains("\0"),
              components.count > 1, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw TrailError.message("Invalid recording attachment path.")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var target = base
        for component in components {
            target.appendPathComponent(component)
            if !isInMemory,
               let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw TrailError.message("Recording attachments cannot use symbolic links.")
            }
        }
        guard target.standardizedFileURL.path.hasPrefix(base.path + "/") else {
            throw TrailError.message("Invalid recording attachment path.")
        }
        return target
    }

    private func writeAttachmentFile(_ data: Data, relativePath: String, createdDirectories: inout [URL]) throws -> URL {
        let url = try attachmentURL(relativePath: relativePath)
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var directory = base
        for component in relativePath.components(separatedBy: "/").dropLast() {
            directory.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw TrailError.message("The attachment folder is unavailable.") }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                createdDirectories.append(directory)
            }
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw TrailError.message("Could not create a new recording attachment: \(String(cString: strerror(errno)))") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
            return url
        } catch {
            try? file.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func removeEmptyDirectories(_ directories: [URL]) {
        for directory in directories.reversed() {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path), entries.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    public func cursorPage(sessionID: String, afterID: Int64 = 0, throughID: Int64 = Int64.max, limit: Int = 20000) throws -> CursorPage {
        let pageSize = max(1, min(limit, 20000))
        var events: [TrailEvent] = []
        try withStatement("SELECT id, json FROM events WHERE session_id=? AND id>? AND id<=? AND kind IN ('mouse_move','mouse_drag','mouse_down','mouse_up','scroll','gap','pause','resume','app_focus','session_start','session_end') ORDER BY id LIMIT ?") { statement in
            bind(sessionID, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, afterID)
            sqlite3_bind_int64(statement, 3, throughID)
            sqlite3_bind_int(statement, 4, Int32(pageSize + 1))
            while try hasRow(statement) {
                var event: TrailEvent = try decode(statement, column: 1)
                event.id = sqlite3_column_int64(statement, 0)
                events.append(event)
            }
        }
        let hasMore = events.count > pageSize
        if hasMore { events.removeLast() }
        return CursorPage(events: events, hasMore: hasMore)
    }

    public func evidence(for action: TrailAction, limit: Int = 200) throws -> [TrailEvent] {
        var results: [TrailEvent] = []
        try withStatement("SELECT id, json FROM events WHERE session_id=? AND ((id>=? AND id<=?) OR (json_extract(json, '$.relatedEventID')>=? AND json_extract(json, '$.relatedEventID')<=?)) ORDER BY id LIMIT ?") { statement in
            bind(action.sessionID, to: statement, at: 1)
            sqlite3_bind_int64(statement, 2, action.firstEventID)
            sqlite3_bind_int64(statement, 3, action.lastEventID)
            sqlite3_bind_int64(statement, 4, action.firstEventID)
            sqlite3_bind_int64(statement, 5, action.lastEventID)
            sqlite3_bind_int(statement, 6, Int32(max(1, min(limit, 1000))))
            while try hasRow(statement) {
                var event: TrailEvent = try decode(statement, column: 1)
                event.id = sqlite3_column_int64(statement, 0)
                results.append(event)
            }
        }
        return results
    }

    public func recoverInterruptedSessions() throws {
        for var session in try sessions() where session.status == "recording" || session.status == "paused" {
            try rebuildActions(sessionID: session.id)
            session.status = "interrupted"
            try saveSession(session)
        }
    }

    private func checkDraftCapacity(for json: String) throws {
        guard isInMemory else { return }
        var pages: Int64 = 0
        try withStatement("PRAGMA page_count") { statement in
            if try hasRow(statement) { pages = sqlite3_column_int64(statement, 0) }
        }
        // Leave room to mark a stopped draft interrupted after hitting the capture budget.
        // Estimate generously for row/index overhead; SQLite also enforces the hard cap.
        let remaining = Int64(Self.draftDatabaseLimitBytes - 8 * 1024 * 1024) - pages * 4096 - 40960
        guard remaining > 0 && Int64(json.utf8.count) <= remaining / 3 else {
            throw TrailError.message("This unsaved recording has reached its memory limit. Stop and save or discard it before recording more.")
        }
    }

    private func error() -> TrailError {
        if isInMemory && sqlite3_errcode(database) == SQLITE_FULL {
            return .message("This unsaved recording has reached its memory limit. Stop and save or discard it before recording more.")
        }
        return .message(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open recording library")
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func withStatement<Value>(_ sql: String, _ body: (OpaquePointer) throws -> Value) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func hasRow(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw error() }
        return result == SQLITE_ROW
    }

    private func decode<Value: Decodable>(_ statement: OpaquePointer, column: Int32) throws -> Value {
        guard let bytes = sqlite3_column_text(statement, column) else { throw TrailError.message("Missing record") }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
