import Foundation

/// A word from the streaming recognizer ("Show words instantly"): lowercase, without punctuation.
public struct StreamedWord: Equatable, Sendable {
    public var text: String
    /// The 16 kHz sample at which its first piece was heard.
    public var at: Int
    public init(_ text: String, at: Int) { self.text = text; self.at = at }
}

/// What the streaming recognizer answers for a batch of audio: every word since its audio began, that its model is
/// still loading (the audio must be sent again from the start), or that it cannot (and stops for this dictation).
public enum StreamAnswer: Sendable, Equatable {
    case words([StreamedWord])
    case loading
    case failed
}

/// How the streaming recognizer's words become the newest part of the live text. That recognizer writes a word about
/// a tenth of a second after it is said and never changes one, but it hears English only, knows no capitals or
/// punctuation and gets about one word in twenty wrong. So it only ever shows what was said after the last pass of the
/// main recognizer, which writes everything again at each pause. Pure.
public enum StreamedWords {
    /// A word heard later than this after the last sound a pass recognized was said after that pass. A pass starts
    /// at a pause of 0.2 s, and the streaming recognizer hears a word's first piece inside the word, so the word before
    /// the pause is earlier than this and the next one later.
    public static let seam = 1_600

    /// Words from the recognizer's pieces (SentencePiece: "▁" begins a word) and the time in ms each was heard at.
    public static func words(pieces: [String], milliseconds: [Int], rate: Int = 16_000) -> [StreamedWord] {
        var words: [StreamedWord] = []
        for (piece, time) in zip(pieces, milliseconds) where !(piece.hasPrefix("<") && piece.hasSuffix(">")) {
            let text = piece.replacingOccurrences(of: "\u{2581}", with: "")
            if piece.hasPrefix("\u{2581}") || words.isEmpty {
                words.append(StreamedWord(text, at: time * rate / 1000))
            } else {
                words[words.count - 1].text += text
            }
        }
        return words.filter { !$0.text.isEmpty }
    }

    /// The words said after `cut`, the end of the last sound a pass recognized (nil: no pass yet, so all of them).
    public static func after(_ cut: Int?, in words: [StreamedWord]) -> ArraySlice<StreamedWord> {
        guard let cut else { return words[...] }
        return words[(words.firstIndex { $0.at >= cut + seam } ?? words.endIndex)...]
    }

    /// The words as they show until the next pass writes them: "I" gets its capital, and a custom word is spelled as
    /// the person wrote it (`spellings`, by its lowercase form), so the pass changes less of what was shown.
    public static func written(_ words: some Sequence<StreamedWord>, spellings: [String: String] = [:]) -> String {
        words.map { word in
            if let spelled = spellings[word.text] { return spelled }
            if word.text == "i" || word.text.hasPrefix("i'") { return "I" + word.text.dropFirst() }
            return word.text
        }.joined(separator: " ")
    }

    /// Whether the streaming recognizer heard what a pass heard in the same audio: at least half of the pass's words.
    /// It does not when the person speaks another language (it writes English-sounding words for any speech), and
    /// then it must stop showing words. Too few words to tell counts as agreeing; numbers are not compared (a pass
    /// writes "2019", the streaming recognizer "twenty nineteen").
    public static func agrees(_ streamed: some Sequence<StreamedWord>, with text: String) -> Bool {
        let heard = text.split(whereSeparator: \.isWhitespace).map { LiveTyping.plain(String($0)) }
            .filter { $0.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" } }
        guard heard.count >= enoughToTell else { return true }
        var counts: [String: Int] = [:]
        for word in streamed { counts[LiveTyping.plain(word.text), default: 0] += 1 }
        var same = 0
        for word in heard where counts[word, default: 0] > 0 { counts[word]! -= 1; same += 1 }
        return same * 2 >= heard.count
    }

    static let enoughToTell = 6
}
