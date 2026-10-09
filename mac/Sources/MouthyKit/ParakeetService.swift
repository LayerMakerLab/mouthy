import AVFoundation
import AppKit
import CoreML
import FluidAudio
import MouthyCore

/// Models stay on this Mac. Download is an explicit setup action; recording only loads cached models.
actor ParakeetRecognizer {
    static let shared = ParakeetRecognizer()
    private var manager: AsrManager?
    /// The same loaded model for dictation: long passes decode their chunks one at a time instead of four at
    /// once, so recognizing while recording never crowds out the audio device. Files keep the parallel manager.
    private var liveManager: AsrManager?
    /// Intel Macs: the same model through sherpa-onnx (see SherpaParakeet).
    private var sherpa: SherpaRecognizer?
    private var occupied = false
    private(set) var lastDocument = TranscriptionDocument(text: "")
    /// Vocabulary terms (one per line) boosted through FluidAudio's CTC keyword rescoring.
    private var vocabulary = ""
    private var boostedVocabulary: String?
    private var boosting: VocabularyBoostingSession?
    private static let directoryLock = NSLock()
    nonisolated(unsafe) private static var customDirectory: URL?
    /// Process-wide model folder. Nil means FluidAudio's shared cache; a host app may point at a read-only
    /// copy in its bundle so a fresh install works offline.
    static var modelDirectory: URL? {
        get { directoryLock.withLock { customDirectory } }
        set { directoryLock.withLock { customDirectory = newValue } }
    }
    static var modelFolder: URL { modelDirectory ?? AsrModels.defaultCacheDirectory(for: .v3) }
    static var installed: Bool { SherpaParakeet.preferred ? SherpaParakeet.installed : installed(at: modelDirectory) }
    static func installed(at directory: URL?) -> Bool {
        AsrModels.modelsExist(at: directory ?? AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }
    private var loadedFolder: URL?
    /// Apple silicon runs Parakeet on the Neural Engine (FluidAudio's default). Intel Macs have none, so they
    /// may use the GPU too. MOUTHY_COMPUTE_UNITS=cpu|gpu|all overrides it for benchmarks.
    static var configuration: MLModelConfiguration? {
        let override = ProcessInfo.processInfo.environment["MOUTHY_COMPUTE_UNITS"]
        guard let units: MLComputeUnits = switch override {
            case "cpu": .cpuOnly
            case "gpu": .cpuAndGPU
            case "all": .all
            default: nil
        } else { return nil }
        let config = AsrModels.defaultConfiguration()
        config.computeUnits = units
        return config
    }
    /// The small CTC model that spots vocabulary terms; downloaded together with Parakeet.
    static var boostingInstalled: Bool { CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m)) }
    func setVocabulary(_ text: String) { vocabulary = text }
    func prepare(download: Bool, progress: @escaping @Sendable (String) -> Void) async throws {
        // A launch warm-up may still be loading when the first dictation starts: wait for it instead of failing.
        while occupied { try await Task.sleep(for: .milliseconds(20)) }
        occupied = true; defer { occupied = false; scheduleRelease() }
        try await load(download: download, progress: progress)
    }
    private func load(download: Bool, progress: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        if SherpaParakeet.preferred {
            if sherpa != nil { return }
            if !SherpaParakeet.installed {
                guard download else { throw MouthyFailure("Download Parakeet in Settings before using it offline.") }
                try await SherpaParakeet.download(progress: progress)
            }
            progress("Loading Parakeet on this Mac…")
            sherpa = try SherpaRecognizer()
            return
        }
        if download && !Self.boostingInstalled {
            progress("Downloading Parakeet vocabulary model…")
            _ = try await CtcModels.download(variant: .ctc110m)
        }
        if manager != nil, loadedFolder == Self.modelFolder { return }
        manager = nil; liveManager = nil
        guard download || Self.installed else { throw MouthyFailure("Download Parakeet in Settings before using it offline.") }
        progress(download && !Self.installed ? "Downloading Parakeet to this Mac…" : "Loading Parakeet on this Mac…")
        let models: AsrModels
        if download {
            models = try await AsrModels.downloadAndLoad(to: Self.modelDirectory, version: .v3)
            await VoiceActivity.download()
        } else {
            models = try await AsrModels.load(from: Self.modelFolder, configuration: Self.configuration, version: .v3)
        }
        try Task.checkCancellation()
        let loaded = AsrManager()
        try await loaded.loadModels(models)
        try Task.checkCancellation()
        manager = loaded
        liveManager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1), models: models)
        loadedFolder = Self.modelFolder
        boostedVocabulary = nil
        boosting = nil
    }

    /// Boosts the person's vocabulary when the CTC model is on this Mac; without it, plain recognition.
    private func applyVocabulary() async {
        guard manager != nil, vocabulary != boostedVocabulary else { return }
        boostedVocabulary = vocabulary
        let words = VocabularyLearner.terms(vocabulary).filter { $0.count >= 3 }
        guard !words.isEmpty, Self.boostingInstalled else { boosting = nil; return }
        do {
            let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
            let models = try await CtcModels.load(from: directory, variant: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: directory)
            let terms = words.compactMap { word -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(word)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: word, ctcTokenIds: ids)
            }
            // minSimilarity 0.75 (was 0.5): measured on spoken product names, the looser value swapped ordinary
            // words for nearby terms ("model" -> "Codex"); 0.75 cut word errors from
            // 11.9% to 7.1% and got more names right (18/21 vs 17/21).
            let context = CustomVocabularyContext(terms: terms, alpha: 1.0, minCtcScore: -15, minSimilarity: 0.75, minCombinedConfidence: 0.45)
            boosting = try await VocabularyBoostingSession(vocabulary: context, ctcModels: models)
        } catch {
            boosting = nil
        }
    }
    /// `boost: false` skips the vocabulary pass (4-6x slower), for live previews that are replaced anyway.
    func transcribe(samples: [Float], boost: Bool = true) async throws -> String {
        guard !occupied else { throw MouthyFailure("Parakeet is already working. Please wait.") }
        occupied = true; defer { occupied = false; scheduleRelease() }
        try await load(download: false, progress: { _ in })
        lastDocument = TranscriptionDocument(text: "")
        // Avoid decoding digital silence. Audio remains in memory, never a temporary recording file.
        guard !samples.isEmpty, samples.contains(where: { abs($0) > 0.0001 }) else { return "" }
        if let sherpa {
            let text = sherpa.transcribe(samples)
            lastDocument = TranscriptionDocument(text: text)
            return text
        }
        guard let manager = liveManager ?? manager else { return "" }
        // Parakeet hears only the voice: alone, room noise, a cough or a click comes back as words ("Yeah.").
        let samples = await VoiceActivity.shared.voiceOnly(samples) ?? samples
        guard samples.contains(where: { abs($0) > 0.0001 }) else { return "" }   // also: no voice at all (empty)
        if boost { await applyVocabulary() }
        let result = try await recognize(samples, with: manager, boost: boost)
        try Task.checkCancellation()
        lastDocument = document(result)
        return result.text
    }
    /// Live dictation's context decode (LiveTranscriber.finish).
    static let decodeAfter: LiveTranscriber.DecodeAfter = { samples, from in try await shared.transcribe(samples: samples, wordsFrom: from) }
    /// Recognizes `samples` with the vocabulary pass but returns only the words that begin at or after sample
    /// `start`; the audio before it is context for them (see LiveTranscriber.finish).
    func transcribe(samples: [Float], wordsFrom start: Int) async throws -> String {
        let start = max(0, min(start, samples.count))
        guard start > 0 else { return try await transcribe(samples: samples) }
        guard !occupied else { throw MouthyFailure("Parakeet is already working. Please wait.") }
        occupied = true; defer { occupied = false; scheduleRelease() }
        try await load(download: false, progress: { _ in })
        lastDocument = TranscriptionDocument(text: "")
        // Parakeet hears only the voice (see transcribe(samples:boost:)); Intel's sherpa path has no voice detector.
        let samples = sherpa == nil ? await VoiceActivity.shared.voiceOnly(samples) ?? samples : samples
        guard samples.count > start else { return "" }   // no voice at all
        let tail = Array(samples[start...])
        guard tail.contains(where: { abs($0) > 0.0001 }) else { return "" }
        // Without token timings, recognize the new audio alone rather than lose any. With them, no word timed after the
        // context means none was said: noise recognized alone comes back as words ("yeah" from faint music).
        if let sherpa { return sherpa.transcribe(samples, wordsFrom: start) ?? sherpa.transcribe(tail) }
        guard let manager = liveManager ?? manager else { return "" }
        await applyVocabulary()
        var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.v3.decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        try Task.checkCancellation()
        let from = Double(start) / 16_000
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            var fresh = TdtDecoderState.make(decoderLayers: AsrModelVersion.v3.decoderLayers)
            return try await manager.transcribe(tail, decoderState: &fresh).text
        }
        // A word starts with a space or SentencePiece's word mark.
        guard let first = timings.firstIndex(where: { $0.startTime >= from && ($0.token.hasPrefix("▁") || $0.token.hasPrefix(" ")) }) else { return "" }
        let kept = Array(timings[first...])
        let text = kept.map(\.token).joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
        if let boosting, let rescored = await boosting.rescore(text: text, tokenTimings: kept, audioSamples: samples), rescored.wasModified {
            return rescored.text
        }
        return text
    }
    func transcribe(file: URL) async throws -> String {
        guard !occupied else { throw MouthyFailure("Parakeet is already working. Please wait.") }
        occupied = true; defer { occupied = false; scheduleRelease() }
        try await load(download: false, progress: { _ in })
        if let sherpa {
            let text = sherpa.transcribe(try AudioConverter().resampleAudioFile(file))
            lastDocument = TranscriptionDocument(text: text)
            return text
        }
        guard let manager else { throw MouthyFailure("Parakeet did not load.") }
        let audio = try AVAudioFile(forReading: file)
        guard Double(audio.length) / audio.processingFormat.sampleRate <= 600 else {
            throw MouthyFailure("For files longer than ten minutes, use Apple Speech or Whisper to keep memory bounded.")
        }
        await applyVocabulary()
        let result = try await recognize(try AudioConverter().resampleAudioFile(file), with: manager)
        try Task.checkCancellation()
        lastDocument = document(result)
        return result.text
    }
    /// One fresh decoder state per utterance, then CTC vocabulary rescoring when terms are boosted.
    private func recognize(_ samples: [Float], with manager: AsrManager, boost: Bool = true) async throws -> (text: String, timings: [TokenTiming]) {
        var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.v3.decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        let timings = result.tokenTimings ?? []
        guard boost, let boosting, let rescored = await boosting.rescore(text: result.text, tokenTimings: timings, audioSamples: samples),
              rescored.wasModified else { return (result.text, timings) }
        return (rescored.text, timings)
    }
    private func document(_ result: (text: String, timings: [TokenTiming])) -> TranscriptionDocument {
        var segments: [TimedSegment] = []
        let timings = result.timings
        for start in stride(from: 0, to: timings.count, by: 12) {
            let group = Array(timings[start..<min(start + 12, timings.count)])
            guard let first = group.first, let last = group.last else { continue }
            let text = group.map(\.token).joined().replacingOccurrences(of: "▁", with: " ")
            segments.append(TimedSegment(start: first.startTime, end: last.endTime, text: text))
        }
        return TranscriptionDocument(text: result.text, segments: segments)
    }
    func releaseIfIdle() async {
        guard !occupied else { return }
        let old = manager, oldLive = liveManager
        manager = nil; liveManager = nil; sherpa = nil; loadedFolder = nil
        // The vocabulary spotter (CTC 110M) goes with the model it boosts.
        boosting = nil; boostedVocabulary = nil
        // cleanup() also empties FluidAudio's process-wide array cache, which outlives the manager otherwise.
        await oldLive?.cleanup()
        await old?.cleanup()
    }
    /// True while a model (or the vocabulary spotter) is held in memory.
    var loaded: Bool { manager != nil || sherpa != nil || boosting != nil }
    func removeDownload() async throws {
        guard !occupied else { throw MouthyFailure("Wait for Parakeet to finish before removing its model.") }
        guard SherpaParakeet.preferred || Self.modelDirectory == nil else { throw MouthyFailure("This model is managed by the host app.") }
        await releaseIfIdle()
        if SherpaParakeet.preferred { try SherpaParakeet.remove(); return }
        boosting = nil; boostedVocabulary = nil
        for item in Self.downloadFolders where FileManager.default.fileExists(atPath: item.path) {
            try FileManager.default.trashItem(at: item, resultingItemURL: nil)
        }
    }
    /// Include the vocabulary model and the older cache layout in both disk size and removal.
    static var downloadFolders: [URL] {
        if let modelDirectory { return [modelDirectory] }
        let folder = AsrModels.defaultCacheDirectory(for: .v3)
        let name = folder.lastPathComponent
        let alternate = name.hasSuffix("-coreml") ? String(name.dropLast(7)) : name + "-coreml"
        let legacy = folder.deletingLastPathComponent().appendingPathComponent(alternate)
        return [folder, legacy, CtcModels.defaultCacheDirectory(for: .ctc110m)]
    }
    /// The model stays loaded so every dictation starts warm; it is released only when macOS is short of memory.
    private func scheduleRelease() { ModelMemory.watch() }

}

