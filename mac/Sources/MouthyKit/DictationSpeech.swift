import Foundation
import MouthyCore

/// What `AppModel` needs from a speech engine: start, split, finish, cancel and file transcription.
/// `SpeechService` is the real one; state tests inject a scripted fake so the dictation state machine
/// can run without a microphone, models or permissions.
@MainActor
protocol DictationSpeech: AnyObject {
    var onPreview: ((String) -> Void)? { get set }
    /// Whether the newest words of a preview will not change by themselves (the streaming recognizer's, with "Show
    /// words instantly"): "Type as I speak" types them at once.
    var previewIsFirm: Bool { get }
    /// Whether previews say when a pause was heard (`previewPause`): "Type as I speak" then types a phrase at
    /// each pause, as the pass over everything said has it, and nothing from the guesses in between.
    var previewMarksPauses: Bool { get }
    /// Set while `onPreview` is called with a pass's text of everything said up to a pause.
    var previewPause: LiveTyping.Pause? { get }
    /// "Show words instantly", for the next `start`.
    var instantWords: Bool { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onWaveform: ((MicrophoneFrame) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    /// The microphone went away mid-recording: capture stopped, and `finish` still returns what was recorded.
    var onInterruption: ((String) -> Void)? { get set }
    var document: TranscriptionDocument { get }
    var inputDevice: InputDevice? { get }
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

extension DictationSpeech {
    var previewIsFirm: Bool { false }
    var previewMarksPauses: Bool { false }
    var previewPause: LiveTyping.Pause? { nil }
    var instantWords: Bool { get { false } set {} }
}

extension SpeechService: DictationSpeech {}
