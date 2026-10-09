import Testing
import Foundation
import AVFoundation
import FoundationModels
import Speech
import MouthyCore
@testable import MouthyKit

@Test @MainActor func storageRoundTripAndPermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalStore(directory: directory)
    let transcript = MouthyCore.Transcript(raw: "Hello", text: "Hello.", duration: 2, source: "Test", mode: "Natural")
    try store.save([transcript], as: "history.json")
    let result = try store.load("history.json", as: [MouthyCore.Transcript].self)
    let loaded = try #require(result)
    #expect(loaded.count == 1)
    #expect(loaded[0].text == "Hello.")
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.json").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] != nil))
@MainActor func actualAppleSpeechFixture() async throws {
    guard let path = ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] else { return }
    let service = SpeechService()
    var previews: [String] = []
    service.onPreview = { previews.append($0) }
    let text = try await service.transcribeFile(URL(fileURLWithPath: path), locale: "en-US", vocabulary: "") { _ in }
    print("NATIVE SPEECH RESULT:", text)
    #expect(text.lowercased().contains("morning"))
    #expect(text.lowercased().contains("coffee"))
    #expect(text.lowercased().contains("garden"))
    #expect(!previews.isEmpty)
    await service.cancel()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] != nil))
@MainActor func cancelledServiceCanRestart() async throws {
    guard let path = ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] else { return }
    let service = SpeechService()
    let task = Task { try await service.transcribeFile(URL(fileURLWithPath: path), locale: "en-US", vocabulary: "") { _ in } }
    for _ in 0..<200 {
        if service.isActive { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(service.isActive)
    task.cancel()
    await service.cancel()
    do { _ = try await task.value; Issue.record("Cancelled transcription returned success") }
    catch { #expect(error is CancellationError) }
    #expect(!service.isActive)
    let text = try await service.transcribeFile(URL(fileURLWithPath: path), locale: "en-US", vocabulary: "") { _ in }
    #expect(text.lowercased().contains("morning"))
    await service.cancel()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1"))
@MainActor func actualAppleIntelligenceCleanup() async throws {
    let source = "um Mira has 42 red pencils and she needs them on Friday"
    let text = try await TextEnhancer.edit(source, mode: .tidy, customInstructions: "")
    print("NATIVE CLEANUP RESULT:", text)
    #expect(text.contains("Mira"))
    #expect(text.contains("42"))
    #expect(text.contains("Friday"))
    #expect(!text.lowercased().hasPrefix("um "))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1"))
@MainActor func silenceProducesNoInventedText() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
    buffer.frameLength = 96000
    if let channel = buffer.floatChannelData?[0] { channel.initialize(repeating: 0, count: 96000) }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
    let service = SpeechService()
    let text = try await service.transcribeFile(url, locale: "en-US", vocabulary: "") { _ in }
    #expect(text.isEmpty)
    await service.cancel()
}

@Test @MainActor func corruptHistoryIsNeverOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.json")
    let original = Data("not valid JSON".utf8)
    try original.write(to: url)
    let store = LocalStore(directory: directory)
    #expect(throws: (any Error).self) { try store.load("history.json", as: [MouthyCore.Transcript].self) }
    #expect(throws: (any Error).self) { try store.save([MouthyCore.Transcript](), as: "history.json") }
    #expect(try Data(contentsOf: url) == original)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] != nil))
@MainActor func fileToEditedOutputAndPersistedHistory() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalStore(directory: directory)
    let model = AppModel(store: store, enablesHotkey: false)
    model.preferences.keepHistory = true
    model.preferences.mode = .verbatim
    model.preferences.replacements = [Replacement(phrase: "morning", replacement: "evening")]
    model.transcribe(url: URL(fileURLWithPath: path))
    for _ in 0..<1000 {
        if !model.busy { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.phase == .idle)
    #expect(model.output.lowercased().contains("evening"))
    #expect(model.history.count == 1)
    #expect(model.history.first?.raw.lowercased().contains("morning") == true)
    let persisted = try store.load("history.json", as: [MouthyCore.Transcript].self)
    #expect(persisted?.first?.text == model.output)
    #expect(model.status.contains("Ready"))
    model.cancel()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1"))
@MainActor func actualSelectionRewrite() async throws {
    let text = try await TextEnhancer.rewrite(selection: "Mira has 42 red pencils.", instruction: "Change red to green.")
    print("NATIVE REWRITE RESULT:", text)
    #expect(text.contains("42"))
    #expect(text.contains("Mira"))
    #expect(text.contains("green"))
    #expect(!text.contains("red"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] != nil))
@MainActor func liveAudioConversionPreservesDuration() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
    let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    let format = try #require(compatibleFormat)
    let (stream, continuation) = AsyncStream<Speech.AnalyzerInput>.makeStream()
    let feed = AudioFeed(format: format, continuation: continuation, meter: { _ in }, failure: { Issue.record("Audio conversion failed: \($0)") })
    var position: Int64 = 0
    while position < file.length {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800))
        try file.read(into: buffer)
        feed.receive(buffer, time: AVAudioTime(sampleTime: position, atRate: file.processingFormat.sampleRate))
        position += Int64(buffer.frameLength)
    }
    feed.finish(); continuation.finish()
    var convertedDuration = 0.0
    // These analyzer input properties exist on macOS 27 (the test host); macOS 26 uses the legacy feed.
    guard #available(macOS 27.0, *) else { return }
    for await input in stream {
        #expect(input.bufferFormat.sampleRate == format.sampleRate)
        #expect(input.bufferFormat.commonFormat == format.commonFormat)
        convertedDuration += CMTimeGetSeconds(input.bufferDuration)
    }
    let originalDuration = Double(file.length) / file.processingFormat.sampleRate
    #expect(abs(convertedDuration - originalDuration) < 0.02)
}

@Test @MainActor func nativePasteKeyCanBeResolved() throws {
    let key = try #require(PasteShortcut.keyCode())
    #expect(key < 128)
}

@Test @MainActor func pasteReadbackRequiresValidUTF16Selection() {
    #expect(TextDelivery.expectedValue(afterInserting: "new", into: "old words", range: CFRange(location: 0, length: 3)) == "new words")
    #expect(TextDelivery.expectedValue(afterInserting: "word", into: "😀 ", range: CFRange(location: 3, length: 0)) == "😀 word")
    #expect(TextDelivery.expectedValue(afterInserting: "word", into: nil, range: CFRange(location: 0, length: 0)) == nil)
    #expect(TextDelivery.expectedValue(afterInserting: "word", into: "abc", range: CFRange(location: 4, length: 0)) == nil)
    #expect(TextDelivery.expectedValue(afterInserting: "word", into: "abc", range: CFRange(location: 1, length: Int.max)) == nil)
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1"))
func grammarStyleCorrectsWithoutRephrasing() async throws {
    let text = try await TextEnhancer.edit("can you fix the build script it fails when the cache is empty", mode: .grammar, customInstructions: "")
    #expect(text == "Can you fix the build script? It fails when the cache is empty.")
}
