import Testing
import Foundation
import AppKit
import AVFoundation
import Combine
import MouthyCore
@testable import MouthyKit

// Dictation state machine tests against a scripted speech engine and recorded deliveries.
// No microphone, models, permissions, key taps or real apps are involved.

@MainActor
final class FakeSpeech: DictationSpeech {
    var onPreview: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onWaveform: ((MicrophoneFrame) -> Void)?
    var onFailure: ((String) -> Void)?
    var onInterruption: ((String) -> Void)?
    var document = TranscriptionDocument(text: "")
    var inputDeviceName = "Test microphone"
    var isActive = false
    /// Results handed out by successive splits (empty when exhausted).
    var splits: [String] = []
    /// A split that keeps decoding this long even when cancelled, like a recognizer call in flight.
    var splitDelay: Double = 0
    /// When set, the next split throws this instead of returning text.
    var splitError: Error?
    /// Successive cancel() calls take these many seconds (then return at once).
    var cancelDelays: [Double] = []
    var finalText = ""
    var fileText = ""
    private(set) var splitCalls = 0
    private(set) var cancelCalls = 0
    private(set) var finishCalls = 0
    private(set) var splitting = false
    /// cancel() ran while a split was still decoding.
    private(set) var cancelledDuringSplit = false

    func start(locale: String, vocabulary: String, inputDeviceUID: String, provider: SpeechEngine, whisperModel: WhisperModel,
               whisperLanguage: String, translate: Bool, status: @escaping (String) -> Void) async throws { isActive = true }
    func split() async throws -> String {
        splitCalls += 1
        splitting = true; defer { splitting = false }
        if splitDelay > 0 { await pause(splitDelay) }
        if let splitError { self.splitError = nil; throw splitError }
        let text = splits.isEmpty ? "" : splits.removeFirst()
        onPreview?("")
        return text
    }
    func finish(cutAt: TimeInterval?) async throws -> String {
        finishCalls += 1
        isActive = false; document = TranscriptionDocument(text: finalText); return finalText
    }
    func cancel() async {
        if splitting { cancelledDuringSplit = true }
        cancelCalls += 1
        if !cancelDelays.isEmpty { await pause(cancelDelays.removeFirst()) }
        isActive = false
    }
    /// A delay that ignores task cancellation.
    private func pause(_ seconds: Double) async {
        await withUnsafeContinuation { done in DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.resume() } }
    }
    func transcribeFile(_ url: URL, locale: String, vocabulary: String, provider: SpeechEngine, whisperModel: WhisperModel,
                        whisperLanguage: String, translate: Bool, status: @escaping (String) -> Void) async throws -> String {
        document = TranscriptionDocument(text: fileText); return fileText
    }
}

/// What the model tried to paste or send, in order.
@MainActor
final class DeliveryLog {
    var texts: [String] = []
    var submits: [Bool] = []
    var returns = 0
}

