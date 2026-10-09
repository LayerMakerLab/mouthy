import AVFoundation
import Foundation
import Testing
@testable import MouthyKit

// MOUTHY_TEST_REPLAY=1 swift test -c release -Xswiftc -enable-testing --filter replayCorpus
// Gate ("cutting out"): for every clip, live recognition through LiveTranscriber, replayed at real time with the
// stop clicks (LiveBenchmark: a double tap 0 ms and 200 ms after the last word, so the stop lands both before and
// after the last background pass, and a single press right at the last word with 160 ms of audio still in flight),
// contains every word that recognizing the whole file contains, the
// clicks add no words (live has no word the whole file lacks), and the stop takes at most 186 ms. Clips are synthesized with `say` at test time and mixed here (speech at
// RMS 0.06, and a quiet speaker at RMS 0.02 and 0.004, over a faint room floor); each names words the whole-file pass
// must hear, or the clip proves nothing. No personal audio. Needs the cached Parakeet model (and Silero, which
// downloads with it, on Apple silicon).

enum Corpus {
    static let rate = 16_000
    static let speech: Float = 0.06
    static func dB(_ value: Float) -> Float { speech * pow(10, value / 20) }

    static func say(_ text: String, voice: String? = nil, in folder: URL) throws -> [Float] {
        let url = folder.appendingPathComponent(UUID().uuidString + ".wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, "--data-format=LEI16@16000", text]
        try process.run(); process.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        // Trim say's own leading and trailing silence so the mix sets every gap.
        let first = samples.firstIndex { abs($0) > 0.002 } ?? 0
        let last = samples.lastIndex { abs($0) > 0.002 } ?? samples.count - 1
        return Array(samples[first...max(first, last)])
    }

    /// Scales `samples` so their RMS is `rms`.
    static func level(_ samples: [Float], _ rms: Float) -> [Float] {
        let current = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
        return current > 0 ? samples.map { $0 * rms / current } : samples
    }

    static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }

