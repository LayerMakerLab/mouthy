import Combine
import SwiftUI
import MouthyCore
import MouthyNotch

/// Spoken commands and questions for the notch, checked in `AppModel.complete()` before a dictation is
/// delivered. From the notch's own mic a bare command ("timer 10 minutes") is enough; from any other
/// dictation the transcript must start with "Mouthy". A timer, note or reminder lands in its tab and the notch
/// peeks a one-line confirmation; a question is answered on this Mac and shown in the notch. Nothing routed is
/// pasted or saved to history, and anything that is not a command is left to normal delivery. The hub drops peeks
/// while it is open, so what the notch should show is held and shown when the hub closes, for the rest of its time.
@MainActor final class NotchVoiceRouter {
    /// What the notch shows for a routed command.
    enum Presentation: Equatable {
        /// A one-line outcome: `line` on the card (with `detail` under it), `ear` in the band beside the camera.
        case confirmation(line: String, ear: String, ok: Bool, detail: String? = nil)
        case thinking(question: String)
        case answer(question: String, answer: String)
        /// The answer was cancelled: take the card down.
        case cleared
    }

    /// How the notch shows it, for how many seconds; the real hub by default, a recorder in tests.
    var present: (Presentation, Double) -> Void = { NotchVoiceRouter.show($0, seconds: $1) }
    /// Whether the hub is open, and its open state as it changes (no polling); the real hub by default.
    var hubIsOpen: () -> Bool = { NotchHub.shared.isOpen }
    var hubOpenChanges: AnyPublisher<Bool, Never> = NotchHub.shared.$isOpen.eraseToAnyPublisher()
    /// How long an answer stays up.
    var answerHold = NotchVoiceRouter.answerSeconds
    /// The tab entry points a command lands in; the real tabs by default, recorders in tests.
    var startTimer: (Int) -> Void = { TimersTab.shared.start(seconds: $0) }
    var addNote: (String) -> Void = { NotesTab.shared.addNote($0) }
    var addReminder: (String, Date) async throws -> Void = { try await CalendarTab.shared.addReminder($0, due: $1) }
    var now: () -> Date = { Date() }
    var calendar = Calendar.current
    var answerer = NotchAnswer()
    /// The question being answered, if any. The only task the router ever holds.
    private(set) var answerTask: Task<Void, Never>?
    /// The latest card and when it is due to leave (system uptime), shown again when the hub closes before then.
    private var held: (presentation: Presentation, until: TimeInterval)?
    private var hubWatch: AnyCancellable?

    /// The command in a finished transcript, or nil to deliver it as usual.
    func command(in transcript: String, fromNotch: Bool) -> NotchCommand? {
        NotchCommand.parse(transcript, now: now(), calendar: calendar, requiresName: !fromNotch)
    }

    /// Runs a command and returns the status line for the model.
    func run(_ command: NotchCommand) async -> String {
        switch command {
        case .timer(let seconds):
            startTimer(seconds)
            let line = Self.timerLine(seconds)
            display(.confirmation(line: line, ear: Self.timerEar(seconds), ok: true))
            return line + " started."
        case .note(let text):
            addNote(text)
            display(.confirmation(line: "Saved to Notes", ear: "Noted", ok: true))
            return "Note added to the notch."
        case .reminder(let due, let text):
            do {
                try await addReminder(text, due)
                let time = due.formatted(date: .omitted, time: .shortened)
                display(.confirmation(line: "Reminder at \(time)", ear: time, ok: true))
                return "Reminder set for \(time)."
            } catch {
                let reason = error.localizedDescription
                // The card has one line for the reason: its first sentence ("Reminders access is off.").
                let short = reason.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? reason
                display(.confirmation(line: "Reminder not saved", ear: "Not saved", ok: false, detail: short))
                return "Reminder not saved: " + reason
            }
        case .question(let question):
            answer(question)
            return "Answering in the notch."
        }
    }

    /// Shows "Thinking…", then the answer. Runs on its own so dictation is free again meanwhile.
    private func answer(_ question: String) {
        answerTask?.cancel()
        display(.thinking(question: question))
        let answerer = self.answerer
        answerTask = Task { [weak self] in
            let reply = await answerer.answer(question)
            guard let self, !Task.isCancelled else { return }
            if let reply { self.display(.answer(question: question, answer: reply)) } else { self.held = nil }
            self.answerTask = nil
        }
    }

