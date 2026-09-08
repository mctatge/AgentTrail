import Foundation

public enum CaptureGap {
    public static func isIntentional(_ reason: String) -> Bool {
        ["Recorder controls excluded", "Application excluded by capture settings", "Secure input is active", "Password field focused"].contains(reason)
    }

    public static func summary(_ reason: String) -> String {
        if reason == "Recorder controls excluded" { return "Not recorded · AgentTrail controls (intentional)" }
        return "\(isIntentional(reason) ? "Not recorded" : "Capture gap") · \(reason)"
    }

    public static func normalizeLegacySummary(_ summary: String) -> String {
        let prefix = "Capture gap · "
        guard summary.hasPrefix(prefix) else { return summary }
        return self.summary(String(summary.dropFirst(prefix.count)))
    }
}
