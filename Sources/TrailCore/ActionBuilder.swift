import Foundation

public final class ActionBuilder {
    private var pending: TrailAction?
    private var anchorX: Double?
    private var anchorY: Double?
    private var lastX: Double?
    private var lastY: Double?
    private var dragButton: Int?
    private var scrollX = 0.0
    private var scrollY = 0.0
    private var keyCount = 0
    private var typed = ""

    public init() {}

    public func consume(_ event: TrailEvent) -> [TrailAction] {
        var output: [TrailAction] = []
        if let current = pending,
           current.bundleID != event.bundleID || current.sessionID != event.sessionID ||
           (current.kind != "drag" && current.kind != "click" && event.timestamp - current.endedAt > 1.0) {
            output += flush()
        }
        switch event.kind {
        case "key_up", "flags_changed", "context", "screenshot":
            return output
        case "mouse_down":
            output += flush()
            pending = TrailAction(event: event, kind: "click", summary: "Click")
            anchorX = event.x
            anchorY = event.y
            lastX = event.x
            lastY = event.y
            dragButton = event.button
        case "mouse_drag":
            if pending?.kind != "click" && pending?.kind != "drag" {
                output += flush()
                pending = TrailAction(event: event, kind: "drag", summary: "Drag (start outside capture)")
                anchorX = event.x
                anchorY = event.y
                dragButton = event.button
            } else {
                extend(event)
            }
            pending?.kind = "drag"
            lastX = event.x
            lastY = event.y
            updatePointerSummary()
        case "mouse_up":
            if pending?.kind == "click" || pending?.kind == "drag" {
                extend(event)
                lastX = event.x
                lastY = event.y
                updatePointerSummary()
                output += flush()
            } else {
                output += flush()
                output.append(TrailAction(event: event, kind: "release", summary: "Release mouse button \(event.button ?? 0)"))
            }
        case "mouse_move":
            if pending?.kind != "move" {
                output += flush()
                pending = TrailAction(event: event, kind: "move", summary: "Move pointer")
                anchorX = event.x
                anchorY = event.y
            } else { extend(event) }
            lastX = event.x
            lastY = event.y
            updatePointerSummary()
        case "scroll":
            if pending?.kind != "scroll" {
                output += flush()
                pending = TrailAction(event: event, kind: "scroll", summary: "Scroll")
                scrollX = 0
                scrollY = 0
            } else { extend(event) }
            scrollX += event.deltaX ?? 0
            scrollY += event.deltaY ?? 0
            pending?.summary = "Scroll · horizontal \(Int(scrollX)), vertical \(Int(scrollY)) points"
        case "key_down":
            let isShortcut = event.modifiers.contains("command") || event.modifiers.contains("control") || event.modifiers.contains("option")
            let printable = event.fields["printable"] == "true"
            if isShortcut || !printable {
                output += flush()
                var action = TrailAction(event: event, kind: "shortcut", summary: Self.chord(event))
                if event.bundleID == "com.microsoft.Excel", event.modifiers.contains("command"), event.keyCode == 2 {
                    action.inference = "Possible Excel fill-down shortcut. The input was observed; the workbook mutation was not verified."
                }
                output.append(action)
            } else {
                if pending?.kind != "typing" {
                    output += flush()
                    pending = TrailAction(event: event, kind: "typing", summary: "Type")
                    keyCount = 0
                    typed = ""
                } else { extend(event) }
                keyCount += 1
                typed = String((typed + (event.text ?? "")).prefix(512))
                pending?.summary = typed.isEmpty ? "Type · \(keyCount) key presses (text not collected)" : "Type · \(typed.prefix(512))"
            }
        default:
            output += flush()
            let summary: String
            switch event.kind {
            case "app_focus": summary = "Switch to \(event.app)"
            case "window_resize":
                let title = event.windowTitle.map { " · \($0)" } ?? ""
                if let before = event.previousWindowFrame, let after = event.windowFrame {
                    summary = "Resize window\(title) · \(Int(before.width))×\(Int(before.height)) → \(Int(after.width))×\(Int(after.height))"
                } else {
                    summary = "Resize window\(title)"
                }
            case "marker": summary = "Bookmark · \(event.text ?? "Moment to review")"
            case "clipboard": summary = "Clipboard changed · \(event.text.map { String($0.prefix(160)) } ?? "content not collected")"
            case "gap": summary = CaptureGap.summary(event.fields["reason"] ?? "unavailable")
            case "pause": summary = "Recording paused"
            case "resume": summary = "Recording resumed"
            case "session_start": summary = "Recording started"
            case "session_end": summary = "Recording stopped"
            default: summary = event.kind.replacingOccurrences(of: "_", with: " ")
            }
            output.append(TrailAction(event: event, kind: event.kind, summary: summary))
        }
        return output
    }

    public func flush() -> [TrailAction] {
        defer { pending = nil }
        return pending.map { [$0] } ?? []
    }

    private func extend(_ event: TrailEvent) {
        pending?.endedAt = event.timestamp
        pending?.lastEventID = event.id
        pending?.eventCount += 1
    }

    private func updatePointerSummary() {
        let origin = "(\(Int(anchorX ?? 0)), \(Int(anchorY ?? 0)))"
        let destination = "(\(Int(lastX ?? 0)), \(Int(lastY ?? 0)))"
        switch pending?.kind {
        case "click": pending?.summary = "\(dragButton == 1 ? "Right-click" : "Click") at \(origin)"
        case "drag": pending?.summary = "Drag \(origin) → \(destination) · button \(dragButton ?? 0)"
        default: pending?.summary = "Move pointer \(origin) → \(destination)"
        }
    }

    public static func chord(_ event: TrailEvent) -> String {
        let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘", "caps_lock": "⇪", "function": "fn "]
        return event.modifiers.map { symbols[$0] ?? $0 }.joined() + (event.key ?? "Key \(event.keyCode ?? 0)")
    }
}
