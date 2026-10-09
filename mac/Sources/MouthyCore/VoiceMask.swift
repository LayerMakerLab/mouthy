import Foundation

/// The audio a recognizer should hear when a voice detector has scored it: speech as recorded, and every other sound
/// turned down to a quiet room's level. Recognizers make words ("Yeah.", "Uh", "Mm.") out of a cough, a breath, typing
/// or a click; turned down to room tone, those sounds say nothing. Audio is never set to digital zero: a quiet room
/// stays as recorded, because seconds of exact zero change how the recognizer weighs the speech around them ("ship"
/// came back as "shift"). The length never changes, so word timings still line up.
public enum VoiceMask {
    /// A quiet room's level (RMS, about -60 dBFS): non-voice sound is never louder than this.
    public static let room: Float = 0.001
    /// Gain changes fade over 10 ms so turning a sound down never adds a click of its own.
    static let fade = 160

    /// Which `chunk`-sized pieces hold a voice: probability ≥ `threshold`, and `pad` pieces either side. Pieces the
    /// detector didn't score (a short tail) count as voice: never turned down on a guess.
    public static func voiced(_ probabilities: [Float], count: Int, threshold: Float, pad: Int) -> [Bool] {
        guard count > 0 else { return [] }
        var keep = [Bool](repeating: false, count: count)
        for (index, probability) in probabilities.prefix(count).enumerated() where probability >= threshold {
            for near in max(0, index - pad)...min(count - 1, index + pad) { keep[near] = true }
        }
        for index in min(probabilities.count, count)..<count { keep[index] = true }
        return keep
    }

    /// `samples` with every piece not in `voiced` turned down to `room` (pieces already that quiet are untouched).
    public static func apply(_ samples: [Float], voiced: [Bool], chunk: Int, room: Float = room) -> [Float] {
        guard !samples.isEmpty, chunk > 0 else { return samples }
        var gains = [Float](repeating: 1, count: voiced.count)
        for index in voiced.indices where !voiced[index] {
            let low = index * chunk, high = min(samples.count, low + chunk)
            guard low < high else { continue }
            var energy: Float = 0
            for i in low..<high { energy += samples[i] * samples[i] }
            let rms = (energy / Float(high - low)).squareRoot()
            if rms > room { gains[index] = room / rms }
        }
        var out = samples
        for index in gains.indices where gains[index] < 1 {
            let low = index * chunk, high = min(samples.count, low + chunk)
            for i in low..<high { out[i] *= gains[index] }
            // Ease from the louder neighbours' gain into this one over 10 ms at each edge.
            if index > 0, gains[index - 1] > gains[index] {
                for i in 0..<min(fade, high - low) {
                    let t = Float(i) / Float(fade)
                    out[low + i] = samples[low + i] * (gains[index - 1] * (1 - t) + gains[index] * t)
                }
            }
            if index + 1 < gains.count, gains[index + 1] > gains[index] {
                for i in 0..<min(fade, high - low) {
                    let t = Float(i) / Float(fade)
                    out[high - 1 - i] = samples[high - 1 - i] * (gains[index + 1] * (1 - t) + gains[index] * t)
                }
            }
        }
        return out
    }

    /// `samples` with the pieces in `voices` (another person's speech) replaced by a quiet room's hiss. Turned down
    /// like other sound, a clear voice still came back as words: the recognizer evens out loudness, so a voice at room
    /// level is still a voice. The hiss is fixed (no randomness), fades in and out over 10 ms, and keeps the length.
    public static func hush(_ samples: [Float], voices: [Bool], chunk: Int, room: Float = room) -> [Float] {
        guard voices.contains(true), chunk > 0 else { return samples }
        var out = samples
        var seed: UInt32 = 0x2545_F491
        for index in voices.indices where voices[index] {
            let low = index * chunk, high = min(samples.count, low + chunk)
            guard low < high else { continue }
            let fadeIn = index > 0 && !voices[index - 1], fadeOut = index + 1 < voices.count && !voices[index + 1]
            for i in low..<high {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let hiss = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 2 * room
                var mix: Float = 1   // share of hiss
                if fadeIn, i - low < fade { mix = Float(i - low) / Float(fade) }
                if fadeOut, high - 1 - i < fade { mix = min(mix, Float(high - 1 - i) / Float(fade)) }
                out[i] = hiss * mix + samples[i] * (1 - mix)
            }
        }
        return out
    }
}

