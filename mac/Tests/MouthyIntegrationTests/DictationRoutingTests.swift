import Testing
import Foundation
import AppKit
import MouthyCore
@testable import MouthyNotch
@testable import MouthyKit

// MARK: Outcome words

@Test func deliveryStatusesMapToOutcomeWordsAndApps() {
    let cases: [(String, DictationOutcome.Kind, String)] = [
        ("Inserted into Notes.", .success, "Inserted · Notes"),
        ("Pasted into Terminal.", .success, "Pasted · Terminal"),
        ("Pasted into Slack. Not sent, because focus changed.", .success, "Pasted · Slack"),
        ("Sent in Messages.", .success, "Sent · Messages"),
        ("Answer sent to the agent.", .success, "Sent to the agent"),
        ("Sent to the agent.", .success, "Sent to the agent"),
        ("Copied to the clipboard.", .success, "Copied"),
        ("Saved to history.", .success, "Saved to history"),
        ("Inserted into Notes. Cleanup unavailable; original wording preserved.", .success, "Inserted · Notes")
    ]
    for (status, kind, text) in cases {
        let outcome = DictationOutcome.from(status: status, failed: false, target: "Mouthy workspace")
        #expect(outcome.kind == kind, "\(status)")
        #expect(outcome.text == text, "\(status) -> \(outcome.text)")
    }
}

@Test func bareSentEndsOnACheckMarkWithTheTarget() {
    let outcome = DictationOutcome.from(status: "Sent.", failed: false, target: "Notes")
    #expect(outcome.kind == .success)
    #expect(outcome.text == "Sent · Notes")
    // No usable target: just the word.
    #expect(DictationOutcome.from(status: "Sent.", failed: false, target: "Mouthy workspace").text == "Sent")
}

@Test func refusalsNeedAttention() {
    let cases: [(String, String)] = [
        ("Ready to copy. A password field is active; nothing was inserted.", "Not into a password field"),
        ("Ready to copy. No other app is focused.", "Nowhere to type"),
        ("Ready to copy. Focus changed before pasting.", "The cursor moved"),
        ("Ready to copy. The selection changed, so the rewrite was not applied.", "The selection changed"),
        ("Ready to copy. Enable Accessibility for automatic insertion.", "Needs Accessibility"),
        ("Transcription timed out.", "That took too long")
    ]
    for (status, text) in cases {
        let outcome = DictationOutcome.from(status: status, failed: false, target: "Notes")
        #expect(outcome.kind == .attention, "\(status)")
        #expect(outcome.text == text, "\(status) -> \(outcome.text)")
    }
    #expect(DictationOutcome.from(status: "Something odd", failed: true, target: "Notes").kind == .attention)
}

@Test func nothingSaidShowsNothing() {
    for status in ["No speech detected. Nothing was inserted.", "No speech detected; the agent was told.", "No final transcript.", "No text to insert."] {
        #expect(DictationOutcome.from(status: status, failed: false, target: "Notes") == .quiet, "\(status)")
    }
}

@Test func cancelledIsQuietAndUnknownStatusesShowNothing() {
    let cancelled = DictationOutcome.from(status: "Cancelled. Nothing was inserted.", failed: false, target: "Notes")
    #expect(cancelled.kind == .neutral && cancelled.text == "Cancelled")
    #expect(DictationOutcome.from(status: "Listening…", failed: false, target: "Notes") == .quiet)
    #expect(DictationOutcome.from(status: "Ready.", failed: false, target: "Notes") == .quiet)
    #expect(DictationOutcome.quiet.holdMilliseconds < DictationOutcome(kind: .success, text: "x").holdMilliseconds)
    #expect(DictationOutcome(kind: .success, text: "x").holdMilliseconds == 900)
}

@Test func appNameIsReadFromTheStatus() {
    #expect(DictationOutcome.appName(in: "Inserted into Notes.") == "Notes")
    #expect(DictationOutcome.appName(in: "Sent in Messages.") == "Messages")
    #expect(DictationOutcome.appName(in: "Inserted into Visual Studio Code.") == "Visual Studio Code")
    #expect(DictationOutcome.appName(in: "Copied to the clipboard.") == nil)
}

// MARK: Routing

