import Foundation
import MouthyCore

/// Recognizes local-engine dictation (Parakeet, Whisper) while the person is still talking, so finishing
/// usually has nothing left to do. Whenever they pause for 0.2 s, the whole open part (everything since the last
/// closed part) is recognized again in the background, with the vocabulary pass: every word is heard with the words
/// before it, and a word one pass missed is heard again by the next. A part closes only once it is long (at a long
/// pause, or at its longest pause), sized to this Mac's speed so a pass stays near half a second. Soft or quiet words
/// the speech threshold misses are caught by a quieter energy check and Silero's trained voice detector (Apple
/// silicon), and recorded audio that might hold words is never thrown away. Audio stays in memory; nothing leaves
/// the Mac.
@MainActor
final class LiveTranscriber {
    /// Recognizes 16 kHz samples; `boost` adds the slower vocabulary pass.
    typealias Decode = @Sendable (_ samples: [Float], _ boost: Bool) async throws -> String
    /// Recognizes 16 kHz samples with the vocabulary pass and returns only the words that begin at or after sample
    /// `from`: the audio before it is context, so the newest words are heard with the words that led up to them.
    typealias DecodeAfter = @Sendable (_ samples: [Float], _ from: Int) async throws -> String
    /// A trained voice detector's verdict on 16 kHz samples; nil when none is on this Mac (energy decides alone).
    typealias HearsSpeech = @Sendable (_ samples: [Float]) async -> Bool?

    static let rate = 16_000
    /// Silence after speech before the background pass starts.
    static let pause = rate / 5
    /// Silence kept after the last word so it is never clipped.
    static let tailPadding = rate / 4
    /// A pause this long closes a part that is already half of the longest part this Mac allows.
    static let partPause = rate
    /// Parts on the fastest Macs and on the slowest; in between, a part is as long as half a second of work.
    static let longestPart = rate * 30
    static let shortestPart = rate * 6
    /// At the stop, the open part is recognized again in one pass when that takes at most this long (an M5 does
    /// 15 s of audio in about 0.1 s); otherwise the newest words are recognized with the `context` before them.
    static let stopBudget = 0.15
    static let longestAtStop = rate * 15
    static let context = rate * 2
    /// Previews wait this long after capture starts, while the audio device settles.
    static let firstPreview = Duration.milliseconds(500)
    /// Seconds this Mac takes per second of audio, shared by every dictation and smoothed over passes of 4 s or more.
    /// Until measured, Apple silicon is taken as fast and an Intel Mac (Parakeet on the CPU) as slow.
    static var cost: Double = {
        #if arch(arm64)
        0.007
        #else
        0.06
        #endif
    }()

    private let decode: Decode
    private let decodeAfter: DecodeAfter?
    private let hearsSpeech: HearsSpeech?
    private let count: () -> Int
    private let read: (Range<Int>) -> [Float]
    private var pauses = SpeechPauses()
    private var parts: [(text: String, gap: Double)] = []
    /// Samples already closed into `parts`.
    private(set) var committed = 0
    private var lastPartSpeechEnd = 0
    /// The background result for `committed..<end`, valid while nobody has spoken past `speechEnd`. `heardEnd` is
    /// where the last sound it heard ended (speech or soft words); `end` adds the padding after it.
    private var ready: Result?
    /// `speakersAt`: the speaker check's `nextWindow` when it was recognized (Int.max without the check).
    private typealias Result = (end: Int, speechEnd: Int, heardEnd: Int, text: String, speakersAt: Int)
    /// Quiet sound up to here was judged not to be speech by the voice detector.
    private var judgedUntil = 0
    private var job: Task<Void, Never>?
    private var preview: Task<Void, Never>?
    private var previewedAt = 0
    private var previewInterval = rate / 2
    private var failed = false
    private let createdAt = ContinuousClock.now
    /// "Only listen to my voice": who is speaking, checked in the background as audio arrives (nil when off).
    private var speakers: SpeakerTrack?
    private var speakerJob: Task<Void, Never>?
    private var speakersFed = 0
    /// The speaker check's `nextWindow` after its last batch.
    private var speakersAt = 0
    /// Whether `ready` was recognized before a scored speaker window reached the last sound it heard. (Waiting for a
    /// window to start past its end, 1.5 s after the last word, outlasted every pause between sentences, so a long
    /// dictation never closed a part and the stop recognized all of it: 26.5 s for the 45 s monologue.)
    private var readyIsProvisional: Bool {
        guard speakers != nil, let ready else { return false }
        return (ready.speakersAt - SpeakerMask.hop + SpeakerMask.window) * VoiceActivity.chunk < ready.heardEnd
    }
    private var maximumPart: Int { min(Self.longestPart, max(Self.shortestPart, Int(0.5 / Self.cost * Double(Self.rate)))) }
    private var wholeAtStop: Int { min(Self.longestAtStop, Int(Self.stopBudget / Self.cost * Double(Self.rate))) }
    /// Live text: closed parts, then the latest background result or a fast guess at the rest.
    var onText: ((String) -> Void)?

