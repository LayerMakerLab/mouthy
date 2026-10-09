import Testing
import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch
@testable import MouthyKit

// Settings, Vocabulary, onboarding, menu bar panel and About: logic tests plus gated offscreen renders.
// Renders: MOUTHY_RENDER_DIR=<dir> swift test --filter "onboardingRenders|settingsRenders|vocabularyRenders|aboutRenders|menuPanelRenders"

@MainActor
private func makeModel() -> AppModel {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-l2-\(UUID().uuidString)")
    let model = AppModel(store: LocalStore(directory: support), enablesHotkey: false)
    // Let the model's own launch refresh finish so the states set below stick for the render.
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    return model
}

// MARK: - Logic

@Test func versionLineUsesBundleVersionAndRevision() {
    #expect(AppVersion.line(["CFBundleShortVersionString": "0.1.0", "MouthySourceRevision": "33a9d61"]) == "Version 0.1.0 (33a9d61)")
    #expect(AppVersion.line(["CFBundleShortVersionString": "0.1.0"]) == "Version 0.1.0")
    #expect(AppVersion.line(["MouthySourceRevision": "abc"]) == "Development build (abc)")
    #expect(AppVersion.line(["CFBundleShortVersionString": ""]) == "Development build")
    #expect(AppVersion.line(nil) == "Development build")
    #expect(!AppVersion.line(nil).contains("0.1"), "no hard-coded version")
}

@Test func vocabularyChipsAddSplitDeduplicateAndRemove() {
    var vocabulary = ""
    vocabulary = VocabularyEditing.adding("  Mouthy ", to: vocabulary)
    #expect(VocabularyEditing.words(vocabulary) == ["Mouthy"])
    vocabulary = VocabularyEditing.adding("LayerMaker, mouthy, Parakeet", to: vocabulary)
    #expect(VocabularyEditing.words(vocabulary) == ["Mouthy", "LayerMaker", "Parakeet"], "commas add several; case-insensitive repeats are skipped")
    #expect(VocabularyEditing.adding("   ", to: vocabulary) == vocabulary)
    vocabulary = VocabularyEditing.removing("LayerMaker", from: vocabulary)
    #expect(vocabulary == "Mouthy\nParakeet")
    #expect(VocabularyEditing.removing("Missing", from: vocabulary) == vocabulary)
}

@Test func replacementRowsTrimRejectBlankAndReplaceSamePhrase() throws {
    #expect(VocabularyEditing.replacement(phrase: "  ", replacement: "x") == nil)
    let first = try #require(VocabularyEditing.replacement(phrase: " my sig ", replacement: " Thank you, Alex Smith "))
    #expect(first.phrase == "my sig" && first.replacement == "Thank you, Alex Smith")
    let other = Replacement(phrase: "btw", replacement: "by the way")
    let second = try #require(VocabularyEditing.replacement(phrase: "MY SIG", replacement: "Thanks"))
    let rules = VocabularyEditing.adding(second, to: [first, other])
    #expect(rules.map(\.phrase) == ["btw", "MY SIG"], "a rule for the same phrase in any case replaces the old one")
}

@Test func menuPanelPoseFollowsTheDictationState() {
    #expect(MenuPanelState.pose(phase: .idle, status: "Ready.", agentQuestion: nil) == .sleep)
    #expect(MenuPanelState.pose(phase: .listening, status: "Listening…", agentQuestion: nil) == .listen)
    #expect(MenuPanelState.pose(phase: .preparing, status: "", agentQuestion: nil) == .listen)
    #expect(MenuPanelState.pose(phase: .finishing, status: "", agentQuestion: nil) == .type)
    #expect(MenuPanelState.pose(phase: .delivering, status: "", agentQuestion: nil) == .type)
    #expect(MenuPanelState.pose(phase: .idle, status: "Inserted into Notes.", agentQuestion: nil, cheering: true) == .cheer)
    #expect(MenuPanelState.pose(phase: .idle, status: "Pasted into Notes.", agentQuestion: nil, cheering: true) == .cheer)
    #expect(MenuPanelState.pose(phase: .idle, status: "Inserted into Notes.", agentQuestion: nil) == .sleep,
            "after the 1.2 s cheer an idle panel sleeps even though the status still says Inserted")
    #expect(MenuPanelState.pose(phase: .idle, status: "Ready.", agentQuestion: nil, cheering: true) == .sleep)
    #expect(MenuPanelState.pose(phase: .failed, status: "Microphone lost", agentQuestion: nil) == .sleep)
    #expect(MenuPanelState.pose(phase: .listening, status: "", agentQuestion: "Which branch?") == .talk)
}

