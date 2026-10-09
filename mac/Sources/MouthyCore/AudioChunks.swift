import Foundation

/// Splits long 16 kHz audio near quiet moments into pieces of at most `maxSamples`, so long
/// recordings can be transcribed piece by piece without cutting words.
public enum AudioChunks {
    public static func ranges(_ samples: [Float], maxSamples: Int) -> [Range<Int>] {
        guard !samples.isEmpty, maxSamples > 0 else { return [] }
        let frame = 1_600 // 100 ms
        var out: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            var end = min(start + maxSamples, samples.count)
            if end < samples.count {
                // Look back up to 5 s for the quietest 100 ms and cut in its middle.
                var best = (energy: Float.greatestFiniteMagnitude, cut: end)
                var i = max(start + frame, end - frame * 50)
                while i + frame <= end {
                    var energy: Float = 0
                    for j in i..<(i + frame) { energy += samples[j] * samples[j] }
                    if energy < best.energy { best = (energy, i + frame / 2) }
                    i += frame
                }
                end = best.cut
            }
            out.append(start..<end)
            start = end
        }
        return out
    }
}
