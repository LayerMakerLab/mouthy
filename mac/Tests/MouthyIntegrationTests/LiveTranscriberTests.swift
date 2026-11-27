import Foundation
import Testing
@testable import MouthyKit
import MouthyCore

// Which audio LiveTranscriber recognizes, and with how much context, against a scripted recognizer and synthetic
// tone bursts. No models, microphone or real time: the recording grows 100 ms per tick.

/// Records every recognition request (sample count, vocabulary pass, where the kept words start).
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(count: Int, boost: Bool, from: Int?)] = []
    func add(_ count: Int, _ boost: Bool, _ from: Int? = nil) { lock.withLock { log.append((count, boost, from)) } }
    var all: [(count: Int, boost: Bool, from: Int?)] { lock.withLock { log } }
    var final: (count: Int, boost: Bool, from: Int?)? { all.last { $0.boost } }
}

@MainActor
private struct Recording {
    static let rate = 16_000
    var samples: [Float] = []
    mutating func speak(_ seconds: Double, level: Float = 0.1) {
        let start = samples.count
        samples += (0..<Int(seconds * Double(Self.rate))).map { level * sin(Float(start + $0) * 0.2) }
    }
    mutating func pause(_ seconds: Double) { samples += [Float](repeating: 0, count: Int(seconds * Double(Self.rate))) }

    /// Replays the recording into a transcriber 100 ms at a time, letting each background pass finish, then stops.
    /// `cost`: seconds the scripted recognizer takes per second of audio.
    func replay(_ calls: Calls, context: Bool = true, cost: Double = 0, hearsSpeech: LiveTranscriber.HearsSpeech? = nil) async throws -> (text: String, finishCalls: ArraySlice<(count: Int, boost: Bool, from: Int?)>) {
        let audio = samples
        var recorded = 0
        let live = LiveTranscriber(decode: { samples, boost in
            calls.add(samples.count, boost)
            if cost > 0 { try await Task.sleep(for: .seconds(cost * Double(samples.count) / Double(Self.rate))) }
            return "w\(samples.count)"
        },
                                   decodeAfter: context ? { samples, from in calls.add(samples.count, true, from); return ContextWords(after: "t\(samples.count - from)") } : nil,
                                   hearsSpeech: hearsSpeech, count: { recorded }, read: { Array(audio[$0.clamped(to: 0..<recorded)]) })
        while recorded < audio.count {
            recorded = min(audio.count, recorded + Self.rate / 10)
            live.tick()
            for _ in 0..<5 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(2))
        }
        let before = calls.all.count
        let text = try await live.finish(audio)
        return (text, calls.all[before...])
    }
}

/// A scripted streaming recognizer ("Show words instantly"): each word shows once the audio 0.15 s past where it was
/// said has been fed. `restart` starts its audio over, as a new recording does.
private final class Streamer: @unchecked Sendable {
    private let lock = NSLock()
    private let script: [(word: String, at: Double)]
    private var fed = 0, restartCount = 0, failing = false, loadingBatches = 0
    init(_ script: [(String, Double)]) { self.script = script.map { (word: $0.0, at: $0.1) } }
    var restarts: Int { lock.withLock { restartCount } }
    func fail() { lock.withLock { failing = true } }
    /// Its model is still loading for this many batches: it hears nothing of them.
    func load(for batches: Int) { lock.withLock { loadingBatches = batches } }
    func hear(_ samples: [Float], _ restart: Bool) -> StreamAnswer {
        lock.withLock {
            if failing { return .failed }
            if loadingBatches > 0 { loadingBatches -= 1; return .loading }
            if restart { fed = 0; restartCount += 1 }
            fed += samples.count
            return .words(script.filter { Int(($0.at + 0.15) * 16_000) <= fed }.map { StreamedWord($0.word, at: Int($0.at * 16_000)) })
        }
    }
}

