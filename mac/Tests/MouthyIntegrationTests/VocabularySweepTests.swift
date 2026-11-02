import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import MouthyKit

/// Diagnostic, not a gate: prints what Parakeet's vocabulary pass does with each rescorer setting on the given
/// clips, so a threshold change is chosen from measurements. MOUTHY_TEST_VOCAB_SWEEP=1, MOUTHY_TEST_VOCAB_CLIPS =
/// colon-separated 16 kHz WAVs, MOUTHY_TEST_VOCAB_TERMS = the vocabulary, one term per line.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_VOCAB_SWEEP"] == "1"))
func vocabularyRescorerSweep() async throws {
    let env = ProcessInfo.processInfo.environment
    let clips = try #require(env["MOUTHY_TEST_VOCAB_CLIPS"]).split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    let words = try #require(env["MOUTHY_TEST_VOCAB_TERMS"]).split(separator: "\n").map(String.init).filter { $0.count >= 3 }
    let models = try await AsrModels.load(from: ParakeetRecognizer.modelFolder, configuration: ParakeetRecognizer.configuration, version: .v3)
    let manager = AsrManager()
    try await manager.loadModels(models)
    let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
    let ctc = try await CtcModels.load(from: directory, variant: .ctc110m)
    let tokenizer = try await CtcTokenizer.load(from: directory)
    let terms = words.compactMap { word -> CustomVocabularyTerm? in
        let ids = tokenizer.encode(word)
        return ids.isEmpty ? nil : CustomVocabularyTerm(text: word, ctcTokenIds: ids)
    }
    var rescues: [(String, VocabularyRescorer.Config)] = [
        ("rescue default", .default),
        ("rescue floors", VocabularyRescorer.Config(spotterRescueMinSimilarity: 0.30, spotterRescueMultiWordMinSimilarity: 0.50)),
    ]
    for pivot in [4, 5, 6] {
        for exponent: Float in [1, 2] {
            rescues.append(("floors taper \(pivot)^\(exponent)", VocabularyRescorer.Config(
                shortTermCbwTaperPivot: pivot, shortTermCbwTaperExponent: exponent,
                spotterRescueMinSimilarity: 0.30, spotterRescueMultiWordMinSimilarity: 0.50)))
        }
    }
    for clip in clips {
        let samples = try AudioConverter().resampleAudioFile(clip)
        var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.v3.decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        print("SWEEP \(clip.lastPathComponent) PLAIN: \(result.text)")
        for similarity: Float in [0.75, 0.6, 0.5] {
            for (name, config) in rescues {
                let context = CustomVocabularyContext(terms: terms, alpha: 1.0, minCtcScore: -15, minSimilarity: similarity, minCombinedConfidence: 0.45)
                let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc, config: config)
                let out = await session.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples)
                let swaps = out?.replacements.filter(\.shouldReplace).map { "\($0.originalWord)->\($0.replacementWord ?? "")" } ?? []
                print("SWEEP \(clip.lastPathComponent) sim \(similarity) \(name): \(out?.wasModified == true ? out!.text : "(unchanged)") \(swaps)")
            }
        }
    }
}
