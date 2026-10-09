import CryptoKit
import Foundation
import WhisperKit
import ArgmaxCore
import MouthyCore

private final class DownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var percent = -1
    func changed(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value != percent else { return false }; percent = value; return true
    }
}

actor WhisperRecognizer {
    static let shared = WhisperRecognizer()
    static let cache = LocalStore.supportDirectory.appendingPathComponent("Models/Whisper", isDirectory: true)
    /// Tokenizer files by Hugging Face revision, with their SHA-256 (checked 2026-10-04).
    static let tokenizers: [WhisperModel: (repo: String, revision: String, files: [(String, String)])] = {
        let multilingual = [("tokenizer.json", "27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566"),
                            ("tokenizer_config.json", "2a4c4281cf9f51ac6ccc406fdc711a087afe6530f671fa7b80953edc498275ce")]
        return [
            .baseEnglish: ("whisper-base.en", "911407f4214e0e1d82085af863093ec0b66f9cd6",
                           [("tokenizer.json", "5eb60cec1e77aeeb6869a2bb5a8e01a84c3fe5d072d75369343021fe6f5310d0"),
                            ("tokenizer_config.json", "14f84bdf4b9ecdbd4738ddc81c17a1baedfc02bb93c6e049c951e15a1b40b70d")]),
            .small: ("whisper-small", "973afd24965f72e36ca33b3055d56a652f456b4d", multilingual),
            .medium: ("whisper-medium", "abdf7c39ab9d0397620ccaea8974cc764cd0953e", multilingual),
            .turbo: ("whisper-large-v3", "06f233fe06e710322aca913c1bc4249a0d71fce1",
                     [("tokenizer.json", "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
                      ("tokenizer_config.json", "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389")]),
        ]
    }()
    private var pipeline: WhisperKit?
    private var selected: WhisperModel?
    private var occupied = false

    static func folder(_ model: WhisperModel) -> URL {
        cache.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.rawValue)")
    }
    static func installed(_ model: WhisperModel) -> Bool {
        guard supported else { return false }
        let folder = folder(model)
        return ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "tokenizer.json", "tokenizer_config.json"]
            .allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
    /// WhisperKit needs Apple silicon (it crashes in Float16 tensor setup on Intel).
    static var supported: Bool {
        #if arch(x86_64)
        return false
        #else
        return true
        #endif
    }
    func prepare(model: WhisperModel, download: Bool, progress: @escaping @Sendable (String) -> Void) async throws {
        guard Self.supported else { throw MouthyFailure("Whisper needs a Mac with Apple silicon. Use NVIDIA Parakeet on this Mac.") }
        // A launch warm-up may still be loading when the first dictation starts: wait for it instead of failing.
        while occupied { try await Task.sleep(for: .milliseconds(20)) }
        occupied = true
        defer { occupied = false; scheduleRelease() }
        try await load(model: model, download: download, progress: progress)
    }
    private func load(model: WhisperModel, download: Bool, progress: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        if pipeline != nil, selected == model { return }
        let old = pipeline; pipeline = nil; selected = nil
        await old?.unloadModels()
        let folder = Self.folder(model)
        if !Self.installed(model) {
            guard download else { throw MouthyFailure("Download the selected Whisper model in Settings before using it offline.") }
            progress("Downloading Whisper to this Mac…")
            let reported = DownloadProgress()
            _ = try await WhisperKit.download(variant: model.rawValue, downloadBase: Self.cache) { value in
                let percent = Int(value.fractionCompleted * 100)
                if reported.changed(percent) { progress("Downloading Whisper · \(percent)%") }
            }
            // Keep tokenizer assets in the model folder so runtime loading stays local.
            // Pinned revisions and SHA-256 hashes, so a changed upstream file is refused.
            let tokenizer = Self.tokenizers[model]!
            for (name, hash) in tokenizer.files where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                let url = URL(string: "https://huggingface.co/openai/\(tokenizer.repo)/resolve/\(tokenizer.revision)/\(name)")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MouthyFailure("Whisper tokenizer download failed.") }
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
                    throw MouthyFailure("The Whisper tokenizer download did not match its expected checksum.")
                }
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
        }
        guard Self.installed(model) else { throw MouthyFailure("Whisper setup is incomplete. Download the model again in Settings.") }
        // Validate locally before the SDK's tokenizer loader can attempt a network fallback.
        _ = try await AutoTokenizerWrapper.from(modelFolder: folder)
        try Task.checkCancellation()
        progress("Loading Whisper on this Mac…")
        // Intel Macs: Metal Performance Shaders cannot run Whisper's padded tensors; use the CPU.
        #if arch(x86_64)
        let compute: ModelComputeOptions? = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly)
        #else
        let compute: ModelComputeOptions? = nil
        #endif
        let config = WhisperKitConfig(model: model.rawValue, downloadBase: Self.cache, modelFolder: folder.path,
                                      tokenizerFolder: folder, computeOptions: compute, verbose: false, logLevel: .none, prewarm: false, load: true, download: false)
        let loaded = try await WhisperKit(config)
        try Task.checkCancellation()
        pipeline = loaded; selected = model
    }
    private func options(_ pipeline: WhisperKit, model: WhisperModel, language: String, translate: Bool, vocabulary: String) -> DecodingOptions {
        let language = model == .baseEnglish ? "en" : language == "auto" ? nil : language
        let prompt = vocabulary.isEmpty ? nil : pipeline.tokenizer?.encode(text: String(vocabulary.prefix(1500)))
        return DecodingOptions(verbose: false, task: translate && model.supportsTranslation ? .translate : .transcribe,
                               language: language, temperatureFallbackCount: 0, detectLanguage: language == nil,
                               skipSpecialTokens: true, withoutTimestamps: false, promptTokens: prompt,
                               concurrentWorkerCount: 1, chunkingStrategy: .vad)
    }
    private func checkedLanguage(_ value: String, model: WhisperModel) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let language = Constants.languages[value] ?? value.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "auto"
        guard language == "auto" || Constants.languageCodes.contains(language) else { throw MouthyFailure("Whisper does not support that language code. Use auto or a supported code such as en, es, or fr.") }
        guard model != .baseEnglish || ["auto", "en"].contains(language) else { throw MouthyFailure("Base English only recognizes English. Choose Small, Medium or Turbo for other languages.") }
        return language
    }
    private func document(_ results: [TranscriptionResult]) -> TranscriptionDocument {
        TranscriptionDocument(text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                              language: results.first?.language,
                              segments: results.flatMap(\.segments).map { TimedSegment(start: Double($0.start), end: Double($0.end), text: $0.text) })
    }
    func transcribe(samples: [Float], model: WhisperModel, language: String, translate: Bool, vocabulary: String) async throws -> TranscriptionDocument {
        guard Self.supported else { throw MouthyFailure("Whisper needs a Mac with Apple silicon. Use NVIDIA Parakeet on this Mac.") }
        guard !translate || model.supportsTranslation else { throw MouthyFailure("Choose Whisper Small or Medium for English translation.") }
        let language = try checkedLanguage(language, model: model)
        guard !occupied else { throw MouthyFailure("Whisper is already working. Please wait.") }
        occupied = true; defer { occupied = false; scheduleRelease() }
        guard samples.contains(where: { abs($0) > 0.0001 }) else { return TranscriptionDocument(text: "") }
        try await load(model: model, download: false, progress: { _ in })
        guard let pipeline else { throw MouthyFailure("Whisper did not load.") }
        let result = try await pipeline.transcribe(audioArray: samples, decodeOptions: options(pipeline, model: model, language: language, translate: translate, vocabulary: vocabulary))
        try Task.checkCancellation()
        return document(result)
    }
    func transcribe(file: URL, model: WhisperModel, language: String, translate: Bool, vocabulary: String) async throws -> TranscriptionDocument {
        guard Self.supported else { throw MouthyFailure("Whisper needs a Mac with Apple silicon. Use NVIDIA Parakeet on this Mac.") }
        guard !translate || model.supportsTranslation else { throw MouthyFailure("Choose Whisper Small or Medium for English translation.") }
        let language = try checkedLanguage(language, model: model)
        guard !occupied else { throw MouthyFailure("Whisper is already working. Please wait.") }
        occupied = true; defer { occupied = false; scheduleRelease() }
        try await load(model: model, download: false, progress: { _ in })
        guard let pipeline else { throw MouthyFailure("Whisper did not load.") }
        let result = try await pipeline.transcribe(audioPath: file.path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental(chunkDurationSeconds: 30, maxBufferedChunks: 1)),
            decodeOptions: options(pipeline, model: model, language: language, translate: translate, vocabulary: vocabulary))
        try Task.checkCancellation()
        return document(result)
    }
    func releaseIfIdle() async {
        guard !occupied else { return }
        let old = pipeline; pipeline = nil; selected = nil
        await old?.unloadModels()
    }
    /// True while a Whisper model is held in memory.
    var loaded: Bool { pipeline != nil }
    func removeDownload(_ model: WhisperModel) async throws {
        guard !occupied else { throw MouthyFailure("Wait for Whisper to finish before removing its model.") }
        if selected == model { await releaseIfIdle() }
        let folder = Self.folder(model)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
    }
    /// The model stays loaded so every dictation starts warm; it is released only when macOS is short of memory.
    private func scheduleRelease() { ModelMemory.watch() }
}