@MainActor
func stateModel(_ speech: FakeSpeech, directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    -> (AppModel, DeliveryLog) {
    let model = AppModel(store: LocalStore(directory: directory), enablesHotkey: false, speech: speech)
    let log = DeliveryLog()
    model.captureTarget = {
        InsertionTarget(pid: ProcessInfo.processInfo.processIdentifier, name: "Target", bundleID: "dev.mouthy.test-target",
                        selectionRange: nil, element: nil, selectedText: "", secure: false)
    }
    model.deliverText = { text, _, _, _, submit in
        log.texts.append(text); log.submits.append(submit)
        return submit ? "Sent in Target." : "Pasted into Target."
    }
    model.pressReturn = { log.returns += 1 }
    return (model, log)
}

@MainActor
func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 5) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { Issue.record("Timed out waiting for a condition"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test func scriptedDictationIsDeliveredAndSettles() async throws {
    let speech = FakeSpeech(); speech.finalText = "Hello from the fake"
    let (model, log) = stateModel(speech)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    model.stop()
    try await waitFor { model.phase == .idle }
    #expect(log.texts == ["Hello from the fake"])
    #expect(model.status == "Pasted into Target.")
    #expect(model.output == "Hello from the fake")
}

/// Dictation results and Enter-sent parts reach the in-memory recent list for the menu bar panel.
@MainActor @Test func resultsAndSentPartsReachRecentResults() async throws {
    let marker = UUID().uuidString.prefix(8)
    let speech = FakeSpeech(); speech.splits = ["First part \(marker)"]; speech.finalText = "Second part \(marker)"
    let (model, log) = stateModel(speech)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    #expect(model.sendAndContinue())
    try await waitFor { log.texts.count == 1 }
    #expect(RecentResults.shared.items.contains("First part \(marker)"))
    model.stop()
    try await waitFor { model.phase == .idle }
    #expect(RecentResults.shared.items.contains("Second part \(marker)"))
}

/// Phases the model passed through, to prove it never showed "Needs attention".
@MainActor
final class PhaseLog {
    var seen: [AppModel.Phase] = []
    private var cancellable: AnyCancellable?
    init(_ model: AppModel) { cancellable = model.$phase.sink { [weak self] in self?.seen.append($0) } }
}

/// A cleanup model that never answers (and ignores cancellation) keeps the unrefined words and finishes.
@MainActor @Test func slowCleanupKeepsOriginalWordingInsteadOfFailing() async throws {
    let speech = FakeSpeech(); speech.finalText = "Meet me at noon"
    let (model, log) = stateModel(speech)
    model.preferences.mode = .tidy
    model.cleanupTimeout = .milliseconds(200)
    model.enhancer = { _, _, _, _ in
        // Ignores cancellation, like a model call that cannot be interrupted.
        await withUnsafeContinuation { done in DispatchQueue.main.asyncAfter(deadline: .now() + 3) { done.resume() } }
        return "Too late."
    }
    let phases = PhaseLog(model)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    let stopped = Date()
    model.stop()
    try await waitFor({ model.phase == .idle }, seconds: 2)
    #expect(Date().timeIntervalSince(stopped) < 1.5)
    #expect(log.texts == ["Meet me at noon"])
    #expect(model.output == "Meet me at noon")
    #expect(model.status == "Pasted into Target. " + AppModel.cleanupTimeoutNote)
    #expect(!phases.seen.contains(.failed))
}

/// The transcription watchdog stops at the words: cleanup longer than the watchdog still succeeds.
@MainActor @Test func watchdogDoesNotFailCleanupThatOutlastsIt() async throws {
    let speech = FakeSpeech(); speech.finalText = "please tidy this"
    let (model, log) = stateModel(speech)
    model.preferences.mode = .tidy
    model.watchdogSeconds = { _ in 0.1 }
    model.cleanupTimeout = .seconds(2)
    model.enhancer = { _, _, _, _ in try await Task.sleep(for: .milliseconds(400)); return "Please tidy this." }
    let phases = PhaseLog(model)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    model.stop()
    try await waitFor({ model.phase == .idle }, seconds: 3)
    #expect(log.texts == ["Please tidy this."])
    #expect(model.status == "Pasted into Target.")
    #expect(!phases.seen.contains(.failed))
}

/// A selection rewrite that takes too long leaves the selection alone and reports why, without failing.
@MainActor @Test func slowRewriteLeavesTheSelectionUnchanged() async throws {
    let speech = FakeSpeech(); speech.finalText = "make it formal"
    let (model, log) = stateModel(speech)
    model.preferences.rewriteSelection = true
    model.captureTarget = {
        InsertionTarget(pid: ProcessInfo.processInfo.processIdentifier, name: "Target", bundleID: "dev.mouthy.test-target",
                        selectionRange: nil, element: nil, selectedText: "hey there", secure: false)
    }
    model.cleanupTimeout = .milliseconds(150)
    model.rewriter = { _, _ in try await Task.sleep(for: .seconds(5)); return "Good day." }
    let phases = PhaseLog(model)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    model.stop()
    try await waitFor({ model.phase == .idle }, seconds: 2)
    #expect(log.texts.isEmpty)
    #expect(model.status == "Selection was not changed. " + AppModel.cleanupTimeoutNote)
    #expect(!phases.seen.contains(.failed))
}

/// Waking re-registers with the last arguments whatever the preset, but never while a shortcut is being recorded.
@MainActor @Test func wakeReRegistersTheLastShortcutsUnlessSuspended() {
    let service = HotkeyService(live: false)
    #expect(!service.didWake()) // nothing registered yet
    let mode = ModeShortcut(keyCode: 15, modifiers: 256, label: "⌘ R")
    _ = service.register(preset: 3, customKeyCode: 2, customModifiers: 4096, modeShortcuts: [mode, nil])
    let expected = HotkeyService.Registration(preset: 3, keyCode: 2, modifiers: 4096, modes: [mode, nil])
    #expect(service.lastRegistration == expected)
    #expect(service.didWake())
    #expect(service.registrations == 2)
    #expect(service.lastRegistration == expected)
    service.suspend()
    #expect(service.isSuspended)
    #expect(!service.didWake())
    #expect(service.registrations == 2)
    _ = service.register(preset: 0)
    #expect(!service.isSuspended)
}

@MainActor @Test func hotkeySuspendedHoldsRegistrationUntilCleared() {
    let (model, _) = stateModel(FakeSpeech())
    let before = model.hotkey.registrations
    model.hotkeySuspended = true
    #expect(model.hotkey.isSuspended)
    #expect(!model.hotkey.didWake())
    model.hotkeySuspended = false
    #expect(!model.hotkey.isSuspended)
    #expect(model.hotkey.registrations == before + 1)
    model.hotkeySuspended = false // already registered: no extra work
    #expect(model.hotkey.registrations == before + 1)
}

/// Settings save themselves shortly after a change, and only shortcut changes re-register the shortcuts.
@MainActor @Test func settingsAutosaveAndReloadWithoutExplicitSave() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _) = stateModel(FakeSpeech(), directory: directory)
    // The launch permission check re-registers the double tap (the default) once it sees Accessibility; count after it.
    try await Task.sleep(for: .milliseconds(600))
    let registrations = model.hotkey.registrations
    model.preferences.mode = .concise
    model.preferences.vocabulary = "Zephyr\nNimbus"
    try await Task.sleep(for: .milliseconds(500))
    let reloaded = AppModel(store: LocalStore(directory: directory), enablesHotkey: false, speech: FakeSpeech())
    #expect(reloaded.preferences.mode == .concise)
    #expect(reloaded.preferences.vocabulary == "Zephyr\nNimbus")
    #expect(model.hotkey.registrations == registrations) // nothing shortcut-related changed

    model.preferences.shortcut = 1
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.hotkey.registrations == registrations + 1)
    #expect(model.hotkey.lastRegistration?.preset == 1)
    // While a shortcut is being recorded, saves never re-register.
    model.hotkeySuspended = true
    model.preferences.customKeyCode = 3; model.preferences.shortcut = 3
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.hotkey.isSuspended)
    #expect(model.hotkey.registrations == registrations + 1)
    #expect(AppModel(store: LocalStore(directory: directory), enablesHotkey: false, speech: FakeSpeech()).preferences.shortcut == 3)
    model.hotkeySuspended = false
    #expect(model.hotkey.lastRegistration == HotkeyService.Registration(preset: 3, keyCode: 3, modifiers: model.preferences.customModifiers))
}