@Test func menuPanelHeadlineAndDetailAreHuman() {
    #expect(MenuPanelState.headline(phase: .idle, agentQuestion: nil) == "Ready")
    #expect(MenuPanelState.headline(phase: .delivering, agentQuestion: nil) == "Typing")
    #expect(MenuPanelState.headline(phase: .listening, agentQuestion: nil, meeting: true) == "Recording a meeting")
    #expect(MenuPanelState.headline(phase: .idle, agentQuestion: "Q") == "An agent is asking")
    #expect(MenuPanelState.detail(status: "Ready.", phase: .idle, agentQuestion: nil) == nil)
    #expect(MenuPanelState.detail(status: "Listening…", phase: .listening, agentQuestion: nil) == nil)
    #expect(MenuPanelState.detail(status: "Inserted into Notes.", phase: .idle, agentQuestion: nil) == "Inserted into Notes.")
    #expect(MenuPanelState.detail(status: "x", phase: .listening, agentQuestion: "Which branch?") == "Which branch?")
}

@MainActor @Test func menuPanelRecentSkipsTheLastResultAndCapsAtThree() {
    #expect(MenuBarPanel.recent(items: ["a", "b", "c", "d", "e"], history: ["h"], excluding: "a") == ["b", "c", "d"])
    #expect(MenuBarPanel.recent(items: [], history: ["h1", "h1", "h2"], excluding: "x") == ["h1", "h2"], "falls back to history, without repeats")
    #expect(MenuBarPanel.recent(items: [], history: [], excluding: "") == [])
}

/// Three screens to the first dictation: hello with the microphone, Accessibility, then Try it, which finishes.
@Test func onboardingReachesTheFirstDictationInThreeScreens() {
    #expect(OnboardingStep.allCases.map(\.title) == ["Hello. I'm Mouthy.", "Let me type for you", "Say something"])
    #expect(OnboardingStep.allCases.map(\.pose) == [.cheer, .type, .listen])
    #expect(OnboardingStep.hello.previous == nil && OnboardingStep.tryIt.next == nil)
    #expect(OnboardingStep.hello.next == .accessibility && OnboardingStep.accessibility.next == .tryIt)
}

@Test func practiceBoxShowsLiveTextWhileListeningThenTheResult() {
    #expect(PracticeText.shown(practice: "", live: "Hello this", listening: true) == "Hello this")
    #expect(PracticeText.shown(practice: "Hello, this is a test.", live: "", listening: false) == "Hello, this is a test.")
    #expect(PracticeText.shown(practice: "Old", live: "", listening: true) == "Old")
    // Spoken punctuation never shows as words while listening.
    #expect(PracticeText.shown(practice: "", live: "Hello comma this is", listening: true) == "Hello, this is")
    #expect(PracticeText.shown(practice: "Done.", live: "stale", listening: false) == "Done.")
}

@Test func shortcutRecorderGlyphsMatchTheSavedLabelOrder() {
    #expect(ShortcutCapture.glyphs([.command, .control, .shift, .option]) == "⌃ ⌥ ⇧ ⌘")
    #expect(ShortcutCapture.glyphs([.command]) == "⌘")
    #expect(ShortcutCapture.glyphs([]) == "")
    #expect(KeycapRow.keys(for: "⌃ ⌥ ⇧ ⌘") == ["⌃", "⌥", "⇧", "⌘"])
}

/// Onboarding holds no timer: its only refresh hooks are activation notifications.
@Test func onboardingSourceHasNoTimer() throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MouthyKit/OnboardingView.swift")
    let text = try String(contentsOf: source, encoding: .utf8)
    #expect(!text.contains("Timer.publish") && !text.contains("TimelineView") && !text.contains("repeatForever"))
    #expect(text.contains("didBecomeActiveNotification") && text.contains("didActivateApplicationNotification"))
}

// MARK: - Renders

