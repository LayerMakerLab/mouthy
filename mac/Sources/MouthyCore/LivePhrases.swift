import Foundation

/// Tracks where speech starts and stops in 16 kHz audio as it is recorded, so local engines can finalize
/// each phrase as soon as the person pauses instead of waiting for the end of the dictation.
public struct SpeechPauses: Sendable {
    /// 20 ms analysis frames.
    public static let frame = 320
    /// Samples analysed in complete frames so far.
    public private(set) var scanned = 0
    /// Samples already handed to `feed`, including the partial frame held for the next call.
    /// A live reader resumes here so an uneven microphone buffer is never counted twice.
    public var received: Int { scanned + pending.count }
    /// Index just after the most recent speech frame (0 before any speech).
    public private(set) var lastSpeechEnd = 0
    public private(set) var heardSpeech = false
    /// Frames counted as speech so far.
    public private(set) var speechFrames = 0
    /// Start indices of each run of speech, oldest first.
    public private(set) var onsets: [Int] = []
    /// End indices of each finished run of speech, oldest first.
    public private(set) var ends: [Int] = []
    /// Index just after the most recent sound that might be words: a voice-length run above `quietThreshold`,
    /// which hears soft and quiet speech the speech threshold misses. Never before `lastSpeechEnd`.
    public private(set) var lastSoundEnd = 0
    /// Start and end indices of each run of sound that might be words (above `quietThreshold`), oldest first. Soft
    /// words the speech threshold misses are in these runs, so a cut placed between them never splits a word.
    public private(set) var soundOnsets: [Int] = []
    public private(set) var soundEnds: [Int] = []
    private var inSound = false
    /// Runs of sound that hold voiced frames, which end a pause: a breath, a sniff or a rustle is unvoiced noise and
    /// leaves the pause running ("That's the plan. [inhale] Next" stays two sentences). Each onset is the run's first
    /// voiced frame less `voicedLead`, no earlier than the run's start, so an unvoiced first sound ("So") is inside.
    public private(set) var wordOnsets: [Int] = []
    public private(set) var wordEnds: [Int] = []
    private var runStart = 0
    private var voicedRun = 0
    private var runVoiced = false
    /// Unvoiced sound before a word's first voiced frame that still counts as the word (an "s" or "f"): 150 ms.
    public static let voicedLead = 2_400
    /// Zero crossings per sample under which a frame is voiced: vowels and voiced consonants sit near 0.1 at 16 kHz,
    /// breath and other noise near 0.3 or more.
    public static let voicedCrossings: Float = 0.25
    private var floor: Float = 0.002
    /// The quietest level lately (minimum tracking): drops at once, rises about 15% a second.
    private var quietFloor: Float = 0.001
    private var quietRun = 0
    private var pending: [Float] = []
    private var inSpeech = false
    private var loudRun = 0
    /// Loud frames in a row before they count as speech: key clicks (the stop shortcut), taps and pops are
    /// shorter, and recognizers turn them into words like "Yeah".
    public static let minimumRun = 3
    /// Speech needed in leftover audio before it is worth recognizing at all.
    public static let minimumSpeechFrames = 8

    public init() {}

    /// A frame is speech when it is clearly above the room's noise floor.
    public var threshold: Float { max(0.004, floor * 3) }
    /// A frame might hold words when it is above the quietest recent level. Soft words never raise it, so a
    /// soft ending after loud speech still counts, unlike `threshold`.
    public var quietThreshold: Float { max(0.0008, quietFloor * 2.5) }

    public mutating func feed(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= Self.frame {
            let level = Self.rms(pending[offset..<(offset + Self.frame)])
            let start = scanned
            scanned += Self.frame
            offset += Self.frame
            quietFloor = level < quietFloor ? quietFloor * 0.7 + level * 0.3 : min(level, quietFloor * 1.003)
            if level > quietThreshold {
                quietRun += 1
                if quietRun >= Self.minimumRun {
                    if !inSound {
                        runStart = start - (Self.minimumRun - 1) * Self.frame
                        soundOnsets.append(runStart); inSound = true; runVoiced = false; voicedRun = 0
                    }
                    lastSoundEnd = scanned
                }
                voicedRun = Self.crossings(pending[offset - Self.frame..<offset]) < Self.voicedCrossings ? voicedRun + 1 : 0
                if inSound, !runVoiced, voicedRun >= Self.minimumRun {
                    runVoiced = true
                    wordOnsets.append(max(runStart, start - (Self.minimumRun - 1) * Self.frame - Self.voicedLead))
                }
            } else {
                quietRun = 0
                voicedRun = 0
                if inSound { soundEnds.append(lastSoundEnd); if runVoiced { wordEnds.append(lastSoundEnd) } }
                inSound = false
                runVoiced = false
            }
            if level > threshold {
                loudRun += 1
                guard loudRun >= Self.minimumRun else { continue }
                speechFrames += loudRun == Self.minimumRun ? Self.minimumRun : 1
                if !inSpeech { onsets.append(start - (Self.minimumRun - 1) * Self.frame); inSpeech = true }
                heardSpeech = true
                lastSpeechEnd = scanned
                lastSoundEnd = max(lastSoundEnd, scanned)
            } else {
                loudRun = 0
                if inSpeech { ends.append(lastSpeechEnd) }
                inSpeech = false
                // The floor follows the quiet frames slowly, so a noisy room raises the bar for speech.
                floor = floor * 0.95 + level * 0.05
            }
        }
        pending.removeFirst(offset)
    }