/// Replays `audio` into a transcriber with the scripted streaming recognizer, 100 ms at a time, and returns every
/// live text it showed. `passes`: what a pass (with the vocabulary step) and a plain recognition answer.
@MainActor
private func stream(_ audio: [Float], _ streamer: Streamer, pass: String, plain: String = "", cost: Duration = .zero, quickFirst: Bool = false,
                    around: LiveTranscriber.DecodeAround? = nil,
                    then: (LiveTranscriber, [String]) async throws -> Void = { _, _ in }) async throws -> [String] {
    let saved = LiveTranscriber.firstPreview
    defer { LiveTranscriber.firstPreview = saved }
    LiveTranscriber.firstPreview = .zero
    var recorded = 0, shown: [String] = []
    let live = LiveTranscriber(decode: { _, boost in
        if boost, cost > .zero { try await Task.sleep(for: cost) }
        return boost ? pass : plain
    }, decodeAround: around, speakers: nil, stream: { samples, restart in streamer.hear(samples, restart) }, count: { recorded }, read: { Array(audio[$0.clamped(to: 0..<recorded)]) })
    live.quickFirst = quickFirst
    live.onText = { shown.append($0) }
    while recorded < audio.count {
        recorded = min(audio.count, recorded + Recording.rate / 10)
        live.tick()
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(2))
    }
    // Long enough for a pass still in flight: the stop silences whatever has not shown by then.
    try await Task.sleep(for: cost * 3 + .milliseconds(40))
    try await then(live, shown)
    _ = try await live.finish(audio)
    return shown
}

/// Seconds per second of audio: an M5 with Parakeet, and an Intel Mac (Parakeet on the CPU).
private let fast = 0.007, intel = 0.06

/// Serialized: this Mac's measured speed (`LiveTranscriber.cost`) is shared by every transcriber.
@MainActor @Suite(.serialized) struct LiveTranscriberTests {

@Test func partialAudioFramesAreReadOnlyOnce() async throws {
    var available = 137
    let audio = [Float](repeating: 0, count: 2_000)
    var reads: [Range<Int>] = []
    let live = LiveTranscriber(decode: { _, _ in "" }, speakers: nil, count: { available }, read: {
        reads.append($0)
        return Array(audio[$0])
    })
    for _ in 0..<8 { live.tick() }
    #expect(reads == [0..<137], "a partial 20 ms frame is retained; unchanged input must not be read again")
    available = 911
    live.tick()
    #expect(reads.last == 137..<911, "only new samples are handed to the pause detector")
    _ = live.soundsAtEnd()
    #expect(reads.count == 2, "checking the stop must not feed the partial frame a second time")
    #expect(try await live.finish(Array(audio[..<available])).isEmpty)
}

/// Runs `body` as if this Mac recognized at `cost`, then restores the measured speed.
private func on(_ cost: Double, _ body: () async throws -> Void) async rethrows {
    let saved = LiveTranscriber.cost
    defer { LiveTranscriber.cost = saved }
    LiveTranscriber.cost = cost
    try await body()
}

@Test func shortDictationWithLongPausesIsRecognizedWhole() async throws {
    for cost in [fast, intel] {
        try await on(cost) {
            // Phrases split by 1.2 s and 3 s pauses: each used to close a part, so the last phrase was heard alone.
            var recording = Recording()
            recording.pause(0.3); recording.speak(1.2); recording.pause(1.2); recording.speak(1.2); recording.pause(3); recording.speak(1); recording.pause(0.4)
            let calls = Calls()
            let result = try await recording.replay(calls)
            // One part: the last background pass covered the whole recording from its first sample.
            let final = try #require(calls.final)
            #expect(final.from == nil)
            #expect(final.count >= recording.samples.count - Recording.rate / 2)
            #expect(!result.text.contains(" "))
        }
    }
}

@Test func everyBackgroundPassHearsTheWholePart() async throws {
    for cost in [fast, intel] {
        try await on(cost) {
            // Short phrases with short pauses: no pass may hear only the newest phrase (a quiet first phrase one
            // pass missed is heard again by the next).
            var recording = Recording()
            recording.pause(0.3)
            for _ in 0..<4 { recording.speak(0.8); recording.pause(0.3) }
            let calls = Calls()
            _ = try await recording.replay(calls)
            let passes = calls.all.filter(\.boost).map(\.count)
            #expect(passes.count >= 3)
            #expect(passes == passes.sorted())
            #expect(passes.dropFirst().allSatisfy { $0 > Recording.rate * 2 })
        }
    }
}

@Test func wordsAfterTheLastPassAreRecognizedWithTheWholePart() async throws {
    try await on(fast) {
        // The stop lands while the person is still finishing a word, before any pause after it.
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.5); recording.pause(0.5); recording.speak(0.6)
        let calls = Calls()
        let result = try await recording.replay(calls)
        let finish = try #require(result.finishCalls.last)
        #expect(finish.count == recording.samples.count)   // the whole part again, not just the last words
        #expect(finish.from == nil)
        #expect(result.text == "w\(recording.samples.count)")
    }
}

