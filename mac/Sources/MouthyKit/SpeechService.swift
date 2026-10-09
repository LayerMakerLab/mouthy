import AVFoundation
import AppKit
import Speech
import MouthyCore

struct MouthyFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

// Used only by the audio tap; no audio buffers or transcripts are written to disk.
final class AudioFeed: @unchecked Sendable {
    let converter: AnalyzerFeedConverter
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    var framesSinceMeter: AVAudioFrameCount = 0
    let meter: @Sendable (Float) -> Void
    let waveform: @Sendable (MicrophoneFrame) -> Void
    let failure: @Sendable (String) -> Void
    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         meter: @escaping @Sendable (Float) -> Void, waveform: @escaping @Sendable (MicrophoneFrame) -> Void = { _ in }, failure: @escaping @Sendable (String) -> Void) {
        if #available(macOS 27.0, *) { converter = ModernAnalyzerConverter(format: format) }
        else { converter = LegacyAnalyzerConverter(format: format) }
        self.continuation = continuation; self.meter = meter; self.failure = failure
        self.waveform = waveform
    }
    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        do {
            for input in try converter.convert(buffer, at: time) {
                if case .dropped = continuation.yield(input) { failure("Audio could not be processed fast enough. Please try again.") }
            }
            framesSinceMeter += buffer.frameLength
            if framesSinceMeter >= AVAudioFrameCount(buffer.format.sampleRate / 30), let data = buffer.floatChannelData?[0] {
                framesSinceMeter = 0
                let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
                let frame = MicrophoneFrame.measure(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength) * stride), stride: stride)
                meter(frame.level); waveform(frame)
            }
        } catch { failure(error.localizedDescription) }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        do { for input in try converter.flush() { continuation.yield(input) } }
        catch { failure(error.localizedDescription) }
    }
}

@MainActor
final class SpeechService {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Error>?
    private var accumulator = TranscriptAccumulator()
    private var sessionID = UUID()
    private let parakeet = ParakeetService()
    private var provider: SpeechEngine = .apple
    private var whisperModel: WhisperModel = .baseEnglish
    private var whisperLanguage = "auto"
    private var translate = false
    private var vocabulary = ""
    private var warmup: Task<Void, Error>?
    private var live: LiveTranscriber?
    private var liveTicker: Task<Void, Never>?
    private(set) var document = TranscriptionDocument(text: "")
    private(set) var inputDeviceName = "Microphone"
    var isActive: Bool { analyzer != nil || parakeet.isActive }
    private var tapInstalled = false
    private var audioFeed: AudioFeed?
    private var routeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    var onPreview: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onWaveform: ((MicrophoneFrame) -> Void)?
    var onFailure: ((String) -> Void)?
    /// The microphone went away mid-recording (route or display change). Capture has stopped; what was recorded
    /// is still here for `finish`.
    var onInterruption: ((String) -> Void)?

