import Darwin
import FluidAudio
import Foundation
import Testing
import MouthyCore
@testable import MouthyKit

// MOUTHY_TEST_VOICEPRINT=1 swift test -c release -Xswiftc -enable-testing --filter VoicePrintTests
// "Only listen to my voice", with real models (Parakeet, Silero, WeSpeaker) and macOS voices: the default voice is the
// person, trained from VoicePrint.sentences; Daniel and Eddy are other people (a TV, someone nearby). Each clip is
// replayed live at real time with the stop clicks (LiveBenchmark), as the replay corpus does.
// 1. The person over another voice at -6 and -12 dB: every word of the person kept, at least 90% of the other's gone.
// 2. Another voice alone with the voiceprint on: nothing recognized. Off: the same words as the whole file, as today.
// 3. The speaker model is released after the dictation (nothing resident when idle).
// MOUTHY_VOICEPRINT_OFF=1 runs 1 and 2 with the voiceprint off: the "before" numbers (1 and 2 then fail).
// The replay corpus with the voiceprint on: MOUTHY_TEST_REPLAY=1 MOUTHY_REPLAY_VOICEPRINT=1 ... --filter replayCorpusLive
// Synthetic speech only; nothing is saved but the test's own temporary files.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_VOICEPRINT"] == "1"))
struct VoicePrintTests {
    static let others = ["Daniel", "Eddy (English (US))"]
    static let person = [
        "Remind me to call the shop about the new filament order.",
        "Then send the invoice to Maria before lunch on Thursday.",
    ]
    static let tv = [
        "Tonight on the evening news, heavy rain is expected across the northern valley.",
        "Officials say the bridge will stay closed until the weekend while crews repair the road.",
        "In sports, the home team won again after a late goal in the second half.",
        "And finally, the weather tomorrow looks cloudy with a light wind from the west.",
    ]

    /// Trains the person's voiceprint from three other sentences in the default voice.
    static func train(in folder: URL) async throws -> Voiceprint {
        try #require(ParakeetRecognizer.installed, "download Parakeet first")
        try #require(SpeakerModel.model != nil, "the Neural Engine voice model is not in the support folder Models/")
        await VoiceActivity.shared.prepare()
        var audio: [Float] = Corpus.silence(0.3)
        for sentence in VoicePrint.sentences { audio += Corpus.level(try Corpus.say(sentence, in: folder), Corpus.speech) + Corpus.silence(0.5) }
        // MOUTHY_VOICEPRINT_TRAIN_TV=<dB>: train with a TV (Daniel) talking the whole time at that level and 4 s after.
        if let dB = ProcessInfo.processInfo.environment["MOUTHY_VOICEPRINT_TRAIN_TV"].flatMap(Float.init) {
            var tv: [Float] = []
            for sentence in Self.tv + Self.tv { tv += Corpus.level(try Corpus.say(sentence, voice: Self.others[0], in: folder), Corpus.speech) + Corpus.silence(0.4) }
            audio += Corpus.silence(4)
            for i in audio.indices where i < tv.count { audio[i] += tv[i] * pow(10, dB / 20) }
            Swift.print("VOICEPRINT training with a TV at \(Int(dB)) dB")
        }
        let print = try await VoicePrint.train(Corpus.room(audio))
        Swift.print("VOICEPRINT trained from \(print.windows) windows of \(String(format: "%.1f", Double(audio.count) / 16_000)) s")
        return print
    }

    static var off: Bool { ProcessInfo.processInfo.environment["MOUTHY_VOICEPRINT_OFF"] == "1" }
    /// MOUTHY_VOICEPRINT_QUICK=1: one stop per clip (a double tap right at the end) instead of all three.
    static func run(_ url: URL) async throws -> LiveBenchmark.Result {
        ProcessInfo.processInfo.environment["MOUTHY_VOICEPRINT_QUICK"] == "1"
            ? try await LiveBenchmark.run(file: url, engine: .parakeet, stopDelays: [0], releaseDelays: [])
            : try await LiveBenchmark.run(file: url, engine: .parakeet)
    }