    /// Deterministic noise so runs compare.
    struct Noise { var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: state) >> 11) / Float(1 << 52) } }

    /// A quiet room under everything (about -66 dBFS), like a real microphone.
    static func room(_ samples: [Float]) -> [Float] {
        var noise = Noise()
        return samples.map { $0 + noise.next() * 0.0008 }
    }

    /// A low music-and-noise bed (chord with a slow pulse plus hiss) at `rms`.
    static func bed(count: Int, rms: Float) -> [Float] {
        var noise = Noise(state: 42)
        let raw: [Float] = (0..<count).map { i in
            let t = Float(i) / Float(rate)
            let chord = sin(2 * .pi * 220 * t) + 0.8 * sin(2 * .pi * 277.2 * t) + 0.7 * sin(2 * .pi * 329.6 * t)
            let pulse = 0.6 + 0.4 * sin(2 * .pi * 2 * t)
            return chord * pulse + 0.8 * noise.next()
        }
        return level(raw, rms)
    }

    static func write(_ samples: [Float], to url: URL) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, value) in samples.enumerated() { buffer.floatChannelData![0][i] = max(-1, min(1, value)) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(rate),
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        try file.write(from: buffer)
    }

    static func words(_ text: String) -> [String] {
        let kept = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(kept).split(separator: " ").map { $0 == "okay" ? "ok" : String($0) }
    }

    /// Words in `a` (with repeats) that `b` lacks.
    static func missing(_ a: [String], from b: [String]) -> [String] {
        var pool = Dictionary(b.map { ($0, 1) }, uniquingKeysWith: +)
        return a.filter { word in
            if let n = pool[word], n > 0 { pool[word] = n - 1; return false }
            return true
        }
    }

    /// A quiet speaker (RMS 0.02, -34 dBFS): their -18 dB endings sit near the room, under the speech threshold.
    static let quiet: Float = 0.02

    /// Each clip with the words recognizing the whole file must contain, so the clip proves those words are kept.
    static func clips(in folder: URL) throws -> [(name: String, audio: [Float], required: [String])] {
        func n(_ text: String) throws -> [Float] { level(try say(text, in: folder), speech) }
        func soft(_ text: String) throws -> [Float] { level(try say(text, in: folder), dB(-18)) }
        func q(_ text: String) throws -> [Float] { level(try say(text, in: folder), quiet) }
        func qSoft(_ text: String) throws -> [Float] { level(try say(text, in: folder), quiet * pow(10, -18 / 20)) }
        let monologue = [
            "Good morning everyone, this is the weekly update for the print shop.",
            "We shipped forty two orders last week, which is our best week so far.",
            "The new printer arrived on Tuesday and the calibration took most of the afternoon.",
            "Two customers asked for custom colors, so I ordered three new spools of filament.",
            "The website now shows delivery times on every product page.",
            "Next week I want to finish the packaging redesign and test the new labels.",
            "Please send me any questions before Friday so we can plan the next order.",
            "One more thing, the supplier raised prices by five percent starting next month.",
            "I think we can absorb that for now, but we should review it in December.",
            "Also remember that the shop is closed on Monday for the holiday.",
            "Thanks everyone, and have a great rest of the week.",
        ]
        var long: [Float] = []
        for (i, sentence) in monologue.enumerated() { long += try n(sentence) + silence([0.35, 0.6, 0.45, 0.8, 0.3, 0.55, 0.4, 0.7, 0.35, 0.5, 0.45][i]) }
        var bedded = try n("Remind me to call the shop about the new filament order") + silence(0.6) + n("and ask about delivery times")
        let music = bed(count: bedded.count + rate, rms: dB(-30))
        bedded = (silence(0.5) + bedded + silence(0.5)).enumerated().map { $0.element + music[$0.offset] }
        let clips: [(String, [Float], String)] = [
            ("soft trailing words (-18 dB)", try n("Please send the quarterly report to the whole team before Friday") + silence(0.4) + soft("and copy Daniel on it"), "copy Daniel"),
            ("soft words after a part boundary", try n("Book a table for four people") + silence(1.5) + soft("near the window"), "window"),
            ("soft short final word: yes (-18 dB)", try n("Can you confirm the meeting is still on for tomorrow") + silence(0.5) + soft("yes"), "yes"),
            ("soft short final word after a part boundary: ok (-18 dB)", try n("Book a table for four people") + silence(1.2) + soft("OK"), "ok"),
            ("short final word: yes", try n("Can you confirm the meeting is still on for tomorrow") + silence(0.5) + n("yes"), "yes"),
            ("short final word: ok", try n("I read the draft and it looks good to me") + silence(0.5) + n("OK"), "ok"),
            ("short final word: done", try n("Move the files into the archive folder") + silence(0.5) + n("done"), "done"),
            ("pauses 0.3 / 0.8 / 1.2 / 3 s", try n("First we open the project") + silence(0.3) + n("then we check the settings") + silence(0.8)
                + n("after that we run the tests") + silence(1.2) + n("and then we write the notes") + silence(3) + n("finally we ship the update"), "finally ship"),
            // A dropped voice in the middle (macOS's Whisper voice is not speech to any recognizer, so a soft one stands in).
            ("soft middle phrase (-15 dB)", try n("The meeting starts at nine") + silence(0.4) + level(say("bring the printed agenda", in: folder), dB(-15))
                + silence(0.4) + n("and the budget sheet"), "printed agenda budget sheet"),
            ("music and noise bed (-30 dB)", bedded, "delivery times"),
            ("45 s monologue", long, "holiday"),
            ("quiet speaker: soft trailing words", try q("Please send the quarterly report to the whole team before Friday") + silence(0.4)
                + qSoft("and copy Daniel on it"), "copy Daniel"),
            ("quiet speaker: soft final word: yes", try q("Can you confirm the meeting is still on for tomorrow") + silence(0.5) + qSoft("yes"), "yes"),
            ("quiet speaker: soft middle phrase (-15 dB)", try q("The meeting starts at nine") + silence(0.4)
                + level(say("bring the printed agenda", in: folder), quiet * pow(10, -15 / 20)) + silence(0.4) + q("and the budget sheet"), "printed agenda budget sheet"),
            ("quiet speaker: soft words after a long pause", try q("Book a table for four people") + silence(1.5) + qSoft("near the window"), "window"),
            ("very quiet speaker (RMS 0.004)", level(try say("Remind me to water the plants tonight", in: folder), 0.004) + silence(0.6)
                + level(try say("and to call the bank in the morning", in: folder), 0.004), "plants bank morning"),
        ]
        return clips.map { ($0.0, room(silence(0.4) + $0.1), words($0.2)) }
    }
}

