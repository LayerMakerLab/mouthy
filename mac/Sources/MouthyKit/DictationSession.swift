import AppKit
import AVFoundation
import Foundation
import MouthyCore

/// How finished text is shaped. `.prose` for chat and agent prompts; `.code` adds spoken casing and
/// symbols ("open paren", "camel case") for shells and editors.
public enum DictationTextStyle: Sendable, Equatable { case prose, code }

public struct DictationConfiguration: Sendable, Equatable {
    public var engine: SpeechEngine
    public var locale: String
    /// One term per line; Parakeet boosts them, Apple Speech uses them as contextual strings.
    public var vocabulary: String
    public var replacements: [Replacement]
    public var textStyle: DictationTextStyle
    /// Recording stops itself after this long and transcribes what was said.
    public var maximumDuration: Duration
    /// Parakeet model folder. Nil uses FluidAudio's shared cache (what Mouthy uses).
    public var modelDirectory: URL?
    /// "Only my voice" (Parakeet and Whisper): other voices (a TV, a call, people nearby) are turned down like any other
    /// non-voice sound, so their words are not returned. Pass `VoicePrint.loadFromMouthy()` (the person's voiceprint
    /// from Mouthy's Settings → Speech, read-only) or nil for everyone's voice. Needs the speaker model
    /// (`SpeakerEmbedder.bundledModel`); without it every voice is heard and `DictationSession.health.onlyMyVoice` is false.
    public var voiceprint: Voiceprint?

    public init(engine: SpeechEngine = .parakeet, locale: String = "en-US", vocabulary: String = "",
                replacements: [Replacement] = [], textStyle: DictationTextStyle = .prose,
                maximumDuration: Duration = .seconds(60), modelDirectory: URL? = nil, voiceprint: Voiceprint? = nil) {
        self.engine = engine; self.locale = locale; self.vocabulary = vocabulary
        self.replacements = replacements; self.textStyle = textStyle; self.maximumDuration = maximumDuration
        self.modelDirectory = modelDirectory; self.voiceprint = voiceprint
    }
}

/// What a host can tell the person about the microphone during a dictation (`DictationSession.health`).
public struct DictationHealth: Sendable, Equatable {
    /// The input recording this dictation ("MacBook Pro Microphone", "AirPods Pro"); empty until listening starts.
    public var inputName: String
    /// The input is a Bluetooth headset: call-quality audio, so the built-in microphone usually hears words better.
    public var isBluetoothHeadset: Bool
    /// The microphone sends only silence (exact zeros or under the noise floor): set after `MicrophoneSilence.warnAfter`
    /// (4 s) of listening with no signal, or when a recording of at least `MicrophoneSilence.reportAfter` (2 s) ended
    /// with no words and no signal. Cleared as soon as signal arrives.
    public var silentInput: Bool
    /// "Only my voice" is on for this dictation: a voiceprint was given, the engine is local and the speaker model was found.
    public var onlyMyVoice: Bool

    public init(inputName: String = "", isBluetoothHeadset: Bool = false, silentInput: Bool = false, onlyMyVoice: Bool = false) {
        self.inputName = inputName; self.isBluetoothHeadset = isBluetoothHeadset
        self.silentInput = silentInput; self.onlyMyVoice = onlyMyVoice
    }

    /// Mouthy's own wording for a silent input: "The microphone sent only silence (AirPods Pro). Check its input level
    /// in System Settings → Sound."
    public var silenceMessage: String { MicrophoneHealth.silenceMessage(input: inputName) }
}

/// The microphone checks Mouthy's dictation (`AppModel`) and host apps' `DictationSession` share.
enum MicrophoneHealth {
    static func silenceMessage(input: String) -> String {
        let microphone = input.isEmpty ? "the microphone" : input
        return "The microphone sent only silence (\(microphone)). Check its input level in System Settings → Sound."
    }
    /// Whether an input is a Bluetooth headset (call-quality audio).
    static func isBluetoothHeadset(_ device: InputDevice) -> Bool { AudioDevices.isBluetooth(device) }
}

public enum DictationError: Error, Sendable, Equatable {
    case microphoneDenied, modelNotInstalled, engine(String)
}

/// One push-to-talk dictation for a host app. Text is always returned to the host; this type never
/// pastes or types into another app. Nothing runs between sessions.
@MainActor public final class DictationSession: ObservableObject {
    public enum Phase: Equatable, Sendable { case idle, preparing, listening, transcribing, finished(String), failed(DictationError) }

    @Published public private(set) var phase: Phase = .idle
    /// Live words for Apple Speech and Parakeet previews; may stay empty until the end.
    @Published public private(set) var partialText = ""
    /// Microphone level 0…1 while listening, 0 otherwise.
    @Published public private(set) var level: Float = 0
    /// The microphone's name, whether it is a Bluetooth headset and whether it sends only silence. Changes only when one
    /// of those does (never per level), so observing it costs nothing while recording.
    @Published public private(set) var health = DictationHealth()
    public var configuration: DictationConfiguration

