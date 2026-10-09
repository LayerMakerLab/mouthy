import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import MouthyCore
@testable import MouthyKit
@testable import MouthyNotch

// Spoken commands and questions routed by `NotchVoiceRouter` from `AppModel.complete()`, through the scripted
// speech engine and the delivery seams. The tab entry points and the notch are recorded seams (the entry points
// themselves are covered by VoiceCommandTabsTests), so no window opens, no shared tab changes and no real app or
// Reminders list is touched.

/// What the router asked the notch to show and the tabs to do, in order.
@MainActor final class PeekLog {
    var shown: [NotchVoiceRouter.Presentation] = []
    /// How long each presentation was asked to stay, in seconds.
    var seconds: [Double] = []
    /// The hub's open state as the router sees it; `hubOpen.send` opens or closes it.
    var hubIsOpen = false
    let hubOpen = PassthroughSubject<Bool, Never>()
    func setHub(open: Bool) { hubOpen.send(open); hubIsOpen = open }
    var timers: [Int] = []
    var notes: [String] = []
    var reminders: [(title: String, due: Date)] = []
    /// Set to make the reminder fail the way CalendarTab does when access is off.
    var remindersDenied = false
}

/// Answers with fixed text, or never (ignoring cancellation, like a stuck model).
private final class StubAnswerModel: NotchAnswerModel, @unchecked Sendable {
    let unavailable: NotchAnswer.Unavailable?
    let reply: String?
    private let lock = NSLock()
    private var held: [UnsafeContinuation<Void, Never>] = []
    private(set) var asked = 0
    init(unavailable: NotchAnswer.Unavailable? = nil, reply: String? = nil) { self.unavailable = unavailable; self.reply = reply }
    var unavailableReason: NotchAnswer.Unavailable? { unavailable }
    func respond(instructions: String, prompt: String) async throws -> String {
        lock.withLock { asked += 1 }
        if let reply { return reply }
        await withUnsafeContinuation { continuation in lock.withLock { held.append(continuation) } }
        return "too late"
    }
    func release() { lock.withLock { held.forEach { $0.resume() }; held = [] } }
}

/// Today at 14:00, so "at 5" is 17:00 today.
@MainActor private func afternoon() -> Date {
    Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
}

@MainActor private func routedModel(_ text: String, keepHistory: Bool = true) -> (AppModel, DeliveryLog, PeekLog) {
    let speech = FakeSpeech(); speech.finalText = text
    let (model, log) = stateModel(speech)
    var preferences = model.preferences
    preferences.keepHistory = keepHistory
    model.preferences = preferences
    // Writing-style cleanup is left out (it would call the on-device model): delivered text is the transcript.
    model.enhancer = { text, _, _, _ in text }
    let peeks = PeekLog()
    model.voiceRouter.present = { peeks.shown.append($0); peeks.seconds.append($1) }
    model.voiceRouter.hubIsOpen = { peeks.hubIsOpen }
    model.voiceRouter.hubOpenChanges = peeks.hubOpen.eraseToAnyPublisher()
    model.voiceRouter.startTimer = { peeks.timers.append($0) }
    model.voiceRouter.addNote = { peeks.notes.append($0) }
    model.voiceRouter.addReminder = { title, due in
        if peeks.remindersDenied { throw MouthyFailure("Reminders access is off. Turn it on in Privacy & Security.") }
        peeks.reminders.append((title, due))
    }
    let now = afternoon()
    model.voiceRouter.now = { now }
    return (model, log, peeks)
}

@MainActor private func dictate(_ model: AppModel, fromNotch: Bool) async throws {
    model.begin(captureTarget: true, fromNotch: fromNotch)
    try await waitFor { model.phase == .listening }
    model.stop()
    try await waitFor { model.phase == .idle }
}

@MainActor @Suite struct NotchVoiceRouterTests {
    // MARK: Talk to the notch

    @Test func notchTimerStartsTheCountdownAndPastesNothing() async throws {
        let (model, log, peeks) = routedModel("Timer, 10 minutes.")
        try await dictate(model, fromNotch: true)
        #expect(peeks.timers == [600])
        #expect(log.texts.isEmpty, "a command is never pasted")
        #expect(model.history.isEmpty)
        #expect(peeks.shown == [.confirmation(line: "10-minute timer", ear: "10 min", ok: true)])
        // Nothing else keeps running: the router holds no task, the model is idle.
        #expect(model.voiceRouter.answerTask == nil && !model.busy)
    }

    @Test func notchNoteLandsInNotes() async throws {
        let (model, log, peeks) = routedModel("note call mom")
        try await dictate(model, fromNotch: true)
        #expect(peeks.notes == ["call mom"])
        #expect(log.texts.isEmpty && model.history.isEmpty)
        #expect(peeks.shown == [.confirmation(line: "Saved to Notes", ear: "Noted", ok: true)])
    }

