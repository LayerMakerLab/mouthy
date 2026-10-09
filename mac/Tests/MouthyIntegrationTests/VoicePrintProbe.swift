import FluidAudio
import Foundation
import Testing
import MouthyCore
@testable import MouthyKit

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_PROBE"] == "1"))
struct VoicePrintProbe {
    /// Window scores and verdicts for the release demo (MOUTHY_TEST_VOICEDEMO, see VoicePrintTests.tvMixTypesOnlyThePerson).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_VOICEDEMO"] != nil))
    func probeDemo() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOUTHY_TEST_VOICEDEMO"] ?? "")
        await VoiceActivity.shared.prepare()
        var enroll: [Float] = Corpus.silence(0.3)
        for index in 1...3 {
            enroll += try AudioConverter().resampleAudioFile(folder.appendingPathComponent("enroll-\(index).wav")) + Corpus.silence(0.5)
        }
        let print = try await VoicePrint.train(enroll)
        for name in ["tv-mix-1", "enroll-1"] {
            let mix = try AudioConverter().resampleAudioFile(folder.appendingPathComponent("\(name).wav"))
            let track = SpeakerTrack(print: print)
            await track.feed(mix)
            let scores = await track.windowScores, speech = await track.speechChances
            let verdicts = SpeakerMask.verdicts(speech: speech.map { $0 >= VoiceActivity.keep }, scores: scores)
            let line = scores.keys.sorted().map { String(format: "%.1fs:%.2f", Double($0) * 0.256, scores[$0]!) }.joined(separator: " ")
            let v = verdicts.map { $0 == .mine ? "M" : $0 == .theirs ? "t" : "?" }.joined()
            Swift.print("PROBE \(name): \(line)\nPROBE verdicts \(v)")
            // Short windows centred on each piece: similarity to the voiceprint and to the other voices' centroid
            // (the 2 s windows that scored clearly someone else).
            let chunk = VoiceActivity.chunk
            var others: [[Float]] = []
            for (start, score) in scores where score < SpeakerTrack.clearlyOther {
                let low = start * chunk, high = min(mix.count, low + SpeakerMask.window * chunk)
                if let e = try await SpeakerModel.shared.embed(Array(mix[low..<high])) { others.append(e) }
            }
            let theirs = SpeakerMask.centroid(others)
            for pieces in [2, 3, 4] {
                var row: [String] = []
                for piece in 0..<speech.count {
                    let centre = piece * chunk + chunk / 2, half = pieces * chunk / 2
                    let low = max(0, centre - half), high = min(mix.count, centre + half)
                    guard high - low >= SpeakerEmbedder.minimumSamples,
                          let e = try await SpeakerModel.shared.embed(Array(mix[low..<high])) else { row.append("  --  "); continue }
                    let m = SpeakerMask.similarity(e, print.embedding), t = theirs.isEmpty ? 0 : SpeakerMask.similarity(e, theirs)
                    row.append(String(format: "%.1f:%+.2f/%+.2f", Double(piece) * 0.256, m, t))
                }
                Swift.print("PROBE short \(pieces) pieces (\(others.count) other windows): " + row.joined(separator: " "))
            }
        }
    }

    @Test func probeScores() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let print = try await VoicePrintTests.train(in: folder)
        for other in VoicePrintTests.others {
            var tv: [Float] = []
            for sentence in VoicePrintTests.tv { tv += Corpus.level(try Corpus.say(sentence, voice: other, in: folder), Corpus.speech) + Corpus.silence(0.4) }
            var me: [Float] = Corpus.silence(1.5)
            for sentence in VoicePrintTests.person { me += Corpus.level(try Corpus.say(sentence, in: folder), Corpus.speech) + Corpus.silence(0.8) }
            for dB in [-6, -12] as [Float] {
                var mix = [Float](repeating: 0, count: max(me.count, tv.count))
                for i in tv.indices { mix[i] += tv[i] * pow(10, dB / 20) }
                for i in me.indices { mix[i] += me[i] }
                let track = SpeakerTrack(print: print)
                await track.feed(mix)
                let scores = await track.windowScores, speech = await track.speechChances
                let verdicts = SpeakerMask.verdicts(speech: speech.map { $0 >= VoiceActivity.keep }, scores: scores)
                let line = scores.keys.sorted().map { String(format: "%.1fs:%.2f", Double($0) * 0.256, scores[$0]!) }.joined(separator: " ")
                let v = verdicts.map { $0 == .mine ? "M" : $0 == .theirs ? "t" : "?" }.joined()
                let mine = (0..<speech.count).map { i -> String in let t = i * 4096; return t >= 24_000 && t < me.count && abs(me[t]) + abs(me[min(me.count - 1, t + 2048)]) > 0 ? "P" : "." }.joined()
                Swift.print("PROBE \(other) \(dB): \(line)\nPROBE verdicts \(v)\nPROBE person   \(mine)")
            }
        }
    }
}
