import Testing
@testable import MouthyKit

// The stop shortcut's key clicks and music resuming after the stop must never reach the recognizer.
@Test func audioAfterTheStopShortcutIsDropped() {
    let samples = [Float](repeating: 0.1, count: 48_000)   // 3 s
    // Recording ended 0.4 s after the stop gesture began: the last 0.4 s goes.
    #expect(SpeechService.trim(samples, recordedUntil: 100.4, cutAt: 100.0).count == 48_000 - 6_400)
    // A stop requested after recording ended keeps everything.
    #expect(SpeechService.trim(samples, recordedUntil: 100.0, cutAt: 100.2).count == 48_000)
    // A wrong clock never eats more than 2 s.
    #expect(SpeechService.trim(samples, recordedUntil: 500, cutAt: 100).count == 48_000 - 32_000)
}
