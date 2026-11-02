import Testing
import Foundation
@testable import MouthyCore

/// Levels from synthetic frames, measured the way capture measures them.
private func level(_ samples: [Float]) -> Float {
    samples.withUnsafeBufferPointer { MicrophoneFrame.measure($0).level }
}

/// Pure digital zeros and near-silence under the noise floor are both a silent microphone; room noise and speech are not.
@Test func silentMicrophoneFromZeroAndLowLevelFrames() {
    let zeros = [Float](repeating: 0, count: 1_600)
    let nearSilence = (0..<1_600).map { Float(sin(Double($0) * 0.3)) * 0.0015 }   // about -59 dBFS RMS
    let roomNoise = (0..<1_600).map { Float(sin(Double($0) * 0.3)) * 0.01 }
    #expect(level(zeros) == 0)
    #expect(level(nearSilence) == 0)
    #expect(level(roomNoise) > 0)

    var silence = MicrophoneSilence()
    #expect(!silence.isSilent(at: 100, after: MicrophoneSilence.warnAfter), "nothing is silent before listening starts")
    silence.start(at: 10)
    for _ in 0..<60 { silence.receive(level: level(zeros)); silence.receive(level: level(nearSilence)) }
    #expect(!silence.isSilent(at: 13.9, after: MicrophoneSilence.warnAfter))
    #expect(silence.isSilent(at: 14, after: MicrophoneSilence.warnAfter))
    #expect(silence.isSilent(at: 12, after: MicrophoneSilence.reportAfter))

    silence.receive(level: level(roomNoise))
    #expect(silence.heardSignal)
    #expect(!silence.isSilent(at: 30, after: MicrophoneSilence.warnAfter))

    // A new recording starts clean.
    silence.start(at: 40)
    #expect(!silence.heardSignal)
    #expect(silence.isSilent(at: 44, after: MicrophoneSilence.warnAfter))
}