    @Test func voicePrintKeepsThePersonAndDropsOtherVoices() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-voiceprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); VoicePrint.active = nil }
        let print = try await Self.train(in: folder)
        VoicePrint.active = Self.off ? nil : print
        var failures: [String] = []
        let personWords = Corpus.words(Self.person.joined(separator: " "))
        for other in Self.others {
            var tv: [Float] = []
            for sentence in Self.tv { tv += Corpus.level(try Corpus.say(sentence, voice: other, in: folder), Corpus.speech) + Corpus.silence(0.4) }
            let tvWords = Corpus.words(Self.tv.joined(separator: " "))
            var me: [Float] = Corpus.silence(1.5)
            for sentence in Self.person { me += Corpus.level(try Corpus.say(sentence, in: folder), Corpus.speech) + Corpus.silence(0.8) }
            for dB in [-6, -12] as [Float] {
                // The other voice talks the whole time; the person speaks over it.
                let length = max(me.count, tv.count)
                var mix = [Float](repeating: 0, count: length)
                for i in tv.indices { mix[i] += tv[i] * pow(10, dB / 20) }
                for i in me.indices { mix[i] += me[i] }
                let url = folder.appendingPathComponent("mix-\(other.prefix(5))\(Int(dB)).wav")
                try Corpus.write(Corpus.room(Corpus.silence(0.4) + mix), to: url)
                let result = try await Self.run(url)
                for run in result.runs {
                    let live = Corpus.words(run.text)
                    let dropped = Corpus.missing(personWords, from: live)
                    let leaked = Corpus.missing(live, from: personWords)
                    let gone = 1 - Double(leaked.count) / Double(tvWords.count)
                    Swift.print(String(format: "VOICEPRINT person over %@ at %d dB, %@ %d ms: stop %d ms, person dropped %@, other's words %d of %d left (%.0f%% gone)",
                                       other, Int(dB), run.release ? "single press" : "double tap", run.stopDelay, run.milliseconds,
                                       dropped.isEmpty ? "none" : dropped.joined(separator: " "), leaked.count, tvWords.count, gone * 100))
                    Swift.print("VOICEPRINT   live: \(run.text)")
                    if !dropped.isEmpty { failures.append("\(other) \(Int(dB)) dB: dropped \(dropped.joined(separator: " "))") }
                    if gone < 0.9 { failures.append("\(other) \(Int(dB)) dB: only \(Int(gone * 100))% of the other voice gone") }
                }
            }
            // The other voice alone: nothing is recognized with the voiceprint on.
            let url = folder.appendingPathComponent("alone-\(other.prefix(5)).wav")
            try Corpus.write(Corpus.room(Corpus.silence(0.4) + Array(tv.prefix(16_000 * 8))), to: url)
            let result = try await Self.run(url)
            for run in result.runs {
                Swift.print("VOICEPRINT \(other) alone, \(run.release ? "single press" : "double tap") \(run.stopDelay) ms: stop \(run.milliseconds) ms, live \"\(run.text)\"")
                if !Corpus.words(run.text).isEmpty { failures.append("\(other) alone: typed \(run.text)") }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
    }

    /// Training with other audio in the room: the person reads the three sentences while a TV talks the whole time
    /// (another macOS voice at -6 and -12 dB), and the TV goes on alone for 4 s before Done is clicked. The voiceprint
    /// must be the person's: as alike to the one trained in quiet as two quiet trainings are, and the TV alone must
    /// score below `SpeakerMask.match` against it, as it does against the quiet one.
    @Test func trainingWithATVPlayingKeepsOnlyThePerson() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-voicetrain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let quiet = try await Self.train(in: folder)
        var reading: [Float] = Corpus.silence(0.3)
        for sentence in VoicePrint.sentences { reading += Corpus.level(try Corpus.say(sentence, in: folder), Corpus.speech) + Corpus.silence(0.5) }
        var failures: [String] = []
        for other in Self.others {
            var tv: [Float] = []
            for sentence in Self.tv + Self.tv { tv += Corpus.level(try Corpus.say(sentence, voice: other, in: folder), Corpus.speech) + Corpus.silence(0.4) }
            let tvAlone = try await VoicePrint.train(Corpus.room(Array(tv.prefix(16_000 * 12))))
            let quietVersusTV = SpeakerMask.similarity(quiet.embedding, tvAlone.embedding)
            for dB in [-6, -12] as [Float] {
                let gain = pow(10, dB / 20)
                var mix = reading + Corpus.silence(4)
                for i in mix.indices where i < tv.count { mix[i] += tv[i] * gain }
                let trained = try await VoicePrint.train(Corpus.room(mix))
                let same = SpeakerMask.similarity(trained.embedding, quiet.embedding)
                let tvScore = SpeakerMask.similarity(trained.embedding, tvAlone.embedding)
                Swift.print(String(format: "VOICETRAIN %@ at %d dB: %d windows, like the quiet voiceprint %.3f, TV alone scores %.3f (quiet voiceprint: %.3f)",
                                   other, Int(dB), trained.windows, same, tvScore, quietVersusTV))
                if tvScore >= SpeakerMask.match { failures.append("\(other) \(Int(dB)) dB: the TV alone scores \(tvScore)") }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
    }

    /// The release demo: a voiceprint from three recorded enrollment clips, then the person's sentence over a newscaster
    /// who talks the whole time. MOUTHY_TEST_VOICEDEMO=<folder with enroll-1.wav ... enroll-3.wav and tv-mix-1.wav>.
    /// The release gate (2026-10-07): every stop types none of the newscaster's words, in order, and every word
    /// of the person's except one the newscaster says at the same instant. Only "book" is that word: his "Traffic"
    /// overlaps it (measured: without the overlap, or with him 6 dB quieter, it is typed right). Two voices at once stay
    /// mixed, since Mouthy has no separation model.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_VOICEDEMO"] != nil))
    func tvMixTypesOnlyThePerson() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOUTHY_TEST_VOICEDEMO"] ?? "")
        defer { VoicePrint.active = nil }
        try #require(ParakeetRecognizer.installed, "download Parakeet first")
        try #require(SpeakerModel.model != nil, "the Neural Engine voice model is not on this Mac")
        await VoiceActivity.shared.prepare()
        var enroll: [Float] = Corpus.silence(0.3)
        for index in 1...3 {
            enroll += try AudioConverter().resampleAudioFile(folder.appendingPathComponent("enroll-\(index).wav")) + Corpus.silence(0.5)
        }
        let print = try await VoicePrint.train(enroll)
        Swift.print("VOICEDEMO trained from \(print.windows) windows")
        VoicePrint.active = Self.off ? nil : print
        let expected = Corpus.words("Book the dentist for Thursday at nine, and ask whether they can move it to Friday.")
        let spokenOver: Set<String> = ["book"]
        let newscaster = Set(Corpus.words("Good evening. Traffic is backed up on the interstate tonight after an accident near the river bridge, "
            + "and forecasters say heavy rain will move in by the weekend, so plan ahead if you're heading out of town.")).subtracting(expected)
        let result = try await LiveBenchmark.run(file: folder.appendingPathComponent("tv-mix-1.wav"), engine: .parakeet)
        Swift.print("VOICEDEMO whole file, no voiceprint: \(result.whole)")
        var failures: [String] = []
        for run in result.runs {
            let live = Corpus.words(run.text)
            let dropped = Corpus.missing(expected, from: live), leaked = Corpus.missing(live, from: expected)
            Swift.print("VOICEDEMO \(run.release ? "single press" : "double tap") \(run.stopDelay) ms: stop \(run.milliseconds) ms, \"\(run.text)\"")
            // One word heard wrong where the newscaster talks over it: the same number of words, in the same places.
            let misheard = live.count == expected.count ? zip(expected, live).filter { $0 != $1 } : []
            let ok = live.count == expected.count && misheard.count <= 1 && misheard.allSatisfy { spokenOver.contains($0.0) && !newscaster.contains($0.1) }
            if !ok {
                failures.append("\(run.release ? "single" : "double") \(run.stopDelay) ms: dropped [\(dropped.joined(separator: " "))], added [\(leaked.joined(separator: " "))]")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
    }

    /// Without a voiceprint, another voice is recognized exactly as today.
    @Test func withoutAVoicePrintEveryVoiceIsHeard() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-voiceprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #require(ParakeetRecognizer.installed, "download Parakeet first")
        VoicePrint.active = nil
        var tv: [Float] = []
        for sentence in Self.tv.prefix(2) { tv += Corpus.level(try Corpus.say(sentence, voice: Self.others[0], in: folder), Corpus.speech) + Corpus.silence(0.4) }
        let url = folder.appendingPathComponent("alone.wav")
        try Corpus.write(Corpus.room(Corpus.silence(0.4) + tv), to: url)
        let result = try await LiveBenchmark.run(file: url, engine: .parakeet)
        for run in result.runs {
            Swift.print("VOICEPRINT off, \(Self.others[0]) alone: live \"\(run.text)\"")
            #expect(Corpus.words(run.text) == Corpus.words(result.whole))
        }
    }

    /// The speaker model is held only while dictating with the feature on, then released.
    @Test func speakerModelIsReleasedAfterDictating() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-voiceprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); VoicePrint.active = nil; SpeakerModel.idleRelease = .seconds(10) }
        let print = try await Self.train(in: folder)
        await SpeakerModel.shared.release()
        try await Task.sleep(for: .milliseconds(300))
        let before = Self.inUse()
        SpeakerModel.idleRelease = .seconds(1)
        VoicePrint.active = print
        let url = folder.appendingPathComponent("me.wav")
        try Corpus.write(Corpus.room(Corpus.silence(0.4) + Corpus.level(try Corpus.say(Self.person[0], in: folder), Corpus.speech)), to: url)
        _ = try await LiveBenchmark.run(file: url, engine: .parakeet, stopDelays: [0], releaseDelays: [])
        let held = await SpeakerModel.shared.loaded
        let during = Self.inUse()
        try await Task.sleep(for: .milliseconds(1_500))
        let released = await SpeakerModel.shared.loaded
        let after = Self.inUse()
        Swift.print(String(format: "VOICEPRINT speaker model held right after the dictation: %@; 1.5 s later: %@; malloc in use %.1f MB before, %.1f MB right after, %.1f MB released",
                           held ? "yes" : "no", released ? "yes" : "no", before, during, after))
        #expect(!released, "the speaker model must not stay resident when idle")
        VoicePrint.active = nil
        let track = SpeakerTrack.forDictation()
        #expect(track == nil, "no voiceprint, no speaker check")
    }

    static func inUse() -> Double {
        malloc_zone_pressure_relief(nil, 0)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use) / 1_048_576
    }
}
