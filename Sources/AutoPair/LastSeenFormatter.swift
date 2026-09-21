import Foundation

enum LastSeenFormatter {
    static func string(lastSeenAt: Date?, isConnected: Bool, now: Date = Date()) -> String {
        if isConnected { return "Now" }
        guard let lastSeenAt else { return "Unknown" }

        let seconds = max(0, now.timeIntervalSince(lastSeenAt))
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }

        let days = Int(seconds / 86_400)
        if days < 7 { return phrase(days, "day") }
        if days < 30 { return phrase(days / 7, "week") }
        if days < 365 { return phrase(days / 30, "month") }
        return phrase(days / 365, "year")
    }

    private static func phrase(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }
}