/// Releases idle speech models only when macOS is critically short of memory. A warning alone keeps them: macOS can
/// sit at warning for hours while another app holds most of the memory, and releasing there made every dictation load
/// the model first.
enum ModelMemory {
    nonisolated(unsafe) private static var source: DispatchSourceMemoryPressure?
    private static let lock = NSLock()
    static func watch() {
        lock.withLock {
            guard source == nil else { return }
            let created = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .global(qos: .utility))
            created.setEventHandler {
                Task {
                    await ParakeetRecognizer.shared.releaseIfIdle()
                    await WhisperRecognizer.shared.releaseIfIdle()
                    await VoiceActivity.shared.releaseIfIdle()
                }
            }
            created.resume()
            source = created
        }
    }
}

/// Bounded 16 kHz mono buffer owned by one capture session, with conversion protected from stop/cancel.
final class ParakeetAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var conversionBuffer: AVAudioPCMBuffer?
    private var samples: [Float] = []
    private var failure: String?
    private var accepting = true
    private var capturedUntil: TimeInterval?
    /// When the newest sample was captured (seconds since boot, like key event times), from the device's own clock.
    /// The stop cut uses it, so the audio still in flight when the person pressed stop is never counted as cut.
    var recordedUntil: TimeInterval? { lock.withLock { capturedUntil } }
    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard accepting, failure == nil else { return }
        if let time, time.isHostTimeValid, buffer.format.sampleRate > 0 {
            capturedUntil = AVAudioTime.seconds(forHostTime: time.hostTime) + Double(buffer.frameLength) / buffer.format.sampleRate
        }
        do {
            if buffer.format == format, converter == nil, let data = buffer.floatChannelData?[0] {
                try append(data, count: Int(buffer.frameLength))
                return
            }
            if converter == nil { converter = AVAudioConverter(from: buffer.format, to: format) }
            guard let converter else { throw MouthyFailure("Parakeet cannot convert this microphone format.") }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64)
            let output = try outputBuffer(capacity: capacity)
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true; inputStatus.pointee = .haveData; return buffer
            }
            if let error { throw error }
            guard status != .error, let data = output.floatChannelData?[0] else { throw MouthyFailure("Microphone conversion failed.") }
            try append(data, count: Int(output.frameLength))
        } catch { failure = error.localizedDescription }
    }
    /// Conversion finishes before this tap returns, so one output buffer can serve every callback.
    private func outputBuffer(capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        if conversionBuffer == nil || conversionBuffer!.frameCapacity < capacity {
            conversionBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        }
        guard let output = conversionBuffer else { throw MouthyFailure("Audio buffer allocation failed.") }
        output.frameLength = 0
        return output
    }
    private func append(_ data: UnsafePointer<Float>, count: Int) throws {
        guard samples.count + count <= 16_000 * 600 else { throw MouthyFailure("Parakeet recordings are limited to ten minutes.") }
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
    }
    /// Hands over the audio so far and keeps recording into an empty buffer (mid-dictation split).
    func take() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let taken = samples
        samples = []
        return taken
    }
    /// Samples recorded since the last split.
    var count: Int { lock.withLock { samples.count } }
    /// A copy of part of the audio so far, for finalizing phrases while recording continues.
    func slice(_ range: Range<Int>) -> [Float] {
        lock.withLock { Array(samples[range.clamped(to: 0..<samples.count)]) }
    }
    /// A copy of the audio so far, for live previews while recording continues.
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
    func finish() throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        defer { samples.removeAll(); converter = nil; conversionBuffer = nil }
        if let failure {
            // Keep the words recorded before it went wrong; only an empty recording reports the failure.
            Diagnostics.dictation.error("capture failed after \(self.samples.count, privacy: .public) samples: \(failure, privacy: .public)")
            guard !samples.isEmpty else { throw MouthyFailure(failure) }
            return samples
        }
        if let converter {
            // A resampler retains its filter tail. Drain it before decoding so final syllables survive.
            for _ in 0..<16 {
                let output = try outputBuffer(capacity: 2_048)
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    inputStatus.pointee = .endOfStream; return nil
                }
                if let error { throw error }
                if let data = output.floatChannelData?[0] {
                    samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
                }
                if status == .endOfStream || output.frameLength == 0 { break }
            }
        }
        return samples
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        accepting = false; samples.removeAll(); converter = nil; conversionBuffer = nil
    }
}

