import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch

/// The menu bar panel: the giraffe for the current state, one big Record/Stop, the mode for the next
/// dictation, the last result and the recent ones, then the way into the app.
struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingRecorder
    @ObservedObject var recent: RecentResults
    @State private var copied = false
    @State private var cheering = false
    @State private var cheerTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, recent: RecentResults? = nil) {
        self.model = model; self.meeting = model.meeting; self.recent = recent ?? .shared
    }

    private var meetingActive: Bool { meeting.recording || meeting.working }
    private var lastResult: String { model.output.isEmpty ? model.history.first?.text ?? "" : model.output }
    private var recentItems: [String] {
        MenuBarPanel.recent(items: recent.items, history: model.history.map(\.text), excluding: lastResult)
    }
    private var pose: MascotPose {
        MenuPanelState.pose(phase: model.phase, status: model.status, agentQuestion: model.agentQuestion, meeting: meetingActive, cheering: cheering)
    }

    /// Up to three recent results that are not the one already shown: memory first, then history.
    static func recent(items: [String], history: [String], excluding last: String) -> [String] {
        let source = items.isEmpty ? history : items
        var seen = Set<String>(), result: [String] = []
        for item in source where item != last && !item.isEmpty && seen.insert(item).inserted {
            result.append(item)
            if result.count == 3 { break }
        }
        return result
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 14) {
                header
                recordButton
                if !model.preferences.modes.isEmpty { modeRow }
                if !lastResult.isEmpty { lastResultCard }
                if !recentItems.isEmpty { recentList }
                footer
            }
            .padding(16)
        }
        .frame(width: 320)
        .background(MouthyBackdrop(glow: 0.14, listening: model.phase == .listening))
        .tint(MouthyTheme.orange)
        .preferredColorScheme(.dark)
        .foregroundStyle(MouthyTheme.cream)
        .onChange(of: model.phase) { old, new in celebrate(from: old, to: new) }
        .onDisappear { cheerTask?.cancel(); cheering = false }
    }

    /// A delivery cheers for 1.2 s, then the giraffe goes back to sleep.
    private func celebrate(from old: AppModel.Phase, to new: AppModel.Phase) {
        guard new == .idle, [.finishing, .delivering].contains(old), MenuPanelState.isSuccess(model.status) else {
            if new != .idle { cheerTask?.cancel(); cheering = false }
            return
        }
        cheerTask?.cancel()
        cheering = true
        cheerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            cheering = false
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            MascotView(pose: pose, size: 96, glowLevel: model.phase == .listening ? model.level : nil, glowFeed: model.voice)
            VStack(alignment: .leading, spacing: 4) {
                Text(MenuPanelState.headline(phase: model.phase, agentQuestion: model.agentQuestion, meeting: meetingActive))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(MouthyTheme.cream)
                    .contentTransition(.interpolate)
                if let detail = MenuPanelState.detail(status: model.status, phase: model.phase, agentQuestion: model.agentQuestion) {
                    Text(detail).font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2).lineLimit(2)
                } else if !model.busy {
                    HStack(spacing: 6) {
                        KeycapRow(shortcut: model.shortcutLabel)
                        Text(model.preferences.shortcut == 4 ? "double-tap to dictate"
                             : model.preferences.shortcut == 5 || model.preferences.holdToTalk ? "hold to talk" : "to dictate")
                            .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    }
                }
                if model.phase == .listening {
                    ElapsedTimeView(clock: model.clock) { elapsed in
                        Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(MouthyTheme.glow)
                            .contentTransition(.numericText(value: elapsed))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: pose)
    }

    private var recordButton: some View {
        Button {
            if meetingActive || model.busy { model.stop() } else { MenuPanelActions.startDictation(model) }
        } label: {
            Label(meetingActive ? "Stop Meeting" : model.busy ? "Stop" : "Record",
                  systemImage: meetingActive || model.busy ? "stop.fill" : "mic.fill")
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.mouthyPrimary)
        .disabled(model.setupBusy || model.phase == .cancelling)
        .accessibilityHint(model.busy ? "Finishes and pastes into the focused app" : "Starts dictating into the app you were using")
    }

    private var modeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
            Text(model.busy ? "Mode" : "Next mode").font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
            Spacer()
            WarmPicker("Mode", selection: Binding(get: { modeSelection }, set: { model.pick(mode: $0) }),
                       options: [(UUID?.none, model.busy ? (model.activeModeName ?? "Settings") : "Automatic")]
                        + model.preferences.modes.map { (Optional($0.id), $0.name) })
        }
    }

    /// While dictating the picker shows the running mode; otherwise the one picked for next time.
    private var modeSelection: UUID? {
        if model.busy, let name = model.activeModeName { return model.preferences.modes.first { $0.name == name }?.id }
        return model.pickedModeID
    }

    private var lastResultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last result").font(MouthyType.section).foregroundStyle(MouthyTheme.cream2)
                Spacer()
                MouthyIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    TextDelivery.copy(lastResult); copied = true
                }
                .contentTransition(.symbolEffect(.replace))
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.4)); copied = false
                }
                MouthyIconButton(symbol: "arrow.down.doc", help: "Paste into the focused app (⌃⌘V)") { MenuPanelActions.pasteLast(model) }
                    .keyboardShortcut("v", modifiers: [.control, .command])
                    .disabled(model.busy)
            }
            Text(lastResult)
                .font(MouthyType.callout).foregroundStyle(MouthyTheme.cream)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous).fill(MouthyTheme.surface.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent").font(MouthyType.section).foregroundStyle(MouthyTheme.cream2).padding(.bottom, 4)
            ForEach(recentItems, id: \.self) { item in
                Button { TextDelivery.copy(item); model.status = "Copied." } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.quote").font(.system(size: 10, weight: .semibold)).foregroundStyle(MouthyTheme.cream3)
                        Text(item).font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(MouthyPressableStyle())
                .help("Copy")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open Mouthy") { model.openWorkspace?() }
                .buttonStyle(.compact)
            Button("Settings") { model.selectedPage = "Settings"; model.openWorkspace?() }
                .buttonStyle(.compact)
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.compact)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.top, 2)
    }
}

/// Panel actions that hand focus back first, so the text goes to the app the person was using rather than
/// to Mouthy (delivery follows focus).
@MainActor
enum MenuPanelActions {
    static func startDictation(_ model: AppModel) {
        stepAside { if !model.busy { model.begin(captureTarget: true) } }
    }

    static func pasteLast(_ model: AppModel) {
        stepAside { model.pasteLast() }
    }

    /// Closes the panel and returns focus to the previous app, leaving a visible main window in place, then runs
    /// `work`. Hiding the app also hides the notch hub and the recording island, so they come back (without
    /// taking focus) before the dictation or paste starts.
    private static func stepAside(then work: @escaping @MainActor () -> Void) {
        let mainVisible = NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible }
        NSApp.keyWindow?.orderOut(nil)
        if mainVisible { NSApp.deactivate() } else { NSApp.hide(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                if !mainVisible { NSApp.unhideWithoutActivation() }
                work()
            }
        }
    }
}