@MainActor @Test func onboardingRendersForVisualReview() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
    let model = makeModel()
    // A Mac where the speech model is on disk and the microphone is allowed, as after the background preparation.
    model.speechAssetsReady = true; model.microphoneAllowed = true
    for step in OnboardingStep.allCases {
        let practice = step == .tryIt ? "Hello, this is a test." : ""
        let view = OnboardingView(model: model, step: step, practice: practice) {}
        if let url = try renderOffscreen(view, size: CGSize(width: 760, height: 500), name: "onboarding-\(step.rawValue + 1)-\(step)", settle: 0.7) {
            assertNoBlue(url)
        }
    }
    // Try it before anything was said, and while listening with live words.
    if let url = try renderOffscreen(OnboardingView(model: model, step: .tryIt) {}, size: CGSize(width: 760, height: 500), name: "onboarding-3-tryIt-empty") {
        assertNoBlue(url)
    }
    model.phase = .listening; model.liveText = "Hello comma this is"; model.level = 0.6
    if let url = try renderOffscreen(OnboardingView(model: model, step: .tryIt) {}, size: CGSize(width: 760, height: 500), name: "onboarding-3-tryIt-listening") {
        assertNoBlue(url)
    }
    model.phase = .idle; model.liveText = ""; model.level = 0
    // The speech model still getting ready in the background: one quiet line on Try it, Try it waits.
    model.speechAssetsReady = false; model.setupBusy = true
    if let url = try renderOffscreen(OnboardingView(model: model, step: .tryIt) {}, size: CGSize(width: 760, height: 500), name: "onboarding-3-tryIt-preparing") {
        assertNoBlue(url)
    }
    model.setupBusy = false
    // Not downloaded and not downloading (offline at first launch): one line and the one button that gets it.
    if let url = try renderOffscreen(OnboardingView(model: model, step: .tryIt) {}, size: CGSize(width: 760, height: 500), name: "onboarding-3-tryIt-download") {
        assertNoBlue(url)
    }
}

@MainActor @Test func settingsRendersForVisualReview() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
    let model = makeModel()
    model.microphoneAllowed = true
    model.accessibilityAllowed = false
    model.preferences.keepHistory = true
    let page = ZStack { MouthyBackdrop(); PreferencesView(model: model) }
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 3000), name: "settings-full", settle: 0.8) { assertNoBlue(url) }
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 720), name: "settings-top") { assertNoBlue(url) }
    // Busy: the capsule replaces a silent disable.
    model.phase = .listening
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 520), name: "settings-busy") { assertNoBlue(url) }
    model.phase = .idle
    // Everything allowed: the tile is titled "Permissions".
    model.accessibilityAllowed = true
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 520), name: "settings-granted") { assertNoBlue(url) }
    // "More options" open: every rarely used control is still one click away.
    let more = ZStack { MouthyBackdrop(); PreferencesView(model: model, showMore: true) }
    if let url = try renderOffscreen(more, size: CGSize(width: 840, height: 3200), name: "settings-more", settle: 0.8) { assertNoBlue(url) }
    // "Only listen to my voice" (Parakeet): untrained, reading the three sentences, then trained.
    model.preferences.speechEngine = .parakeet
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 1300), name: "settings-voice-untrained", settle: 0.8) { assertNoBlue(url) }
    model.voiceTrainer.step = .reading
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 1300), name: "settings-voice-reading", settle: 0.8) { assertNoBlue(url) }
    model.voiceTrainer.step = .idle; model.voiceTrainer.trained = true; model.preferences.onlyMyVoice = true
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 1300), name: "settings-voice-trained", settle: 0.8) { assertNoBlue(url) }
    model.voiceTrainer.trained = false; model.preferences.onlyMyVoice = false
    // Local Only: downloads and update checks are off and say why.
    model.preferences.localOnly = true
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 3000), name: "settings-local-only", settle: 0.8) { assertNoBlue(url) }
}

@MainActor @Test func vocabularyRendersForVisualReview() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
    let model = makeModel()
    let page = ZStack { MouthyBackdrop(); VocabularyView(model: model) }
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 900), name: "vocabulary-empty") { assertNoBlue(url) }
    model.preferences.vocabulary = "Mouthy\nLayerMaker\nParakeet\nSwiftUI\nRealityKit\nSmith\nParis\nLinux\nLiquid Glass"
    model.preferences.replacements = [Replacement(phrase: "my sig", replacement: "Thank you, Alex Smith"),
                                      Replacement(phrase: "mouthy dot dev", replacement: "mouthy.dev"),
                                      Replacement(phrase: "um actually", replacement: "")]
    if let url = try renderOffscreen(page, size: CGSize(width: 840, height: 1000), name: "vocabulary-populated") { assertNoBlue(url) }
}