    init(decode: @escaping Decode, decodeAfter: DecodeAfter? = nil, hearsSpeech: HearsSpeech? = nil,
         speakers: SpeakerTrack? = SpeakerTrack.forDictation(), count: @escaping () -> Int, read: @escaping (Range<Int>) -> [Float]) {
        self.speakers = speakers
        self.decode = decode
        self.decodeAfter = decodeAfter
        self.hearsSpeech = hearsSpeech
        self.count = count
        self.read = read
    }

    var text: String { PhraseJoiner.join(parts) }

    /// Call often (every ~100 ms) while recording.
    func tick() {
        let available = count()
        if available > pauses.received { pauses.feed(read(pauses.received..<available)) }
        listenForSpeakers(available)
        guard job == nil, preview == nil, !failed else { return }
        let speechEnd = pauses.lastSpeechEnd
        // Quiet sound the speech threshold missed (a soft ending, a quiet voice) counts as heard only once recognized.
        let soundEnd = max(pauses.lastSoundEnd, speechEnd)
        let heardUntil = max(ready?.end ?? committed, judgedUntil)
        let unheard = soundEnd > heardUntil
        let end = min(available, soundEnd + Self.tailPadding)
        // Until a voice has been recognized, a moment of sound (a key, a breath, a cough) is recognized only once the
        // voice detector hears speech in it: recognizers make words ("Yeah") out of it.
        let moment = parts.isEmpty && ready == nil && pauses.speechFrames < Self.momentOfSound
        let judgedNoise = moment && judgedUntil >= soundEnd
        if let ready, !unheard, ready.speechEnd == speechEnd, available - soundEnd >= Self.partPause,
           available - committed > maximumPart / 2, !readyIsProvisional {
            // A long pause (no sound that might be words, not just no loud speech) closes only a long part: a short
            // dictation is recognized whole, so a phrase after a pause still hears the words before it ("ship" alone
            // came back as "shipped", a very quiet "bank" as "land").
            close(ready)
        } else if available - committed > maximumPart {
            if let gap = pauses.longestPause(from: committed + maximumPart / 2, to: available) {
                recognize(committed..<((gap.start + gap.end) / 2), speechEnd: gap.start, heardEnd: gap.start, thenClose: true)
            } else {
                let window = read(committed..<available)
                let cut = committed + (AudioChunks.ranges(window, maxSamples: maximumPart).first?.upperBound ?? window.count)
                recognize(committed..<cut, speechEnd: min(cut, speechEnd), heardEnd: cut, thenClose: true)
            }
        } else if speechEnd > committed, available - speechEnd >= Self.pause, ready?.speechEnd != speechEnd, !judgedNoise {
            recognize(committed..<end, speechEnd: speechEnd, heardEnd: soundEnd, judge: moment ? committed..<end : nil)
        } else if unheard, available - soundEnd >= Self.pause {
            // Only soft sound is new: recognized once the voice detector hears speech in it (without one, energy
            // decides: when unsure, recognize). Never alone, so faint music is heard as the whole file hears it.
            recognize(committed..<end, speechEnd: speechEnd, heardEnd: soundEnd, judge: heardUntil..<end)
        } else if speechEnd > committed, ready?.speechEnd != speechEnd, !judgedNoise, available - previewedAt >= previewInterval,
                  createdAt.duration(to: .now) >= Self.firstPreview {
            // Only the words since the last background result, so previews stay short on any Mac.
            previewTail((ready?.end ?? committed)..<available)
        }
    }

