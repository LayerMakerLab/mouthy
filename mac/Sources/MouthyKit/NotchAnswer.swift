import Foundation
import FoundationModels
import NaturalLanguage

/// The language model behind `NotchAnswer`. The app uses Apple's on-device model; tests pass a stub.
public protocol NotchAnswerModel: Sendable {
    /// Nil when the model can answer now.
    var unavailableReason: NotchAnswer.Unavailable? { get }
    func respond(instructions: String, prompt: String) async throws -> String
}

/// Answers one spoken question on this Mac with Apple Intelligence's on-device model: at most two short
/// sentences and 280 characters. The prompt is the question alone; no history, clipboard, screen or app
/// context is sent, and nothing leaves the computer. Every outcome is plain text for the notch, never an
/// error: when Apple Intelligence is off it says how to turn it on, and after `limit` it says there was no
/// answer in time. Returns nil only when the calling task is cancelled.
public struct NotchAnswer: Sendable {
    public enum Unavailable: Sendable, Equatable { case notEnabled, notReady, notEligible }

    public static let maxSentences = 2
    public static let maxCharacters = 280
    public static let defaultLimit: Duration = .seconds(20)
    /// Longest question passed to the model; a spoken question is far shorter.
    static let maxQuestion = 1_000

    public static let instructions = "Answer the question in one or two short sentences of plain text, no lists or formatting. If you are not sure, say so briefly."
    public static let turnOnMessage = "Turn on Apple Intelligence in System Settings to get answers here."
    public static let notReadyMessage = "Apple Intelligence is still getting ready. Try again in a few minutes."
    public static let notEligibleMessage = "Answers need a Mac that supports Apple Intelligence."
    public static let noAnswerMessage = "No answer in time. Try a shorter question."
    public static let emptyMessage = "I didn't catch a question."
    public static let failedMessage = "I couldn't answer that one."

    let model: any NotchAnswerModel
    let limit: Duration

    public init(model: any NotchAnswerModel = OnDeviceAnswerModel(), limit: Duration = NotchAnswer.defaultLimit) {
        self.model = model; self.limit = limit
    }

    public func answer(_ question: String) async -> String? {
        let prompt = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQuestion))
        guard !prompt.isEmpty else { return Self.emptyMessage }
        switch model.unavailableReason {
        case .notEnabled: return Self.turnOnMessage
        case .notReady: return Self.notReadyMessage
        case .notEligible: return Self.notEligibleMessage
        case nil: break
        }
        let model = self.model
        switch await Self.race(limit: limit, { try await model.respond(instructions: Self.instructions, prompt: prompt) }) {
        case .cancelled: return nil
        case .timedOut: return Self.noAnswerMessage
        case .failed: return Self.failedMessage
        case .finished(let text):
            let trimmed = Self.trim(text)
            return trimmed.isEmpty ? Self.failedMessage : trimmed
        }
    }

    /// The first `maxSentences` sentences without markdown emphasis, cut at a word with "…" if still too long.
    public static func trim(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = plain
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: plain.startIndex..<plain.endIndex) { range, _ in
            let sentence = plain[range].trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            return sentences.count < maxSentences
        }
        let joined = sentences.joined(separator: " ")
        guard joined.count > maxCharacters else { return joined }
        let head = joined.prefix(maxCharacters - 1)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    enum Outcome: Sendable { case finished(String), failed, timedOut, cancelled }

    /// Runs `work` against the clock. Resolves on the first of: the work finishing, the limit passing or the
    /// caller cancelling, even when the work ignores cancellation (it is cancelled and left to wind down).
    static func race(limit: Duration, _ work: @escaping @Sendable () async throws -> String) async -> Outcome {
        let gate = Gate()
        let worker = Task { await gate.settle(with: (try? await work()).map(Outcome.finished) ?? .failed) }
        let timer = Task {
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            await gate.settle(with: .timedOut)
        }
        let outcome = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            Task { await gate.settle(with: .cancelled) }
        }
        worker.cancel(); timer.cancel()
        return outcome
    }

    /// Hands out the first outcome once.
    private actor Gate {
        private var outcome: Outcome?
        private var waiter: CheckedContinuation<Outcome, Never>?
        func settle(with value: Outcome) {
            guard outcome == nil else { return }
            outcome = value
            waiter?.resume(returning: value); waiter = nil
        }
        func wait() async -> Outcome {
            if let outcome { return outcome }
            return await withCheckedContinuation { waiter = $0 }
        }
    }
}

/// Apple Intelligence's on-device model (`SystemLanguageModel.default`); never Private Cloud Compute.
public struct OnDeviceAnswerModel: NotchAnswerModel {
    public init() {}
    public var unavailableReason: NotchAnswer.Unavailable? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .notReady
        case .unavailable(.deviceNotEligible): .notEligible
        case .unavailable: .notReady
        }
    }
    public func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: 120))
        return response.content
    }
}
