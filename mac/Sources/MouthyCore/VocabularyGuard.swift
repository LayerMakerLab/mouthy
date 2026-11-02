import Foundation

/// Checks the person's vocabulary terms against what the recognizer wrote, after the vocabulary pass.
public enum VocabularyGuard {
    /// Whether a vocabulary swap of `original` (what the recognizer wrote) for `term` stands. A swap for a term that
    /// only adds letters to the word that was written ("code" -> "Codex") is refused: the recognizer heard the whole
    /// shorter word, and the extra syllable would have come out as letters of its own.
    public static func keeps(original: String, term: String) -> Bool {
        let spoken = original.lowercased().filter { $0.isLetter || $0.isNumber }
        let written = term.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !spoken.isEmpty, !original.contains(" ") else { return true }
        return !(written.count > spoken.count && written.hasPrefix(spoken))
    }

    /// `text` (as recognized, before the vocabulary pass) with only the swaps that stand, in order. Each swap names
    /// the words it replaces (the recognizer's span, any case, without punctuation). Nil when a span cannot be found,
    /// so the caller keeps the unswapped text rather than guess.
    public static func apply(_ text: String, swaps: [(original: String, term: String)]) -> String? {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var used = Set<Int>()
        func bare(_ token: String) -> String { token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        for swap in swaps.map({ (original: trimmed($0.original, to: $0.term), term: $0.term) }) where keeps(original: swap.original, term: swap.term) {
            let span = swap.original.lowercased().split(separator: " ").map { bare(String($0)) }
            guard !span.isEmpty, let start = tokens.indices.first(where: { index in
                index + span.count <= tokens.count && (index..<index + span.count).allSatisfy { !used.contains($0) }
                    && (0..<span.count).allSatisfy { bare(tokens[index + $0]) == span[$0] }
            }) else { return nil }
            let last = tokens[start + span.count - 1]
            let trailing = String(last.reversed().prefix { !($0.isLetter || $0.isNumber) }.reversed())
            tokens[start] = swap.term + trailing
            for index in start + 1..<start + span.count { tokens[index] = "" }
            used.formUnion(start..<start + span.count)
        }
        return tokens.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The part of a swap's span that sounds like the term. The vocabulary pass swaps a span as long as the term in
    /// words, so a two-word term can take a neighbour with it ("Ask XGrower" -> "X Grower" drops "Ask"). The
    /// shortest run of the span's words whose letters are closest to the term's is kept; the rest stay as written.
    public static func trimmed(_ original: String, to term: String) -> String {
        let words = original.split(separator: " ").map(String.init)
        guard words.count > 1 else { return original }
        func letters(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let target = letters(term)
        guard !target.isEmpty else { return original }
        func score(_ run: ArraySlice<String>) -> Double {
            let spoken = letters(run.joined())
            return Double(VocabularyLearner.distance(spoken, target)) / Double(max(spoken.count, target.count, 1))
        }
        var best = (start: 0, end: words.count, score: score(words[...]))
        for start in words.indices {
            for end in (start + 1)...words.count where end - start < words.count {
                let s = score(words[start..<end])
                if s < best.score { best = (start, end, s) }
            }
        }
        return words[best.start..<best.end].joined(separator: " ")
    }

    /// A multi-word term the recognizer ran together ("XGrower", "Xgrower") is written as the term ("X Grower") when
    /// the word's letters are exactly the term's letters, or one letter off ("Xcrower") for a word that is not in the
    /// dictionary (`isKnownWord`, lowercase), so a real word ("explore") never changes.
    public static func spacing(_ text: String, terms: [String], isKnownWord: (String) -> Bool = { _ in true }) -> String {
        let joined = terms.filter { $0.contains(" ") }.map { (letters: $0.lowercased().filter { $0.isLetter || $0.isNumber }, term: $0) }
            .filter { $0.letters.count >= 4 }
        guard !joined.isEmpty else { return text }
        return text.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let word = String(token.prefix { $0.isLetter || $0.isNumber })
            let lower = word.lowercased()
            guard word.count >= 4, let match = joined.first(where: { $0.letters == lower })
                    ?? joined.first(where: { $0.letters.count >= 6 && VocabularyLearner.distance($0.letters, lower) == 1 && !isKnownWord(lower) })
            else { return String(token) }
            return match.term + token.dropFirst(word.count)
        }.joined(separator: " ")
    }

    /// A word the recognizer wrote as a name in mid-sentence ("Ask Cloud to review it") that is spelled close to one
    /// of the person's terms becomes that term ("Claude"). Only capitalized words that do not open a sentence: the
    /// capital is the recognizer saying it heard a name, so ordinary words ("the cloud") are never touched. Only
    /// dictionary words (`isKnownWord`, lowercase) are swapped, so a real name ("Greg") never becomes a term ("Grak").
    public static func names(_ text: String, terms: [String], isKnownWord: (String) -> Bool) -> String {
        let candidates = terms.filter { $0.count >= 3 && !$0.contains(" ") }
        guard !candidates.isEmpty else { return text }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in tokens.indices where index > 0 {
            let previous = tokens[index - 1]
            guard let end = previous.last, !SmartInsertion.sentenceEnds.contains(end), end != ":", end != "\"", end != "“" else { continue }
            let token = tokens[index]
            let word = String(token.prefix { $0.isLetter })
            guard word.count >= 3, word.first!.isUppercase, word.dropFirst().allSatisfy(\.isLowercase),
                  !candidates.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { continue }
            let lower = word.lowercased()
            guard isKnownWord(lower) else { continue }
            let match = candidates.filter { term in
                let t = term.lowercased()
                return t.first == lower.first && abs(t.count - lower.count) <= 2 && keeps(original: lower, term: term)
                    && Double(VocabularyLearner.distance(lower, t)) / Double(max(t.count, lower.count)) <= 0.34
            }
            guard match.count == 1 else { continue }
            tokens[index] = match[0] + token.dropFirst(word.count)
        }
        return tokens.joined(separator: " ")
    }
}