/// Serialized: both use the shared recognizer, which takes one request at a time.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_REPLAY"] == "1"))
struct ReplayCorpus {

@Test func replayCorpusLiveKeepsEveryWord() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-replay-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var failures: [String] = []
    let only = ProcessInfo.processInfo.environment["MOUTHY_REPLAY_ONLY"]
    // MOUTHY_REPLAY_COST=<seconds per second of audio> replays as if this Mac were that busy (0.06: a loaded or Intel
    // Mac), so the stop takes its cheaper paths here too.
    let savedCost = LiveTranscriber.cost
    defer { LiveTranscriber.cost = savedCost }
    if let cost = ProcessInfo.processInfo.environment["MOUTHY_REPLAY_COST"].flatMap(Double.init) { LiveTranscriber.cost = cost }
    // MOUTHY_REPLAY_VOICEPRINT=1 replays with "Only listen to my voice" on, trained on the corpus voice from three other
    // sentences (VoicePrintTests.train): the person alone must keep every word.
    defer { VoicePrint.active = nil }
    if ProcessInfo.processInfo.environment["MOUTHY_REPLAY_VOICEPRINT"] == "1" { VoicePrint.active = try await VoicePrintTests.train(in: folder) }
    var stops: [Int] = []
    // MOUTHY_REPLAY_EXPORT=<dir> writes the clips and their required words (clips.tsv) for `Mouthy bench-live` on
    // another Mac (an Intel one) instead of replaying them here.
    if let export = ProcessInfo.processInfo.environment["MOUTHY_REPLAY_EXPORT"].map(URL.init(fileURLWithPath:)) {
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        var list = ""
        for (index, clip) in try Corpus.clips(in: folder).enumerated() {
            try Corpus.write(clip.audio, to: export.appendingPathComponent("clip-\(index).wav"))
            list += "clip-\(index).wav\t\(clip.name)\t\(clip.required.joined(separator: " "))\n"
        }
        try list.write(to: export.appendingPathComponent("clips.tsv"), atomically: true, encoding: .utf8)
        return
    }
    for (index, clip) in try Corpus.clips(in: folder).enumerated() where only.map({ clip.name.contains($0) }) ?? true {
        let url = folder.appendingPathComponent("clip-\(index).wav")
        try Corpus.write(clip.audio, to: url)
        if clip.required.isEmpty { failures.append("\(clip.name): names no words, so it proves nothing") }
        let result = try await LiveBenchmark.run(file: url, engine: .parakeet)
        let whole = Corpus.words(result.whole)
        // A clip proves its words are kept only if recognizing the whole file hears them.
        let unheard = Corpus.missing(clip.required, from: whole)
        if !unheard.isEmpty { failures.append("\(clip.name): the whole file lacks \(unheard.joined(separator: " ")), so the clip proves nothing") }
        for run in result.runs {
            let live = Corpus.words(run.text)
            let dropped = Corpus.missing(whole, from: live)
            // Live recognition says exactly the words of the whole file: a word it adds came from the clicks or noise.
            let added = Corpus.missing(live, from: whole)
            print(String(format: "REPLAY %@ (%.1f s) %@ %d ms: stop %d ms (+%d ms in flight), whole %d words, live %d words, dropped %@, added %@",
                         clip.name, Double(clip.audio.count) / 16_000, run.release ? "single press" : "double tap", run.stopDelay,
                         run.milliseconds, run.waited, whole.count, live.count,
                         dropped.isEmpty ? "none" : dropped.joined(separator: " "), added.isEmpty ? "none" : added.joined(separator: " ")))
            print("REPLAY   whole: \(result.whole)")
            print("REPLAY   live:  \(run.text)")
            if !dropped.isEmpty || !added.isEmpty { failures.append(clip.name) }
            if run.milliseconds > 186 { failures.append("\(clip.name): stop \(run.milliseconds) ms") }
            stops.append(run.milliseconds)
        }
    }
    let sorted = stops.sorted()
    if !sorted.isEmpty {
        print("REPLAY \(sorted.count) stops\(VoicePrint.active == nil ? "" : " (voiceprint on)"): median \(sorted[sorted.count / 2]) ms, mean \(sorted.reduce(0, +) / sorted.count) ms, max \(sorted.last!) ms, exact \(sorted.count - Set(failures).count)")
    }
    #expect(failures.isEmpty, "clips that dropped or added words: \(failures.joined(separator: "; "))")
}

/// The stop's context decode (long parts): two seconds of earlier speech go in with the new words, and only the new
/// words come back, none repeated and none lost.
@Test func replayCorpusContextDecodeKeepsOnlyTheNewWords() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-context-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try await ParakeetRecognizer.shared.prepare(download: false) { _ in }
    let earlier = Corpus.level(try Corpus.say("and the calibration took most of the afternoon", in: folder), Corpus.speech)
    let newer = Corpus.level(try Corpus.say("please order three new spools of filament", in: folder), Corpus.speech)
    // Pauses from the shortest that starts a background pass to a long one.
    for pause in [0.2, 0.45, 1.0] {
        let audio = Corpus.room(earlier + Corpus.silence(pause) + newer + Corpus.silence(0.2))
        let text = try await ParakeetRecognizer.shared.transcribe(samples: audio, wordsFrom: LiveTranscriber.newWords(after: earlier.count))
        print("REPLAY context decode after a \(pause) s pause: \(text)")
        #expect(Corpus.words(text) == Corpus.words("please order three new spools of filament"))
    }
}
}