    @Test func notchReminderReachesTheStore() async throws {
        let (model, log, peeks) = routedModel("Remind me at 5 to call Mom.")
        try await dictate(model, fromNotch: true)
        try await waitFor { !peeks.shown.isEmpty }
        let due = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: afternoon())!
        #expect(peeks.reminders.count == 1 && peeks.reminders.first?.title == "call Mom" && peeks.reminders.first?.due == due)
        #expect(log.texts.isEmpty && model.history.isEmpty)
        let time = due.formatted(date: .omitted, time: .shortened)
        #expect(peeks.shown == [.confirmation(line: "Reminder at \(time)", ear: time, ok: true)])
    }

    @Test func failedReminderPeeksWhyAndPastesNothing() async throws {
        let (model, log, peeks) = routedModel("remind me at 5 to call mom")
        peeks.remindersDenied = true
        try await dictate(model, fromNotch: true)
        try await waitFor { !peeks.shown.isEmpty }
        #expect(peeks.reminders.isEmpty && log.texts.isEmpty)
        guard case .confirmation(let line, _, let ok, let detail)? = peeks.shown.last else { Issue.record("no peek"); return }
        #expect(!ok && line == "Reminder not saved" && detail == "Reminders access is off.")
        #expect(model.status.contains("Privacy & Security"), "the full reason stays in the status line")
    }

    @Test func ordinaryWordsFromTheNotchArePastedUnchanged() async throws {
        let (model, log, peeks) = routedModel("see you at 5")
        try await dictate(model, fromNotch: true)
        #expect(log.texts == ["See you at 5"], "delivered as any dictation (the text rules add the capital)")
        #expect(peeks.shown.isEmpty)
    }

    @Test func bareCommandOutsideTheNotchIsPastedUnchanged() async throws {
        let (model, log, peeks) = routedModel("timer 10 minutes")
        try await dictate(model, fromNotch: false)
        #expect(log.texts == ["Timer 10 minutes"], "delivered as any dictation (the text rules add the capital)")
        #expect(peeks.timers.isEmpty && peeks.shown.isEmpty)
    }

    // MARK: Voice notes anywhere

    @Test func namedNoteFromAnyAppSavesToNotes() async throws {
        let (model, log, peeks) = routedModel("Mouthy, note buy milk.")
        try await dictate(model, fromNotch: false)
        #expect(peeks.notes == ["buy milk"])
        #expect(log.texts.isEmpty, "paste spy never called")
        #expect(model.history.isEmpty, "history is on, yet the command stays out of it")
        #expect(peeks.shown == [.confirmation(line: "Saved to Notes", ear: "Noted", ok: true)], "peeks with the hub closed")
    }

    @Test func namedTimerFromAnyAppStartsTheCountdown() async throws {
        let (model, log, peeks) = routedModel("Mouthy, set a timer for an hour and a half.")
        try await dictate(model, fromNotch: false)
        #expect(peeks.timers == [5_400] && log.texts.isEmpty)
    }

    @Test func unnamedNoteIsNeverIntercepted() async throws {
        let (model, log, peeks) = routedModel("Note that the build failed.")
        try await dictate(model, fromNotch: false)
        #expect(log.texts == ["Note that the build failed."])
        #expect(peeks.notes.isEmpty && peeks.shown.isEmpty)
        #expect(model.history.count == 1, "ordinary dictation still reaches history")
    }

    // MARK: Answers in the notch

    @Test func namedQuestionShowsThinkingThenTheAnswer() async throws {
        let (model, log, peeks) = routedModel("Mouthy, what's 12 times 12?")
        model.voiceRouter.answerer = NotchAnswer(model: StubAnswerModel(reply: "12 times 12 is 144."))
        try await dictate(model, fromNotch: false)
        try await waitFor { model.voiceRouter.answerTask == nil }
        #expect(peeks.shown == [.thinking(question: "what's 12 times 12?"),
                                .answer(question: "what's 12 times 12?", answer: "12 times 12 is 144.")])
        #expect(log.texts.isEmpty && model.history.isEmpty)
        #expect(!model.output.contains("144"), "an answer is never kept for Paste last")
    }

    @Test func questionWithAppleIntelligenceOffShowsHowToTurnItOn() async throws {
        let (model, log, peeks) = routedModel("Mouthy, what's the capital of France?")
        let stub = StubAnswerModel(unavailable: .notEnabled, reply: "Paris")
        model.voiceRouter.answerer = NotchAnswer(model: stub)
        try await dictate(model, fromNotch: true)
        try await waitFor { model.voiceRouter.answerTask == nil }
        #expect(peeks.shown.last == .answer(question: "what's the capital of France?", answer: NotchAnswer.turnOnMessage))
        #expect(stub.asked == 0 && log.texts.isEmpty)
    }

    @Test func cancelWhileThinkingStopsTheModelAndClearsTheCard() async throws {
        let (model, log, peeks) = routedModel("Mouthy, why is the sky orange at sunset?")
        let stub = StubAnswerModel()
        defer { stub.release() }
        model.voiceRouter.answerer = NotchAnswer(model: stub, limit: .seconds(20))
        try await dictate(model, fromNotch: false)
        try await waitFor { stub.asked == 1 }
        #expect(peeks.shown == [.thinking(question: "why is the sky orange at sunset?")])
        let cancelled = Date()
        model.cancel()
        try await waitFor({ model.voiceRouter.answerTask == nil }, seconds: 0.5)
        #expect(Date().timeIntervalSince(cancelled) < 0.5)
        #expect(peeks.shown.last == .cleared)
        #expect(!peeks.shown.contains { if case .answer = $0 { true } else { false } })
        #expect(log.texts.isEmpty && model.history.isEmpty)
    }

    @Test func escapeWhileThinkingStopsTheModelAndClearsTheCard() async throws {
        let (model, log, peeks) = routedModel("Mouthy, why is the sky orange at sunset?")
        let stub = StubAnswerModel()
        defer { stub.release() }
        model.voiceRouter.answerer = NotchAnswer(model: stub, limit: .seconds(20))
        try await dictate(model, fromNotch: false)
        try await waitFor { stub.asked == 1 }
        #expect(model.phase == .idle, "the dictation is over while the question is answered")
        let pressed = Date()
        model.hotkey.onCancel?()   // the global Escape monitor
        try await waitFor({ model.voiceRouter.answerTask == nil }, seconds: 0.5)
        #expect(Date().timeIntervalSince(pressed) < 0.5)
        #expect(peeks.shown.last == .cleared)
        #expect(log.texts.isEmpty && model.history.isEmpty)
    }

    @Test func escapeWithNothingToCancelChangesNothing() async throws {
        let (model, _, peeks) = routedModel("see you at 5")
        try await dictate(model, fromNotch: false)
        let status = model.status
        model.hotkey.onCancel?()
        #expect(model.status == status && peeks.shown.isEmpty)
    }

    @Test func answerArrivingWhileTheHubIsOpenShowsWhenItCloses() async throws {
        let (model, log, peeks) = routedModel("Mouthy, what's 12 times 12?")
        model.voiceRouter.answerer = NotchAnswer(model: StubAnswerModel(reply: "12 times 12 is 144."))
        peeks.setHub(open: true)
        try await dictate(model, fromNotch: false)
        try await waitFor { model.voiceRouter.answerTask == nil }
        #expect(peeks.shown.isEmpty, "an open hub drops peeks, so nothing is sent to it")
        peeks.setHub(open: false)
        try await waitFor { !peeks.shown.isEmpty }
        #expect(peeks.shown == [.answer(question: "what's 12 times 12?", answer: "12 times 12 is 144.")])
        let left = try #require(peeks.seconds.last)
        #expect(left > 10 && left <= NotchVoiceRouter.answerSeconds, "the rest of its 12 s: \(left)")
        #expect(log.texts.isEmpty && model.history.isEmpty)
    }

    @Test func answerWipedByOpeningTheHubComesBackWhenItCloses() async throws {
        let (model, _, peeks) = routedModel("Mouthy, why is the sky orange at sunset?")
        let stub = StubAnswerModel()
        model.voiceRouter.answerer = NotchAnswer(model: stub, limit: .seconds(20))
        try await dictate(model, fromNotch: false)
        try await waitFor { stub.asked == 1 }
        #expect(peeks.shown == [.thinking(question: "why is the sky orange at sunset?")])
        peeks.setHub(open: true)   // opening the hub takes the thinking card down
        stub.release()
        try await waitFor { model.voiceRouter.answerTask == nil }
        #expect(peeks.shown.count == 1, "nothing is shown into the open hub")
        peeks.setHub(open: false)
        try await waitFor { peeks.shown.count == 2 }
        #expect(peeks.shown.last == .answer(question: "why is the sky orange at sunset?", answer: "too late"))
    }

    @Test func expiredAnswerIsNotShownWhenTheHubCloses() async throws {
        let (model, _, peeks) = routedModel("Mouthy, what's 12 times 12?")
        model.voiceRouter.answerer = NotchAnswer(model: StubAnswerModel(reply: "144."))
        model.voiceRouter.answerHold = 0.2
        peeks.setHub(open: true)
        try await dictate(model, fromNotch: false)
        try await waitFor { model.voiceRouter.answerTask == nil }
        try await Task.sleep(for: .milliseconds(300))
        peeks.setHub(open: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(peeks.shown.isEmpty, "past its 12 s, the answer is gone")
    }

    @Test func noteSavedWhileTheHubIsOpenConfirmsWhenItCloses() async throws {
        let (model, log, peeks) = routedModel("Mouthy, note buy milk.")
        peeks.setHub(open: true)
        try await dictate(model, fromNotch: false)
        #expect(peeks.notes == ["buy milk"] && log.texts.isEmpty)
        #expect(peeks.shown.isEmpty)
        peeks.setHub(open: false)
        try await waitFor { !peeks.shown.isEmpty }
        #expect(peeks.shown == [.confirmation(line: "Saved to Notes", ear: "Noted", ok: true)])
    }

    /// Apple's on-device model, end to end: needs Apple Intelligence on. `MOUTHY_TEST_NATIVE=1`.
    @Test func nativeNamedQuestionIsAnsweredOnThisMac() async throws {
        guard ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1" else { return }
        let (model, log, peeks) = routedModel("Mouthy, what is 12 times 12?")
        try await dictate(model, fromNotch: false)
        try await waitFor({ model.voiceRouter.answerTask == nil }, seconds: 25)
        guard case .answer(_, let answer)? = peeks.shown.last else { Issue.record("no answer card"); return }
        #expect(answer.contains("144"), "answer: \(answer)")
        #expect(log.texts.isEmpty)
    }

    /// The confirmation peeks, offscreen. `MOUTHY_RENDER_DIR=<dir>`.
    @Test func voiceCommandPeekRenders() throws {
        guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
        let geometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 944),
                                        notchLeft: 656, notchRight: 856, safeTop: 38)
        Mascot.install()
        let peeks: [(String, VoiceCommandPeek)] = [
            ("timer", VoiceCommandPeek(line: "10-minute timer", ok: true)),
            ("note", VoiceCommandPeek(line: "Saved to Notes", ok: true)),
            ("reminder-failed", VoiceCommandPeek(line: "Reminder not saved", ok: false, detail: "Reminders access is off.")),
        ]
        for (name, peek) in peeks {
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.66), Color(white: 0.48)], startPoint: .top, endPoint: .bottom)
                PeekCard(content: AnyView(peek), notchWidth: geometry.cameraWidth, notchHeight: geometry.notchHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(NotchShape(bottomRadius: NotchMetrics.bottomRadius(for: .peek), shoulder: NotchMetrics.shoulder(for: .peek)).fill(Color.black))
            }
            if let url = try renderOffscreen(view, size: CGSize(width: NotchMetrics.peekWidth + 80, height: 160), name: "voice-command-\(name)", settle: 0.6) { assertNoBlue(url) }
        }
    }

    /// The cards cost nothing while they sit in the notch: each is hosted far off screen (never on a display, no
    /// focus) for 10 s and the process CPU time is read. `MOUTHY_TEST_CPU=1`; gate 1% of one core.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_CPU"] == "1"))
    func voiceCardsCostUnderOnePercent() throws {
        let geometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 944),
                                        notchLeft: 656, notchRight: 856, safeTop: 38)
        Mascot.install()
        func card(_ content: some View) -> AnyView {
            AnyView(PeekCard(content: AnyView(content), notchWidth: geometry.cameraWidth, notchHeight: geometry.notchHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(NotchShape(bottomRadius: NotchMetrics.bottomRadius(for: .peek), shoulder: NotchMetrics.shoulder(for: .peek)).fill(Color.black)))
        }
        let question = "what's 12 times 12?"
        let cards: [(String, AnyView)] = [
            ("thinking card", card(NotchAnswerCard(question: question, answer: nil))),
            ("answer card", card(NotchAnswerCard(question: question, answer: "12 times 12 is 144."))),
            ("timer confirmation", card(VoiceCommandPeek(line: "10-minute timer", ok: true))),
        ]
        var over: [String] = []
        for (name, view) in cards {
            let percent = hostedCPUPercent(view, seconds: 10)
            print(String(format: "CPU %@: %.2f%%", name, percent))
            if percent > 1.0 { over.append(name) }
        }
        #expect(over.isEmpty, "over 1% CPU: \(over.joined(separator: ", "))")
    }
}

private func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// CPU percent of one core while `view` sits in a borderless window far off screen for `seconds`.
@MainActor private func hostedCPUPercent(_ view: some View, seconds: TimeInterval) -> Double {
    let size = CGSize(width: NotchMetrics.peekWidth + 80, height: 200)
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top).environment(\.colorScheme, .dark))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    let before = processCPUSeconds(), started = Date()
    RunLoop.main.run(until: started.addingTimeInterval(seconds))
    let used = processCPUSeconds() - before
    let wall = Date().timeIntervalSince(started)
    window.orderOut(nil)
    window.contentView = nil
    window.close()
    return used / wall * 100
}
