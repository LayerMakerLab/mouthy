import CoreML
import Foundation
import MouthyCore

/// "Only listen to my voice": a small voiceprint of the person (the mean of speaker embeddings from three sentences
/// they read, never audio) and, while they dictate, a check of who is speaking, so a TV, music with singing or people
/// nearby are turned down like any other non-voice sound (VoiceActivity.voiceOnly). Everything runs on this Mac.
/// The embedding model is WeSpeaker ResNet34-LM on the Neural Engine (`SpeakerModel`), held only while dictating with
/// the feature on or while training, then released.
public struct Voiceprint: Codable, Sendable, Equatable {
    public var version = 1
    /// The model whose embeddings these are: a voiceprint from another model would compare as noise.
    public var model = Voiceprint.modelName
    /// Unit-length mean embedding of the windows the person read.
    public var embedding: [Float]
    /// Windows that went into it.
    public var windows: Int
    public var created = Date()

    /// Embeddings from this model only: a voiceprint from FluidAudio's WeSpeaker compares as noise.
    public static let modelName = "wespeaker-resnet34-lm-ane-2s"

    public init(embedding: [Float], windows: Int) {
        self.embedding = embedding
        self.windows = windows
    }
}

public enum VoicePrint {
    /// Three short sentences, about 15 s read aloud, with most of English's sounds between them.
    public static let sentences = [
        "The quick brown fox jumps over the lazy dog by the river.",
        "Please call me back when you have a minute this afternoon.",
        "I would like two coffees and a slice of lemon cake, thank you.",
    ]
    static let fileName = "voiceprint.json"

