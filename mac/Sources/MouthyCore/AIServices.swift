import Foundation

/// The AI subscriptions the person says they pay for (setup and Settings ask). The notch's AI usage tab shows only
/// these. What Mouthy can read is whatever the service's own tool already writes on this Mac: nothing is fetched,
/// nothing is logged in to, nothing costs anything.
public enum AIService: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, chatgpt, opencode, gemini, cursor, grok
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .opencode: "OpenCode Go"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        case .grok: "Grok"
        }
    }

    /// The mark in the middle of the ring (SF Symbols, drawn for Mouthy; no company logos).
    public var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .chatgpt: "circle.hexagonpath"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        case .gemini: "sparkles"
        case .cursor: "cursorarrow.rays"
        case .grok: "bolt.circle"
        }
    }

    /// Whether this Mac holds the service's limit percentages (or enough to work them out); the others show only
    /// whether they are in use.
    public var showsLimits: Bool { self == .claude || self == .chatgpt || self == .opencode }

    /// Where the numbers come from, in plain words for Settings.
    public var source: String {
        switch self {
        case .claude: "Claude Code's 5-hour and weekly limits."
        case .chatgpt: "Codex's 5-hour and weekly limits."
        case .opencode: "OpenCode's costs on this Mac against Go's limits."
        case .gemini, .cursor, .grok: "Shows when it's in use. Its limits aren't kept on this Mac."
        }
    }
}

/// Awake or asleep: a service is awake while its tool keeps writing, and falls asleep this long after the last write.
public enum AIActivity {
    public static let awakeFor: TimeInterval = 10 * 60
    public static func isAwake(lastActivity: Date?, now: Date = Date()) -> Bool {
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) < awakeFor && lastActivity <= now.addingTimeInterval(60)
    }
}

/// The share of a ring that is filled for a percentage used: exactly proportional (25% is a quarter), clamped to 0…1,
/// full at 100% (maxed out).
public func ringFill(percent: Double) -> Double {
    guard percent.isFinite else { return 0 }
    return min(1, max(0, percent / 100))
}

/// OpenCode Go meters usage in dollars at each model's rate and caps it per window. Published limits for the base Go
/// plan (opencode.ai/docs/go, 2026-11): $12 per rolling 5 hours, $30 per week, $60 per month. Mouthy sums the costs
/// OpenCode records on this Mac, so use from other machines on the same account is not counted.
public enum OpenCodeGo {
    public static let fiveHourLimit = 12.0, weekLimit = 30.0, monthLimit = 60.0

    /// Percent of each window used by `costs` (time, dollars), as of `now`; rolling windows.
    public static func percents(costs: [(date: Date, dollars: Double)], now: Date = Date()) -> (fiveHour: Double, week: Double, month: Double) {
        func spent(_ seconds: TimeInterval) -> Double {
            costs.reduce(0) { $1.date > now.addingTimeInterval(-seconds) && $1.date <= now ? $0 + max(0, $1.dollars) : $0 }
        }
        return (spent(5 * 3600) / fiveHourLimit * 100, spent(7 * 86400) / weekLimit * 100, spent(30 * 86400) / monthLimit * 100)
    }

    /// When the oldest cost still inside a rolling window leaves it: the moment that window's percent first drops.
    public static func nextDrop(costs: [(date: Date, dollars: Double)], window: TimeInterval, now: Date = Date()) -> Date? {
        costs.filter { $0.date > now.addingTimeInterval(-window) && $0.date <= now && $0.dollars > 0 }
            .map(\.date).min().map { $0.addingTimeInterval(window) }
    }
}
