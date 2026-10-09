import Testing
import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch
@testable import MouthyKit

// MOUTHY_RENDER_DIR=<dir> swift test --filter workspaceRenders
// PNGs of every main-window page, empty and populated, at the default window size (plus a tall copy for
// scrolling pages). Every render is checked for blue.

private let renderEnabled = ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil
private let windowSize = CGSize(width: 1080, height: 760)
private let tallSize = CGSize(width: 1080, height: 1500)

/// A model on a throwaway store whose start-up capability refresh has finished, so seeded state sticks.
@MainActor private func freshModel() async throws -> AppModel {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-workspace-render-\(UUID().uuidString)")
    let model = AppModel(store: LocalStore(directory: support), enablesHotkey: false)
    await model.refreshCapabilities()
    try await Task.sleep(for: .milliseconds(300))
    return model
}

@MainActor private func render(_ model: AppModel, page: WorkspacePage, name: String, tall: Bool = false) throws {
    model.selectedPage = page.rawValue
    for (suffix, size) in tall ? [("", windowSize), ("-tall", tallSize)] : [("", windowSize)] {
        if let url = try renderOffscreen(WorkspaceView(model: model), size: size, name: name + suffix, settle: 0.7) { assertNoBlue(url) }
    }
}

/// A page on its own over the backdrop, for states the window can't reach directly (the Modes inspector).
@MainActor private func renderPage(_ view: some View, name: String, size: CGSize = windowSize) throws {
    let root = ZStack { MouthyBackdrop(); view }
        .tint(MouthyTheme.orange)
        .preferredColorScheme(.dark)
        .foregroundStyle(MouthyTheme.cream)
    if let url = try renderOffscreen(root, size: size, name: name, settle: 0.8) { assertNoBlue(url) }
}

@MainActor private func seedHistory(_ model: AppModel) {
    let now = Date()
    func entry(_ text: String, source: String, mode: String, minutesAgo: Double, duration: Double) -> MouthyCore.Transcript {
        var t = MouthyCore.Transcript(raw: text, text: text, duration: duration, source: source, mode: mode)
        t.date = now.addingTimeInterval(-minutesAgo * 60)
        return t
    }
    model.history = [
        entry("Thanks for the notes. I'll send the revised schedule tomorrow morning and loop in the print shop once the samples are ready.", source: "Mail", mode: "Clean up", minutesAgo: 4, duration: 9),
        entry("Remind me to order more PETG filament and check the nozzle on the second printer.", source: "Notes", mode: "Natural", minutesAgo: 95, duration: 5),
        entry("let user name equal request dot user dot display name", source: "Xcode", mode: "Natural", minutesAgo: 60 * 26, duration: 4),
        entry("The giraffe mascot should glow while it listens, and sleep when nothing is happening.", source: "Mouthy workspace", mode: "Grammar", minutesAgo: 60 * 27, duration: 7),
        entry("Welcome back to the show. Today we're talking about building tools that stay out of your way.", source: "Podcast intro.m4a", mode: "Natural", minutesAgo: 60 * 24 * 4, duration: 42)
    ]
}

@MainActor private func seedStats(_ model: AppModel) {
    var stats = UsageStats()
    stats.words = 12_480; stats.sessions = 214; stats.speakingSeconds = 12_480.0 / 142 * 60
    model.stats = stats
}

@MainActor @Test(.enabled(if: renderEnabled))
func workspaceRendersEmptyPages() async throws {
    let model = try await freshModel()
    model.microphoneAllowed = false; model.accessibilityAllowed = false; model.speechAssetsReady = false
    for page in WorkspacePage.allCases {
        try render(model, page: page, name: "page-\(page.rawValue)", tall: page == .dictate || page == .settings)
    }
    // History on but nothing said yet.
    model.preferences.keepHistory = true
    try render(model, page: .history, name: "page-History-on-empty")
}

