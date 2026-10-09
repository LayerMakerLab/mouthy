import SwiftUI
import AppKit
import Combine
import MouthyCore
import MouthyNotch

@MainActor
private final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where the recording display goes.
enum OverlayRoute: Equatable {
    /// Nothing on screen (display turned off, or a headless run).
    case none
    /// The notch hub's dictation pill.
    case hub
    /// The recording island at the top edge or in a corner.
    case island

    /// One surface: whenever the hub is on screen the dictation is its band, never an island stacked over it. The
    /// island (which joins full-screen spaces) shows only while no hub shape is on screen at all: the hub is off,
    /// or a full-screen app has hidden it (and with it every external pill).
    static func decide(showOverlay: Bool, hubRunning: Bool, headless: Bool, hubHiddenForFullScreen: Bool = false) -> OverlayRoute {
        guard showOverlay, !headless else { return .none }
        return hubRunning && !hubHiddenForFullScreen ? .hub : .island
    }
}

/// How a finished run reads at a glance: the outcome word (from APP-MICROCOPY) and whether it gets the cheering
/// giraffe and a check, the sleepy giraffe and an ember mark, or just a quiet word.
struct DictationOutcome: Equatable {
    enum Kind: Equatable { case none, success, attention, neutral }
    var kind: Kind
    /// Short display text, e.g. "Inserted · Notes".
    var text: String

    static let quiet = DictationOutcome(kind: .none, text: "")

    /// Statuses that end on a check mark, longest prefixes first.
    static let successWords: [(prefix: String, word: String, namesApp: Bool)] = [
        ("Answer sent to the agent", "Sent to the agent", false),
        ("Sent to the agent", "Sent to the agent", false),
        ("Inserted", "Inserted", true),
        ("Pasted", "Pasted", true),
        ("Sent", "Sent", true),
        ("Copied", "Copied", false),
        ("Last result copied", "Copied", false),
        ("Saved to history", "Saved to history", false),
        ("Saved", "Saved", false),
        ("Opened", "Opened", false),
        ("Searched", "Searched", false),
        ("Ran", "Ran", false),
        ("Ready. Review", "Ready to review", false),
        ("Meeting saved", "Meeting saved", false),
        ("Meeting stopped", "Meeting saved", false),
        ("Two-hour limit", "Meeting saved", false),
        ("Batch finished", "Files ready", false)
    ]

    /// Statuses that need a second look, with the words the pill shows.
    static let attentionWords: [(prefix: String, word: String)] = [
        ("Ready to copy. A password field", "Not into a password field"),
        ("Ready to copy. No other app is focused", "Nowhere to type"),
        ("Ready to copy. Focus changed", "The cursor moved"),
        ("Ready to copy. The selection changed", "The selection changed"),
        ("Ready to copy. Enable Accessibility", "Needs Accessibility"),
        ("Ready to copy. The focused item", "Nowhere to type"),
        ("Ready to copy", "Ready to copy"),
        ("Text copied", "Copied · paste it yourself"),
        ("Microphone", "Check the microphone"),
        ("Enable Mouthy", "Needs permission"),
        ("Allow microphone", "Needs the microphone"),
        ("Transcription timed out", "That took too long"),
        ("That took too long", "That took too long"),
        ("Command failed", "That didn't work"),
        ("Selection was not changed", "The selection changed"),
        ("Meeting notes failed", "Notes didn't finish"),
        ("That part could not be sent", "Not sent")
    ]

    /// Maps the model's status line (and phase) to an outcome. `target` names the app when the status doesn't.
    static func from(status: String, failed: Bool, target: String) -> DictationOutcome {
        let status = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = attentionWords.first(where: { status.hasPrefix($0.prefix) }) {
            return DictationOutcome(kind: .attention, text: match.word)
        }
        // Nothing said: nothing to show.
        if ["No speech", "No final transcript", "No text to insert"].contains(where: status.hasPrefix) { return quiet }
        if status.hasPrefix("Cancelled") || status.hasPrefix("Meeting cancelled") {
            return DictationOutcome(kind: .neutral, text: "Cancelled")
        }
        if failed { return DictationOutcome(kind: .attention, text: "Needs attention") }
        if let match = successWords.first(where: { status.hasPrefix($0.prefix) }) {
            guard match.namesApp, let app = appName(in: status) ?? usableTarget(target) else {
                return DictationOutcome(kind: .success, text: match.word)
            }
            return DictationOutcome(kind: .success, text: match.word + " · " + app)
        }
        return quiet
    }