    public static func url(in directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    /// The saved voiceprint, or nil when there is none (or it came from another model).
    public static func load(in directory: URL) -> Voiceprint? {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let print = try? JSONDecoder().decode(Voiceprint.self, from: data),
              print.model == Voiceprint.modelName, !print.embedding.isEmpty else { return nil }
        return print
    }

    /// Saved owner-only (0600) in the support folder; never sent anywhere.
    public static func save(_ print: Voiceprint, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = url(in: directory)
        try JSONEncoder().encode(print).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// "Forget my voice".
    public static func forget(in directory: URL) throws {
        let url = url(in: directory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// The voiceprint dictation checks against, set when a dictation starts (nil: everyone's voice is heard, as before).
    nonisolated(unsafe) private static var current: Voiceprint?
    private static let lock = NSLock()
    public static var active: Voiceprint? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Builds a voiceprint from the person reading `sentences` (16 kHz). Throws when too little speech was heard.
    public static func train(_ samples: [Float]) async throws -> Voiceprint {
        guard let chances = await VoiceActivity.shared.probabilities(samples) else {
            throw MouthyFailure("Mouthy's voice detector isn't on this Mac yet. Download Parakeet in Settings first.")
        }
        let chunk = VoiceActivity.chunk
        var embeddings: [[Float]] = []
        for start in SpeakerMask.windows(pieces: chances.count) {
            let speech = chances[start..<start + SpeakerMask.window].filter { $0 >= VoiceActivity.keep }.count
            guard speech >= SpeakerMask.window - 2 else { continue }
            let low = start * chunk, high = min(samples.count, (start + SpeakerMask.window) * chunk)
            guard let embedding = try await SpeakerModel.shared.embed(Array(samples[low..<high])) else { continue }
            embeddings.append(embedding)
        }
        guard embeddings.count >= minimumWindows else {
            throw MouthyFailure("Mouthy heard too little of your voice. Read all three sentences out loud, then try again.")
        }
        return Voiceprint(embedding: SpeakerMask.centroid(embeddings), windows: embeddings.count)
    }
    /// About 4 s of clear speech.
    static let minimumWindows = 4
    public static let notInstalled = "The voice model isn't installed on this Mac."
}

/// The speaker embedding model: WeSpeaker's VoxCeleb ResNet34-LM converted for the Neural Engine (`SpeakerEmbedder`,
/// fixed 2 s fbank input, 100% of its cost on the Neural Engine). It ships inside the app (`SpeakerEmbedder.bundledModel`).
/// It loads only with `.cpuAndNeuralEngine`; there is no CPU or GPU fallback, so without it the feature says the voice
/// model isn't installed. Loaded on first use, released `idleRelease` after the last embedding: nothing stays resident
/// when idle.
actor SpeakerModel {
    static let shared = SpeakerModel()
    nonisolated(unsafe) static var idleRelease: Duration = .seconds(10)
    private var embedder: SpeakerEmbedder?
    private var releaseTask: Task<Void, Never>?

    /// The compiled model inside the app (outside an app, as in swift test, the support folder's Models/ copy).
    static var model: URL? { SpeakerEmbedder.bundledModel }

    var loaded: Bool { embedder != nil }

    func prepare() { _ = load(); scheduleRelease() }

    /// A unit-length speaker embedding of `samples` (16 kHz, one 2 s window); nil when the model is not on this Mac.
    func embed(_ samples: [Float]) throws -> [Float]? {
        guard samples.count >= SpeakerEmbedder.minimumSamples, let embedder = load() else { return nil }
        defer { scheduleRelease() }
        let embedding = try embedder.embedding(samples)
        let length = embedding.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? embedding.map { $0 / length } : nil
    }

    func release() {
        releaseTask?.cancel(); releaseTask = nil
        embedder = nil
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        let delay = Self.idleRelease
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.release()
        }
    }

    private func load() -> SpeakerEmbedder? {
        if let embedder { return embedder }
        guard let url = Self.model, let loaded = try? SpeakerEmbedder(compiledModel: url, computeUnits: .cpuAndNeuralEngine) else { return nil }
        embedder = loaded
        return loaded
    }
}

/// One dictation's speaker check: as audio is recorded, each 1.5 s window holding speech is compared with the
/// voiceprint in the background, so the stop never waits for it. Positions count from the start of the dictation
/// (or the last split). Recognition before a window is scored uses the verdict of the speech it runs on from (or
/// keeps it); LiveTranscriber recognizes again when a later score changes what was kept (`changed`).
actor SpeakerTrack {
    let print: Voiceprint
    private let chunk = VoiceActivity.chunk
    /// Audio from `bufferStart` (samples) onward, still needed by windows not yet scored.
    private var buffer: [Float] = []
    private var bufferStart = 0
    /// The next window to score (in 256 ms pieces): every piece before it has all its windows scored.
    private(set) var nextWindow = 0
    private var speech: [Float] = []
    private var scores: [Int: Float] = [:]
    /// Embeddings of the windows that scored clearly someone else (by window start): the other voices heard in this
    /// dictation, which the short windows are compared with.
    private var otherVoices: [Int: [Float]] = [:]
    /// Short-window embeddings of pieces (`SpeakerMask.fineSizes`), made only once another voice has been heard, with
    /// the `nextWindow` they were made at.
    private var fine: [Int: (at: Int, embeddings: [[Float]])] = [:]
    /// Pieces before this have their short windows, held no speech, or came before any other voice.
    private var fineNext = 0
    /// Embeddings computed (for tests and the dictation log).
    private(set) var scored = 0
    /// Below this, speech the background check hasn't reached yet, checked at the stop, is clearly someone else's
    /// (another voice alone scored -0.02-0.20 against the default voice on 2 s windows; the person 0.53 or more).
    static let clearlyOther: Float = 0.3

    init(print: Voiceprint) {
        self.print = print
        Task.detached(priority: .utility) { await SpeakerModel.shared.prepare() }
    }

    /// A track for a new dictation when "Only listen to my voice" is on.
    static func forDictation() -> SpeakerTrack? { VoicePrint.active.map(SpeakerTrack.init) }

    /// The track and where the samples being recognized start, for VoiceActivity.voiceOnly. `final`: the stop's own
    /// recognition, which checks speech the background hasn't scored yet instead of guessing.
    struct Scope: Sendable { let track: SpeakerTrack; let offset: Int; let final: Bool }
    @TaskLocal static var scope: Scope?

    var fed: Int { bufferStart + buffer.count }
    /// Scores by window start (tests).
    var windowScores: [Int: Float] { scores }
    var speechChances: [Float] { speech }

    /// Takes recorded samples (starting at `start`, default `fed`; what was already fed is skipped) and scores every
    /// window they complete; returns `nextWindow`.
    @discardableResult
    func feed(_ samples: [Float], from start: Int? = nil) async -> Int {
        let skip = max(0, fed - (start ?? fed))
        if skip < samples.count { buffer += samples[skip...] }
        while (nextWindow + SpeakerMask.window) * chunk <= fed {
            let low = nextWindow * chunk - bufferStart
            let window = Array(buffer[low..<low + SpeakerMask.window * chunk])
            if let chances = await VoiceActivity.shared.probabilities(window) {
                for (i, chance) in chances.prefix(SpeakerMask.window).enumerated() {
                    let piece = nextWindow + i
                    while speech.count <= piece { speech.append(0) }
                    speech[piece] = max(speech[piece], chance)
                }
                if chances.filter({ $0 >= VoiceActivity.keep }).count >= SpeakerMask.minimumSpeech,
                   let embedding = try? await SpeakerModel.shared.embed(window) {
                    let score = SpeakerMask.similarity(embedding, print.embedding)
                    scores[nextWindow] = score
                    if score < Self.clearlyOther { otherVoices[nextWindow] = embedding }
                    scored += 1
                }
            }
            // Every short window of these pieces lies in the audio still held.
            await embedPieces(through: nextWindow + SpeakerMask.window - 2, speechOnly: true)
            nextWindow += SpeakerMask.hop
            let drop = nextWindow * chunk - bufferStart
            if drop > 0 { buffer.removeFirst(min(drop, buffer.count)); bufferStart += drop }
        }
        return nextWindow
    }

    /// Scores every window `samples` (starting at `offset`) completes that the background check hasn't reached yet, so
    /// recognition never keeps another voice only because the check was behind (a busy Mac, or the stop).
    /// At the stop (`final`), the newest pieces no 2 s window reaches get their short windows too.
    @discardableResult
    func catchUp(_ samples: [Float], offset: Int, final: Bool = false) async -> Int {
        if offset + samples.count > fed, offset <= fed { await feed(samples, from: offset) }
        if final { await embedPieces(through: fed / chunk - 1, speechOnly: false) }
        return nextWindow
    }

    /// Short windows centred on the pieces from `fineNext` through `last`, once another voice has been heard (until
    /// then there is nobody to tell apart, and nothing is spent). `speechOnly`: skip pieces the voice detector heard no
    /// speech in (the stop's newest pieces have no detector score yet).
    private func embedPieces(through last: Int, speechOnly: Bool) async {
        guard !otherVoices.isEmpty else { return }
        var piece = max(fineNext, bufferStart == 0 ? 0 : bufferStart / chunk + 1)
        while piece <= last {
            if !speechOnly || (piece < speech.count && speech[piece] >= VoiceActivity.keep) {
                var embeddings: [[Float]] = []
                for size in SpeakerMask.fineSizes {
                    let centre = piece * chunk + chunk / 2
                    let low = max(bufferStart, centre - size * chunk / 2), high = min(fed, centre + size * chunk / 2)
                    guard high - low >= SpeakerEmbedder.minimumSamples,
                          let embedding = try? await SpeakerModel.shared.embed(Array(buffer[(low - bufferStart)..<(high - bufferStart)]))
                    else { break }
                    embeddings.append(embedding)
                }
                if embeddings.count == SpeakerMask.fineSizes.count { fine[piece] = (nextWindow, embeddings) }
            }
            piece += 1
        }
        fineNext = max(fineNext, piece)
    }

    /// Pieces whose short windows all sound clearly like the other voices heard in this dictation, as known before
    /// window `since` was scored (nil: now). Inside the person's sentences these are another voice alone: a pause, or
    /// right before or after them.
    private func clearlyOthers(since: Int? = nil) -> Set<Int> {
        let voices = otherVoices.filter { since == nil || $0.key < since! }.map(\.value)
        guard !voices.isEmpty else { return [] }
        let theirs = SpeakerMask.centroid(voices)
        var pieces = Set<Int>()
        for (piece, entry) in fine where since == nil || entry.at < since! {
            if SpeakerMask.clearlyTheirs(mine: entry.embeddings.map { SpeakerMask.similarity($0, print.embedding) },
                                         theirs: entry.embeddings.map { SpeakerMask.similarity($0, theirs) }) {
                pieces.insert(piece)
            }
        }
        return pieces
    }

    /// Speech per piece: the background check's, then `heard` (piece, speech) for pieces it hasn't reached.
    private func speechFlags(_ heard: [(Int, Bool)]) -> [Bool] {
        var flags = speech.map { $0 >= VoiceActivity.keep }
        for (piece, isSpeech) in heard where piece >= speech.count && piece >= 0 {
            while flags.count <= piece { flags.append(false) }
            flags[piece] = flags[piece] || isSpeech
        }
        return flags
    }

    /// Verdicts as scored so far: unscored speech that runs straight on from scored speech is the same voice still
    /// talking; speech that starts fresh is kept. (Holding back "theirs" until every window around a piece was in
    /// changed no words of the person's in VoicePrintTests and made the stop re-recognize, 160-207 ms instead of 0-56.)
    /// `clear`: pieces the short windows say are clearly someone else's, whatever the 2 s windows around them say.
    private static func verdicts(_ flags: [Bool], _ scores: [Int: Float], clear: Set<Int>) -> [SpeakerMask.Verdict] {
        var verdicts = SpeakerMask.verdicts(speech: flags, scores: scores, spreadTheirs: true)
        for piece in clear where piece < verdicts.count { verdicts[piece] = .theirs }
        return verdicts
    }

    /// Whether any window covering `piece` was scored (in `scores`).
    private func covered(_ piece: Int, _ scores: [Int: Float]) -> Bool {
        var start = piece - piece % SpeakerMask.hop
        while start > piece - SpeakerMask.window, start >= 0 {
            if scores[start] != nil { return true }
            start -= SpeakerMask.hop
        }
        return false
    }

    /// For each piece of audio being recognized (its centre at `positions`, in samples from the dictation's start, with
    /// whether it holds speech), whether it is someone else's voice. At the stop (`final`), speech the background check
    /// hasn't scored yet that runs on from someone else's is checked once against the voiceprint (the newest 1.5 s of
    /// `samples`, which start at `offset`), so the person starting to talk right before the stop is never dropped on a guess.
    /// `clear`: the pieces the short windows positively heard as another voice alone (turned down even right beside the
    /// person's words, where other sound is kept as their padding).
    func someoneElse(at positions: [Int], speech heard: [Bool], samples: [Float]? = nil, offset: Int = 0) async -> (others: [Bool], clear: [Bool]) {
        let pieces = positions.map { $0 / chunk }
        let flags = speechFlags(Array(zip(pieces, heard)))
        let clear = clearlyOthers()
        var verdicts = Self.verdicts(flags, scores, clear: clear)
        if let samples {
            let guessed = pieces.indices.filter { heard[$0] && pieces[$0] >= 0 && pieces[$0] < verdicts.count
                && verdicts[pieces[$0]] == .theirs && !covered(pieces[$0], scores) }
            if let last = guessed.last, case let end = min(samples.count, (pieces[last] + 1) * chunk - offset),
               case let start = max(0, end - SpeakerMask.window * chunk), start < end {
                let score = (try? await SpeakerModel.shared.embed(Array(samples[start..<end]))).flatMap { $0 }
                    .map { SpeakerMask.similarity($0, print.embedding) }
                let other = (score ?? 1) < Self.clearlyOther
                for index in guessed where !clear.contains(pieces[index]) { verdicts[pieces[index]] = other ? .theirs : .mine }
            }
        }
        let others = pieces.indices.map { heard[$0] && pieces[$0] >= 0 && pieces[$0] < verdicts.count && verdicts[pieces[$0]] == .theirs }
        return (others, pieces.map { clear.contains($0) })
    }

    /// Whether recognition of `range` (samples) made when the windows before `since` were scored kept or turned down
    /// different speech than the scores now say (then it is recognized again). At the stop (`final`), also when it
    /// turned down speech no window has scored yet: the stop's own recognition checks that speech instead.
    func changed(_ range: Range<Int>, since: Int, final: Bool) -> Bool {
        let low = range.lowerBound / chunk, high = (range.upperBound + chunk - 1) / chunk
        guard low < high else { return false }
        let flags = speechFlags([])
        let now = Self.verdicts(flags, scores, clear: clearlyOthers())
        let then = Self.verdicts(flags, scores.filter { $0.key < since }, clear: clearlyOthers(since: since))
        for piece in low..<min(high, flags.count) where flags[piece] {
            if (now[piece] == .theirs) != (then[piece] == .theirs) { return true }
            if final, now[piece] == .theirs, !covered(piece, scores) { return true }
        }
        return false
    }
}

/// Settings' "Train my voice": records the person reading `VoicePrint.sentences` from the chosen microphone, keeps
/// only the voiceprint built from it (the audio is dropped as soon as it is measured) and saves it owner-only.
@MainActor
final class VoiceTrainer: ObservableObject {
    enum Step: Equatable { case idle, reading, working, failed(String) }
    @Published var step: Step = .idle
    @Published var trained: Bool
    let directory: URL
    private var capture: ParakeetService?
    private var limit: Task<Void, Never>?

    init(directory: URL = LocalStore.supportDirectory) {
        self.directory = directory
        trained = FileManager.default.fileExists(atPath: VoicePrint.url(in: directory).path)
    }

    /// Starts recording. Nothing downloads; without the voice model it says so.
    func start(inputDeviceUID: String) {
        guard step != .reading, step != .working else { return }
        Task {
            guard SpeakerModel.model != nil else { step = .failed(VoicePrint.notInstalled); return }
            let capture = ParakeetService()
            do { try capture.start(inputDeviceUID: inputDeviceUID, level: { _ in }, interrupted: { [weak self] message in self?.fail(message) }) }
            catch { step = .failed(error.localizedDescription); return }
            self.capture = capture
            step = .reading
            // Three sentences take about 15 s; a forgotten recording stops itself.
            limit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                self?.finish()
            }
        }
    }

    /// Runs after a voiceprint is saved (AppModel switches "Only listen to my voice" on).
    var onTrained: (() -> Void)?

    /// The person finished reading: build and save the voiceprint.
    func finish() {
        guard step == .reading, let capture else { return }
        limit?.cancel(); limit = nil
        self.capture = nil
        step = .working
        Task {
            do {
                let samples = try capture.finishSamples()
                let print = try await VoicePrint.train(samples)
                try VoicePrint.save(print, in: directory)
                trained = true; step = .idle
                onTrained?()
            } catch {
                step = .failed(error.localizedDescription)
            }
            await SpeakerModel.shared.release()
        }
    }

    func cancel() {
        limit?.cancel(); limit = nil
        capture?.cancel(); capture = nil
        step = .idle
    }

    /// "Forget my voice": deletes the voiceprint.
    func forget() {
        cancel()
        try? VoicePrint.forget(in: directory)
        trained = FileManager.default.fileExists(atPath: VoicePrint.url(in: directory).path)
        VoicePrint.active = nil
    }

    private func fail(_ message: String) {
        capture?.cancel(); capture = nil
        limit?.cancel(); limit = nil
        step = .failed(message)
    }
}