@Test func longPartsGiveTheLastWordsTwoSecondsOfContext() async throws {
    // 18 s of talk with only short pauses is too long to recognize again at the stop on a fast Mac; on an Intel
    // Mac anything over 2.5 s is.
    for (cost, phrases) in [(fast, 9), (intel, 2)] {
        try await on(cost) {
            var recording = Recording()
            recording.pause(0.3)
            for _ in 0..<phrases { recording.speak(1.6); recording.pause(0.4) }
            recording.speak(0.8)
            let calls = Calls()
            let result = try await recording.replay(calls)
            let finish = try #require(result.finishCalls.last)
            let from = try #require(finish.from)
            // Context is about two seconds before the new words; only the new words are kept.
            #expect(from >= Recording.rate * 3 / 2 && from <= Recording.rate * 5 / 2)
            #expect(finish.count - from < Recording.rate * 2)
            #expect(result.text.hasSuffix("t\(finish.count - from)"))
        }
    }
}

@Test func aStopWaitsForAudioInFlightOnlyWhileSoundIsRunning() {
    // A word running into the stop (sound in the newest 150 ms) waits for the device's audio still on its way; a stop
    // after a pause does not.
    for (trailing, waits) in [(0.0, true), (0.1, true), (0.3, false)] {
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.2); recording.pause(trailing)
        let audio = recording.samples
        let live = LiveTranscriber(decode: { _, _ in "" }, count: { audio.count }, read: { Array(audio[$0]) })
        #expect(live.soundsAtEnd() == waits, "\(trailing) s of silence before the stop")
    }
}

@Test func silenceAfterTheLastPassIsNotRecognizedAgain() async throws {
    try await on(fast) {
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.5); recording.pause(0.8)
        let calls = Calls()
        let result = try await recording.replay(calls)
        #expect(result.finishCalls.isEmpty)   // the background result is used as is: nothing to wait for
        #expect(result.text.hasPrefix("w"))
    }
}

@Test func wholePartAgainStaysWithinTheStopBudget() async throws {
    // An engine that takes 30 ms per second of audio (Whisper, an older Mac): 5 s fits the 150 ms budget, 6 s does not.
    try await on(0.03) {
        var recording = Recording()
        recording.pause(0.3); recording.speak(4.5); recording.pause(0.5); recording.speak(0.8)
        let calls = Calls()
        let result = try await recording.replay(calls, cost: 0.03)
        #expect(LiveTranscriber.cost >= 0.025)
        let finish = try #require(result.finishCalls.last)
        #expect(finish.from != nil)   // the context decode, not the whole 6 s part again
    }
}