    /// Finishes the dictation: waits for work in flight, then uses the background result if nothing that might
    /// hold words came after it; otherwise recognizes the rest with the words before it. `samples` is the whole
    /// recording since the last split, up to the stop.
    func finish(_ samples: [Float]) async throws -> String {
        let stopped = ContinuousClock.now
        await job?.value
        await preview?.value
        let waited = stopped.duration(to: .now)
        if waited > .milliseconds(20) {
            Diagnostics.dictation.notice("finish: waited \(Self.milliseconds(waited), privacy: .public) ms for a pass in flight")
        }
        if samples.count > pauses.received { pauses.feed(Array(samples[pauses.received...])) }
        let start = min(committed, samples.count)
        // A background pass may have run a little past the stop (the padding after the last word); its words all came
        // before the stop, so it stands.
        if let ready, ready.heardEnd > samples.count { self.ready = nil }
        // With "Only listen to my voice", a background result made before the speaker check reached all of it stands
        // only if what it kept is still right.
        // The speaker check scores what it hasn't reached yet (usually the last window or two) before anything is kept.
        if let speakers { speakersAt = await speakers.catchUp(samples, offset: 0, final: true) }
        if let ready, readyIsProvisional, let speakers,
           await speakers.changed(start..<min(ready.end, samples.count), since: ready.speakersAt, final: true) {
            Diagnostics.dictation.notice("finish: speaker check changed the background result")
            self.ready = nil
        }
        if let ready {
            guard await mightHoldWords(samples[min(ready.end, samples.count)...]) else {
                Diagnostics.dictation.notice("finish: background result as is (\(ready.end - start, privacy: .public) samples)")
                close(ready); return text
            }
        } else {
            // Only audio that cannot hold words is skipped. Recognizers make words ("Yeah") out of silence, a key, a
            // breath or a cough, so until a voice has been recognized, a moment of sound counts only if it sounds like one.
            let open = samples[start...]
            let holdsWords = parts.isEmpty && pauses.speechFrames < Self.momentOfSound ? await soundsLikeAVoice(open) : await mightHoldWords(open)
            guard holdsWords else { return text }
        }
        let gap = gap(before: start)
        let words = try await recognizeRest(samples, from: start)
        parts.append((words, gap))
        ready = nil
        return text
    }

    /// The open part's words at the stop, each heard with the words before it: the whole part again in one pass when
    /// this Mac does that within `stopBudget`, otherwise the background result plus the newest words, recognized
    /// with the two seconds before them ("sheet" alone came back as "cheek").
    private func recognizeRest(_ samples: [Float], from start: Int) async throws -> String {
        guard let ready, samples.count - start > wholeAtStop else {
            Diagnostics.dictation.notice("finish: whole part (\(samples.count - start, privacy: .public) samples)")
            return try await Self.heard(by: speakers, from: start, final: true) { try await decode(Array(samples[start...]), true) }
        }
        // The new words begin after the last sound the background pass heard.
        let next = min(pauses.onset(atOrAfter: ready.heardEnd) ?? ready.end, ready.end, samples.count)
        let cut = (ready.heardEnd + max(ready.heardEnd, next)) / 2
        let timedCut = max(start, Self.newWords(after: ready.heardEnd))
        let lead = max(start, timedCut - Self.context)
        if decodeAfter != nil, lead == start {
            // The context pass would recognize this same whole part, then discard its prefix and join an older
            // result. Keep the complete current result instead: no extra audio or inference, and no boundary word
            // lost to imprecise token times (a short "I" can be timed just before the cut).
            Diagnostics.dictation.notice("finish: context covers whole part (\(samples.count - start, privacy: .public) samples)")
            return try await Self.heard(by: speakers, from: start, final: true) { try await decode(Array(samples[start...]), true) }
        }
        let newer: String
        if let decodeAfter, lead < timedCut {
            Diagnostics.dictation.notice("finish: new words with context (\(timedCut - lead, privacy: .public) + \(samples.count - timedCut, privacy: .public) samples)")
            newer = try await Self.heard(by: speakers, from: lead, final: true) { try await decodeAfter(Array(samples[lead...]), timedCut - lead) }
        } else {
            Diagnostics.dictation.notice("finish: new words (\(samples.count - cut, privacy: .public) samples)")
            newer = try await Self.heard(by: speakers, from: cut, final: true) { try await decode(Array(samples[cut...]), true) }
        }
        // The pause before the new words, measured to where they really start: `next` stops at the end of the background
        // pass's audio (its 0.25 s padding), which made every pause look short and took a sentence's period away.
        let onset = min(pauses.onset(atOrAfter: ready.heardEnd) ?? next, samples.count)
        let gap = Double(max(0, onset - ready.heardEnd)) / Double(Self.rate)
        return PhraseJoiner.join([(ready.text, 0), (newer, gap)])
    }