/// Escape during an Enter split pastes nothing, and the engine is only torn down once the split has let go.
@MainActor @Test func cancelDuringSplitPastesNothing() async throws {
    let speech = FakeSpeech(); speech.splits = ["Do not paste this"]; speech.splitDelay = 0.3
    let (model, log) = stateModel(speech)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    #expect(model.sendAndContinue())
    try await waitFor { speech.splitting }
    model.cancel()
    try await waitFor { model.phase == .idle }
    try await Task.sleep(for: .milliseconds(100))
    #expect(log.texts.isEmpty)
    #expect(log.returns == 0)
    #expect(model.status == "Cancelled. Nothing was inserted.")
    #expect(!speech.cancelledDuringSplit)
    #expect(model.sentSegments == 0)
}

/// The microphone changing mid-recording (a route change, a display sleeping, the lid closing) stops the recording
/// there and still delivers every word recorded so far, then says why it ended; it never fails or discards them.
@MainActor @Test func routeChangeMidRecordingDeliversTheWordsSoFar() async throws {
    let speech = FakeSpeech(); speech.finalText = "Words recorded before the microphone changed"
    let (model, log) = stateModel(speech)
    let phases = PhaseLog(model)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    speech.onInterruption?("The microphone changed, so recording stopped.")
    try await waitFor { model.phase == .idle }
    #expect(log.texts == ["Words recorded before the microphone changed"])
    #expect(speech.finishCalls == 1)
    #expect(speech.cancelCalls == 0)
    #expect(model.status == "Pasted into Target. The microphone changed, so recording stopped.")
    #expect(DictationOutcome.from(status: model.status, failed: false, target: model.targetName).kind == .success)
    #expect(!phases.seen.contains(.failed))
    // The next dictation starts clean: no stale notice.
    speech.finalText = "Next one"
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    model.stop()
    try await waitFor { model.phase == .idle }
    #expect(model.status == "Pasted into Target.")
}

