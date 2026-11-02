import Foundation

// Talk: a realtime voice conversation with a provider's model. This file holds the pure parts (configuration,
// usage, transcript, PCM and each provider's wire format); the session, socket and audio live in MouthyKit.
// Decisions and the verified protocol facts: notes/ADR-talk-sessions.md.

/// A realtime voice provider Talk can drive.
public enum TalkProvider: String, Sendable, Codable, CaseIterable {
    case geminiLive
    case openAIRealtime

    /// The model Talk uses when the host names none.
    public var defaultModel: String {
        switch self {
        case .geminiLive: return "gemini-3.8-live"
        case .openAIRealtime: return "gpt-realtime-2.1"
        }
    }

    /// This provider's wire format for one session.
    public func wireFormat(_ configuration: TalkSessionConfiguration) -> any TalkWireFormat {
        switch self {
        case .geminiLive: return GeminiLiveFormat(configuration)
        case .openAIRealtime: return OpenAIRealtimeFormat(configuration)
        }
    }
}

public struct TalkSessionConfiguration: Sendable, Equatable {
    public var provider: TalkProvider
    public var model: String
    /// The provider's voice name ("Kore" for Gemini); nil lets the provider choose.
    public var voice: String?
    /// System instructions for the model; nil or blank sends none.
    public var instructions: String?
    /// The session hangs up by itself after this long, counted from `start()`.
    public var maximumDuration: Duration
    /// Asks the provider for text of both sides. Gemini bills these words as output text on top of the audio.
    public var transcribe: Bool

    public init(provider: TalkProvider = .geminiLive, model: String? = nil, voice: String? = nil, instructions: String? = nil,
                maximumDuration: Duration = .seconds(300), transcribe: Bool = true) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.voice = voice; self.instructions = instructions
        self.maximumDuration = maximumDuration; self.transcribe = transcribe
    }
}

// MARK: - Usage

/// Token counts a provider reported. Zero where it reported nothing.
public struct TalkTokenCounts: Sendable, Equatable, Codable {
    public var input = 0
    public var output = 0
    public var total = 0
    public var inputAudio = 0
    public var outputAudio = 0
    public var cachedInput = 0

    public init(input: Int = 0, output: Int = 0, total: Int = 0, inputAudio: Int = 0, outputAudio: Int = 0, cachedInput: Int = 0) {
        self.input = input; self.output = output; self.total = total
        self.inputAudio = inputAudio; self.outputAudio = outputAudio; self.cachedInput = cachedInput
    }

    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, output: a.output + b.output, total: a.total + b.total, inputAudio: a.inputAudio + b.inputAudio,
             outputAudio: a.outputAudio + b.outputAudio, cachedInput: a.cachedInput + b.cachedInput)
    }
}

/// What one Talk session used, for the host's spend ledger. Seconds are measured by Mouthy from the audio it sent and
/// received; tokens are the provider's own numbers, nil when it reported none.
public struct TalkUsage: Sendable, Equatable, Codable {
    public var provider: TalkProvider
    public var model: String
    /// Microphone audio sent to the provider.
    public var secondsSent: Double = 0
    /// Model speech received from the provider (played or not).
    public var secondsReceived: Double = 0
    public var tokens: TalkTokenCounts?

    public init(provider: TalkProvider, model: String, secondsSent: Double = 0, secondsReceived: Double = 0, tokens: TalkTokenCounts? = nil) {
        self.provider = provider; self.model = model
        self.secondsSent = secondsSent; self.secondsReceived = secondsReceived; self.tokens = tokens
    }
}

/// Adds up a session's usage. A provider may report a turn's tokens more than once; the last report of a turn counts,
/// and turns add up.
public struct TalkUsageMeter: Sendable {
    private var usage: TalkUsage
    private var turn: TalkTokenCounts?

    public init(provider: TalkProvider, model: String) { usage = TalkUsage(provider: provider, model: model) }

    public mutating func sent(bytes: Int, sampleRate: Double) { usage.secondsSent += PCM16.seconds(bytes: bytes, sampleRate: sampleRate) }
    public mutating func received(bytes: Int, sampleRate: Double) { usage.secondsReceived += PCM16.seconds(bytes: bytes, sampleRate: sampleRate) }
    public mutating func report(_ counts: TalkTokenCounts) { turn = counts }
    public mutating func endTurn() {
        guard let turn else { return }
        usage.tokens = (usage.tokens ?? TalkTokenCounts()) + turn
        self.turn = nil
    }
    /// Everything so far, including a turn still open.
    public var total: TalkUsage {
        var copy = self
        copy.endTurn()
        return copy.usage
    }
}

