import Foundation

/// What the notch shows while a host is dictating.
public struct NotchDictation: Equatable, Sendable {
    /// Where the words will go, e.g. "Atlas" or "Notes".
    public var target: String
    public var level: Float
    public var partialText: String
    public var transcribing: Bool
    /// An agent's question shown above the live text while the person answers it out loud.
    public var prompt: String?
    /// When listening began; the band counts up from it.
    public var startedAt: Date?
    public init(target: String, level: Float = 0, partialText: String = "", transcribing: Bool = false, prompt: String? = nil, startedAt: Date? = nil) {
        self.target = target; self.level = level; self.partialText = partialText; self.transcribing = transcribing; self.prompt = prompt
        self.startedAt = startedAt
    }
}