/// An interruption that arrives while the microphone is still starting stops it as soon as it is listening.
@MainActor @Test func interruptionWhilePreparingStillDelivers() async throws {
    let speech = FakeSpeech(); speech.finalText = "Early words"
    let (model, log) = stateModel(speech)
    model.begin(captureTarget: true)
    #expect(model.phase == .preparing)
    model.interrupt("The microphone went away, so recording stopped.")
    try await waitFor { model.phase == .idle }
    #expect(log.texts == ["Early words"])
    #expect(model.status.hasSuffix("The microphone went away, so recording stopped."))
}

/// A failure that is cancelled before it settles ends idle: the cancel owns the phase, not the stale failure.
@MainActor @Test func cancelAfterFailureEndsIdle() async throws {
    let speech = FakeSpeech(); speech.cancelDelays = [0.3] // the failure's teardown is the slow one
    let (model, _) = stateModel(speech)
    let phases = PhaseLog(model)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    model.fail("The microphone connection changed.")
    #expect(model.phase == .finishing)
    model.cancel()
    try await waitFor { model.phase == .idle }
    try await Task.sleep(for: .milliseconds(450))
    #expect(model.phase == .idle)
    #expect(!phases.seen.contains(.failed))
    // An uncontested failure still lands on "Needs attention".
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    model.fail("The microphone is no longer available.")
    try await waitFor { model.phase == .failed }
}

/// A file batch never runs mode actions left over from a dictation, never strips trigger words, and holds
/// its phase until the whole batch is done.
@MainActor @Test func fileBatchSkipsModeActionsAndHoldsItsPhase() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let files = try (1...2).map { index -> URL in
        let url = directory.appendingPathComponent("clip\(index).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try file.write(from: buffer)
        return url
    }
    let marker = UUID().uuidString.prefix(8)
    let speech = FakeSpeech(); speech.finalText = "email note to self \(marker)"; speech.fileText = "email from the file \(marker)"
    let (model, _) = stateModel(speech, directory: directory.appendingPathComponent("support"))
    var mode = DictationMode(name: "Email"); mode.triggerWord = "email"; mode.output = .historyOnly
    model.preferences.modes = [mode]
    // A dictation picks the mode by trigger word: history only.
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    model.stop()
    try await waitFor { model.phase == .idle }
    #expect(model.status == "Saved to history.")
    #expect(model.history.count == 1)

    let phases = PhaseLog(model)
    model.transcribe(urls: files)
    try await waitFor({ !model.busy }, seconds: 10)
    let during = phases.seen.dropFirst() // the value at subscription
    #expect(during.filter { $0 == .idle }.count == 1)
    #expect(during.last == .idle)
    #expect(model.fileResults.map(\.state) == ["Ready", "Ready"])
    #expect(model.output.lowercased().hasPrefix("email from the file")) // trigger word kept
    #expect(model.activeModeName == nil)
    #expect(model.history.count == 1) // history is off; the dictation's history-only action did not carry over
    #expect(!RecentResults.shared.items.contains { $0.contains("from the file \(marker)") })
    #expect(model.status == "Batch finished. 2 of 2 files ready.")
}

/// An agent's question ends with the cancellation answer when the person cancels or the agent hangs up.
@MainActor @Test func agentQuestionCancelAndHangUp() async throws {
    for hangUp in [false, true] {
        let speech = FakeSpeech()
        let (model, log) = stateModel(speech)
        model.preferences.speakAgentQuestions = false
        let asked = Task { await model.askUser(["Ship it today?"]) }
        try await waitFor { model.phase == .listening }
        #expect(model.agentQuestion == "Ship it today?")
        if hangUp { model.agentAbandoned() } else { model.cancel() }
        let answer = await asked.value
        #expect(answer == "(The user cancelled the spoken answer.)")
        try await waitFor { model.phase == .idle }
        #expect(model.agentQuestion == nil)
        #expect(log.texts.isEmpty)
        model.agentAbandoned() // nothing open any more: no effect
        #expect(model.phase == .idle)
    }
}

