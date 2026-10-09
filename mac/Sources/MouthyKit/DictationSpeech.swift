import Foundation
import MouthyCore

/// What `AppModel` needs from a speech engine: start, split, finish, cancel and file transcription.
/// `SpeechService` is the real one; state tests inject a scripted fake so the dictation state machine
/// can run without a microphone, models or permissions.
@MainActor
protocol DictationSpeech: AnyObject {
    var onPreview: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onWaveform: ((MicrophoneFrame) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    /// The microphone went away mid-recording: capture stopped, and `finish` still returns what was recorded.
    var onInterruption: ((String) -> Void)? { get set }
    var document: TranscriptionDocument { get }
    var inputDeviceName: String { get }
    var isActive: Bool { get }
    func start(locale: String, vocabulary: String, inputDeviceUID: String, provider: SpeechEngine, whisperModel: WhisperModel,
               whisperLanguage: String, translate: Bool, status: @escaping (String) -> Void) async throws
    /// Mid-dictation split: what was said since the last split; the session keeps running.
    func split() async throws -> String
    func finish(cutAt: TimeInterval?) async throws -> String
    func cancel() async
    func transcribeFile(_ url: URL, locale: String, vocabulary: String, provider: SpeechEngine, whisperModel: WhisperModel,
                        whisperLanguage: String, translate: Bool, status: @escaping (String) -> Void) async throws -> String
}

extension SpeechService: DictationSpeech {}
