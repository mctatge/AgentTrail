import Foundation
import TrailCore

enum CLI {
    static func run(_ arguments: [String], root: URL) throws {
        guard let command = arguments.first else { return }
        if ["--help", "-h", "help"].contains(command) {
            print("""
                AgentTrail — record demonstrations for computer-use agents

                AgentTrail                              Open the recording workspace
                AgentTrail --open-demo                   Open a synthetic example (no capture)
                AgentTrail list                         List sessions as JSON
                AgentTrail timeline SESSION [QUERY]     Search actions as JSON (first 500)
                AgentTrail events SESSION [AFTER_ID]     Read raw events as JSON (first 500)
                AgentTrail raw SESSION [--follow]        Stream all raw records as JSONL
                AgentTrail export SESSION NEW_FOLDER    Export a finished dataset
                AgentTrail demo                         Create a synthetic example
                AgentTrail --mcp                        Serve read-only MCP over stdio

                Add --root PATH to use a different local library.
                Run the packaged .app for stable macOS permission identity.
                """)
            return
        }
        if command == "demo" {
            let lease = try WriterLease(root: root)
            try withExtendedLifetime(lease) {
                let store = try TrailStore(root: root)
                print(try TrailJSON.string(DemoSession.create(in: store)))
            }
            return
        }
        let store = try TrailStore(root: root, readOnly: true)
        switch command {
        case "--mcp": MCPServer(store: store).run()
        case "list": print(try TrailJSON.string(store.sessions()))
        case "timeline":
            guard arguments.count >= 2 else { throw TrailError.message("Usage: AgentTrail timeline SESSION [QUERY]") }
            _ = try store.session(arguments[1])
            print(try TrailJSON.string(store.actions(sessionID: arguments[1], query: arguments.dropFirst(2).joined(separator: " "))))
        case "events":
            guard arguments.count >= 2 else { throw TrailError.message("Usage: AgentTrail events SESSION [AFTER_ID]") }
            _ = try store.session(arguments[1])
            let afterID = arguments.count > 2 ? Int64(arguments[2]) : 0
            guard let afterID, afterID >= 0 else { throw TrailError.message("AFTER_ID must be a nonnegative integer") }
            print(try TrailJSON.string(store.events(sessionID: arguments[1], afterID: afterID)))
        case "export":
            guard arguments.count == 3 else { throw TrailError.message("Usage: AgentTrail export SESSION NEW_FOLDER") }
            let destination = URL(fileURLWithPath: (arguments[2] as NSString).expandingTildeInPath)
            try SessionExport.write(store: store, sessionID: arguments[1], destination: destination)
            print(destination.path)
        case "raw":
            guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--follow") else {
                throw TrailError.message("Usage: AgentTrail raw SESSION [--follow]")
            }
            var cursor: Int64 = 0
            repeat {
                cursor = try RawLog.write(store: store, sessionID: arguments[1], afterID: cursor) { data in
                    try FileHandle.standardOutput.write(contentsOf: data)
                }
                guard arguments.contains("--follow") else { break }
                let session = try store.session(arguments[1])
                if session.status != "recording" && session.status != "paused" {
                    try RawLog.write(store: store, sessionID: arguments[1], afterID: cursor) { data in
                        try FileHandle.standardOutput.write(contentsOf: data)
                    }
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            } while true
        default: throw TrailError.message("Unknown command. Run AgentTrail --help.")
        }
    }
}
