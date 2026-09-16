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

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let model: RecordingModel
    private let lease: WriterLease
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var subscription: AnyCancellable?
    private var terminationTimer: Timer?

    init(model: RecordingModel, lease: WriterLease) { self.model = model; self.lease = lease }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AgentTrail"
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
        guard model.currentSession != nil || model.isFinalizing else { return .terminateNow }
        guard terminationTimer == nil else { return .terminateLater }
        model.stop()
        terminationTimer = AppRunLoopTimer.schedule(interval: 0.1) { [weak self] timer in
            guard let self, self.model.currentSession == nil, !self.model.isFinalizing else { return }
            timer.invalidate()
            self.terminationTimer = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func start() { model.start() }
    @objc private func pause() { model.togglePause() }
    @objc private func stop() { model.stop() }
    @objc private func marker() { model.addMarker() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func updateStatus() {
        statusItem?.button?.title = model.isRecording ? (model.isPaused ? "Ⅱ AT" : "● AT") : "◉ AT"
        statusItem?.button?.contentTintColor = model.isRecording && !model.isPaused ? NSColor.systemRed : nil
        statusItem?.button?.toolTip = "AgentTrail · \(model.status)"
        let menu = NSMenu()
        menu.addItem(item("AgentTrail · \(model.status)", action: #selector(showWindow)))
        menu.addItem(.separator())
        if model.isRecording {
            menu.addItem(item(model.isPaused ? "Resume recording" : "Pause recording", action: #selector(pause)))
            menu.addItem(item("Add bookmark", action: #selector(marker)))
            menu.addItem(item("Finish session", action: #selector(stop)))
        } else if !model.isFinalizing { menu.addItem(item("Start recording", action: #selector(start))) }
        menu.addItem(item("Open workspace", action: #selector(showWindow)))
        menu.addItem(.separator())
        menu.addItem(item("Quit AgentTrail", action: #selector(quit)))
        statusItem?.menu = menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
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
