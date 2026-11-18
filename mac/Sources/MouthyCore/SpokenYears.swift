import Foundation

/// Years the recognizer wrote in words: "twenty nineteen" -> "2019", "nineteen ninety-eight" -> "1998",
/// "nineteen oh five" -> "1905", "nineteen hundred" -> "1900" (not "eighteen hundred and fifty", a number),
/// "two thousand nine" -> "2009". Only the shapes people
/// use for years (a century word with two more digits, or "two thousand" and a number below a hundred), never inside a
/// longer run of numbers ("eighteen, nineteen, twenty" or "two thousand five hundred") and never before a unit, so
/// counts and prices keep their form.
public enum SpokenYears {
    static let ones = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    static let teens = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
                        "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let centuries = ["eighteen": 18, "nineteen": 19, "twenty": 20]
    static func alternation(_ words: [String: Int]) -> String { words.keys.sorted { $0.count > $1.count }.joined(separator: "|") }

    /// Any number word, so a year is never cut out of a longer number.
    static let numberWords = "\(alternation(ones))|\(alternation(teens))|\(alternation(tens))|hundred|thousand|million|oh|zero"
    static let numberWord = "(?:\(numberWords))(?![\\p{L}])"
    static let before = "(?<![\\p{L}\\p{N}'’-])(?<!\\b(?:\(numberWords))[ -])"
    static let after = "(?![\\p{L}\\p{N}'’-])(?![ -]\(numberWord))\(ClockTimes.notUnit)"
    /// Two digits after the century: "nineteen", "ninety-eight", "ninety eight", "oh five", "hundred".
    static let lastTwo = "(?:(\(alternation(tens)))(?:[- ](\(alternation(ones))))?|(\(alternation(teens)))|oh[- ](\(alternation(ones)))|(hundred)(?! and(?![\\p{L}])))"
    static let centuryYear = ClockTimes.regex("\(before)(\(alternation(centuries)))[- ]\(lastTwo)\(after)")
    /// "two thousand nine", "two thousand and nineteen", "two thousand twenty-five".
    static let thousandYear = ClockTimes.regex("\(before)two[- ]thousand(?: and)? (?:(\(alternation(tens)))(?:[- ](\(alternation(ones))))?|(\(alternation(teens)))|(\(alternation(ones))))\(after)")

    public static func apply(_ text: String) -> String {
        var output = text
        for match in centuryYear.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
            guard let whole = Range(match.range, in: output) else { continue }
            func word(_ index: Int) -> String? { Range(match.range(at: index), in: output).map { output[$0].lowercased() } }
            guard let century = word(1).flatMap({ centuries[$0] }) else { continue }
            let rest: Int
            if let ten = word(2).flatMap({ tens[$0] }) { rest = ten + (word(3).flatMap { ones[$0] } ?? 0) }
            else if let teen = word(4).flatMap({ teens[$0] }) { rest = teen }
            else if let one = word(5).flatMap({ ones[$0] }) { rest = one }
            else if word(6) != nil { rest = 0 }
            else { continue }
            output.replaceSubrange(whole, with: String(format: "%d%02d", century, rest))
        }
        for match in thousandYear.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
            guard let whole = Range(match.range, in: output) else { continue }
            func word(_ index: Int) -> String? { Range(match.range(at: index), in: output).map { output[$0].lowercased() } }
            let rest: Int
            if let ten = word(1).flatMap({ tens[$0] }) { rest = ten + (word(2).flatMap { ones[$0] } ?? 0) }
            else if let teen = word(3).flatMap({ teens[$0] }) { rest = teen }
            else if let one = word(4).flatMap({ ones[$0] }) { rest = one }
            else { continue }
            output.replaceSubrange(whole, with: String(2000 + rest))
        }
        return output
    }
}
