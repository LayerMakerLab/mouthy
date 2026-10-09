import Foundation

/// A spoken command for the notch: a timer, a note, a reminder, or a question for Mouthy.
/// Pure text handling; nothing here runs the command.
public enum NotchCommand: Equatable, Sendable {
    case timer(seconds: Int)
    case note(String)
    case reminder(due: Date, text: String)
    case question(String)

    /// `requiresName` is true for ordinary dictation anywhere: only a transcript that starts with the whole
    /// word "Mouthy" (optionally followed by , . : or !; never "Mouthy's" or "Mouthy-like") is a command.
    /// False for the notch's own mic, where bare commands match too. Questions only ever match after the name. Anything else returns nil and stays text.
    public static func parse(_ text: String, now: Date, calendar: Calendar, requiresName: Bool) -> NotchCommand? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let named: Bool
        if let match = firstMatch(#"^mouthy(?=[\s,.:!]|$)[,.:!]?\s*"#, in: rest) {
            named = true
            rest = String(rest[match.range.upperBound...])
        } else {
            named = false
        }
        guard named || !requiresName, !rest.isEmpty else { return nil }
        let plain = rest.trimmingCharacters(in: trailing)
        if let command = timerCommand(plain) ?? noteCommand(plain) ?? reminderCommand(plain, now: now, calendar: calendar) { return command }
        guard named, isQuestion(rest) else { return nil }
        return .question(rest)
    }

    // MARK: Commands

    private static let trailing = CharacterSet(charactersIn: ".!?,;:").union(.whitespacesAndNewlines)
    private static let separators = #"[\s,:;.\-]+"#

    private static func timerCommand(_ text: String) -> NotchCommand? {
        let patterns = [
            #"^(?:(?:set|start)\s+)?(?:an?\s+)?timer(?:\s+(?:for|of))?"# + separators + #"(.+)$"#,
            #"^(?:(?:set|start)\s+)?(?:an?\s+)?(.+?)[\s\-]+timer$"#,
        ]
        for pattern in patterns {
            if let match = firstMatch(pattern, in: text), let spoken = match.groups[0],
               let seconds = duration(spoken), seconds <= 24 * 3600 {
                return .timer(seconds: seconds)
            }
        }
        return nil
    }

    private static func noteCommand(_ text: String) -> NotchCommand? {
        guard let match = firstMatch(#"^(?:note to self|take a note|make a note|note)"# + separators + #"(.+)$"#, in: text),
              let body = match.groups[0]?.trimmingCharacters(in: trailing), !body.isEmpty else { return nil }
        return .note(body)
    }

    private static func reminderCommand(_ text: String, now: Date, calendar: Calendar) -> NotchCommand? {
        // "remind me at 5 to call mom": the time comes first, then to/that/about and the text.
        if let match = firstMatch(#"^remind me(?:\s+(?:at|by))\s+(.+)$"#, in: text), let tail = match.groups[0] {
            for connector in matches(#"[\s,]+(?:to|that|about)\s+"#, in: tail) {
                let time = String(tail[..<connector.range.lowerBound])
                let body = String(tail[connector.range.upperBound...]).trimmingCharacters(in: trailing)
                if !body.isEmpty, let due = due(time, now: now, calendar: calendar) { return .reminder(due: due, text: body) }
            }
            return nil
        }
        // "remind me to call mom at 5": the text first, the time after the last "at".
        guard let match = firstMatch(#"^remind me\s+(?:(?:to|that|about)\s+)?(.+)\s+(?:at|by)\s+(.+)$"#, in: text),
              let body = match.groups[0]?.trimmingCharacters(in: trailing), !body.isEmpty,
              let time = match.groups[1], let due = due(time, now: now, calendar: calendar) else { return nil }
        return .reminder(due: due, text: body)
    }

    private static let questionWords: Set<String> = [
        "what", "what's", "whats", "who", "who's", "whose", "why", "how", "how's", "when", "where", "which",
    ]

    /// After the name: anything ending in a question mark, or opening with a question word.
    private static func isQuestion(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return true }
        let first = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? ""
        return questionWords.contains(first.replacingOccurrences(of: "\u{2019}", with: "'"))
    }

    // MARK: Durations

    private static let units: [String: Double] = [
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
    ]

    /// "10 minutes", "ten minutes", "an hour and a half", "1 hour 30 minutes", "half an hour", "1.5 hours".
    /// Every word has to be part of the duration, or this returns nil.
    static func duration(_ text: String) -> Int? {
        let words = text.lowercased().replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        var total = 0.0, index = 0
        var lastUnit: Double?
        func next(_ expected: String...) -> Bool {
            guard index + expected.count <= words.count, Array(words[index..<index + expected.count]) == expected else { return false }
            index += expected.count
            return true
        }
        while index < words.count {
            if let unit = lastUnit, next("and", "a", "half") || next("a", "half") { total += unit / 2; lastUnit = nil; continue }
            if next("and") { continue }
            if next("half", "an") || next("half", "a") {
                guard index < words.count, let unit = units[words[index]] else { return nil }
                total += unit / 2; index += 1; lastUnit = nil; continue
            }
            guard var amount = number(words, &index) else { return nil }
            if next("and", "a", "half") { amount += 0.5 }
            guard index < words.count, let unit = units[words[index]] else { return nil }
            total += amount * unit; index += 1; lastUnit = unit
        }
        guard total >= 1, total < 1_000_000_000 else { return nil }
        return Int(total.rounded())
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// One number at `index`: digits ("10", "1.5"), "a"/"an", or words up to ninety-nine ("twenty five").
    private static func number(_ words: [String], _ index: inout Int) -> Double? {
        guard index < words.count else { return nil }
        let word = words[index]
        if let value = Double(word), value.isFinite, value >= 0, value < 100_000 { index += 1; return value }
        if word == "a" || word == "an" { index += 1; return 1 }
        if let value = ones.firstIndex(of: word) { index += 1; return Double(value) }
        guard let ten = tens[word] else { return nil }
        index += 1
        if index < words.count, let one = ones.firstIndex(of: words[index]), (1...9).contains(one) { index += 1; return Double(ten + one) }
        return Double(ten)
    }

    // MARK: Times

    /// "5", "5 pm", "5:30", "5 p.m.", "17:45", "five", "five thirty", "noon", "midnight", "5 o'clock".
    /// A bare hour from 1 to 12 is its soonest 12-hour occurrence after `now`.
    private static func due(_ spoken: String, now: Date, calendar: Calendar) -> Date? {
        var text = spoken.lowercased().trimmingCharacters(in: trailing)
        var half: Int?
        if let match = firstMatch(#"\s*(a|p)\.?\s?m\.?$"#, in: text) {
            half = text[match.range].contains("p") ? 12 : 0
            text = String(text[..<match.range.lowerBound])
        }
        if let match = firstMatch(#"\s*o'?\s?clock$"#, in: text) { text = String(text[..<match.range.lowerBound]) }
        let hour: Int, minute: Int
        if text == "noon" || text == "midnight" { (hour, minute, half) = (12, 0, text == "noon" ? 12 : 0) }
        else if let match = firstMatch(#"^(\d{1,2})(?:[:.](\d{2}))?$"#, in: text), let h = match.groups[0].flatMap({ Int($0) }) {
            hour = h; minute = match.groups[1].flatMap { Int($0) } ?? 0
        } else {
            let words = text.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
            var index = 0
            guard let h = number(words, &index), words[0] != "a", words[0] != "an" else { return nil }
            var m = 0.0
            if index < words.count {
                if words[index] == "oh" { index += 1 }
                guard let value = number(words, &index), index == words.count else { return nil }
                m = value
            }
            guard h == h.rounded(), m == m.rounded() else { return nil }
            hour = Int(h); minute = Int(m)
        }
        guard (0..<60).contains(minute) else { return nil }
        let candidates: [Int]
        if let half {
            guard (1...12).contains(hour) else { return nil }
            candidates = [hour % 12 + half]
        } else if (1...12).contains(hour) {
            candidates = [hour % 12, hour % 12 + 12]
        } else {
            guard (0..<24).contains(hour) else { return nil }
            candidates = [hour]
        }
        let start = calendar.startOfDay(for: now)
        return [0, 1].flatMap { day in
            candidates.compactMap { hour -> Date? in
                guard let date = calendar.date(byAdding: .day, value: day, to: start) else { return nil }
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
            }
        }
        .filter { $0 > now }.min()
    }

    // MARK: Matching

    private struct Match { let range: Range<String.Index>; let groups: [String?] }

    private static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let groups = (1..<max(result.numberOfRanges, 1)).map { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
            return Match(range: range, groups: groups)
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? { matches(pattern, in: text).first }
}
