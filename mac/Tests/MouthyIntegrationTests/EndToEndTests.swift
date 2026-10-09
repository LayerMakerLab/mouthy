import Testing
import Foundation
import AVFoundation
import CoreAudio
import Speech
import MouthyCore
@testable import MouthyKit

@MainActor
private func waitUntilSettled(_ model: AppModel) async throws {
    for _ in 0..<3000 {
        if !model.busy { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    model.cancel()
    Issue.record("AppModel did not settle within 30 seconds")
}

@Test @MainActor func setupPreventsCompetingOperations() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = AppModel(store: LocalStore(directory: directory), enablesHotkey: false)
    model.setupBusy = true
    model.output = "Preserve these words."
    model.transcribe(url: directory.appendingPathComponent("absent.wav"))
    #expect(model.phase == .idle)
    #expect(model.output == "Preserve these words.")
    model.rewriteOutput()
    #expect(model.phase == .idle)
    model.cancel()
}

@Test @MainActor func unreadableSettingsDoNotHideValidHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalStore(directory: directory)
    try store.save([MouthyCore.Transcript(raw: "Fixture", text: "Fixture", duration: 1, source: "Test", mode: "Natural")], as: "history.json")
    try Data("broken".utf8).write(to: directory.appendingPathComponent("preferences.json"))
    let model = AppModel(store: store, enablesHotkey: false)
    #expect(model.history.count == 1)
    #expect(model.status.contains("could not be read"))
    model.savePreferences(showConfirmation: true)
    #expect(model.status.contains("Settings could not be saved"))
    #expect(try String(contentsOf: directory.appendingPathComponent("preferences.json"), encoding: .utf8) == "broken")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] != nil))
@MainActor func failedImportCanRecoverAndHistoryStaysOptIn() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(store: LocalStore(directory: directory), enablesHotkey: false)
    model.transcribe(url: directory.appendingPathComponent("absent.wav"))
    try await waitUntilSettled(model)
    #expect(model.phase == .failed)
    #expect(!model.speech.isActive)
    model.transcribe(url: URL(fileURLWithPath: path))
    try await waitUntilSettled(model)
    #expect(model.phase == .idle)
    #expect(model.output.lowercased().contains("coffee"))
    #expect(model.history.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] != nil))
@MainActor func historyFailureRemainsVisibleAfterSuccessfulTranscription() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.json")
    let corrupt = Data("broken".utf8)
    try corrupt.write(to: url)
    let model = AppModel(store: LocalStore(directory: directory), enablesHotkey: false)
    model.preferences.keepHistory = true
    model.transcribe(url: URL(fileURLWithPath: path))
    try await waitUntilSettled(model)
    #expect(model.phase == .idle)
    #expect(model.output.lowercased().contains("coffee"))
    #expect(model.status.contains("History could not be saved"))
    #expect(try Data(contentsOf: url) == corrupt)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"] != nil))
@MainActor func historyRetentionOptOutDeletionAndReload() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalStore(directory: directory)
    let model = AppModel(store: store, enablesHotkey: false)
    model.preferences.keepHistory = true
    model.preferences.historyLimit = 10
    model.savePreferences()
    for _ in 0..<12 {
        model.transcribe(url: URL(fileURLWithPath: path))
        try await waitUntilSettled(model)
        try #require(model.phase == .idle)
    }
    #expect(model.history.count == 10)
    let lastIDs = model.history.map(\.id)
    model.preferences.keepHistory = false
    model.savePreferences()
    model.transcribe(url: URL(fileURLWithPath: path))
    try await waitUntilSettled(model)
    #expect(model.history.map(\.id) == lastIDs)
    model.deleteHistory(try #require(lastIDs.first))
    let reloaded = AppModel(store: LocalStore(directory: directory), enablesHotkey: false)
    #expect(reloaded.history.count == 9)
    #expect(!reloaded.preferences.keepHistory)
    #expect(reloaded.history.map(\.id) == Array(lastIDs.dropFirst()))
    reloaded.clearHistory()
    #expect(try store.load("history.json", as: [MouthyCore.Transcript].self)?.isEmpty == true)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1"))
@MainActor func additionalWritingModesAndOversizeFailurePreserveText() async throws {
    let source = "Mira has 42 red pencils. The delivery is on Friday."
    for mode in [WritingMode.concise, .custom] {
        let result = try await TextEnhancer.edit(source, mode: mode, customInstructions: "Use two short sentences. Keep every name, number, color, and date.")
        #expect(result.contains("Mira"))
        #expect(result.contains("42"))
        #expect(result.contains("Friday"))
        #expect(result.lowercased().contains("red"))
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = AppModel(store: LocalStore(directory: directory), enablesHotkey: false)
    let original = String(repeating: source + " ", count: 2000)
    model.output = original
    model.rewriteOutput()
    try await waitUntilSettled(model)
    #expect(model.phase == .idle)
    #expect(model.output == original)
    #expect(!model.status.hasPrefix("Refined."))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1"))
@MainActor func unsupportedLanguageFailsWithoutStartingAnalyzer() async throws {
    let service = SpeechService()
    do {
        let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
        _ = try await service.transcribeFile(URL(fileURLWithPath: path), locale: "zz-ZZ", vocabulary: "") { _ in }
        Issue.record("Unsupported language unexpectedly succeeded")
    } catch {
        #expect(error.localizedDescription.contains("does not support"))
    }
    #expect(!service.isActive)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1"))
@MainActor func batchKeepsSuccessfulFilesAndReportsIndividualFailure() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(store: LocalStore(directory: directory), enablesHotkey: false)
    model.transcribe(urls: [URL(fileURLWithPath: path), directory.appendingPathComponent("absent.wav"), URL(fileURLWithPath: path)])
    try await waitUntilSettled(model)
    #expect(model.phase == .idle)
    #expect(model.fileResults.count == 3)
    #expect(model.fileResults[0].document?.text.lowercased().contains("coffee") == true)
    #expect(model.fileResults[1].document == nil && model.fileResults[1].state.hasPrefix("Failed:"))
    #expect(model.fileResults[2].document?.segments.isEmpty == false)
    #expect(model.history.isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_CORPUS"] != nil))
@MainActor func audioCorpusThroughNativeRecognizer() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_CORPUS"]))
    let service = SpeechService()
    for name in ["normal", "stereo-48k", "quiet", "noise", "long", "silence"] {
        let start = Date()
        let text = try await service.transcribeFile(directory.appendingPathComponent(name + ".wav"), locale: "en-US", vocabulary: "") { _ in }
        print("CORPUS \(name) [\(Date().timeIntervalSince(start))s]: \(text)")
        if name == "silence" { #expect(text.isEmpty) }
        else {
            for word in ["morning", "garden", "coffee", "meeting"] { #expect(text.lowercased().contains(word), "\(name) missing \(word)") }
            if name == "long" { #expect(text.lowercased().components(separatedBy: "coffee").count - 1 == 8) }
        }
        #expect(!service.isActive)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_CORPUS"] != nil))
@MainActor func chunkedStereoFeedThroughStreamingAnalyzer() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_CORPUS"]))
    let file = try AVAudioFile(forReading: directory.appendingPathComponent("stereo-48k.wav"))
    let transcriber = try await SpeechService.transcriber(locale: "en-US", install: false) { _ in }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: file.processingFormat))
    try await analyzer.prepareToAnalyze(in: format)
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(512))
    var accumulator = TranscriptAccumulator()
    var previews = 0
    var meterUpdates = 0
    let reader = Task { @MainActor in
        for try await result in transcriber.results {
            accumulator.accept(String(result.text.characters), isFinal: result.isFinal)
            previews += 1
        }
    }
    try await analyzer.start(inputSequence: stream)
    let feed = AudioFeed(format: format, continuation: continuation, meter: { _ in Task { @MainActor in meterUpdates += 1 } }, failure: { Issue.record("Streaming feed failed: \($0)") })
    var position: Int64 = 0
    while position < file.length {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800))
        try file.read(into: buffer)
        feed.receive(buffer, time: AVAudioTime(sampleTime: position, atRate: file.processingFormat.sampleRate))
        position += Int64(buffer.frameLength)
        try await Task.sleep(for: .milliseconds(1))
    }
    feed.finish(); continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    try await reader.value
    #expect(accumulator.finalText.lowercased().contains("coffee"))
    #expect(previews > 0)
    #expect(meterUpdates > 0)
    print("STREAMING STEREO RESULT:", accumulator.finalText)
}

// Explicit opt-in: briefly plays a synthetic fixture through the current output.
// Does not request permissions, log recognized words, or save microphone audio.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_MICROPHONE"] == "1"))
@MainActor func liveMicrophoneLoopbackAndCancellation() async throws {
    #expect(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
    let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(store: LocalStore(directory: directory), enablesHotkey: false)
    model.preferences.showOverlay = false
    if let name = ProcessInfo.processInfo.environment["MOUTHY_MICROPHONE_ENGINE"], let engine = SpeechEngine(rawValue: name) { model.preferences.speechEngine = engine }
    model.preferences.autoInsert = false
    defer { model.cancel() }
    model.begin(captureTarget: false)
    for _ in 0..<1000 {
        if model.phase != .preparing { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(model.phase == .listening)
    let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
    player.currentDevice = try builtInSpeakerUID()
    defer { player.stop() }
    try #require(player.play())
    var sawLevel = false
    for _ in 0..<400 {
        sawLevel = sawLevel || model.level > 0.005
        if !player.isPlaying { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(500))
    model.stop()
    #expect(model.level == 0)
    try await waitUntilSettled(model)
    if model.phase == .failed { print("Microphone failure diagnostic:", model.status) }
    #expect(model.phase == .idle)
    #expect(sawLevel)
    #expect(model.startupSeconds != nil && model.finishSeconds != nil)
    #expect(model.currentInputName != "Microphone")
    print("Microphone metrics engine=\(model.preferences.speechEngine.rawValue) start=\(model.startupSeconds ?? -1)s finish=\(model.finishSeconds ?? -1)s")
    // Deliberately report only booleans, never the microphone transcript.
    let heardFixture = ["garden", "coffee", "meeting"].allSatisfy { model.output.lowercased().contains($0) }
    #expect(heardFixture)
    #expect(model.history.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
    #expect(!model.speech.isActive)
    model.begin(captureTarget: false)
    for _ in 0..<1000 {
        if model.phase != .preparing { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(model.phase == .listening)
    model.cancel()
    #expect(model.level == 0)
    try await waitUntilSettled(model)
    #expect(model.phase == .idle)
    #expect(!model.speech.isActive)
    #expect(model.status == "Cancelled. Nothing was inserted.")

    // A disconnected saved input must fail clearly, then permit a new session.
    model.preferences.inputDeviceUID = "mouthy-test-device-that-does-not-exist"
    model.begin(captureTarget: false)
    try await waitUntilSettled(model)
    #expect(model.phase == .failed)
    #expect(model.status.contains("disconnected"))
    #expect(!model.speech.isActive)
    model.preferences.inputDeviceUID = ""
    model.begin(captureTarget: false)
    for _ in 0..<1000 {
        if model.phase != .preparing { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(model.phase == .listening)
    model.cancel()
    try await waitUntilSettled(model)
    #expect(model.phase == .idle)
    #expect(!model.speech.isActive)
}

private func builtInSpeakerUID() throws -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try #require(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr)
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    try #require(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr)
    for device in devices {
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { continue }
        address.mSelector = kAudioDevicePropertyStreams; address.mScope = kAudioDevicePropertyScopeOutput
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { address.mScope = kAudioObjectPropertyScopeGlobal; continue }
        address.mSelector = kAudioDevicePropertyDeviceUID; address.mScope = kAudioObjectPropertyScopeGlobal
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid { return uid.takeRetainedValue() as String }
    }
    throw MouthyFailure("No built-in speaker was found for the explicitly requested microphone test.")
}
