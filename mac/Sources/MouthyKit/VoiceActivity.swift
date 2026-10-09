import CoreML
import FluidAudio
import MouthyCore
import Foundation

/// Silero's trained voice detector (FluidAudio, about 1 MB, Neural Engine), on Apple silicon. It hears soft and
/// quiet speech that an energy threshold misses, so leftover audio holding words is never thrown away. After speech
/// it only adds: audio it calls silence is still recognized when the energy check is unsure. In a recording where
/// nothing passed the speech threshold it decides, because recognizers make words ("Yeah") out of silence. Intel Macs keep
/// the energy check. The model downloads with the local engine, or at the warm-up after launch on installs made
/// before it (Whisper-only ones too), unless Local Only Mode blocks network use; without it, energy decides alone.
actor VoiceActivity {
    static let shared = VoiceActivity()
    /// Samples per probability (256 ms at 16 kHz).
    static let chunk = VadManager.chunkSize
    /// A chunk at or above this probability holds speech. Silero's own default is 0.5; lower keeps more.
    static let speech: Float = 0.4
    private var manager: VadManager?
    private var unavailable = false

    /// The model folder: FluidAudio's current name, then the one older versions used.
    static var model: URL? {
        #if arch(arm64)
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
        return ["silero-vad-coreml", "silero-vad"].lazy
            .map { models.appendingPathComponent("\($0)/\(ModelNames.VAD.sileroVadFile)", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        #else
        return nil
        #endif
    }

    /// Fetches the model if it is missing (setup, or the warm-up after launch); never during dictation.
    static func download() async {
        #if arch(arm64)
        guard model == nil else { return }
        _ = try? await VadManager()
        #endif
    }

    /// Speech probability for each 256 ms chunk of `samples`, oldest first; nil when the model is not on this Mac.
    func probabilities(_ samples: [Float]) async -> [Float]? {
        guard let manager = load(), !samples.isEmpty else { return nil }
        return try? await manager.process(samples).map(\.probability)
    }

    /// Whether any chunk of `samples` holds speech; nil when the model is not on this Mac.
    func hearsSpeech(_ samples: [Float]) async -> Bool? {
        guard let chances = await probabilities(samples) else { return nil }
        return chances.contains { $0 >= Self.speech }
    }

    /// Speech probability at which audio is kept for recognition. Measured 2026-10-06: speech scores 0.99-1.00 even at
    /// -30 dB, while typing scored 0.08, a key click 0.15, music 0.38, breathing 0.44 and a cough 0.54.
    static let keep: Float = 0.65
    /// Chunks kept either side of speech (0.5 s), so word edges and short gaps between words stay.
    static let keepPad = 2

    /// `samples` for the recognizer: speech as recorded and every other sound turned down to a quiet room (VoiceMask).
    /// Empty when the detector hears no voice at all (then there is nothing to recognize); nil when the model is not
    /// on this Mac (then the recognizer hears everything, as before).
    /// With "Only listen to my voice" on (a dictation's SpeakerTrack in scope), speech that isn't the person's becomes
    /// a quiet room's hiss, keeping the padding around the person's own speech.
    func voiceOnly(_ samples: [Float]) async -> [Float]? {
        guard var chances = await probabilities(samples) else { return nil }
        var others: [Bool] = [], clear: [Bool] = []
        if let scope = SpeakerTrack.scope {
            await scope.track.catchUp(samples, offset: scope.offset, final: scope.final)
            let positions = chances.indices.map { scope.offset + $0 * Self.chunk + Self.chunk / 2 }
            (others, clear) = await scope.track.someoneElse(at: positions, speech: chances.map { $0 >= Self.keep },
                                                            samples: scope.final ? samples : nil, offset: scope.offset)
            for index in chances.indices where others[index] { chances[index] = 0 }
        }
        let voiced = VoiceMask.voiced(chances, count: (samples.count + Self.chunk - 1) / Self.chunk, threshold: Self.keep, pad: Self.keepPad)
        guard voiced.contains(true) else { return [] }
        let masked = VoiceMask.apply(samples, voiced: voiced, chunk: Self.chunk)
        // Another voice becomes room hiss (a quiet copy of a voice is still words), except the person's own padding.
        // Another voice the short windows heard clearly is hushed even inside the person's padding.
        return VoiceMask.hush(masked, voices: others.indices.map { (others[$0] && $0 < voiced.count && !voiced[$0]) || clear[$0] }, chunk: Self.chunk)
    }

    /// LiveTranscriber's voice check.
    static let hearsSpeech: LiveTranscriber.HearsSpeech = { samples in await shared.hearsSpeech(samples) }

    /// Loads the model before the first dictation needs it (a few ms once loaded; about 1 MB).
    func prepare() { _ = load() }

    func releaseIfIdle() { manager = nil; unavailable = false }

    var loaded: Bool { manager != nil }

    private func load() -> VadManager? {
        if let manager { return manager }
        guard !unavailable, let url = Self.model else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { unavailable = true; return nil }
        let loaded = VadManager(config: VadConfig(defaultThreshold: Self.speech), vadModel: model)
        manager = loaded
        return loaded
    }
}
