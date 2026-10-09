import Foundation
import Testing
@testable import MouthyKit

@Test func usageCacheDropsExpiredSamplesAndDeletedFiles() throws {
    try UsageScanner.lock.withLock {
        let saved = UsageScanner.cache
        UsageScanner.cache = [:]
        defer { UsageScanner.cache = saved }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-usage-cache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), file = root.appendingPathComponent("rollout.jsonl")
        func line(_ date: Date, _ tokens: Int) -> String {
            "{\"timestamp\":\"\(date.ISO8601Format())\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(tokens)}}}}\n"
        }
        try (line(now.addingTimeInterval(-8 * 86400), 500) + line(now.addingTimeInterval(-1), 20))
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(UsageScanner.codex(now: now, root: root)?.week == 20)
        #expect(UsageScanner.cache.count == 1)
        #expect(UsageScanner.cache.values.flatMap(\.samples).count == 1)
        #expect(UsageScanner.codex(now: now, root: root)?.week == 20, "an unchanged log is not counted twice")
        try FileManager.default.removeItem(at: file)
        #expect(UsageScanner.codex(now: now, root: root) == nil)
        #expect(UsageScanner.cache.isEmpty)
    }
}

@Test func replacedUsageLogResetsCountsAndSupportsLimitsWithoutTokenTotals() throws {
    try UsageScanner.lock.withLock {
        let saved = UsageScanner.cache
        UsageScanner.cache = [:]
        defer { UsageScanner.cache = saved }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-usage-replace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), file = root.appendingPathComponent("rollout.jsonl")
        let date = now.addingTimeInterval(-1).ISO8601Format()
        let original = "{\"timestamp\":\"\(date)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":500}}}}\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        #expect(UsageScanner.codex(now: now, root: root)?.week == 500)
        let replacement = "{\"timestamp\":\"\(date)\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":12,\"window_minutes\":300}}}}\n"
        try replacement.write(to: file, atomically: true, encoding: .utf8)
        let summary = try #require(UsageScanner.codex(now: now, root: root))
        #expect(summary.week == 0 && summary.limits.first?.percent == 12)
    }
}

@Test func usageSummaryExcludesFutureSamplesFromEveryWindow() {
    let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
    let summary = UsageScanner.summarize("Test", [UsageScanner.Sample(date: now.addingTimeInterval(30), tokens: 500),
                                                  .init(date: now.addingTimeInterval(-30), tokens: 7)], limits: [], now: now)
    #expect(summary.fiveHours == 7 && summary.today == 7 && summary.week == 7)
    #expect(summary.hourly.reduce(0, +) == 7)
}
