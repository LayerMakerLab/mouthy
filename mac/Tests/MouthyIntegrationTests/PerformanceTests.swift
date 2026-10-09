import Testing
import Foundation
import Darwin
import MouthyCore
@testable import MouthyKit

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_BENCHMARK"] == "1"))
@MainActor func localEngineMemoryAndLatency() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["MOUTHY_TEST_AUDIO"])
    let file = URL(fileURLWithPath: path)
    let service = SpeechService()
    print("PERFORMANCE baseline_rss_bytes=\(residentBytes())")
    for engine in SpeechEngine.allCases {
        for iteration in 0..<4 {
            let start = ContinuousClock.now
            let text = try await service.transcribeFile(file, locale: "en-US", vocabulary: "", provider: engine, status: { _ in })
            let seconds = start.duration(to: .now).components
            let duration = Double(seconds.seconds) + Double(seconds.attoseconds) / 1e18
            let fixtureRecognized = ["garden", "coffee", "meeting"].allSatisfy { text.lowercased().contains($0) }
            #expect(fixtureRecognized)
            print("PERFORMANCE engine=\(engine.rawValue) iteration=\(iteration) seconds=\(duration) rss_bytes=\(residentBytes()) fixture=\(fixtureRecognized)")
        }
        await ParakeetRecognizer.shared.releaseIfIdle()
        await WhisperRecognizer.shared.releaseIfIdle()
        try await Task.sleep(for: .seconds(2))
        print("PERFORMANCE released=\(engine.rawValue) rss_bytes=\(residentBytes())")
    }
}