@MainActor @Test func aboutRendersForVisualReview() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
    let model = makeModel()
    let about = AboutView(model: model, versionLine: AppVersion.line(["CFBundleShortVersionString": "0.1.0", "MouthySourceRevision": "render"]), licensesFolder: nil) {}
    if let url = try renderOffscreen(about, size: CGSize(width: 440, height: 600), name: "about-sheet") { assertNoBlue(url) }
}

@MainActor @Test func menuPanelRendersForVisualReview() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
    let model = makeModel()
    let recent = RecentResults()
    if let url = try renderOffscreen(ZStack(alignment: .top) { MouthyBackdrop(glow: 0.14); MenuBarPanel(model: model, recent: recent) }, size: CGSize(width: 320, height: 250), name: "menu-panel-first-run") { assertNoBlue(url) }
    model.preferences.modes = [DictationMode(name: "Email"), DictationMode(name: "Code")]
    model.output = "Let's move the demo to Thursday at four and send the notes after."
    for text in ["Let's move the demo to Thursday at four and send the notes after.", "Remind me to order more PETG.",
                 "The giraffe glows while it listens.", "Ship the Settings tiles tonight."] { recent.add(text) }
    model.status = "Inserted into Notes."
    if let url = try renderOffscreen(ZStack(alignment: .top) { MouthyBackdrop(glow: 0.14); MenuBarPanel(model: model, recent: recent) }, size: CGSize(width: 320, height: 520), name: "menu-panel-idle") { assertNoBlue(url) }
    model.phase = .listening; model.status = "Listening…"; model.level = 0.7; model.elapsed = 12
    if let url = try renderOffscreen(ZStack(alignment: .top) { MouthyBackdrop(glow: 0.14); MenuBarPanel(model: model, recent: recent) }, size: CGSize(width: 320, height: 520), name: "menu-panel-listening") { assertNoBlue(url) }
    model.phase = .idle; model.level = 0
}

@MainActor @Test func settingsRendersSpeechModelsTile() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
    // Synthetic states only; neither cache queries nor model actions run in this render.
    let rows = [SpeechModelRow(id: .apple, status: "Installed · English (United States)", size: "Size managed by macOS",
                               installed: true, canDownload: false, canRemove: true)] + SpeechModelID.all.dropFirst().map { id in
        var row = SpeechModelCatalog.row(id, ready: id == .parakeet, bytes: id == .parakeet ? ModelDownloadSize.parakeetCoreML : 0,
                                         supported: true, intel: false)
        if id == .parakeet { row.status += SpeechModelCatalog.parakeetDetail(intel: false) }
        return row
    }
    let page = ZStack { MouthyBackdrop(); SpeechModelsTile(rows: rows).padding(24) }
    if let url = try renderOffscreen(page, size: CGSize(width: 760, height: 700), name: "settings-models") { assertNoBlue(url) }
    let blocked = ZStack {
        MouthyBackdrop()
        SpeechModelsTile(rows: rows, busy: true, localOnly: true, message: "Downloading Whisper · 42%").padding(24)
    }
    if let url = try renderOffscreen(blocked, size: CGSize(width: 760, height: 740), name: "settings-models-downloading") { assertNoBlue(url) }
    let intel = [SpeechModelRow(id: .apple, status: "Needs Apple silicon", size: "Size managed by macOS", canDownload: false)] + SpeechModelID.all.dropFirst().map { id in
        var row = SpeechModelCatalog.row(id, ready: false, bytes: 0, supported: id == .parakeet, intel: true)
        if id == .parakeet { row.status += SpeechModelCatalog.parakeetDetail(intel: true) }
        return row
    }
    if let url = try renderOffscreen(ZStack { MouthyBackdrop(); SpeechModelsTile(rows: intel).padding(24) },
                                    size: CGSize(width: 760, height: 700), name: "settings-models-intel") { assertNoBlue(url) }
}
