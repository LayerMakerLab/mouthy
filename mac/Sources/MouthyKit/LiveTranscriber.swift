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
///
/// The words since the last pass show in one of two ways: a fast guess by the same recognizer at the audio after it
/// (about ten a second), or, with "Show words instantly", the words of a streaming recognizer that hears the audio as
/// it arrives (`Stream`, `StreamedWords`). Those are behind the voice by a tenth of a second, not half a second.
@MainActor
final class LiveTranscriber {
    /// Recognizes 16 kHz samples; `boost` adds the slower vocabulary pass.
    typealias Decode = @Sendable (_ samples: [Float], _ boost: Bool) async throws -> String
    /// Recognizes 16 kHz samples with the vocabulary pass and returns the words that begin at or after sample `from`
    /// (and the words it heard before it): the audio before it is context, so the newest words are heard with the words
    /// that led up to them.
    typealias DecodeAfter = @Sendable (_ samples: [Float], _ from: Int) async throws -> ContextWords
    /// Recognizes 16 kHz samples once, without the vocabulary step, and returns the words on each side of sample `cut`
    /// by their token times (nil when it has none to go by): how the recognizer writes a pause it hears both sides of.
    typealias DecodeAround = @Sendable (_ samples: [Float], _ cut: Int) async throws -> ContextWords?
    /// A trained voice detector's verdict on 16 kHz samples; nil when none is on this Mac (energy decides alone).
    typealias HearsSpeech = @Sendable (_ samples: [Float]) async -> Bool?
    /// The streaming recognizer: hears newly recorded 16 kHz samples (`restart`: they begin a recording) and answers
    /// with every word since the restart. When it cannot, the fast guesses take over.
    typealias Stream = @Sendable (_ samples: [Float], _ restart: Bool) async -> StreamAnswer

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
    static var firstPreview = Duration.milliseconds(500)
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
    private let decodeAround: DecodeAround?
    private let hearsSpeech: HearsSpeech?
    private let count: () -> Int
    private let read: (Range<Int>) -> [Float]
    private var pauses = SpeechPauses()
    private var parts: [(text: String, gap: Double)] = []
    /// Samples already closed into `parts`.
    private(set) var committed = 0
    /// The end of the last sound the closed parts heard; the pause before the next part is measured from it.
    private var lastPartHeardEnd = 0
    /// The background result for `committed..<end`, valid while nobody has spoken past `speechEnd`. `heardEnd` is
    /// where the last sound it heard ended (speech or soft words); `end` adds the padding after it.
    private var ready: Result?
    /// `speakersAt`: the speaker check's `nextWindow` when it was recognized (Int.max without the check).
    private typealias Result = (end: Int, speechEnd: Int, heardEnd: Int, text: String, speakersAt: Int)
    /// Quiet sound up to here was judged not to be speech by the voice detector.
    private var judgedUntil = 0
    /// The join before the open part. A pause of `PhraseJoiner.sentencePause` there ends the sentence by the pause
    /// rule, and people pause that long in the middle of one to think ("not needing. To use a keyboard"): each side
    /// was recognized without the other, so only the pause could say. The audio around the pause is therefore
    /// recognized once more in one piece (`decodeAround`), and where that recognizer writes the sentence on, it goes
    /// on. Heard twice: after the first `seamFirst` of the new words, which wait for it (it then says "goes on" only
    /// when it does, and an end otherwise), and again with `seamWhole` of them when it heard an end. Not across a
    /// pause over `seamLongest` (the recognizer hears those as an end anyway), and not where that pass would take
    /// longer than `seamBudget` by the time the last one took (`seamCost`): the pause decides there, as before.
    private var seam: Seam?
    private struct Seam {
        /// Where the closed part's last sound ended.
        var heardEnd: Int
        var continues: Bool?
        /// How much of the new part the verdict heard.
        var heard = 0
        /// The part closed while the person was already talking on: words after it were shown, and stay shown.
        var talkedOn = false
    }
    static let seamBefore = rate * 2
    static let seamFirst = rate * 3 / 5
    static let seamWhole = rate * 3
    static let seamLongest = rate * 2
    static let seamBudget = 0.2
    /// Seconds a seam's pass takes per second of audio: measured on each one, and until then the plain guess.
    static var seamCost = plainCost
    private var job: Task<Void, Never>?
    private var preview: Task<Void, Never>?
    private var previewedAt = 0
    /// Audio between previews: 0.1 s where a preview is quick (an M5 takes about 40 ms), so live words follow the
    /// voice closely; slower Macs stretch it to twice what a preview takes.
    static var shortestPreviewInterval = rate / 10
    /// Live passes run at this priority. At `.utility` an Apple silicon Mac ran them on its efficiency cores, two
    /// to four times slower (367 ms for a 2.9 s pass with custom words, against about 160 ms), and nothing live can
    /// be shown while one runs. The audio thread is real-time and unaffected.
    static var livePriority = TaskPriority.userInitiated
    private var previewInterval = shortestPreviewInterval
    private var failed = false
    /// The stop or an Enter split is taking the words: a pass still in flight shows nothing more. Its text is the
    /// part being taken, and shown after the split it was typed again into the field that had just been sent.
    private var finishing = false
    private let createdAt = ContinuousClock.now
    /// "Only listen to my voice": who is speaking, checked in the background as audio arrives (nil when off).
    private var speakers: SpeakerTrack?
    private var speakerJob: Task<Void, Never>?
    private var speakersFed = 0
    /// The speaker check's `nextWindow` after its last batch.
    private var speakersAt = 0
    /// "Show words instantly": the streaming recognizer (nil: off, or it stopped), fed one batch at a time.
    private var stream: Stream?
    private var streamJob: Task<Void, Never>?
    /// Samples handed to it, and samples it has answered for.
    private var streamFed = 0
    private var streamHeard = 0
    private var streamed: [StreamedWord] = []
    /// A pass's text before its vocabulary step, shown until the pass itself is done (see `quickFirst`).
    private var early: (text: String, heardEnd: Int)?
    /// With the streaming recognizer and custom words: a pass first shows its text without the vocabulary step,
    /// which takes several times longer (on an M5 with 24 custom words 0.2 to 0.4 s, against 0.05 s). The capitals,
    /// punctuation and numbers then arrive that much sooner after a pause, and fewer of the words said meanwhile are
    /// typed again. Costs one more plain recognition per pass, so only where that is short (`quickBudget`): a stop that
    /// lands in it waits that much longer. Its time is kept out of `cost`, which sizes parts and the stop's work.
    var quickFirst = false
    static let quickBudget = 0.08
    /// Seconds a plain recognition takes per second of audio, measured like `cost` (which is the slower pass with
    /// the vocabulary step) and starting from the same guess.
    static var plainCost: Double = {
        #if arch(arm64)
        0.007
        #else
        0.06
        #endif
    }()
    private var lastShown = ""
    /// A pass's text the streaming recognizer's words are still to be checked against, once it has heard that far.
    private var unchecked: (text: String, range: Range<Int>)?
    /// Whether the live text's newest words come from the streaming recognizer. They never change by themselves, so
    /// they can be typed at once ("Type as I speak" otherwise waits for two guesses to agree).
    var streams: Bool { stream != nil }
    /// Custom words by their lowercase form: streamed words (always lowercase) show as the person spelled them.
    var spellings: [String: String] = [:]
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
    /// Set while `onText` is called with a pass's text of everything said up to a pause: whether the person was
    /// still silent when the pass was done, or had talked on (the fast guesses have those words).
    private(set) var textPause: LiveTyping.Pause?