@MainActor @Test(.enabled(if: renderEnabled))
func workspaceRendersPopulatedPages() async throws {
    let model = try await freshModel()
    model.microphoneAllowed = true; model.accessibilityAllowed = true; model.speechAssetsReady = true
    model.preferences.keepHistory = true
    seedStats(model)
    seedHistory(model)
    model.output = "Thanks for the notes. I'll send the revised schedule tomorrow morning and loop in the print shop once the samples are ready."
    try render(model, page: .dictate, name: "populated-Dictate", tall: true)
    try render(model, page: .history, name: "populated-History", tall: true)

    // Modes: the three examples.
    model.preferences.modes = ModeExamples.make()
    model.preferences.modes[0].shortcut = ModeShortcut(keyCode: 14, modifiers: 0, label: "⌃ ⌥ E")
    try render(model, page: .modes, name: "populated-Modes")

    // Files: one ready, one transcribing, one failed, one waiting.
    model.fileResults = [
        FileResult(url: URL(fileURLWithPath: "/tmp/Team standup.m4a"), state: "Ready",
                   document: TranscriptionDocument(text: "Morning everyone. Quick round: the website film is rendering overnight, the notch hub tabs are in review, and Mouthy's new look lands today.")),
        FileResult(url: URL(fileURLWithPath: "/tmp/Podcast intro.mov"), state: "Transcribing"),
        FileResult(url: URL(fileURLWithPath: "/tmp/Voice memo.wav"), state: "Failed: The file has no audio track."),
        FileResult(url: URL(fileURLWithPath: "/tmp/Interview part 2.mp3"), state: "Queued")
    ]
    model.phase = .finishing
    try render(model, page: .files, name: "populated-Files")
    model.phase = .idle
}

@MainActor @Test(.enabled(if: renderEnabled))
func workspaceRendersDictationStates() async throws {
    let model = try await freshModel()
    model.microphoneAllowed = true; model.accessibilityAllowed = false; model.speechAssetsReady = true
    seedStats(model)
    // Setup still needed: Accessibility missing.
    try render(model, page: .dictate, name: "dictate-setup", tall: true)

    model.accessibilityAllowed = true
    model.phase = .listening
    model.level = 0.6
    model.elapsed = 7
    model.targetName = "Notes"
    model.liveText = "Remind me to pick up the giraffe stickers and send the revised schedule to the print shop"
    try render(model, page: .dictate, name: "dictate-listening")

    model.liveText = ""
    model.agentQuestion = "Should I merge the notch hub branch into main now, or wait for the review?"
    model.level = 0.4
    try render(model, page: .dictate, name: "dictate-agent-question")
    model.agentQuestion = nil

    model.phase = .finishing
    model.level = 0
    try render(model, page: .dictate, name: "dictate-finishing")
    model.phase = .idle
}

@MainActor @Test(.enabled(if: renderEnabled))
func workspaceRendersModesInspector() async throws {
    let model = try await freshModel()
    model.preferences.modes = ModeExamples.make()
    let chat = try #require(model.preferences.modes.last)
    try renderPage(ModesView(model: model, editing: chat.id), name: "modes-inspector", size: CGSize(width: 1080, height: 860))
    // The active mode while dictating gets the glow ring.
    model.phase = .listening
    model.activeModeName = "Email"
    try renderPage(ModesView(model: model), name: "modes-active")
    model.phase = .idle
}

@MainActor @Test(.enabled(if: renderEnabled))
func workspaceRendersTranscript() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Meeting 2026-10-05 \(UUID().uuidString.prefix(4))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let lines = [
        MeetingNotes.Line(start: 2, speaker: "You", text: "Thanks for joining. Let's start with the launch video for Mouthy."),
        MeetingNotes.Line(start: 9.5, speaker: "Speaker 1", text: "The giraffe should be in the first shot. The listening glow on the horns reads really well on camera."),
        MeetingNotes.Line(start: 21, speaker: "You", text: "Agreed. Then the notch pill, live text, and the cheer when it inserts."),
        MeetingNotes.Line(start: 33.2, speaker: "Speaker 1", text: "Perfect. I'll cut it to forty seconds.")
    ]
    _ = try MeetingNotes.write(MeetingNotes.Saved(summary: "Launch video plan.", lines: lines), to: folder)
    let view = try #require(TranscriptView(folder: folder) {})
    try renderPage(view, name: "transcript", size: CGSize(width: 860, height: 520))
}
