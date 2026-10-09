import CoreML
import Darwin
import FluidAudio
import Foundation
import Testing
import MouthyCore
@testable import MouthyKit

// MOUTHY_TEST_MEMORY=1 swift test -c release -Xswiftc -enable-testing --filter ModelMemoryTests
// Only the selected engine stays warm (zero wait at the next dictation); switching engines releases the others.
// One serialized suite: the tests load the shared recognizers, so run in parallel they would read each other's
// models. The gate asserts only what does not move with machine load or test order: which models are held after
// every switch, the bytes malloc reports in use (what is really alive) per round, and that released holds less than
// warm. Footprint (phys_footprint, Activity Monitor's Memory) and RSS move with load, because macOS malloc keeps some
// freed pages dirty, so they are printed as information only. Needs Parakeet (and checks Whisper base.en when it is
// on this Mac). MOUTHY_MEMORY_ROUNDS sets the switching rounds (default 16).
// Needs the real model cache, so it fails on `ParakeetRecognizer.installed` under CFFIXED_USER_HOME.
// Negative control: MOUTHY_MEMORY_LEAK_MB=1 keeps that many MB alive every round; the suite must then fail.

private struct Memory {
    let footprint: Double, inUse: Double, resident: Double
    static func now() -> Memory {
        malloc_zone_pressure_relief(nil, 0)  // hand freed pages back first, so released memory shows
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let ok = result == KERN_SUCCESS
        return Memory(footprint: ok ? Double(info.phys_footprint) / 1_048_576 : -1, inUse: Double(stats.size_in_use) / 1_048_576,
                      resident: ok ? Double(info.resident_size) / 1_048_576 : -1)
    }
    var text: String { String(format: "%.1f MB, RSS %.1f MB (%.1f MB in use by malloc)", footprint, resident, inUse) }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_MEMORY"] == "1"))
struct ModelMemoryTests {
    @Test func latestEngineWinsWhileAnotherModelWarms() async throws {
        try #require(ParakeetRecognizer.installed)
        for delay in [1, 5, 10] {
            await SpeechModels.keepOnly(.apple, whisperModel: .baseEnglish, vocabulary: "")
            let warming = Task { await SpeechModels.keepOnly(.parakeet, whisperModel: .baseEnglish, vocabulary: "") }
            try await Task.sleep(for: .milliseconds(delay))
            await SpeechModels.keepOnly(.apple, whisperModel: .baseEnglish, vocabulary: "")
            await warming.value
            #expect(await !ParakeetRecognizer.shared.loaded, "choosing Apple during warm-up must release the earlier model (\(delay) ms switch)")
        }
        await SpeechModels.keepOnly(.apple, whisperModel: .baseEnglish, vocabulary: "")
    }

    @Test func selectingAppleReleasesTheLocalVoiceDetector() async throws {
        try #require(VoiceActivity.model != nil, "the local voice detector must be cached for this memory gate")
        await VoiceActivity.shared.prepare()
        #expect(await VoiceActivity.shared.loaded)
        await SpeechModels.keepOnly(.apple, whisperModel: .baseEnglish, vocabulary: "")
        #expect(await !VoiceActivity.shared.loaded)
    }

