import AppKit
import ApplicationServices
import Carbon
import Combine
import TrailCore

final class RecordingModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selectedSessionID: String? { didSet { if oldValue != selectedSessionID { selectedAction = nil; actionLimit = 500; refresh() } } }
    @Published var actions: [TrailAction] = []
    @Published var selectedAction: TrailAction?
    @Published var query = "" { didSet { actionLimit = 500; refresh() } }
    @Published var title = ""
    @Published var options = CaptureOptions() {
        didSet {
            if let data = try? TrailJSON.encode(options) { captureDefaults.set(data, forKey: "captureOptions") }
        }
    }
    @Published var currentSession: Session?
    @Published var isPaused = false
    @Published var isFinalizing = false
    @Published var errorMessage: String?
    @Published var notice = "Ready when you are."
    @Published var hasInputPermission = CGPreflightListenEventAccess()
    @Published var hasAccessibilityPermission = AXIsProcessTrusted()
    @Published var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @Published var markerText = ""
    @Published var elapsed: TimeInterval = 0
    @Published var suppression: String?
    let store: TrailStore
    private let captureDefaults: UserDefaults
    private let input = InputCapture()
    private let contextResolver = ContextResolver()
    private let excelResolver = ExcelResolver()
    private let screenshots = ScreenshotCapture()
    private let writerQueue = DispatchQueue(label: "agenttrail.writer", qos: .utility)
    private var builder = ActionBuilder()
    private var pending: [TrailEvent] = []
    private var outstandingEvents = 0
    private var failedSessionIDs: Set<String> = []
    private var cachedContext: ElementContext?
    private var cachedExcel: ElementContext?
    private var flushTimer: Timer?
    private var contextTimer: Timer?
    private var refreshTimer: Timer?
    private var lastBundleID = ""
    private var lastGap = ""
    private var clipboardChange = NSPasteboard.general.changeCount
    private var refreshing = false
    private var actionLimit = 500
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    init(store: TrailStore, captureDefaults: UserDefaults = .standard) throws {
        self.store = store
        self.captureDefaults = captureDefaults
        try store.recoverInterruptedSessions()
        if let data = captureDefaults.data(forKey: "captureOptions"), let saved = try? JSONDecoder().decode(CaptureOptions.self, from: data) { options = saved }
        input.onEvent = { [weak self] in self?.receive($0) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.input.drain()
            self.input.updateForeground(app)
            self.trackFocus(app)
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.currentSession != nil, !self.isPaused else { return }
            self.gap("System sleep; recording paused until manually resumed")
            self.togglePause()
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.currentSession != nil, !self.isPaused else { return }
            self.gap("Login session became inactive; recording paused")
            self.togglePause()
        })
        refreshTimer = AppRunLoopTimer.schedule(interval: 1) { [weak self] _ in
            guard let self else { return }
            self.refreshPermissions()
            if let session = self.currentSession { self.elapsed = Date().timeIntervalSince1970 - session.startedAt }
            self.refresh()
        }
        refresh()
    }

    deinit {
        refreshTimer?.invalidate()
        flushTimer?.invalidate()
        contextTimer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func refreshPermissions() {
        hasInputPermission = CGPreflightListenEventAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasScreenPermission = CGPreflightScreenCaptureAccess()
    }

    var isRecording: Bool { currentSession != nil && !isFinalizing }
    var selectedSession: Session? { sessions.first { $0.id == selectedSessionID } }
    var status: String { isFinalizing ? "Saving" : isRecording ? (isPaused ? "Paused" : suppression == nil ? "Recording" : "Protected") : "Ready" }

    func start() {
        guard currentSession == nil, !isFinalizing else { return }
        do {
            let sessionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displays = NSScreen.screens.map { "\($0.localizedName):\($0.frame),scale=\($0.backingScaleFactor)" }.joined(separator: "; ")
            let session = Session(title: sessionTitle.isEmpty ? "Demonstration · \(Date().formatted(date: .abbreviated, time: .shortened))" : sessionTitle,
                                  options: options, metadata: ["schema_version": "1", "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                                             "coordinates": "macOS global display points, main-display top-left origin for CG events",
                                                             "displays_appkit": displays, "keyboard_labels": "physical ANSI labels; raw key codes retained",
                                                             "version": "0.2.2", "capture": "dedicated-thread listen-only annotated CGEventTap; AX sampled; no replay"])
            input.sessionID = session.id
            input.includeText = options.captureText
            try input.start()
            do { try store.saveSession(session) } catch { input.stop(); throw error }
            currentSession = session
            isPaused = false
            elapsed = 0
            generation += 1
            builder = ActionBuilder()
            cachedContext = nil
            cachedExcel = nil
            lastBundleID = ""
            lastGap = ""
            suppression = nil
            clipboardChange = NSPasteboard.general.changeCount
            excelResolver.reset()
            selectedSessionID = session.id
            pending.append(TrailEvent(sessionID: session.id, kind: "session_start"))
            let flushTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.flush() }
            let contextTimer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in self?.sampleContext() }
            RunLoop.main.add(flushTimer, forMode: .common)
            RunLoop.main.add(contextTimer, forMode: .common)
            self.flushTimer = flushTimer
            self.contextTimer = contextTimer
            notice = "Recording your demonstration. ⌃⌥⌘P pauses; ⌃⌥⌘M adds a bookmark."
            errorMessage = nil
            flush()
        } catch { errorMessage = error.localizedDescription }
    }

    func stop() {
        guard var session = currentSession, !isFinalizing else { return }
        input.stop()
        flushTimer?.invalidate()
        contextTimer?.invalidate()
        generation += 1
        pending.append(TrailEvent(sessionID: session.id, kind: "session_end"))
        flush()
        isFinalizing = true
        session.endedAt = Date().timeIntervalSince1970
        session.status = "complete"
        let finalized = session
        let activeBuilder = builder
        writerQueue.async {
            do {
                guard !self.failedSessionIDs.contains(finalized.id) else { throw TrailError.message("Some input batches failed to save. The session remains interrupted.") }
                try self.store.transaction {
                    for action in activeBuilder.flush() { try self.store.append(action) }
                    try self.store.saveSession(finalized)
                }
                DispatchQueue.main.async {
                    self.currentSession = nil
                    self.isFinalizing = false
                    self.isPaused = false
                    self.suppression = nil
                    self.notice = "Session saved. Search the timeline or export the dataset."
                    self.refresh()
                }
            } catch { DispatchQueue.main.async { if self.currentSession?.id == finalized.id { self.fail(error) } } }
        }
    }

    func togglePause() {
        guard currentSession != nil, !isFinalizing else { return }
        input.togglePause()
    }

    private func applyPause(_ event: TrailEvent) {
        guard var session = currentSession, !isFinalizing else { return }
        isPaused = event.kind == "pause"
        generation += 1
        cachedContext = nil
        cachedExcel = nil
        clipboardChange = NSPasteboard.general.changeCount
        session.status = isPaused ? "paused" : "recording"
        currentSession = session
        pending.append(event)
        flush()
        let saved = session
        writerQueue.async {
            do { try self.store.saveSession(saved) }
            catch {
                self.failedSessionIDs.insert(saved.id)
                DispatchQueue.main.async { if self.currentSession?.id == saved.id { self.fail(error) } }
            }
        }
    }

    func addMarker(captured: TrailEvent? = nil) {
        guard let session = currentSession, !isFinalizing else { return }
        var event = captured ?? TrailEvent(sessionID: session.id, kind: "marker")
        event.kind = "marker"
        event.text = markerText.isEmpty ? "Moment to review" : String(markerText.prefix(2048))
        if let context = cachedContext, Date().timeIntervalSince1970 - context.observedAt < 2 {
            event.context = context
            event.app = context.app
            event.bundleID = context.bundleID
        }
        pending.append(event)
        markerText = ""
        notice = "Bookmark added."
        flush()
    }

    func requestInputPermission() { _ = CGRequestListenEventAccess(); openPrivacy("ListenEvent") }
    func requestAccessibility() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        openPrivacy("Accessibility")
    }
    func requestScreenPermission() { _ = CGRequestScreenCaptureAccess(); openPrivacy("ScreenCapture") }

    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(url) }
    }

    func loadMore() { actionLimit += 500; refresh() }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let sessionID = selectedSessionID
        let search = query
        let limit = actionLimit
        DispatchQueue.global(qos: .utility).async {
            do {
                let sessions = try self.store.sessions()
                let selected = sessionID ?? sessions.first?.id
                var actions: [TrailAction] = []
                if let selected {
                    var cursor: Int64 = 0
                    while actions.count < limit {
                        let batch = try self.store.actions(sessionID: selected, query: search, afterID: cursor, limit: min(1000, limit - actions.count))
                        actions += batch
                        guard let last = batch.last else { break }
                        cursor = last.id
                    }
                }
                DispatchQueue.main.async {
                    self.refreshing = false
                    self.sessions = sessions
                    if self.selectedSessionID == sessionID && self.query == search {
                        self.actions = actions
                        if self.selectedSessionID == nil { self.selectedSessionID = selected }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.refreshing = false; self.errorMessage = error.localizedDescription }
            }
        }
    }

    func createDemo() {
        guard !isRecording, !isFinalizing else { return }
        writerQueue.async {
            do {
                let session = try DemoSession.create(in: self.store)
                DispatchQueue.main.async { self.selectedSessionID = session.id; self.notice = "Synthetic example loaded. No computer input was recorded."; self.refresh() }
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }

    func exportSelected() {
        guard let session = selectedSession, session.status != "recording", session.status != "paused" else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where to save the demonstration dataset"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let destination = folder.appendingPathComponent("AgentTrail-\(session.id.prefix(8))-\(Int(Date().timeIntervalSince1970))")
        notice = "Exporting dataset…"
        writerQueue.async {
            do {
                try SessionExport.write(store: self.store, sessionID: session.id, destination: destination)
                DispatchQueue.main.async { self.notice = "Exported timeline, raw inputs, and training records."; NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }

    private func receive(_ incoming: TrailEvent) {
        guard let session = currentSession, incoming.sessionID == session.id, !isFinalizing else { return }
        if incoming.kind == "pause" || incoming.kind == "resume" { applyPause(incoming); return }
        if incoming.kind == "marker_shortcut" { addMarker(captured: incoming); return }
        guard !isPaused else { return }
        if incoming.kind == "gap" {
            if lastGap != incoming.fields["reason"] {
                lastGap = incoming.fields["reason"] ?? ""
                pending.append(incoming)
            }
            return
        }
        if let reason = gate(bundleID: incoming.bundleID, options: session.options) {
            if suppression != reason {
                suppression = reason
                gap(reason, timestamp: incoming.timestamp)
                clipboardChange = NSPasteboard.general.changeCount
            }
            return
        }
        if suppression != nil { suppression = nil }
        if !lastGap.isEmpty { lastGap = "" }
        if incoming.bundleID != lastBundleID {
            generation += 1
            lastBundleID = incoming.bundleID
            var focus = TrailEvent(sessionID: session.id, kind: "app_focus", timestamp: incoming.timestamp,
                                   monotonicNS: incoming.monotonicNS, app: incoming.app, bundleID: incoming.bundleID)
            focus.fields["trigger"] = "first observed input in application"
            pending.append(focus)
        }
        var event = incoming
        if let context = cachedContext, context.bundleID == incoming.bundleID,
           incoming.timestamp >= context.observedAt, incoming.timestamp - context.observedAt < 2 {
            event.context = context
            if let excel = cachedExcel, incoming.bundleID == "com.microsoft.Excel",
               incoming.timestamp >= excel.observedAt, incoming.timestamp - excel.observedAt < 2 {
                event.context?.selection = excel.selection ?? context.selection
                event.context?.workbook = excel.workbook
                event.context?.worksheet = excel.worksheet
                event.fields["excel_observed_at"] = String(excel.observedAt)
            }
        }
        if pending.count + outstandingEvents >= 8000 { gap("Input buffer capacity reached; some events were dropped"); return }
        pending.append(event)
    }

    private func trackFocus(_ app: NSRunningApplication) {
        guard let session = currentSession, !isPaused, !isFinalizing else { return }
        generation += 1
        cachedContext = nil
        cachedExcel = nil
        clipboardChange = NSPasteboard.general.changeCount
        let bundle = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        if let reason = gate(bundleID: bundle, options: session.options) { suppression = reason; gap(reason); lastBundleID = ""; return }
        suppression = nil
        lastGap = ""
        guard lastBundleID != bundle else { return }
        lastBundleID = bundle
        var event = TrailEvent(sessionID: session.id, kind: "app_focus", app: app.localizedName ?? "", bundleID: bundle)
        event.fields["trigger"] = "workspace application activation"
        pending.append(event)
        sampleContext()
    }

    private func gate(bundleID: String, options: CaptureOptions) -> String? {
        if bundleID == Bundle.main.bundleIdentifier || bundleID == "local.agenttrail.recorder" { return "Recorder controls excluded" }
        if !options.allows(bundleID) { return "Application excluded by capture settings" }
        if IsSecureEventInputEnabled() { return "Secure input is active" }
        if cachedContext?.bundleID == bundleID, cachedContext?.secure == true { return "Password field focused" }
        return nil
    }

    private func gap(_ reason: String, timestamp: Double = Date().timeIntervalSince1970) {
        guard let session = currentSession, !isPaused, !isFinalizing, lastGap != reason else { return }
        lastGap = reason
        var event = TrailEvent(sessionID: session.id, kind: "gap", timestamp: timestamp)
        event.fields["reason"] = reason
        event.fields["category"] = CaptureGap.isIntentional(reason) ? "intentional_exclusion" : "capture_failure"
        pending.append(event)
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        let activeBuilder = builder
        let sessionID = batch[0].sessionID
        outstandingEvents += batch.count
        pending.removeAll(keepingCapacity: true)
        writerQueue.async {
            do {
                guard !self.failedSessionIDs.contains(sessionID) else { throw TrailError.message("An earlier input batch failed to save") }
                var significant: TrailEvent?
                try self.store.transaction {
                    for event in batch {
                        let saved = try self.store.append(event)
                        for action in activeBuilder.consume(saved) { try self.store.append(action) }
                        if ["mouse_down", "mouse_up", "key_down"].contains(saved.kind) { significant = saved }
                    }
                }
                DispatchQueue.main.async {
                    self.outstandingEvents -= batch.count
                    if let significant { self.sampleContext(related: significant) }
                }
            } catch {
                self.failedSessionIDs.insert(sessionID)
                DispatchQueue.main.async {
                    self.outstandingEvents -= batch.count
                    if self.currentSession?.id == sessionID { self.fail(error) }
                }
            }
        }
    }

    private func sampleContext(related: TrailEvent? = nil) {
        guard let session = currentSession, !isPaused, !isFinalizing, let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundle = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        guard session.options.allows(bundle), bundle != Bundle.main.bundleIdentifier, !IsSecureEventInputEnabled() else {
            clipboardChange = NSPasteboard.general.changeCount
            return
        }
        if let related, related.bundleID != bundle || related.sessionID != session.id { return }
        let token = generation
        let point = related.flatMap { event -> CGPoint? in
            guard event.kind.hasPrefix("mouse"), let horizontal = event.x, let vertical = event.y else { return nil }
            return CGPoint(x: horizontal, y: vertical)
        }
        contextResolver.request(app: app, point: point, includeText: session.options.captureText) { [weak self] context in
            guard let self, self.currentSession?.id == session.id, !self.isPaused, !self.isFinalizing,
                  self.generation == token, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            self.cachedContext = context
            guard !context.secure, !IsSecureEventInputEnabled() else { self.gap("Password field focused"); return }
            var event = TrailEvent(sessionID: session.id, kind: "context", app: context.app, bundleID: context.bundleID)
            event.context = context
            event.relatedEventID = related?.id
            self.pending.append(event)
            if session.options.captureScreenshots, let related, self.hasScreenPermission {
                self.captureScreenshot(app: app, related: related, token: token)
            }
        }
        if bundle == "com.microsoft.Excel", session.options.excelContext {
            excelResolver.request { [weak self] context in
                guard let self, self.currentSession?.id == session.id, !self.isPaused, !self.isFinalizing,
                      self.generation == token, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle, !IsSecureEventInputEnabled() else { return }
                self.cachedExcel = context
                var event = TrailEvent(sessionID: session.id, kind: "context", app: context.app, bundleID: context.bundleID)
                event.context = context
                event.relatedEventID = related?.id
                self.pending.append(event)
                if let error = context.error { self.notice = "Excel context: \(error)" }
            }
        }
        if NSPasteboard.general.changeCount != clipboardChange {
            clipboardChange = NSPasteboard.general.changeCount
            guard gate(bundleID: bundle, options: session.options) == nil else { return }
            var event = TrailEvent(sessionID: session.id, kind: "clipboard", app: app.localizedName ?? "", bundleID: bundle)
            event.fields["types"] = (NSPasteboard.general.types ?? []).map(\.rawValue).joined(separator: ",")
            if session.options.captureClipboard { event.text = NSPasteboard.general.string(forType: .string).map { String($0.prefix(16384)) } }
            pending.append(event)
        }
    }

    private func captureScreenshot(app: NSRunningApplication, related: TrailEvent, token: Int) {
        let requestedAt = Date().timeIntervalSince1970
        screenshots.request(pid: app.processIdentifier) { [weak self] data, error in
            guard let self, let session = self.currentSession, session.id == related.sessionID, !self.isPaused,
                  !self.isFinalizing, self.generation == token, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  self.gate(bundleID: related.bundleID, options: session.options) == nil else { return }
            guard let data else { self.notice = "Screenshot skipped: \(error ?? "capture unavailable")"; return }
            let relative = "sessions/\(session.id)/frames/\(UUID().uuidString.lowercased()).jpg"
            var event = TrailEvent(sessionID: session.id, kind: "screenshot", app: related.app, bundleID: related.bundleID)
            event.relatedEventID = related.id
            event.attachment = relative
            event.fields["requested_at"] = String(requestedAt)
            event.fields["timing"] = "asynchronous post-input capture; frame time within request/completion interval"
            let saved = event
            self.writerQueue.async {
                do {
                    let url = self.store.root.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    _ = try self.store.append(saved)
                } catch {
                    self.failedSessionIDs.insert(session.id)
                    DispatchQueue.main.async { if self.currentSession?.id == session.id { self.fail(error) } }
                }
            }
        }
    }

    private func fail(_ error: Error) {
        input.stop(deliverPending: false)
        flushTimer?.invalidate()
        contextTimer?.invalidate()
        generation += 1
        pending.removeAll()
        currentSession = nil
        isFinalizing = false
        isPaused = false
        errorMessage = "Recording stopped because data could not be saved: \(error.localizedDescription). On next launch, AgentTrail will recover committed events."
    }
}