@Test func aContextPassCoveringTheWholePartKeepsItsWholeResult() async throws {
    try await on(intel) {
        // A short first clause leaves less than two seconds of context before the next words. The final
        // context pass therefore hears the whole recording anyway. On Intel the token for "I" in this
        // sentence was timed 40 ms before the splice and discarded even though that pass recognized it.
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.2); recording.pause(0.3); recording.speak(3.4)
        let audio = recording.samples
        let expected = "The morning light filled the garden, I made a cup of coffee."
        let rate = Recording.rate
        let calls = Calls()
        var recorded = 0
        let live = LiveTranscriber(decode: { samples, boost in
            calls.add(samples.count, boost)
            return samples.count < rate * 2 ? "The morning light filled the garden." : expected
        }, decodeAfter: { samples, from in
            calls.add(samples.count, true, from)
            return ContextWords(after: "made a cup of coffee.")
        }, speakers: nil, count: { recorded }, read: { Array(audio[$0.clamped(to: 0..<recorded)]) })
        while recorded < audio.count {
            recorded = min(audio.count, recorded + Recording.rate / 10)
            live.tick()
            for _ in 0..<5 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(2))
        }
        let before = calls.all.count
        let result = try await live.finish(audio)
        #expect(result == expected, "keep the complete result when the context pass covers the whole part")
        #expect(calls.all.count == before + 1, "finishing must still use exactly one recognition pass")
        let finish = try #require(calls.final)
        #expect(finish.count == audio.count, "the corrected pass must not decode any additional audio")
        #expect(finish.from == nil, "do not discard words from an already complete result")
    }
}

@Test func softWordsAfterTheLastPassAreNeverDropped() async throws {
    for cost in [fast, intel] {
        try await on(cost) {
            // A loud phrase, then a soft ending under the speech threshold, stopped right after it: the soft words
            // used to be thrown away because the speech threshold heard nothing after the background result.
            var recording = Recording()
            recording.pause(0.3); recording.speak(1.5); recording.pause(0.4); recording.speak(0.9, level: 0.004)
            let calls = Calls()
            let result = try await recording.replay(calls)
            let finish = try #require(result.finishCalls.last, "the soft ending was not recognized")
            // A fast Mac recognizes the whole part again; an Intel Mac the soft words with the words before them.
            let kept = finish.count - (finish.from ?? 0)
            #expect(kept >= Int(0.9 * Double(Recording.rate)))
            #expect(result.text.contains("\(kept)"))
        }
    }
}

@Test func softWordsBeforeAPauseAreRecognizedInTheBackground() async throws {
    try await on(fast) {
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.5); recording.pause(0.4); recording.speak(0.9, level: 0.004); recording.pause(0.6)
        let calls = Calls()
        let result = try await recording.replay(calls, hearsSpeech: { samples in samples.contains { abs($0) > 0.001 } })
        // A background pass took in the soft words, so the stop had nothing left to do.
        #expect(result.finishCalls.isEmpty)
        #expect(calls.all.contains { $0.boost && $0.count >= Int(3.0 * Double(Recording.rate)) })
    }
}

@Test func soundTheVoiceDetectorCallsNoiseIsNotRecognizedInTheBackground() async throws {
    try await on(fast) {
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.5); recording.pause(0.4); recording.speak(0.5, level: 0.004); recording.pause(0.6)
        let calls = Calls()
        let result = try await recording.replay(calls, hearsSpeech: { _ in false })
        // No background pass for the noise; at the stop the quiet check still says it might be words, so it is recognized.
        #expect(!calls.all.dropLast(result.finishCalls.count).contains { $0.boost && $0.count >= Int(2.3 * Double(Recording.rate)) })
        #expect(!result.finishCalls.isEmpty)
    }
}

@Test func silenceIsNeverRecognized() async throws {
    // Recognizers make words out of silence ("Yeah"), so a dictation where nothing was said recognizes nothing,
    // with the voice detector and without it (Intel Macs).
    let detectors: [LiveTranscriber.HearsSpeech?] = [{ _ in false }, nil]
    for detector in detectors {
        try await on(fast) {
            var recording = Recording()
            recording.pause(1.0); recording.speak(0.04, level: 0.3); recording.pause(1.5)   // a key click in a quiet room
            let calls = Calls()
            let result = try await recording.replay(calls, hearsSpeech: detector)
            #expect(calls.all.isEmpty)
            #expect(result.text.isEmpty)
        }
    }
}

