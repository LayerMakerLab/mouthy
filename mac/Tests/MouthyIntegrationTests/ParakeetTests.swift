import Testing
import AVFoundation
import Foundation
import MouthyCore
@testable import MouthyKit

@Test func parakeetBufferConvertsStereoAndStopsAcceptingAfterFinish() throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    audio.frameLength = 48_000
    for channel in 0..<2 { for i in 0..<48_000 { audio.floatChannelData![channel][i] = 0.2 * sin(Float(i) * 0.06) } }
    let buffer = ParakeetAudioBuffer()
    buffer.receive(audio)
    #expect(buffer.count > 0)
    let samples = try buffer.finish()
    #expect(abs(samples.count - 16_000) < 100)
    #expect(samples.allSatisfy { $0.isFinite })
    buffer.receive(audio)
    #expect(buffer.count == 0)
    #expect(try buffer.finish().isEmpty)
    let cancelled = ParakeetAudioBuffer()
    cancelled.receive(audio); cancelled.cancel()
    #expect(try cancelled.finish().isEmpty)
}

@Test func nativeCaptureOwnsSamplesAcrossBufferReuseAndSplits() throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 533)!
    audio.frameLength = 533
    let capture = ParakeetAudioBuffer()
    for i in 0..<533 { audio.floatChannelData![0][i] = 0.25 }
    capture.receive(audio)
    let snapshot = capture.snapshot()
    for i in 0..<533 { audio.floatChannelData![0][i] = -0.5 }
    capture.receive(audio)
    let first = capture.take()
    #expect(snapshot == [Float](repeating: 0.25, count: 533))
    #expect(first == snapshot + [Float](repeating: -0.5, count: 533))
    #expect(capture.count == 0)
    capture.receive(audio)
    #expect(try capture.finish() == [Float](repeating: -0.5, count: 533))
    #expect(first.prefix(533).allSatisfy { $0 == 0.25 }, "subsequent capture must not overwrite handed-off audio")
}

@Test func captureConversionKeepsAudioAcrossUnevenBuffers() throws {
    for rate in [44_100.0, 48_000.0] {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let capture = ParakeetAudioBuffer()
        var count = 0
        for length in [137, 1_600, 53, 4_321, 1_000, 17_003] {
            let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
            audio.frameLength = AVAudioFrameCount(length)
            for channel in 0..<2 { for i in 0..<length { audio.floatChannelData![channel][i] = 0.2 * sin(Float(count + i) * 0.06) } }
            capture.receive(audio)
            count += length
        }
        let samples = try capture.finish()
        #expect(abs(samples.count - Int(Double(count) * 16_000 / rate)) < 100)
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(samples.filter { abs($0) > 0.05 }.count > samples.count / 2, "buffer reuse must not replace speech with silence")
    }
}


@Test func parakeetModelFolderFollowsTheHost() throws {
    defer { ParakeetRecognizer.modelDirectory = nil }
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-empty-models-\(UUID().uuidString)")
    #expect(!SpeechModels.isInstalled(.parakeet, modelDirectory: empty))
    ParakeetRecognizer.modelDirectory = empty
    #expect(ParakeetRecognizer.modelFolder == empty && !ParakeetRecognizer.installed)
}



/// Real-model tests share one recognizer, so they run one at a time.
@Suite(.serialized) struct ParakeetModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_PARAKEET"] == "1"))
    func localParakeetRecognizesFixtureAndSilence() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
        try await ParakeetRecognizer.shared.prepare(download: true) { _ in }
        #expect(ParakeetRecognizer.installed)
        let text = try await ParakeetRecognizer.shared.transcribe(file: URL(fileURLWithPath: path))
        #expect(["garden", "coffee", "meeting"].allSatisfy { text.lowercased().contains($0) })
        let silence = try await ParakeetRecognizer.shared.transcribe(samples: [Float](repeating: 0, count: 16_000))
        #expect(silence.isEmpty)
    }


    /// Boosting matches spelling against the audio: it fixes terms said the way they are written
    /// (kubectl) and never makes a result worse. Names spelled unlike their sound (Siobhan) need a replacement.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_PARAKEET"] == "1"))
    func parakeetVocabularyBoostsRareTerms() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-vocabulary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("terms.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "--data-format=LEI16@16000", "Siobhan asked Nguyen to deploy the Tauri build with kubectl before the Anthropic review."]
        try say.run(); say.waitUntilExit()
        try await ParakeetRecognizer.shared.prepare(download: true) { _ in }
        #expect(ParakeetRecognizer.boostingInstalled)
        let terms = ["Siobhan", "Nguyen", "Tauri", "kubectl", "Anthropic"]
        await ParakeetRecognizer.shared.setVocabulary("")
        let plain = try await ParakeetRecognizer.shared.transcribe(file: audio)
        await ParakeetRecognizer.shared.setVocabulary(terms.joined(separator: "\n"))
        let boosted = try await ParakeetRecognizer.shared.transcribe(file: audio)
        print("PARAKEET PLAIN: \(plain)\nPARAKEET BOOSTED: \(boosted)")
        let found = { (text: String) in terms.filter { text.localizedCaseInsensitiveContains($0) }.count }
        #expect(found(boosted) >= found(plain))
        #expect(boosted.localizedCaseInsensitiveContains("kubectl"))
    }

    /// The host-facing file path: `say` audio → Parakeet → shaped text.
    @MainActor @Test func speechModelsTranscribeFileForHosts() async throws {
        guard ProcessInfo.processInfo.environment["MOUTHY_TEST_PARAKEET"] == "1", let fixture = ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] else { return }
        let text = try await SpeechModels.transcribe(fileAt: URL(fileURLWithPath: fixture), configuration: DictationConfiguration(engine: .parakeet))
        #expect(!text.isEmpty)
    }
}
