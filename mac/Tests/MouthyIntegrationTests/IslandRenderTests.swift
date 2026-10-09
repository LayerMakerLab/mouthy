import Testing
import SwiftUI
import AppKit
import MouthyCore
import AVFoundation
@testable import MouthyNotch
@testable import MouthyKit

/// A warm wallpaper behind the renders so the black island and pill edges read.
private let wallpaper = LinearGradient(colors: [Color(red: 0.42, green: 0.27, blue: 0.17), Color(red: 0.13, green: 0.08, blue: 0.05)],
                                       startPoint: .top, endPoint: .bottom)

/// A microphone frame from a synthetic tone at `amplitude`.
private func toneFrame(_ amplitude: Double) -> MicrophoneFrame {
    let tone = (0..<4_800).map { Float(sin(Double($0) / 9) * amplitude) }
    return tone.withUnsafeBufferPointer { MicrophoneFrame.measure($0) }
}

/// MOUTHY_RENDER_DIR=<dir>: every recording-island state on a notched display, an external display's menu bar
/// and a bottom-corner pill: `swift test --filter islandRenders`.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil))
func islandRendersForVisualReview() async throws {
    Mascot.install()
    defer { NotchArt.mascot = nil }
    let store = LocalStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let model = AppModel(store: store, enablesHotkey: false)
    model.targetName = "Notes"
    let external = RecordingPlacement.island(screen: NSRect(x: 0, y: 0, width: 2560, height: 1440), visible: NSRect(x: 0, y: 0, width: 2560, height: 1410), notchLeft: nil, notchRight: nil, notchHeight: 0)
    let notched = RecordingPlacement.island(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 950), notchLeft: 662, notchRight: 850, notchHeight: 32)
    let corner = RecordingPlacement.island(screen: NSRect(x: 0, y: 0, width: 2560, height: 1440), visible: NSRect(x: 0, y: 60, width: 2560, height: 1350), notchLeft: nil, notchRight: nil, notchHeight: 0, corner: .bottomRight)

    struct State {
        let name: String
        let phase: AppModel.Phase
        var amplitude = 0.0
        var live = ""
        var question: String?
        var outcome: IslandPresenter.Outcome = .none
        var message = ""
    }
    let states = [
        State(name: "preparing", phase: .preparing),
        State(name: "listening-low", phase: .listening, amplitude: 0.02),
        State(name: "listening-high", phase: .listening, amplitude: 0.3),
        State(name: "live-text", phase: .listening, amplitude: 0.2, live: "Pick up oat milk and the good bread on the way home"),
        State(name: "finishing", phase: .finishing),
        State(name: "inserted", phase: .idle, outcome: .success, message: "Inserted · Notes"),
        State(name: "pasted", phase: .idle, outcome: .success, message: "Pasted · Terminal"),
        State(name: "sent", phase: .idle, outcome: .success, message: "Sent to the agent"),
        State(name: "attention", phase: .idle, outcome: .attention, message: "Nothing heard"),
        State(name: "cancelled", phase: .idle, outcome: .neutral, message: "Cancelled"),
        State(name: "agent-question", phase: .listening, amplitude: 0.15, question: "Which branch should I deploy to staging?")
    ]
    for (place, geometry) in [("notch", notched), ("external", external), ("corner", corner)] {
        for state in states {
            model.phase = state.phase
            model.liveText = state.live
            model.agentQuestion = state.question
            let frame = toneFrame(state.amplitude)
            model.receiveLevel(frame.level)
            let presenter = IslandPresenter()
            presenter.presented = true
            presenter.outcome = state.outcome
            presenter.message = state.message
            let view = RecordingIsland(model: model, presenter: presenter, geometry: geometry)
                .tint(MouthyTheme.orange)
                .frame(width: geometry.panel.width, height: geometry.panel.height)
                .background(wallpaper)
            let url = try renderOffscreen(view, size: CGSize(width: geometry.panel.width, height: geometry.panel.height),
                                          name: "island-\(place)-\(state.name)", settle: 0.6) {
                model.receiveLevel(frame.level)
            }
            if let url { assertNoBlue(url) }
        }
    }
    model.level = 0
    model.phase = .idle; model.agentQuestion = nil; model.liveText = ""
}