@Test func aMomentOfSoundIsRecognizedOnlyWhenItSoundsLikeAVoice() async throws {
    for voice in [false, true] {
        try await on(fast) {
            // A cough or a breath (0.3 s of loud sound) and nothing else: only the voice detector can tell it from "yes".
            var recording = Recording()
            recording.pause(0.8); recording.speak(0.3, level: 0.2); recording.pause(1.2)
            let calls = Calls()
            let result = try await recording.replay(calls, hearsSpeech: { _ in voice })
            #expect(calls.all.contains { $0.boost } == voice)
            #expect(result.text.isEmpty == !voice)
        }
    }
}

@Test func aSoftVoiceAloneIsStillRecognized() async throws {
    try await on(fast) {
        // Nothing passes the speech threshold, but the voice detector hears speech, so it is recognized.
        var recording = Recording()
        recording.pause(0.5); recording.speak(1.2, level: 0.003); recording.pause(0.3)
        let calls = Calls()
        let result = try await recording.replay(calls, hearsSpeech: { samples in samples.contains { abs($0) > 0.001 } })
        #expect(calls.all.contains { $0.boost })
        #expect(!result.text.isEmpty)
    }
}

@Test func aSentenceBreakBeforeTheLastWordsKeepsItsPeriod() async throws {
    try await on(intel) {
        // A phrase, a full second's pause (a new sentence), then the last words right before the stop: the stop
        // recognizes only the last words, and the pause between must still read as a sentence break.
        var recording = Recording()
        recording.pause(0.3); recording.speak(2.0); recording.pause(1.0); recording.speak(0.8)
        let calls = Calls()
        let result = try await recording.replay(calls)
        #expect(result.finishCalls.last?.from != nil, "the stop took the context path")
        #expect(result.text.contains(". "), "\(result.text)")
    }
}

/// Replays `audio` 100 ms at a time into a transcriber with a scripted recognizer and stops. Returns the finished
/// text and every live text shown on the way. `around`: the recognizer's words on each side of a pause.
@MainActor private func play(_ audio: [Float], around: LiveTranscriber.DecodeAround? = nil, decode: @escaping LiveTranscriber.Decode) async throws -> (text: String, shown: [String]) {
    let saved = (LiveTranscriber.firstPreview, LiveTranscriber.seamCost)
    defer { (LiveTranscriber.firstPreview, LiveTranscriber.seamCost) = saved }
    LiveTranscriber.firstPreview = .zero
    var recorded = 0, shown: [String] = []
    let live = LiveTranscriber(decode: decode, decodeAround: around, speakers: nil, count: { recorded }, read: { Array(audio[$0.clamped(to: 0..<recorded)]) })
    live.onText = { shown.append($0) }
    while recorded < audio.count {
        recorded = min(audio.count, recorded + Recording.rate / 10)
        live.tick()
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(2))
    }
    return (try await live.finish(audio), shown)
}

/// Two parts that meet at a pause: five seconds of speech, the pause, two more seconds. (The scripted recognizer
/// answers at once, which halves the measured cost: at 0.2 parts are six seconds, so the pause closes the first.)
@MainActor private func twoParts(pause: Double, seamCost: Double = fast, around: LiveTranscriber.DecodeAround?) async throws -> (text: String, shown: [String]) {
    var result: (text: String, shown: [String]) = ("", [])
    try await on(0.2) {
        LiveTranscriber.seamCost = seamCost
        defer { LiveTranscriber.seamCost = fast }
        var recording = Recording()
        recording.pause(0.3); recording.speak(5); recording.pause(pause); recording.speak(2); recording.pause(0.4)
        result = try await play(recording.samples, around: around) { samples, boost in
            guard boost else { return "To use" }
            return samples.count > 5 * 16_000 ? "We plan the beds without needing." : "To use a ruler."
        }
    }
    return result
}

