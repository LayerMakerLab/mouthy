import Testing
import Foundation
import MouthyCore
@testable import MouthyKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_WHISPER"] == "1"))
func localWhisperRecognizesFixtureAndSilence() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
    #expect(WhisperRecognizer.installed(.baseEnglish))
    let document = try await WhisperRecognizer.shared.transcribe(file: URL(fileURLWithPath: path), model: .baseEnglish, language: "en", translate: false, vocabulary: "")
    #expect(["garden", "coffee", "meeting"].allSatisfy { document.text.lowercased().contains($0) })
    #expect(!document.segments.isEmpty)
    #expect(try !document.exported(as: .srt).isEmpty)
    let silence = try await WhisperRecognizer.shared.transcribe(samples: [Float](repeating: 0, count: 16_000), model: .baseEnglish, language: "en", translate: false, vocabulary: "")
    #expect(silence.text.isEmpty)
    await WhisperRecognizer.shared.releaseIfIdle()
}

@Test @MainActor func inputLevelReturnsToFlatAfterStaleSignal() async throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-stale-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let model = AppModel(store: LocalStore(directory: support), enablesHotkey: false)
    model.phase = .listening
    model.receiveLevel(0.5)
    #expect(model.level == 0.5)
    // Waits on a deadline rather than one fixed sleep, so a busy parallel run can't flake it.
    let deadline = ContinuousClock.now + .seconds(2)
    while model.level != 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(model.level == 0)
    model.phase = .idle
}

@Test func whisperRejectsUnsupportedLanguageAndTranslationBeforeLoading() async {
    await #expect(throws: MouthyFailure.self) {
        try await WhisperRecognizer.shared.transcribe(samples: [], model: .baseEnglish, language: "es", translate: false, vocabulary: "")
    }
    await #expect(throws: MouthyFailure.self) {
        try await WhisperRecognizer.shared.transcribe(samples: [], model: .turbo, language: "auto", translate: true, vocabulary: "")
    }
}