/// MOUTHY_RENDER_DIR=<dir>: the notch pill while listening, with live words, finishing, answering an agent,
/// and its result lines: `swift test --filter pillRenders`.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil))
func pillRendersForVisualReview() throws {
    Mascot.install()
    defer { NotchArt.mascot = nil }
    let notchWidth: CGFloat = 188, notchHeight: CGFloat = 32
    let pills: [(String, AnyView)] = [
        ("pill-listening", AnyView(DictationPill(dictation: NotchDictation(target: "Notes", level: 0.55), notchWidth: notchWidth, notchHeight: notchHeight))),
        ("pill-live-text", AnyView(DictationPill(dictation: NotchDictation(target: "Notes", level: 0.7, partialText: "Pick up oat milk and the good bread on the way home, and call the vet about Friday"), notchWidth: notchWidth, notchHeight: notchHeight))),
        ("pill-transcribing", AnyView(DictationPill(dictation: NotchDictation(target: "Notes", partialText: "Pick up oat milk and the good bread", transcribing: true), notchWidth: notchWidth, notchHeight: notchHeight))),
        ("pill-prompt", AnyView(DictationPill(dictation: NotchDictation(target: "Claude Code", level: 0.4, partialText: "Staging, and run the smoke tests first", prompt: "Which branch should I deploy to staging?"), notchWidth: notchWidth, notchHeight: notchHeight))),
        ("pill-result", AnyView(ResultPill(text: "Inserted · Notes", ok: true, notchWidth: notchWidth, notchHeight: notchHeight))),
        ("pill-result-agent", AnyView(ResultPill(text: "Sent to the agent", ok: true, notchWidth: notchWidth, notchHeight: notchHeight))),
        ("pill-result-attention", AnyView(ResultPill(text: "Nothing heard", ok: false, notchWidth: notchWidth, notchHeight: notchHeight)))
    ]
    for (name, pill) in pills {
        let size = CGSize(width: 520, height: notchHeight + 110)
        let view = ZStack(alignment: .top) {
            wallpaper
            // The hardware notch the pill grows out of.
            pill
            NotchShape(bottomRadius: 10, shoulder: 0).fill(Color.black).frame(width: notchWidth, height: notchHeight)
                .overlay(Circle().fill(Color(white: 0.08)).frame(width: 9, height: 9).offset(x: 30))
        }
        .tint(MouthyTheme.orange)
        let url = try renderOffscreen(view, size: size, name: name, settle: 0.8)
        if let url { assertNoBlue(url) }
    }
}

/// MOUTHY_RENDER_DIR=<dir>: the Meetings page empty, with past meetings, at the default window width.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil))
func meetingsRendersForVisualReview() throws {
    Mascot.install()
    defer { NotchArt.mascot = nil }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-meetings-render-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: LocalStore(directory: root.appendingPathComponent("support")), enablesHotkey: false)
    let suite = "mouthy-meetings-render-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let empty = MeetingLibrary(defaults: defaults)
    let size = CGSize(width: 860, height: 760)
    func page(_ library: MeetingLibrary) -> some View {
        ZStack { MouthyBackdrop(); MeetingsView(model: model, meeting: model.meeting, library: library) }
            .tint(MouthyTheme.orange)
            .foregroundStyle(MouthyTheme.cream)
    }
    if let url = try renderOffscreen(page(empty), size: size, name: "meetings-empty") { assertNoBlue(url) }

    let filled = MeetingLibrary(defaults: defaults)
    for (index, notes) in [true, false, false].enumerated() {
        let folder = root.appendingPathComponent("Mouthy meeting 2026-10-0\(index + 1)T09-30-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeSilence(seconds: Double(90 + index * 600), to: folder.appendingPathComponent("Microphone.wav"))
        if notes { try "# Notes".write(to: folder.appendingPathComponent("Meeting notes.md"), atomically: true, encoding: .utf8) }
        filled.remember(folder)
    }
    if let url = try renderOffscreen(page(filled), size: size, name: "meetings-past") { assertNoBlue(url) }
}

/// A short 16 kHz mono WAV of silence (for duration only).
private func writeSilence(seconds: Double, to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * 16_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    try file.write(from: buffer)
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_RENDER_TRANSCRIPT"] != nil))
func renderTranscript() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOUTHY_RENDER_TRANSCRIPT"]!)
    let view = try #require(TranscriptView(folder: folder) {}).frame(width: 760, height: 360).background(Palette.background).preferredColorScheme(.dark)
    let renderer = ImageRenderer(content: view); renderer.scale = 2
    let image = try #require(renderer.cgImage)
    try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("transcript.png"))
}
