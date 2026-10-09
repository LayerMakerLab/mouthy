import Foundation
import Testing
@testable import MouthyKit

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
                                   decodeAfter: context ? { samples, from in calls.add(samples.count, true, from); return "t\(samples.count - from)" } : nil,
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
            return "made a cup of coffee."
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
}
