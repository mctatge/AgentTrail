import AppKit
import SwiftUI
import TrailCore

enum Studio {
    static let signal = Color(red: 0.91, green: 0.35, blue: 0.26)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let inset = Color.primary.opacity(0.035)
    static let line = Color.primary.opacity(0.09)
}

struct WorkspaceView: View {
    @ObservedObject var model: RecordingModel
    @State private var showingSetup = false
    @State private var showingAI = false
    @State private var cursorRequest: CursorTrailRequest?
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.title2).foregroundStyle(Studio.signal)
                Text("AgentTrail").font(.system(size: 19, weight: .semibold))
                Text("DEMONSTRATION STUDIO").font(.system(size: 10, weight: .medium)).tracking(1.6).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(model.isRecording && !model.isPaused ? Studio.signal : Color.secondary).frame(width: 7, height: 7)
                Text(model.status).font(.system(size: 12, weight: .medium))
                Button { showingAI = true } label: { Label("Use with AI", systemImage: "sparkle") }
                Button { showingSetup = true } label: { Image(systemName: "slider.horizontal.3") }.help("Capture settings and permissions")
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 224)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    recordingControls
                    Divider()
                    if let session = model.selectedSession { timeline(session) }
                    else { emptyState }
                }.frame(minWidth: 430, maxWidth: .infinity)
                if let action = model.selectedAction {
                    Divider()
                    EventInspector(action: action, store: model.selectedStore, showCursor: {
                        cursorRequest = CursorTrailRequest(sessionID: action.sessionID, title: action.summary, firstEventID: action.firstEventID, lastEventID: action.lastEventID)
                    }) { model.selectedAction = nil }.id("\(action.sessionID)-\(model.hasUnsavedRecording)").frame(width: 306)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text(model.errorMessage ?? model.notice).lineLimit(2).foregroundStyle(model.errorMessage == nil ? Color.secondary : Studio.signal)
                Spacer(minLength: 12)
                Text("ON THIS MAC").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(.horizontal, 20).padding(.vertical, 10)
        }
        .background(Studio.surface)
        .frame(minWidth: 980, minHeight: 650)
        .tint(Studio.signal)
        .sheet(isPresented: $showingSetup) { SetupView(model: model).background(NonblockingSheet()) }
        .sheet(isPresented: $showingAI) { AIView(model: model).background(NonblockingSheet()) }
        .sheet(item: $cursorRequest) { request in CursorTrailView(store: model.store(for: request.sessionID), request: request).background(NonblockingSheet()) }
        .onChange(of: model.hasUnsavedRecording) { _, hasUnsaved in
            if !hasUnsaved { cursorRequest = nil }
        }
        .alert("Discard this recording?", isPresented: $confirmingDiscard) {
            Button("Discard recording", role: .destructive) { model.discardRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This recording has not been saved. Discarding removes it permanently.")
        }
    }

    private var savedSessions: [Session] { model.sessions.filter { $0.id != model.draftSession?.id } }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let draft = model.draftSession {
                Text("UNSAVED RECORDING").font(.system(size: 9, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Studio.signal).padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 6)
                sessionRow(draft, unsaved: true).padding(.horizontal, 8).padding(.bottom, 12)
                Divider()
            }
            HStack {
                Text("Saved sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(savedSessions.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(savedSessions) { session in sessionRow(session, unsaved: false) }
                }.padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                Button { model.createDemo() } label: { Label("Explore an example", systemImage: "play.rectangle") }
                    .disabled(model.hasUnsavedRecording || model.isFinalizing || model.isSaving)
                Button { NSWorkspace.shared.open(model.store.root) } label: { Label("Open recording library", systemImage: "folder") }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).padding(20)
        }
    }

    private func sessionRow(_ session: Session, unsaved: Bool) -> some View {
        Button {
            model.query = ""
            model.selectedSessionID = session.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: session.metadata["synthetic"] == "true" ? "play.rectangle" : "waveform.path").foregroundStyle(model.selectedSessionID == session.id ? Studio.signal : Color.secondary)
                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                }
                Text(Date(timeIntervalSince1970: session.startedAt).formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text("\(session.actionCount) actions")
                    Spacer()
                    Text(unsaved ? "Unsaved" : session.status.capitalized)
                        .foregroundStyle(unsaved ? Studio.signal : Color.secondary)
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedSessionID == session.id ? Studio.inset : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.isRecording ? "CAPTURE IN PROGRESS · UNSAVED" : model.hasUnsavedRecording ? "UNSAVED RECORDING" : "YOUR NEXT DEMONSTRATION")
                        .font(.system(size: 10, weight: .medium)).tracking(1.6)
                        .foregroundStyle(model.hasUnsavedRecording ? Studio.signal : Color.secondary)
                    if let draft = model.draftSession {
                        Text(draft.title).font(.system(size: 23, weight: .semibold)).lineLimit(2)
                    } else {
                        TextField("Give this session a name", text: $model.title)
                            .textFieldStyle(.plain).font(.system(size: 25, weight: .medium))
                            .accessibilityLabel("New session name")
                    }
                    Text(recordingExplanation).font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.isRecording || model.isFinalizing {
                    Text(duration(model.elapsed)).font(.system(size: 32, weight: .light, design: .monospaced)).monospacedDigit()
                }
            }
            HStack(spacing: 10) {
                if model.isRecording {
                    Button { model.togglePause() } label: { Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") }
                    Button { model.stop() } label: { Label("Stop recording", systemImage: "stop.fill") }.buttonStyle(.borderedProminent)
                    Spacer()
                    Text("⌃⌥⌘P to pause").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                } else if model.hasUnsavedRecording {
                    Button { model.saveRecording() } label: {
                        Label(model.isSaving ? "Saving…" : model.isFinalizing ? "Finishing…" : "Save recording", systemImage: "square.and.arrow.down")
                    }.buttonStyle(.borderedProminent).disabled(model.isFinalizing || model.isSaving)
                    Button("Discard…") { confirmingDiscard = true }.disabled(model.isFinalizing || model.isSaving)
                    Spacer()
                    Button("Start recording") { model.start() }.disabled(true).help("Save or discard the current recording first")
                } else {
                    Button { model.start() } label: { Label("Start recording", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent).disabled(model.isFinalizing || model.isSaving)
                    Button { showingSetup = true } label: { Label("Capture settings", systemImage: "slider.horizontal.3") }.disabled(model.isFinalizing || model.isSaving)
                    Spacer()
                    if !model.hasInputPermission || !model.hasAccessibilityPermission {
                        Button("Set up permissions") { showingSetup = true }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }.controlSize(.large)
            if model.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark").foregroundStyle(.secondary)
                    TextField("Note an edge case or intention…", text: $model.markerText).textFieldStyle(.plain).onSubmit { model.addMarker() }
                    Button("Add bookmark") { model.addMarker() }.buttonStyle(.borderless)
                }.font(.system(size: 12)).padding(12).background(Studio.inset, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(28)
    }

    private var recordingExplanation: String {
        if model.isSaving { return "Saving this recording to your library…" }
        if model.isFinalizing { return "Preparing your recording for review. It has not been saved." }
        if model.isRecording {
            if let suppression = model.suppression { return "\(suppression). This recording is still unsaved." }
            return model.isPaused ? "Paused. Nothing is saved until you choose Save recording." : "Recording temporarily. Stop to review, then choose Save or Discard."
        }
        if model.hasUnsavedRecording { return "Review this recording, then save it to your library or discard it." }
        return "Start captures temporarily. Only Save recording keeps it in your library."
    }

    private func timeline(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(session.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        if model.draftSession?.id == session.id {
                            Text("Unsaved").font(.system(size: 10, weight: .semibold)).foregroundStyle(Studio.signal)
                                .padding(.horizontal, 7).padding(.vertical, 3).background(Studio.signal.opacity(0.10), in: Capsule())
                        }
                    }
                    Text("\(session.eventCount.formatted()) raw events → \(session.actionCount.formatted()) actions\(session.metadata["synthetic"] == "true" ? " · SYNTHETIC EXAMPLE" : "")")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    cursorRequest = CursorTrailRequest(sessionID: session.id, title: session.title)
                } label: { Label("Cursor trail", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                VStack(alignment: .trailing, spacing: 4) {
                    Button { model.exportSelected() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .disabled(model.isSaving || model.draftSession?.id == session.id || session.status == "recording" || session.status == "paused")
                    if model.draftSession?.id == session.id {
                        Text("Save before export").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search shortcuts, apps, ranges, or bookmarks", text: $model.query).textFieldStyle(.plain)
                if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.font(.system(size: 12)).padding(12).background(Studio.inset, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 28).padding(.bottom, 16)
            HStack {
                Text("ELAPSED").frame(width: 76, alignment: .leading)
                Text("OBSERVED ACTION")
                Spacer()
                Text("EVENTS")
            }.font(.system(size: 9, weight: .medium)).tracking(1.2).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.bottom, 10)
            Divider()
            if model.actions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path").font(.title).foregroundStyle(.secondary)
                    Text(model.query.isEmpty ? "Your actions will appear here" : "No matching actions")
                    Text(model.query.isEmpty ? "Switch to the app you want to demonstrate." : "Try an app name, shortcut, or cell range.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.actions) { action in
                            ActionRow(action: action, sessionStart: session.startedAt, selected: model.selectedAction?.id == action.id) { model.selectedAction = action }
                        }
                        if model.actions.count >= 500 {
                            Button("Load more actions") { model.loadMore() }.padding(20)
                        }
                    }
                }
            }
        }.frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "cursorarrow.motionlines").font(.system(size: 36, weight: .light)).foregroundStyle(Studio.signal)
            Text("Every demonstration\nhas a story.").font(.system(size: 30, weight: .medium)).tracking(-0.6)
            Text("Keep the clicks, shortcuts, drags, and context that explain how a task was done. Return to a moment, inspect its inputs, or export the session for an agent.")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5).frame(maxWidth: 430)
            HStack(spacing: 20) {
                Label("Timestamped inputs", systemImage: "clock")
                Label("Queryable history", systemImage: "text.magnifyingglass")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Explore a sample timeline") { model.createDemo() }.buttonStyle(.bordered).controlSize(.large)
                .disabled(model.hasUnsavedRecording || model.isFinalizing || model.isSaving)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func duration(_ seconds: Double) -> String {
        String(format: "%02d:%02d:%02d", Int(seconds) / 3600, Int(seconds) / 60 % 60, Int(seconds) % 60)
    }
}

struct ActionRow: View {
    let action: TrailAction
    let sessionStart: Double
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Text(String(format: "%02d:%05.2f", Int(max(0, action.startedAt - sessionStart)) / 60, max(0, action.startedAt - sessionStart).truncatingRemainder(dividingBy: 60)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading).padding(.top, 3)
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(action.kind == "marker" ? Studio.signal : Color.secondary)
                    .frame(width: 20).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(action.summary).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(3).multilineTextAlignment(.leading)
                    let context = [action.app.isEmpty ? nil : action.app, action.context?.selection].compactMap { $0 }.joined(separator: " · ")
                    if !context.isEmpty { Text(context).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    if action.inference != nil { Text("Possible fill-down · inspect evidence").font(.system(size: 10)).foregroundStyle(Studio.signal) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text("\(action.eventCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 3)
            }.padding(.horizontal, 28).padding(.vertical, 14)
                .background(selected ? Studio.inset : Color.clear).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var icon: String {
        switch action.kind {
        case "shortcut": return "command"
        case "typing": return "text.cursor"
        case "drag": return "arrow.up.left.and.arrow.down.right"
        case "click", "release": return "cursorarrow.click"
        case "move": return "cursorarrow.motionlines"
        case "scroll": return "arrow.up.and.down"
        case "marker": return "bookmark.fill"
        case "app_focus": return "macwindow.on.rectangle"
        case "gap": return action.summary.hasPrefix("Not recorded") ? "eye.slash" : "exclamationmark.triangle"
        case "pause": return "pause"
        case "resume", "session_start": return "play"
        case "session_end": return "stop"
        default: return "circle.dotted"
        }
    }
}

struct EventInspector: View {
    let action: TrailAction
    let store: TrailStore
    let showCursor: () -> Void
    let dismiss: () -> Void
    @State private var events: [TrailEvent] = []
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("EVENT EVIDENCE").font(.system(size: 10, weight: .medium)).tracking(1.4).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close event inspector")
                }
                Text(action.summary).font(.system(size: 20, weight: .medium)).textSelection(.enabled)
                detail("Time", SessionExport.iso(action.startedAt))
                detail("Application", action.app.isEmpty ? "Recorder" : action.app)
                detail("Raw event IDs", "\(action.firstEventID)–\(action.lastEventID)")
                if ["move", "drag", "click", "release", "scroll"].contains(action.kind) {
                    Button(action: showCursor) { Label("View cursor trail", systemImage: "cursorarrow.motionlines") }
                }
                if let context = action.context ?? events.compactMap(\.context).first {
                    if let window = context.window { detail("Window", window) }
                    if let selection = context.selection { detail("Observed selection", selection) }
                    if let label = context.label { detail("Element", label) }
                    if let role = context.role { detail("Accessibility role", role) }
                    detail("Context observed", SessionExport.iso(context.observedAt))
                    Text("Context is sampled separately. Its timestamp determines whether it was observed before or after the input.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let inference = action.inference {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("INFERENCE").font(.system(size: 9, weight: .semibold)).tracking(1.1)
                        Text(inference).font(.system(size: 12)).lineSpacing(3)
                    }.foregroundStyle(Studio.signal).padding(12).background(Studio.inset, in: RoundedRectangle(cornerRadius: 8))
                }
                if let frame = events.first(where: { $0.attachment != nil }), let path = frame.attachment,
                   let imageData = try? store.attachmentData(relativePath: path), let image = NSImage(data: imageData) {
                    Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Asynchronous frame · \(SessionExport.iso(frame.timestamp))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("RAW RECORDS").font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rawJSON, forType: .string)
                    }.buttonStyle(.borderless)
                }
                if let failure { Text(failure).foregroundStyle(Studio.signal) }
                Text(rawJSON).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                Text("Up to 200 raw and linked context records. Export the session to inspect all events.").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(20)
        }
        .task(id: action.id) {
            events = []
            failure = nil
            do {
                let evidenceStore = store
                let evidenceAction = action
                let result = try await Task.detached { try evidenceStore.evidence(for: evidenceAction, limit: 200) }.value
                if !Task.isCancelled { events = result }
            } catch { failure = error.localizedDescription }
        }
    }

    private var rawJSON: String { events.compactMap { try? TrailJSON.string($0) }.joined(separator: "\n\n") }
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, design: label.contains("Time") || label.contains("IDs") ? .monospaced : .default)).textSelection(.enabled)
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: RecordingModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Capture settings").font(.system(size: 24, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                settingsContent.padding(.trailing, 4)
            }.frame(maxHeight: 560)
            HStack {
                Text("Choices save immediately. Closing the window does not quit.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit AgentTrail") { NSApp.terminate(nil) }
            }
        }.padding(28).frame(width: 590).tint(Studio.signal)
        .onAppear { model.refreshPermissions() }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Start captures a temporary recording. Stop to review it, then choose Save recording to keep it or Discard to remove it. Nothing enters your library without Save.").font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(spacing: 12) {
                permission("Input Monitoring", detail: "Keyboard, pointer, buttons, and scroll", granted: model.hasInputPermission, action: model.requestInputPermission)
                permission("Accessibility", detail: "Application, window, and element context", granted: model.hasAccessibilityPermission, action: model.requestAccessibility)
                permission("Screen Recording", detail: "Only needed for optional screenshots", granted: model.hasScreenPermission, action: model.requestScreenPermission)
            }.padding(16).background(Studio.inset, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                Text("Already enabled in System Settings? Fully quit and reopen AgentTrail, then recheck. If access is still missing, remove only AgentTrail's stale permission entry and add this app copy again.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("Recheck access", action: model.refreshPermissions)
                    Button("Reveal this app") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }.font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("ALWAYS CAPTURED").font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
                Text("Key codes and modifiers • clicks and drags • cursor movement • scroll • timestamps • sampled app context")
                    .font(.system(size: 12)).lineSpacing(3)
                Text("Key codes can reconstruct what you type, even when literal text is off.").font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                Toggle("Include typed text and accessibility values", isOn: $model.options.captureText)
                Toggle("Include clipboard text (up to 16 KB per observation)", isOn: $model.options.captureClipboard)
                Toggle("Capture window screenshots after actions (up to 1 per second)", isOn: $model.options.captureScreenshots)
                Toggle("Read Excel workbook, sheet, and selected range", isOn: $model.options.excelContext)
                Text("Excel asks for Automation permission on its first sample. Sampling reads selection only and does not change your workbook.").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Only record these bundle IDs (empty = all apps)", text: Binding(get: { model.options.allowedBundleIDs.joined(separator: ", ") }, set: { model.options.allowedBundleIDs = split($0) }))
                TextField("Excluded bundle IDs", text: Binding(get: { model.options.excludedBundleIDs.joined(separator: ", ") }, set: { model.options.excludedBundleIDs = split($0) }))
                Text("Password managers listed here, secure input, and recorder controls are excluded. Password detection varies by app; pause for credentials. Local recordings are not encrypted by this app.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).disabled(model.isRecording || model.isFinalizing)
            if model.isRecording { Text("Stop the current recording to change capture options.").font(.caption).foregroundStyle(Studio.signal) }
        }
    }

    private func split(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "Settings" : "Enable", action: action).controlSize(.small)
        }
    }
}

