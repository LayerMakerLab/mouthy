import CoreML
import FluidAudio
import Foundation
import MouthyCore
import Testing
@testable import MouthyKit

/// The Neural Engine speaker model against its PyTorch original. `MOUTHY_TEST_SPEAKER=<folder>` holds
/// `WeSpeakerResNet34LM.mlmodelc` and `reference/` (synthetic `say` clips plus torchaudio fbank and PyTorch embeddings
/// written by `convert.py`, kept with the model's source). `MOUTHY_TEST_BENCHMARK=1` adds latency.
private let speakerFolder = ProcessInfo.processInfo.environment["MOUTHY_TEST_SPEAKER"].map { URL(fileURLWithPath: $0) }

private struct ReferenceWindow: Decodable {
    let clip: String, voice: String, window: Int, start: Int, count: Int, stem: String
}

private func referenceWindows() throws -> [ReferenceWindow] {
    let data = try Data(contentsOf: speakerFolder!.appendingPathComponent("reference/manifest.json"))
    return try JSONDecoder().decode([ReferenceWindow].self, from: data)
}

private func floats(_ name: String) throws -> [Float] {
    let data = try Data(contentsOf: speakerFolder!.appendingPathComponent("reference/\(name)"))
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// 16-bit mono WAV samples at the int16 scale.
private func clipSamples(_ name: String) throws -> [Float] {
    let data = try Data(contentsOf: speakerFolder!.appendingPathComponent("reference/clips/\(name)"))
    var offset = 12
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = Int(data[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        if id == "data" {
            var values = [Int16](repeating: 0, count: size / 2)
            _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0, from: offset + 8..<offset + 8 + size) }
            return values.map(Float.init)
        }
        offset += 8 + size + size % 2
    }
    throw CocoaError(.fileReadCorruptFile)
}

private func embedder(_ units: MLComputeUnits = .cpuAndNeuralEngine) throws -> SpeakerEmbedder {
    try SpeakerEmbedder(compiledModel: speakerFolder!.appendingPathComponent("WeSpeakerResNet34LM.mlmodelc"),
                        computeUnits: units)
}

private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