    init(decode: @escaping Decode, decodeAfter: DecodeAfter? = nil, decodeAround: DecodeAround? = nil, hearsSpeech: HearsSpeech? = nil,
         speakers: SpeakerTrack? = SpeakerTrack.forDictation(), stream: Stream? = nil,
         count: @escaping () -> Int, read: @escaping (Range<Int>) -> [Float]) {
        self.speakers = speakers
        // The streaming recognizer hears every voice; with "Only listen to my voice" it would show the others' words.
        self.stream = speakers == nil ? stream : nil
        self.decode = decode
        self.decodeAfter = decodeAfter
        self.decodeAround = decodeAround
        self.hearsSpeech = hearsSpeech
        self.count = count
        self.read = read
    }

    /// Vocabulary terms written in lowercase (`PhraseJoiner.lowercaseTerms`): a part starting with one shows no case.
    var keepCase: Set<String> = []

    var text: String { PhraseJoiner.join(parts, keepCase: keepCase) }

    /// Call often (every ~100 ms) while recording.
    func tick() {
        let available = count()
        if available > pauses.received { pauses.feed(read(pauses.received..<available)) }
        listenForSpeakers(available)
        listenForWords(available)
        guard job == nil, preview == nil, !failed else { return }
        if hearSeam(available) { return }
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
        } else if stream == nil, speechEnd > committed, ready?.speechEnd != speechEnd, !judgedNoise, available - previewedAt >= previewInterval,
                  createdAt.duration(to: .now) >= Self.firstPreview {
            // Only the words since the last background result, so previews stay short on any Mac.
            previewTail((ready?.end ?? committed)..<available)
        }
    }

    /// The pause at the seam, when the seam is one to hear: a recognizer that can, a pause long enough to end a
    /// sentence and short enough to be a pause in one, and a pass that fits its budget. Otherwise the seam is dropped.
    private func seamPause() -> Int? {
        guard decodeAround != nil, let seam, !parts.isEmpty, let silence = pauses.silence(after: seam.heardEnd) else { return nil }
        guard Double(silence) / Double(Self.rate) >= PhraseJoiner.sentencePause, silence <= Self.seamLongest else { self.seam = nil; return nil }
        // (A verdict already given stands when a later pass is too slow to hear it again.)
        let longest = Double(Self.seamBefore + silence + Self.seamWhole) / Double(Self.rate)
        guard longest * Self.seamCost <= Self.seamBudget else { if seam.heard == 0 { self.seam = nil }; return nil }
        return silence
    }

    /// The audio around the seam, up to `available`: its range, where the pause's middle is, and how much of the new
    /// part that is. Nil when there is nothing (more) to hear: no seam to hear, a verdict that stands, or no more
    /// audio than the last one heard.
    private func seamAudio(upTo available: Int) -> (range: Range<Int>, cut: Int, heard: Int)? {
        guard let silence = seamPause(), let seam, seam.continues != true, seam.heard < Self.seamWhole else { return nil }
        let onset = seam.heardEnd + silence
        let heard = min(available - onset, Self.seamWhole)
        guard heard > seam.heard else { return nil }
        return (max(0, seam.heardEnd - Self.seamBefore)..<(onset + heard), seam.heardEnd + silence / 2, heard)
    }

    /// One pass over the audio around the seam: whether the sentence went on there, and what the pass cost.
    private static func judge(_ samples: [Float], cut: Int, with decodeAround: DecodeAround) async -> Bool? {
        let started = ContinuousClock.now
        let heard = try? await decodeAround(samples, cut)
        let took = milliseconds(started.duration(to: .now))
        // Short passes are mostly fixed cost; only one of 4 s or more says how fast this Mac is.
        if samples.count >= rate * 4 { seamCost = (seamCost + Double(took) / 1000 / (Double(samples.count) / Double(rate))) / 2 }
        let continues = heard.flatMap { $0 }.flatMap(PhraseJoiner.continues)
        Diagnostics.dictation.notice("seam: \(samples.count - cut, privacy: .public) samples after the pause's middle, \(continues.map { $0 ? "goes on" : "ends" } ?? "no verdict", privacy: .public), \(took, privacy: .public) ms")
        return continues
    }

    /// Hears the seam when it is time to. True while this tick is taken: the audio around the seam is being
    /// recognized, or the new part's first words wait until `seamFirst` of them can be.
    private func hearSeam(_ available: Int) -> Bool {
        guard let (range, cut, heard) = seamAudio(upTo: available), let seam, let decodeAround else { return false }
        guard heard >= (seam.heard == 0 ? Self.seamFirst : Self.seamWhole) else { return seam.heard == 0 }
        let samples = read(range), speakers = speakers
        preview = Task(priority: Self.livePriority) { [weak self] in
            let continues = await Self.heard(by: speakers, from: range.lowerBound) { await Self.judge(samples, cut: cut - range.lowerBound, with: decodeAround) }
            guard let self, !Task.isCancelled else { return }
            self.preview = nil
            guard self.seam?.heardEnd == seam.heardEnd else { return }
            self.seam?.heard = heard
            if let continues { self.seam?.continues = continues }
            // The streaming recognizer's words waited for this.
            if self.stream != nil { self.showStreamed() }
        }
        return true
    }

    /// Finishes the dictation: waits for work in flight, then uses the background result if nothing that might
    /// hold words came after it; otherwise recognizes the rest with the words before it. `samples` is the whole
    /// recording since the last split, up to the stop.
    func finish(_ samples: [Float]) async throws -> String {
        let stopped = ContinuousClock.now
        finishing = true
        // Nothing live is shown from here on. The streaming recognizer's batch in flight is dropped, and waited for:
        // it must not still be writing its state when the next part's audio starts it over.
        let streaming = streamJob
        streamJob = nil
        streaming?.cancel()
        await job?.value
        await preview?.value
        await streaming?.value
        let waited = stopped.duration(to: .now)
        if waited > .milliseconds(20) {
            Diagnostics.dictation.notice("finish: waited \(Self.milliseconds(waited), privacy: .public) ms for a pass in flight")
        }
        if samples.count > pauses.received { pauses.feed(Array(samples[pauses.received...])) }
        // A seam whose verdict has not heard all the words after it yet is heard with everything there is.
        if let (range, cut, _) = seamAudio(upTo: samples.count), let decodeAround,
           let continues = await Self.heard(by: speakers, from: range.lowerBound, { await Self.judge(Array(samples[range]), cut: cut - range.lowerBound, with: decodeAround) }) {
            seam?.continues = continues
        }
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
        let next = min(pauses.soundOnset(atOrAfter: ready.heardEnd) ?? ready.end, ready.end, samples.count)
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
        // The pause before the new words, measured in sound to where they really start: `next` stops at the end of the
        // background pass's audio (its 0.25 s padding), which made every pause look short and took a sentence's period away.
        let gap = Double(pauses.silence(after: ready.heardEnd) ?? max(0, next - ready.heardEnd)) / Double(Self.rate)
        if let decodeAfter, lead < timedCut {
            Diagnostics.dictation.notice("finish: new words with context (\(timedCut - lead, privacy: .public) + \(samples.count - timedCut, privacy: .public) samples)")
            let heard = try await Self.heard(by: speakers, from: lead, final: true) { try await decodeAfter(Array(samples[lead...]), timedCut - lead) }
            return PhraseJoiner.join(ready.text, heard: heard, gap: gap, keepCase: keepCase)
        }
        Diagnostics.dictation.notice("finish: new words (\(samples.count - cut, privacy: .public) samples)")
        let newer = try await Self.heard(by: speakers, from: cut, final: true) { try await decode(Array(samples[cut...]), true) }
        return PhraseJoiner.join([(ready.text, 0), (newer, gap)], keepCase: keepCase)
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
            pauses = SpeechPauses(); parts = []; committed = 0; lastPartHeardEnd = 0; ready = nil; previewedAt = 0; failed = false
            seam = nil
            finishing = false
            judgedUntil = 0
            speakerJob?.cancel(); speakerJob = nil; speakersFed = 0; speakersAt = 0
            streamJob?.cancel(); streamJob = nil; streamFed = 0; streamHeard = 0; streamed = []; lastShown = ""; early = nil; unchecked = nil
            speakers = speakers.map { SpeakerTrack(print: $0.print) }
        }
        return try await finish(taken)
    }

    /// Lets work in flight finish (the recognizer can't be interrupted mid-pass) and drops its results.
    func drain() async {
        job?.cancel(); preview?.cancel(); speakerJob?.cancel(); streamJob?.cancel()
        await job?.value; await preview?.value; await speakerJob?.value; await streamJob?.value
        job = nil; preview = nil; speakerJob = nil; streamJob = nil
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
        // Measured in sound, not loud speech: soft words the speech threshold misses are not a pause, and a part cut
        // while sound ran on (no pause long enough) continues its sentence. A stale loud-speech end made a 0.2 s breath
        // look like 6 s and kept the period mid-sentence ("noon. after").
        guard !parts.isEmpty else { return 0 }
        // The recognizer heard the sentence go on across this pause (`seam`): joined as a short pause is.
        if seam?.continues == true { return 0 }
        return Double(pauses.silence(after: lastPartHeardEnd) ?? max(0, start - lastPartHeardEnd)) / Double(Self.rate)
    }

    private func close(_ result: Result) {
        parts.append((result.text, gap(before: committed)))
        committed = result.end
        lastPartHeardEnd = result.heardEnd
        previewedAt = result.end
        ready = nil
        seam = Seam(heardEnd: result.heardEnd, talkedOn: pauses.lastSpeechEnd > result.end)
    }

    /// `judge`: quiet sound to check with the voice detector first; when it hears no speech there, nothing is
    /// recognized and that sound counts as judged.
    private func recognize(_ range: Range<Int>, speechEnd: Int, heardEnd: Int, thenClose: Bool = false, judge: Range<Int>? = nil) {
        let samples = read(range)
        let judged = judge.map(read)
        let decode = decode, hearsSpeech = hearsSpeech, speakers = speakers, speakersAt = speakers == nil ? Int.max : speakersAt
        let started = ContinuousClock.now
        job = Task(priority: Self.livePriority) { [weak self] in
            if let judged, let hearsSpeech, await hearsSpeech(judged) == false {
                guard let self, !Task.isCancelled else { return }
                self.job = nil
                self.judgedUntil = max(self.judgedUntil, heardEnd)
                return
            }
            var passStarted = started
            let seconds = Double(samples.count) / Double(Self.rate)
            // The plain step never takes longer than the whole pass does, so a slow measurement of it cannot outlast
            // `cost`, which every long pass corrects.
            if let self, self.stream != nil, self.quickFirst, !self.finishing,
               seconds * min(Self.plainCost, Self.cost) <= Self.quickBudget {
                let plainStarted = ContinuousClock.now
                let quick = try? await Self.heard(by: speakers, from: range.lowerBound, { try await decode(samples, false) })
                passStarted = .now
                if seconds >= 4 { Self.plainCost = (Self.plainCost + Double(Self.milliseconds(plainStarted.duration(to: passStarted))) / 1000 / seconds) / 2 }
                guard !Task.isCancelled else { return }
                // The stop came during the plain step: it recognizes what it needs itself, and must not wait for the
                // vocabulary step of a pass whose text would no longer be shown.
                if self.finishing { self.job = nil; return }
                if let quick, !quick.isEmpty, self.stream != nil, range.lowerBound == self.committed {
                    self.early = (quick, heardEnd)
                    self.showStreamed()
                }
            }
            let result: String?
            do { result = try await Self.heard(by: speakers, from: range.lowerBound) { try await decode(samples, true) } } catch { result = nil }
            let took = passStarted.duration(to: .now)
            Diagnostics.dictation.notice("pass: \(samples.count, privacy: .public) samples\(judged == nil ? "" : " (soft words)", privacy: .public) in \(Self.milliseconds(took), privacy: .public) ms\(passStarted == started ? "" : ", its plain text first", privacy: .public)")
            guard let self, !Task.isCancelled else { return }
            self.job = nil
            self.early = nil
            // Short passes are mostly fixed cost; only passes of 4 s or more say how fast this Mac is.
            if samples.count >= Self.rate * 4 {
                let seconds = Double(Self.milliseconds(took)) / 1000 / (Double(samples.count) / Double(Self.rate))
                Self.cost = (Self.cost + seconds) / 2
            }
            guard let result, range.lowerBound == self.committed else { self.failed = result == nil; return }
            let finished = (end: range.upperBound, speechEnd: speechEnd, heardEnd: heardEnd, text: result, speakersAt: speakersAt)
            let gap = self.gap(before: range.lowerBound)
            if thenClose { self.close(finished) } else { self.ready = finished }
            self.previewedAt = max(self.previewedAt, range.upperBound)
            guard !self.finishing else { return }
            self.unchecked = (result, range.lowerBound..<heardEnd)
            self.checkStream()
            // With the streaming recognizer, the words said since this pass's audio stay shown after its text.
            if self.stream != nil { self.showStreamed(); return }
            // A part closed while the person talks on says nothing about the words after its cut. The text shown keeps
            // them until the next guess, a moment later, has both: shown without them, "Type as I speak" took a
            // hundred characters back and typed them again.
            if thenClose, self.pauses.lastSpeechEnd > range.upperBound { return }
            self.textPause = self.pauses.lastSpeechEnd <= speechEnd ? .held : .talkedOn
            self.onText?(PhraseJoiner.join(self.parts + (thenClose ? [] : [(result, gap)]), keepCase: self.keepCase))
            self.textPause = nil
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

    /// Hands newly recorded audio to the streaming recognizer, one batch at a time, and shows its words.
    private func listenForWords(_ available: Int) {
        guard let stream, streamJob == nil, available > streamFed else { return }
        let from = streamFed
        streamFed = available
        let samples = read(from..<available)
        streamJob = Task(priority: Self.livePriority) { [weak self] in
            let answer = await stream(samples, from == 0)
            guard let self, !Task.isCancelled else { return }
            self.streamJob = nil
            guard case .words(let words) = answer else {
                // Still loading: it heard nothing, so the next batch is everything from the start again. It answers
                // at once, so a stop never waits for a model to load.
                if answer == .loading { self.streamFed = 0; return }
                Diagnostics.dictation.notice("live words: the streaming recognizer stopped, guesses take over")
                self.stream = nil
                return
            }
            self.streamed = words
            self.streamHeard = available
            self.checkStream()
            if self.stream != nil { self.showStreamed() }
        }
    }

    /// The live text with the streaming recognizer: closed parts, the latest background result, then the words it
    /// heard after that result's last sound. Shown under the rules a fast guess is: loud speech since the result, not
    /// in the first half second, and not sound the voice detector judged to be no voice.
    private func showStreamed() {
        guard !failed, !finishing else { return }
        var shown = parts
        // The pass in flight heard more than the last result: its text before the vocabulary step stands in.
        let newest = early ?? ready.map { ($0.text, $0.heardEnd) }
        if let newest { shown.append((newest.text, gap(before: committed))) }
        let cut = newest?.heardEnd ?? (parts.isEmpty ? nil : lastPartHeardEnd)
        // The first words after a seam wait for its first verdict here too, and are joined on as it says. Not words
        // that were shown before the part closed (a part cut while the person talks on): a hold never takes shown
        // words away.
        let waits = newest == nil && seam?.heard == 0 && seam?.talkedOn == false && seamPause() != nil
        let tail = waits ? [] : StreamedWords.after(cut, in: streamed)
        let speechEnd = pauses.lastSpeechEnd
        let moment = parts.isEmpty && newest == nil && pauses.speechFrames < Self.momentOfSound
        let judgedNoise = moment && judgedUntil >= max(pauses.lastSoundEnd, speechEnd)
        if let first = tail.first, speechEnd > (cut ?? 0), !judgedNoise, createdAt.duration(to: .now) >= Self.firstPreview {
            let silence = newest == nil && seam?.continues == true ? 0
                : cut.map { cut in Double(pauses.silence(after: cut) ?? max(0, first.at - cut)) / Double(Self.rate) } ?? 0
            let words = StreamedWords.written(tail, spellings: spellings)
            // The first words of a dictation begin a sentence, as the pass will write them.
            shown.append((shown.isEmpty ? SmartInsertion.capitalizingFirstWord(words) : words, silence))
        }
        let text = PhraseJoiner.join(shown, keepCase: keepCase)
        guard !text.isEmpty, text != lastShown else { return }
        lastShown = text
        onText?(text)
    }

    /// The streaming recognizer hears English only. When a pass heard something else in the same audio, the person
    /// is speaking another language (or it is lost), and it stops for the rest of this dictation.
    private func checkStream() {
        // Only audio it has answered for, with room for the last word's pieces; until then the check waits.
        guard stream != nil, let (text, range) = unchecked, streamHeard >= range.upperBound + Self.pause else { return }
        unchecked = nil
        let heard = streamed.filter { $0.at >= range.lowerBound && $0.at < range.upperBound + StreamedWords.seam }
        guard !StreamedWords.agrees(heard, with: text) else { return }
        Diagnostics.dictation.notice("live words: the streaming recognizer heard other words than the pass (another language?), guesses take over")
        stream = nil
        streamJob?.cancel(); streamJob = nil
        // Its words go from the live text at once; the next guess shows what was said since.
        var shown = parts
        if let ready { shown.append((ready.text, gap(before: committed))) }
        let without = PhraseJoiner.join(shown, keepCase: keepCase)
        if !without.isEmpty, without != lastShown { onText?(without) }
    }

    private func previewTail(_ range: Range<Int>) {
        previewedAt = range.upperBound
        let samples = read(range)
        let decode = decode, speakers = speakers
        let started = ContinuousClock.now
        preview = Task(priority: Self.livePriority) { [weak self] in
            let guess = try? await Self.heard(by: speakers, from: range.lowerBound) { try await decode(samples, false) }
            guard let self, !Task.isCancelled else { return }
            self.preview = nil
            // Slower Macs preview less often so the background pass is never kept waiting.
            let seconds = Double(Self.milliseconds(started.duration(to: .now))) / 1000
            self.previewInterval = max(Self.shortestPreviewInterval, Int(seconds * 2 * Double(Self.rate)))
            guard !self.finishing, range.lowerBound == (self.ready?.end ?? self.committed), let guess, !guess.isEmpty else { return }
            var shown = self.parts
            if let ready = self.ready { shown.append((ready.text, self.gap(before: self.committed))) }
            shown.append((guess, self.ready == nil ? self.gap(before: range.lowerBound) : 0.3))
            self.onText?(PhraseJoiner.join(shown, keepCase: self.keepCase))
        }
    }
}
