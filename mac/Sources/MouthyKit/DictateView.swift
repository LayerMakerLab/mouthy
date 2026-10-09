import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch

/// One usage number with its caption, floating on its own tile.
struct StatTile: View {
    let value: Int
    let label: String
    let symbol: String
    var help: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Tile(padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MouthyTheme.glow)
                Text(value.formatted())
                    .font(MouthyType.numeral)
                    .foregroundStyle(MouthyTheme.cream)
                    .contentTransition(.numericText(value: Double(value)))
                    .animation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion), value: value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label).font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2).lineLimit(1)
            }
        }
        .help(help ?? label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value.formatted()) \(label)")
    }
}

/// The Dictate page: the giraffe hero with live text, the record controls, setup and usage.
struct DictationView: View {
    @ObservedObject var model: AppModel
    @State private var cheering = false
    @State private var cheerTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var listening: Bool { model.phase == .listening }
    private var firstRun: Bool { model.stats.sessions == 0 && model.history.isEmpty && model.output.isEmpty }
    private var pose: MascotPose {
        DictateHero.pose(phase: model.phase, agentQuestion: model.agentQuestion, cheering: cheering, firstRun: firstRun)
    }
    private var showSetupTile: Bool { !model.microphoneAllowed || !model.accessibilityAllowed }
    private var readiness: DictateReadiness {
        DictateReadiness.evaluate(microphone: model.microphoneAllowed, speechAssets: model.speechAssetsReady, accessibility: model.accessibilityAllowed,
                                  localOnly: model.preferences.localOnly, setupBusy: model.setupBusy, engine: model.preferences.speechEngine)
    }