@Suite(.serialized, .enabled(if: speakerFolder != nil))
struct SpeakerEmbedderTests {
    @Test func simultaneousEmbeddingsDoNotShareMutableInput() async throws {
        let model = try embedder()
        let samples = try clipSamples("Samantha_0.wav").map { $0 / 32_768 }
        let first = Array(samples.prefix(SpeakerEmbedder.windowSamples))
        let second = Array(samples.suffix(SpeakerEmbedder.windowSamples))
        let expected = [try model.embedding(first), try model.embedding(second)]
        try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for index in 0..<16 {
                let input = index.isMultiple(of: 2) ? first : second
                group.addTask { (index % 2, try model.embedding(input)) }
            }
            for try await (index, embedding) in group {
                #expect(SpeakerEmbedder.cosine(expected[index], embedding) > 0.99999)
            }
        }
    }

    @Test func speakerModelRunsOnTheNeuralEngine() async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let url = speakerFolder!.appendingPathComponent("WeSpeakerResNet34LM.mlmodelc")
        let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
        guard case .program(let program) = plan.modelStructure else { Issue.record("not an ML program"); return }
        var cost: [String: Double] = [:], operations: [String: Int] = [:]
        func visit(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                if let usage = plan.deviceUsage(for: operation) {
                    let device: String
                    switch usage.preferred {
                    case .neuralEngine: device = "Neural Engine"
                    case .gpu: device = "GPU"
                    case .cpu: device = "CPU"
                    @unknown default: device = "other"
                    }
                    operations[device, default: 0] += 1
                    cost[device, default: 0] += plan.estimatedCost(of: operation)?.weight ?? 0
                }
                for inner in operation.blocks { visit(inner) }
            }
        }
        for (_, function) in program.functions { visit(function.block) }
        let share = (cost["Neural Engine"] ?? 0) / max(cost.values.reduce(0, +), 1e-12)
        print("speaker plan: Neural Engine \(String(format: "%.4f", share * 100))% of cost; ops \(operations)")
        #expect(share >= 0.95)
    }

    @Test func swiftFbankMatchesTorchaudio() throws {
        let fbank = KaldiFbank()
        var worst: Float = 0, clips: [String: [Float]] = [:]
        for window in try referenceWindows() {
            if clips[window.clip] == nil { clips[window.clip] = try clipSamples(window.clip) }
            let samples = Array(clips[window.clip]![window.start..<window.start + window.count])
            let ours = fbank.features(samples), theirs = try floats("\(window.stem).fbank.f32")
            #expect(ours.count == theirs.count)
            worst = max(worst, zip(ours, theirs).map { abs($0 - $1) }.max() ?? .infinity)
        }
        print("speaker fbank: largest difference from torchaudio \(worst) over \(clips.count) clips")
        #expect(worst < 0.01)
    }

    @Test func neuralEngineEmbeddingsMatchPyTorch() throws {
        let model = try embedder(), fbank = KaldiFbank()
        var cosines: [Float] = [], clips: [String: [Float]] = [:]
        for window in try referenceWindows() {
            if clips[window.clip] == nil { clips[window.clip] = try clipSamples(window.clip) }
            var features = fbank.features(Array(clips[window.clip]![window.start..<window.start + window.count]))
            KaldiFbank.subtractMean(&features, bands: 80)
            let ours = try model.embedding(features: features)
            cosines.append(SpeakerEmbedder.cosine(ours, try floats("\(window.stem).embedding.f32")))
        }
        print("speaker embeddings vs PyTorch: min cosine \(cosines.min()!), mean \(cosines.reduce(0, +) / Float(cosines.count)) over \(cosines.count) windows")
        #expect(cosines.allSatisfy { $0 >= 0.99 })
    }

    /// Same voice (different sentences) against different voices, for 2 s windows and for the 1.536 s windows
    /// Only my voice scores today (repeated to fill the model's window), next to FluidAudio's WeSpeaker on the latter.
    @Test func voicesSeparate() throws {
        let model = try embedder()
        let windows = try referenceWindows()
        var clips: [String: [Float]] = [:]
        for window in windows where clips[window.clip] == nil { clips[window.clip] = try clipSamples(window.clip) }
        var embedders: [(String, Int, ([Float]) throws -> [Float])] = [
            ("Neural Engine ResNet34-LM", SpeakerEmbedder.windowSamples, { try model.embedding($0) }),
            ("Neural Engine ResNet34-LM", 6 * 4_096, { try model.embedding($0) }),
        ]
        let current = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models/speaker-diarization-coreml/wespeaker_v2.mlmodelc")
        if let fluid = try? MLModel(contentsOf: current),
           let frames = fluid.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.last?.intValue {
            let extractor = EmbeddingExtractor(embeddingModel: fluid)
            embedders.append(("current FluidAudio WeSpeaker", 6 * 4_096, {
                try extractor.getEmbeddings(audio: $0, masks: [[Float](repeating: 1, count: frames)])[0]
            }))
        }
        for (name, length, embed) in embedders {
            var items: [(voice: String, clip: String, embedding: [Float])] = []
            for window in windows {
                let samples = clips[window.clip]![window.start..<window.start + length].map { $0 / 32_768 }
                items.append((window.voice, window.clip, try embed(samples)))
            }
            var same: [Float] = [], different: [(Float, String)] = []
            for i in items.indices { for j in items.indices where j > i && items[i].clip != items[j].clip {
                let score = SpeakerEmbedder.cosine(items[i].embedding, items[j].embedding)
                if items[i].voice == items[j].voice { same.append(score) }
                else { different.append((score, "\(items[i].voice)/\(items[j].voice)")) }
            } }
            let others = different.map(\.0)
            func summary(_ v: [Float]) -> String {
                String(format: "min %.3f mean %.3f max %.3f (n=%d)", v.min()!, v.reduce(0, +) / Float(v.count), v.max()!, v.count)
            }
            // Pairs on the wrong side of the best single threshold.
            let wrong = (same + others).map { t in same.filter { $0 < t }.count + others.filter { $0 >= t }.count }.min()!
            let closest = different.max { $0.0 < $1.0 }!
            print("speaker separation, \(name), \(length) samples: same voice \(summary(same)); different voices \(summary(others)); "
                  + "closest different pair \(closest.1); \(wrong) of \(same.count + others.count) pairs wrong at the best threshold")
            let gap = same.reduce(0, +) / Float(same.count) - others.reduce(0, +) / Float(others.count)
            if name.hasPrefix("Neural") { #expect(gap > 0.4) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_BENCHMARK"] == "1"))
    func speakerLatency() throws {
        let samples = try clipSamples("Samantha_0.wav").map { $0 / 32_768 }
        let fbank = KaldiFbank()
        // New: Swift fbank plus the ResNet on the Neural Engine, one 2 s window.
        let neural = try embedder(.cpuAndNeuralEngine), cpu = try embedder(.cpuOnly)
        let window = try SpeakerEmbedder.window(Array(samples[3_200..<3_200 + SpeakerEmbedder.windowSamples]))
        var features: [Float] = []
        var fbankTimes: [Double] = [], neuralTimes: [Double] = [], cpuTimes: [Double] = []
        for run in 0..<60 {
            let f = milliseconds { features = fbank.features(window); KaldiFbank.subtractMean(&features, bands: 80) }
            let n = try milliseconds { _ = try neural.embedding(features: features) }
            let c = try milliseconds { _ = try cpu.embedding(features: features) }
            if run >= 10 { fbankTimes.append(f); neuralTimes.append(n); cpuTimes.append(c) }
        }
        // Current: FluidAudio's WeSpeaker v2 (waveform [3, 160000] + mask) as VoicePrint calls it, one 1.536 s window.
        let current = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models/speaker-diarization-coreml/wespeaker_v2.mlmodelc")
        var currentTimes: [Double] = []
        if FileManager.default.fileExists(atPath: current.path) {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: current, configuration: configuration)
            let frames = model.modelDescription.inputDescriptionsByName["mask"]!.multiArrayConstraint!.shape.last!.intValue
            let extractor = EmbeddingExtractor(embeddingModel: model)
            let piece = Array(samples[3_200..<3_200 + 6 * 4_096])
            for run in 0..<25 {
                let t = try milliseconds { _ = try extractor.getEmbeddings(audio: piece, masks: [[Float](repeating: 1, count: frames)]) }
                if run >= 5 { currentTimes.append(t) }
            }
        }
        print(String(format: "speaker latency (median ms): fbank %.3f, ResNet Neural Engine %.3f, ResNet CPU only %.3f, current FluidAudio WeSpeaker %.3f",
                     median(fbankTimes), median(neuralTimes), median(cpuTimes), currentTimes.isEmpty ? .nan : median(currentTimes)))
    }
}
