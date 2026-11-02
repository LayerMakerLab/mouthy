import Foundation

/// Gemini Live over a raw WebSocket (Google AI for Developers, Live API reference https://ai.google.dev/api/live).
/// Input is 16 kHz and output 24 kHz 16-bit little-endian mono PCM. The key goes in the `x-goog-api-key` header,
/// as Google's own SDK sends it, instead of the `?key=` query the WebSocket guide shows.
public struct GeminiLiveFormat: TalkWireFormat {
    public static let endpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
    public let inputSampleRate: Double = 16_000
    public let outputSampleRate: Double = 24_000
    private let configuration: TalkSessionConfiguration

    public init(_ configuration: TalkSessionConfiguration) { self.configuration = configuration }

    public func request(apiKey: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    public func openingMessages() -> [String] {
        let model = configuration.model.hasPrefix("models/") ? configuration.model : "models/" + configuration.model
        let voice = configuration.voice.flatMap { $0.isEmpty ? nil : $0 }
        let instructions = configuration.instructions.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let setup = Setup(model: model,
                          generationConfig: .init(responseModalities: ["AUDIO"],
                                                  speechConfig: voice.map { .init(voiceConfig: .init(prebuiltVoiceConfig: .init(voiceName: $0))) }),
                          systemInstruction: instructions.map { .init(parts: [.init(text: $0)]) },
                          inputAudioTranscription: configuration.transcribe ? Empty() : nil,
                          outputAudioTranscription: configuration.transcribe ? Empty() : nil)
        return [Self.json(["setup": setup])]
    }

    public func audioMessage(_ pcm16: Data) -> String {
        // Base64 needs no JSON escaping, so the hot path skips the encoder.
        #"{"realtimeInput":{"audio":{"data":""# + pcm16.base64EncodedString() + #"","mimeType":"audio/pcm;rate=16000"}}}"#
    }

    public mutating func read(_ message: String) -> [TalkEvent] {
        guard let server = try? JSONDecoder().decode(ServerMessage.self, from: Data(message.utf8)) else { return [] }
        var events: [TalkEvent] = []
        if server.setupComplete != nil { events.append(.ready) }
        if let content = server.serverContent {
            if let input = content.inputTranscription { events += Self.transcript(input, .user) }
            if let output = content.outputTranscription { events += Self.transcript(output, .model) }
            for part in content.modelTurn?.parts ?? [] {
                guard let blob = part.inlineData, blob.mimeType?.hasPrefix("audio/pcm") ?? true,
                      let audio = Data(base64Encoded: blob.data), !audio.isEmpty else { continue }
                events.append(.audio(audio))
            }
            if content.interrupted == true { events.append(.interrupted) }
        }
        if let usage = server.usageMetadata { events.append(.usage(usage.counts)) }
        if server.serverContent?.turnComplete == true { events.append(.turnComplete) }
        if let away = server.goAway { events.append(.closing("Gemini will end the connection in \(away.timeLeft ?? "a moment").")) }
        return events
    }

    private static func transcript(_ piece: Transcription, _ role: TalkRole) -> [TalkEvent] {
        // Google's sample client shows a piece marked finished as the end of that side's turn, not as new words.
        if piece.finished == true { return [.transcriptFinished(role)] }
        return piece.text.map { [.transcript(role, $0)] } ?? []
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Messages

    struct Empty: Codable {}

    struct Setup: Encodable {
        struct GenerationConfig: Encodable {
            struct SpeechConfig: Encodable {
                struct VoiceConfig: Encodable {
                    struct Prebuilt: Encodable { var voiceName: String }
                    var prebuiltVoiceConfig: Prebuilt
                }
                var voiceConfig: VoiceConfig
            }
            var responseModalities: [String]
            var speechConfig: SpeechConfig?
        }
        struct Content: Encodable {
            struct Part: Encodable { var text: String }
            var parts: [Part]
        }
        var model: String
        var generationConfig: GenerationConfig
        var systemInstruction: Content?
        var inputAudioTranscription: Empty?
        var outputAudioTranscription: Empty?
    }

    struct ServerMessage: Decodable {
        struct Content: Decodable {
            struct Turn: Decodable {
                struct Part: Decodable {
                    struct Blob: Decodable { var mimeType: String?; var data: String }
                    var inlineData: Blob?
                }
                var parts: [Part]?
            }
            var modelTurn: Turn?
            var turnComplete: Bool?
            var interrupted: Bool?
            var inputTranscription: Transcription?
            var outputTranscription: Transcription?
        }
        struct Usage: Decodable {
            struct Modality: Decodable { var modality: String?; var tokenCount: Int? }
            var promptTokenCount: Int?
            var cachedContentTokenCount: Int?
            var responseTokenCount: Int?
            var totalTokenCount: Int?
            var promptTokensDetails: [Modality]?
            var responseTokensDetails: [Modality]?

            var counts: TalkTokenCounts {
                func audio(_ details: [Modality]?) -> Int { details?.filter { $0.modality == "AUDIO" }.compactMap(\.tokenCount).reduce(0, +) ?? 0 }
                return TalkTokenCounts(input: promptTokenCount ?? 0, output: responseTokenCount ?? 0, total: totalTokenCount ?? 0,
                                       inputAudio: audio(promptTokensDetails), outputAudio: audio(responseTokensDetails),
                                       cachedInput: cachedContentTokenCount ?? 0)
            }
        }
        struct GoAway: Decodable { var timeLeft: String? }
        var setupComplete: Empty?
        var serverContent: Content?
        var usageMetadata: Usage?
        var goAway: GoAway?
    }

    struct Transcription: Decodable { var text: String?; var finished: Bool? }
}
