import Foundation
import Testing
import MouthyCore
@testable import MouthyKit

// What host apps get from `DictationSession` beyond plain dictation: microphone health and "Only my voice"
// through `DictationConfiguration.voiceprint`. No microphone, model or permission is used: a scripted engine stands in.

/// A scripted engine for `DictationSession`: the test sends levels; `finish` returns `finalText`.
@MainActor final class HostSpeech: DictationSpeech {
    var onPreview: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onWaveform: ((MicrophoneFrame) -> Void)?
    var onFailure: ((String) -> Void)?
    var onInterruption: ((String) -> Void)?
    var document = TranscriptionDocument(text: "")
    var inputDevice: InputDevice? = InputDevice(id: "test-headset", name: "Test Headset", objectID: 0)
    var inputDeviceName: String { inputDevice?.name ?? "Microphone" }
    var isActive = false
    var finalText = ""
    /// The voiceprint the voice filter would use, read when capture starts.
    private(set) var voiceprintAtStart: Voiceprint?
    func start(locale: String, vocabulary: String, inputDeviceUID: String, provider: SpeechEngine, whisperModel: WhisperModel,
               whisperLanguage: String, translate: Bool, status: @escaping (String) -> Void) async throws {
        voiceprintAtStart = VoicePrint.active
        isActive = true
    }
    func split() async throws -> String { "" }
    func finish(cutAt: TimeInterval?) async throws -> String { isActive = false; return finalText }
    func cancel() async { isActive = false }
    func transcribeFile(_ url: URL, locale: String, vocabulary: String, provider: SpeechEngine, whisperModel: WhisperModel,
                        whisperLanguage: String, translate: Bool, status: @escaping (String) -> Void) async throws -> String { "" }
    /// A level measured from samples the way capture measures them.
    func send(_ samples: [Float]) { onLevel?(samples.withUnsafeBufferPointer { MicrophoneFrame.measure($0).level }) }
}

@MainActor private func hostSession(_ speech: HostSpeech, _ configuration: DictationConfiguration = DictationConfiguration(),
                                    bluetooth: Bool = false) -> DictationSession {
    let session = DictationSession(configuration: configuration, speech: speech)
    session.microphonePermission = { true }
    session.modelInstalled = { _ in true }
    session.isBluetoothInput = { _ in bluetooth }
    session.speakerModelInstalled = { true }
    return session
}

private let zeros = [Float](repeating: 0, count: 1_600)
private let nearSilence = (0..<1_600).map { Float(sin(Double($0) * 0.3)) * 0.0015 }
private let roomNoise = (0..<1_600).map { Float(sin(Double($0) * 0.3)) * 0.01 }

/// Zeros and near-silence for the warning time raise `silentInput` while listening; signal clears it at once.
@MainActor @Test func dictationHealthWarnsOfASilentMicrophoneWhileListening() async throws {
    let speech = HostSpeech()
    let session = hostSession(speech, bluetooth: true)
    session.silenceWarning = .milliseconds(300)
    #expect(session.health == DictationHealth())
    try await session.start()
    #expect(session.phase == .listening)
    #expect(session.health.inputName == "Test Headset")
    #expect(session.health.isBluetoothHeadset)
    #expect(!session.health.silentInput)
    for _ in 0..<6 { speech.send(zeros); speech.send(nearSilence); try await Task.sleep(for: .milliseconds(30)) }
    try await waitFor({ session.health.silentInput }, seconds: 2)
    #expect(session.health.silenceMessage == "The microphone sent only silence (Test Headset). Check its input level in System Settings → Sound.")
    speech.send(roomNoise)
    try await waitFor { !session.health.silentInput }
    #expect(session.level > 0)
    session.cancel()
    #expect(session.level == 0)
}

/// Signal before the warning time: no warning.
@MainActor @Test func dictationHealthStaysQuietWhenTheMicrophoneHearsTheRoom() async throws {
    let speech = HostSpeech()
    let session = hostSession(speech)
    session.silenceWarning = .milliseconds(200)
    try await session.start()
    speech.send(roomNoise)
    try await Task.sleep(for: .milliseconds(450))
    #expect(!session.health.silentInput)
    #expect(!session.health.isBluetoothHeadset)
    session.cancel()
}

/// A recording that ends with no words after two seconds of pure silence names the microphone, as Mouthy does
/// (`silentMicrophoneIsNamedNotTheSpeaker`); a new start clears it.
@MainActor @Test func silentRecordingIsReportedWhenItStops() async throws {
    let speech = HostSpeech()
    let session = hostSession(speech)
    session.silenceWarning = .seconds(30)
    try await session.start()
    for _ in 0..<4 { speech.send(zeros) }
    try await Task.sleep(for: .milliseconds(2100))
    #expect(await session.stop() == nil)
    #expect(session.health.silentInput)
    try await session.start()
    #expect(!session.health.silentInput)
    speech.send(roomNoise)
    speech.finalText = "hello there"
    try await Task.sleep(for: .milliseconds(50))
    #expect(await session.stop() == "Hello there")
    #expect(!session.health.silentInput)
}

