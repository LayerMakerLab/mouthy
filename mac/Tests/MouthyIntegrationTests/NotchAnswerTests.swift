import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MouthyKit
@testable import MouthyNotch

/// A stand-in model: records what it was asked and answers with fixed text, or never answers.
private final class StubModel: NotchAnswerModel, @unchecked Sendable {
    let unavailable: NotchAnswer.Unavailable?
    let reply: String?
    private let lock = NSLock()
    private var held: [UnsafeContinuation<Void, Never>] = []
    private(set) var prompts: [String] = []
    private(set) var instructions: [String] = []

    init(unavailable: NotchAnswer.Unavailable? = nil, reply: String? = nil) {
        self.unavailable = unavailable; self.reply = reply
    }
    var unavailableReason: NotchAnswer.Unavailable? { unavailable }
    func respond(instructions: String, prompt: String) async throws -> String {
        lock.withLock { self.prompts.append(prompt); self.instructions.append(instructions) }
        if let reply { return reply }
        // Never answers and ignores cancellation, like a stuck model.
        await withUnsafeContinuation { continuation in lock.withLock { held.append(continuation) } }
        return "too late"
    }
    /// Lets any stuck call finish so no task outlives the test.
    func release() { lock.withLock { held.forEach { $0.resume() }; held = [] } }
}

@Test func notchAnswerExplainsHowToTurnOnAppleIntelligence() async {
    let model = StubModel(unavailable: .notEnabled, reply: "unused")
    let reply = await NotchAnswer(model: model).answer("What is the capital of France?")
    #expect(reply == NotchAnswer.turnOnMessage)
    #expect(reply?.contains("Apple Intelligence") == true && reply?.contains("System Settings") == true)
    #expect(model.prompts.isEmpty, "an unavailable model is never asked")
    let notReady = await NotchAnswer(model: StubModel(unavailable: .notReady)).answer("Hi?")
    #expect(notReady == NotchAnswer.notReadyMessage)
    let notEligible = await NotchAnswer(model: StubModel(unavailable: .notEligible)).answer("Hi?")
    #expect(notEligible == NotchAnswer.notEligibleMessage)
}

@Test func notchAnswerKeepsTwoShortSentencesAtMost() async {
    let long = "**Paris** is the capital of France. It sits on the Seine in the north of the country. It has been the capital for centuries. "
        + String(repeating: "More words here. ", count: 40)
    let reply = await NotchAnswer(model: StubModel(reply: long)).answer("What is the capital of France?")
    #expect(reply == "Paris is the capital of France. It sits on the Seine in the north of the country.")
    let rambling = String(repeating: "word ", count: 120) + "end. Second sentence."
    let cut = await NotchAnswer(model: StubModel(reply: rambling)).answer("Why?") ?? ""
    #expect(!cut.isEmpty && cut.count <= NotchAnswer.maxCharacters)
    #expect(cut.hasSuffix("…"))
    #expect(!cut.contains("  "))
    // Decimals and abbreviations are not sentence ends.
    #expect(NotchAnswer.trim("Pi is about 3.14 and e.g. used in circles. Second one. Third one.") == "Pi is about 3.14 and e.g. used in circles. Second one.")
}

@Test func notchAnswerGivesUpQuietlyAfterTheLimit() async {
    let model = StubModel()
    defer { model.release() }
    let clock = ContinuousClock(), start = clock.now
    let reply = await NotchAnswer(model: model, limit: .milliseconds(300)).answer("What is 12 times 12?")
    #expect(reply == NotchAnswer.noAnswerMessage)
    #expect(clock.now - start < .milliseconds(1_500))
}

@Test func notchAnswerStopsWithinHalfASecondOfCancelling() async throws {
    let model = StubModel()
    defer { model.release() }
    let task = Task { await NotchAnswer(model: model, limit: .seconds(20)).answer("What is 12 times 12?") }
    try await Task.sleep(for: .milliseconds(200))
    let clock = ContinuousClock(), start = clock.now
    task.cancel()
    let reply = await task.value
    #expect(clock.now - start < .milliseconds(500))
    #expect(reply == nil, "a cancelled question has no reply")
}

@Test func notchAnswerPromptIsTheQuestionOnly() async {
    let model = StubModel(reply: "144.")
    _ = await NotchAnswer(model: model).answer("  what is 12 times 12\n")
    #expect(model.prompts == ["what is 12 times 12"])
    #expect(model.instructions == [NotchAnswer.instructions], "instructions are fixed text, never context")
    let empty = await NotchAnswer(model: model).answer("   ")
    #expect(empty == NotchAnswer.emptyMessage)
    #expect(model.prompts.count == 1, "an empty question is never sent")
}

/// MOUTHY_TEST_NATIVE=1: the real on-device model answers a simple question.
@Test func notchAnswerOnDeviceModelAnswers() async {
    guard ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1" else { return }
    let reply = await NotchAnswer().answer("what is 12 times 12")
    #expect(reply?.contains("144") == true, "got \(reply ?? "nil")")
    #expect((reply?.count ?? 999) <= NotchAnswer.maxCharacters)
}

/// MOUTHY_RENDER_DIR=<dir>: the answer card as the hovered peek shows it under the notch (answer, thinking,
/// and the Apple Intelligence notice).
@MainActor @Test func notchAnswerRenders() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
    let geometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 944),
                                    notchLeft: 656, notchRight: 856, safeTop: 38)
    Mascot.install()
    let question = "What's the tallest animal in the world?"
    let cards: [(String, NotchAnswerCard)] = [
        ("answer", NotchAnswerCard(question: question, answer: NotchAnswer.trim("The giraffe is the tallest animal, often reaching about 5.5 metres. Its long neck lets it eat leaves other animals can't reach. It also has a long tongue."))),
        ("thinking", NotchAnswerCard(question: question, answer: nil)),
        ("turn-on", NotchAnswerCard(question: question, answer: NotchAnswer.turnOnMessage)),
    ]
    for (name, card) in cards {
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.66), Color(white: 0.48)], startPoint: .top, endPoint: .bottom)
            PeekCard(content: AnyView(card), notchWidth: geometry.cameraWidth, notchHeight: geometry.notchHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(NotchShape(bottomRadius: NotchMetrics.bottomRadius(for: .peek), shoulder: NotchMetrics.shoulder(for: .peek)).fill(Color.black))
        }
        if let url = try renderOffscreen(view, size: CGSize(width: NotchMetrics.peekWidth + 80, height: 200), name: "notch-answer-\(name)", settle: 0.6) { assertNoBlue(url) }
    }
}
