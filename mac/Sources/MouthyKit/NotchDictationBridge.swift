import Combine
import Foundation
import MouthyNotch

@MainActor private var dictationLink: AnyCancellable?

/// What the notch shows for a session phase, or nil when the session is over.
enum NotchSessionMirror {
    static func state(phase: DictationSession.Phase, level: Float, partial: String, target: String, prompt: String?) -> NotchDictation? {
        switch phase {
        case .preparing, .listening:
            return NotchDictation(target: target, level: level, partialText: partial, prompt: prompt)
        case .transcribing:
            return NotchDictation(target: target, partialText: partial, transcribing: true, prompt: prompt)
        case .idle, .finished, .failed:
            return nil
        }
    }
}

public extension NotchHub {
    /// Mirrors a dictation session in the notch (level, live words, transcribing) until it finishes,
    /// fails or is cancelled. `target` labels where the text goes, e.g. a pane name.
    func presentDictation(session: DictationSession, target: String) {
        presentDictation(session: session, target: target, prompt: nil)
    }

    /// Like `presentDictation(session:target:)`, with a question shown above the live words while the
    /// person answers it out loud.
    func presentDictation(session: DictationSession, target: String, prompt: String?) {
        // A session presented before it starts is still idle; only an idle after it has run ends the link.
        dictationLink = session.$phase.drop(while: { $0 == .idle }).combineLatest(session.$level, session.$partialText)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, level, partial in
                guard let self else { return }
                if let state = NotchSessionMirror.state(phase: phase, level: level, partial: partial, target: target, prompt: prompt) {
                    if state != self.dictation { self.presentDictation(state) }
                } else {
                    if self.dictation != nil { self.endDictation() }
                    dictationLink = nil
                }
            }
    }
}