/// The host's voiceprint reaches the local engines' voice filter for that dictation; Apple Speech leaves it alone.
@MainActor @Test func voiceprintReachesTheVoiceFilterForLocalEngines() async throws {
    defer { VoicePrint.active = nil }
    let print = Voiceprint(embedding: [Float](repeating: 0.0625, count: SpeakerEmbedder.dimensions), windows: 6)
    let speech = HostSpeech()
    let session = hostSession(speech, DictationConfiguration(engine: .parakeet, voiceprint: print))
    try await session.start()
    #expect(speech.voiceprintAtStart == print)
    #expect(session.health.onlyMyVoice)
    session.cancel()
    try await waitFor { !speech.isActive }

    // Without the speaker model every voice is heard, and health says so.
    let noModel = hostSession(speech, DictationConfiguration(engine: .parakeet, voiceprint: print))
    noModel.speakerModelInstalled = { false }
    try await noModel.start()
    #expect(!noModel.health.onlyMyVoice)
    noModel.cancel()
    try await waitFor { !speech.isActive }

    // No voiceprint: a later session hears everyone again.
    let everyone = hostSession(speech, DictationConfiguration(engine: .parakeet))
    try await everyone.start()
    #expect(speech.voiceprintAtStart == nil)
    #expect(!everyone.health.onlyMyVoice)
    everyone.cancel()
    try await waitFor { !speech.isActive }

    // Apple Speech has no voice filter: the setting is not touched and health reports it off.
    let apple = hostSession(speech, DictationConfiguration(engine: .apple, voiceprint: print))
    VoicePrint.active = nil
    try await apple.start()
    #expect(speech.voiceprintAtStart == nil)
    #expect(!apple.health.onlyMyVoice)
    apple.cancel()
}

/// The speaker model is found in the first place that has it, and only a compiled model counts.
@Test func speakerModelIsFoundInTheFirstPlaceThatHasIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-model-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let host = root.appendingPathComponent("Host.app/Contents/Resources/\(SpeakerEmbedder.modelName)")
    let support = root.appendingPathComponent("Mouthy/Models/\(SpeakerEmbedder.modelName)")
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)   // empty: not compiled
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    #expect(SpeakerEmbedder.firstModel(in: [host, support]) == nil)
    try Data().write(to: support.appendingPathComponent("coremldata.bin"))
    #expect(SpeakerEmbedder.firstModel(in: [host, support]) == support)
    try Data().write(to: host.appendingPathComponent("coremldata.bin"))
    #expect(SpeakerEmbedder.firstModel(in: [host, support]) == host)
    // The host's bundle comes first, then Mouthy's support folder.
    let locations = SpeakerEmbedder.modelLocations
    #expect(locations.count >= 2)
    #expect(locations[1] == LocalStore.supportDirectory.appendingPathComponent("Models/\(SpeakerEmbedder.modelName)"))
}

/// Another app's speaker model is used only when the host named the signing team and that app is validly signed by it.
@Test func installedAppModelNeedsTheHostsTrustedTeam() throws {
    let team = "QWERT12345"
    #expect(SpeakerEmbedder.trusts(validSignature: true, teamID: team, trusted: team))
    #expect(!SpeakerEmbedder.trusts(validSignature: false, teamID: team, trusted: team), "a broken or altered bundle")
    #expect(!SpeakerEmbedder.trusts(validSignature: true, teamID: nil, trusted: team), "a Dev build signed locally")
    #expect(!SpeakerEmbedder.trusts(validSignature: true, teamID: "ABCDE12345", trusted: team), "another developer's app")
    #expect(!SpeakerEmbedder.trusts(validSignature: true, teamID: team, trusted: nil), "the host named no team")
    // An unsigned folder that looks like an app is never trusted, whatever team is named.
    let fake = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-fake-\(UUID().uuidString)/Mouthy.app")
    defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: fake.appendingPathComponent("Contents/Resources/\(SpeakerEmbedder.modelName)"), withIntermediateDirectories: true)
    try Data().write(to: fake.appendingPathComponent("Contents/Resources/\(SpeakerEmbedder.modelName)/coremldata.bin"))
    #expect(SpeakerEmbedder.signature(ofApp: fake, team: team).valid == false)
    #expect(SpeakerEmbedder.signature(ofApp: fake, team: "not a team\"").valid == false, "a malformed team is refused")
    #expect(SpeakerEmbedder.signature(ofApp: URL(fileURLWithPath: "/Applications/Mouthy.app"), team: "ÄBCDE12345") == (false, nil), "only ASCII letters and digits")
    #expect(SpeakerEmbedder.signature(ofApp: URL(fileURLWithPath: "/Applications/Mouthy.app"), team: "") == (false, nil))
    // This Mac's release, when present and Developer ID signed, checks out against its own team and no other.
    let release = URL(fileURLWithPath: "/Applications/Mouthy.app")
    if FileManager.default.fileExists(atPath: release.path), let releaseTeam = SpeakerEmbedder.signature(ofApp: release, team: team).teamID {
        #expect(SpeakerEmbedder.signature(ofApp: release, team: releaseTeam).valid)
        #expect(!SpeakerEmbedder.signature(ofApp: release, team: team).valid)
    }
}

/// By default (no team named) no installed app is read, so Mouthy's own lookup never leaves its own folders.
@Test func noTrustedTeamMeansNoInstalledApps() {
    #expect(SpeakerEmbedder.trustedTeamID == nil)
    #expect(SpeakerEmbedder.installedLocations.isEmpty)
    #expect(!SpeakerEmbedder.trustsInstalledApp(at: URL(fileURLWithPath: "/Applications/Mouthy.app")))
}
