import Foundation

public struct TranscriptionOptions: Sendable {
    public var inputs: [String] = []
    public var engine: SpeechEngine = .apple
    public var model: WhisperModel = .baseEnglish
    public var language = "auto"
    public var prompt = ""
    public var translate = false
    public var format: TranscriptionDocument.Format = .text
    public var output: String?
    public var outputDirectory: String?
    public init() {}
}
public enum MouthyCommand {
    case application(headless: Bool, open: Bool)
    case help
    case models
    case download(SpeechEngine, WhisperModel)
    case transcribe(TranscriptionOptions)
    /// Records from the default microphone for a few seconds and prints the transcript (hardware check).
    case micTest(seconds: Int, engine: SpeechEngine)
    /// Replays a recording in real time through live recognition and prints stop-to-text latency.
    case benchLive(path: String, engine: SpeechEngine)

    public static func parse(_ arguments: [String]) throws -> MouthyCommand {
        if arguments.isEmpty { return .application(headless: false, open: false) }
        if arguments == ["--headless"] { return .application(headless: true, open: false) }
        if arguments == ["--open"] { return .application(headless: false, open: true) }
        if ["--help", "-h", "help"].contains(arguments[0]) { return .help }
        if arguments == ["models"] { return .models }
        if arguments.first == "bench-live", arguments.count >= 2 {
            return .benchLive(path: arguments[1], engine: arguments.dropFirst(2).compactMap { SpeechEngine(rawValue: $0) }.first ?? .parakeet)
        }
        if arguments.first == "mic-test" {
            let seconds = arguments.dropFirst().compactMap { Int($0) }.first ?? 6
            let engine = arguments.dropFirst().compactMap { SpeechEngine(rawValue: $0) }.first ?? .apple
            return .micTest(seconds: max(1, min(60, seconds)), engine: engine)
        }
        guard ["transcribe", "--transcribe", "download"].contains(arguments[0]) else { throw ArgumentError("Unknown command. Use --help.") }
        var options = TranscriptionOptions()
        var index = 1
        if arguments[0] == "download" {
            guard arguments.count > 1, let engine = SpeechEngine(rawValue: arguments[1]), engine != .apple else { throw ArgumentError("Use download whisper or download parakeet. Apple assets are prepared in Settings.") }
            options.engine = engine; index = 2
        }
        while index < arguments.count {
            let key = arguments[index]
            if arguments[0] == "download", key != "--model" {
                throw ArgumentError("Download takes an engine and optional --model only.")
            }
            func value() throws -> String {
                guard index + 1 < arguments.count else { throw ArgumentError("Missing value for \(key).") }
                index += 1; return arguments[index]
            }
            switch key {
            case "--engine":
                guard let engine = SpeechEngine(rawValue: try value()) else { throw ArgumentError("Engine must be apple, parakeet, or whisper.") }
                options.engine = engine
            case "--model":
                let value = try value()
                let aliases: [String: WhisperModel] = ["base.en": .baseEnglish, "small": .small, "medium": .medium, "turbo": .turbo]
                guard let model = aliases[value] ?? WhisperModel(rawValue: value) else { throw ArgumentError("Model must be base.en, small, medium, or turbo.") }
                options.model = model
            case "--language": options.language = try value()
            case "--prompt": options.prompt = try value()
            case "--translate": options.translate = true
            case "--format":
                guard let format = TranscriptionDocument.Format(rawValue: try value()) else { throw ArgumentError("Format must be text, json, srt, or vtt.") }
                options.format = format
            case "--output": options.output = try value()
            case "--output-dir": options.outputDirectory = try value()
            case "--": options.inputs += arguments.dropFirst(index + 1); index = arguments.count
            default:
                guard !key.hasPrefix("-") else { throw ArgumentError("Unknown option \(key).") }
                options.inputs.append(key)
            }
            index += 1
        }
        if arguments[0] == "download" {
            guard options.inputs.isEmpty else { throw ArgumentError("Download takes an engine and optional --model only.") }
            return .download(options.engine, options.model)
        }
        guard !options.inputs.isEmpty else { throw ArgumentError("Provide at least one audio file.") }
        guard options.output == nil || options.outputDirectory == nil else { throw ArgumentError("Choose --output or --output-dir, not both.") }
        guard options.inputs.count == 1 || options.outputDirectory != nil else { throw ArgumentError("Batch transcription requires --output-dir.") }
        guard !options.translate || options.engine == .whisper && options.model.supportsTranslation else { throw ArgumentError("English translation requires Whisper Small or Medium. Turbo is not trained for translation.") }
        return .transcribe(options)
    }
    public struct ArgumentError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
