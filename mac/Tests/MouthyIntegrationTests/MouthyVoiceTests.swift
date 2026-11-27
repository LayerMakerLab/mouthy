import AVFoundation
import CoreML
import Foundation
import MouthyCore
import Testing
@testable import MouthyKit

/// Mouthy's own voice. The inverse FFT is checked always; the models only with `MOUTHY_TEST_VOICE=<folder>` holding
/// the three `.mlpackage`s (the voice's conversion output): they are compiled into a temporary folder with the
/// repo's lexicon, sentences are rendered (`MOUTHY_VOICE_OUT=<dir>` saves the WAVs), timed, and heard back by
/// Parakeet when it is installed. Nothing plays through the speakers.
@Suite struct MouthyVoiceTests {
    @Test func inverseFFTMatchesTheDefinition() {
        let n = MouthyVoice.nFFT, bins = MouthyVoice.bins
        var rng = SeededNormal(seed: 3)
        let re = (0..<bins).map { _ in Float(rng.next()) }, im = (0..<bins).map { _ in Float(rng.next()) }
        let fast = re.withUnsafeBufferPointer { r in im.withUnsafeBufferPointer { i in MouthyVoice.irfft(real: r.baseAddress!, imag: i.baseAddress!, stride: 1) } }
        // torch.fft.irfft: DC and Nyquist imaginary parts are ignored, the rest mirrored, divided by n.
        var worst: Float = 0
        for t in stride(from: 0, to: n, by: 37) {
            var s = Double(re[0]) + Double(re[bins - 1]) * cos(Double.pi * Double(t))
            for k in 1..<(bins - 1) {
                let a = 2 * Double.pi * Double(k * t) / Double(n)
                s += 2 * (Double(re[k]) * cos(a) - Double(im[k]) * sin(a))
            }
            worst = max(worst, abs(Float(s / Double(n)) - fast[t]))
        }
        #expect(worst < 1e-4)
    }

    @Test func tokensAreInterspersedWithBlanks() {
        let ids = MouthyVoice.tokens("hˈI")
        #expect(ids.count == 7 && ids[0] == 0 && ids[2] == 0 && ids[6] == 0)
        #expect(ids[1] == MouthyVoice.symbolIDs["h"])
    }

    static let folder = ProcessInfo.processInfo.environment["MOUTHY_TEST_VOICE"].map { URL(fileURLWithPath: $0) }

    /// Plays one question through the speakers the way `AppModel.askUser` does (`MOUTHY_TEST_VOICE_PLAY=1`).
    @Test(.enabled(if: folder != nil && ProcessInfo.processInfo.environment["MOUTHY_TEST_VOICE_PLAY"] == "1")) @MainActor
    func playsAQuestionAndWaitsForTheEnd() async throws {
        _ = try Self.compiledVoice()
        MouthyVoice.directoryOverride = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-voice-test-\(getpid())")
        defer { MouthyVoice.directoryOverride = nil }
        let text = "Hi, I'm Mouthy. Should I push the branch to the hub now?"
        let start = Date()
        try await MouthyVoicePlayer.shared.speak(text)
        let seconds = Date().timeIntervalSince(start)
        print(String(format: "VOICE played in %.2f s", seconds))
        #expect(seconds > 2 && seconds < 8)
    }

    /// Compiled once per test run (tests run in parallel; Swift initializes a static let once).
    static let compiled: Result<MouthyVoice, Error> = Result { try compileVoice() }
    static func compiledVoice() throws -> MouthyVoice { try compiled.get() }