struct AIView: View {
    @ObservedObject var model: RecordingModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Bring the history to your agent").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Save a recording, then export it and attach timeline.md to your AI conversation. The JSONL files preserve inputs, action boundaries, and observations for deeper analysis or training.")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            Text("“Find every fill-down shortcut and drag in this session. Show the recorded selection, the supporting event IDs, and anything the log cannot verify.”")
                .font(.system(size: 14)).padding(16).background(Studio.inset, in: RoundedRectangle(cornerRadius: 10)).textSelection(.enabled)
            Divider()
            Text("Connect the local MCP server").font(.system(size: 16, weight: .semibold))
            Text("For an MCP-compatible AI client, add this server configuration. It exposes three read-only tools: list sessions, search actions, and inspect raw events. Your AI client controls where the returned data goes.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            Text(configuration).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(16)
                .frame(maxWidth: .infinity, alignment: .leading).background(Studio.inset, in: RoundedRectangle(cornerRadius: 8))
            Button(copied ? "Copied" : "Copy MCP configuration") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(configuration, forType: .string)
                copied = true
            }
        }.padding(28).frame(width: 610).tint(Studio.signal)
    }

    private var configuration: String {
        let config: [String: Any] = ["mcpServers": ["agenttrail": ["command": Bundle.main.executableURL?.path ?? "AgentTrail", "args": ["--mcp", "--root", model.store.root.path]]]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
