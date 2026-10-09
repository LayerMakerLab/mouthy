import Testing
import Foundation
import MouthyCore
import MouthyNotch
@testable import MouthyKit

@MainActor @Test func dictateHeroPoseFollowsState() {
    #expect(DictateHero.pose(phase: .idle, agentQuestion: nil, cheering: false, firstRun: false) == .sleep)
    #expect(DictateHero.pose(phase: .idle, agentQuestion: nil, cheering: false, firstRun: true) == .wave)
    #expect(DictateHero.pose(phase: .idle, agentQuestion: nil, cheering: true, firstRun: true) == .cheer)
    #expect(DictateHero.pose(phase: .preparing, agentQuestion: nil, cheering: false, firstRun: false) == .listen)
    #expect(DictateHero.pose(phase: .listening, agentQuestion: nil, cheering: false, firstRun: false) == .listen)
    #expect(DictateHero.pose(phase: .listening, agentQuestion: "Merge now?", cheering: false, firstRun: false) == .talk)
    #expect(DictateHero.pose(phase: .finishing, agentQuestion: nil, cheering: false, firstRun: false) == .type)
    #expect(DictateHero.pose(phase: .delivering, agentQuestion: nil, cheering: false, firstRun: false) == .type)
    #expect(DictateHero.pose(phase: .failed, agentQuestion: nil, cheering: false, firstRun: false) == .sleep)
    #expect(DictateHero.pose(phase: .cancelling, agentQuestion: nil, cheering: true, firstRun: false) == .sleep)
}

@Test func dictateHeroWordsMatchTheShortcutAndOutcome() {
    #expect(DictateHero.startPrompt("⌃⌥Space") == "Press ⌃⌥Space to start")
    #expect(DictateHero.startPrompt("Hold Fn") == "Hold Fn to start")
    #expect(DictateHero.startPrompt("Double-tap Right ⌘") == "Double-tap Right ⌘ to start")
    #expect(DictateHero.outcomeWord("Inserted into Notes.") == "Inserted")
    #expect(DictateHero.outcomeWord("Pasted into Slack.") == "Pasted")
    #expect(DictateHero.outcomeWord("Answer sent to the agent.") == "Sent to the agent")
    #expect(DictateHero.outcomeWord("Copied to the clipboard.") == "Copied")
    #expect(DictateHero.outcomeWord("No speech detected.") == nil)
    #expect(DictateHero.outcomeWord("Ready.") == nil)
    #expect(DictateHero.headline(phase: .listening, shortcut: "⌃⌥Space", cheering: false, status: "") == "Listening")
    #expect(DictateHero.headline(phase: .idle, shortcut: "⌃⌥Space", cheering: true, status: "Inserted into Notes.") == "Inserted")
    #expect(DictateHero.headline(phase: .idle, shortcut: "Hold Fn", cheering: false, status: "Inserted") == "Hold Fn to start")
    #expect(DictateHero.clock(0) == "0:00")
    #expect(DictateHero.clock(7.9) == "0:07")
    #expect(DictateHero.clock(125) == "2:05")
}

@Test func readinessNamesTheFirstMissingRequirement() {
    func evaluate(mic: Bool = true, assets: Bool = true, ax: Bool = true, localOnly: Bool = false, busy: Bool = false) -> DictateReadiness {
        DictateReadiness.evaluate(microphone: mic, speechAssets: assets, accessibility: ax, localOnly: localOnly, setupBusy: busy, engine: .parakeet)
    }
    #expect(evaluate() == .ready)
    #expect(evaluate().actionTitle == nil)
    #expect(evaluate(mic: false, assets: false, ax: false) == .microphone)
    #expect(evaluate(mic: false).actionTitle == "Allow microphone")
    #expect(evaluate(assets: false) == .speechModel(engine: "NVIDIA Parakeet v3"))
    #expect(evaluate(assets: false, localOnly: true) == .localOnly(engine: "NVIDIA Parakeet v3"))
    #expect(evaluate(assets: false, busy: true) == .downloading)
    #expect(evaluate(ax: false) == .accessibility)
    #expect(evaluate(ax: false).actionTitle == "Open Accessibility settings")
    // Never claims "Ready" while something is missing.
    for state in [evaluate(mic: false), evaluate(assets: false), evaluate(ax: false)] { #expect(!state.isReady) }
}

@Test func historyGroupsByDayNewestFirst() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)))
    func entry(hoursAgo: Double, text: String) -> MouthyCore.Transcript {
        var t = MouthyCore.Transcript(raw: text, text: text, duration: 1, source: "Notes", mode: "Natural")
        t.date = now.addingTimeInterval(-hoursAgo * 3600)
        return t
    }
    let entries = [entry(hoursAgo: 30, text: "yesterday"), entry(hoursAgo: 1, text: "today late"), entry(hoursAgo: 2, text: "today early"),
                   entry(hoursAgo: 24 * 3, text: "friday"), entry(hoursAgo: 24 * 40, text: "august")]
    let days = HistoryGrouping.days(entries, now: now, calendar: calendar)
    #expect(days.map(\.title).prefix(2) == ["Today", "Yesterday"])
    #expect(days.count == 4)
    #expect(days[0].entries.map(\.text) == ["today late", "today early"])
    #expect(days[1].entries.map(\.text) == ["yesterday"])
    #expect(days.map(\.start) == days.map(\.start).sorted(by: >))
    #expect(HistoryGrouping.filter(entries, query: "  TODAY ").count == 2)
    #expect(HistoryGrouping.filter(entries, query: "").count == entries.count)
}

