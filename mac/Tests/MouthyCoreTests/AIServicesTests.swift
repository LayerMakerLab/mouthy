import Foundation
import Testing
@testable import MouthyCore

@Suite struct AIServicesTests {
    @Test func ringFillIsExactlyProportionalAndFullWhenMaxed() {
        #expect(ringFill(percent: 25) == 0.25)
        #expect(ringFill(percent: 50) == 0.5)
        #expect(ringFill(percent: 100) == 1)
        #expect(ringFill(percent: 140) == 1)
        #expect(ringFill(percent: -3) == 0)
        #expect(ringFill(percent: .nan) == 0)
    }

    @Test func awakeForTenMinutesAfterTheLastWrite() {
        let now = Date()
        #expect(AIActivity.isAwake(lastActivity: now.addingTimeInterval(-60), now: now))
        #expect(!AIActivity.isAwake(lastActivity: now.addingTimeInterval(-11 * 60), now: now))
        #expect(!AIActivity.isAwake(lastActivity: nil, now: now))
        #expect(!AIActivity.isAwake(lastActivity: now.addingTimeInterval(3600), now: now))   // a clock in the future
    }

    @Test func openCodeGoPercentsUseRollingWindows() {
        let now = Date()
        let costs: [(date: Date, dollars: Double)] = [
            (now.addingTimeInterval(-3600), 3),          // inside 5 h
            (now.addingTimeInterval(-2 * 86400), 6),     // inside week
            (now.addingTimeInterval(-20 * 86400), 6),    // inside month
            (now.addingTimeInterval(-40 * 86400), 50),   // too old
        ]
        let p = OpenCodeGo.percents(costs: costs, now: now)
        #expect(p.fiveHour == 25)          // $3 of $12
        #expect(p.week == 30)              // $9 of $30
        #expect(p.month == 25)             // $15 of $60
        #expect(OpenCodeGo.nextDrop(costs: costs, window: 5 * 3600, now: now) == now.addingTimeInterval(-3600 + 5 * 3600))
    }

    @Test func picksSurviveSavingAndUnknownNamesAreKept() throws {
        var prefs = Preferences()
        #expect(prefs.aiServices == nil && prefs.aiPicks.isEmpty)
        prefs.aiServices = ["grok", "someday-ai", "claude"]
        #expect(prefs.aiPicks == [.claude, .grok])
        prefs.aiPicks = [.claude, .opencode]
        #expect(prefs.aiServices == ["claude", "opencode", "someday-ai"])
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.aiServices == ["claude", "opencode", "someday-ai"])
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{\"notchHub\": true}".utf8))
        #expect(old.aiServices == nil)
    }
}
