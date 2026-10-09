import AVFoundation
import AppKit
import Testing
@testable import MouthyKit
@testable import MouthyNotch

// End to end, the way people use Mouthy: synthetic speech enters where the microphone's audio does, in real time
// and followed by a quiet room (ParakeetService.testInput), then capture, the live recognizer, Parakeet (voice only),
// every text rule and delivery run as they do for the microphone, and the words are typed into the headless delivery
// target (scripts/delivery-target.swift: off screen, private pasteboard, no keystrokes). Needs Accessibility for the
// terminal running it; plays nothing out loud.
// MOUTHY_TEST_DELIVERY=1 MOUTHY_TEST_PARAKEET=1 swift test --filter microphoneToText
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_DELIVERY"] == "1"
                                           && ProcessInfo.processInfo.environment["MOUTHY_TEST_PARAKEET"] == "1"))
struct MicrophoneToText {
    // Six cases, plus a seventh with "Only listen to my voice" on (needs the speaker model on this Mac).
    @Test func microphoneToTextTypesWhatWasSaidAndNothingElse() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = try await Harness(); defer { harness.stop() }
        let model = AppModel(store: LocalStore(directory: folder), enablesHotkey: false)
        model.preferences.speechEngine = .parakeet
        model.preferences.showOverlay = false
        model.preferences.autoInsert = true
        model.preferences.smartFormatting = true
        model.preferences.removeFillers = true
        model.preferences.mediaWhileDictating = .nothing
        defer { model.cancel(); ParakeetService.testInput = nil }
        try await ParakeetRecognizer.shared.prepare(download: false) { _ in }

        // Speech, written with `say`'s own silences ([[slnc ms]]).
        func spoken(_ name: String, _ text: String, voice: String? = nil) throws -> URL {
            let url = folder.appendingPathComponent("\(name).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, text]
            try say.run(); say.waitUntilExit()
            return url
        }
        // A cough-like burst of shaped noise in a quiet second: no voice in it.
        func cough() throws -> URL {
            let url = folder.appendingPathComponent("cough.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let frames = AVAudioFrameCount(16_000 * 3)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            var seed: UInt32 = 99, previous: Float = 0
            for i in 0..<Int(frames) {
                seed = seed &* 1_103_515_245 &+ 12_345
                let noise = Float(seed % 1_000) / 1_000 - 0.5
                previous = 0.6 * previous + 0.4 * noise
                let t = Double(i) / 16_000 - 1.0
                let envelope = t > 0 && t < 0.35 ? Float(sin(Double.pi * t / 0.35)) : 0
                buffer.floatChannelData![0][i] = 0.5 * envelope * previous
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }

        var loudest: Float = 0
        func dictate(_ clip: URL, quiet seconds: Double = 0) async throws -> String {
            harness.set("", cursor: 0)
            ParakeetService.testInput = clip
            model.begin(captureTarget: true)
            for _ in 0..<1000 where model.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
            try #require(model.phase == .listening)
            let length = try AVAudioFile(forReading: clip)
            let duration = Double(length.length) / length.processingFormat.sampleRate
            for _ in 0..<Int((duration + seconds + 0.6) * 20) {
                loudest = max(loudest, model.level)
                try await Task.sleep(for: .milliseconds(50))
            }
            // Only ever the harness: if anything pointed delivery elsewhere, cancel instead of typing into a real app.
            guard TextDelivery.frontmost()?.processIdentifier == harness.app.processIdentifier else {
                model.cancel()
                Issue.record("delivery no longer points at the test target; cancelled instead of typing")
                return ""
            }
            model.stop()
            for _ in 0..<3000 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(300))
            return harness.value
        }

        let cases: [(name: String, clip: URL, quiet: Double, expected: String)] = [
            ("pause mid-sentence", try spoken("pause", "I want to go [[slnc 450]] to the store."), 0, "I want to go to the store."),
            ("time and abbreviation", try spoken("time", "Let's meet at 3 p.m. on Tuesday."), 0, "Let's meet at 3 p.m. on Tuesday."),
            ("two sentences", try spoken("two", "Send the update tonight. [[slnc 1100]] Then tell the team."), 0, "Send the update tonight. Then tell the team."),
            ("speech then silence", try spoken("tail", "Book the dentist for Thursday."), 4, "Book the dentist for Thursday."),
            ("silence only", try spoken("silence", "[[slnc 3000]]"), 0, ""),
            ("a cough only", try cough(), 0, ""),
        ]
        var failures: [String] = []
        for item in cases {
            let typed = try await dictate(item.clip, quiet: item.quiet)
            let ok = typed == item.expected
            print("E2E \(item.name): \(ok ? "PASS" : "FAIL, typed \"\(typed)\", wanted \"\(item.expected)\"; recognized \"\(model.output)\"; status \"\(model.status)\"")")
            if !ok { failures.append(item.name) }
        }
        // "Only listen to my voice": with the person's voiceprint (the default voice) on, another voice alone types nothing.
        try VoicePrint.save(try await VoicePrintTests.train(in: folder), in: folder)
        model.preferences.onlyMyVoice = true
        defer { model.preferences.onlyMyVoice = false; VoicePrint.active = nil }
        let other = try spoken("other", "Tonight on the evening news, heavy rain is expected across the northern valley.", voice: "Daniel")
        let typed = try await dictate(other)
        print("E2E another voice only, voiceprint on: \(typed.isEmpty ? "PASS" : "FAIL, typed \"\(typed)\"")")
        if !typed.isEmpty { failures.append("another voice only, voiceprint on") }
        #expect(failures.isEmpty, "\(failures)")
        // The bars follow the voice: ordinary speech lifts every bar off its rest.
        let lifted = zip(WaveformShape.live(count: 5, level: loudest), (0..<5).map { WaveformShape.rest($0, of: 5) }).allSatisfy { $0 - $1 >= 0.1 }
        print("E2E loudest level \(String(format: "%.2f", loudest)), bars lifted: \(lifted)")
        #expect(lifted)
        #expect(model.history.isEmpty)
    }
}
