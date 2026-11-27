import AVFoundation
import FluidAudio
import Foundation
import MouthyCore

/// "Show words instantly": a second, small recognizer that hears the audio as it arrives and writes each word about a
/// tenth of a second after it is said (NVIDIA's Parakeet EOU 120M in 160 ms steps, through FluidAudio; English only,
/// lowercase, no punctuation; NVIDIA Open Model License). It only ever shows the newest words (`StreamedWords`): the
/// main recognizer writes the text at every pause and at the stop. Its model (214 MB) downloads only when the person
/// asks, from FluidAudio's Hugging Face repository like the Core ML Parakeet. Audio stays on this Mac.
actor LiveWords {
    static let shared = LiveWords()

    /// Core ML on the Neural Engine; an Intel Mac has no fast route for it.
    static var supported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    static let megabytes = 214
    /// Where FluidAudio keeps it: `loadModels(to: nil)` downloads into this folder's parent.
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)
    }
    /// Every file is there and whole: a download cut short leaves the model folders behind with `.partial` files in
    /// them, and a switch that then does nothing.
    static var installed: Bool {
        guard supported else { return false }
        let files = FileManager.default
        return ModelNames.ParakeetEOU.requiredModels.allSatisfy { name in
            let item = folder.appendingPathComponent(name)
            guard name.hasSuffix(".mlmodelc") else { return files.fileExists(atPath: item.path) }
            guard files.fileExists(atPath: item.appendingPathComponent("coremldata.bin").path),
                  let inside = files.enumerator(at: item, includingPropertiesForKeys: nil) else { return false }
            return !inside.contains { ($0 as? URL)?.pathExtension == "partial" }
        }
    }

    private var manager: StreamingEouAsrManager?
    private var loading: Task<StreamingEouAsrManager?, Never>?
    /// The model is on this Mac and did not load: not tried again until it is downloaded anew.
    private var unloadable = false
    private var hearing = 0
    /// When it last heard audio: a dictation is using it between batches too.
    private var heardAt: ContinuousClock.Instant?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Downloads the model (an explicit action in Settings) and loads it.
    func download() async throws {
        guard Self.supported else { throw MouthyFailure("Showing words instantly needs a Mac with Apple silicon.") }
        let downloaded = StreamingEouAsrManager(chunkSize: .ms160)
        try await downloaded.loadModels()
        unloadable = false
        if manager == nil { manager = downloaded }
    }

    /// Loads the downloaded model, so a dictation starts with it warm. False when it is not on this Mac or will not load.
    @discardableResult
    func prepare() async -> Bool {
        if manager != nil { return true }
        guard Self.installed else { return false }
        // One load, however many callers ask while it runs (the warm-up after launch and a first dictation).
        let load = loading ?? Task {
            let created = StreamingEouAsrManager(chunkSize: .ms160)
            do { try await created.loadModels(from: Self.folder) } catch {
                Diagnostics.dictation.notice("live words: the model did not load, \(error.localizedDescription, privacy: .public)")
                return nil
            }
            return created
        }
        loading = load
        let loaded = await load.value
        if loading == load { loading = nil }
        if manager == nil { manager = loaded }
        if manager == nil { unloadable = true }
        return manager != nil
    }

    /// Hears newly recorded 16 kHz samples (`restart`: they begin a recording) and answers with every word since the
    /// restart. While the model loads it answers `.loading` at once and hears nothing (the stop waits for a batch in
    /// flight, and must never wait for a model); `.failed` when it cannot: the caller goes on without it.
    func hear(_ samples: [Float], restart: Bool) async -> StreamAnswer {
        guard let manager else {
            guard Self.installed, !unloadable else { return .failed }
            if loading == nil { Task { await self.prepare() } }
            return .loading
        }
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return .failed }
        hearing += 1
        defer { hearing -= 1; heardAt = .now }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            if restart { await manager.reset() }
            _ = try await manager.process(audioBuffer: buffer)
            return .words(StreamedWords.words(pieces: await manager.getRawTokenStrings(), milliseconds: await manager.getTokenTimestampsMs()))
        } catch {
            if !(error is CancellationError) {
                Diagnostics.dictation.notice("live words: stopped, \(error.localizedDescription, privacy: .public)")
            }
            return .failed
        }
    }

    var loaded: Bool { manager != nil }

    /// Not while a dictation is using it: batches come ten times a second, and one released between two would start
    /// its audio over mid-sentence. `quiet`: how long ago the last batch must be.
    func releaseIfIdle(quiet: Duration = .seconds(5)) async {
        guard hearing == 0, heardAt.map({ $0.duration(to: .now) >= quiet }) ?? true, let old = manager else { return }
        manager = nil
        await old.cleanup()
    }

    func removeDownload() async throws {
        guard hearing == 0 else { throw MouthyFailure("Wait for the dictation to finish before removing this model.") }
        await releaseIfIdle(quiet: .zero)
        guard FileManager.default.fileExists(atPath: Self.folder.path) else { return }
        try FileManager.default.trashItem(at: Self.folder, resultingItemURL: nil)
    }
}