/// Escape, the dictation shortcut (press and release) and mode shortcuts never stop a recording meeting.
@MainActor @Test func cancelRequestDuringMeetingLeavesItRecording() async throws {
    let speech = FakeSpeech()
    let (model, _) = stateModel(speech)
    var meetingStops = 0
    model.cancelMeeting = { meetingStops += 1 }
    model.preferences.modes = [DictationMode(name: "Email")]
    model.meetingCapture = true
    model.phase = .listening
    model.hotkey.onCancel?()
    model.hotkey.onPress?()
    model.hotkey.onRelease?()
    model.hotkey.onModeShortcut?(0)
    model.preferences.holdToTalk = true
    model.hotkey.onRelease?()
    try await Task.sleep(for: .milliseconds(50))
    #expect(meetingStops == 0)
    #expect(model.meetingCapture)
    #expect(model.phase == .listening)
    #expect(!speech.isActive) // no dictation was started on top of the meeting
    // The app's own Stop still ends it.
    model.stop()
    #expect(meetingStops == 1)
}

/// Enter before any live text (Parakeet/Whisper preview late) is still taken; a split with no words pastes
/// nothing and presses Return exactly once, for an empty and a punctuation-only result alike.
@MainActor @Test func wordlessSplitSubmitsExactlyOnce() async throws {
    for result in ["", " ... ", "?"] {
        let speech = FakeSpeech(); speech.splits = [result]
        let (model, log) = stateModel(speech)
        #expect(!model.sendAndContinue()) // not dictating: Enter passes through
        model.begin(captureTarget: true)
        try await waitFor { model.phase == .listening }
        #expect(model.liveText.isEmpty)
        #expect(model.sendAndContinue())
        try await waitFor { speech.splitCalls == 1 && log.returns == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.returns == 1)
        #expect(log.texts.isEmpty)
        #expect(model.sentSegments == 0)
        model.cancel()
        try await waitFor { model.phase == .idle }
    }
}

/// Enter sends a part; finishing with nothing new reports "Sent." and keeps the sent text, never the old preview.
@MainActor @Test func enterSplitThenStopReportsSent() async throws {
    let speech = FakeSpeech(); speech.splits = ["Ship it today"]
    let (model, log) = stateModel(speech)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    model.liveText = "Ship it today"
    #expect(model.sendAndContinue())
    try await waitFor { log.texts.count == 1 }
    try await waitFor { model.status == "Listening…" }
    #expect(log.submits == [true])
    #expect(model.liveText.isEmpty) // the split cleared the preview
    #expect(model.sentSegments == 1)
    model.liveText = "Ship it today" // a stale preview must not come back as the result
    model.stop()
    try await waitFor { model.phase == .idle }
    #expect(model.status == "Sent.")
    #expect(model.output == "Ship it today")
    #expect(log.texts == ["Ship it today"])
    // The next dictation starts counting again.
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    #expect(model.sentSegments == 0)
    model.stop()
    try await waitFor { model.phase == .idle }
    #expect(model.status == "No speech detected. Nothing was inserted.")
}

@MainActor @Test func failedEnterSplitThenStopKeepsTheFailure() async throws {
    struct Broken: LocalizedError { var errorDescription: String? { "the recognizer stopped" } }
    let speech = FakeSpeech(); speech.splitError = Broken()
    let (model, log) = stateModel(speech)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    #expect(model.sendAndContinue())
    try await waitFor { model.status.hasPrefix("That part could not be sent") }
    #expect(log.returns == 1, "the Enter still reaches the app once")
    model.stop() // says "Finishing your words…" and nothing more was said
    try await waitFor { model.phase == .idle }
    #expect(model.status == "That part could not be sent: the recognizer stopped")
    let outcome = DictationOutcome.from(status: model.status, failed: false, target: model.targetName)
    #expect(outcome.kind == .attention && outcome.text == "Not sent")
    #expect(log.texts.isEmpty)
}
