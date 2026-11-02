import Accelerate
import AppKit
import CoreML
import Foundation
import MouthyCore
import Security

/// WeSpeaker's VoxCeleb ResNet34-LM speaker embedding on the Neural Engine. The Kaldi fbank front end runs in Swift
/// (`KaldiFbank`); the compiled Core ML model holds only the ResNet, with a fixed input of one 2 s window
/// (200 frames × 80 bands, mean-normalized) and a 256-number embedding out. It ships inside Mouthy.app, compiled from
/// Resources/Models/WeSpeakerResNet34LM.mlpackage by build.sh; `bundledModel` finds it there, in a host app's own
/// resources or in Mouthy's support folder.
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

    public static let modelName = "WeSpeakerResNet34LM.mlmodelc"
    /// Where the compiled model is looked for, in order: the running app's resources (Mouthy.app, or a host app that
    /// bundles it), Mouthy's support folder `~/Library/Application Support/Mouthy/Models/` (swift test, or a copy put
    /// there for host apps), then an installed Mouthy.app's resources (release, then Dev), read in place and only when
    /// the host named the team that signs Mouthy (`trustedTeamID`) and that app's code signature is valid for it
    /// (`trustsInstalledApp`): a Dev build signed locally, or a look-alike app claiming Mouthy's bundle identifier, is
    /// skipped. With no team named, installed apps are never read.
    public static var modelLocations: [URL] { ownLocations + installedLocations }
    static var ownLocations: [URL] {
        [Bundle.main.resourceURL?.appendingPathComponent(modelName),
         LocalStore.supportDirectory.appendingPathComponent("Models/\(modelName)")].compactMap { $0 }
    }
    static var installedLocations: [URL] {
        guard trustedTeamID != nil else { return [] }
        return ["dev.mouthy.Mouthy", "dev.mouthy.Mouthy.dev"].compactMap { identifier in
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier), trustsInstalledApp(at: app) else { return nil }
            return app.appendingPathComponent("Contents/Resources/\(modelName)")
        }
    }

    /// The Developer ID team that signs the Mouthy releases a host app may read the model from, set by the host
    /// before its first lookup (Mouthy itself never needs it: its model is in its own resources). Nil, the default,
    /// trusts no installed app. Changing it forgets earlier verdicts.
    public static var trustedTeamID: String? {
        get { trustLock.withLock { team } }
        set { trustLock.withLock { team = newValue?.isEmpty == true ? nil : newValue; trustCache.removeAll() } }
    }
    nonisolated(unsafe) private static var team: String?

    /// The decision: another app's model is loaded only from a bundle whose whole signature (resources included, so
    /// the model inside is sealed) checks out against the trusted team.
    static func trusts(validSignature: Bool, teamID: String?, trusted: String? = trustedTeamID) -> Bool {
        guard let trusted else { return false }
        return validSignature && teamID == trusted
    }

    /// Checks `app`'s signature once per signed state (its CodeResources' date) and remembers the answer.
    static func trustsInstalledApp(at app: URL) -> Bool {
        guard let trusted = trustedTeamID else { return false }
        let seal = app.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: seal.path)[.modificationDate] as? Date) ?? nil
        let key = app.standardizedFileURL.path
        if let known = trustLock.withLock({ team == trusted ? trustCache[key] : nil }), known.stamp == stamp { return known.trusted }
        let signature = signature(ofApp: app, team: trusted)
        let verdict = trusts(validSignature: signature.valid, teamID: signature.teamID, trusted: trusted)
        trustLock.withLock { if team == trusted { trustCache[key] = (stamp, verdict) } }
        return verdict
    }
    nonisolated(unsafe) private static var trustCache: [String: (stamp: Date?, trusted: Bool)] = [:]
    private static let trustLock = NSLock()

    /// Whether `app`'s code signature is valid (all architectures, strict, every sealed resource) for an Apple-issued
    /// certificate of `team`, and the team it names.
    static func signature(ofApp app: URL, team: String) -> (valid: Bool, teamID: String?) {
        guard (1...20).contains(team.count), team.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else { return (false, nil) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return (false, nil) }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { return (false, nil) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let valid = SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        return (valid, team)
    }

    /// The first compiled model in `modelLocations`, or nil when none is on this Mac. Installed apps are looked up only
    /// when the first two places have none.
    public static var bundledModel: URL? { firstModel(in: ownLocations) ?? firstModel(in: installedLocations) }

    static func firstModel(in locations: [URL]) -> URL? {
        locations.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("coremldata.bin").path) }
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
