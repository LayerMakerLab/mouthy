import Testing
import MouthyCore

@Test func microphoneWaveformIsFlatForSilenceAndNoiseFloor() {
    for samples in [[Float](), Array(repeating: Float(0), count: 480), Array(repeating: Float(0.001), count: 480)] {
        #expect(samples.withUnsafeBufferPointer { MicrophoneFrame.measure($0) } == .silence)
    }
}

@Test func microphoneWaveformUsesInputAndRemainsBounded() {
    var samples = [Float](repeating: 0.2, count: 400)
    for i in 200..<400 { samples[i] = -0.3 }
    let frame = samples.withUnsafeBufferPointer { MicrophoneFrame.measure($0) }
    #expect(frame.level > 0)
    #expect(frame.samples.count == MicrophoneFrame.pointCount)
    #expect(frame.samples.prefix(20).allSatisfy { $0 > 0 })
    #expect(frame.samples.suffix(20).allSatisfy { $0 < 0 })
    #expect(frame.samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
    #expect([Float.nan, .infinity].withUnsafeBufferPointer { MicrophoneFrame.measure($0) } == .silence)
}