@Test func aLongPauseWhereTwoPartsMeetEndsTheSentenceOnlyWhenTheRecognizerHearsItEnd() async throws {
    // A part closes at a 1.4 s pause, and the next begins with "To": each was recognized without the other. The
    // audio around the pause is recognized once more in one piece, its words split at the pause's middle.
    let goesOn = try await twoParts(pause: 1.4) { samples, cut in
        // 2 s before the pause, the pause, and what there is of the new words; the cut is the pause's middle.
        #expect((2 * 16_000 + 8_000...2 * 16_000 + 12_800).contains(cut) && samples.count > cut, "\(cut) of \(samples.count)")
        return ContextWords(before: "the beds without needing", after: "to use a ruler")
    }
    #expect(goesOn.text == "We plan the beds without needing to use a ruler.")
    // The new part's first words wait for that verdict: a period and capital typed live would stay in the field.
    #expect(!goesOn.shown.contains { $0.contains("needing. ") }, "\(goesOn.shown)")
    // The recognizer hears the sentence end, or cannot say: the pause ends it, as before.
    let ends = try await twoParts(pause: 1.4) { _, _ in ContextWords(before: "the beds without needing.", after: "To use a ruler") }
    #expect(ends.text == "We plan the beds without needing. To use a ruler.")
    let unknown = try await twoParts(pause: 1.4) { _, _ in nil }
    #expect(unknown.text == "We plan the beds without needing. To use a ruler.")
    let none = try await twoParts(pause: 1.4, around: nil)
    #expect(none.text == "We plan the beds without needing. To use a ruler.")
}

@Test func aSeamIsHeardOnlyWhereThatIsQuickAndThePauseIsShort() async throws {
    let asked = Calls()
    let around: LiveTranscriber.DecodeAround = { samples, _ in asked.add(samples.count, false); return ContextWords(before: "needing", after: "to use") }
    // A Mac where that pass would take longer than its budget (7 s of audio at Intel speed): never run.
    let slow = try await twoParts(pause: 1.4, seamCost: intel, around: around)
    #expect(slow.text == "We plan the beds without needing. To use a ruler." && asked.all.isEmpty)
    // A pause of 2.5 s is an end, whatever comes after it.
    let long = try await twoParts(pause: 2.5, around: around)
    #expect(long.text == "We plan the beds without needing. To use a ruler." && asked.all.isEmpty, "\(long.text) \(asked.all)")
    // A short pause continues the sentence by the pause rule alone.
    let short = try await twoParts(pause: 1.1, around: around)
    #expect(short.text == "We plan the beds without needing to use a ruler." && !asked.all.isEmpty)
}

@Test func aPartClosedWhileThePersonTalksOnKeepsTheWordsAfterItShown() async throws {
    try await on(0.2) {
        // Ten seconds with one short pause, more than a part holds: the part closes at the pause while the person
        // talks on. The live text must not lose the words after the cut for a moment ("Type as I speak" took them
        // all back and typed them again).
        var recording = Recording()
        recording.pause(0.3); recording.speak(5); recording.pause(0.3); recording.speak(6); recording.pause(0.3)
        let result = try await play(recording.samples) { samples, _ in "w\(samples.count)" }
        let counts = result.shown.map { $0.split(separator: " ").count }
        let two = try #require(counts.firstIndex(of: 2), "\(result.shown)")
        #expect(!counts[two...].contains(1), "\(result.shown)")
        #expect(result.text.split(separator: " ").count == 2)
    }
}