    var body: some View {
        PageScroll {
            PageHeader("Dictate") { headerControls }
            hero
            if showSetupTile {
                setupTile
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            HStack(spacing: MouthyTheme.Layout.tileGap) {
                StatTile(value: model.stats.words, label: "words dictated", symbol: "text.word.spacing")
                StatTile(value: model.stats.wordsPerMinute, label: "words per minute", symbol: "speedometer")
                StatTile(value: model.stats.minutesSaved, label: "minutes saved", symbol: "hourglass",
                         help: "Compared with typing the same words at \(Int(UsageStats.typingWordsPerMinute)) words per minute")
            }
            if !model.busy {
                resultTile
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.page, reduceMotion: reduceMotion), value: model.busy)
        .animation(MouthyMotion.resolve(MouthyMotion.page, reduceMotion: reduceMotion), value: model.microphoneAllowed && model.accessibilityAllowed)
        .onChange(of: model.phase) { old, new in celebrate(from: old, to: new) }
        .onDisappear { cheerTask?.cancel(); cheering = false }
        .sensoryFeedback(.success, trigger: cheering) { _, now in now }
    }

    // MARK: Header

    private var headerControls: some View {
        HStack(spacing: 8) {
            // The engine, in the same 30 pt glass capsule as the style menu beside it and the other pages' header
            // buttons, so the header reads as one row of chrome rather than a tag next to a button.
            HStack(spacing: 6) {
                Image(systemName: model.preferences.speechEngine == .apple ? "apple.logo" : "cpu")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
                Text(model.preferences.speechEngine.label).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(MouthyTheme.cream)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .mouthyGlass(Capsule(style: .circular))
            .help("Speech engine. Change it in Settings.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Speech engine, \(model.preferences.speechEngine.label)")
            Menu {
                Picker("Writing style", selection: $model.preferences.mode) {
                    ForEach(WritingMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
                    Text(model.preferences.mode.rawValue).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(MouthyTheme.cream2)
                }
                .foregroundStyle(MouthyTheme.cream)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Capsule(style: .circular))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .mouthyGlass(Capsule(style: .circular), interactive: true)
            .disabled(model.busy)
            .opacity(model.busy ? 0.5 : 1)
            .onChange(of: model.preferences.mode) { model.savePreferences() }
            .help("Writing style for your next dictation")
            .accessibilityLabel("Writing style, \(model.preferences.mode.rawValue)")
        }
    }

    // MARK: Hero

    private var hero: some View {
        Tile(padding: 28, style: .hero) {
            VStack(spacing: 16) {
                MascotView(pose: pose, size: 220, glowLevel: model.phase == .preparing || listening ? model.level : nil, glowFeed: model.voice)
                    .padding(.bottom, -4)
                heroText
                    .frame(maxWidth: 560)
                    .frame(minHeight: 52, alignment: .top)
                if model.busy {
                    VStack(spacing: 8) {
                        MouthyWaveform(level: model.level, active: listening, sweep: model.phase == .finishing || model.phase == .delivering, feed: model.voice)
                        ElapsedTimeView(clock: model.clock) { elapsed in
                            Text(DictateHero.clock(elapsed))
                                .font(.system(size: 15, design: .rounded).monospacedDigit())
                                .foregroundStyle(MouthyTheme.cream2)
                                .contentTransition(.numericText(value: elapsed))
                                .accessibilityLabel("Elapsed \(DictateHero.clock(elapsed))")
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                actions
                if !(model.busy && readiness.isReady) {
                    readinessLine
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: pose)
    }

    @ViewBuilder private var heroText: some View {
        VStack(spacing: 6) {
            if let question = model.agentQuestion {
                Label("An agent asks", systemImage: "bubble.left.fill")
                    .font(MouthyType.caption.weight(.semibold))
                    .foregroundStyle(MouthyTheme.glow)
                Text(question)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(MouthyTheme.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Text(model.liveText.isEmpty ? "Speak, then press your shortcut · Escape cancels" : model.liveText)
                    .font(model.liveText.isEmpty ? MouthyType.callout : .system(size: 15, design: .rounded))
                    .foregroundStyle(model.liveText.isEmpty ? MouthyTheme.cream2 : MouthyTheme.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .contentTransition(.interpolate)
            } else if listening && !model.liveText.isEmpty {
                Text(model.liveText)
                    .font(.system(size: 17, design: .rounded))
                    .foregroundStyle(MouthyTheme.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .truncationMode(.head)
                    .contentTransition(.interpolate)
                    .textSelection(.enabled)
                Text(model.currentInputName + " → " + model.targetName)
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
            } else {
                if model.phase == .idle && !cheering {
                    startPrompt
                } else {
                    Text(DictateHero.headline(phase: model.phase, shortcut: model.shortcutLabel, cheering: cheering, status: model.status))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(MouthyTheme.cream)
                        .contentTransition(.opacity)
                }
                Text(heroDetail)
                    .font(MouthyType.callout)
                    .foregroundStyle(MouthyTheme.cream2)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: model.liveText)
        .accessibilityElement(children: .combine)
    }

    /// "Press [⌃][⌥][Space] to start", with the shortcut drawn as keycaps.
    private var startPrompt: some View {
        let label = model.shortcutLabel.trimmingCharacters(in: .whitespaces)
        let verb = label.hasPrefix("Hold ") ? "Hold" : label.hasPrefix("Double-tap ") ? "Double-tap" : "Press"
        return HStack(spacing: 8) {
            Text(verb)
            KeycapRow(shortcut: label)
                .scaleEffect(1.1)
            Text("to start")
        }
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .foregroundStyle(MouthyTheme.cream)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DictateHero.startPrompt(label))
    }

    private var heroDetail: String {
        switch model.phase {
        case .preparing: return "Warming up the microphone"
        case .listening:
            return model.preferences.speechEngine == .apple ? "Enter sends · Escape cancels" : "Recording on this Mac. Words appear when you finish."
        case .finishing, .delivering: return model.currentInputName + " → " + model.targetName
        case .cancelling: return "Nothing was typed"
        case .failed: return model.status
        case .idle:
            if cheering, model.targetName != "Mouthy workspace", DictateHero.outcomeWord(model.status) != nil { return "into " + model.targetName }
            return "I'll type where your cursor is, in any app. Or record here."
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { model.toggle() } label: {
                Label {
                    Text(model.busy ? "Stop" : "Record in Mouthy")
                } icon: {
                    Image(systemName: model.busy ? "stop.fill" : "mic.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(minWidth: 150)
            }
            .buttonStyle(.mouthyPrimaryLarge)
            .disabled([.finishing, .delivering, .cancelling].contains(model.phase) || model.setupBusy)
            .help("Record into this window. To type into another app, put the cursor there and press \(model.shortcutLabel).")

            if model.busy {
                Button { model.cancel() } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(.mouthySecondaryLarge)
                    .disabled(model.phase == .delivering || model.phase == .cancelling)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Button { model.importAudio() } label: { Label("Import audio", systemImage: "arrow.up.doc") }
                    .buttonStyle(.mouthySecondaryLarge)
                    .disabled(model.setupBusy)
                    .help("Transcribe an audio or video file on this Mac")
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.top, 4)
        .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: model.busy)
    }

    /// One line naming exactly what is missing, with the one button that fixes it.
    private var readinessLine: some View {
        let state = readiness
        return HStack(spacing: 8) {
            if state == .downloading {
                ProgressView().controlSize(.small).tint(MouthyTheme.orange)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.isReady ? MouthyTheme.glow : MouthyTheme.ember)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(state.message)
                .font(MouthyType.callout)
                .foregroundStyle(state.isReady ? MouthyTheme.cream2 : MouthyTheme.cream)
                .lineLimit(2)
            // The setup tile below carries the same buttons; one of each is enough.
            if let title = state.actionTitle, !(showSetupTile && setupTileCovers(state)) {
                Button(title) { fix(state) }
                    .buttonStyle(.compactGlass)
                    .disabled(state == .microphone && model.microphoneRequestPending)
            }
        }
        .padding(.top, 2)
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: state)
        .accessibilityElement(children: .combine)
    }

    /// The setup tile has its own row (and button) for these.
    private func setupTileCovers(_ state: DictateReadiness) -> Bool {
        switch state {
        case .microphone, .accessibility, .speechModel: true
        case .downloading, .localOnly, .ready: false
        }
    }

    private func fix(_ state: DictateReadiness) {
        switch state {
        case .microphone: model.requestMicrophone()
        case .speechModel: model.installAssets()
        case .localOnly: model.selectedPage = WorkspacePage.settings.rawValue
        case .accessibility: openAccessibility()
        case .downloading, .ready: break
        }
    }

    private func openAccessibility() {
        TextDelivery.requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    // MARK: Setup

    private var setupTile: some View {
        Tile {
            VStack(alignment: .leading, spacing: 4) {
                TileHeader("Make it yours", symbol: "sparkles") {
                    Button("All settings") { model.selectedPage = WorkspacePage.settings.rawValue }
                        .buttonStyle(.compactGlass)
                }
                .padding(.bottom, 6)
                setupRow(done: model.microphoneAllowed, title: "Microphone", detail: "I listen only while you dictate or record a meeting you started.") {
                    Button("Allow microphone") { model.requestMicrophone() }
                        .disabled(model.microphoneRequestPending)
                }
                SettingDivider()
                setupRow(done: model.accessibilityAllowed, title: "Accessibility", detail: "Lets me paste into other apps and fit the spacing and capitals already there.") {
                    Button("Open Accessibility settings") { openAccessibility() }
                }
                SettingDivider()
                setupRow(done: model.speechAssetsReady, doneLabel: "Ready", title: "Speech model", detail: model.preferences.speechEngine.label + (model.speechAssetsReady ? " is ready and works offline." : ". It downloads once, then works offline.")) {
                    if model.setupBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(MouthyTheme.orange)
                            Text("Downloading…").font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                        }
                    } else {
                        Button("Download") { model.installAssets() }
                            .disabled(model.preferences.localOnly || model.busy)
                            .help(model.preferences.localOnly ? "Network use is blocked, so I can't download." : "Download the speech model")
                    }
                }
            }
        }
    }

    private func setupRow<Action: View>(done: Bool, doneLabel: String = "Allowed", title: String, detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(done ? MouthyTheme.glow : MouthyTheme.cream3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MouthyType.body.weight(.medium)).foregroundStyle(MouthyTheme.cream)
                Text(detail).font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Group {
                if done {
                    Text(doneLabel).font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                } else {
                    action().buttonStyle(.compactGlass).fixedSize()
                }
            }
            .frame(minWidth: 180, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    // MARK: Result

    private var resultTile: some View {
        let hasText = !model.output.isEmpty
        let canPaste = hasText || !(model.history.first?.text.isEmpty ?? true)
        return Tile {
            VStack(alignment: .leading, spacing: 12) {
                TileHeader(hasText ? "Last result" : "Your words", symbol: "text.quote") {
                    if hasText {
                        GlassEffectContainer(spacing: 6) {
                            HStack(spacing: 6) {
                                MouthyIconButton(symbol: "sparkles", help: "Refine with Apple Intelligence") { model.rewriteOutput() }
                                    .disabled(!model.intelligenceReady)
                                    .opacity(model.intelligenceReady ? 1 : 0.4)
                                MouthyIconButton(symbol: "doc.on.doc", help: "Copy") {
                                    TextDelivery.copy(model.output); model.status = "Copied to the clipboard."
                                }
                                MouthyIconButton(symbol: "arrow.down.doc", help: "Paste last result (⌃⌘V in any app)") { model.pasteLast() }
                                MouthyIconMenu(symbol: "square.and.arrow.up", help: "Export") {
                                    Button("Text…") { model.export(model.output) }
                                    if !model.document.text.isEmpty {
                                        Divider()
                                        Button("Recognition JSON…") { model.exportDocument(model.document, format: .json) }
                                        Button("Subtitles · SRT…") { model.exportDocument(model.document, format: .srt) }
                                        Button("Subtitles · VTT…") { model.exportDocument(model.document, format: .vtt) }
                                    }
                                }
                            }
                            .padding(2)
                        }
                        .transition(.opacity)
                    } else if canPaste {
                        MouthyIconButton(symbol: "arrow.down.doc", help: "Paste last result (⌃⌘V in any app)") { model.pasteLast() }
                            .transition(.opacity)
                    }
                }
                WarmTextEditor(text: $model.output, font: .systemFont(ofSize: 15), minHeight: 44,
                               placeholder: "A blank page, without the typing.", accessibilityLabel: "Transcript editor")
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hasText)
    }

    // MARK: Cheer

    private func celebrate(from old: AppModel.Phase, to new: AppModel.Phase) {
        guard new == .idle, [.finishing, .delivering, .listening].contains(old), DictateHero.outcomeWord(model.status) != nil else {
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
}
