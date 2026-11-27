import Accelerate
import AVFoundation
import CoreML
import Foundation
import MouthyCore
import NaturalLanguage

/// Mouthy's own voice, on-device: text -> phonemes (`VoicePhonemes`) -> Matcha-TTS encoder -> durations -> flow steps ->
/// Vocos spectrum -> inverse FFT here -> 24 kHz audio. Three Core ML models trained for Mouthy (Matcha-TTS and Vocos,
/// MIT architectures; trained with `voice-model/`, converted and checked against PyTorch outside the repo), run on the CPU (the
/// encoder's variable length doesn't plan on the Neural Engine). Tone is the model's speaker input: neutral, excited,
/// calm or worried.
public final class MouthyVoice: @unchecked Sendable {
    public enum Tone: Int32, Sendable, CaseIterable { case neutral, excited, calm, worried }
    public static let sampleRate = 24_000.0
    public static let modelNames = ["MouthyVoiceEncoder", "MouthyVoiceFlow", "MouthyVoiceVocoder"]
    static let channels = 100, nFFT = 1024, hop = 256, bins = 513
    /// The longest phoneme input the encoder takes (its range); longer sentences are split at commas or words.
    static let maxTokens = 1024

    let encoder: MLModel, flow: MLModel, vocoder: MLModel
    let phonemizer: VoicePhonemes

    /// `directory` holds the three compiled models (`<name>.mlmodelc`) and `lexicon.tsv`.
    public init(directory: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        encoder = try MLModel(contentsOf: directory.appendingPathComponent("MouthyVoiceEncoder.mlmodelc"), configuration: config)
        flow = try MLModel(contentsOf: directory.appendingPathComponent("MouthyVoiceFlow.mlmodelc"), configuration: config)
        vocoder = try MLModel(contentsOf: directory.appendingPathComponent("MouthyVoiceVocoder.mlmodelc"), configuration: config)
        phonemizer = try VoicePhonemes(lexicon: directory.appendingPathComponent("lexicon.tsv"))
    }

    /// Where the voice is looked for: the running app's resources (build.sh puts it there), then Mouthy's support
    /// folder `Models/MouthyVoice/` (tests, or a copy for a host app).
    public static var locations: [URL] {
        [Bundle.main.resourceURL, LocalStore.supportDirectory.appendingPathComponent("Models/MouthyVoice")].compactMap { $0 }
    }
    /// Tests point this at a freshly compiled voice instead of the app's or support folder's.
    nonisolated(unsafe) static var directoryOverride: URL?
    public static var installedDirectory: URL? {
        if let directoryOverride { return directoryOverride }
        return locations.first { dir in
            (modelNames.map { "\($0).mlmodelc" } + ["lexicon.tsv"]).allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
    }

    // MARK: - Symbols

    /// Matcha's symbol table for this voice (`matcha/text/symbols.py`): pad, punctuation, letters, IPA, then "ᵊ".
    /// Indexed by Unicode scalar like Python's `str` (a later duplicate wins, as in its dict).
    static let symbolIDs: [Unicode.Scalar: Int32] = {
        let all = "_;:,.!?¡¿—…\"«»“” ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘'̩'ᵻᵊ"
        var map = [Unicode.Scalar: Int32]()
        for (i, s) in all.unicodeScalars.enumerated() { map[s] = Int32(i) }
        return map
    }()

    /// Token ids with the blank (0) between and around them (Matcha's `intersperse`); unknown symbols are skipped.
    static func tokens(_ phonemes: String) -> [Int32] {
        let ids = phonemes.unicodeScalars.compactMap { symbolIDs[$0] }
        var out = [Int32](repeating: 0, count: ids.count * 2 + 1)
        for (i, id) in ids.enumerated() { out[2 * i + 1] = id }
        return out
    }

    // MARK: - Rendering

    /// Sentences, each short enough for the encoder.
    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [text] : out
    }

    /// Audio for `text` at 24 kHz, sentence by sentence (`onSentence` gets each as it is ready). `steps` flow steps
    /// (more is smoother and slower), `seed` fixes the noise so the same text sounds the same.
    public func render(_ text: String, tone: Tone = .neutral, steps: Int = 6, seed: UInt64 = 7,
                       onSentence: (([Float]) -> Void)? = nil) throws -> [Float] {
        var all: [Float] = []
        var rng = SeededNormal(seed: seed)
        for sentence in Self.sentences(text) {
            for piece in split(phonemizer.phonemes(sentence)) {
                let audio = try renderPhonemes(piece, tone: tone, steps: steps, rng: &rng)
                onSentence?(audio)
                all += audio
            }
        }
        return all
    }

