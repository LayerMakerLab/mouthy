import Testing
import Foundation
@testable import MouthyKit

/// MOUTHY_TEST_LIVE=<16 kHz wav> [MOUTHY_TEST_VOCABULARY=terms]: stop-to-text with live recognition against
/// recognizing everything after the stop. Run as release (`swift test -c release -Xswiftc -enable-testing`);
/// debug builds overstate FluidAudio's vocabulary pass about twice.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_LIVE"] != nil))
func liveStopToTextLatency() async throws {
    let env = ProcessInfo.processInfo.environment
    let result = try await LiveBenchmark.run(file: URL(fileURLWithPath: env["MOUTHY_TEST_LIVE"]!), vocabulary: env["MOUTHY_TEST_VOCABULARY"] ?? "")
    print("LIVE before: recognize everything after the stop = \(result.wholeMilliseconds) ms")
    for run in result.runs {
        print("LIVE after: stop \(run.stopDelay) ms after the last word = \(run.milliseconds) ms")
        print("LIVE text: \(run.text)")
        #expect(!run.text.isEmpty)
    }
    print("LIVE whole: \(result.whole)")
}