    @Test func modelMemoryKeepsOnlyTheSelectedEngine() async throws {
        try #require(ParakeetRecognizer.installed, "download Parakeet first")
        let whisper = WhisperModel.baseEnglish
        let engines: [SpeechEngine] = WhisperRecognizer.installed(whisper) ? [.parakeet, .whisper] : [.parakeet]
        let vocabulary = "Mouthy\nLayerMaker\nParakeet"
        let start = Memory.now()
        var peaks: [Double] = [], live: [Double] = [], released: [Memory] = []
        let rounds = max(8, Int(ProcessInfo.processInfo.environment["MOUTHY_MEMORY_ROUNDS"] ?? "") ?? 16)
        let leakBytes = Int((Double(ProcessInfo.processInfo.environment["MOUTHY_MEMORY_LEAK_MB"] ?? "") ?? 0) * 1_048_576)
        var leaked: [[UInt8]] = []
        defer { print("memory: negative control kept \(leaked.count) blocks of \(leakBytes) bytes") }
        for round in 1...rounds {
            var peak = 0.0, peakLive = 0.0
            if leakBytes > 0 { leaked.append([UInt8](repeating: UInt8(round & 0xff), count: leakBytes)) }
            for engine in engines + [.apple] {
                await SpeechModels.keepOnly(engine, whisperModel: whisper, vocabulary: vocabulary)
                let parakeet = await ParakeetRecognizer.shared.loaded, whisperHeld = await WhisperRecognizer.shared.loaded
                #expect(parakeet == (engine == .parakeet), "round \(round), \(engine): Parakeet held = \(parakeet)")
                #expect(whisperHeld == (engine == .whisper), "round \(round), \(engine): Whisper held = \(whisperHeld)")
                let now = Memory.now()
                peak = max(peak, now.footprint); peakLive = max(peakLive, now.inUse)
                if engine == .apple { released.append(now) }
                print("memory: round \(round), \(engine.rawValue) selected: \(now.text)")
            }
            peaks.append(peak); live.append(peakLive)
        }
        func list(_ values: [Double]) -> String { values.map { String(format: "%.1f", $0) }.joined(separator: " / ") }
        let livePerRound = (live.last! - live[1]) / Double(rounds - 2)
        let releasedPerRound = (released.last!.inUse - released[1].inUse) / Double(rounds - 2)
        print("memory: start \(start.text), footprint peak per round \(list(peaks)), RSS released \(list(released.map(\.resident)))")
        print("memory: in use per round \(list(live)), released \(list(released.map(\.inUse)))")
        print(String(format: "memory: information only: footprint rose %.1f MB after round 1; gate: %.3f MB a round in use, %.3f MB a round released",
                     peaks.last! - peaks[1], livePerRound, releasedPerRound))
        // What stays alive is FluidAudio 0.17.4's own Parakeet load and cleanup, not Mouthy's (switchResidualByLoad).
        // The negative control keeps 1 MB a round and fails here.
        #expect(livePerRound < 0.5 && releasedPerRound < 0.5, "nothing a switch loads may stay alive: in use \(live), released \(released.map(\.inUse))")
        // Released means gone: with every local model released, malloc holds far less than with one warm.
        #expect(released.last!.inUse < live.last! - 5, "a released model must leave: warm \(live.last!) MB, released \(released.last!.text)")
    }