    /// Whether the newest audio might be words still running (sound in its last 150 ms). The stop then waits for the
    /// audio still in flight from the device, so a word finished right at the shortcut keeps its end.
    func soundsAtEnd() -> Bool {
        let available = count()
        if available > pauses.received { pauses.feed(read(pauses.received..<available)) }
        return available - max(pauses.lastSoundEnd, pauses.lastSpeechEnd) < Self.rate * 3 / 20
    }

    /// Where words after `heardEnd` (the end of the last sound already recognized) are timed from: one model frame
    /// (80 ms) before it. Parakeet times a word's first token up to a quarter second before the word is heard ("Please"
    /// after a 0.45 s pause came back timed 0.23 s early), while the last word before a pause starts well before it ends.
    static func newWords(after heardEnd: Int) -> Int { heardEnd - rate * 2 / 25 }

    /// Ends the current part (mid-dictation send) and starts over on fresh audio.
    /// The positions reset even when recognizing fails: the taken audio is gone either way, and positions left
    /// pointing into it would skip the words said after the split.
    func split(_ taken: [Float]) async throws -> String {
        defer {
            pauses = SpeechPauses(); parts = []; committed = 0; lastPartSpeechEnd = 0; ready = nil; previewedAt = 0; failed = false
            judgedUntil = 0
            speakerJob?.cancel(); speakerJob = nil; speakersFed = 0; speakersAt = 0
            speakers = speakers.map { SpeakerTrack(print: $0.print) }
        }
        return try await finish(taken)
    }

    /// Lets work in flight finish (the recognizer can't be interrupted mid-pass) and drops its results.
    func drain() async {
        job?.cancel(); preview?.cancel(); speakerJob?.cancel()
        await job?.value; await preview?.value; await speakerJob?.value
        job = nil; preview = nil; speakerJob = nil
    }

    /// Whether leftover audio might hold words: a voice-length run above the quiet bar, or speech by the voice
    /// detector (which hears speech under the bar). Recognized when either says so; never thrown away on a guess.
    private func mightHoldWords(_ samples: ArraySlice<Float>) async -> Bool {
        guard samples.count >= SpeechPauses.frame * SpeechPauses.minimumRun else { return false }
        if pauses.mightHoldWords(samples) { return true }
        return await hearsSpeech?(Array(samples)) ?? false
    }

    /// Speech frames (20 ms) below which a dictation with nothing recognized yet might be only a key, breath or cough.
    static let momentOfSound = 25

    /// Whether sound holds a voice: the voice detector decides when this Mac has it; without it (Intel), a voice-length
    /// run above the quiet bar.
    private func soundsLikeAVoice(_ samples: ArraySlice<Float>) async -> Bool {
        guard samples.count >= SpeechPauses.frame * SpeechPauses.minimumRun else { return false }
        if let heard = await hearsSpeech?(Array(samples)) { return heard }
        return pauses.mightHoldWords(samples)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }

    private func gap(before start: Int) -> Double {
        guard !parts.isEmpty, let onset = pauses.onset(atOrAfter: start) else { return 0 }
        return Double(max(0, onset - lastPartSpeechEnd)) / Double(Self.rate)
    }

    private func close(_ result: Result) {
        parts.append((result.text, gap(before: committed)))
        committed = result.end
        lastPartSpeechEnd = result.speechEnd
        previewedAt = result.end
        ready = nil
    }

