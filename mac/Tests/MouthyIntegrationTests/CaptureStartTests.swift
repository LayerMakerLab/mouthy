import AVFoundation
import Foundation
import Testing
@testable import MouthyKit

// MOUTHY_TEST_CAPTURE=1 swift test --filter captureStart (MOUTHY_TEST_CAPTURE_INPUT=<uid> adds a chosen microphone)
// Opens the default microphone the way a dictation does (ParakeetService), for 1.5 s, five times, and measures how
// much of the start is lost: time from start() returning to the first sample, audio the engine dropped while it
// stopped itself after starting ("iounit configuration changed"), and how far the last sample lags the clock (the
// stop cut). Needs an existing microphone grant for the app running the tests; it never prompts for one. Audio stays
// in memory, is never recognized and is discarded. Gate: under 60 ms lost at the start, no configuration restart.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_CAPTURE"] == "1"))
struct CaptureStart {
    @Test func captureStartKeepsTheFirstWords() async throws {
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "no microphone grant: run where one exists")
        var worstLost = 0.0, restarts = 0
        // The system input (what most people use) five times, then twice the microphone named by MOUTHY_TEST_CAPTURE_INPUT
        // (a UID), as if chosen in Settings, which may still need a restart (reported, not gated). Never another device
        // unasked: an iPhone or Bluetooth microphone would wake that device.
        let uid = ProcessInfo.processInfo.environment["MOUTHY_TEST_CAPTURE_INPUT"]
        let other = uid.flatMap { uid in AudioDevices.inputs().first { $0.id == uid } }
        for round in 1...(other == nil ? 5 : 7) {
            let chosen = round > 5 ? other?.id ?? "" : ""
            if round > 5 { print("CAPTURE chosen input \(other?.name ?? "")") }
            var changes = 0
            let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { _ in changes += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }
            let service = ParakeetService()
            let requested = ProcessInfo.processInfo.systemUptime
            try service.start(inputDeviceUID: chosen, level: { _ in }, interrupted: { _ in })
            let started = ProcessInfo.processInfo.systemUptime
            var firstSample: Double?
            while ProcessInfo.processInfo.systemUptime - started < 1.5 {
                if firstSample == nil, service.sampleCount > 0 { firstSample = ProcessInfo.processInfo.systemUptime }
                try await Task.sleep(for: .milliseconds(5))
            }
            let samples = try service.finishSamples()
            let now = ProcessInfo.processInfo.systemUptime
            let until = service.recordedUntil ?? now
            // Audio that should exist from the moment start() returned until the last captured sample, against what came.
            let captured = Double(samples.count) / 16_000
            let lost = max(0, (until - started) - captured)
            if round <= 5 { worstLost = max(worstLost, lost); restarts += changes }
            print(String(format: "CAPTURE round %d: start() took %.0f ms, first sample after %.0f ms, captured %.3f s of %.3f s (lost %.0f ms), configuration changes %d, last sample %.0f ms before the stop",
                         round, (started - requested) * 1000, ((firstSample ?? now) - started) * 1000, captured, until - started, lost * 1000,
                         changes, (now - until) * 1000))
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(worstLost < 0.06, "lost \(Int(worstLost * 1000)) ms at the start")
        #expect(restarts == 0, "the engine restarted \(restarts) times")
    }

    /// The audio device must keep up while Parakeet recognizes: the microphone records for 20 s while a LiveTranscriber
    /// replays synthesized speech through the same passes and previews a dictation runs. Gate: no "skipping cycle due
    /// to overload" lines from this process in the unified log, and no audio missing from the capture.
    @Test func captureKeepsUpWhileRecognizing() async throws {
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "no microphone grant: run where one exists")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await ParakeetRecognizer.shared.prepare(download: false) { _ in }
        await VoiceActivity.shared.prepare()
        var clip: [Float] = []
        for sentence in ["The new printer arrived on Tuesday and the calibration took most of the afternoon.",
                         "Two customers asked for custom colors, so I ordered three new spools of filament.",
                         "Next week I want to finish the packaging redesign and test the new labels.",
                         "Please send me any questions before Friday so we can plan the next order.",
                         "The supplier raised prices by five percent starting next month."] {
            clip += Corpus.level(try Corpus.say(sentence, in: folder), Corpus.speech) + Corpus.silence(0.5)
        }
        clip = Corpus.room(clip + Corpus.silence(1))
        let window = Date()
        let service = ParakeetService()
        try service.start(inputDeviceUID: "", level: { _ in }, interrupted: { _ in })
        let started = ProcessInfo.processInfo.systemUptime
        var fed = 0
        let audio = clip
        let live = LiveTranscriber(decode: { samples, boost in try await ParakeetRecognizer.shared.transcribe(samples: samples, boost: boost) },
                                   decodeAfter: ParakeetRecognizer.decodeAfter, hearsSpeech: VoiceActivity.hearsSpeech,
                                   count: { fed }, read: { Array(audio[$0.clamped(to: 0..<fed)]) })
        while fed < audio.count {
            fed = min(audio.count, fed + 1_600)
            live.tick()
            try await Task.sleep(for: .milliseconds(100))
        }
        let text = try await live.finish(audio)
        let samples = try service.finishSamples()
        let until = service.recordedUntil ?? ProcessInfo.processInfo.systemUptime
        let lost = max(0, (until - started) - Double(samples.count) / 16_000)
        let log = Process()
        let pipe = Pipe()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        log.arguments = ["show", "--start", formatter.string(from: window.addingTimeInterval(-1)), "--style", "compact", "--predicate",
                         "processID == \(ProcessInfo.processInfo.processIdentifier) AND eventMessage CONTAINS[c] \"overload\""]
        log.standardOutput = pipe
        try log.run(); log.waitUntilExit()
        let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").filter { $0.localizedCaseInsensitiveContains("overload") }
        print(String(format: "CAPTURE under load: %.1f s recorded while recognizing %.1f s of speech (%d words), lost %.0f ms, overload lines %d",
                     until - started, Double(audio.count) / 16_000, Corpus.words(text).count, lost * 1000, lines.count))
        #expect(lines.isEmpty, "\(lines.count) overload lines")
        #expect(lost < 0.1, "lost \(Int(lost * 1000)) ms")
        #expect(Corpus.words(text).count > 50)
    }
}
