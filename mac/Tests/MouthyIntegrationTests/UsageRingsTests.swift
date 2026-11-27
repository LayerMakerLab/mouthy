import Foundation
import MouthyCore
import SQLite3
import SwiftUI
import Testing
@testable import MouthyKit

/// The AI usage tab with the person's picks: which writes wake which service, paging, the fullest window, OpenCode's
/// costs read from its database, and renders (`MOUTHY_RENDER_DIR`).
@Suite(.serialized) @MainActor struct UsageRingsTests {
    @Test func writesWakeTheirOwnServiceOnly() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(UsageTab.service(for: home + "/.codex/sessions/2026/11/19/x.jsonl") == .chatgpt)
        #expect(UsageTab.service(for: home + "/.local/share/opencode/opencode.db-wal") == .opencode)
        // Mouthy's own read-only read touches the shared-memory index: that must never wake OpenCode.
        #expect(UsageTab.service(for: home + "/.local/share/opencode/opencode.db-shm") == nil)
        #expect(UsageTab.service(for: home + "/.local/share/opencode") == nil)
        #expect(UsageTab.service(for: home + "/.gemini/antigravity/conversations/a") == .gemini)
        #expect(UsageTab.service(for: home + "/.grok/x") == .grok)
        #expect(UsageTab.service(for: ClaudeLimitsBridge.file.path) == .claude)
        #expect(UsageTab.service(for: ClaudeLimitsBridge.folder.appendingPathComponent("preferences.json").path) == nil)
        #expect(UsageTab.service(for: home + "/.codexfoo/x") == nil)
    }

    @Test func awakeThenAsleepAndPagesTurnWithinTheTab() {
        let tab = UsageTab.shared
        tab.setPicks([.claude, .chatgpt, .opencode, .gemini])
        defer { tab.setPicks(nil) }
        let now = Date()
        tab.noteActivity(.gemini, at: now, now: now)
        #expect(tab.awake.contains(.gemini))
        tab.noteActivity(.gemini, at: .distantPast, now: now.addingTimeInterval(11 * 60))
        #expect(!tab.awake.contains(.gemini))
        #expect(tab.pageCount == 2)
        #expect(tab.page(1) && tab.page == 1)
        #expect(!tab.page(1))                 // at the end: the hub moves to the next tab
        #expect(tab.page(-1) && tab.page == 0)
        #expect(!tab.page(-1))
    }

    @Test func picksMadeAfterAttachingStartWatchingAndKeepTheirSleep() {
        let tab = UsageTab.shared
        defer { tab.stopWatching(); tab.setPicks(nil) }
        tab.setPicks(nil)
        tab.startWatching()                    // a fresh install: nothing picked, nothing to watch
        #expect(tab.isWatching)
        tab.setPicks([.grok])                  // picked later: still watching, with the new service
        #expect(tab.isWatching)
        tab.noteActivity(.grok, at: Date())
        tab.setPicks([.grok, .gemini])         // a restart keeps grok awake, with its sleep scheduled again
        #expect(tab.awake.contains(.grok) && tab.hasSleeper(for: .grok))
        tab.setPicks([.gemini])
        #expect(!tab.awake.contains(.grok))
    }

    /// Another tool's file can hold any number: none of them may reach a whole-number conversion as it is.
    @Test func aLimitFromAFileIsHeldToASanePercent() {
        #expect(UsageLimit(percent: 1e300, resets: nil).percent == 999 && UsageLimit(percent: .infinity, resets: nil).percent == 0)
        #expect(UsageLimit(percent: .nan, resets: nil).percent == 0 && UsageLimit(percent: -5, resets: nil).percent == 0)
        #expect(UsageLimit(percent: 42.4, resets: nil).percent == 42.4)
        #expect(Int(UsageLimit(percent: 1e300, resets: nil).current().rounded()) == 999)
    }

    @Test func theRingFollowsTheFullestWindow() {
        let limits = ServiceLimits(week: UsageLimit(percent: 30, resets: nil), fiveHour: UsageLimit(percent: 75, resets: nil))
        #expect(limits.binding?.percent == 75 && limits.binding?.window == "5-hour")
        #expect(ServiceLimits(week: nil, fiveHour: nil).binding == nil)
    }

    @Test func openCodeCostsComeFromItsDatabaseReadOnly() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-\(UUID()).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let now = Date(), ms = { (d: Date) in Int64(d.timeIntervalSince1970 * 1000) }
        let rows = [
            "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)",
            "INSERT INTO message VALUES ('a','s',\(ms(now.addingTimeInterval(-600))),0,'{\"role\":\"assistant\",\"providerID\":\"opencode-go\",\"cost\":1.5}')",
            "INSERT INTO message VALUES ('d','s',\(ms(now.addingTimeInterval(-400))),0,'{\"role\":\"assistant\",\"providerID\":\"anthropic\",\"cost\":4}')",
            "INSERT INTO message VALUES ('b','s',\(ms(now.addingTimeInterval(-500))),0,'{\"role\":\"user\"}')",
            "INSERT INTO message VALUES ('c','s',\(ms(now.addingTimeInterval(-90 * 86400))),0,'{\"role\":\"assistant\",\"providerID\":\"opencode-go\",\"cost\":9}')",
        ]
        for sql in rows { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        sqlite3_close(db)
        let costs = try #require(OpenCodeCosts.read(since: now.addingTimeInterval(-30 * 86400), path: path))
        #expect(costs.count == 1 && costs[0].dollars == 1.5)   // another provider's $4 is not Go's
        let limits = ServiceLimits(openCodeCosts: costs, now: now)
        #expect(limits.fiveHour?.percent == 12.5)    // $1.50 of $12
        #expect(OpenCodeCosts.read(since: now, path: path + ".missing") == nil)
    }

    @Test func ringsRenderForReview() throws {
        let quarter = ServiceLimits(week: UsageLimit(percent: 25, resets: nil), fiveHour: UsageLimit(percent: 10, resets: nil))
        let maxed = ServiceLimits(week: UsageLimit(percent: 100, resets: nil), fiveHour: nil)
        let row = HStack(spacing: 12) {
            ServiceRing(service: .claude, limits: quarter, awake: true)
            ServiceRing(service: .chatgpt, limits: maxed, awake: true)
            ServiceRing(service: .opencode, limits: ServiceLimits(week: UsageLimit(percent: 62, resets: nil), fiveHour: nil), awake: false)
            ServiceRing(service: .gemini, limits: nil, awake: false)
        }.padding(16).background(Color.black)
        if let url = try renderOffscreen(row, size: CGSize(width: 520, height: 150), name: "usage-rings") { assertNoBlue(url) }
        let picker = UsagePicker(model: UsageTab.shared).padding(16).frame(width: 520, height: 170).background(Color.black)
        if let url = try renderOffscreen(picker, size: CGSize(width: 520, height: 170), name: "usage-picker") { assertNoBlue(url) }
    }
}

