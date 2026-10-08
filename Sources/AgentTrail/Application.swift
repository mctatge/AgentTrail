import AppKit
import Combine
import SwiftUI
import TrailCore

@main
enum AgentTrailApplication {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var root = TrailStore.defaultRoot
        if let index = arguments.firstIndex(of: "--root") {
            guard arguments.indices.contains(index + 1) else { die("--root requires a path") }
            root = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
            arguments.removeSubrange(index...index + 1)
        }
        umask(0o077)
        do {
            if let command = arguments.first, command != "--open-demo" {
                try CLI.run(arguments, root: root)
                return
            }
            let lease = try WriterLease(root: root)
            let store = try TrailStore(root: root)
            let model = try RecordingModel(store: store)
            let delegate = ApplicationDelegate(model: model, lease: lease)
            let application = NSApplication.shared
            application.delegate = delegate
            application.setActivationPolicy(.regular)
            if arguments.first == "--open-demo", try store.sessions().isEmpty { model.createDemo() }
            withExtendedLifetime(delegate) { application.run() }
        } catch { die(error.localizedDescription) }
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data("AgentTrail: \(message)\n".utf8))
        exit(1)
    }
}

enum RecordingQuitChoice: Equatable { case save, discard, cancel }

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: RecordingModel
    private let lease: WriterLease
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var subscription: AnyCancellable?
    private var terminationTimer: Timer?
    private var awaitingTermination = false
    private let confirmQuit: (Bool) -> RecordingQuitChoice
    private let replyToQuit: (Bool) -> Void

    init(model: RecordingModel, lease: WriterLease,
         confirmQuit: @escaping (Bool) -> RecordingQuitChoice = ApplicationDelegate.askToQuit,
         replyToQuit: @escaping (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }) {
        self.model = model
        self.lease = lease
        self.confirmQuit = confirmQuit
        self.replyToQuit = replyToQuit
    }

    deinit { terminationTimer?.invalidate() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AgentTrail"
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        window.minSize = NSSize(width: 980, height: 690)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AgentTrailWorkspace")
        window.center()
        self.window = window
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatus()
        subscription = model.objectWillChange.debounce(for: .milliseconds(100), scheduler: RunLoop.main).sink { [weak self] _ in self?.updateStatus() }
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshPermissions() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !awaitingTermination else { return .terminateLater }
        // A Save already in progress was explicitly requested. Wait for its result;
        // a failure must leave the draft open instead of retrying or discarding it.
        if model.isSaving {
            awaitingTermination = true
            terminationTimer = AppRunLoopTimer.schedule(interval: 0.1) { [weak self] _ in
                guard let self, !self.model.isSaving else { return }
                self.finishTermination(!self.model.hasUnsavedRecording)
            }
            return .terminateLater
        }
        guard model.hasUnsavedRecording || model.currentSession != nil || model.isFinalizing else { return .terminateNow }
        let choice = confirmQuit(model.isRecording)
        guard choice != .cancel else { return .terminateCancel }
        // Ask before stopping, so Cancel leaves active capture unchanged.
        awaitingTermination = true
        model.stop()
        terminationTimer = AppRunLoopTimer.schedule(interval: 0.1) { [weak self] timer in
            guard let self, self.model.currentSession == nil, !self.model.isFinalizing, !self.model.isSaving else { return }
            timer.invalidate()
            self.terminationTimer = nil
            guard self.model.hasUnsavedRecording else { self.finishTermination(true); return }
            switch choice {
            case .save:
                self.model.saveRecording { [weak self] succeeded in self?.finishTermination(succeeded) }
            case .discard:
                self.model.discardRecording()
                self.finishTermination(!self.model.hasUnsavedRecording)
            case .cancel:
                self.finishTermination(false)
            }
        }
        return .terminateLater
    }

    private func finishTermination(_ allowed: Bool) {
        terminationTimer?.invalidate()
        terminationTimer = nil
        awaitingTermination = false
        replyToQuit(allowed)
        if !allowed { showWindow() }
    }

    static func askToQuit(isRecording: Bool) -> RecordingQuitChoice {
        let alert = NSAlert()
        alert.messageText = "Save this recording before quitting?"
        alert.informativeText = isRecording
            ? "Your recording is unsaved. Save and Quit stops recording and keeps it in your library. Discard and Quit removes it. Cancel continues recording."
            : "Your recording has not been saved. Save and Quit keeps it in your library. Discard and Quit removes it permanently."
        alert.addButton(withTitle: "Save and Quit")
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnsavedRecording else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep AgentTrail running?"
        alert.informativeText = model.isRecording
            ? "Closing this window keeps recording in the menu bar. Your recording remains unsaved until you stop and choose Save recording."
            : "Your recording remains temporary while AgentTrail is open. Use the AgentTrail menu-bar icon to return and save or discard it."
        alert.addButton(withTitle: "Keep running")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func start() { model.start() }
    @objc private func pause() { model.togglePause() }
    @objc private func stop() { model.stop() }
    @objc private func save() { model.saveRecording() }
    @objc private func marker() { model.addMarker() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func updateStatus() {
        statusItem?.button?.title = model.isRecording ? (model.isPaused ? "Ⅱ AT" : "● AT") : model.hasUnsavedRecording ? "◌ AT" : "◉ AT"
        statusItem?.button?.contentTintColor = model.isRecording && !model.isPaused ? NSColor.systemRed : model.hasUnsavedRecording ? NSColor.systemOrange : nil
        statusItem?.button?.toolTip = "AgentTrail · \(model.status)"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("AgentTrail · \(model.status)", action: #selector(showWindow)))
        menu.addItem(.separator())
        if model.isRecording {
            menu.addItem(item(model.isPaused ? "Resume recording" : "Pause recording", action: #selector(pause)))
            menu.addItem(item("Add bookmark", action: #selector(marker)))
            menu.addItem(item("Stop recording", action: #selector(stop)))
        } else if model.hasUnsavedRecording {
            menu.addItem(item("Save recording", action: #selector(save), enabled: !model.isFinalizing && !model.isSaving))
        }
        if model.hasUnsavedRecording {
            menu.addItem(item("Unsaved recording · review or discard…", action: #selector(showWindow)))
        }
        if !model.isRecording {
            menu.addItem(item("Start recording", action: #selector(start), enabled: !model.hasUnsavedRecording && !model.isFinalizing && !model.isSaving))
        }
        menu.addItem(item("Open workspace", action: #selector(showWindow)))
        menu.addItem(.separator())
        menu.addItem(item("Quit AgentTrail", action: #selector(quit)))
        statusItem?.menu = menu
    }

    private func item(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func buildMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(item("Open AgentTrail", action: #selector(showWindow)))
        appMenu.addItem(.separator())
        let quitItem = item("Quit AgentTrail", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        appMenu.addItem(quitItem)
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
