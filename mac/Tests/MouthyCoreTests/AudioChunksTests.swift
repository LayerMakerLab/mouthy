import Testing
@testable import MouthyCore

@Test func chunksCoverAudioAndCutInQuiet() {
    var samples = [Float](repeating: 0.5, count: 16_000 * 60)
    for i in (16_000 * 22)..<(16_000 * 22 + 3_200) { samples[i] = 0 }
    let parts = AudioChunks.ranges(samples, maxSamples: 16_000 * 25)
    #expect(parts.first?.lowerBound == 0 && parts.last?.upperBound == samples.count)
    #expect(parts[0].upperBound > 16_000 * 22 && parts[0].upperBound < 16_000 * 22 + 3_200)
    #expect(zip(parts, parts.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    #expect(AudioChunks.ranges([], maxSamples: 100).isEmpty)
}