@MainActor
final class ParakeetService {
    private(set) var inputDeviceName = "Microphone"
    private var engine: AVAudioEngine?
    private var buffer: ParakeetAudioBuffer?
    private var routeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// Tests only: when set, `start` plays this audio file into the capture buffer in real time instead of opening the
    /// microphone, then sends silence (a quiet room) until stopped. Everything after capture runs as it does for the
    /// microphone, so a test can check speech to typed text without speakers or a room.
    nonisolated(unsafe) static var testInput: URL?
    private var feeder: Task<Void, Never>?
    var isActive: Bool { engine != nil || feeder != nil }
    /// `interrupted` reports that the microphone went away (route or display change) and capture has stopped; the
    /// audio recorded so far stays in the buffer for `finishSamples()`.
    func start(inputDeviceUID: String, level: @escaping (Float) -> Void, waveform: @escaping (MicrophoneFrame) -> Void = { _ in }, interrupted: @escaping (String) -> Void) throws {
        recordedUntil = nil
        if let file = Self.testInput { try feed(file, level: level, waveform: waveform); return }
        let engine = AVAudioEngine()
        let selectedInput = try AudioDevices.select(inputDeviceUID, engine: engine)
        inputDeviceName = selectedInput.name
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MouthyFailure("No working microphone was found.") }
        let buffer = ParakeetAudioBuffer()
        try AudioCompat.installTap(on: input, bufferSize: AVAudioFrameCount(format.sampleRate / 30), format: format) { pcm, time in
            buffer.receive(pcm, time: time)
            let stride = pcm.format.isInterleaved ? Int(pcm.format.channelCount) : 1
            let frame = pcm.floatChannelData.map { MicrophoneFrame.measure(UnsafeBufferPointer(start: $0[0], count: Int(pcm.frameLength) * stride), stride: stride) } ?? .silence
            Task { @MainActor in level(frame.level); waveform(frame) }
        }
        self.engine = engine; self.buffer = buffer
        do { engine.prepare(); try engine.start() }
        catch { cancel(); throw error }
        Diagnostics.dictation.notice("capture started: \(Int(format.sampleRate), privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, \(selectedInput.followsDefault ? "system input" : "chosen input", privacy: .public)")
        AudioDevices.restartIfStopped(engine, selected: selectedInput, format: format) { [weak self] in self?.engine === engine }
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.engine === engine else { return }
                let resumed = AudioDevices.resumeUnchangedInput(selectedInput, format: format, engine: engine)
                Diagnostics.dictation.notice("route change: \(resumed ? "same input, resumed" : "input changed", privacy: .public)")
                if !resumed { interrupted("The microphone changed, so recording stopped.") }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.engine === engine else { return }
                let resumed = AudioDevices.resumeUnchangedInput(selectedInput, format: format, engine: engine)
                Diagnostics.dictation.notice("screen change: \(resumed ? "input unchanged" : "input gone", privacy: .public)")
                if !resumed { interrupted("The microphone went away, so recording stopped.") }
            }
        }
    }
    private func feed(_ file: URL, level: @escaping (Float) -> Void, waveform: @escaping (MicrophoneFrame) -> Void) throws {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 30)
        let buffer = ParakeetAudioBuffer()
        self.buffer = buffer
        inputDeviceName = "Test input"
        feeder = Task { @MainActor in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) {
                if audio.framePosition < audio.length { try? audio.read(into: pcm, frameCount: chunk) }
                let read = Int(pcm.frameLength)
                pcm.frameLength = chunk
                for channel in 0..<Int(format.channelCount) { for i in read..<Int(chunk) { pcm.floatChannelData![channel][i] = 0 } }
                buffer.receive(pcm, time: AVAudioTime(hostTime: mach_absolute_time()))
                let frame = MicrophoneFrame.measure(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(chunk)), stride: 1)
                level(frame.level); waveform(frame)
                next += .seconds(Double(chunk) / format.sampleRate)
                try? await Task.sleep(until: next, clock: clock)
            }
        }
        Diagnostics.dictation.notice("capture started: test input")
    }
    private func stopAudio() {
        feeder?.cancel(); feeder = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver); self.routeObserver = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
    }
    func currentSamples() -> [Float] { buffer?.snapshot() ?? [] }
    var sampleCount: Int { buffer?.count ?? 0 }
    func samples(_ range: Range<Int>) -> [Float] { buffer?.slice(range) ?? [] }
    func takeSamples() -> [Float] { buffer?.take() ?? [] }
    /// When the last sample `finishSamples()` returned was captured (seconds since boot); nil without device times.
    private(set) var recordedUntil: TimeInterval?
    /// Keeps capturing until the device has delivered the audio recorded up to `moment` (seconds since boot), at most
    /// `limit`: a word finished right at the stop shortcut is still on its way (71-162 ms on an M5).
    func awaitCapture(through moment: TimeInterval, limit: Duration = .milliseconds(250)) async -> Duration {
        let started = ContinuousClock.now
        while let until = buffer?.recordedUntil, until < moment, started.duration(to: .now) < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return started.duration(to: .now)
    }
    func finishSamples() throws -> [Float] {
        stopAudio()
        defer { buffer = nil }
        recordedUntil = buffer?.recordedUntil
        let samples = try buffer?.finish() ?? []
        Diagnostics.dictation.notice("capture stopped: \(samples.count, privacy: .public) samples")
        return samples
    }
    func finish() async throws -> String {
        try await ParakeetRecognizer.shared.transcribe(samples: finishSamples())
    }
    func cancel() { stopAudio(); buffer?.cancel(); buffer = nil }
}