    static func compileVoice() throws -> MouthyVoice {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-voice-test-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in MouthyVoice.modelNames where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).mlmodelc").path) {
            let compiled = try MLModel.compileModel(at: folder!.appendingPathComponent("\(name).mlpackage"))
            try FileManager.default.moveItem(at: compiled, to: dir.appendingPathComponent("\(name).mlmodelc"))
        }
        let lexicon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Voice/lexicon.tsv")
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("lexicon.tsv").path) {
            try FileManager.default.copyItem(at: lexicon, to: dir.appendingPathComponent("lexicon.tsv"))
        }
        return try MouthyVoice(directory: dir)
    }

    static let sentences = [
        "Should I push the branch to the hub now, or wait until the tests pass?",
        "The build finished in 4.2 seconds with 3 warnings. Do you want me to fix them?",
        "Can I delete the 12 old backups from November 3rd, 2026?",
        "Hi, I'm Mouthy. What should I type?",
        "Is it okay to restart the PC at 9:30 tonight?",
        "Which file should I edit, AGENTS.md or the README?",
    ]

    @Test(.enabled(if: folder != nil)) @MainActor func rendersSentencesTheRecognizerHears() async throws {
        let voice = try Self.compiledVoice()
        let out = ProcessInfo.processInfo.environment["MOUTHY_VOICE_OUT"].map { URL(fileURLWithPath: $0) }
        let parakeet = SpeechModels.isInstalled(.parakeet, modelDirectory: nil)
        var errors = 0, words = 0
        for (i, text) in Self.sentences.enumerated() {
            let start = Date()
            var first: TimeInterval?
            let audio = try voice.render(text) { _ in if first == nil { first = Date().timeIntervalSince(start) } }
            let seconds = Double(audio.count) / MouthyVoice.sampleRate
            let peak = audio.map(abs).max() ?? 0
            print(String(format: "VOICE %d: %.2f s audio, first sentence after %.0f ms, all in %.0f ms | %@", i, seconds,
                         (first ?? 0) * 1000, Date().timeIntervalSince(start) * 1000, text))
            #expect(seconds > 0.6 && seconds < Double(text.count) * 0.12)
            #expect(peak > 0.01)
            let url = (out ?? FileManager.default.temporaryDirectory).appendingPathComponent("mouthy-voice-\(i).wav")
            try Self.writeWAV(audio, to: url)
            if parakeet {
                let heard = try await SpeechModels.transcribe(fileAt: url, configuration: DictationConfiguration(engine: .parakeet))
                let a = Self.words(text), b = Self.words(heard)
                let e = Self.editDistance(a, b); errors += e; words += a.count
                print("   heard: \(heard)  (\(e) word errors)")
            }
        }
        if parakeet {
            print("VOICE word errors \(errors)/\(words)")
            #expect(Double(errors) / Double(words) < 0.15)
        }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "-", with: " ").components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var d = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var prev = d[0]; d[0] = i + 1
            for (j, y) in b.enumerated() { let cur = d[j + 1]; d[j + 1] = min(d[j + 1] + 1, d[j] + 1, prev + (x == y ? 0 : 1)); prev = cur }
        }
        return d[b.count]
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: MouthyVoice.sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: MouthyVoice.sampleRate,
                                                              AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let peak = max(samples.map(abs).max() ?? 1, 1e-6)
        for i in 0..<samples.count { buffer.floatChannelData![0][i] = samples[i] / peak * 0.9 }
        try file.write(from: buffer)
    }
}

extension MouthyVoiceTests {
    @Test func phonemesWithoutSpacesAreCutToTheEncoderLimit() throws {
        guard Self.folder != nil else { return }
        let voice = try Self.compiledVoice()
        let limit = (MouthyVoice.maxTokens - 1) / 2
        let parts = voice.split(String(repeating: "ɛks", count: 400))
        #expect(parts.count > 1 && parts.allSatisfy { $0.unicodeScalars.count <= limit })
    }

    @Test @MainActor func playbackWaitResumesOnceWhicheverEndComesFirst() async {
        let wait = PlaybackWait()
        wait.added(); wait.finishProducing()
        wait.finish(); wait.played()
        await wait.wait()
        let early = PlaybackWait()
        early.finishProducing()
        await early.wait()
        #expect(wait.done && early.done)
    }
}
