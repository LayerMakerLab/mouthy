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
                if quietRun >= Self.minimumRun { lastSoundEnd = scanned }
            } else {
                quietRun = 0
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

    /// The longest pause that starts at or after `from` and ends before `to`: (end of speech, next onset).
    public func longestPause(from: Int, to: Int) -> (start: Int, end: Int)? {
        var best: (start: Int, end: Int)?
        for end in ends where end >= from {
            guard let next = onset(atOrAfter: end), next <= to else { continue }
            if next - end > (best.map { $0.end - $0.start } ?? 0) { best = (end, next) }
        }
        return best
    }

    /// The first speech at or after `index`.
    public func onset(atOrAfter index: Int) -> Int? { onsets.first { $0 >= index } }

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

    /// `gap` is the silence in seconds between the previous phrase's last word and this phrase's first.
    public static func join(_ phrases: [(text: String, gap: Double)]) -> String {
        var output = ""
        for (raw, gap) in phrases {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if output.isEmpty { output = text; continue }
            let last = output.last { !SmartInsertion.quoteClosers.contains($0) } ?? " "
            let short = gap < sentencePause
            if SmartInsertion.sentenceEnds.contains(last) {
                if short, output.hasSuffix("."), !output.hasSuffix("..") {
                    // A short pause continues the sentence: the recognizer's period and capital go. An
                    // abbreviation's period ("3 p.m.", "e.g.") stays.
                    let tail = output.suffix(3)
                    let abbreviation = tail.count == 3 && tail.first == "." && tail.dropFirst().first!.isLetter
                    if !abbreviation { output.removeLast() }
                    text = SmartInsertion.lowercasingFirstWord(text)
                }
            } else if short || last == "," || last == ";" || last == ":" {
                // The sentence is still open: a phrase after a short pause, or after a clause the recognizer
                // left open, continues it, so the capital every new phrase gets goes.
                text = SmartInsertion.lowercasingFirstWord(text)
            } else if last.isLetter || last.isNumber {
                // A part cut at a long pause never showed the recognizer the end of its sentence; the pause is it.
                output += "."
            }
            output += " " + text
        }
        return output
    }
}
