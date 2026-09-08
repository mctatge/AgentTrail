import Foundation

public enum DemoSession {
    @discardableResult
    public static func create(in store: TrailStore) throws -> Session {
        var session = Session(title: "Example · Spreadsheet demonstration", metadata: ["synthetic": "true", "schema_version": "1"])
        session.startedAt -= 38
        try store.saveSession(session)
        let builder = ActionBuilder()
        var context = ElementContext(app: "Microsoft Excel", bundleID: "com.microsoft.Excel", source: "synthetic_example")
        context.window = "Quarterly forecast.xlsx"
        context.workbook = "Quarterly forecast.xlsx"
        context.worksheet = "Forecast"
        context.selection = "B2:B10"
        context.role = "AXLayoutArea"
        context.label = "Content Area"
        context.observedAt = session.startedAt + 7.9
        func add(_ kind: String, at offset: Double, configure: (inout TrailEvent) -> Void = { _ in }) throws {
            var event = TrailEvent(sessionID: session.id, kind: kind, timestamp: session.startedAt + offset,
                                   monotonicNS: UInt64(offset * 1_000_000_000), app: context.app, bundleID: context.bundleID)
            event.context = context
            configure(&event)
            let saved = try store.append(event)
            for action in builder.consume(saved) { try store.append(action) }
        }
        try store.transaction {
            try add("session_start", at: 0)
            try add("app_focus", at: 1)
            try add("mouse_down", at: 4) { $0.x = 336; $0.y = 284; $0.button = 0 }
            for step in 1...90 {
                try add("mouse_drag", at: 4 + Double(step) / 60) { $0.x = 336; $0.y = 284 + Double(step) * 2; $0.button = 0 }
            }
            try add("mouse_up", at: 5.6) { $0.x = 336; $0.y = 464; $0.button = 0 }
            try add("key_down", at: 8) { $0.keyCode = 2; $0.key = "D"; $0.modifiers = ["command"] }
            try add("key_up", at: 8.1) { $0.keyCode = 2; $0.key = "D"; $0.modifiers = ["command"] }
            try add("marker", at: 12) { $0.text = "Check how fill-down handled the selected range" }
            context.selection = "C2"
            context.observedAt = session.startedAt + 15
            for step in 0..<6 {
                try add("key_down", at: 16 + Double(step) / 5) { $0.key = "Key 18"; $0.keyCode = 18; $0.fields["printable"] = "true" }
            }
            try add("key_down", at: 18) { $0.key = "Return"; $0.keyCode = 36 }
            for step in 0..<15 {
                try add("scroll", at: 20 + Double(step) / 20) { $0.deltaY = -8; $0.deltaX = 0 }
            }
            try add("key_down", at: 25) { $0.keyCode = 6; $0.key = "Z"; $0.modifiers = ["command"] }
            try add("pause", at: 27)
            try add("resume", at: 32)
            for step in 0..<120 {
                try add("mouse_move", at: 33 + Double(step) / 50) {
                    $0.x = 440 + Double(step) * 2
                    $0.y = 330 + sin(Double(step) / 22) * 90
                }
            }
            try add("mouse_down", at: 35.5) { $0.x = 678; $0.y = 330 + sin(119.0 / 22) * 90; $0.button = 1 }
            try add("mouse_up", at: 35.6) { $0.x = 678; $0.y = 330 + sin(119.0 / 22) * 90; $0.button = 1 }
            try add("session_end", at: 37)
            for action in builder.flush() { try store.append(action) }
            session.status = "complete"
            session.endedAt = session.startedAt + 37
            try store.saveSession(session)
        }
        return try store.session(session.id)
    }
}
