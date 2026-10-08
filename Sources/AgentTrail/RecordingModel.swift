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
    @Published private(set) var draftSession: Session?
    @Published private(set) var isSaving = false
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
    private let input: RecordingInput
    private let observesWorkspace: Bool
    private var draftStore: TrailStore?
    private var libraryRevision = 0
    private let contextResolver = ContextResolver()
    private let excelResolver = ExcelResolver()
    private let screenshots = ScreenshotCapture()
    private let windowGeometryObserver = WindowGeometryObserver()
    private let writerQueue = DispatchQueue(label: "agenttrail.writer", qos: .utility)
    private var builder = ActionBuilder()
    private var pending: [TrailEvent] = []
    private var outstandingEvents = 0
    private var failedSessionIDs: Set<String> = []
    private var handlingFailure = false
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

    init(store: TrailStore, captureDefaults: UserDefaults = .standard, input: RecordingInput = InputCapture(), observesWorkspace: Bool = true) throws {
        self.store = store
        self.captureDefaults = captureDefaults
        self.input = input
        self.observesWorkspace = observesWorkspace
        try store.recoverInterruptedSessions()
        if let data = captureDefaults.data(forKey: "captureOptions"), let saved = try? JSONDecoder().decode(CaptureOptions.self, from: data) { options = saved }
        input.onEvent = { [weak self] in self?.receive($0) }
        windowGeometryObserver.onEvent = { [weak self] in self?.receive($0) }
        if observesWorkspace {
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
        }
        refreshTimer = AppRunLoopTimer.schedule(interval: 1) { [weak self] _ in
            guard let self else { return }
            self.refreshPermissions()
            if let session = self.currentSession { self.elapsed = Date().timeIntervalSince1970 - session.startedAt }
            self.startWindowGeometryObservation(for: NSWorkspace.shared.frontmostApplication)
            self.refresh()
        }
        refresh()
    }

    deinit {
        refreshTimer?.invalidate()
        flushTimer?.invalidate()
        contextTimer?.invalidate()
        windowGeometryObserver.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func refreshPermissions() {
        hasInputPermission = CGPreflightListenEventAccess()
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasScreenPermission = CGPreflightScreenCaptureAccess()
    }

    var isRecording: Bool { currentSession != nil && !isFinalizing }
    var selectedSession: Session? { sessions.first { $0.id == selectedSessionID } }
    var hasUnsavedRecording: Bool { draftSession != nil }
    var selectedStore: TrailStore { store(for: selectedSessionID) }
    func store(for sessionID: String?) -> TrailStore {
        if let draftStore, let sessionID, draftSession?.id == sessionID { return draftStore }
        return store
    }
    var status: String {
        if isSaving { return "Saving" }
        if isFinalizing { return "Finishing" }
        if isRecording { return isPaused ? "Paused · Unsaved" : suppression == nil ? "Recording · Unsaved" : "Protected · Unsaved" }
        return hasUnsavedRecording ? "Unsaved" : "Ready"
    }

    func start() {
        guard currentSession == nil, !isFinalizing, !isSaving, !hasUnsavedRecording else { return }
        do {
            let sessionTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displays = (observesWorkspace ? NSScreen.screens : []).map { "\($0.localizedName):\($0.frame),scale=\($0.backingScaleFactor)" }.joined(separator: "; ")
            let session = Session(title: sessionTitle.isEmpty ? "Demonstration · \(Date().formatted(date: .abbreviated, time: .shortened))" : sessionTitle,
                                  options: options, metadata: ["schema_version": "1", "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                                             "coordinates": "macOS global display points, main-display top-left origin for CG events",
                                                             "displays_appkit": displays, "keyboard_labels": "physical ANSI labels; raw key codes retained",
                                                             "version": "0.3.0", "capture": "dedicated-thread listen-only annotated CGEventTap; AX sampled including focused-window geometry; no replay"])
            let draft = try TrailStore(root: store.root, inMemory: true)
            try draft.saveSession(session)
            input.sessionID = session.id
            input.includeText = options.captureText
            try input.start()
            draftStore = draft
            draftSession = session
            libraryRevision += 1
            currentSession = session
            isPaused = false
            elapsed = 0
            generation += 1
            builder = ActionBuilder()
            handlingFailure = false
            cachedContext = nil
            cachedExcel = nil
            lastBundleID = ""
            lastGap = ""
            suppression = nil
            clipboardChange = NSPasteboard.general.changeCount
            excelResolver.reset()
            windowGeometryObserver.sessionID = session.id
            selectedSessionID = session.id
            pending.append(TrailEvent(sessionID: session.id, kind: "session_start"))
            let flushTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.flush() }
            let contextTimer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in self?.sampleContext() }
            RunLoop.main.add(flushTimer, forMode: .common)
            if observesWorkspace { RunLoop.main.add(contextTimer, forMode: .common) }
            self.flushTimer = flushTimer
            self.contextTimer = contextTimer
            startWindowGeometryObservation(for: NSWorkspace.shared.frontmostApplication)
            notice = "Recording temporarily. Nothing is saved until you choose Save recording. ⌃⌥⌘P pauses."
            errorMessage = nil
            flush()
        } catch { errorMessage = error.localizedDescription }
    }

    func stop() {
        guard var session = currentSession, let draft = draftStore, !isFinalizing else { return }
        windowGeometryObserver.stop()
        input.stop(deliverPending: true)
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
                guard !self.failedSessionIDs.contains(finalized.id) else { throw TrailError.message("Some input batches could not be retained. Review the interrupted draft before saving.") }
                try draft.transaction {
                    for action in activeBuilder.flush() { try draft.append(action) }
                    try draft.saveSession(finalized)
                }
                DispatchQueue.main.async {
                    self.libraryRevision += 1
                    self.draftSession = finalized
                    self.currentSession = nil
                    self.isFinalizing = false
                    self.isPaused = false
                    self.suppression = nil
                    self.notice = "Recording stopped. Review it, then choose Save recording or Discard. Nothing has been saved."
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
        guard var session = currentSession, let draft = draftStore, !isFinalizing else { return }
        isPaused = event.kind == "pause"
        if isPaused {
            windowGeometryObserver.stop()
        } else if observesWorkspace {
            startWindowGeometryObservation(for: NSWorkspace.shared.frontmostApplication)
        }
        generation += 1
        cachedContext = nil
        cachedExcel = nil
        clipboardChange = NSPasteboard.general.changeCount
        session.status = isPaused ? "paused" : "recording"
        currentSession = session
        draftSession = session
        libraryRevision += 1
        pending.append(event)
        flush()
        let saved = session
        writerQueue.async {
            do { try draft.saveSession(saved) }
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
        let revision = libraryRevision
        let draft = draftStore
        let draftID = draftSession?.id
        DispatchQueue.global(qos: .utility).async {
            do {
                let saved = try self.store.sessions()
                let unsaved = try draft?.sessions().first
                let sessions = (unsaved.map { [$0] } ?? []) + saved
                let selected = sessionID ?? sessions.first?.id
                let source = selected != nil && selected == draftID ? (draft ?? self.store) : self.store
                var actions: [TrailAction] = []
                if let selected {
                    var cursor: Int64 = 0
                    while actions.count < limit {
                        let batch = try source.actions(sessionID: selected, query: search, afterID: cursor, limit: min(1000, limit - actions.count))
                        actions += batch
                        guard let last = batch.last else { break }
                        cursor = last.id
                    }
                }
                DispatchQueue.main.async {
                    self.refreshing = false
                    guard self.libraryRevision == revision else { self.refresh(); return }
                    self.sessions = sessions
                    if self.draftSession?.id == draftID { self.draftSession = unsaved }
                    if self.selectedSessionID == sessionID && self.query == search {
                        self.actions = actions
                        if self.selectedSessionID == nil { self.selectedSessionID = selected }
                    } else { self.refresh() }
                }
            } catch {
                DispatchQueue.main.async {
                    self.refreshing = false
                    if self.libraryRevision == revision { self.errorMessage = error.localizedDescription }
                    else { self.refresh() }
                }
            }
        }
    }

    func createDemo() {
        guard !isRecording, !isFinalizing, !isSaving, !hasUnsavedRecording else { return }
        isFinalizing = true
        writerQueue.async {
            do {
                let draft = try TrailStore(root: self.store.root, inMemory: true)
                let session = try DemoSession.create(in: draft)
                DispatchQueue.main.async {
                    self.draftStore = draft
                    self.draftSession = session
                    self.libraryRevision += 1
                    self.isFinalizing = false
                    self.selectedSessionID = session.id
                    self.notice = "Unsaved synthetic example. Save it to keep it, or discard it. No computer input was recorded."
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async { self.isFinalizing = false; self.errorMessage = error.localizedDescription }
            }
        }
    }

    func saveRecording(completion: ((Bool) -> Void)? = nil) {
        guard let draft = draftStore, let session = draftSession,
              currentSession == nil, !isFinalizing, !isSaving else { completion?(false); return }
        isSaving = true
        errorMessage = nil
        notice = "Saving recording…"
        writerQueue.async {
            do {
                _ = try self.store.saveRecording(from: draft, sessionID: session.id)
                DispatchQueue.main.async {
                    self.libraryRevision += 1
                    self.draftSession = nil
                    self.draftStore = nil
                    self.selectedAction = nil
                    self.actions = []
                    self.isSaving = false
                    self.failedSessionIDsCleanup(session.id)
                    self.notice = "Recording saved. It is now in your library and available for export."
                    self.refresh()
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.errorMessage = "Could not save recording: \(error.localizedDescription). Your unsaved recording is still here; retry Save or choose Discard."
                    completion?(false)
                }
            }
        }
    }

    func discardRecording() {
        guard let session = draftSession, currentSession == nil, !isFinalizing, !isSaving else { return }
        libraryRevision += 1
        draftSession = nil
        draftStore = nil
        pending.removeAll()
        builder = ActionBuilder()
        cachedContext = nil
        cachedExcel = nil
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id { selectedSessionID = sessions.first?.id; selectedAction = nil; actions = [] }
        failedSessionIDsCleanup(session.id)
        errorMessage = nil
        notice = "Recording discarded. Nothing was saved."
        refresh()
    }

    private func failedSessionIDsCleanup(_ id: String) {
        writerQueue.async { self.failedSessionIDs.remove(id) }
    }

    func exportSelected() {
        guard let session = selectedSession, session.id != draftSession?.id, session.status != "recording", session.status != "paused", !isSaving else { return }
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
        if let reason = gate(bundleID: bundle, options: session.options) {
            windowGeometryObserver.stop()
            suppression = reason
            gap(reason)
            lastBundleID = ""
            return
        }
        startWindowGeometryObservation(for: app)
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

    private func startWindowGeometryObservation(for app: NSRunningApplication?) {
        guard observesWorkspace, let session = currentSession, !isPaused, !isFinalizing,
              let app else {
            windowGeometryObserver.stop()
            return
        }
        let bundle = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        guard bundle != Bundle.main.bundleIdentifier,
              session.options.allows(bundle),
              !IsSecureEventInputEnabled() else {
            windowGeometryObserver.stop()
            return
        }
        windowGeometryObserver.start(app: app)
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
        guard !pending.isEmpty, let draft = draftStore else { return }
        let batch = pending
        let activeBuilder = builder
        let sessionID = batch[0].sessionID
        outstandingEvents += batch.count
        pending.removeAll(keepingCapacity: true)
        writerQueue.async {
            do {
                guard !self.failedSessionIDs.contains(sessionID) else { throw TrailError.message("An earlier input batch could not be retained") }
                var significant: TrailEvent?
                try draft.transaction {
                    for event in batch {
                        let saved = try draft.append(event)
                        for action in activeBuilder.consume(saved) { try draft.append(action) }
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
        guard observesWorkspace, let session = currentSession, !isPaused, !isFinalizing, let app = NSWorkspace.shared.frontmostApplication else { return }
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
            guard let draft = self.draftStore else { return }
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
                    try draft.writeAttachment(data, relativePath: relative)
                    _ = try draft.append(saved)
                } catch {
                    self.failedSessionIDs.insert(session.id)
                    DispatchQueue.main.async { if self.currentSession?.id == session.id { self.fail(error) } }
                }
            }
        }
    }

    private func fail(_ error: Error) {
        guard var interrupted = currentSession, let draft = draftStore, !handlingFailure else { return }
        handlingFailure = true
        input.stop(deliverPending: false)
        windowGeometryObserver.stop()
        flushTimer?.invalidate()
        contextTimer?.invalidate()
        generation += 1
        pending.removeAll()
        isFinalizing = true
        isPaused = false
        suppression = nil
        interrupted.status = "interrupted"
        interrupted.metadata["capture_error"] = error.localizedDescription
        let failed = interrupted
        writerQueue.async {
            // Preserve committed draft evidence after a failed batch. It still requires explicit Save.
            try? draft.saveSession(failed)
            try? draft.rebuildActions(sessionID: failed.id)
            DispatchQueue.main.async {
                self.libraryRevision += 1
                self.draftSession = failed
                self.currentSession = nil
                self.isFinalizing = false
                self.errorMessage = "Recording stopped: \(error.localizedDescription). Nothing was saved. Review the retained draft, then Save recording or Discard."
                self.refresh()
            }
        }
    }
}
