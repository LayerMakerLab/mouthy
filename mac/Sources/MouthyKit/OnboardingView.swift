import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch

/// First run in three screens: hello and the microphone, Accessibility, then a first dictation that finishes setup.
/// The speech model gets ready in the background meanwhile, and the shortcut is picked where it is first used.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case hello, accessibility, tryIt
    var id: Int { rawValue }

    var pose: MascotPose {
        switch self {
        case .hello: .cheer
        case .accessibility: .type
        case .tryIt: .listen
        }
    }

    var title: String {
        switch self {
        case .hello: "Hello. I'm Mouthy."
        case .accessibility: "Let me type for you"
        case .tryIt: "Say something"
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// The practice box text: the finished result once one arrives, otherwise the live words.
enum PracticeText {
    /// The live words read the way they will land: "Hello comma" shows as "Hello,".
    static func shown(practice: String, live: String, listening: Bool) -> String {
        if listening, !live.isEmpty { return SpokenPunctuation.apply(live) }
        return practice
    }
}

/// First run: a mascot stage on the left and one step at a time on the right.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let finish: () -> Void
    @State private var step: OnboardingStep
    @State private var practice: String
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `step` and `practice` start elsewhere only for renders and tests.
    init(model: AppModel, step: OnboardingStep = .hello, practice: String = "", finish: @escaping () -> Void) {
        self.model = model; self.finish = finish
        _step = State(initialValue: step); _practice = State(initialValue: practice)
    }

    private var pageMotion: Animation { reduceMotion ? MouthyMotion.reduced : .spring(response: 0.42, dampingFraction: 0.85) }

    var body: some View {
        ZStack {
            MouthyBackdrop(glow: 0.12, listening: model.phase == .listening)
            HStack(spacing: 0) {
                stage
                    .frame(width: 300)
                    .padding(.vertical, 12).padding(.leading, 12)
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        page(step)
                            .id(step)
                            .transition(reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading).combined(with: .opacity))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    footer
                }
                .padding(.leading, 30).padding(.trailing, 24).padding(.top, 52).padding(.bottom, 24)
            }
        }
        .frame(width: 760, height: 500)
        .tint(MouthyTheme.orange)
        .preferredColorScheme(.dark)
        .foregroundStyle(MouthyTheme.cream)
        .sensoryFeedback(.selection, trigger: step)
        .task { await model.refreshCapabilities() }
        // No timer: permissions are re-read when Mouthy or another app comes forward (System Settings and back).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in model.refreshPermissions() }
        .onChange(of: model.output) { _, output in
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { withAnimation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion)) { practice = trimmed } }
        }
    }

    // MARK: Stage

    private var stagePose: MascotPose {
        if step == .tryIt {
            if model.phase == .preparing || model.phase == .listening { return .listen }
            if model.phase == .finishing || model.phase == .delivering { return .type }
            return practice.isEmpty ? .listen : .cheer
        }
        return step.pose
    }

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MouthyTheme.Radius.sidebar, style: .continuous)
                .fill(MouthyTheme.surface.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: MouthyTheme.Radius.sidebar, style: .continuous)
                    .fill(RadialGradient(colors: [MouthyTheme.orange.opacity(0.28), .clear], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 210)))
                .overlay(RoundedRectangle(cornerRadius: MouthyTheme.Radius.sidebar, style: .continuous).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
            Ellipse()
                .fill(RadialGradient(colors: [.black.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 90))
                .frame(width: 190, height: 34)
                .offset(y: 118)
            Group {
                if step == .hello {
                    Giraffe3DView(fallbackPose: .cheer, size: 250)
                        .transition(.opacity)
                } else {
                    MascotView(pose: stagePose, size: 250,
                               glowLevel: step == .tryIt && model.phase == .listening ? model.level : nil, glowFeed: model.voice)
                        .transition(.opacity)
                }
            }
            .offset(y: -6)
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
                    Text("Everything runs on this Mac").font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                }
                .padding(.bottom, 18)
            }
        }
        .animation(pageMotion, value: step == .hello)
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ step: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title(for: step))
                .font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.5)
                .foregroundStyle(MouthyTheme.cream)
                .fixedSize(horizontal: false, vertical: true)
            Text(blurb(for: step))
                .font(.system(size: 15)).foregroundStyle(MouthyTheme.cream2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            content(for: step)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How to start with the chosen shortcut, mid-sentence: "double-tap Right ⌘", "hold Fn", "press ⌃⌥Space".
    static func shortcutAction(preset: Int, label: String) -> String {
        preset == 4 ? "double-tap Right ⌘" : preset == 5 ? "hold Fn" : "press " + label.replacingOccurrences(of: " ", with: "")
    }
    private var shortcutAction: String { Self.shortcutAction(preset: model.preferences.shortcut, label: model.shortcutLabel) }

    private var heard: Bool { !practice.isEmpty && !recording }
    private var recording: Bool { model.phase == .preparing || model.phase == .listening }
    /// Try it can run: the microphone is allowed and the speech model is on this Mac.
    private var canTry: Bool { model.microphoneAllowed && model.speechAssetsReady && !model.setupBusy }

    private func title(for step: OnboardingStep) -> String {
        step == .tryIt && heard ? "You're set" : step.title
    }

    private func blurb(for step: OnboardingStep) -> String {
        switch step {
        case .hello: "Talk, and I type it where your cursor is. I listen only while you dictate."
        case .accessibility: "Allow Accessibility so I can paste into any app."
        case .tryIt:
            heard ? shortcutAction.prefix(1).uppercased() + shortcutAction.dropFirst() + " in any app and talk."
                : recording ? "Say “Hello, this is a test.” Then stop."
                : !model.speechAssetsReady && !model.setupBusy ? "Speech needs a one-time download first."
                : "Press Try it or \(shortcutAction), then talk."
        }
    }

    @ViewBuilder
    private func content(for step: OnboardingStep) -> some View {
        switch step {
        case .hello:
            VStack(alignment: .leading, spacing: 14) {
                checkRow("Microphone", granted: model.microphoneAllowed,
                         pending: model.microphoneRequestPending ? "Allow Mouthy in the dialog." : "Needed to hear you.")
                // Once allowed, pick which microphone to use; the next screens show it hears you.
                if model.microphoneAllowed {
                    HStack(spacing: 10) {
                        Text("Use").font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                        WarmPicker("Microphone", selection: $model.preferences.inputDeviceUID,
                                   options: [("", "System default")] + model.inputDevices.map { ($0.id, $0.name) }, fullWidth: true)
                            .onChange(of: model.preferences.inputDeviceUID) { model.savePreferences() }
                    }
                    .onAppear { Task { await model.refreshCapabilities() } }
                }
            }
        case .accessibility:
            checkRow("Accessibility", granted: model.accessibilityAllowed,
                     pending: "Turn Mouthy on in System Settings, then come back.")
        case .tryIt:
            VStack(alignment: .leading, spacing: 12) {
                practiceBox
                if !heard && !recording {
                    HStack(spacing: 10) {
                        Text("Shortcut").font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                        WarmPicker("Shortcut", selection: $model.preferences.shortcut, options: shortcutOptions, fullWidth: true)
                            .onChange(of: model.preferences.shortcut) { model.registerHotkey() }
                    }
                    if model.preferences.shortcut == 5 {
                        Text("Set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”.")
                            .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    }
                }
                // Only before the first try, while the speech model is not on this Mac yet: progress while it downloads.
                // Otherwise the blurb says so and the footer's one button gets it.
                if !model.speechAssetsReady && !heard && !model.busy && (model.setupBusy || model.preferences.localOnly) {
                    HStack(spacing: 8) {
                        if model.setupBusy { ProgressView().controlSize(.small).tint(MouthyTheme.glow) }
                        Text(model.setupBusy ? "Getting speech ready…" : "Downloads are off. Turn them on in Settings.")
                            .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2).lineLimit(1)
                    }
                }
            }
        }
    }

    private var shortcutOptions: [(value: Int, label: String)] {
        HotkeyService.labels.indices.map { ($0, HotkeyService.labels[$0]) } + [(4, "Double-tap Right ⌘"), (5, "Hold Fn (🌐)")]
            + (model.preferences.shortcut == 3 ? [(3, "Custom: " + model.preferences.customShortcutLabel)] : [])
    }

    private var practiceBox: some View {
        let listening = model.phase == .listening || model.phase == .preparing
        let shown = PracticeText.shown(practice: practice, live: model.liveText, listening: listening)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous)
                    .fill(MouthyTheme.raised)
                RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous)
                    .strokeBorder(listening ? MouthyTheme.glow : MouthyTheme.hoof, lineWidth: listening ? 1.5 : 1)
                if shown.isEmpty {
                    Text(listening ? "Listening…" : "Your words land here.")
                        .font(.system(size: 15)).foregroundStyle(MouthyTheme.cream3)
                        .padding(14)
                } else {
                    Text(shown)
                        .font(.system(size: 15)).foregroundStyle(listening ? MouthyTheme.cream2 : MouthyTheme.cream)
                        .lineLimit(4)
                        .contentTransition(.interpolate)
                        .padding(14)
                        .textSelection(.enabled)
                }
            }
            .frame(height: 104)
            .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: listening)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Practice result")
            .overlay(alignment: .topTrailing) {
                if heard {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(MouthyTheme.glow)
                        .padding(12)
                        .transition(.drawOnCheck(reduceMotion: reduceMotion))
                }
            }
        }
    }

    private func checkRow(_ title: String, granted: Bool, pending: String) -> some View {
        HStack(spacing: 12) {
            PermissionMark(granted: granted, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                Text(granted ? "Allowed. Thank you." : pending)
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous).fill(MouthyTheme.surface.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous)
            .strokeBorder(granted ? MouthyTheme.glow.opacity(0.45) : MouthyTheme.hoof, lineWidth: 1))
        .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: granted)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases) { item in
                    Capsule(style: .circular)
                        .fill(item == step ? MouthyTheme.glow : MouthyTheme.cream.opacity(item.rawValue < step.rawValue ? 0.45 : 0.18))
                        .frame(width: item == step ? 18 : 6, height: 6)
                }
            }
            .animation(pageMotion, value: step)
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
            Spacer()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    // A finished first run has one way out.
                    if let previous = step.previous, !(step == .tryIt && heard) {
                        Button("Back") { go(previous) }
                            .buttonStyle(.mouthySecondary)
                            .keyboardShortcut(.cancelAction)
                    }
                    actions
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
        .padding(.top, 16)
    }

    /// The step's one action and the way forward. While a requirement is pending its action is the primary
    /// button and moving on reads "Later"; once met, Next is primary.
    @ViewBuilder private var actions: some View {
        switch step {
        case .hello:
            if model.microphoneAllowed { nextButton }
            else {
                laterButton
                Button(model.microphoneRequestPending ? "Waiting…" : "Allow microphone") { model.requestMicrophone() }
                    .buttonStyle(.mouthyPrimary).disabled(model.microphoneRequestPending)
            }
        case .accessibility:
            if model.accessibilityAllowed { nextButton }
            else {
                laterButton
                Button("Open Accessibility settings") {
                    TextDelivery.requestAccessibility()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.mouthyPrimary)
            }
        case .tryIt:
            if heard {
                Button("Done") { finish() }
                    .buttonStyle(.mouthyPrimary)
                    .keyboardShortcut(.defaultAction)
            } else if recording {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.mouthyPrimary)
            } else if !model.speechAssetsReady && !model.setupBusy && !model.busy {
                laterButton
                Button("Get speech") { model.installAssets() }
                    .buttonStyle(.mouthyPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.preferences.localOnly)
            } else {
                laterButton
                Button("Try it") { model.toggle(captureTarget: false) }
                    .buttonStyle(.mouthyPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canTry || model.busy)
            }
        }
    }

    private var nextButton: some View {
        Button("Next") { if let next = step.next { go(next) } }
            .buttonStyle(.mouthyPrimary)
            .keyboardShortcut(.defaultAction)
    }

    /// Skippable steps offer "Later" in small text, so the step's own action stays the clear choice. On the last
    /// screen it finishes setup; anything skipped stays in Settings.
    private var laterButton: some View {
        LaterLink(help: step.next == nil ? "Finish setup now" : "Skip this step for now") {
            if let next = step.next { go(next) } else { finish() }
        }
    }

    private func go(_ target: OnboardingStep) {
        if model.busy && step == .tryIt { model.cancel() }
        forward = target.rawValue > step.rawValue
        withAnimation(pageMotion) { step = target }
    }
}

/// "Later" as a quiet underlined link beside the step's glass buttons, with a soft hover fill and a link pointer.
private struct LaterLink: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text("Later")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .underline(true, color: MouthyTheme.cream2.opacity(0.5))
                .foregroundStyle(hovering ? MouthyTheme.cream : MouthyTheme.cream2)
                .padding(.horizontal, 12).frame(minHeight: 32)
                .background(Capsule(style: .circular).fill(MouthyTheme.cream.opacity(hovering ? 0.07 : 0)))
                .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .help(help)
    }
}