extension UsageRingsTests {
    /// On a Mac with OpenCode idle: Mouthy's own reads of its database must not wake it (`MOUTHY_TEST_USAGE_LIVE=1`;
    /// reads `~/.local/share/opencode/opencode.db` read-only, writes nothing).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_USAGE_LIVE"] == "1")) func ownReadsDoNotWakeOpenCode() async throws {
        let tab = UsageTab.shared
        let wal = UsageTab.openCodeRoot + "/opencode.db-wal"
        let lastWrite = (try? FileManager.default.attributesOfItem(atPath: wal)[.modificationDate] as? Date) ?? .distantPast
        try #require(Date().timeIntervalSince(lastWrite) > AIActivity.awakeFor, "OpenCode wrote recently; run this while it is idle")
        tab.setPicks([.opencode]); tab.startWatching()
        defer { tab.stopWatching(); tab.setPicks(nil) }
        for _ in 0..<3 { tab.refresh(force: true, scanOpenCode: true); try await Task.sleep(for: .seconds(4)) }
        #expect(!tab.awake.contains(.opencode))
        print("OpenCode ring: \(tab.opencode?.binding.map { "\(Int($0.percent))% of \($0.window)" } ?? "no data")")
    }
}

@Test func theOuterRingIsTheFullerOfWeekAndMonth() {
    let soon = Date().addingTimeInterval(3_600), past = Date().addingTimeInterval(-60)
    func limit(_ percent: Double, _ resets: Date? = nil) -> UsageLimit { UsageLimit(percent: percent, resets: resets ?? soon) }
    // OpenCode Go has all three: with steady use the month is the fuller, and the number in the middle (the limit
    // closest to its cap) is then one the rings show.
    let three = ServiceLimits(week: limit(33), fiveHour: limit(8), month: limit(67))
    #expect(three.long?.name == "month" && three.long?.percent == 67 && three.binding?.percent == 67)
    let weekFuller = ServiceLimits(week: limit(80), fiveHour: limit(8), month: limit(40))
    #expect(weekFuller.long?.name == "week" && weekFuller.long?.percent == 80)
    // One long limit, or none; a limit whose reset has passed counts as empty.
    #expect(ServiceLimits(week: limit(23), fiveHour: limit(12)).long?.name == "week")
    #expect(ServiceLimits(week: nil, fiveHour: limit(12), month: limit(5)).long?.name == "month")
    #expect(ServiceLimits(week: nil, fiveHour: limit(12)).long == nil)
    #expect(ServiceLimits(week: limit(90, past), fiveHour: limit(12), month: limit(30)).long?.name == "month")
}
