import AppKit
import ApplicationServices
import TrailCore

/// Observes the focused window in the frontmost recorded application.
///
/// Accessibility notifications are the primary signal. A common-mode timer
/// also samples the same AX window so applications that do not emit a resize
/// notification still contribute observed geometry changes. This class only
/// reports a size change; pointer input remains the separate evidence for the
/// gesture that may have caused it.
final class WindowGeometryObserver {
    var sessionID = ""
    var onEvent: ((TrailEvent) -> Void)?

    private let tracker = WindowGeometryTracker()
    private var app: NSRunningApplication?
    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var windowIdentity = ""
    private var observer: AXObserver?
    private var observerSource: CFRunLoopSource?
    private var pollTimer: Timer?

    deinit { stop() }

    func start(app: NSRunningApplication?) {
        guard let app, app.processIdentifier > 0, AXIsProcessTrusted() else {
            stop()
            return
        }
        observe(app: app)
    }

    func observe(app: NSRunningApplication) {
        guard app.processIdentifier > 0, AXIsProcessTrusted() else {
            stop()
            return
        }

        if self.app?.processIdentifier != app.processIdentifier {
            stop()
            self.app = app
            appElement = AXUIElementCreateApplication(app.processIdentifier)
            if let appElement { AXUIElementSetMessagingTimeout(appElement, 0.15) }
            installObserver(for: app.processIdentifier)
        } else {
            self.app = app
        }

        if pollTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
        refreshWindow()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let observer, let appElement {
            AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
        }
        if let observer, let windowElement {
            AXObserverRemoveNotification(observer, windowElement, kAXResizedNotification as CFString)
        }
        if let observerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), observerSource, .commonModes)
        }

        observer = nil
        observerSource = nil
        appElement = nil
        windowElement = nil
        app = nil
        windowIdentity = ""
        tracker.reset()
    }

    private func installObserver(for pid: pid_t) {
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &created) == .success, let created else { return }
        observer = created
        let source = AXObserverGetRunLoopSource(created)
        observerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        if let appElement {
            _ = AXObserverAddNotification(created, appElement, kAXFocusedWindowChangedNotification as CFString, context)
        }
    }

    private var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private static let axCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let owner = Unmanaged<WindowGeometryObserver>.fromOpaque(refcon).takeUnretainedValue()
        owner.handle(element: element, notification: notification as String)
    }

    private func handle(element: AXUIElement, notification: String) {
        if notification == (kAXFocusedWindowChangedNotification as String) {
            refreshWindow()
        } else if notification == (kAXResizedNotification as String), sameElement(element, windowElement) {
            emitIfChanged(source: "accessibility_notification")
        }
    }

    private func poll() {
        guard app != nil else { return }
        refreshWindow()
        emitIfChanged(source: "accessibility_poll")
    }

    private func refreshWindow() {
        guard let appElement, let focused = element(appElement, kAXFocusedWindowAttribute) else {
            detachWindow()
            return
        }
        guard !sameElement(focused, windowElement) else { return }

        detachWindow()
        windowElement = focused
        windowIdentity = UUID().uuidString.lowercased()
        AXUIElementSetMessagingTimeout(focused, 0.15)
        if let observer {
            _ = AXObserverAddNotification(observer, focused, kAXResizedNotification as CFString, context)
        }
        _ = snapshot(focused).map { tracker.observe($0) }
    }

    private func detachWindow() {
        if let observer, let windowElement {
            AXObserverRemoveNotification(observer, windowElement, kAXResizedNotification as CFString)
        }
        windowElement = nil
        windowIdentity = ""
        tracker.reset()
    }

    private func emitIfChanged(source: String) {
        guard let windowElement, let snapshot = snapshot(windowElement),
              let change = tracker.observe(snapshot) else { return }

        var event = TrailEvent(sessionID: sessionID, kind: "window_resize",
                               timestamp: Date().timeIntervalSince1970,
                               monotonicNS: DispatchTime.now().uptimeNanoseconds,
                               app: change.current.app, bundleID: change.current.bundleID)
        event.windowTitle = change.current.windowTitle
        event.windowFrame = change.current.frame
        event.previousWindowFrame = change.previous.frame
        event.fields["source"] = source
        event.fields["window_pid"] = String(change.current.pid)
        event.fields["change"] = "window_bounds_changed"
        onEvent?(event)
    }

    private func snapshot(_ window: AXUIElement) -> WindowGeometrySnapshot? {
        guard let app,
              let position = value(window, kAXPositionAttribute),
              let size = value(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width >= 0, dimensions.height >= 0 else { return nil }

        return WindowGeometrySnapshot(
            identity: windowIdentity,
            app: app.localizedName ?? "Unknown application",
            bundleID: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
            pid: app.processIdentifier,
            windowTitle: string(window, kAXTitleAttribute),
            frame: WindowFrame(x: origin.x, y: origin.y, width: dimensions.width, height: dimensions.height)
        )
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(parent, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return CFEqual(lhs, rhs)
        default: return false
        }
    }
}
