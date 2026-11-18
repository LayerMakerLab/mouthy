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

    /// The person's terms written the way they spell them, from three kinds of near miss:
    /// - the same letters cased or spaced differently ("Makerworld", "XGrower", "maker world" -> "MakerWorld",
    ///   "X Grower"), across up to three words. Real words become a term only when the term has a capital inside it
    ///   ("maker world" -> "MakerWorld"), so "the cursor", "a swift reply" and "the blue sky" stay;
    /// - a multi-word term run together one letter off ("Xcrower") as a word the dictionary lacks;
    /// - a word the dictionary lacks, alone or after one short word (or any word after a lone capital letter), that
    ///   sounds like a term ("Alama" -> "Ollama", "a marky" -> "Omarko", "X field" -> "Pixfield"): the same
    ///   `soundKey`, or one sound off for longer terms, and letters at most half different.
    /// A word counts as known when `isKnownWord` accepts it as written or in lowercase, so names the dictionary has
    /// ("Jeff", "Clyde") never change by sound.
    public static func spelling(_ text: String, terms: [String], isKnownWord: (String) -> Bool = { _ in true }) -> String {
        func letters(_ s: some StringProtocol) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = terms.map { (term: $0, letters: letters($0), sound: soundKey($0)) }.filter { $0.letters.count >= 3 }
        guard !wanted.isEmpty else { return text }
        let byLetters = Dictionary(wanted.map { ($0.letters, $0) }, uniquingKeysWith: { first, _ in first })
        func innerCapital(_ term: String) -> Bool { term.dropFirst().contains { $0.isUppercase } }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // Each token's word (leading letters and digits), what follows it, and whether the dictionary lacks the word.
        var words: [(word: String, rest: Substring, unknown: Bool)] = tokens.map { token in
            let word = String(token.prefix { $0.isLetter || $0.isNumber })
            let unknown = word.count > 2 && !isKnownWord(word) && !isKnownWord(word.lowercased())
            return (word, token.dropFirst(word.count), unknown)
        }
        /// A capital letter on its own other than "I" and "A": the recognizer heard a letter's name ("X field").
        func letterName(_ word: String) -> Bool { word.count == 1 && word.first!.isUppercase && word != "I" && word != "A" }
        var index = 0
        while index < tokens.count {
            for length in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let span = words[index..<index + length]
                // Only the last word may carry punctuation; a span never crosses a comma or a sentence end.
                guard span.allSatisfy({ !$0.word.isEmpty }), span.dropLast().allSatisfy({ $0.rest.isEmpty }) else { continue }
                let written = span.map(\.word).joined(separator: " "), spoken = letters(span.map(\.word).joined())
                let anyUnknown = span.contains(where: \.unknown)
                var match: (term: String, letters: String, sound: String)?
                if let same = byLetters[spoken], same.term != written, anyUnknown || innerCapital(same.term) {
                    match = same
                } else if length == 1, anyUnknown {
                    match = wanted.first { $0.term.contains(" ") && $0.letters.count >= 6 && VocabularyLearner.distance($0.letters, spoken) == 1 }
                        ?? soundsLike(spoken, wanted)
                } else if length == 2, let first = span.first, let second = span.last, first.word.count <= 2,
                          second.unknown || letterName(first.word),
                          // A short word joins only when the word alone sounds like no term ("a marchie", not "to Alama").
                          byLetters[letters(second.word)] == nil, soundsLike(letters(second.word), wanted) == nil {
                    match = soundsLike(spoken, wanted)
                }
                guard let match, match.term != written else { continue }
                let rest = span.last!.rest
                tokens.replaceSubrange(index..<index + length, with: [match.term + rest])
                words.replaceSubrange(index..<index + length, with: [(match.term, rest, false)])
                break
            }
            index += 1
        }
        return tokens.joined(separator: " ")
    }

    /// The one term `spoken` (letters only) sounds like, if exactly one does.
    static func soundsLike(_ spoken: String, _ wanted: [(term: String, letters: String, sound: String)]) -> (term: String, letters: String, sound: String)? {
        let key = soundKey(spoken)
        guard key.count >= 2 else { return nil }
        let close = wanted.filter { term in
            guard term.sound == key || term.sound.count >= 4 && key.count >= 4 && abs(term.sound.count - key.count) <= 1,
                  spoken != term.letters, abs(spoken.count - term.letters.count) * 2 <= max(spoken.count, term.letters.count) else { return false }
            let letterGap = VocabularyLearner.distance(spoken, term.letters)
            guard Double(letterGap) / Double(max(spoken.count, term.letters.count)) <= 0.5 else { return false }
            if term.sound == key { return term.sound.count >= 3 || letterGap <= 2 }
            return term.sound.count >= 4 && key.count >= 4 && VocabularyLearner.distance(term.sound, key) == 1
        }
        return close.count == 1 ? close[0] : nil
    }

    /// A rough key for how a word sounds: spellings of one sound written alike (ph f, ck k, th t, sh/ch s/k, x ks),
    /// voiced and unvoiced pairs merged (d t, b p, g k, v f, z s), vowels and h, w, y dropped after the first letter
    /// (a word that starts with a vowel keeps one "a"), doubles collapsed. "Ollama", "Alama" -> "alm";
    /// "Omarko", "a marky" -> "amrk"; "Pixfield" -> "pksflt", "xfield" -> "ksflt".
    public static func soundKey(_ word: String) -> String {
        var s = word.lowercased().filter { $0.isLetter }
        for (from, to) in [("ph", "f"), ("ck", "k"), ("th", "t"), ("sh", "s"), ("ch", "k"), ("gh", "g"), ("qu", "k"), ("q", "k"),
                           ("x", "ks"), ("c", "k"), ("d", "t"), ("b", "p"), ("g", "k"), ("v", "f"), ("z", "s"), ("j", "k")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        let vowels = Set("aeiouyhw")
        var key = ""
        for (offset, character) in s.enumerated() {
            if vowels.contains(character) {
                if offset == 0 && character != "h" && character != "w" { key.append("a") }
                continue
            }
            if key.last != character { key.append(character) }
        }
        return key
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
