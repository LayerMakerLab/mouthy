import Foundation

/// Learns words the person corrects after Mouthy inserted them.
/// Only single-word substitutions that look like a misrecognition are considered.
public enum VocabularyLearner {
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// The runs of words that differ between `before` and `after`, in order (a word-level diff, ignoring case).
    static func changedRuns(_ before: [String], _ after: [String]) -> [(old: [String], new: [String])] {
        let a = before.map { $0.lowercased() }, b = after.map { $0.lowercased() }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var runs: [(old: [String], new: [String])] = []
        var i = 0, j = 0, old: [String] = [], new: [String] = []
        func flush() { if !old.isEmpty || !new.isEmpty { runs.append((old, new)) }; old = []; new = [] }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { flush(); i += 1; j += 1 }
            else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] { new.append(after[j]); j += 1 }
            else { old.append(before[i]); i += 1 }
        }
        flush()
        return runs
    }

    /// Words and short phrases the person corrected: each changed run of at most 4 words for at most 4 words
    /// ("explore" -> "X Grower"), where the new words look like a name or term (a capital, a digit or a word the
    /// dictionary lacks) and sound-sized like the old ones. More change than a correction is a rewrite: nothing.
    /// `isKnownWord` should return true for ordinary dictionary words (lowercase spell check).
    public static func corrections(inserted: String, edited: String, isKnownWord: (String) -> Bool) -> [String] {
        let before = words(inserted), after = words(edited)
        guard !before.isEmpty else { return [] }
        var runs = changedRuns(before, after)
        // Words after the inserted text (the read covers a little more than the insertion) are not a correction.
        if let last = runs.last, last.old.isEmpty, after.suffix(last.new.count).elementsEqual(last.new) { runs.removeLast() }
        let changed = runs.reduce(0) { $0 + max($1.old.count, $1.new.count) }
        guard !runs.isEmpty, changed <= max(2, before.count / 3),
              runs.allSatisfy({ !$0.old.isEmpty && !$0.new.isEmpty && $0.old.count <= 4 && $0.new.count <= 4 }) else { return [] }
        func letters(_ words: [String]) -> String { words.joined().lowercased().filter { $0.isLetter || $0.isNumber } }
        return runs.compactMap { run in
            let new = run.new.joined(separator: " ")
            let looksSpecial = run.new.contains { word in word.contains { $0.isUppercase || $0.isNumber } || !isKnownWord(word.lowercased()) }
            let (spoken, written) = (letters(run.old), letters(run.new))
            guard looksSpecial, written.count >= 2 else { return nil }
            if run.old.count == 1, run.new.count == 1 {
                return distance(spoken, written) <= max(2, max(spoken.count, written.count) / 2) ? new : nil
            }
            // A phrase heard as other words ("explore" for "X Grower"): about as long when spoken.
            let ratio = Double(written.count) / Double(max(spoken.count, 1))
            return (0.6...1.7).contains(ratio) ? new : nil
        }
    }

    /// Names that sound unlike their spelling ("Chavon" corrected to "Siobhan"): the misheard word is not a
    /// real word and the correction is capitalized but spelled too differently for recognition hints to help.
    /// Returned as (heard, meant) pairs to learn as exact replacements.
    public static func soundAlikes(inserted: String, edited: String, isKnownWord: (String) -> Bool) -> [(heard: String, meant: String)] {
        let before = words(inserted), after = words(edited)
        guard before.count == after.count, !before.isEmpty else { return [] }
        let changed = zip(before, after).filter { $0.lowercased() != $1.lowercased() }
        guard !changed.isEmpty, changed.count <= max(1, before.count / 4) else { return [] }
        return changed.compactMap { old, new in
            let similar = distance(old.lowercased(), new.lowercased()) <= max(2, max(old.count, new.count) / 2)
            let name = new.first?.isUppercase == true && new.count >= 2
            return !similar && name && old.count >= 2 && !isKnownWord(old.lowercased()) ? (old, new) : nil
        }
    }

    /// Vocabulary terms: one per line; commas also separate (older files and pasted lists).
    public static func terms(_ vocabulary: String) -> [String] {
        vocabulary.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Adds words to the vocabulary, one per line, skipping ones already there.
    public static func merge(_ learned: [String], into vocabulary: String) -> String {
        var items = terms(vocabulary)
        for word in learned where !items.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { items.append(word) }
        return items.joined(separator: "\n")
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]; row[0] = i
            for j in 1...max(1, b.count) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
}
