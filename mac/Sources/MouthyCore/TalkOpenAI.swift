import Foundation

/// OpenAI Realtime (GA interface) over a WebSocket: developers.openai.com/api/docs/guides/realtime-websocket and the
/// client and server event references. 16-bit little-endian mono PCM at 24 kHz both ways, server voice activity
/// detection that answers and interrupts by itself, and the key in the Authorization header (no beta header).
/// Over a WebSocket the client plays the audio, so after a barge-in it truncates the model's item to what was heard.
public struct OpenAIRealtimeFormat: TalkWireFormat {
    public static let endpoint = URL(string: "wss://api.openai.com/v1/realtime")!
    /// Input transcription runs as a separate model; this one is billed on top of the session.
    public static let transcriptionModel = "gpt-4o-mini-transcribe"
    public let inputSampleRate: Double = 24_000
    public let outputSampleRate: Double = 24_000
    private let configuration: TalkSessionConfiguration
    private var ready = false
    /// The model item whose audio is playing and how much of it arrived, for the truncate after a barge-in.
    private var speakingItem: String?
    private var speakingBytes = 0
    /// User items whose words arrived as deltas; their `completed` event then only closes the turn.
    private var streamedItems: Set<String> = []

    public init(_ configuration: TalkSessionConfiguration) { self.configuration = configuration }

    public func request(apiKey: String) -> URLRequest {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "model", value: configuration.model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    public func openingMessages() -> [String] {
        let voice = configuration.voice.flatMap { $0.isEmpty ? nil : $0 }
        let instructions = configuration.instructions.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let pcm = SessionUpdate.Format(type: "audio/pcm", rate: 24_000)
        let session = SessionUpdate.Session(
            type: "realtime", model: configuration.model, output_modalities: ["audio"], instructions: instructions,
            audio: .init(input: .init(format: pcm,
                                      turn_detection: .init(type: "server_vad", create_response: true, interrupt_response: true),
                                      transcription: configuration.transcribe ? .init(model: Self.transcriptionModel) : nil),
                         output: .init(format: pcm, voice: voice)))
        return [Self.json(SessionUpdate(type: "session.update", session: session))]
    }

    public func audioMessage(_ pcm16: Data) -> String {
        #"{"type":"input_audio_buffer.append","audio":""# + pcm16.base64EncodedString() + #""}"#
    }

    public mutating func read(_ message: String) -> [TalkEvent] {
        guard let event = try? JSONDecoder().decode(ServerEvent.self, from: Data(message.utf8)) else { return [] }
        switch event.type {
        case "session.updated":
            guard !ready else { return [] }
            ready = true
            return [.ready]
        case "response.output_audio.delta":
            guard let delta = event.delta, let audio = Data(base64Encoded: delta), !audio.isEmpty else { return [] }
            if event.item_id != speakingItem { speakingItem = event.item_id; speakingBytes = 0 }
            speakingBytes += audio.count
            return [.audio(audio)]
        case "response.output_audio_transcript.delta":
            return event.delta.map { [.transcript(.model, $0)] } ?? []
        case "response.output_audio_transcript.done":
            return [.transcriptFinished(.model)]
        case "conversation.item.input_audio_transcription.delta":
            if let item = event.item_id { streamedItems.insert(item) }
            return event.delta.map { [.transcript(.user, $0)] } ?? []
        case "conversation.item.input_audio_transcription.completed":
            let streamed = event.item_id.map { streamedItems.remove($0) != nil } ?? false
            guard !streamed, let words = event.transcript else { return [.transcriptFinished(.user)] }
            return [.transcript(.user, words), .transcriptFinished(.user)]
        case "input_audio_buffer.speech_started":
            // Server VAD cancels the response by itself; the client stops playback and truncates.
            return [.interrupted]
        case "response.done":
            var events: [TalkEvent] = []
            if let usage = event.response?.usage { events.append(.usage(usage.counts)) }
            if event.response?.status == "failed", let message = event.response?.status_details?.error?.message {
                events.append(.notice(message))
            }
            return events + [.turnComplete]
        case "error":
            let message = event.error?.message ?? "OpenAI reported an error."
            // Before the session is configured an error means it never will be.
            return [ready ? .notice(message) : .failure(message)]
        default:
            return []
        }
    }

    public mutating func interruptionMessages(unplayedSeconds: Double) -> [String] {
        defer { speakingItem = nil; speakingBytes = 0 }
        guard let item = speakingItem, unplayedSeconds > 0 else { return [] }
        let received = PCM16.seconds(bytes: speakingBytes, sampleRate: outputSampleRate)
        // Never past the audio that arrived: OpenAI rejects an end beyond it.
        let heard = Int((max(0, received - unplayedSeconds) * 1_000).rounded(.down))
        return [Self.json(Truncate(type: "conversation.item.truncate", item_id: item, content_index: 0, audio_end_ms: heard))]
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Messages (field names as OpenAI spells them)

    struct SessionUpdate: Encodable {
        struct Format: Encodable { var type: String; var rate: Int }
        struct TurnDetection: Encodable { var type: String; var create_response: Bool; var interrupt_response: Bool }
        struct Transcription: Encodable { var model: String }
        struct Input: Encodable { var format: Format; var turn_detection: TurnDetection; var transcription: Transcription? }
        struct Output: Encodable { var format: Format; var voice: String? }
        struct Audio: Encodable { var input: Input; var output: Output }
        struct Session: Encodable {
            var type: String
            var model: String
            var output_modalities: [String]
            var instructions: String?
            var audio: Audio
        }
        var type: String
        var session: Session
    }

    struct Truncate: Encodable { var type: String; var item_id: String; var content_index: Int; var audio_end_ms: Int }

    struct ServerEvent: Decodable {
        struct Failure: Decodable { var message: String? }
        struct Response: Decodable {
            struct Usage: Decodable {
                struct Details: Decodable { var audio_tokens: Int?; var cached_tokens: Int? }
                var total_tokens: Int?
                var input_tokens: Int?
                var output_tokens: Int?
                var input_token_details: Details?
                var output_token_details: Details?
                var counts: TalkTokenCounts {
                    TalkTokenCounts(input: input_tokens ?? 0, output: output_tokens ?? 0, total: total_tokens ?? 0,
                                    inputAudio: input_token_details?.audio_tokens ?? 0, outputAudio: output_token_details?.audio_tokens ?? 0,
                                    cachedInput: input_token_details?.cached_tokens ?? 0)
                }
            }
            struct StatusDetails: Decodable { var error: Failure? }
            var status: String?
            var status_details: StatusDetails?
            var usage: Usage?
        }
        var type: String
        var delta: String?
        var item_id: String?
        var transcript: String?
        var response: Response?
        var error: Failure?
    }
}