@Test func streamedWordsShowAtOnceAndFollowThePassThatHeardTheWordsBeforeThem() async throws {
    try await on(fast) {
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.0); recording.pause(0.5); recording.speak(1.0)
        let streamer = Streamer([("alpha", 0.5), ("beta", 1.0), ("gamma", 2.0), ("delta", 2.5)])
        let shown = try await stream(recording.samples, streamer, pass: "First part.") { live, _ in #expect(live.streams) }
        // Each word as it is said; the pass at the pause writes the words it heard, and only the words said after its
        // last sound follow it (never "beta" again, never "gamma" missing).
        #expect(shown == ["Alpha", "Alpha beta", "First part.", "First part gamma", "First part gamma delta"], "\(shown)")
    }
}

@Test func streamedWordsSaidDuringAPassStayAfterItsText() async throws {
    try await on(fast) {
        // The pass takes 0.4 s; the person goes on talking 0.3 s after pausing. The live text never loses "gamma".
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.0); recording.pause(0.3); recording.speak(1.2)
        let streamer = Streamer([("alpha", 0.5), ("beta", 1.0), ("gamma", 1.7), ("delta", 2.2)])
        let shown = try await stream(recording.samples, streamer, pass: "First part.", cost: .milliseconds(40))
        let first = try #require(shown.firstIndex { $0.contains("gamma") })
        #expect(shown[first...].allSatisfy { $0.contains("gamma") }, "\(shown)")
        #expect(shown.last == "First part gamma delta", "\(shown)")
    }
}

@Test func streamedWordsShownBeforeAPartClosesAreNeverHeldBack() async throws {
    // A part is cut at its 0.9 s pause while the person talks on: "gamma" and "delta" were shown before the cut was
    // made. The join there waits for its verdict, but a hold never takes shown words away (typed live, they were
    // deleted and typed again).
    let seamCost = LiveTranscriber.seamCost
    defer { LiveTranscriber.seamCost = seamCost }
    LiveTranscriber.seamCost = fast
    try await on(0.2) {
        var recording = Recording()
        recording.pause(0.3); recording.speak(3.5); recording.pause(0.9); recording.speak(6); recording.pause(0.3)
        let streamer = Streamer([("alpha", 1.0), ("beta", 2.5), ("gamma", 5.0), ("delta", 5.5), ("epsilon", 8.0)])
        let shown = try await stream(recording.samples, streamer, pass: "First part.", around: { _, _ in ContextWords(before: "part", after: "gamma") })
        let first = try #require(shown.firstIndex { $0.contains("gamma") }, "\(shown)")
        // (The scripted pass answers "First part." for the second part too, at its end.)
        #expect(!shown[first...].contains("First part."), "\(shown)")
        #expect(shown.contains("First part gamma delta"), "\(shown)")
    }
}

@Test func aPassShowsItsTextBeforeTheVocabularyStepWithCustomWords() async throws {
    try await on(fast) {
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.0); recording.pause(0.6)
        let streamer = Streamer([("alpha", 0.5), ("beta", 1.0)])
        let shown = try await stream(recording.samples, streamer, pass: "Alpha Beta.", plain: "Alpha beta.", cost: .milliseconds(30), quickFirst: true)
        #expect(shown == ["Alpha", "Alpha beta", "Alpha beta.", "Alpha Beta."], "\(shown)")
    }
}

@Test func theStreamingRecognizerStopsWhenThePassHeardAnotherLanguage() async throws {
    try await on(fast) {
        var recording = Recording()
        recording.pause(0.3); recording.speak(2.0); recording.pause(0.6); recording.speak(0.6)
        let words = ["the", "nex", "the", "tack", "is", "a", "see", "the"].enumerated().map { ($0.element, 0.4 + Double($0.offset) * 0.2) }
        let streamer = Streamer(words + [("fen", 3.1)])
        let shown = try await stream(recording.samples, streamer, pass: "Der nächste Tag ist dazu da, die Fenster zu putzen.") { live, _ in
            #expect(!live.streams)
        }
        // Its words leave the live text with the pass, and none come back.
        let pass = try #require(shown.firstIndex { $0.hasPrefix("Der") })
        #expect(shown[pass...].allSatisfy { !$0.contains("fen") && !$0.contains("tack") }, "\(shown)")
    }
}