    private let speech: any DictationSpeech
    private var limit: Task<Void, Never>?
    private var teardown: Task<Void, Never>?
    private var pendingStop: Task<String?, Never>?
    private var silence = MicrophoneSilence()
    private var silenceWatch: Task<Void, Never>?
    // Seams for tests: the microphone permission, whether the engine's model is installed, Bluetooth detection, the
    // speaker model's presence and how long silence lasts before the live warning.
    var microphonePermission: () async -> Bool = { await MicrophonePermission.request() }
    var modelInstalled: (DictationConfiguration) -> Bool = { SpeechModels.isInstalled($0.engine, modelDirectory: $0.modelDirectory) }
    var isBluetoothInput: (InputDevice) -> Bool = MicrophoneHealth.isBluetoothHeadset
    var speakerModelInstalled: () -> Bool = { SpeakerEmbedder.bundledModel != nil }
    var silenceWarning: Duration = .seconds(MicrophoneSilence.warnAfter)

    public convenience init(configuration: DictationConfiguration = DictationConfiguration()) {
        self.init(configuration: configuration, speech: SpeechService())
    }

    init(configuration: DictationConfiguration, speech: any DictationSpeech) {
        self.configuration = configuration
        self.speech = speech
        speech.onPreview = { [weak self] text in Task { @MainActor in self?.partialText = text } }
        speech.onLevel = { [weak self] value in Task { @MainActor in self?.receiveLevel(value) } }
    }

    public var isRunning: Bool {
        switch phase { case .preparing, .listening, .transcribing: return true; default: return false }
    }

    public func start() async throws {
        guard !isRunning else { return }
        partialText = ""; phase = .preparing; update(DictationHealth())
        // A cancel or failure just before still tears the last session down; starting under it would lose this one.
        while let pending = teardown {
            await pending.value
            if teardown == pending { teardown = nil }
        }
        guard phase == .preparing else { return }
        guard await microphonePermission() else { return fail(.microphoneDenied) }
        ParakeetRecognizer.modelDirectory = configuration.modelDirectory
        guard modelInstalled(configuration) else { return fail(.modelNotInstalled) }
        // "Only my voice" runs in the local engines' voice filter (VoiceActivity.voiceOnly), which reads it per dictation.
        let onlyMyVoice = configuration.engine != .apple && configuration.voiceprint != nil && speakerModelInstalled()
        if configuration.engine != .apple { VoicePrint.active = configuration.voiceprint }
        do {
            try await speech.start(locale: configuration.locale, vocabulary: configuration.vocabulary, inputDeviceUID: "",
                                   provider: configuration.engine, whisperModel: .baseEnglish, whisperLanguage: "auto",
                                   translate: false, status: { _ in })
        } catch {
            return fail(.engine(error.localizedDescription))
        }
        guard phase == .preparing else { await speech.cancel(); return }
        phase = .listening
        silence.start(at: ProcessInfo.processInfo.systemUptime)
        update(DictationHealth(inputName: speech.inputDevice?.name ?? speech.inputDeviceName,
                               isBluetoothHeadset: speech.inputDevice.map(isBluetoothInput) ?? false, onlyMyVoice: onlyMyVoice))
        let maximum = configuration.maximumDuration, warning = silenceWarning
        limit = Task { [weak self] in
            do { try await Task.sleep(for: maximum) } catch { return }
            _ = await self?.stop()
        }
        silenceWatch = Task { [weak self] in
            do { try await Task.sleep(for: warning) } catch { return }
            guard let self, self.phase == .listening, !self.silence.heardSignal else { return }
            var health = self.health; health.silentInput = true; self.update(health)
        }
    }

    /// Stops recording and returns the finished text, or nil when nothing was said or the run failed.
    public func stop() async -> String? {
        if let pendingStop { return await pendingStop.value }
        guard phase == .listening else { return nil }
        limit?.cancel(); limit = nil
        silenceWatch?.cancel(); silenceWatch = nil
        phase = .transcribing; level = 0
        let cut = ProcessInfo.processInfo.systemUptime
        let task = Task<String?, Never> { [self] in
            do {
                let raw = try await speech.finish(cutAt: cut)
                // Cancelled while transcribing: the host asked for nothing.
                guard phase == .transcribing else { return nil }
                let text = Self.shape(raw, with: configuration)
                // No words and no signal for the whole recording: the microphone, not the person, was silent.
                if text.isEmpty, silence.isSilent(at: cut, after: MicrophoneSilence.reportAfter) {
                    var health = health; health.silentInput = true; update(health)
                }
                phase = text.isEmpty ? .idle : .finished(text)
                return text.isEmpty ? nil : text
            } catch {
                if phase == .transcribing { fail(.engine(error.localizedDescription)) }
                return nil
            }
        }
        pendingStop = task
        defer { pendingStop = nil }
        return await task.value
    }

