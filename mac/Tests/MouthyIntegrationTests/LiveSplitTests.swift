import FluidAudio
import Foundation
import MouthyCore
import Testing
@testable import MouthyKit

// MOUTHY_TEST_SPLIT=<16 kHz wav> MOUTHY_SPLIT_AT=<seconds,...> [MOUTHY_SPLIT_VOICE=<wav of the same speaker>]
// swift test --filter liveSplitReplay
// Replays a recording into LiveTranscriber at real time like SpeechService does with Parakeet: Enter takes the audio
// so far (`split`) while the microphone keeps recording, and the stop finishes the rest. Prints every sent part and
// the whole-file text, so lost or repeated words at a split show. With MOUTHY_SPLIT_VOICE, "Only listen to my voice"
// is on, trained on that recording.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_SPLIT"] != nil))
func liveSplitReplay() async throws {
    let env = ProcessInfo.processInfo.environment
    let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: env["MOUTHY_TEST_SPLIT"]!))
    let splits = (env["MOUTHY_SPLIT_AT"] ?? "").split(separator: ",").compactMap { Double($0) }.map { Int($0 * 16_000) }
    try await ParakeetRecognizer.shared.prepare(download: false) { _ in }
    await VoiceActivity.shared.prepare()
    defer { VoicePrint.active = nil }
    // MOUTHY_SPLIT_COST=<seconds per second of audio>: replay as if this Mac were that busy (0.06: loaded or Intel).
    let savedCost = LiveTranscriber.cost
    defer { LiveTranscriber.cost = savedCost }
    if let cost = env["MOUTHY_SPLIT_COST"].flatMap(Double.init) { LiveTranscriber.cost = cost }
    if let voice = env["MOUTHY_SPLIT_VOICE"] {
        VoicePrint.active = try await VoicePrint.train(try AudioConverter().resampleAudioFile(URL(fileURLWithPath: voice)))
        print("SPLIT voiceprint on")
    }
    // MOUTHY_SPLIT_SLOW=<seconds per second of audio>: every recognition also waits that long (a heavily loaded Mac).
    let slow = env["MOUTHY_SPLIT_SLOW"].flatMap(Double.init) ?? 0
    let parts = try await LiveSplit.run(audio, splits: splits, slow: slow)
    for (index, part) in parts.enumerated() { print("SPLIT part \(index + 1): \(part)") }
    print("SPLIT whole: \(try await ParakeetRecognizer.shared.transcribe(samples: audio, boost: true))")
}

/// SpeechService's Parakeet session in miniature: a capture buffer that Enter empties, a 100 ms ticker that stops
/// while a split is recognized, and audio that keeps arriving meanwhile.
@MainActor
enum LiveSplit {
    static func run(_ audio: [Float], splits: [Int], slow: Double = 0, speakers: SpeakerTrack? = SpeakerTrack.forDictation()) async throws -> [String] {
        var recorded = 0, base = 0
        let decode: LiveTranscriber.Decode = { samples, boost in
            if slow > 0 { try await Task.sleep(for: .milliseconds(Int(slow * Double(samples.count) / 16))) }
            return try await ParakeetRecognizer.shared.transcribe(samples: samples, boost: boost)
        }
        let decodeAfter: LiveTranscriber.DecodeAfter = { samples, from in
            if slow > 0 { try await Task.sleep(for: .milliseconds(Int(slow * Double(samples.count) / 16))) }
            return try await ParakeetRecognizer.decodeAfter(samples, from)
        }
        let live = LiveTranscriber(decode: decode, decodeAfter: decodeAfter, hearsSpeech: VoiceActivity.hearsSpeech,
                                   speakers: speakers, count: { recorded - base },
                                   read: { range in Array(audio[(range.lowerBound + base)..<min(range.upperBound + base, recorded)]) })
        var parts: [String] = []
        var pending = splits.sorted()
        let started = ContinuousClock.now
        func catchUp() { recorded = min(audio.count, Int(Double(started.duration(to: .now).components.seconds) * 16_000
            + Double(started.duration(to: .now).components.attoseconds) / 1e18 * 16_000)) }
        while recorded < audio.count {
            try await Task.sleep(for: .milliseconds(100))
            catchUp()
            if let next = pending.first, recorded >= next {
                pending.removeFirst()
                let taken = Array(audio[base..<recorded])
                base = recorded
                parts.append(try await live.split(taken))
                catchUp()
            }
            live.tick()
        }
        parts.append(try await live.finish(Array(audio[base..<audio.count])))
        return parts
    }
}

/// Two spoken sentences with an inhale-like noise burst in the pause between them: the breath must not shorten the
/// measured pause into a run-on ("That's the plan next we ship").
@Test func aBreathBetweenSpokenSentencesKeepsTheSentenceEnd() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-breath-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = Corpus.level(try Corpus.say("That's the plan.", in: folder), Corpus.speech)
    let second = Corpus.level(try Corpus.say("Next we ship.", in: folder), Corpus.speech)
    var state: UInt32 = 7
    let breath = (0..<5_600).map { _ -> Float in
        state = state &* 1_664_525 &+ 1_013_904_223
        return Corpus.dB(-18) * (Float(state >> 8) / Float(1 << 24) * 2 - 1) * 1.7
    }
    let silence = [Float](repeating: 0, count: 4_800), lead = [Float](repeating: 0, count: 1_600)
    var pauses = SpeechPauses()
    var audio = silence + first
    audio += silence + breath
    audio += lead + second + silence
    pauses.feed(audio)
    let end = try #require(pauses.wordEnds.first { $0 > silence.count + first.count - 3_200 })
    let measured = Double(try #require(pauses.silence(after: end))) / 16_000
    #expect(measured >= PhraseJoiner.sentencePause, "\(measured) s")
    #expect(PhraseJoiner.join([("That's the plan.", 0), ("Next we ship.", measured)]) == "That's the plan. Next we ship.")
}
