import Foundation

/// Local usage counts (no text is stored): words dictated, sessions and speaking time.
public struct UsageStats: Codable, Equatable {
    public var words = 0
    public var sessions = 0
    public var speakingSeconds: Double = 0
    public var since = Date()
    public init() {}

    /// Typing speed assumed for "time saved" (a common average).
    public static let typingWordsPerMinute: Double = 40

    public mutating func record(text: String, seconds: Double) {
        let count = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        guard count > 0 else { return }
        words += count; sessions += 1; speakingSeconds += max(0, seconds)
    }
    /// Speaking speed in words per minute.
    public var wordsPerMinute: Int { speakingSeconds >= 1 ? Int((Double(words) / speakingSeconds * 60).rounded()) : 0 }
    /// Minutes saved compared with typing the same words.
    public var minutesSaved: Int { max(0, Int((Double(words) / Self.typingWordsPerMinute - speakingSeconds / 60).rounded())) }
}
