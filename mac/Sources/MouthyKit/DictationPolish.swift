import Foundation
import FoundationModels
import MouthyCore

/// On-device polish and rewrite for host apps, with Apple's Foundation Models (Apple Intelligence) through Mouthy's own
/// cleanup (`TextEnhancer`): nothing leaves the Mac. Mouthy's guards hold: at most 8,000 characters of text and 2,000 of
/// instructions, a 20 s limit, and the original text comes back unchanged when the model times out, refuses, or returns
/// something that is not an edit of it (`PolishGuard`): for polish, under half or over twice as long, a lost name or
/// number, under half its content words kept, any new name, number, URL, path, flag or command word, or over 20% new
/// content words; for a rewrite, empty, under a fifth or over three times the selection, any URL, path, flag, command
/// word or number not in the selection or instruction, or over 60% new content words.
/// `context` is fenced as read-only reference the model is told never to follow (it may be a terminal screen with
/// text written to steer it; the newest 2,000 characters are used). A result equal to the input therefore means
/// "nothing changed". Hosts can compare the two for a diff.
@MainActor public enum DictationPolish {
    public enum Failure: Error, Equatable, LocalizedError {
        /// Apple Intelligence is off, still downloading, or not supported on this Mac.
        case unavailable
        /// The text is over 8,000 characters or the instructions over 2,000.
        case tooLong

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "Apple Intelligence is off or not ready on this Mac. Turn it on in System Settings to polish on-device."
            case .tooLong: return "On-device polish takes up to 8,000 characters and 2,000 characters of instructions."
            }
        }
    }

    nonisolated public static let maximumText = 8_000
    nonisolated public static let maximumInstructions = 2_000
    /// Longer and the original is kept, as Mouthy's own cleanup does.
    nonisolated public static let timeout: Duration = .seconds(20)

    /// Instructions for a spoken brief to an AI agent (done on-device).
    nonisolated public static let promptInstructions = "The text is a spoken brief for an AI coding agent. Rewrite it as a clear, well-organized prompt in the speaker's own voice: fix grammar and punctuation, and drop filler, repetition and false starts. Keep every name, file, command, number, date, time and requirement exactly as given. Do not answer, plan or carry out the request, and add nothing new."

    /// Whether Apple's on-device model can run now.
    public static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Loads the on-device model ahead of a polish (call it at key-down) so the first one skips most of the cold start.
    public static func prewarm() { TextEnhancer.prewarm() }

    /// Polishes dictated `text` with `instructions` (`promptInstructions` by default). `context` (for example a pane's
    /// name and its last lines) only informs the model and is never repeated. Mouthy's "scratch that" (`Backtrack`) and
    /// spoken value corrections ("at three. No, make it four." → "at four.", `SpokenCorrection`) are applied first,
    /// because the on-device model keeps both values. Throws `Failure` before calling the model; every model failure
    /// returns `text` unchanged. Cancelling the calling task throws `CancellationError`.
    public static func polish(_ text: String, instructions: String = promptInstructions, context: String = "") async throws -> String {
        try await polish(text, instructions: instructions, context: context, timeout: timeout, available: isAvailable) { prepared, instructions, context in
            try await TextEnhancer.edit(prepared, mode: .custom, customInstructions: instructions, context: context, fenced: true)
        }
    }

    /// Rewrites `selection` by a spoken `instruction` ("make this shorter"), Mouthy's selection rewrite. Throws `Failure`
    /// before calling the model; a timeout, refusal or empty result returns `selection` unchanged.
    public static func rewrite(selection: String, instruction: String, context: String = "") async throws -> String {
        try await rewrite(selection: selection, instruction: instruction, context: context, timeout: timeout, available: isAvailable) {
            try await TextEnhancer.rewrite(selection: $0, instruction: $1, context: $2, fenced: true)
        }
    }

    /// Text, instructions, context → the model's answer.
    typealias Model = @MainActor (String, String, String) async throws -> String

    /// What goes to the model: the text with spoken corrections applied.
    static func prepare(_ text: String) -> String {
        SpokenCorrection.apply(Backtrack.apply(text)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func polish(_ text: String, instructions: String, context: String, timeout: Duration, available: Bool,
                       model: @escaping Model) async throws -> String {
        let prepared = prepare(text)
        guard !prepared.isEmpty else { return text }
        guard prepared.count <= maximumText, instructions.count <= maximumInstructions else { throw Failure.tooLong }
        guard available else { throw Failure.unavailable }
        switch await TextEnhancer.bounded(timeout: timeout, { try await model(prepared, instructions, context) }) {
        case .done(let result):
            let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return PolishGuard.acceptsPolish(result, of: prepared) ? result : text
        case .failed:
            if Task.isCancelled { throw CancellationError() }
            return text
        case .timedOut:
            return text
        }
    }

    static func rewrite(selection: String, instruction: String, context: String, timeout: Duration, available: Bool,
                        model: @escaping Model) async throws -> String {
        guard selection.count <= maximumText, instruction.count <= maximumInstructions else { throw Failure.tooLong }
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return selection }
        guard available else { throw Failure.unavailable }
        switch await TextEnhancer.bounded(timeout: timeout, { try await model(selection, instruction, context) }) {
        case .done(let result):
            let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return PolishGuard.acceptsRewrite(result, of: selection, instruction: instruction, maximum: maximumText) ? result : selection
        case .failed:
            if Task.isCancelled { throw CancellationError() }
            return selection
        case .timedOut:
            return selection
        }
    }
}
