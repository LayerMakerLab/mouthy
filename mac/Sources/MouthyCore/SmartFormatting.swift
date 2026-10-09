import Foundation
import NaturalLanguage

/// Fits dictated text to the characters around the insertion point, like typing would:
/// a separating space, sentence-start capitalization, and a lowercase start mid-sentence.
public enum SmartInsertion {
    static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "-", "—", "@", "#", "$"]
    static let closers: Set<Character> = [".", ",", "!", "?", ":", ";", ")", "]", "}", "”", "’", "%"]
    static let sentenceEnds: Set<Character> = [".", "!", "?"]
    static let properWords: Set<String> = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "June", "July", "August", "September", "October", "November", "December"]

    public static func adjust(_ text: String, before: String, after: String) -> String {
        guard !text.isEmpty else { return text }
        var output = text
        let previous = before.last
        let lastVisible = before.last { !$0.isWhitespace }
        if lastVisible == nil || sentenceEnds.contains(lastVisible!) || before.hasSuffix("\n") {
            output = capitalizingFirstWord(output)
        } else if let lastVisible, lastVisible.isLetter || lastVisible.isNumber || lastVisible == "," || lastVisible == ";" || lastVisible == ":" {
            output = lowercasingFirstWord(output)
        }
        if let previous, !previous.isWhitespace, !openers.contains(previous),
           let start = output.first, start.isLetter || start.isNumber || openers.contains(start) {
            output = " " + output
        }
        if let next = after.first(where: { !$0.isWhitespace }), next.isLowercase, output.count > 1, output.last == "." {
            // The surrounding sentence continues after the cursor.
            output.removeLast()
        }
        if let next = after.first, next.isLetter || next.isNumber, let end = output.last, !end.isWhitespace, !openers.contains(end) {
            output += " "
        }
        if let next = after.first, closers.contains(next), output.count > 1, let end = output.last, sentenceEnds.contains(end) || end == "," {
            // The existing text already supplies the punctuation.
            output.removeLast()
        }
        return output
    }

    static let quoteOpeners: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘"]
    static let quoteClosers: Set<Character> = [")", "]", "}", "\"", "'", "”", "’"]
    /// Capitalizes the first word only when it starts with a letter: "20 minutes" and "$15 is" keep their case.
    public static func capitalizingFirstWord(_ text: String) -> String {
        guard let index = text.firstIndex(where: { !$0.isWhitespace && !quoteOpeners.contains($0) }),
              text[index].isLetter, text[index].isLowercase else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }

    static func lowercasingFirstWord(_ text: String) -> String {
        guard let index = text.firstIndex(where: { !$0.isWhitespace }), text[index].isUppercase else { return text }
        let word = text[index...].prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        // Keep "I", acronyms, mixed case (iPhone, McDonald) and recognized names.
        guard word.count > 1, word.dropFirst().allSatisfy({ $0.isLowercase || $0 == "'" || $0 == "’" }),
              !word.hasPrefix("I'"), !word.hasPrefix("I’"), !isName(String(word), in: text) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].lowercased())
    }

    static func isName(_ word: String, in text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        guard let range = text.range(of: word) else { return false }
        let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType)
        if let tag, [NLTag.personalName, .placeName, .organizationName].contains(tag) { return true }
        return properWords.contains(word)
    }
}

/// Removes hesitation fillers ("um", "uh", "erm") with the commas around them. A filler that opened a
/// sentence hands its capital to the next word; one that closed a sentence leaves the period in place.
/// Nothing else is touched, so "p.m.", "e.g." and "mouthy.dev" read as spoken. Words that can carry
/// meaning ("like", "you know") are left alone.
public enum Fillers {
    static let pattern = try! NSRegularExpression(pattern: "(,\\s*)?(?<![\\p{L}\\p{N}'’])(?:u+h*m+|u+h+|e+r+m+|h+m+m+)(?![\\p{L}\\p{N}'’])(?:\\s*([,.])(?=\\s|$))?", options: [.caseInsensitive])
    public static func remove(_ text: String) -> String {
        var out = text
        // Back to front, so each match's offsets still hold.
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let head = out[..<range.lowerBound]
            let lastVisible = head.last { $0 != " " && $0 != "\t" }
            let opensSentence = lastVisible == nil || lastVisible == "\n" || SmartInsertion.sentenceEnds.contains(lastVisible!)
            let closesSentence = Range(match.range(at: 2), in: out).map { out[$0] == "." } ?? false
            var tail = String(out[range.upperBound...])
            if opensSentence || closesSentence { tail = SmartInsertion.capitalizingFirstWord(tail) }
            out = String(head) + (closesSentence && !opensSentence ? "." : "") + tail
        }
        out = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        return stripLeadingPunctuation(out)
    }
}

/// Spoken self-correction commands that remove what was just said.
public enum Backtrack {
    static let pattern = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])(?:scratch that|delete that|strike that)(?![\\p{L}\\p{N}_])[.,!?]?", options: [.caseInsensitive])

    /// Each command removes the sentence (or clause after the last sentence end) spoken before it.
    public static func apply(_ text: String) -> String {
        var output = text
        while let match = pattern.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range, in: output) {
            let head = output[..<range.lowerBound]
            let trimmedHead = head.reversed().drop { $0.isWhitespace || $0 == "," }
            var cut = head.startIndex
            if let boundary = trimmedHead.dropFirst().firstIndex(where: { SmartInsertion.sentenceEnds.contains($0) || $0 == "\n" }) {
                cut = boundary.base
            }
            var tail = String(output[range.upperBound...].drop { $0 == " " })
            let kept = String(output[..<cut])
            // What follows now opens the sentence the command removed.
            let keptVisible = kept.last { $0 != " " && $0 != "\t" }
            if keptVisible == nil || keptVisible == "\n" || SmartInsertion.sentenceEnds.contains(keptVisible!) {
                tail = SmartInsertion.capitalizingFirstWord(tail)
            }
            output = kept + (kept.isEmpty || kept.last!.isWhitespace || tail.isEmpty ? "" : " ") + tail
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