    /// Stops a question still being answered and clears its card. False when none was.
    @discardableResult func cancelAnswer() -> Bool {
        guard let task = answerTask else { return false }
        task.cancel(); answerTask = nil
        display(.cleared)
        return true
    }

    /// Shows `presentation` now, or holds it while the hub is open (an open hub drops peeks).
    private func display(_ presentation: Presentation) {
        if presentation == .cleared { held = nil; present(.cleared, 0); return }
        let seconds = duration(presentation)
        held = (presentation, ProcessInfo.processInfo.systemUptime + seconds)
        watchHub()
        if !hubIsOpen() { present(presentation, seconds) }
    }

    /// Opening the hub takes a card down; when it closes, the held card comes back for the time it has left.
    private func watchHub() {
        guard hubWatch == nil else { return }
        hubWatch = hubOpenChanges.sink { [weak self] open in
            guard !open else { return }
            // The hub reports the change before it applies it: show once it is closed.
            Task { @MainActor [weak self] in self?.showHeld() }
        }
    }

    private func showHeld() {
        guard !hubIsOpen(), let held else { return }
        let left = held.until - ProcessInfo.processInfo.systemUptime
        guard left > 0.5 else { self.held = nil; return }
        present(held.presentation, left)
    }

    private func duration(_ presentation: Presentation) -> Double {
        switch presentation {
        case .confirmation(_, _, let ok, _): ok ? 3.5 : 5
        case .thinking: answerer.limit.seconds + 1
        case .answer: answerHold
        case .cleared: 0
        }
    }

    // MARK: Words

    static func timerLine(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return "\(seconds / 3600)-hour timer" }
        if seconds % 60 == 0 { return "\(seconds / 60)-minute timer" }
        return "\(seconds)-second timer"
    }

    /// About ten characters for the band: "10 min", "1 h 30 min", "45 s".
    static func timerEar(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if rest > 0 || parts.isEmpty { parts.append("\(rest) s") }
        return parts.joined(separator: " ")
    }

    // MARK: The notch

    /// Answers stay up for 12 s, also counting time the hub was open; "Thinking…" until the answer replaces it.
    static let answerSeconds = 12.0

    static func show(_ presentation: Presentation, seconds: Double) {
        let hub = NotchHub.shared
        switch presentation {
        case .confirmation(let line, let ear, let ok, let detail):
            hub.peek(AnyView(VoiceCommandPeek(line: line, ok: ok, detail: detail)), seconds: seconds,
                     leading: AnyView(VoiceCommandPeek.glyph(ok: ok)), trailing: AnyView(Text(ear)), title: line)
        case .thinking(let question):
            let card = NotchAnswerCard(question: question, answer: nil)
            hub.peek(AnyView(card), seconds: seconds,
                     leading: AnyView(MascotGlyph(pose: .listen, size: 18)), trailing: AnyView(Text("Thinking…")), title: card.accessibilityTitle)
        case .answer(let question, let answer):
            let card = NotchAnswerCard(question: question, answer: answer)
            hub.peek(AnyView(card), seconds: seconds,
                     leading: AnyView(MascotGlyph(pose: .talk, size: 18)), trailing: AnyView(Text("Answer")), title: card.accessibilityTitle)
        case .cleared:
            // A new peek replaces the card and is gone at once.
            hub.peek(AnyView(EmptyView()), seconds: 0, title: "Cancelled")
        }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// The one-line confirmation under the notch: the cheering giraffe and what happened, or why it didn't.
struct VoiceCommandPeek: View {
    let line: String
    let ok: Bool
    var detail: String?

    static func glyph(ok: Bool) -> some View {
        Group {
            if ok { MascotGlyph(pose: .cheer, size: 18) }
            // A text glyph: an SF Symbol drawn as an Image ignores the foreground style.
            else { Text(Image(systemName: "exclamationmark.circle.fill")).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(MouthyTheme.glow) }
        }
    }

    var body: some View {
        NotchPeekRow(title: line, detail: detail) {
            if ok { MascotGlyph(pose: .cheer, size: 24) }
            else { Self.glyph(ok: false) }
        }
    }
}