// MARK: - Transcript

public enum TalkRole: String, Sendable, Codable { case user, model }

public struct TalkTurn: Sendable, Equatable, Identifiable {
    public let id: Int
    public let role: TalkRole
    public fileprivate(set) var text: String
    /// No more words will join this turn.
    public fileprivate(set) var isComplete: Bool
}

/// Joins the provider's transcription pieces into turns. Pieces arrive in no guaranteed order between the two sides,
/// so each side keeps at most one open turn and pieces join it until that turn completes.
public struct TalkTranscript: Sendable, Equatable {
    public private(set) var turns: [TalkTurn] = []
    private var nextID = 0

    public init() {}

    public mutating func append(_ text: String, from role: TalkRole) {
        guard !text.isEmpty else { return }
        if let open = turns.lastIndex(where: { $0.role == role && !$0.isComplete }) {
            turns[open].text += text
        } else {
            turns.append(TalkTurn(id: nextID, role: role, text: text, isComplete: false))
            nextID += 1
        }
    }

    public mutating func complete(_ role: TalkRole) {
        for index in turns.indices where turns[index].role == role { turns[index].isComplete = true }
    }

    public mutating func completeAll() {
        for index in turns.indices { turns[index].isComplete = true }
    }
}

// MARK: - Audio

/// Raw 16-bit little-endian mono PCM, the format every Talk provider takes and sends.
public enum PCM16 {
    public static func encode<C: Collection>(_ samples: C) -> Data where C.Element == Float {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            var offset = 0
            for sample in samples {
                let clamped = sample.isFinite ? max(-1, min(1, sample)) : 0
                let value = Int16(clamped < 0 ? clamped * 32_768 : clamped * 32_767)
                raw.storeBytes(of: value.littleEndian, toByteOffset: offset, as: Int16.self)
                offset += 2
            }
        }
        return data
    }

    public static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            (0..<raw.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768 }
        }
    }

    public static func seconds(bytes: Int, sampleRate: Double) -> Double { sampleRate > 0 ? Double(bytes / 2) / sampleRate : 0 }

    /// Loudness 0…1 on the same scale as `MicrophoneFrame.level`.
    public static func level(_ data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        let energy = data.withUnsafeBytes { raw in
            (0..<count).reduce(0.0) { sum, index in
                let value = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
                return sum + value * value
            }
        }
        let rms = Float(sqrt(energy / Double(count)))
        return rms > 0.002 ? min(1, rms * 8) : 0
    }
}

// MARK: - Wire format

/// What a provider said, in the session's terms.
public enum TalkEvent: Sendable, Equatable {
    /// The provider accepted the setup; microphone audio may flow.
    case ready
    /// Model speech: 16-bit PCM at the format's `outputSampleRate`.
    case audio(Data)
    case transcript(TalkRole, String)
    /// The provider says that side's current turn has no more words.
    case transcriptFinished(TalkRole)
    /// The person spoke over the model: stop playback at once and drop what is queued.
    case interrupted
    case turnComplete
    /// The latest token report for the current turn.
    case usage(TalkTokenCounts)
    /// The provider will close the connection soon.
    case closing(String)
    /// The provider reported an error it ends the session for.
    case failure(String)
    /// The provider reported a problem but keeps the session open.
    case notice(String)
}

/// One provider's wire format. Pure: it builds the connection request and messages and reads server messages, so
/// every provider is tested without a network.
public protocol TalkWireFormat: Sendable {
    /// Sample rate of the microphone PCM the provider takes.
    var inputSampleRate: Double { get }
    /// Sample rate of the model speech it sends.
    var outputSampleRate: Double { get }
    /// The WebSocket request, with the key in a header and never in the URL.
    func request(apiKey: String) -> URLRequest
    /// Sent once the socket is open, before any audio.
    func openingMessages() -> [String]
    func audioMessage(_ pcm16: Data) -> String
    /// Reads one server message. Unknown or malformed messages read as no events.
    mutating func read(_ message: String) -> [TalkEvent]
    /// Sent after an interruption flushed `unplayedSeconds` of the model's speech unheard. A provider that keeps
    /// the conversation by what was sent (OpenAI Realtime) is told where the person stopped hearing it.
    mutating func interruptionMessages(unplayedSeconds: Double) -> [String]
}

extension TalkWireFormat {
    public mutating func interruptionMessages(unplayedSeconds: Double) -> [String] { [] }
}
