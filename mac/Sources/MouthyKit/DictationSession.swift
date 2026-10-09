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

    public init(engine: SpeechEngine = .parakeet, locale: String = "en-US", vocabulary: String = "",
                replacements: [Replacement] = [], textStyle: DictationTextStyle = .prose,
                maximumDuration: Duration = .seconds(60), modelDirectory: URL? = nil) {
        self.engine = engine; self.locale = locale; self.vocabulary = vocabulary
        self.replacements = replacements; self.textStyle = textStyle; self.maximumDuration = maximumDuration
        self.modelDirectory = modelDirectory
    }
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
    public var configuration: DictationConfiguration

    private let speech = SpeechService()
    private var limit: Task<Void, Never>?
    private var pendingStop: Task<String?, Never>?

    public init(configuration: DictationConfiguration = DictationConfiguration()) {
        self.configuration = configuration
        speech.onPreview = { [weak self] text in Task { @MainActor in self?.partialText = text } }
        speech.onLevel = { [weak self] value in Task { @MainActor in self?.level = value } }
    }

    public var isRunning: Bool {
        switch phase { case .preparing, .listening, .transcribing: return true; default: return false }
    }

    public func start() async throws {
        guard !isRunning else { return }
        partialText = ""; phase = .preparing
        guard await MicrophonePermission.request() else { return fail(.microphoneDenied) }
        ParakeetRecognizer.modelDirectory = configuration.modelDirectory
        guard SpeechModels.isInstalled(configuration.engine, modelDirectory: configuration.modelDirectory) else { return fail(.modelNotInstalled) }
        do {
            try await speech.start(locale: configuration.locale, vocabulary: configuration.vocabulary,
                                   provider: configuration.engine, status: { _ in })
        } catch {
            return fail(.engine(error.localizedDescription))
        }
        guard phase == .preparing else { await speech.cancel(); return }
        phase = .listening
        let maximum = configuration.maximumDuration
        limit = Task { [weak self] in
            do { try await Task.sleep(for: maximum) } catch { return }
            _ = await self?.stop()
        }
    }

    /// Stops recording and returns the finished text, or nil when nothing was said or the run failed.
    public func stop() async -> String? {
        if let pendingStop { return await pendingStop.value }
        guard phase == .listening else { return nil }
        limit?.cancel(); limit = nil
        phase = .transcribing; level = 0
        let cut = ProcessInfo.processInfo.systemUptime
        let task = Task<String?, Never> { [self] in
            do {
                let raw = try await speech.finish(cutAt: cut)
                let text = Self.shape(raw, with: configuration)
                phase = text.isEmpty ? .idle : .finished(text)
                return text.isEmpty ? nil : text
            } catch {
                fail(.engine(error.localizedDescription)); return nil
            }
        }
        pendingStop = task
        defer { pendingStop = nil }
        return await task.value
    }

    public func cancel() {
        limit?.cancel(); limit = nil
        guard isRunning else { return }
        phase = .idle; level = 0; partialText = ""
        Task { await speech.cancel() }
    }

    /// The same cleanup Mouthy applies before delivery: backtrack, replacements, spoken punctuation,
    /// and for `.code` spoken casing and symbols.
    nonisolated static func shape(_ raw: String, with configuration: DictationConfiguration) -> String {
        var text = TextPipeline.process(raw, replacements: configuration.replacements, punctuation: true)
        if configuration.textStyle == .code { text = CodeDictation.apply(text) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fail(_ error: DictationError) {
        limit?.cancel(); limit = nil
        level = 0; phase = .failed(error)
        Task { await speech.cancel() }
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
