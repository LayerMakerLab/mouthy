import Foundation
import MouthyCore
import Testing
@testable import MouthyKit

// MOUTHY_TEST_VAD=1 swift test -c release -Xswiftc -enable-testing --filter voiceActivity
// Evaluates Silero (FluidAudio's trained voice detector) against the energy checks on synthesized speech: soft endings
// after loud speech, a quiet speaker, a whisper, and non-speech (room, music bed, key clicks). Per 256 ms chunk it
// prints Silero's probability, the speech threshold (SpeechPauses.hasSpeech) and the quiet check (mightHoldWords).
// Gate: every speech region is heard by Silero or the quiet check, Silero hears nothing in room noise or key clicks,
// and a chunk costs under 5 ms. Needs the cached Silero model (it downloads with Parakeet).
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_VAD"] == "1"))
struct VoiceActivityEvaluation {
    @Test func voiceActivityHearsSoftSpeechAndIgnoresNoise() async throws {
        #expect(VoiceActivity.model != nil, "Silero model missing")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-vad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func say(_ text: String, _ rms: Float, voice: String? = nil) throws -> [Float] { Corpus.level(try Corpus.say(text, voice: voice, in: folder), rms) }
        let quiet: Float = 0.02, soft = quiet * pow(10, -18 / 20)
        var clicks = Corpus.silence(1.5)
        for click in [8_000, 10_400] { for i in 0..<320 { clicks[click + i] = (i % 2 == 0 ? 0.3 : -0.3) * Float(320 - i) / 320 } }
        // (name, lead-in that sets the room, region to judge, holds speech)
        let cases: [(String, [Float], [Float], Bool)] = [
            ("soft ending -18 dB under a quiet voice", try say("Please send the quarterly report before Friday", quiet) + Corpus.silence(0.4),
             try say("and copy Daniel on it", soft), true),
            ("soft short word -18 dB: yes", try say("Can you confirm the meeting", quiet) + Corpus.silence(0.4), try say("yes", soft), true),
            ("quiet speaker (RMS 0.006)", Corpus.silence(1), try say("Remind me to water the plants tonight", 0.006), true),
            ("very quiet speaker (RMS 0.003)", Corpus.silence(1), try say("Remind me to water the plants tonight", 0.003), true),
            ("whisper (RMS 0.01)", Corpus.silence(1), try say("bring the printed agenda", 0.01, voice: "Whisper"), true),
            ("room noise", Corpus.silence(1), Corpus.silence(2), false),
            ("key clicks", Corpus.silence(1), clicks, false),
            ("music bed -30 dB", Corpus.silence(1), Corpus.bed(count: 32_000, rms: Corpus.dB(-30)), false),
        ]
        var failures: [String] = []
        var chunkCost: [Double] = []
        for (name, lead, region, speech) in cases {
            let audio = Corpus.room(lead + region + Corpus.silence(0.3))
            var pauses = SpeechPauses()
            pauses.feed(Array(audio[..<lead.count]))
            let slice = audio[lead.count..<(lead.count + region.count)]
            let started = ContinuousClock.now
            let chances = try #require(await VoiceActivity.shared.probabilities(Array(slice)))
            let took = started.duration(to: .now)
            chunkCost.append((Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000) / Double(max(1, chances.count)))
            let silero = chances.contains { $0 >= VoiceActivity.speech }
            let strict = pauses.hasSpeech(slice), quietCheck = pauses.mightHoldWords(slice)
            print(String(format: "VAD %@: silero max %.2f [%@], speech threshold %@, quiet check %@ (threshold %.4f / quiet %.4f)",
                         name, chances.max() ?? 0, chances.map { String(format: "%.2f", $0) }.joined(separator: " "),
                         strict ? "yes" : "no", quietCheck ? "yes" : "no", pauses.threshold, pauses.quietThreshold))
            if speech, !silero, !quietCheck { failures.append("\(name): missed") }
            if !speech, silero { failures.append("\(name): Silero heard speech") }
            if name == "key clicks", quietCheck { failures.append("key clicks passed the quiet check") }
        }
        let cost = chunkCost.dropFirst().max() ?? 0
        print(String(format: "VAD cost: %.2f ms per 256 ms chunk (worst after the first load)", cost))
        #expect(cost < 5)
        #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
    }
}
