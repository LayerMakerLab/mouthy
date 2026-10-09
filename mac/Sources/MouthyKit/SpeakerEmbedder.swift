import Accelerate
import CoreML
import Foundation
import MouthyCore

/// WeSpeaker's VoxCeleb ResNet34-LM speaker embedding on the Neural Engine. The Kaldi fbank front end runs in Swift
/// (`KaldiFbank`); the compiled Core ML model holds only the ResNet, with a fixed input of one 2 s window
/// (200 frames × 80 bands, mean-normalized) and a 256-number embedding out. It ships inside Mouthy.app, compiled from
/// Resources/Models/WeSpeakerResNet34LM.mlpackage by build.sh; `bundledModel` finds it.
public final class SpeakerEmbedder: @unchecked Sendable {
    public static let frames = 200
    public static let bands = 80
    public static let dimensions = 256
    /// Samples in one model window: 32 240 at 16 kHz (2.015 s).
    public static let windowSamples = KaldiFbank.sampleCount(frames: frames)
    /// Shorter audio is refused rather than repeated many times over.
    public static let minimumSamples = KaldiFbank.sampleRate / 2

    public enum Failure: Error, Equatable {
        case tooShort(Int)
        case unexpectedOutput
    }

    /// The compiled model inside the app; outside an app (swift test) the copy in Mouthy's support folder's Models/.
    public static var bundledModel: URL? {
        let name = "WeSpeakerResNet34LM.mlmodelc"
        return [Bundle.main.resourceURL?.appendingPathComponent(name),
                LocalStore.supportDirectory.appendingPathComponent("Models/\(name)")]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("coremldata.bin").path) }
    }

    public let model: MLModel
    private let fbank = KaldiFbank(melBins: bands)
    private let lock = NSLock()
    /// One fixed-shape input per model, protected with prediction by `lock`.
    private let input: MLMultiArray
    private let provider: MLDictionaryFeatureProvider

    public init(compiledModel url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.frames), NSNumber(value: Self.bands)], dataType: .float32)
        provider = try MLDictionaryFeatureProvider(dictionary: ["fbank": MLFeatureValue(multiArray: input)])
    }

    /// The embedding of 16 kHz mono `samples` in -1...1. Longer audio uses its middle 2 s; shorter audio (at least
    /// 0.5 s) is repeated to fill the window, the way WeSpeaker pads short chunks in training.
    public func embedding(_ samples: [Float]) throws -> [Float] {
        var features = fbank.features(try Self.window(samples))
        KaldiFbank.subtractMean(&features, bands: Self.bands)
        return try embedding(features: features)
    }

    /// The embedding of one window of fbank features (200 × 80, row-major), already mean-normalized.
    public func embedding(features: [Float]) throws -> [Float] {
        precondition(features.count == Self.frames * Self.bands, "SpeakerEmbedder wants 200 × 80 features")
        return try lock.withLock {
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
                let frameStride = strides[1], bandStride = strides[2]
                if frameStride == Self.bands, bandStride == 1 {
                    features.withUnsafeBufferPointer { buffer.baseAddress!.update(from: $0.baseAddress!, count: features.count) }
                } else {
                    for frame in 0..<Self.frames {
                        for band in 0..<Self.bands {
                            buffer[frame * frameStride + band * bandStride] = features[frame * Self.bands + band]
                        }
                    }
                }
            }
            let output = try model.prediction(from: provider)
            guard let array = output.featureValue(for: "embedding")?.multiArrayValue,
                  array.count == Self.dimensions else { throw Failure.unexpectedOutput }
            if array.dataType == .float32, array.shape.count == 2, array.shape[0].intValue == 1 {
                let stride = array.strides[1].intValue
                return array.withUnsafeBufferPointer(ofType: Float.self) { values in
                    (0..<Self.dimensions).map { values[$0 * stride] }
                }
            }
            return (0..<Self.dimensions).map { array[[0, NSNumber(value: $0)]].floatValue }
        }
    }

    /// Int16-scale samples for exactly one window.
    static func window(_ samples: [Float]) throws -> [Float] {
        guard samples.count >= minimumSamples else { throw Failure.tooShort(samples.count) }
        var window: [Float]
        if samples.count >= windowSamples {
            let start = (samples.count - windowSamples) / 2
            window = Array(samples[start..<start + windowSamples])
        } else {
            window = []
            window.reserveCapacity(windowSamples)
            while window.count < windowSamples {
                window.append(contentsOf: samples.prefix(windowSamples - window.count))
            }
        }
        var scale: Float = 32_768
        vDSP_vsmul(window, 1, &scale, &window, 1, vDSP_Length(window.count))
        return window
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = vDSP.dot(a, b), norms = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
        return norms > 0 ? dot / norms : 0
    }
}