    /// The longest pause that starts at or after `from` and ends before `to`: (end of sound, next onset). A pause is
    /// silence by the quiet bar, so soft words are never inside one; only when the room never went that quiet does it
    /// fall back to a pause in loud speech.
    public func longestPause(from: Int, to: Int) -> (start: Int, end: Int)? {
        Self.longest(ends: wordEnds, onsets: wordOnsets, from: from, to: to) ?? Self.longest(ends: ends, onsets: onsets, from: from, to: to)
    }

    private static func longest(ends: [Int], onsets: [Int], from: Int, to: Int) -> (start: Int, end: Int)? {
        var best: (start: Int, end: Int)?
        for end in ends where end >= from {
            guard let next = onsets.first(where: { $0 >= end }), next <= to else { continue }
            if next - end > (best.map { $0.end - $0.start } ?? 0) { best = (end, next) }
        }
        return best
    }

    /// The silence after `end` (the end of the last sound a part heard) before the next sound that might be words:
    /// 0 when sound runs on through `end` (a part cut without a pause), nil when nothing was heard after it yet.
    /// Breaths and other unvoiced noise in between do not end it.
    public func silence(after end: Int) -> Int? {
        if let start = wordOnsets.last(where: { $0 < end }) {
            // The run that began before `end` either ended before it or is still going through it.
            let finished = wordEnds.first { $0 > start }
            if finished == nil || finished! > end { return 0 }
        }
        return wordOnsets.first { $0 >= end }.map { $0 - end }
    }

    /// The first speech at or after `index`.
    public func onset(atOrAfter index: Int) -> Int? { onsets.first { $0 >= index } }
    /// The first sound that might be words (soft speech included) at or after `index`.
    public func soundOnset(atOrAfter index: Int) -> Int? { soundOnsets.first { $0 >= index } }

    /// Whether `samples` hold real speech by this recording's threshold: enough loud frames in runs long
    /// enough to be voice, not a click or a breath.
    public func hasSpeech(_ samples: ArraySlice<Float>) -> Bool {
        var start = samples.startIndex, run = 0, frames = 0
        while start + Self.frame <= samples.endIndex {
            if Self.rms(samples[start..<(start + Self.frame)]) > threshold {
                run += 1
                if run == Self.minimumRun { frames += run } else if run > Self.minimumRun { frames += 1 }
                if frames >= Self.minimumSpeechFrames { return true }
            } else {
                run = 0
            }
            start += Self.frame
        }
        return false
    }

    /// Whether `samples` might hold words: a voice-length run (60 ms, longer than a key click) above
    /// `quietThreshold`. Leftover audio that passes is recognized: when unsure, recognize it.
    public func mightHoldWords(_ samples: ArraySlice<Float>) -> Bool {
        var start = samples.startIndex, run = 0
        while start + Self.frame <= samples.endIndex {
            run = Self.rms(samples[start..<(start + Self.frame)]) > quietThreshold ? run + 1 : 0
            if run >= Self.minimumRun { return true }
            start += Self.frame
        }
        return false
    }

    /// Zero crossings per sample: low for voiced sound, high for noise.
    static func crossings(_ samples: ArraySlice<Float>) -> Float {
        var count = 0, previous = samples.first ?? 0
        for value in samples.dropFirst() {
            if (value >= 0) != (previous >= 0) { count += 1 }
            previous = value
        }
        return Float(count) / Float(max(1, samples.count - 1))
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        var energy: Float = 0
        for value in samples { energy += value * value }
        return (energy / Float(max(1, samples.count))).squareRoot()
    }
}

/// Joins phrases that were recognized one at a time back into one text. Recognizers end every phrase with
/// a period; after a short pause the sentence usually goes on, so that period is dropped and the next
/// phrase continues in lowercase (names, "I" and acronyms keep their capitals).
public enum PhraseJoiner {
    /// Pauses shorter than this continue the sentence.
    public static let sentencePause = 0.7