@Test func aStreamingRecognizerStillLoadingHearsEverythingOnceItIsReady() async throws {
    try await on(fast) {
        // The model loads during the first six batches (0.6 s): they are answered at once with nothing heard, and the
        // audio is sent again from the start, so the first word is not lost and its time is right.
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.5)
        let streamer = Streamer([("alpha", 0.4), ("beta", 1.0), ("gamma", 1.5)])
        streamer.load(for: 6)
        let shown = try await stream(recording.samples, streamer, pass: "First part.") { live, _ in #expect(live.streams) }
        #expect(streamer.restarts == 1)
        #expect(shown == ["Alpha beta", "Alpha beta gamma"] || shown == ["Alpha", "Alpha beta", "Alpha beta gamma"], "\(shown)")
    }
}

@Test func theStreamingRecognizerFailingBringsTheGuessesBack() async throws {
    try await on(fast) {
        var recording = Recording()
        recording.pause(0.3); recording.speak(2.0)
        let streamer = Streamer([("alpha", 0.5)])
        streamer.fail()
        let shown = try await stream(recording.samples, streamer, pass: "First part.", plain: "a guess") { live, _ in #expect(!live.streams) }
        #expect(shown.contains("a guess"), "\(shown)")
    }
}

@Test func theStreamingRecognizerStartsOverAfterASplit() async throws {
    try await on(fast) {
        var first = Recording()
        first.pause(0.3); first.speak(1.0); first.pause(0.1)
        var second = Recording()
        second.pause(0.2); second.speak(1.0)
        let streamer = Streamer([("alpha", 0.5), ("beta", 1.0)])
        let saved = LiveTranscriber.firstPreview
        defer { LiveTranscriber.firstPreview = saved }
        LiveTranscriber.firstPreview = .zero
        var audio = first.samples, recorded = 0, shown: [String] = []
        let live = LiveTranscriber(decode: { _, _ in "Sent." }, speakers: nil, stream: { samples, restart in streamer.hear(samples, restart) },
                                   count: { recorded }, read: { Array(audio[$0.clamped(to: 0..<recorded)]) })
        live.onText = { shown.append($0) }
        @MainActor func play() async throws {
            while recorded < audio.count {
                recorded = min(audio.count, recorded + Recording.rate / 10)
                live.tick()
                for _ in 0..<5 { await Task.yield() }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        try await play()
        #expect(shown.last == "Alpha beta")
        // Enter: the words so far are taken, and the recording starts over.
        _ = try await live.split(audio)
        audio = second.samples; recorded = 0; shown = []
        try await play()
        #expect(streamer.restarts == 2)
        // Its audio began again: the same script plays from the start, and nothing from before the split is shown.
        #expect(shown == ["Alpha", "Alpha beta"], "\(shown)")
        _ = try await live.finish(audio)
    }
}

@Test func aPassInFlightWhenEnterIsPressedShowsNothingAfterwards() async throws {
    try await on(fast) {
        // The pass that starts at the pause is still running when Enter takes the part. Its text is the part being
        // sent: shown after the split, it was typed again into the field that had just been emptied.
        var recording = Recording()
        recording.pause(0.3); recording.speak(1.0); recording.pause(0.4)
        let audio = recording.samples
        var recorded = 0, shown: [String] = []
        let live = LiveTranscriber(decode: { _, _ in
            try await Task.sleep(for: .milliseconds(80))
            return "See you then."
        }, speakers: nil, count: { recorded }, read: { Array(audio[$0.clamped(to: 0..<recorded)]) })
        live.onText = { shown.append($0) }
        while recorded < audio.count {
            recorded = min(audio.count, recorded + Recording.rate / 10)
            live.tick()
            for _ in 0..<5 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(shown.isEmpty, "the pass is still in flight: \(shown)")
        #expect(try await live.split(audio) == "See you then.")
        try await Task.sleep(for: .milliseconds(120))
        #expect(shown.isEmpty, "\(shown)")
    }
}
}