    /// Splits phonemes too long for the encoder at punctuation, else at spaces.
    func split(_ phonemes: String) -> [String] {
        let limit = (Self.maxTokens - 1) / 2
        guard phonemes.unicodeScalars.count > limit else { return phonemes.isEmpty ? [] : [phonemes] }
        var parts: [String] = [], current = ""
        // a run longer than the limit with no space (a spelled-out string of letters) is cut into pieces
        let words = phonemes.split(separator: " ", omittingEmptySubsequences: true).flatMap { word -> [Substring] in
            let scalars = Array(word.unicodeScalars)
            guard scalars.count > limit else { return [word] }
            return stride(from: 0, to: scalars.count, by: limit).map { Substring(String(String.UnicodeScalarView(scalars[$0..<min($0 + limit, scalars.count)]))) }
        }
        for word in words {
            if (current.unicodeScalars.count + word.unicodeScalars.count + 1) > limit, !current.isEmpty { parts.append(current); current = "" }
            current += (current.isEmpty ? "" : " ") + word
            if let last = word.last, ",;:.!?".contains(last), current.unicodeScalars.count > limit / 2 { parts.append(current); current = "" }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    func renderPhonemes(_ phonemes: String, tone: Tone, steps: Int, rng: inout SeededNormal) throws -> [Float] {
        let ids = Self.tokens(phonemes)
        guard ids.count > 1 else { return [] }
        let T = ids.count
        let x = try MLMultiArray(shape: [1, NSNumber(value: T)], dataType: .int32)
        for (i, id) in ids.enumerated() { x[i] = NSNumber(value: id) }
        let toneArray = try MLMultiArray(shape: [1], dataType: .int32); toneArray[0] = NSNumber(value: tone.rawValue)
        let enc = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["phonemes": x, "tone": toneArray]))
        guard let mu = enc.featureValue(for: "mu")?.multiArrayValue, let logw = enc.featureValue(for: "logw")?.multiArrayValue else { throw Failure.unexpectedOutput }
        let muX = Self.floats(mu), lw = Self.floats(logw)
        // Durations: rounded, not ceiled (ceil made every sound ~14% long; see the voice plan).
        let durations = lw.map { max(0, Int((exp($0)).rounded())) }
        let frames = max(1, durations.reduce(0, +))
        let padded = (frames + 3) / 4 * 4
        let C = Self.channels
        var muY = [Float](repeating: 0, count: C * padded)
        var f = 0
        for (t, d) in durations.enumerated() where d > 0 {
            for _ in 0..<d where f < frames {
                for c in 0..<C { muY[c * padded + f] = muX[c * T + t] }
                f += 1
            }
        }
        var mask = [Float](repeating: 0, count: padded)
        for i in 0..<frames { mask[i] = 1 }
        var z = (0..<(C * padded)).map { _ in Float(rng.next()) * 0.667 }
        let muArray = try Self.array(muY, [1, C, padded]), maskArray = try Self.array(mask, [1, 1, padded])
        let dt = 1 / Float(steps)
        for i in 0..<steps {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "x": Self.array(z, [1, C, padded]), "mu": muArray, "mask": maskArray,
                "t": Self.array([Float(i) * dt], [1]), "tone": toneArray])
            guard let v = try flow.prediction(from: input).featureValue(for: "velocity")?.multiArrayValue else { throw Failure.unexpectedOutput }
            let velocity = Self.floats(v)
            vDSP.add(z, vDSP.multiply(dt, velocity), result: &z)
        }
        var mel = [Float](repeating: 0, count: C * frames)
        for c in 0..<C { for i in 0..<frames { mel[c * frames + i] = z[c * padded + i] } }
        let voc = try vocoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": Self.array(mel, [1, C, frames])]))
        guard let re = voc.featureValue(for: "real")?.multiArrayValue, let im = voc.featureValue(for: "imag")?.multiArrayValue else { throw Failure.unexpectedOutput }
        return Self.istft(real: Self.floats(re), imag: Self.floats(im), frames: frames)
    }

    public enum Failure: Error { case unexpectedOutput, notInstalled }

    static func floats(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        switch a.dataType {
        case .float32: return Array(UnsafeBufferPointer(start: a.dataPointer.assumingMemoryBound(to: Float.self), count: n))
        #if arch(arm64)
        case .float16:   // Float16 doesn't exist on Intel Macs; there the generic path below reads it
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            return (0..<n).map { Float(p[$0]) }
        #endif
        default: return (0..<n).map { a[$0].floatValue }
        }
    }

    static func array(_ values: [Float], _ shape: [Int]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        values.withUnsafeBufferPointer { src in a.dataPointer.assumingMemoryBound(to: Float.self).update(from: src.baseAddress!, count: values.count) }
        return a
    }

    // MARK: - Inverse STFT (Vocos "same" padding)

    static let window: [Float] = (0..<nFFT).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(nFFT)) }
    static let dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .INVERSE)!

    /// One frame: the inverse real FFT of 513 bins (torch.fft.irfft, norm "backward").
    static func irfft(real: UnsafePointer<Float>, imag: UnsafePointer<Float>, stride: Int) -> [Float] {
        let half = nFFT / 2
        var ir = [Float](repeating: 0, count: half), ii = [Float](repeating: 0, count: half)
        for k in 0..<half { ir[k] = real[k * stride]; ii[k] = imag[k * stride] }
        ii[0] = real[half * stride]                // vDSP's packing: Nyquist's real part rides in imag[0]
        var or = [Float](repeating: 0, count: half), oi = [Float](repeating: 0, count: half)
        vDSP_DFT_Execute(dft, ir, ii, &or, &oi)
        var out = [Float](repeating: 0, count: nFFT)
        let scale = 1 / Float(2 * nFFT)
        for k in 0..<half { out[2 * k] = or[k] * scale * 2; out[2 * k + 1] = oi[k] * scale * 2 }
        return out
    }

    static func istft(real: [Float], imag: [Float], frames: Int) -> [Float] {
        let pad = (nFFT - hop) / 2
        let size = (frames - 1) * hop + nFFT
        var y = [Float](repeating: 0, count: size), env = [Float](repeating: 0, count: size)
        let windowSquared = window.map { $0 * $0 }
        real.withUnsafeBufferPointer { re in
            imag.withUnsafeBufferPointer { im in
                for t in 0..<frames {
                    let frame = irfft(real: re.baseAddress! + t, imag: im.baseAddress! + t, stride: frames)
                    for n in 0..<nFFT { y[t * hop + n] += frame[n] * window[n]; env[t * hop + n] += windowSquared[n] }
                }
            }
        }
        guard size > 2 * pad else { return [] }
        return (pad..<(size - pad)).map { y[$0] / max(env[$0], 1e-11) }
    }
}