    /// `gap` is the silence in seconds between the previous phrase's last word and this phrase's first. `keepCase` holds
    /// vocabulary terms written in lowercase ("npm"): a phrase that starts with one, or with a number, shows no case, so
    /// the sentence end before it stays and the term is never capitalized.
    public static func join(_ phrases: [(text: String, gap: Double)], keepCase: Set<String> = []) -> String {
        var output = ""
        for (raw, gap) in phrases {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if output.isEmpty { output = text; continue }
            let last = output.last { !SmartInsertion.quoteClosers.contains($0) } ?? " "
            let short = gap < sentencePause
            if SmartInsertion.sentenceEnds.contains(last) {
                // A recognizer that starts a phrase in lowercase heard it begin mid-sentence; the mark before it was
                // written by a pass that never heard what came next.
                let continued = startsLowercase(text, keepCase: keepCase)
                if caseUnknown(text, keepCase: keepCase) {
                    // "We have 3 options. 2 are bad.": nothing tells the sentence went on.
                } else if short, output.hasSuffix("."), !output.hasSuffix("..") {
                    // A short pause continues the sentence: the recognizer's period and capital go. An
                    // abbreviation's period ("3 p.m.", "e.g.") stays.
                    if !abbreviation(output) { output.removeLast() }
                    text = SmartInsertion.lowercasingFirstWord(text)
                } else if continued, short, last == "?" || last == "!" {
                    output.removeLast()
                } else if continued {
                    // A long pause ends the sentence: never a period followed by a lowercase word ("noon. after").
                    text = SmartInsertion.capitalizingFirstWord(text)
                }
            } else if short || last == "," || last == ";" || last == ":" {
                // The sentence is still open: a phrase after a short pause, or after a clause the recognizer
                // left open, continues it, so the capital every new phrase gets goes.
                text = SmartInsertion.lowercasingFirstWord(text)
            } else if last.isLetter || last.isNumber {
                // A part cut at a long pause never showed the recognizer the end of its sentence; the pause is it.
                output += "."
                if !caseUnknown(text, keepCase: keepCase) { text = SmartInsertion.capitalizingFirstWord(text) }
            }
            output += " " + text
        }
        return output
    }

    /// Joins the newest words, recognized with the audio before them (a context decode), onto the text already heard.
    /// That recognizer heard the boundary, so it decides it. Token times put a word that ends right at the cut on
    /// either side, so the earlier text's last words can come back again: they are dropped when the decode did not
    /// hear them in its context (it heard them once, after the cut) and kept when it did (said twice). A first word
    /// it wrote in lowercase continues the sentence, so the earlier text's closing mark, written without hearing what
    /// came next, goes ("this is. you can"); a capital (or a number or lowercase vocabulary term, which show no case)
    /// never takes a sentence end away. A sentence the earlier pass left open is the pause's to decide, as in `join`.
    public static func join(_ earlier: String, heard: ContextWords, gap: Double, keepCase: Set<String> = []) -> String {
        var tokens = heard.after.split(whereSeparator: \.isWhitespace).map(String.init)
        let earlierWords = words(earlier), beforeWords = words(heard.before)
        if !beforeWords.isEmpty {
            for count in stride(from: min(3, earlierWords.count, tokens.count), through: 1, by: -1) {
                let shared = Array(earlierWords.suffix(count))
                guard tokens.prefix(count).map(normalized) == shared, Array(beforeWords.suffix(count)) != shared else { continue }
                tokens.removeFirst(count)
                break
            }
        }
        let newer = tokens.joined(separator: " ")
        guard newer.contains(where: { $0.isLetter || $0.isNumber }) else { return earlier }
        var output = earlier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return newer }
        guard let last = output.last, SmartInsertion.sentenceEnds.contains(last) else {
            return join([(output, 0), (newer, gap)], keepCase: keepCase)
        }
        guard startsLowercase(newer, keepCase: keepCase) else { return output + " " + newer }
        if last == "?" || last == "!" || (last == "." && !output.hasSuffix("..") && !abbreviation(output)) {
            output.removeLast()
        }
        return output + " " + newer
    }

    /// An abbreviation's period ("3 p.m.", "e.g.") ends the text.
    static func abbreviation(_ text: String) -> Bool {
        let tail = text.suffix(3)
        return tail.count == 3 && tail.first == "." && tail.dropFirst().first!.isLetter
    }

    /// Whether the first word is all lowercase ("where"; not "iPhone", "I", "3" or a lowercase vocabulary term).
    static func startsLowercase(_ text: String, keepCase: Set<String> = []) -> Bool {
        guard let word = firstWord(text), word.first!.isLetter, !keepCase.contains(word.lowercased()) else { return false }
        return word.allSatisfy { !$0.isLetter || $0.isLowercase }
    }

    /// Whether the first word shows nothing about a sentence start: a number, or a vocabulary term always written in lowercase.
    static func caseUnknown(_ text: String, keepCase: Set<String>) -> Bool {
        guard let word = firstWord(text) else { return false }
        return word.first!.isNumber || keepCase.contains(word.lowercased())
    }

    private static func firstWord(_ text: String) -> Substring? {
        guard let start = text.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text[start...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// The vocabulary terms written all in lowercase ("npm"), which a phrase can start with without showing its case.
    public static func lowercaseTerms(_ terms: [String]) -> Set<String> {
        Set(terms.compactMap { term in
            guard let word = term.split(whereSeparator: \.isWhitespace).first, word.first?.isLetter == true,
                  !word.contains(where: \.isUppercase) else { return nil }
            return String(word).lowercased()
        })
    }

    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }.filter { !$0.isEmpty } }

    static func normalized(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" })
    }
}

/// The words a context decode returns: `after`, the words that begin at or after the cut, and `before`, the words it
/// heard in the context audio before the cut (empty when the recognizer gives no token times).
public struct ContextWords: Sendable, Equatable {
    public var before: String
    public var after: String
    public init(before: String = "", after: String) { self.before = before; self.after = after }
}
