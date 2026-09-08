import AppKit
import ApplicationServices
import TrailCore

final class ContextResolver {
    private let queue = DispatchQueue(label: "agenttrail.accessibility", qos: .utility)
    private var busy = false

    func request(app: NSRunningApplication, point: CGPoint?, includeText: Bool, completion: @escaping (ElementContext) -> Void) {
        guard !busy else { return }
        busy = true
        let name = app.localizedName ?? "Unknown application"
        let bundle = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
        let pid = app.processIdentifier
        queue.async {
            let context = self.read(name: name, bundle: bundle, pid: pid, point: point, includeText: includeText)
            DispatchQueue.main.async {
                self.busy = false
                completion(context)
            }
        }
    }

    private func read(name: String, bundle: String, pid: Int32, point: CGPoint?, includeText: Bool) -> ElementContext {
        var context = ElementContext(app: name, bundleID: bundle, pid: pid)
        guard AXIsProcessTrusted() else {
            context.error = "Accessibility permission unavailable"
            return context
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        let window = element(application, kAXFocusedWindowAttribute)
        context.window = window.flatMap { string($0, kAXTitleAttribute) }
        let focused = element(application, kAXFocusedUIElementAttribute)
        context.secure = focused.map { string($0, kAXSubroleAttribute) == "AXSecureTextField" || string($0, kAXRoleAttribute) == "AXSecureTextField" } ?? false
        if context.secure { return context }
        var target = focused
        if let point {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success { target = hit }
        }
        if let target {
            if string(target, kAXSubroleAttribute) == "AXSecureTextField" {
                context.secure = true
                return context
            }
            context.role = string(target, kAXRoleAttribute)
            context.label = string(target, kAXTitleAttribute) ?? string(target, kAXDescriptionAttribute)
            if includeText { context.value = string(target, kAXValueAttribute).map { String($0.prefix(4096)) } }
            if let position = value(target, kAXPositionAttribute), let size = value(target, kAXSizeAttribute),
               CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                var origin = CGPoint.zero
                var dimensions = CGSize.zero
                if AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
                    context.bounds = [origin.x, origin.y, dimensions.width, dimensions.height]
                }
            }
        }
        if bundle == "com.microsoft.Excel", let window {
            var remaining = 180
            let deadline = Date().addingTimeInterval(0.25)
            context.selection = findNameBox(window, remaining: &remaining, deadline: deadline)
        }
        context.observedAt = Date().timeIntervalSince1970
        return context
    }

    private func findNameBox(_ node: AXUIElement, remaining: inout Int, deadline: Date) -> String? {
        guard remaining > 0, Date() < deadline else { return nil }
        remaining -= 1
        let role = string(node, kAXRoleAttribute)
        let label = string(node, kAXDescriptionAttribute) ?? string(node, kAXTitleAttribute) ?? ""
        if role == "AXComboBox", label.localizedCaseInsensitiveContains("name"), let address = string(node, kAXValueAttribute) {
            return address
        }
        guard let children = value(node, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let address = findNameBox(child, remaining: &remaining, deadline: deadline) { return address }
        }
        return nil
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
}

final class ExcelResolver {
    private let queue = DispatchQueue(label: "agenttrail.excel", qos: .utility)
    private var busy = false
    private var permissionDenied = false

    func reset() { permissionDenied = false }

    func request(completion: @escaping (ElementContext) -> Void) {
        guard !busy, !permissionDenied else { return }
        busy = true
        queue.async {
            let script = """
                with timeout of 2 seconds
                    tell application id "com.microsoft.Excel"
                        if not running then return {"", "", ""}
                        if (count of workbooks) is 0 then return {"", "", ""}
                        return {name of active workbook, name of active sheet, get address selection}
                    end tell
                end timeout
                """
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            var context = ElementContext(app: "Microsoft Excel", bundleID: "com.microsoft.Excel", source: "excel_applescript")
            if let error {
                context.error = error[NSAppleScript.errorMessage] as? String ?? "Excel context unavailable"
            } else if let result, result.numberOfItems == 3 {
                context.workbook = result.atIndex(1)?.stringValue
                context.worksheet = result.atIndex(2)?.stringValue
                context.selection = result.atIndex(3)?.stringValue
            }
            let denied = error?[NSAppleScript.errorNumber] as? Int == -1743
            DispatchQueue.main.async {
                self.busy = false
                self.permissionDenied = denied
                completion(context)
            }
        }
    }
}