/// Standard normal noise from a fixed seed (SplitMix64 + Box-Muller), so a sentence renders the same each time.
struct SeededNormal {
    var state: UInt64
    var spare: Double?
    init(seed: UInt64) { state = seed }
    mutating func uniform() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53)
    }
    mutating func next() -> Double {
        if let s = spare { spare = nil; return s }
        let u = uniform(), v = uniform()
        let r = (-2 * log(u)).squareRoot()
        spare = r * sin(2 * .pi * v)
        return r * cos(2 * .pi * v)
    }
}

/// Counts scheduled buffers until the last has played; `finish` ends the wait early. Resumes its waiter once.
@MainActor final class PlaybackWait {
    private var pending = 0, producing = true
    private(set) var done = false
    private var continuation: CheckedContinuation<Void, Never>?
    func added() { pending += 1 }
    func played() { pending -= 1; check() }
    func finishProducing() { producing = false; check() }
    private func check() { if !producing && pending <= 0 { finish() } }
    func finish() {
        guard !done else { return }
        done = true
        continuation?.resume(); continuation = nil
    }
    func wait() async {
        guard !done else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in if done { c.resume() } else { continuation = c } }
    }
}

/// Plays Mouthy's voice: sentences are scheduled as they render, so the first one starts while the rest are made.
@MainActor public final class MouthyVoicePlayer {
    public static let shared = MouthyVoicePlayer()
    private var voice: MouthyVoice?
    private var release: Task<Void, Never>?

    /// Speaks `text` and returns when it has finished playing. Throws when the voice isn't on this Mac or fails before
    /// any sound plays (the caller then uses the system voice). A change of output device (the engine stops itself) or
    /// playback running well past the audio's length ends it early, so the caller never waits forever.
    public func speak(_ text: String, tone: MouthyVoice.Tone = .neutral) async throws {
        release?.cancel()
        defer { scheduleRelease() }
        let voice: MouthyVoice
        if let loaded = self.voice { voice = loaded } else {
            guard let dir = MouthyVoice.installedDirectory else { throw MouthyVoice.Failure.notInstalled }
            voice = try await Task.detached(priority: .userInitiated) { try MouthyVoice(directory: dir) }.value
            self.voice = voice
        }
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: MouthyVoice.sampleRate, channels: 1) else { throw MouthyVoice.Failure.unexpectedOutput }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.play()
        let wait = PlaybackWait()
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            Task { @MainActor in wait.finish() }
        }
        defer { NotificationCenter.default.removeObserver(observer); node.stop(); engine.stop() }
        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            Task.detached(priority: .userInitiated) {
                do { _ = try voice.render(text, tone: tone) { continuation.yield($0) }; continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
        }
        var seconds = 0.0, renderError: Error?
        do {
            for try await samples in stream where !samples.isEmpty && !wait.done {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                let peak = max(vDSP.maximumMagnitude(samples), 1e-6), gain = min(1, 0.9 / peak)
                var dst = UnsafeMutableBufferPointer(start: buffer.floatChannelData![0], count: samples.count)
                vDSP.multiply(gain, samples, result: &dst)
                wait.added()
                seconds += Double(samples.count) / MouthyVoice.sampleRate
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in Task { @MainActor in wait.played() } }
            }
        } catch { renderError = error }
        if seconds == 0, let renderError { throw renderError }
        wait.finishProducing()
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds + 3))
            wait.finish()
        }
        await wait.wait()
        watchdog.cancel()
    }

    /// The models stay loaded 30 s after the last sentence, then are released.
    private func scheduleRelease() {
        release = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            voice = nil
        }
    }
}
