import Foundation

/// Whether the microphone sends anything at all. A real microphone always hears some room noise; input that never rises
/// above `MicrophoneFrame`'s noise floor (exact digital zeros, or near-silence under about -54 dBFS RMS, so every level
/// is 0) means the input is muted, turned down to zero or blocked, and "nothing was heard" would blame the person.
/// Mouthy's dictation (`AppModel`) and host apps' `DictationSession` both keep one per recording.
public struct MicrophoneSilence: Sendable, Equatable {
    /// A recording this long with no signal is reported as a silent microphone when it ends with no words.
    public static let reportAfter: TimeInterval = 2
    /// While recording, a warning after this long with no signal at all.
    public static let warnAfter: TimeInterval = 4

    /// Any level above the noise floor since `start`.
    public private(set) var heardSignal = false
    /// When listening began (any monotonic clock, in seconds); nil before.
    public private(set) var startedAt: TimeInterval?

    public init() {}

    /// A new recording began listening at `time`.
    public mutating func start(at time: TimeInterval) {
        heardSignal = false
        startedAt = time
    }

    /// One microphone level (0...1, already 0 under the noise floor).
    public mutating func receive(level: Float) {
        if level > 0 { heardSignal = true }
    }

    /// True when listening began at least `seconds` before `now` and no level above the noise floor arrived since.
    public func isSilent(at now: TimeInterval, after seconds: TimeInterval) -> Bool {
        guard let startedAt, !heardSignal else { return false }
        return now - startedAt >= seconds
    }
}