@Test func onlyAudioAndVideoDropsAreTranscribed() {
    let urls = ["a.m4a", "b.mov", "c.wav", "d.txt", "e.pdf", "f.mp3"].map { URL(fileURLWithPath: "/tmp/" + $0) }
    #expect(FileDrop.transcribable(urls).map(\.lastPathComponent) == ["a.m4a", "b.mov", "c.wav", "f.mp3"])
    #expect(FileDrop.transcribable([URL(string: "https://example.com/a.mp3")!]).isEmpty)
    #expect(FileDrop.symbol(for: URL(fileURLWithPath: "/tmp/x.mov")) == "film")
    #expect(FileDrop.symbol(for: URL(fileURLWithPath: "/tmp/x.m4a")) == "waveform")
}

@Test func fileStateReadsTheBatchStrings() {
    #expect(FileState("Queued") == .queued)
    #expect(FileState("Transcribing") == .transcribing)
    #expect(FileState("Ready") == .ready)
    #expect(FileState("Cancelled") == .cancelled)
    #expect(FileState("Failed: No audio track.") == .failed("No audio track."))
    #expect(FileState("Failed: ") == .failed("Couldn't transcribe this file."))
}

@Test func exampleModesMatchTheSpecAndNeverDuplicate() throws {
    let examples = ModeExamples.make()
    #expect(examples.map(\.name) == ["Email", "Code", "Chat"])
    let email = try #require(examples.first { $0.name == "Email" })
    #expect(email.triggerWord == "email" && email.writingMode == .tidy && email.output == .insert)
    let code = try #require(examples.first { $0.name == "Code" })
    #expect(code.apps == ["com.apple.Terminal", "com.apple.dt.Xcode"] && code.codeDictation)
    let chat = try #require(examples.first { $0.name == "Chat" })
    #expect(chat.websites == ["chatgpt.com", "claude.ai"] && chat.output == .insertAndReturn)
    #expect(Set(examples.map(\.id)).count == 3)
    #expect(ModeExamples.missing(from: examples).isEmpty)
    #expect(ModeExamples.missing(from: [DictationMode(name: "email")]).map(\.name) == ["Code", "Chat"])
    // Example modes resolve the way their chips say.
    #expect(ModeResolver.startMode(examples, shortcutMode: nil, url: "https://claude.ai/new", bundleID: "")?.name == "Chat")
    #expect(ModeResolver.startMode(examples, shortcutMode: nil, url: nil, bundleID: "com.apple.dt.Xcode")?.name == "Code")
    #expect(ModeResolver.trigger(in: "Email hello team", modes: examples)?.0.name == "Email")
}

@Test func newModeNamesStayUnique() {
    #expect(ModeExamples.newName(existing: []) == "New mode")
    #expect(ModeExamples.newName(existing: [DictationMode(name: "New mode")]) == "New mode 2")
    #expect(ModeExamples.newName(existing: [DictationMode(name: "New mode"), DictationMode(name: "New mode 2")]) == "New mode 3")
}

@Test func entrySourcesAreClassified() {
    if case .mouthy = EntrySource.classify("Mouthy workspace") {} else { Issue.record("workspace should be Mouthy") }
    if case .file(let symbol) = EntrySource.classify("Interview.m4a") { #expect(symbol == "waveform") } else { Issue.record("audio file") }
    if case .file(let symbol) = EntrySource.classify("Clip.mov") { #expect(symbol == "film") } else { Issue.record("video file") }
    if case .app(let name) = EntrySource.classify("Notes") { #expect(name == "Notes") } else { Issue.record("app") }
}

@MainActor @Test func turningOnHistoryFromTheEmptyStatePersists() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-history-\(UUID().uuidString)")
    let model = AppModel(store: LocalStore(directory: support), enablesHotkey: false)
    #expect(model.preferences.keepHistory == false)
    model.preferences.keepHistory = true
    model.savePreferences()
    let reloaded = AppModel(store: LocalStore(directory: support), enablesHotkey: false)
    #expect(reloaded.preferences.keepHistory)
}