    // Where the live bytes a switch leaves come from: the same rounds with FluidAudio's own Parakeet load and cleanup
    // (no Mouthy code), then Mouthy's prepare and release with its vocabulary spotter, then Whisper. Mouthy's rounds
    // may leave at most a little more than the bare FluidAudio load does.
    @Test func switchResidualByLoad() async throws {
        try #require(ParakeetRecognizer.installed, "download Parakeet first")
        await SpeechModels.keepOnly(.apple, whisperModel: .baseEnglish, vocabulary: "")
        let rounds = 8
        func perRound(_ name: String, _ round: () async throws -> Void) async rethrows -> Double {
            var live: [Double] = []
            for _ in 0..<rounds { try await round(); live.append(Memory.now().inUse) }
            let growth = (live.last! - live[1]) / Double(rounds - 2)
            print(String(format: "memory: %@ leaves %.3f MB a round in use (%@)", name, growth,
                         live.map { String(format: "%.2f", $0) }.joined(separator: " ")))
            return growth
        }
        let compiled = try FileManager.default.contentsOfDirectory(at: ParakeetRecognizer.modelFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mlmodelc" }
        let coreML = try await perRound("Core ML load of its \(compiled.count) models") {
            for url in compiled { _ = try MLModel(contentsOf: url, configuration: ParakeetRecognizer.configuration ?? MLModelConfiguration()) }
        }
        let bare = try await perRound("FluidAudio load and cleanup") {
            let models = try await AsrModels.load(from: ParakeetRecognizer.modelFolder, configuration: ParakeetRecognizer.configuration, version: .v3)
            let manager = AsrManager()
            try await manager.loadModels(models)
            await manager.cleanup()
        }
        let mouthy = await perRound("Parakeet selected, then Apple") {
            await SpeechModels.keepOnly(.parakeet, whisperModel: .baseEnglish, vocabulary: "Mouthy\nLayerMaker\nParakeet")
            await SpeechModels.keepOnly(.apple, whisperModel: .baseEnglish, vocabulary: "")
        }
        if WhisperRecognizer.installed(.baseEnglish) {
            _ = await perRound("Whisper selected, then Apple") {
                await SpeechModels.keepOnly(.whisper, whisperModel: .baseEnglish, vocabulary: "")
                await SpeechModels.keepOnly(.apple, whisperModel: .baseEnglish, vocabulary: "")
            }
        }
        #expect(mouthy < max(bare, 0) + 0.25, "Mouthy's switch must leave no more than FluidAudio's own load: \(mouthy) against \(bare) MB a round (Core ML alone \(coreML))")
    }

    // Which load holds memory while Parakeet is selected: each load the app makes (the model with its dictation
    // manager, a first recognition, the vocabulary spotter, Silero, a dictation's background passes), then releasing
    // them. Synthetic speech only.
    @Test func memoryBreakdownParakeet() async throws {
        try #require(ParakeetRecognizer.installed, "download Parakeet first")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let speech = try Corpus.say("Please send the Mouthy notes to LayerMaker before the meeting on Friday.", in: folder)
        await SpeechModels.keepOnly(.apple, whisperModel: .baseEnglish, vocabulary: "")
        await ParakeetRecognizer.shared.releaseIfIdle(); await VoiceActivity.shared.releaseIfIdle()
        var steps: [(String, Memory)] = [("start", Memory.now())]
        func step(_ name: String) {
            steps.append((name, Memory.now()))
            print("memory: \(name) \(steps.last!.1.text)")
        }
        try await ParakeetRecognizer.shared.prepare(download: false) { _ in }
        step("parakeet loaded")
        _ = try await ParakeetRecognizer.shared.transcribe(samples: speech, boost: false)
        step("first recognition")
        _ = try await ParakeetRecognizer.shared.transcribe(samples: speech, boost: false)
        step("second recognition")
        await ParakeetRecognizer.shared.setVocabulary("Mouthy\nLayerMaker\nParakeet")
        _ = try await ParakeetRecognizer.shared.transcribe(samples: speech)
        step("vocabulary spotter")
        await VoiceActivity.shared.prepare()
        _ = await VoiceActivity.shared.hearsSpeech(speech)
        step("silero")
        // A dictation's background passes: every pause recognizes the open part again, a different length each time.
        let long = Array((0..<6).map { _ in speech + Corpus.silence(0.4) }.joined())
        func cpuSeconds() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let clock = ContinuousClock(), cpu = cpuSeconds()
        let elapsed = try await clock.measure {
            for pass in 0..<40 {
                let length = min(long.count, 8_000 + (pass * 7_919) % (8 * 16_000))
                _ = try await ParakeetRecognizer.shared.transcribe(samples: Array(long[..<length]), boost: false)
                _ = await VoiceActivity.shared.hearsSpeech(Array(long[..<length]))
            }
        }
        print(String(format: "memory: 40 passes took %.0f ms, %.0f ms of CPU", Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15, (cpuSeconds() - cpu) * 1000))
        step("40 background passes")
        await ParakeetRecognizer.shared.releaseIfIdle(); await VoiceActivity.shared.releaseIfIdle()
        try await Task.sleep(for: .milliseconds(300))
        step("released")
        let text = zip(steps.dropFirst(), steps).map { String(format: "%@ %+.1f (%+.1f in use)", $0.0.0, $0.0.1.footprint - $0.1.1.footprint, $0.0.1.inUse - $0.1.1.inUse) }
        print("memory breakdown (MB): start \(steps[0].1.text), " + text.joined(separator: ", "))
        let warm = steps[steps.count - 2].1, start = steps[0].1, released = steps.last!.1
        print("memory: information only: Parakeet warm with its spotter and Silero \(warm.text)")
        #expect(released.inUse - start.inUse < 3, "releasing must free what the loads hold: start \(start.text), released \(released.text)")
    }
}
