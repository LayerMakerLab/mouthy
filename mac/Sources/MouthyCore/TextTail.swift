import Foundation

/// Short single-line previews of live words that never start mid-word.
public enum TextTail {
    /// The last whole words of `text` that fit in `maxCharacters`, prefixed with "…" when earlier words were
    /// dropped. A single word longer than the limit keeps its own tail.
    public static func lastWords(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters > 0, trimmed.count > maxCharacters else { return trimmed }
        var kept: [Substring] = []
        var length = 0
        for word in trimmed.split(whereSeparator: \.isWhitespace).reversed() {
            let added = word.count + (kept.isEmpty ? 0 : 1)
            guard length + added <= maxCharacters else { break }
            kept.append(word)
            length += added
        }
        guard !kept.isEmpty else { return "…" + trimmed.suffix(maxCharacters) }
        return "…" + kept.reversed().joined(separator: " ")
    }
}
