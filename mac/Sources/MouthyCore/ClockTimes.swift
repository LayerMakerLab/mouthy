import Foundation

/// Clock times the recognizer wrote as anything but "11:58": with a period ("at 3.30"), run together ("at 1158",
/// "6 45 pm") or in words ("at eleven fifty-eight", "ten oh five p.m."). Only where the text says it is a time: after a
/// word that introduces one, or before a.m./p.m., and never before a unit, so prices, counts and measurements keep
/// their form.
public enum ClockTimes {
    static let units = "%|percent|dollars?|euros?|pounds?|cents?|each|apiece|per|a piece|kg|km|mm|cm|miles?|met(?:er|re)s?|inch(?:es)?|feet|times|people|items?|minutes?|hours?|seconds?|days?|years?"
    static let meridiem = "\\s?(?:a\\.?m\\.?|p\\.?m\\.?)(?![\\p{L}])"
    static let notUnit = "(?!\\s*(?:\(units))(?![\\p{L}]))"
    static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }

    // Digits: "at 3.30", "at 1158" and "it's 645." become "H:MM". Run-together digits only after at/until/till or a
    // clause-ending "it's" ("by 150", "around 250", "after 100" are usually counts), and never as :00 ("at 100", "it's 100").
    static let afterWord = regex("(?<![\\p{L}\\p{N}])((?:at|by|until|till|before|after|around) )(1[0-2]|0?[1-9])\\.([0-5][0-9])(?![\\p{N}]|\\.[\\p{N}])\(notUnit)")
    static let runTogether = regex("(?<![\\p{L}\\p{N}])((?:at|until|till) )(1[0-2]|[1-9])(0[1-9]|[1-5][0-9])(?![\\p{N}]|[.,][\\p{N}])\(notUnit)")
    static let itIs = regex("(?<![\\p{L}\\p{N}])((?:it['’]s|it is) )(1[0-2]|[1-9])(?:[. ]([0-5][0-9])|(?=0[1-9]|[1-5][0-9])([0-5][0-9]))(?=\\s*(?:[.,!?;]|$|(?:right )?now(?![\\p{L}])))")
    // A whole hour run together before a.m./p.m. is just the hour: "100 p.m." -> "1 p.m.", "1000 a.m." -> "10 a.m.".
    static let wholeHour = regex("(?<![\\p{N}.:])(1[0-2]|[1-9])00(?=\(meridiem))")
    static let beforeMeridiem = regex("(?<![\\p{N}.:])()(1[0-2]|0?[1-9])[. ]?([0-5][0-9])(?=\(meridiem))")

    // Words: an hour and its minutes ("eleven fifty-eight", "ten oh five", "six fifteen").
    static let hours = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                        "ten": 10, "eleven": 11, "twelve": 12]
    static let teens = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
                        "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]
    static let ones = "one|two|three|four|five|six|seven|eight|nine"
    static let spokenTime = "(\(hours.keys.joined(separator: "|"))) (?:oh (\(ones))|(\(teens.keys.joined(separator: "|")))|(\(tens.keys.joined(separator: "|")))(?:[- ](\(ones)))?)(?![\\p{L}\\p{N}-])(?![- ](?:\(ones)|hundred|thousand)(?![\\p{L}]))"
    static let wordsAfterCue = regex("(?<![\\p{L}\\p{N}])((?:at|by|until|till|before|after|around|about|from|it['’]s|it is) )\(spokenTime)\(notUnit)")
    static let wordsBeforeMeridiem = regex("(?<![\\p{L}\\p{N}])()\(spokenTime)(?=\(meridiem)|\\s?o['’]clock)")

    public static func apply(_ text: String) -> String {
        var output = text
        output = wholeHour.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "$1")
        for (regex, template) in [(afterWord, "$1$2:$3"), (runTogether, "$1$2:$3"), (itIs, "$1$2:$3$4"), (beforeMeridiem, "$1$2:$3")] {
            output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: template)
        }
        for regex in [wordsAfterCue, wordsBeforeMeridiem] { output = spoken(output, regex) }
        return attachedMeridiem(hourWords(output))
    }

    // "10am", "6:45PM." -> "10 a.m.", "6:45 p.m.": one way of writing a.m./p.m. whatever the recognizer chose.
    static let attached = regex("(?<![\\p{L}\\p{N}.:])((?:1[0-2]|0?[1-9])(?::[0-5][0-9])?)([ap])\\.?m\\.?(?![\\p{L}])")
    private static func attachedMeridiem(_ text: String) -> String {
        var output = text
        for match in attached.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
            guard let whole = Range(match.range, in: output), let time = Range(match.range(at: 1), in: output),
                  let mark = Range(match.range(at: 2), in: output) else { continue }
            output.replaceSubrange(whole, with: "\(output[time]) \(output[mark].lowercased()).m.")
        }
        return output
    }

    // A spoken hour on its own is a time only with a.m./p.m. or o'clock after it ("ten a.m." -> "10 a.m.", "one o'clock"
    // -> "1 o'clock"); "at one", "one idea" and "one, two, three" stay words. A bare "am" counts only after a word that
    // introduces a time or before punctuation, so "which one am I" stays.
    static let hourBeforeMark = regex("(?<![\\p{L}\\p{N}'’-])(\(hours.keys.joined(separator: "|")))(?=\\s?(?:a\\.m\\.?|p\\.?m\\.?|o['’]clock)(?![\\p{L}]))")
    static let hourBeforeAm = regex("(?<![\\p{L}\\p{N}'’-])(\(hours.keys.joined(separator: "|")))(?=\\s?am(?:[.,!?;]|$))")
    static let cueHourBeforeAm = regex("(?<=(?:at|by|until|till|before|after|around|about|from) )(\(hours.keys.joined(separator: "|")))(?=\\s?am(?![\\p{L}]))")
    private static func hourWords(_ text: String) -> String {
        var output = text
        for regex in [hourBeforeMark, hourBeforeAm, cueHourBeforeAm] {
            for match in regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
                guard let range = Range(match.range(at: 1), in: output), let hour = hours[output[range].lowercased()] else { continue }
                output.replaceSubrange(range, with: String(hour))
            }
        }
        return output
    }

    private static func spoken(_ text: String, _ regex: NSRegularExpression) -> String {
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: text).map { text[$0].lowercased() }
            }
            let digit = ones.split(separator: "|").map(String.init)
            func one(_ word: String?) -> Int { word.flatMap { digit.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 }
            guard let hourWord = group(2), let hour = hours[hourWord] else { continue }
            let minute: Int
            if let oh = group(3) { minute = one(oh) }
            else if let teen = group(4), let value = teens[teen] { minute = value }
            else if let ten = group(5), let value = tens[ten] { minute = value + one(group(6)) }
            else { continue }
            guard let whole = Range(match.range, in: output) else { continue }
            let cue = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            output.replaceSubrange(whole, with: cue + "\(hour):" + String(format: "%02d", minute))
        }
        return output
    }
}
