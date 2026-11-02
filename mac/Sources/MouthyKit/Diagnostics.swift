import os

/// Diagnostic log for cut-offs and stalls: phases, engines, failures, capture changes and sample counts.
/// Read with `log show --predicate 'subsystem == "dev.mouthy.Mouthy"'`. Never text or audio.
enum Diagnostics {
    static let dictation = Logger(subsystem: "dev.mouthy.Mouthy", category: "dictation")
    /// Talk sessions: provider, model, state changes and close reasons only. Never keys, audio or words.
    static let talk = Logger(subsystem: "dev.mouthy.Mouthy", category: "talk")
}