    /// `judge`: quiet sound to check with the voice detector first; when it hears no speech there, nothing is
    /// recognized and that sound counts as judged.
    private func recognize(_ range: Range<Int>, speechEnd: Int, heardEnd: Int, thenClose: Bool = false, judge: Range<Int>? = nil) {
        let samples = read(range)
        let judged = judge.map(read)
        let decode = decode, hearsSpeech = hearsSpeech, speakers = speakers, speakersAt = speakers == nil ? Int.max : speakersAt
        let started = ContinuousClock.now
        // Background passes yield to the audio device and the interface; finishing waits on (and so raises) them.
        job = Task(priority: .utility) { [weak self] in
            if let judged, let hearsSpeech, await hearsSpeech(judged) == false {
                guard let self, !Task.isCancelled else { return }
                self.job = nil
                self.judgedUntil = max(self.judgedUntil, heardEnd)
                return
            }
            let result: String?
            do { result = try await Self.heard(by: speakers, from: range.lowerBound) { try await decode(samples, true) } } catch { result = nil }
            let took = started.duration(to: .now)
            Diagnostics.dictation.notice("pass: \(samples.count, privacy: .public) samples\(judged == nil ? "" : " (soft words)", privacy: .public) in \(Self.milliseconds(took), privacy: .public) ms")
            guard let self, !Task.isCancelled else { return }
            self.job = nil
            // Short passes are mostly fixed cost; only passes of 4 s or more say how fast this Mac is.
            if samples.count >= Self.rate * 4 {
                let seconds = Double(Self.milliseconds(took)) / 1000 / (Double(samples.count) / Double(Self.rate))
                Self.cost = (Self.cost + seconds) / 2
            }
            guard let result, range.lowerBound == self.committed else { self.failed = result == nil; return }
            let finished = (end: range.upperBound, speechEnd: speechEnd, heardEnd: heardEnd, text: result, speakersAt: speakersAt)
            if thenClose { self.close(finished) } else { self.ready = finished }
            self.previewedAt = max(self.previewedAt, range.upperBound)
            self.onText?(PhraseJoiner.join(self.parts + (thenClose ? [] : [(result, self.gap(before: range.lowerBound))])))
        }
    }

    /// Runs `work` (a recognition of samples starting at `offset`) with the speaker check in scope, so the voice
    /// step turns down every voice but the person's.
    private nonisolated static func heard<T: Sendable>(by speakers: SpeakerTrack?, from offset: Int, final: Bool = false,
                                                       _ work: () async throws -> T) async rethrows -> T {
        guard let speakers else { return try await work() }
        return try await SpeakerTrack.$scope.withValue(SpeakerTrack.Scope(track: speakers, offset: offset, final: final)) { try await work() }
    }

    /// Hands newly recorded audio to the speaker check, one batch at a time.
    private func listenForSpeakers(_ available: Int) {
        guard let speakers, speakerJob == nil else { return }
        let from = speakersFed
        guard available - from >= SpeakerMask.hop * VoiceActivity.chunk else { return }
        speakersFed = available
        let samples = read(from..<available)
        speakerJob = Task(priority: .utility) { [weak self] in
            let reached = await speakers.feed(samples, from: from)
            guard let self, !Task.isCancelled else { return }
            self.speakersAt = reached
            // A background result made before these scores: recognized again if they change what it kept.
            if let ready = self.ready, self.readyIsProvisional {
                let changed = await speakers.changed(self.committed..<ready.end, since: ready.speakersAt, final: false)
                if self.ready?.end == ready.end, self.ready?.speakersAt == ready.speakersAt {
                    if changed { self.ready = nil } else { self.ready?.speakersAt = reached }
                }
            }
            self.speakerJob = nil
        }
    }

    private func previewTail(_ range: Range<Int>) {
        previewedAt = range.upperBound
        let samples = read(range)
        let decode = decode, speakers = speakers
        let started = ContinuousClock.now
        preview = Task(priority: .utility) { [weak self] in
            let guess = try? await Self.heard(by: speakers, from: range.lowerBound) { try await decode(samples, false) }
            guard let self, !Task.isCancelled else { return }
            self.preview = nil
            // Slower Macs preview less often so the background pass is never kept waiting.
            let seconds = Double(Self.milliseconds(started.duration(to: .now))) / 1000
            self.previewInterval = max(Self.rate / 2, Int(seconds * 2 * Double(Self.rate)))
            guard range.lowerBound == (self.ready?.end ?? self.committed), let guess, !guess.isEmpty else { return }
            var shown = self.parts
            if let ready = self.ready { shown.append((ready.text, self.gap(before: self.committed))) }
            shown.append((guess, self.ready == nil ? self.gap(before: range.lowerBound) : 0.3))
            self.onText?(PhraseJoiner.join(shown))
        }
    }
}