    /// The app named in a delivery status: "Inserted into Notes." / "Sent in Messages." -> Notes / Messages.
    static func appName(in status: String) -> String? {
        for marker in [" into ", " in "] {
            guard let range = status.range(of: marker) else { continue }
            var name = String(status[range.upperBound...])
            if let stop = name.range(of: ". ") { name = String(name[..<stop.lowerBound]) }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
            if !name.isEmpty { return name }
        }
        return nil
    }

    private static func usableTarget(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "Mouthy workspace" || trimmed == "Meeting audio files" ? nil : trimmed
    }

    /// How long the island keeps the outcome before tucking away.
    var holdMilliseconds: Int {
        switch kind {
        case .success: 900
        case .attention: 1_600
        case .neutral: 700
        case .none: 120
        }
    }
}

@MainActor
final class OverlayController {
    private let panel: NSPanel
    private unowned let model: AppModel
    private var screenObserver: NSObjectProtocol?
    private let presenter = IslandPresenter()
    private var geometry: IslandGeometry?
    private var retract: Task<Void, Never>?
    /// Mirrors the model into the notch pill; exists only while the hub shows a dictation.
    private var hubLink: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        panel = RecordingPanel(contentRect: .zero,
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.setAccessibilityLabel("Mouthy microphone")
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Mid-dictation the display must follow the new geometry, not vanish. Busy work that never
                // showed a display (Refine, file batches) must not conjure one that nothing will hide.
                if self.model.busy { if self.displayUp { self.show() } } else { self.hide() }
            }
        }
        followHubFullScreen()
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }

    /// Mid-dictation, a full-screen app hiding the hub moves the display to the island (and back).
    func followHubFullScreen() {
        NotchHub.shared.onFullScreenChange = { [weak self] _ in
            guard let self, self.model.busy, self.model.preferences.showOverlay, self.displayUp else { return }
            self.show()
        }
    }

    /// True while a dictation or meeting display is actually on screen (the hub pill or the island).
    var displayUp: Bool { hubLink != nil || panel.isVisible }

    /// The screen being worked on: the one under the pointer, else the main display.
    private func activeScreen() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }
            ?? NSScreen.screens.first
    }

    private var route: OverlayRoute {
        OverlayRoute.decide(showOverlay: model.preferences.showOverlay, hubRunning: NotchHub.shared.isRunning, headless: CommandLine.arguments.contains("--headless"),
                            hubHiddenForFullScreen: NotchHub.shared.isHiddenForFullScreen)
    }

    func show() {
        switch route {
        case .none:
            dropHubLink(endingDictation: true)
            tearDownIsland()
        case .hub:
            tearDownIsland()
            linkHub()
        case .island:
            dropHubLink(endingDictation: true)
            showIsland()
        }
    }

    /// Ends the session's display: a brief outcome (check or attention mark), then the pill or island tucks
    /// back into the screen edge. Nothing stays on screen while Mouthy is idle.
    func hide() {
        guard panel.isVisible || hubLink != nil else { return }
        if model.busy && model.preferences.showOverlay { return }
        let outcome = DictationOutcome.from(status: model.status, failed: model.phase == .failed, target: model.targetName)
        if hubLink != nil {
            dropHubLink(endingDictation: false)
            switch outcome.kind {
            // Words that landed need no word about it; only something that needs the person leaves a mark.
            case .attention: NotchHub.shared.endDictation(result: outcome.text, ok: false)
            case .success, .none, .neutral: NotchHub.shared.endDictation()
            }
        }
        guard panel.isVisible else { return }
        // Only something that needs the person stays a moment (as an ember dot); everything else tucks away at once.
        let attention = outcome.kind == .attention
        presenter.outcome = attention ? .attention : .none
        presenter.message = attention ? outcome.text : ""
        retract?.cancel()
        retract = Task { @MainActor [presenter, panel] in
            try? await Task.sleep(for: .milliseconds(attention ? outcome.holdMilliseconds : DictationOutcome.quiet.holdMilliseconds))
            guard !Task.isCancelled else { return }
            presenter.presented = false
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled, !presenter.presented else { return }
            panel.orderOut(nil)
            // Drop the view so no animation or layout runs while Mouthy is idle.
            panel.contentView = nil
            presenter.outcome = .none
            presenter.message = ""
        }
    }

    // MARK: Notch hub

    /// The pill's state for the model right now, or nil when nothing is being dictated.
    nonisolated static func notchState(phase: AppModel.Phase, level: Float, liveText: String, question: String?, target: String) -> NotchDictation? {
        let prompt = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usablePrompt = (prompt?.isEmpty ?? true) ? nil : prompt
        switch phase {
        case .preparing, .listening:
            return NotchDictation(target: target, level: phase == .listening ? level : 0, partialText: liveText, prompt: usablePrompt)
        case .finishing, .delivering:
            return NotchDictation(target: target, partialText: liveText, transcribing: true, prompt: usablePrompt)
        case .idle, .cancelling, .failed:
            return nil
        }
    }

    private func linkHub() {
        retract?.cancel(); retract = nil
        guard hubLink == nil else { return }
        let hub = NotchHub.shared
        var started: Date?
        hubLink = Publishers.CombineLatest4(model.$phase, model.voice.levels, model.$liveText, model.$agentQuestion)
            .combineLatest(model.$targetName)
            .map { values, target -> NotchDictation? in
                if values.0 == .listening, started == nil { started = Date() }
                var state = Self.notchState(phase: values.0, level: values.1, liveText: values.2, question: values.3, target: target)
                state?.startedAt = started
                return state
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { state in
                guard let state else { return }
                hub.presentDictation(state)
            }
    }

    private func dropHubLink(endingDictation: Bool) {
        guard hubLink != nil else { return }
        hubLink = nil
        if endingDictation, NotchHub.shared.dictation != nil { NotchHub.shared.endDictation() }
    }

    // MARK: Island

    private func tearDownIsland() {
        retract?.cancel(); retract = nil
        guard panel.isVisible || panel.contentView != nil else { return }
        presenter.presented = false
        panel.orderOut(nil)
        panel.contentView = nil
        geometry = nil
    }

    private func showIsland() {
        guard let screen = activeScreen() else { panel.orderOut(nil); return }
        retract?.cancel(); retract = nil
        let next = RecordingPlacement.island(screen: screen.frame, visible: screen.visibleFrame,
                                             notchLeft: screen.auxiliaryTopLeftArea?.maxX, notchRight: screen.auxiliaryTopRightArea?.minX,
                                             notchHeight: screen.safeAreaInsets.top,
                                             corner: IslandCorner(rawValue: model.preferences.islandCorner) ?? .bottomRight)
        if next != geometry || !panel.isVisible || panel.contentView == nil {
            geometry = next
            presenter.presented = false
            panel.setFrame(next.panel, display: false)
            panel.contentView = NSHostingView(rootView: RecordingIsland(model: model, presenter: presenter, geometry: next)
                .tint(MouthyTheme.orange)
                .preferredColorScheme(.dark))
        }
        // Above the menu bar so the island reads as part of the screen edge, and above other
        // notch apps so the waveform appears to grow out of their notch.
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.mainMenu.rawValue + 2, Self.notchUtilityLayer()) + 1)
        panel.orderFrontRegardless()
        presenter.outcome = .none
        presenter.message = ""
        DispatchQueue.main.async { [presenter] in presenter.presented = true }
    }

    /// The highest window layer used by a running notch utility, or 0.
    static func notchUtilityLayer() -> Int {
        let owners: Set<String> = ["com.omninotch.app"]
        let pids = Set(NSWorkspace.shared.runningApplications.filter { owners.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
        guard !pids.isEmpty, let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return windows.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }
            .compactMap { $0[kCGWindowLayer as String] as? Int }.max() ?? 0
    }
}