@Test func recordingDisplayRoutesToTheHubOnlyWhenItRuns() {
    #expect(OverlayRoute.decide(showOverlay: true, hubRunning: true, headless: false) == .hub)
    #expect(OverlayRoute.decide(showOverlay: true, hubRunning: false, headless: false) == .island)
    // A full-screen app hides the hub; the island (which joins full-screen spaces) takes over.
    #expect(OverlayRoute.decide(showOverlay: true, hubRunning: true, headless: false, hubHiddenForFullScreen: true) == .island)
    #expect(OverlayRoute.decide(showOverlay: false, hubRunning: true, headless: false) == .none)
    #expect(OverlayRoute.decide(showOverlay: true, hubRunning: true, headless: true) == .none)
}

/// One surface: the island and a visible hub shape (the notch band or an external pill) are never up together.
/// Every combination that shows the island has the hub off screen; every combination with the hub on screen
/// routes the dictation into it.
@Test func islandNeverStacksOnAVisibleHub() {
    for running in [false, true] {
        for hidden in [false, true] {
            let hubOnScreen = running && !hidden
            let route = OverlayRoute.decide(showOverlay: true, hubRunning: running, headless: false, hubHiddenForFullScreen: hidden)
            #expect(!(route == .island && hubOnScreen), "island over a visible hub: running \(running), hidden \(hidden)")
            #expect(hubOnScreen == (route == .hub))
        }
    }
}

@Test func modelPhasesBecomeNotchPillStates() {
    let listening = OverlayController.notchState(phase: .listening, level: 0.4, liveText: "hello", question: nil, target: "Notes")
    #expect(listening == NotchDictation(target: "Notes", level: 0.4, partialText: "hello"))
    let preparing = OverlayController.notchState(phase: .preparing, level: 0.9, liveText: "", question: nil, target: "Notes")
    #expect(preparing?.level == 0 && preparing?.transcribing == false)
    for phase in [AppModel.Phase.finishing, .delivering] {
        let state = OverlayController.notchState(phase: phase, level: 0.4, liveText: "hello", question: nil, target: "Notes")
        #expect(state?.transcribing == true && state?.level == 0 && state?.partialText == "hello")
    }
    let asked = OverlayController.notchState(phase: .listening, level: 0, liveText: "", question: "Which branch?", target: "Claude Code")
    #expect(asked?.prompt == "Which branch?")
    #expect(OverlayController.notchState(phase: .listening, level: 0, liveText: "", question: "  ", target: "x")?.prompt == nil)
    for phase in [AppModel.Phase.idle, .cancelling, .failed] {
        #expect(OverlayController.notchState(phase: phase, level: 0, liveText: "", question: nil, target: "Notes") == nil)
    }
}

@Test func sessionPhasesMirrorIntoTheNotch() {
    #expect(NotchSessionMirror.state(phase: .listening, level: 0.3, partial: "hi", target: "Atlas", prompt: nil) == NotchDictation(target: "Atlas", level: 0.3, partialText: "hi"))
    #expect(NotchSessionMirror.state(phase: .transcribing, level: 0.3, partial: "hi", target: "Atlas", prompt: "Q?") == NotchDictation(target: "Atlas", partialText: "hi", transcribing: true, prompt: "Q?"))
    #expect(NotchSessionMirror.state(phase: .finished("done"), level: 0, partial: "", target: "Atlas", prompt: nil) == nil)
    #expect(NotchSessionMirror.state(phase: .idle, level: 0, partial: "", target: "Atlas", prompt: nil) == nil)
}

// MARK: Pill and island faces

@Test func pillPoseLabelAndSizeFollowTheState() {
    let plain = NotchDictation(target: "Notes", level: 0.5)
    #expect(DictationPillMetrics.pose(for: plain) == .listen)
    #expect(DictationPillMetrics.label(for: plain) == "Listening · Notes")
    #expect(DictationPillMetrics.size(for: plain, notchHeight: 32) == CGSize(width: 420, height: 78))
    let asked = NotchDictation(target: "Claude Code", prompt: "Which branch?")
    #expect(DictationPillMetrics.pose(for: asked) == .talk)
    #expect(DictationPillMetrics.size(for: asked, notchHeight: 32) == CGSize(width: 460, height: 102))
    let finishing = NotchDictation(target: "Notes", transcribing: true)
    #expect(DictationPillMetrics.pose(for: finishing) == .type)
    #expect(DictationPillMetrics.label(for: finishing) == "Finishing · Notes")
    #expect(DictationPillMetrics.resultSize(notchHeight: 32) == CGSize(width: 340, height: 62))
}