    static func permission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// The same question, but never waits longer than `timeout`: macOS can leave a request unanswered (no dialog shown,
    /// for example after the app's permission was reset while it ran). nil means macOS gave no answer in time.
    static func permission(timeout: Duration) async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let once = ResumeOnce(continuation)
            Task { once.resume(await permission()) }
            Task { try? await Task.sleep(for: timeout); once.resume(nil) }
        }
    }

    static func transcriber(locale: String, install: Bool, status: @escaping (String) -> Void) async throws -> SpeechTranscriber {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable else { throw MouthyFailure("Apple speech recognition is unavailable on this Mac.") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw MouthyFailure("Apple Speech does not support this language. Choose another in Settings.")
        }
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        if assetStatus != .installed {
            // macOS may report .supported until cached shared assets are attached to
            // this process. A nil request means no download is needed.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                guard install else { throw MouthyFailure("Install the Apple speech assets in Settings first.") }
                status("Installing Apple speech assets…")
                try await withTaskCancellationHandler {
                    try await request.downloadAndInstall()
                } onCancel: { request.progress.cancel() }
            }
        }
        try Task.checkCancellation()
        return transcriber
    }

    private func configure(_ transcriber: SpeechTranscriber, vocabulary: String) async throws -> SpeechAnalyzer {
        try Task.checkCancellation()
        sessionID = UUID()
        accumulator = TranscriptAccumulator()
        document = TranscriptionDocument(text: "")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = VocabularyLearner.terms(vocabulary)
        try await analyzer.setContext(context)
        try Task.checkCancellation()
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    self?.accumulator.accept(String(result.text.characters), isFinal: result.isFinal)
                    if result.isFinal {
                        self?.document.segments.append(TimedSegment(start: result.range.start.seconds, end: result.range.end.seconds, text: String(result.text.characters)))
                    }
                    if let self { self.onPreview?(self.accumulator.preview) }
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { self?.onFailure?(error.localizedDescription) }
                throw error
            }
        }
        return analyzer
    }

    func start(locale: String, vocabulary: String, inputDeviceUID: String = "", provider: SpeechEngine = .apple, whisperModel: WhisperModel = .baseEnglish, whisperLanguage: String = "auto", translate: Bool = false, status: @escaping (String) -> Void) async throws {
        try Task.checkCancellation()
        guard await Self.permission(timeout: .seconds(10)) == true else { throw MouthyFailure("Microphone access is off. Enable Mouthy in System Settings → Privacy & Security → Microphone.") }
        try Task.checkCancellation()
        self.provider = provider
        self.whisperModel = whisperModel; self.whisperLanguage = whisperLanguage; self.translate = translate; self.vocabulary = vocabulary
        document = TranscriptionDocument(text: "")
        if provider != .apple {
            guard provider == .parakeet ? ParakeetRecognizer.installed : WhisperRecognizer.installed(whisperModel) else {
                throw MouthyFailure("Download the selected model in Settings first.")
            }
            // Capture immediately. Model warm-up happens alongside speaking, not before it.
            warmup = Task {
                if provider == .parakeet {
                    await WhisperRecognizer.shared.releaseIfIdle()
                    await ParakeetRecognizer.shared.setVocabulary(vocabulary)
                    try await ParakeetRecognizer.shared.prepare(download: false, progress: { _ in })
                    await VoiceActivity.shared.prepare()
                } else {
                    await ParakeetRecognizer.shared.releaseIfIdle()
                    try await WhisperRecognizer.shared.prepare(model: whisperModel, download: false, progress: { _ in })
                    await VoiceActivity.shared.prepare()
                }
            }
            sessionID = UUID(); let token = sessionID
            try parakeet.start(inputDeviceUID: inputDeviceUID, level: { [weak self] value in
                guard self?.sessionID == token else { return }; self?.onLevel?(value)
            }, waveform: { [weak self] frame in
                guard self?.sessionID == token else { return }; self?.onWaveform?(frame)
            }, interrupted: { [weak self] message in
                guard self?.sessionID == token else { return }; self?.onInterruption?(message)
            })
            inputDeviceName = parakeet.inputDeviceName
            startLive(token: token)
            return
        }
        await ParakeetRecognizer.shared.releaseIfIdle()
        await WhisperRecognizer.shared.releaseIfIdle()
        let transcriber = try await Self.transcriber(locale: locale, install: false, status: status)
        try Task.checkCancellation()
        let analyzer = try await configure(transcriber, vocabulary: vocabulary)
        let engine = AVAudioEngine()
        self.engine = engine
        let selectedInput = try AudioDevices.select(inputDeviceUID, engine: engine)
        inputDeviceName = selectedInput.name
        let input = engine.inputNode
        // The output scope may still reflect the playback device (for example,
        // a 44.1 kHz Bluetooth speaker). A recording tap must match input hardware.
        let naturalFormat = input.inputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else { throw MouthyFailure("No working microphone was found.") }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: naturalFormat) else {
            throw MouthyFailure("No compatible microphone format is available.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(512))
        self.continuation = continuation
        try await analyzer.start(inputSequence: stream)
        // Cancelled while the analyzer was starting: do not start a microphone nobody will stop.
        try Task.checkCancellation()
        let currentSession = sessionID
        let feed = AudioFeed(format: format, continuation: continuation, meter: { [weak self] level in
            Task { @MainActor in guard self?.sessionID == currentSession else { return }; self?.onLevel?(level) }
        }, waveform: { [weak self] frame in
            Task { @MainActor in guard self?.sessionID == currentSession else { return }; self?.onWaveform?(frame) }
        }, failure: { [weak self] message in
            Task { @MainActor in guard self?.sessionID == currentSession else { return }; self?.onFailure?(message) }
        })
        audioFeed = feed
        try AudioCompat.installTap(on: input, bufferSize: AVAudioFrameCount(naturalFormat.sampleRate / 30), format: naturalFormat) { buffer, time in
            feed.receive(buffer, time: time)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        Diagnostics.dictation.notice("capture started (Apple): \(Int(naturalFormat.sampleRate), privacy: .public) Hz, \(naturalFormat.channelCount, privacy: .public) ch, \(selectedInput.followsDefault ? "system input" : "chosen input", privacy: .public)")
        AudioDevices.restartIfStopped(engine, selected: selectedInput, format: naturalFormat) { [weak self] in self?.engine === engine && self?.sessionID == currentSession }
        // A changed microphone stops capture; what the analyzer already heard is finished and delivered.
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.sessionID == currentSession, self?.engine === engine else { return }
                let resumed = AudioDevices.resumeUnchangedInput(selectedInput, format: naturalFormat, engine: engine)
                Diagnostics.dictation.notice("route change: \(resumed ? "same input, resumed" : "input changed", privacy: .public)")
                if !resumed { self?.onInterruption?("The microphone changed, so recording stopped.") }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.sessionID == currentSession, self?.engine === engine else { return }
                let resumed = AudioDevices.resumeUnchangedInput(selectedInput, format: naturalFormat, engine: engine)
                Diagnostics.dictation.notice("screen change: \(resumed ? "input unchanged" : "input gone", privacy: .public)")
                if !resumed { self?.onInterruption?("The microphone went away, so recording stopped.") }
            }
        }
    }

    private func stopAudio(flush: Bool = true) {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver); self.routeObserver = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if flush { audioFeed?.finish() }; audioFeed = nil
        engine = nil
        continuation?.finish(); continuation = nil
        onLevel?(0)
        onWaveform?(.silence)
    }


    /// Mid-dictation split: returns what was said since the last split and keeps the session running.
    func split() async throws -> String {
        if provider != .apple {
            await stopLiveTicker()
            defer { startLiveTicker(token: sessionID) }
            let samples = parakeet.takeSamples()
            // The preview showed the audio just taken; clear it so finishing never mistakes sent words for unsent ones.
            onPreview?("")
            try await warmup?.value
            return try await live?.split(samples) ?? ""
        }
        guard let analyzer else { return "" }
        // Finalize what has been heard so far without ending the input.
        try await analyzer.finalize(through: nil)
        for _ in 0..<20 where !accumulator.partial.isEmpty { try await Task.sleep(for: .milliseconds(15)) }
        let text = accumulator.takeFinalized()
        onPreview?(accumulator.preview)
        return text
    }

    /// Local engines finalize each phrase as the person pauses (see LiveTranscriber), so finishing only
    /// recognizes what was said after the last pause.
    private func startLive(token: UUID) {
        let provider = provider, model = whisperModel, language = whisperLanguage, translate = translate, vocabulary = vocabulary
        let live = LiveTranscriber(decode: { samples, boost in
            if provider == .parakeet { return try await ParakeetRecognizer.shared.transcribe(samples: samples, boost: boost) }
            let samples = await VoiceActivity.shared.voiceOnly(samples) ?? samples   // Whisper too hears only the voice
            guard !samples.isEmpty else { return "" }
            return try await WhisperRecognizer.shared.transcribe(samples: samples, model: model, language: language, translate: translate,
                                                                  vocabulary: boost ? vocabulary : "").text
        }, decodeAfter: provider == .parakeet ? ParakeetRecognizer.decodeAfter : nil, hearsSpeech: VoiceActivity.hearsSpeech, count: { [weak self] in self?.parakeet.sampleCount ?? 0 }, read: { [weak self] in self?.parakeet.samples($0) ?? [] })
        live.onText = { [weak self] text in
            guard let self, self.sessionID == token else { return }
            self.onPreview?(text)
        }
        self.live = live
        startLiveTicker(token: token)
    }

    private func startLiveTicker(token: UUID) {
        liveTicker?.cancel()
        liveTicker = Task { [weak self] in
            // The recognizer takes one request at a time; let the warm-up finish first.
            try? await self?.warmup?.value
            while !Task.isCancelled {
                guard let self, self.sessionID == token else { return }
                self.live?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopLiveTicker() async {
        let running = liveTicker
        liveTicker = nil
        running?.cancel()
        await running?.value
    }

    /// `cutAt` (seconds since boot) is when the person asked to stop. Audio recorded after it is the stop
    /// shortcut's key clicks or music resuming, never their words, so it is dropped before recognition.
    func finish(cutAt: TimeInterval? = nil) async throws -> String {
        if provider != .apple {
            await stopLiveTicker()
            // A word running into the stop: wait for the audio still in flight from the device before stopping it.
            if let cutAt, live?.soundsAtEnd() == true {
                let waited = await parakeet.awaitCapture(through: cutAt)
                Diagnostics.dictation.notice("finish: waited \(LiveTranscriber.milliseconds(waited), privacy: .public) ms for audio in flight")
            }
            onLevel?(0); onWaveform?(.silence)
            var samples = try parakeet.finishSamples()
            let recorded = samples.count
            // Cut by the device's capture time of the last sample, not the time now: audio still in flight at the stop
            // was recorded before it, so a word right before the shortcut keeps its end (LiveBenchmark cuts the same way).
            let now = ProcessInfo.processInfo.systemUptime
            let until = parakeet.recordedUntil.flatMap { $0 <= now && now - $0 < 1 ? $0 : nil } ?? now
            if let cutAt { samples = Self.trim(samples, recordedUntil: until, cutAt: cutAt) }
            Diagnostics.dictation.notice("finish: \(samples.count, privacy: .public) samples, \(recorded - samples.count, privacy: .public) cut at the stop shortcut, last sample \(Int((ProcessInfo.processInfo.systemUptime - until) * 1000), privacy: .public) ms before now")
            try await warmup?.value; warmup = nil
            let text = try await live?.finish(samples) ?? ""
            live = nil
            document = TranscriptionDocument(text: text)
            return text
        }
        stopAudio()
        Diagnostics.dictation.notice("capture stopped (Apple)")
        guard let analyzer else { return "" }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try Task.checkCancellation()
        try await resultsTask?.value
        try Task.checkCancellation()
        let text = accumulator.finalText
        document.text = text
        self.analyzer = nil; resultsTask = nil
        return text
    }

    /// Drops the audio recorded after `cutAt`, at most 2 s (a stuck clock must never eat a dictation).
    nonisolated static func trim(_ samples: [Float], recordedUntil end: TimeInterval, cutAt: TimeInterval, rate: Int = 16_000) -> [Float] {
        let extra = min(2, max(0, end - cutAt))
        let drop = min(samples.count, Int(extra * Double(rate)))
        return drop == 0 ? samples : Array(samples.dropLast(drop))
    }

    func cancel() async {
        sessionID = UUID()
        // Wait for in-flight decodes so the recognizer is free for the next dictation.
        await stopLiveTicker()
        await live?.drain(); live = nil
        parakeet.cancel()
        warmup?.cancel(); _ = try? await warmup?.value; warmup = nil
        stopAudio(flush: false)
        let task = resultsTask
        task?.cancel()
        await analyzer?.cancelAndFinishNow()
        _ = try? await task?.value
        analyzer = nil; resultsTask = nil
    }

    func transcribeFile(_ url: URL, locale: String, vocabulary: String, provider: SpeechEngine = .apple, whisperModel: WhisperModel = .baseEnglish, whisperLanguage: String = "auto", translate: Bool = false, status: @escaping (String) -> Void) async throws -> String {
        self.provider = provider
        document = TranscriptionDocument(text: "")
        guard try await MediaInput.containsSignal(url) else { return "" }
        if provider == .parakeet {
            await WhisperRecognizer.shared.releaseIfIdle()
            await ParakeetRecognizer.shared.setVocabulary(vocabulary)
            status("Transcribing with Parakeet on this Mac…")
            let text = try await ParakeetRecognizer.shared.transcribe(file: url)
            document = await ParakeetRecognizer.shared.lastDocument
            return text
        }
        if provider == .whisper {
            await ParakeetRecognizer.shared.releaseIfIdle()
            status("Transcribing with Whisper on this Mac…")
            document = try await WhisperRecognizer.shared.transcribe(file: url, model: whisperModel, language: whisperLanguage, translate: translate, vocabulary: vocabulary)
            return document.text
        }
        await ParakeetRecognizer.shared.releaseIfIdle()
        await WhisperRecognizer.shared.releaseIfIdle()
        try Task.checkCancellation()
        let transcriber = try await Self.transcriber(locale: locale, install: false, status: status)
        let analyzer = try await configure(transcriber, vocabulary: vocabulary)
        let file = try AVAudioFile(forReading: url)
        try Task.checkCancellation()
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try Task.checkCancellation()
        try await resultsTask?.value
        try Task.checkCancellation()
        let text = accumulator.finalText
        document.text = text; document.language = locale
        self.analyzer = nil; resultsTask = nil
        return text
    }
}

/// Keeps only the selected engine's model warm, so the next dictation starts with zero wait, and releases every
/// other local model. Apple Speech runs in a system service, so choosing it releases both local models.
extension SpeechModels {
    static func keepOnly(_ engine: SpeechEngine, whisperModel: WhisperModel, vocabulary: String) async {
        await SpeechModelWarmup.shared.select(engine, whisperModel: whisperModel, vocabulary: vocabulary)
    }
}

/// A setting can change while Core ML is loading. Finish that load, then apply the newest selection;
/// releaseIfIdle alone cannot release a model whose load is still in flight. Intermediate selections coalesce.
private actor SpeechModelWarmup {
    static let shared = SpeechModelWarmup()
    private typealias Selection = (engine: SpeechEngine, whisperModel: WhisperModel, vocabulary: String)
    private var pending: Selection?
    private var worker: Task<Void, Never>?

    func select(_ engine: SpeechEngine, whisperModel: WhisperModel, vocabulary: String) async {
        pending = (engine, whisperModel, vocabulary)
        let operation: Task<Void, Never>
        if let worker { operation = worker }
        else {
            operation = Task { await self.drain() }
            worker = operation
        }
        await operation.value
    }

    private func drain() async {
        while let selection = pending {
            pending = nil
            await apply(selection)
        }
        worker = nil
    }

    private func apply(_ selection: Selection) async {
        switch selection.engine {
        case .parakeet:
            await WhisperRecognizer.shared.releaseIfIdle()
            guard ParakeetRecognizer.installed else { return }
            await ParakeetRecognizer.shared.setVocabulary(selection.vocabulary)
            try? await ParakeetRecognizer.shared.prepare(download: false) { _ in }
        case .whisper:
            await ParakeetRecognizer.shared.releaseIfIdle()
            guard WhisperRecognizer.installed(selection.whisperModel) else { return }
            try? await WhisperRecognizer.shared.prepare(model: selection.whisperModel, download: false) { _ in }
        case .apple:
            await ParakeetRecognizer.shared.releaseIfIdle()
            await WhisperRecognizer.shared.releaseIfIdle()
            await VoiceActivity.shared.releaseIfIdle()
        }
    }
}

/// Resumes a continuation exactly once, whichever answer comes first.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func resume(_ value: T) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}
