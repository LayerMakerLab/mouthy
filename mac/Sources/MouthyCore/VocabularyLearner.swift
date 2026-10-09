import Foundation

/// Learns words the person corrects after Mouthy inserted them.
/// Only single-word substitutions that look like a misrecognition are considered.
public enum VocabularyLearner {
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// Corrected words when `edited` keeps `inserted`'s word count and changes a few words.
    /// `isKnownWord` should return true for ordinary dictionary words (lowercase spell check).
    public static func corrections(inserted: String, edited: String, isKnownWord: (String) -> Bool) -> [String] {
        let before = words(inserted), after = words(edited)
        guard before.count == after.count, !before.isEmpty else { return [] }
        let changed = zip(before, after).filter { $0.lowercased() != $1.lowercased() }
        // A rewrite, not a correction.
        guard !changed.isEmpty, changed.count <= max(1, before.count / 4) else { return [] }
        return changed.compactMap { old, new in
            let looksSpecial = new.contains { $0.isUppercase || $0.isNumber } || !isKnownWord(new.lowercased())
            let similar = distance(old.lowercased(), new.lowercased()) <= max(2, max(old.count, new.count) / 2)
            return looksSpecial && similar && new.count >= 2 ? new : nil
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