    public func cancel() {
        limit?.cancel(); limit = nil
        silenceWatch?.cancel(); silenceWatch = nil
        guard isRunning else { return }
        phase = .idle; level = 0; partialText = ""
        teardown = Task { await speech.cancel() }
    }

    /// Mouthy's own cleanup (`DictationText.shape`) with its default settings.
    static func shape(_ raw: String, with configuration: DictationConfiguration) -> String {
        DictationText.shape(raw, code: configuration.textStyle == .code, replacements: configuration.replacements,
                            punctuation: true, removeFillers: true, vocabulary: configuration.vocabulary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func receiveLevel(_ value: Float) {
        guard phase == .listening else { level = 0; return }
        level = value
        silence.receive(level: value)
        if value > 0, health.silentInput { var health = health; health.silentInput = false; update(health) }
    }

    private func update(_ value: DictationHealth) {
        if health != value { health = value }
    }

    private func fail(_ error: DictationError) {
        limit?.cancel(); limit = nil
        silenceWatch?.cancel(); silenceWatch = nil
        level = 0; phase = .failed(error)
        teardown = Task { await speech.cancel() }
    }
}

public enum MicrophonePermission {
    public static var isGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    public static func request() async -> Bool { await SpeechService.permission() }
}

/// On-device speech models. Downloads happen only on an explicit call.
public enum SpeechModels {
    /// Parakeet needs its downloaded model; Apple Speech installs its own assets on first use.
    /// Whisper is configured inside Mouthy only.
    public static func isInstalled(_ engine: SpeechEngine, modelDirectory: URL? = nil) -> Bool {
        switch engine {
        case .parakeet: return ParakeetRecognizer.installed(at: modelDirectory)
        case .apple: return true
        case .whisper: return WhisperRecognizer.installed(.baseEnglish)
        }
    }

    /// Downloads into `modelDirectory` (nil: the shared cache). The folder must be writable.
    public static func downloadParakeet(modelDirectory: URL? = nil, progress: @escaping @Sendable (String) -> Void) async throws {
        ParakeetRecognizer.modelDirectory = modelDirectory
        try await ParakeetRecognizer.shared.prepare(download: true, progress: progress)
    }

    /// Transcribes an audio file with the configuration's engine, locale, vocabulary and model folder,
    /// then shapes the text as a dictation would. For hosts' end-to-end tests and file imports.
    @MainActor public static func transcribe(fileAt url: URL, configuration: DictationConfiguration) async throws -> String {
        ParakeetRecognizer.modelDirectory = configuration.modelDirectory
        guard isInstalled(configuration.engine, modelDirectory: configuration.modelDirectory) else { throw DictationError.modelNotInstalled }
        let raw = try await SpeechService().transcribeFile(url, locale: configuration.locale, vocabulary: configuration.vocabulary,
                                                           provider: configuration.engine, status: { _ in })
        return DictationSession.shape(raw, with: configuration)
    }

    /// Frees the loaded model's memory now instead of waiting for the idle release.
    public static func releaseMemory() async {
        await ParakeetRecognizer.shared.releaseIfIdle()
        await WhisperRecognizer.shared.releaseIfIdle()
    }
}

/// The text rules every dictation goes through before a style or delivery, in Mouthy and in host apps
/// (`DictationSession`): backtrack, replacements, spoken punctuation, fillers, custom-word names, then code
/// casing and symbols, or for prose clock times and a capital first word (a recognizer may write it lowercase;
/// code keeps its case: "git commit -m").
@MainActor enum DictationText {
    static func shape(_ raw: String, code: Bool, replacements: [Replacement], punctuation: Bool, removeFillers: Bool, vocabulary: String) -> String {
        if let snippet = TextPipeline.wholeReplacement(raw, replacements: replacements) { return snippet }
        var text = TextPipeline.process(raw, replacements: replacements, punctuation: punctuation)
        if removeFillers { text = Fillers.remove(text) }
        let terms = VocabularyLearner.terms(vocabulary)
        if !terms.isEmpty {
            let isKnownWord = { (word: String) in NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound }
            text = VocabularyGuard.names(VocabularyGuard.spacing(text, terms: terms, isKnownWord: isKnownWord), terms: terms, isKnownWord: isKnownWord)
        }
        return code ? CodeDictation.apply(text) : SmartInsertion.capitalizingFirstWord(ClockTimes.apply(text))
    }

    static func shape(_ raw: String, code: Bool, config: Preferences) -> String {
        shape(raw, code: code, replacements: config.replacements, punctuation: config.punctuationCommands,
              removeFillers: config.removeFillers, vocabulary: config.vocabulary)
    }
}
