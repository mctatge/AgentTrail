import Foundation

public enum RawLog {
    @discardableResult
    public static func write(store: TrailStore, sessionID: String, afterID: Int64 = 0, output: (Data) throws -> Void) throws -> Int64 {
        _ = try store.session(sessionID)
        var cursor = afterID
        while true {
            let page = try store.events(sessionID: sessionID, afterID: cursor, limit: 1000)
            if page.isEmpty { return cursor }
            for event in page {
                var data = try TrailJSON.encode(event)
                data.append(10)
                try output(data)
                cursor = event.id
            }
        }
    }
}
