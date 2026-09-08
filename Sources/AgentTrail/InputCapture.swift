import AppKit
import Carbon
import TrailCore

final class InputCapture {
    var onEvent: ((TrailEvent) -> Void)?
    var sessionID = ""
    var includeText = false
    private let worker = CaptureRunLoop()
    private var buffer = InputEventBuffer()
    private var deliveryTimer: Timer?
    private var tap: CFMachPort?

    func start() throws {
        buffer = InputEventBuffer()
        updateForeground(NSWorkspace.shared.frontmostApplication)
        try worker.start { try self.installTap() }
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in self?.drain() }
        RunLoop.main.add(timer, forMode: .common)
        deliveryTimer = timer
    }

    private func installTap() throws -> (() -> Void) {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                   .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                   .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let capture = Unmanaged<InputCapture>.fromOpaque(pointer).takeUnretainedValue()
            capture.receive(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap,
                                             options: .listenOnly, eventsOfInterest: mask, callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw TrailError.message("Input capture is unavailable. Enable AgentTrail in System Settings → Privacy & Security → Input Monitoring, then relaunch AgentTrail.")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            throw TrailError.message("Could not create the input listener's run-loop source.")
        }
        tap = created
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        CGEvent.tapEnable(tap: created, enable: true)
        return {
            CGEvent.tapEnable(tap: created, enable: false)
            CFMachPortInvalidate(created)
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            self.tap = nil
        }
    }

    func stop(deliverPending: Bool = true) {
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        worker.stop()
        if deliverPending { drain() } else { _ = buffer.takeAll() }
    }

    func updateForeground(_ app: NSRunningApplication?) {
        buffer.updateForeground(CaptureForeground(app: app?.localizedName ?? "Unknown application",
                                                   bundleID: app?.bundleIdentifier ?? "pid:\(app?.processIdentifier ?? 0)"))
    }

    func togglePause() {
        buffer.togglePause(sessionID: sessionID)
        drain()
    }

    func drain() {
        var applications: [Int32: CaptureForeground] = [:]
        for var event in buffer.takeAll() {
            if let targetPID = event.fields["target_pid"].flatMap(Int32.init), targetPID > 0 {
                if applications[targetPID] == nil, let app = NSRunningApplication(processIdentifier: targetPID), let bundleID = app.bundleIdentifier {
                    applications[targetPID] = CaptureForeground(app: app.localizedName ?? "Unknown application", bundleID: bundleID)
                }
                if let app = applications[targetPID] {
                    event.app = app.app
                    event.bundleID = app.bundleID
                    event.fields["app_attribution"] = "cg_event_target_pid"
                } else {
                    var gap = TrailEvent(sessionID: event.sessionID, kind: "gap", timestamp: event.timestamp, monotonicNS: event.monotonicNS)
                    gap.fields["reason"] = "Event target could not be identified; input omitted for privacy"
                    onEvent?(gap)
                    continue
                }
            }
            onEvent?(event)
        }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            var gap = TrailEvent(sessionID: sessionID, kind: "gap")
            gap.fields["reason"] = type == .tapDisabledByTimeout
                ? "Input listener timed out; re-enabled. Some inputs may be missing."
                : "Input listener was disabled by macOS; re-enabled. Some inputs may be missing."
            gap.fields["cause"] = type == .tapDisabledByTimeout ? "tap_disabled_by_timeout" : "tap_disabled_by_user_input"
            buffer.append(gap)
            return
        }
        let timestamp = Date().timeIntervalSince1970
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, event.flags.contains([.maskCommand, .maskAlternate, .maskControl]), event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            if code == 35 { buffer.togglePause(sessionID: sessionID, timestamp: timestamp, monotonicNS: event.timestamp); return }
            if code == 46 { buffer.append(TrailEvent(sessionID: sessionID, kind: "marker_shortcut", timestamp: timestamp, monotonicNS: event.timestamp)); return }
        }
        if IsSecureEventInputEnabled() {
            var gap = TrailEvent(sessionID: sessionID, kind: "gap", timestamp: timestamp, monotonicNS: event.timestamp)
            gap.fields["reason"] = "Secure input is active"
            buffer.append(gap)
            return
        }
        let kind: String
        switch type {
        case .keyDown: kind = "key_down"
        case .keyUp: kind = "key_up"
        case .flagsChanged: kind = "flags_changed"
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = "mouse_down"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = "mouse_up"
        case .mouseMoved: kind = "mouse_move"
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = "mouse_drag"
        case .scrollWheel: kind = "scroll"
        default: return
        }
        var record = TrailEvent(sessionID: sessionID, kind: kind, timestamp: timestamp, monotonicNS: event.timestamp)
        let flagNames: [(CGEventFlags, String)] = [(.maskControl, "control"), (.maskAlternate, "option"), (.maskShift, "shift"), (.maskCommand, "command"), (.maskAlphaShift, "caps_lock"), (.maskSecondaryFn, "function")]
        record.modifiers = flagNames.filter { event.flags.contains($0.0) }.map { $0.1 }
        record.fields["source_pid"] = String(event.getIntegerValueField(.eventSourceUnixProcessID))
        record.fields["target_pid"] = String(event.getIntegerValueField(.eventTargetUnixProcessID))
        record.fields["clock"] = "cg_event_timestamp_ns"
        if kind.hasPrefix("key_") || kind == "flags_changed" {
            record.keyCode = code
            record.key = Self.keyNames[code] ?? "Key \(code)"
            record.fields["repeat"] = String(event.getIntegerValueField(.keyboardEventAutorepeat))
            record.fields["printable"] = String(Self.printableCodes.contains(code))
            if includeText, type == .keyDown, !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl) {
                var length = 0
                var buffer = [UniChar](repeating: 0, count: 64)
                event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
                if length > 0 { record.text = String(utf16CodeUnits: buffer, count: min(length, buffer.count)) }
            }
        } else {
            record.x = event.location.x
            record.y = event.location.y
            if kind == "scroll" {
                record.deltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                record.deltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                record.fields["continuous"] = String(event.getIntegerValueField(.scrollWheelEventIsContinuous))
            } else { record.button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) }
            record.fields["click_count"] = String(event.getIntegerValueField(.mouseEventClickState))
        }
        buffer.append(record)
    }

    static let keyNames: [Int: String] = [0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"−", 28:"8", 29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"Return", 37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"Tab", 49:"Space", 50:"`", 51:"Delete", 53:"Escape", 54:"Right Command", 55:"Command", 56:"Shift", 57:"Caps Lock", 58:"Option", 59:"Control", 60:"Right Shift", 61:"Right Option", 62:"Right Control", 63:"fn", 65:"Keypad .", 67:"Keypad *", 69:"Keypad +", 71:"Clear", 75:"Keypad /", 76:"Enter", 78:"Keypad −", 81:"Keypad =", 82:"Keypad 0", 83:"Keypad 1", 84:"Keypad 2", 85:"Keypad 3", 86:"Keypad 4", 87:"Keypad 5", 88:"Keypad 6", 89:"Keypad 7", 91:"Keypad 8", 92:"Keypad 9", 96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8", 101:"F9", 103:"F11", 109:"F10", 111:"F12", 115:"Home", 116:"Page Up", 117:"Forward Delete", 118:"F4", 119:"End", 120:"F2", 121:"Page Down", 122:"F1", 123:"←", 124:"→", 125:"↓", 126:"↑"]
    static let printableCodes: Set<Int> = Set(0...35).union(37...47).union([49, 50, 65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92])
}
