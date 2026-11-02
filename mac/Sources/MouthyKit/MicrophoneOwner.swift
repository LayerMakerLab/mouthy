import Foundation

/// The one microphone owner inside a process: dictation, meetings and Talk never record at the same time, so no two
/// AVAudioEngines fight over the input and Talk's echo cancellation stays its own. Dictation and meetings ask before
/// they open the microphone; Talk claims it for the whole conversation.
@MainActor final class MicrophoneOwner {
    static let shared = MicrophoneOwner()
    nonisolated static let talkMessage = "Talk is using the microphone. Dictation is back when Talk ends."
    nonisolated static let busyMessage = "The microphone is busy with a dictation or meeting. Finish it, then start Talk."

    private struct Recorder {
        weak var object: AnyObject?
        let isRecording: () -> Bool
    }
    /// Weak, so a Talk session the host dropped without stopping frees the microphone too.
    private weak var talk: AnyObject?
    private var recorders: [Recorder] = []

    var isTalkActive: Bool { talk != nil }

    /// Registers something that records (a speech service or meeting recorder); `isRecording` is read before Talk
    /// starts and must hold `object` weakly. Gone objects drop out.
    func register(_ object: AnyObject, isRecording: @escaping () -> Bool) {
        recorders.removeAll { $0.object == nil }
        recorders.append(Recorder(object: object, isRecording: isRecording))
    }

    /// Dictation and meetings call this before opening the microphone.
    func requireFree() throws {
        if talk != nil { throw MouthyFailure(Self.talkMessage) }
    }

    func claimForTalk(_ owner: AnyObject) throws {
        guard talk == nil || talk === owner else { throw MouthyFailure("Another Talk session is using the microphone.") }
        guard !recorders.contains(where: { $0.object != nil && $0.isRecording() }) else { throw MouthyFailure(Self.busyMessage) }
        talk = owner
    }

    func release(_ owner: AnyObject) {
        if talk === owner { talk = nil }
    }
}
