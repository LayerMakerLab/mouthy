import Foundation

/// A small, bounded picture of real PCM input, never a generated animation.
public struct MicrophoneFrame: Sendable, Equatable {
    public static let pointCount = 40
    public static let silence = MicrophoneFrame(level: 0, samples: Array(repeating: 0, count: pointCount))
    public let level: Float
    public let samples: [Float]

    public static func measure(_ input: UnsafeBufferPointer<Float>, stride: Int = 1) -> MicrophoneFrame {
        guard stride > 0, input.count >= stride else { return .silence }
        let count = input.count / stride
        var energy: Double = 0
        for i in 0..<count {
            let value = input[i * stride]
            if value.isFinite { energy += Double(value) * Double(value) }
        }
        let rms = Float(sqrt(energy / Double(count)))
        // Suppress the microphone noise floor; silence and disconnected/stopped input stay flat.
        guard rms > 0.002 else { return .silence }
        var points = [Float](repeating: 0, count: pointCount)
        for bin in 0..<pointCount {
            let start = bin * count / pointCount
            let end = max(start + 1, (bin + 1) * count / pointCount)
            var peak: Float = 0
            for i in start..<min(end, count) {
                let value = input[i * stride]
                if value.isFinite && abs(value) > abs(peak) { peak = value }
            }
            points[bin] = tanh(peak * 7)
        }
        return MicrophoneFrame(level: min(1, rms * 8), samples: points)
    }
}