/// "Only my voice": which voiced pieces of a dictation belong to the person whose voiceprint is on this Mac. Speech is
/// scored in overlapping windows long enough for a stable speaker embedding (`window` pieces of 256 ms, 2 s: the speaker
/// model's input, every `hop`, 0.5 s); a piece is someone else's only when the windows around it clearly don't match. When unsure (no window
/// around it was scored, and no other voice ran straight into it), a piece is kept: the person's words are never
/// dropped on a guess.
public enum SpeakerMask {
    /// Pieces (256 ms) per scored window and between window starts.
    public static let window = 8
    public static let hop = 2
    /// Speech pieces a window needs before its embedding says anything about the speaker.
    public static let minimumSpeech = 4
    /// Cosine similarity at or above which a window is the person. Measured 2026-10-07 with the Neural Engine model on
    /// 2 s windows against a voiceprint of the default macOS voice (VoicePrintProbe): the person over another voice at
    /// -6 or -12 dB 0.53-0.86 inside their sentences, another voice alone -0.02-0.20.
    public static let match: Float = 0.45

    /// Short windows (in pieces) centred on a piece of the person's sentence that tell whether it is another voice
    /// alone: a 2 s window can't (a TV word in a half-second pause scored as the sentence around it and was typed).
    public static let fineSizes = [2, 3]
    /// How much closer to the other voices than to the person every short window must be. Measured 2026-10-07 with a
    /// newscaster under the person at -12 dB: the newscaster alone in her pause and at her sentence's ends +0.12 to
    /// +0.57; her words at most +0.17 on one window and below 0 on the other.
    public static let fineMargin: Float = 0.1

    /// Whether a piece is clearly someone else's: every short window around it is at least `margin` closer to the
    /// other voices heard in this dictation (`theirs`, similarities) than to the voiceprint (`mine`).
    public static func clearlyTheirs(mine: [Float], theirs: [Float], margin: Float = fineMargin) -> Bool {
        guard !mine.isEmpty, mine.count == theirs.count else { return false }
        return zip(mine, theirs).allSatisfy { $1 - $0 >= margin }
    }

    public enum Verdict: Sendable, Equatable { case mine, theirs, unsure }

    /// Window starts (in pieces) whose pieces all lie within the first `pieces`.
    public static func windows(pieces: Int) -> StrideTo<Int> { stride(from: 0, to: max(0, pieces - window + 1), by: hop) }

    /// Cosine similarity of two embeddings (any length; 0 when either is empty or silent).
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        guard aa > 0, bb > 0 else { return 0 }
        return dot / (aa.squareRoot() * bb.squareRoot())
    }

    /// The unit-length mean of `embeddings` (a voiceprint).
    public static func centroid(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for embedding in embeddings where embedding.count == sum.count {
            let length = embedding.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard length > 0 else { continue }
            for i in sum.indices { sum[i] += embedding[i] / length }
        }
        let length = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? sum.map { $0 / length } : sum
    }

    /// One verdict per piece. `speech`: whether each piece holds speech; `scores`: similarity of the window starting at
    /// each scored piece. A piece is the person's when any window around it scores `match`, someone else's when none
    /// does. With no scored window around it, a speech piece is kept (the person's words are never dropped on a guess);
    /// only `spreadTheirs` (the stop, which then checks that speech once) lets it take the verdict of the speech it
    /// runs straight on from.
    public static func verdicts(speech: [Bool], scores: [Int: Float], match: Float = match, spreadTheirs: Bool = false) -> [Verdict] {
        var verdicts = [Verdict](repeating: .unsure, count: speech.count)
        for piece in speech.indices {
            // Any window around it that matches keeps it: the windows reaching into the person's first or last word
            // hold mostly the other voice, and averaging them dropped that word ("remind").
            var best: Float?
            var start = piece - piece % hop
            while start > piece - window, start >= 0 {
                if let score = scores[start] { best = max(best ?? score, score) }
                start -= hop
            }
            if let best { verdicts[piece] = best >= match ? .mine : .theirs }
        }
        // Unscored speech: the nearest decided piece earlier in the same run of speech, else later in it, else kept.
        var piece = 0
        while piece < speech.count {
            guard speech[piece] else { piece += 1; continue }
            var end = piece
            while end + 1 < speech.count, speech[end + 1] { end += 1 }
            var last: Verdict?
            for i in piece...end {
                if verdicts[i] != .unsure { last = verdicts[i] } else if let last, last == .mine || spreadTheirs { verdicts[i] = last }
            }
            var next: Verdict?
            for i in stride(from: end, through: piece, by: -1) {
                if verdicts[i] != .unsure { next = verdicts[i] } else if let next, next == .mine || spreadTheirs { verdicts[i] = next }
            }
            piece = end + 1
        }
        return verdicts
    }
}