@MainActor @Test func islandFaceShowsNoStateWords() {
    func face(_ phase: AppModel.Phase, live: String = "", question: String? = nil, outcome: IslandPresenter.Outcome = .none, message: String = "") -> IslandFace {
        IslandFace.make(phase: phase, liveText: live, agentQuestion: question, outcome: outcome, message: message)
    }
    #expect(face(.preparing).label.isEmpty && face(.preparing).trailing == .sweep)
    #expect(face(.listening).label.isEmpty && face(.listening).trailing == .waveform && !face(.listening).live)
    #expect(face(.listening, live: "hello there").label == "hello there" && face(.listening, live: "hello there").live)
    #expect(face(.finishing).label.isEmpty && face(.finishing).trailing == .sweep)
    #expect(face(.delivering).label.isEmpty)
    let asked = face(.listening, question: "Which branch?")
    #expect(asked.pose == .talk && asked.question == "Which branch?")
    #expect(face(.finishing, question: "Which branch?").question == nil)
    let success = face(.idle, outcome: .success, message: "Inserted · Notes")
    #expect(success.label.isEmpty && success.trailing == .quiet)
    let attention = face(.idle, outcome: .attention, message: "Needs Accessibility")
    #expect(attention.label.isEmpty && attention.trailing == .attention)
    #expect(face(.idle, outcome: .neutral, message: "Cancelled").trailing == .quiet)
}

@Test func islandLeavesRoomToGrowInsideItsPanel() {
    let notched = RecordingPlacement.island(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 950), notchLeft: 662, notchRight: 850, notchHeight: 32)
    #expect(notched.panel.width >= notched.restingWidth + IslandGeometry.questionGrowth + 2 * IslandGeometry.shoulder)
    #expect(notched.panel.height >= notched.height + 54)
    let corner = RecordingPlacement.island(screen: NSRect(x: 0, y: 0, width: 2560, height: 1440), visible: NSRect(x: 0, y: 60, width: 2560, height: 1350), notchLeft: nil, notchRight: nil, notchHeight: 0, corner: .bottomLeft)
    #expect(corner.floating && corner.corner == .bottomLeft && corner.height == RecordingPlacement.floatingHeight)
    #expect(corner.panel.height >= corner.height + 36 + 2 * IslandGeometry.margin)
}

// MARK: Meetings library

@MainActor @Test func meetingLibraryRemembersExistingMeetingFoldersOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-meetings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "mouthy-meetings-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = MeetingLibrary(defaults: defaults)

    let meeting = root.appendingPathComponent("Mouthy meeting A")
    try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
    try Data().write(to: meeting.appendingPathComponent("Microphone.wav"))
    let empty = root.appendingPathComponent("Not a meeting")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

    library.remember(meeting)
    library.remember(empty)
    library.remember(meeting)
    #expect(library.records.map(\.folder.lastPathComponent) == ["Mouthy meeting A"])
    #expect(library.records.first?.hasNotes == false)

    try "# Notes".write(to: meeting.appendingPathComponent("Meeting notes.md"), atomically: true, encoding: .utf8)
    library.refresh()
    #expect(library.records.first?.hasNotes == true)

    // A second library on the same defaults sees the same list; a deleted folder drops out.
    let again = MeetingLibrary(defaults: defaults)
    again.refresh()
    #expect(again.records.count == 1)
    try FileManager.default.removeItem(at: meeting)
    again.refresh()
    #expect(again.records.isEmpty)
    library.forget(meeting)
    #expect((defaults.stringArray(forKey: "recentMeetingFolders") ?? []).allSatisfy { !$0.hasSuffix("Mouthy meeting A") })
}

@Test func meetingFolderNamesGiveTheStartTime() throws {
    let date = try #require(MeetingRecord.stampDate("Mouthy meeting 2026-10-05T14-30-00Z"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    #expect(parts.year == 2026 && parts.month == 10 && parts.day == 5 && parts.hour == 14 && parts.minute == 30)
    #expect(MeetingRecord.stampDate("Team sync") == nil)
}
