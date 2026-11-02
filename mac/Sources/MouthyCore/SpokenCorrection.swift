import Foundation

/// A spoken self-correction of one value, resolved before on-device polish (`DictationPolish`): "Thursday at three.
/// No, make it four." becomes "Thursday at four." The on-device model keeps both values (measured 2026-10-15), so the
/// correction is applied by rule first. Only a value of the same kind is replaced (a number or clock time, a day, a
/// month), only within the sentence the correction follows, and only when the corrected value ends its clause:
/// "No, four is too many" and "I mean it" stay as spoken. The correction must open a clause (after a period, comma,
/// semicolon or question mark), never follow a reporting verb ("she said, no, four") and never sit inside quotes,
/// so reported speech stays as spoken. Polish only: Mouthy's dictation text rules
/// (`TextPipeline`, shared/text-rules.json) do not use it.
public enum SpokenCorrection {
    enum Kind: Equatable { case number, day, month }

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "noon", "midnight",
    ]
    static let days: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "tonight"]
    static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                                      "october", "november", "december"]

    static let value = "(\\d{1,2}:\\d{2}|\\d+(?:[.,]\\d+)?%?|[A-Za-z]+(?:-[A-Za-z]+)?)"
    static let suffix = "((?:\\s*(?:[ap]\\.?m\\.?|o'clock))?)"
    /// "<lead> no, make it <value>", "sorry, make that <value>", "make that <value>", "I mean <value>", "no, <value>":
    /// the value must end its clause.
    static let correction = try! NSRegularExpression(pattern:
        "([.,;!?]\\s+)(?:(?:(?:no|sorry|actually|wait|oops)[,.!]?\\s+)+(?:(?:make it|make that|change it to|change that to|I mean)[,]?\\s+)?"
        + "|(?:make that|I mean)[,]?\\s+)" + value + suffix + "(?=\\s*(?:[.,;!?](?!\\d)|$))", options: [.caseInsensitive])
    static let token = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_:])" + value + suffix + "(?![\\p{L}\\p{N}_])", options: [.caseInsensitive])

    static func kind(_ word: String) -> Kind? {
        let lower = word.lowercased()
        if lower.first?.isNumber == true { return .number }
        let head = lower.split(separator: "-").first.map(String.init) ?? lower
        if numberWords.contains(head) { return .number }
        if days.contains(lower) { return .day }
        if months.contains(lower) { return .month }
        return nil
    }

    /// The text with each recognized correction applied; anything else unchanged.
    public static func apply(_ text: String) -> String {
        var output = text
        var searchFrom = 0
        while true {
            let ns = output as NSString
            guard searchFrom < ns.length,
                  let match = correction.firstMatch(in: output, range: NSRange(location: searchFrom, length: ns.length - searchFrom)) else { break }
            let newValue = ns.substring(with: match.range(at: 2))
            let newSuffix = ns.substring(with: match.range(at: 3))
            guard let kind = kind(newValue), !isReported(ns.substring(to: match.range.location)), let replaced = replaceLast(kind, in: ns.substring(to: match.range.location),
                                                                         with: newValue, suffix: newSuffix) else {
                searchFrom = match.range.location + max(1, match.range(at: 1).length)
                continue
            }
            let tail = ns.substring(from: match.range.location + match.range.length)
            output = replaced + tail
            searchFrom = (replaced as NSString).length
        }
        return output
    }

    static let reportingVerbs: Set<String> = ["said", "says", "told", "tells", "asked", "asks", "replied", "replies", "answered",
                                               "answers", "wrote", "writes", "yelled", "shouted", "added", "whispered"]
    /// The correction would sit in reported speech: right after a reporting verb ("she said, no, four", "he told me, make that three"), or inside an
    /// open quotation.
    static func isReported(_ head: String) -> Bool {
        let straight = head.filter { $0 == "\"" }.count
        let opens = head.filter { $0 == "\u{201C}" }.count, closes = head.filter { $0 == "\u{201D}" }.count
        if straight % 2 == 1 || opens > closes { return true }
        // "she said", "he told me", "Sam asked him": a reporting verb among the clause's last two words.
        let words = head.split(whereSeparator: { !$0.isLetter && $0 != "'" }).suffix(2).map { $0.lowercased() }
        return words.contains(where: reportingVerbs.contains)
    }

    /// `head` with its last value of `kind` in its last sentence replaced, or nil when that sentence has none.
    static func replaceLast(_ kind: Kind, in head: String, with newValue: String, suffix newSuffix: String) -> String? {
        let ns = head as NSString
        var sentenceStart = 0
        for (offset, character) in head.utf16.enumerated().reversed() where [46, 33, 63, 10].contains(character) {   // . ! ? \n
            // A decimal point or a clock time is no sentence end.
            if character == 46, offset + 1 < ns.length, let next = UnicodeScalar(ns.character(at: offset + 1)), CharacterSet.decimalDigits.contains(next) { continue }
            sentenceStart = offset + 1; break
        }
        let sentence = NSRange(location: sentenceStart, length: ns.length - sentenceStart)
        guard let last = token.matches(in: head, range: sentence).last(where: { Self.kind(ns.substring(with: $0.range(at: 1))) == kind }) else { return nil }
        let oldValue = ns.substring(with: last.range(at: 1))
        var value = newValue
        if oldValue.first?.isUppercase == true, kind == .number { value = value.prefix(1).uppercased() + value.dropFirst() }
        // A spoken "a.m."/"p.m." replaces the old one; without one, the old one stays.
        let range = newSuffix.isEmpty ? last.range(at: 1) : NSRange(location: last.range(at: 1).location,
                                                                     length: last.range(at: 1).length + last.range(at: 2).length)
        return ns.replacingCharacters(in: range, with: value + newSuffix)
    }
}
