import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch
import UniformTypeIdentifiers

/// Settings: floating tiles of SettingRows. Changes persist through the model's autosave; only side effects
/// (hotkey, engine capabilities, overlay, notch hub, agent server) run here.
struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @State private var recordingShortcut = false
    @State private var showNotchTabs = false
    @State private var showAbout = false
    @State private var copiedConnect = false
    /// Rarely used controls wait behind one "More options" button so first open stays short.
    @State private var showMore: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, showMore: Bool = false) {
        self.model = model
        _showMore = State(initialValue: showMore)
    }

    private var everythingGranted: Bool { model.microphoneAllowed && model.accessibilityAllowed }

    var body: some View {
        PageScroll {
            PageHeader("Settings", subtitle: "Everything here stays on this Mac.") {
                if model.busy { BusyCapsule().transition(.opacity.combined(with: .scale(scale: 0.94))) }
            }
            .animation(MouthyMotion.resolve(MouthyMotion.toast, reduceMotion: reduceMotion), value: model.busy)

            // Granting a permission cannot disturb a dictation, so setup stays live and fully opaque.
            setupTile

            Group {
                speechTile.disabled(model.setupBusy)
                SpeechModelsSettings(model: model)
                shortcutTile
                notchTile
                soundTile
                writingTile
                privacyTile
                moreTile
            }
            .disabled(model.busy)
            .opacity(model.busy ? 0.6 : 1)
            .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: model.busy)

            aboutTile
            welcomeTile
        }
        .sheet(isPresented: $showAbout) { AboutView(model: model) { showAbout = false } }
        .onDisappear { if recordingShortcut { recordingShortcut = false; model.registerHotkey() } }
        .onChange(of: model.preferences.speechEngine) { Task { await model.refreshCapabilities() }; model.prewarmSpeech() }
        .onChange(of: model.preferences.locale) { Task { await model.refreshCapabilities() } }
        .onChange(of: model.preferences.whisperModel) {
            if !model.preferences.whisperModel.supportsTranslation { model.preferences.whisperTranslateToEnglish = false }
            Task { await model.refreshCapabilities() }; model.prewarmSpeech()
        }
        .onChange(of: model.preferences.shortcut) { model.registerHotkey() }
        .onChange(of: model.preferences.showOverlay) { model.overlay?.hide() }
        .onChange(of: model.preferences.islandCorner) { model.overlay?.hide() }
        .onChange(of: model.preferences.notchHub) { MouthyTabs.setHub(enabled: model.preferences.notchHub) }
        .onChange(of: model.preferences.agentVoice) {
            if model.preferences.agentVoice { model.agentServer.start() } else { model.agentServer.stop() }
        }
    }

    // MARK: Tiles

    private var setupTile: some View {
        SettingsTile(everythingGranted ? "Permissions" : "Setup", symbol: everythingGranted ? "checkmark.shield" : "sparkles") {
            PermissionRow("Microphone",
                          detail: model.microphoneRequestPending ? "Waiting for macOS. Allow Mouthy in the dialog." : "Listens only while you dictate.",
                          granted: model.microphoneAllowed) {
                if !model.microphoneAllowed {
                    Button(model.microphoneRequestPending ? "Waiting…" : "Allow microphone") { model.requestMicrophone() }
                        .buttonStyle(.compactProminent)
                        .disabled(model.microphoneRequestPending)
                } else {
                    grantedLabel
                }
            }
            SettingDivider()
            PermissionRow("Accessibility", detail: "Pastes into the app you are using.", granted: model.accessibilityAllowed) {
                if !model.accessibilityAllowed {
                    Button("Open Accessibility settings") {
                        TextDelivery.requestAccessibility()
                        openPrivacyPane("Privacy_Accessibility")
                    }
                    .buttonStyle(.compactProminent)
                    .accessibilityLabel("Open Accessibility Settings")
                } else {
                    grantedLabel
                }
            }
            SettingDivider()
            SettingRow("Open at login", detail: "Start Mouthy quietly in the menu bar.", controlWidth: nil) {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })).labelsHidden().toggleStyle(.warmSwitch)
            }
        }
    }

    private var grantedLabel: some View {
        Text("Allowed").font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundStyle(MouthyTheme.cream2)
    }

    private var speechTile: some View {
        SettingsTile("Speech", symbol: "waveform") {
            SettingRow("Listen with", detail: engineDetail) {
                WarmPicker("Speech engine", selection: $model.preferences.speechEngine,
                           options: model.availableEngines.map { ($0, $0.label) })
            }
            SettingDivider()
            if model.preferences.speechEngine == .apple {
                SettingRow("Language") {
                    WarmPicker("Speech language", selection: $model.preferences.locale,
                               options: [("auto", "Keyboard language")] + model.languages.map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) })
                }
                SettingDivider()
            }
            if model.preferences.speechEngine == .whisper {
                SettingRow("Whisper model") {
                    WarmPicker("Whisper model", selection: $model.preferences.whisperModel,
                               options: WhisperModel.allCases.map { ($0, $0.label) })
                }
                SettingDivider()
                SettingRow("Whisper language", detail: "auto, en, es, fr…") {
                    MouthyField("auto", text: $model.preferences.whisperLanguage).frame(width: 120)
                }
                SettingDivider()
                SettingRow("Translate to English", detail: "Small and Medium only.", controlWidth: nil) {
                    Toggle("Translate to English", isOn: $model.preferences.whisperTranslateToEnglish).labelsHidden().toggleStyle(.warmSwitch)
                        .disabled(!model.preferences.whisperModel.supportsTranslation)
                }
                SettingDivider()
            }
            SettingRow("Microphone") {
                WarmPicker("Audio input", selection: $model.preferences.inputDeviceUID,
                           options: [("", "System default")] + model.inputDevices.map { ($0.id, $0.name) })
            }
            if model.preferences.speechEngine != .apple {
                SettingDivider()
                VoiceTrainingRows(model: model, trainer: model.voiceTrainer)
            }
        }
    }

    private var engineDetail: String {
        switch model.preferences.speechEngine {
        case .apple: "Live text while you speak."
        case .parakeet: "NVIDIA Parakeet, on this Mac."
        case .whisper: "OpenAI Whisper, on this Mac."
        }
    }
    private var shortcutTile: some View {
        SettingsTile("Shortcut", symbol: "command") {
            SettingRow("Start and finish", detail: "Press once to start and once to finish.") {
                WarmPicker("Shortcut", selection: $model.preferences.shortcut, options: shortcutOptions)
            }
            if model.preferences.shortcut == 3 || recordingShortcut {
                SettingDivider()
                SettingRow("Custom shortcut", detail: recordingShortcut ? "Press a key with ⌘, ⌃ or ⌥. Escape cancels." : "Click to record a new one.") {
                    ShortcutRecorder(label: model.preferences.customShortcutLabel, recording: $recordingShortcut,
                                     begin: { model.hotkeySuspended = true },
                                     end: { key, modifiers, label in
                                         if let key, let modifiers, let label {
                                             model.preferences.customKeyCode = key
                                             model.preferences.customModifiers = modifiers
                                             model.preferences.customShortcutLabel = label
                                             model.preferences.shortcut = 3
                                         }
                                         model.registerHotkey()
                                     })
                }
            }
            if model.preferences.shortcut < 4 {
                SettingDivider()
                SettingRow("Style", detail: styleDetail) {
                    WarmSegmented("Shortcut style", selection: Binding(
                        get: { model.preferences.automaticActivation ? 2 : model.preferences.holdToTalk ? 1 : 0 },
                        set: { model.preferences.automaticActivation = $0 == 2; model.preferences.holdToTalk = $0 == 1 }),
                                  options: [(0, "Toggle"), (1, "Hold"), (2, "Automatic")])
                }
            }
            if model.preferences.shortcut == 5 {
                Text("In System Settings → Keyboard, set “Press 🌐 key to” to “Do Nothing” so macOS doesn't also open emoji or dictation.")
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    .padding(.bottom, 10)
            }
            SettingDivider()
            SettingRow("Paste into the focused app when finished", detail: "Off keeps the text in Mouthy to copy.", controlWidth: nil) {
                Toggle("Paste into the focused app when finished", isOn: $model.preferences.autoInsert).labelsHidden().toggleStyle(.warmSwitch)
            }
        }
    }

    private var shortcutOptions: [(value: Int, label: String)] {
        HotkeyService.labels.indices.map { ($0, HotkeyService.labels[$0]) }
            + [(3, "Custom: " + model.preferences.customShortcutLabel), (4, "Double-tap Right ⌘"), (5, "Hold Fn (🌐)")]
    }
    private var styleDetail: String {
        if model.preferences.automaticActivation { return "Tap to toggle, or hold and release." }
        return model.preferences.holdToTalk ? "Hold while you talk, release to finish." : "Enter sends · Escape cancels."
    }

    private var notchTile: some View {
        SettingsTile("Notch", symbol: "rectangle.topthird.inset.filled") {
            SettingRow("Show while recording", detail: "A small pill in the notch, or a little island on Macs without one.", controlWidth: nil) {
                Toggle("Show recording display", isOn: $model.preferences.showOverlay).labelsHidden().toggleStyle(.warmSwitch)
            }
            SettingDivider()
            SettingRow("Notch hub", detail: "Hover the notch to open timers, notes, music and more. ⌃⌥N opens it too.", controlWidth: nil) {
                Toggle("Show the hub in the notch", isOn: $model.preferences.notchHub).labelsHidden().toggleStyle(.warmSwitch)
            }
            if model.preferences.notchHub {
                SettingDivider()
                SettingRow("Hub tabs", detail: "Choose what the hub shows.") {
                    Button(showNotchTabs ? "Hide" : "Customize") {
                        withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { showNotchTabs.toggle() }
                    }
                    .buttonStyle(.compact)
                }
                if showNotchTabs {
                    NotchSettingsView()
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous).fill(MouthyTheme.night.opacity(0.45)))
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var soundTile: some View {
        SettingsTile("Sound", symbol: "speaker.wave.2") {
            SettingRow("Other audio while you talk", detail: "Leave it, mute the speakers, or pause what is playing.") {
                WarmSegmented("Other audio while dictating", selection: $model.preferences.mediaWhileDictating,
                              options: MediaWhileDictating.allCases.map { ($0, $0 == .nothing ? "Leave" : $0.rawValue) })
            }
            SettingDivider()
            SettingRow("Start and stop sounds", detail: "A soft click when recording starts and ends.", controlWidth: nil) {
                Toggle("Play start and stop sounds", isOn: $model.preferences.playSounds).labelsHidden().toggleStyle(.warmSwitch)
            }
        }
    }

    private var writingTile: some View {
        SettingsTile("Writing", symbol: "pencil.and.scribble") {
            SettingRow("Style", detail: model.intelligenceReady ? "Natural keeps your words. Others rewrite on this Mac." : "Apple Intelligence isn't ready; Natural always works.") {
                WarmPicker("Writing style", selection: $model.preferences.mode, options: WritingMode.allCases.map { ($0, $0.rawValue) })
            }
            if model.preferences.mode == .custom {
                SettingDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your instructions").font(MouthyType.body).foregroundStyle(MouthyTheme.cream)
                    Text("How the Custom style rewrites your words.").font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    WarmTextBox(text: $model.preferences.customInstructions, label: "Custom writing instructions")
                        .frame(height: 76)
                }
                .padding(.vertical, 12)
            }
            SettingDivider()
            SettingRow("Remove filler words", detail: "Drops “um”, “uh” and “erm”.", controlWidth: nil) {
                Toggle("Remove filler words", isOn: $model.preferences.removeFillers).labelsHidden().toggleStyle(.warmSwitch)
            }
            SettingDivider()
            SettingRow("Rewrite selected text", detail: "Select text, then say how to change it.", controlWidth: nil) {
                Toggle("Use speech to rewrite selected text", isOn: $model.preferences.rewriteSelection).labelsHidden().toggleStyle(.warmSwitch)
            }
        }
    }

    private var privacyTile: some View {
        SettingsTile("Privacy", symbol: "lock") {
            SettingRow("Keep dictated text on this Mac", detail: "Off by default. Never leaves this Mac.", controlWidth: nil) {
                Toggle("Keep transcript history", isOn: $model.preferences.keepHistory).labelsHidden().toggleStyle(.warmSwitch)
            }
            if model.preferences.keepHistory {
                SettingDivider()
                SettingRow("Keep up to", detail: "Older entries drop off.") {
                    HStack(spacing: 10) {
                        Text("\(model.preferences.historyLimit)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText(value: Double(model.preferences.historyLimit)))
                        Stepper("History limit", value: $model.preferences.historyLimit, in: 10...1000, step: 10).labelsHidden()
                    }
                }
            }
            SettingDivider()
            SettingRow("Block all network use", detail: "Stops model downloads, update checks, lyrics, artwork and weather requests.", controlWidth: nil) {
                Toggle("Block all network use", isOn: $model.preferences.localOnly).labelsHidden().toggleStyle(.warmSwitch)
            }
            SettingDivider()
            SettingRow("Check for updates automatically", detail: model.preferences.localOnly ? "Off while network use is blocked." : "Once a day from mouthy.dev. New versions install when you quit.", controlWidth: nil) {
                Toggle("Check for updates automatically", isOn: $model.preferences.checkForUpdates).labelsHidden().toggleStyle(.warmSwitch)
                    .disabled(model.preferences.localOnly)
            }
        }
    }

    private var moreTile: some View {
        SettingsTile("More options", symbol: "slider.horizontal.3") {
            SettingRow("Everything else", detail: "Text fitting, island position, AI agents, sync, backups and stats.") {
                Button(showMore ? "Hide" : "Show") {
                    withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { showMore.toggle() }
                }
                .buttonStyle(.compact)
                .accessibilityLabel(showMore ? "Hide more options" : "Show more options")
            }
            if showMore {
                moreOptions.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder private var moreOptions: some View {
        SettingDivider()
        SettingRow("Fit the text around the cursor", detail: "Matches spacing and capitals.", controlWidth: nil) {
            Toggle("Match spacing and capitals", isOn: $model.preferences.smartFormatting).labelsHidden().toggleStyle(.warmSwitch)
        }
        SettingDivider()
        SettingRow("Learn my corrections", detail: "Words you fix right after dictating join Vocabulary.", controlWidth: nil) {
            Toggle("Learn words I correct", isOn: $model.preferences.learnWords).labelsHidden().toggleStyle(.warmSwitch)
        }
        if model.preferences.showOverlay {
            SettingDivider()
            SettingRow("Island position", detail: "Where recording shows on Macs without a notch.") {
                WarmPicker("Island position", selection: $model.preferences.islandCorner,
                           options: [(0, "Top centre"), (1, "Bottom left"), (2, "Bottom right")])
            }
        }
        SettingDivider()
        SettingRow("Let AI agents ask me questions", detail: "You answer out loud; the text goes back to the agent, not into an app.", controlWidth: nil) {
            Toggle("Let AI agents ask me questions", isOn: $model.preferences.agentVoice).labelsHidden().toggleStyle(.warmSwitch)
        }
        SettingDivider()
        SettingRow("Read questions aloud", detail: "Before recording the answer.", controlWidth: nil) {
            Toggle("Read agent questions aloud", isOn: $model.preferences.speakAgentQuestions).labelsHidden().toggleStyle(.warmSwitch)
        }
        SettingDivider()
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect Claude Code with:").font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
            HStack(spacing: 10) {
                Text(connectCommand)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(MouthyTheme.cream)
                    .lineLimit(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copiedConnect ? "Copied" : "Copy") {
                    TextDelivery.copy(connectCommand)
                    copiedConnect = true
                }
                .buttonStyle(.compact)
                .contentTransition(.interpolate)
                .task(id: copiedConnect) {
                    guard copiedConnect else { return }
                    try? await Task.sleep(for: .seconds(1.6))
                    copiedConnect = false
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).fill(MouthyTheme.night.opacity(0.55)))
        }
        .padding(.vertical, 12)
        SettingDivider()
        SettingRow("Sync folder", detail: model.preferences.syncFolder.isEmpty ? "Share vocabulary, replacements and modes through a folder you sync yourself." : model.preferences.syncFolder) {
            HStack(spacing: 6) {
                if !model.preferences.syncFolder.isEmpty {
                    Button("Sync") { model.syncNow() }.buttonStyle(.compact)
                    Button("Stop") { model.preferences.syncFolder = "" }.buttonStyle(.compact)
                } else {
                    Button("Choose…") { model.chooseSyncFolder() }.buttonStyle(.compact)
                }
            }
        }
        SettingDivider()
        SettingRow("Settings file", detail: "Back up or move your setup.") {
            HStack(spacing: 6) {
                Button("Export") { model.exportSettings() }.buttonStyle(.compact)
                Button("Import") { model.importSettings() }.buttonStyle(.compact)
            }
        }
        SettingDivider()
        SettingRow("Usage stats", detail: "Counts only, never your text.") {
            Button("Reset") { model.resetStats() }.buttonStyle(.compact)
        }
    }

    /// Replays the first-run welcome tour (the waving giraffe, permissions, shortcut), e.g. to show someone.
    private var welcomeTile: some View {
        Button { NotificationCenter.default.post(name: .mouthyReplayWelcome, object: nil) } label: {
            HStack(spacing: 14) {
                MascotGlyph(pose: .wave, size: 30)
                    .frame(width: 48, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Say hi again").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                    Text("Replay the welcome tour. Your settings stay as they are.").font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.system(size: 18)).foregroundStyle(MouthyTheme.glow)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background { TileBackground(style: .standard) }
        }
        .buttonStyle(MouthyPressableStyle(radius: MouthyTheme.Radius.tile))
        .tileHover()
        .accessibilityLabel("Replay the welcome tour")
    }

    private var aboutTile: some View {
        Button { showAbout = true } label: {
            HStack(spacing: 14) {
                Group {
                    if let head = Mascot.glyphImage(.wave) {
                        Image(nsImage: head).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        MascotGlyph(pose: .wave, size: 44)
                    }
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("mouthy").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                    Text(AppVersion.current).font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("About Mouthy").font(.system(size: 13, weight: .medium, design: .rounded))
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(MouthyTheme.glow)
            }
            .padding(20)
            .background { TileBackground(style: .standard) }
        }
        .buttonStyle(MouthyPressableStyle(radius: MouthyTheme.Radius.tile))
        .tileHover()
        .accessibilityLabel("About Mouthy")
    }

    // MARK: Actions

    private var connectCommand: String { "claude mcp add mouthy -- \"\(AgentVoiceServer.bridgeURL.path)\"" }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

/// A multi-line editor on raised cocoa with a glow ring while focused, in place of the system focus ring.
/// Uses the shared AppKit `WarmTextEditor` so selection and caret match every other text surface.
struct WarmTextBox: View {
    @Binding var text: String
    let label: String
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous)
        ScrollView {
            WarmTextEditor(text: $text, font: .systemFont(ofSize: 13), accessibilityLabel: label)
        }
        .scrollIndicators(.never)
        .padding(8)
        .background(shape.fill(MouthyTheme.raised))
        .overlay(shape.strokeBorder(MouthyTheme.hoof, lineWidth: 1))
    }
}

/// "Only listen to my voice": a switch that works once the person has trained their voice, with "Train my voice" (or
/// "Retrain" and "Forget my voice") beside it. While training, the three sentences to read and Done.
struct VoiceTrainingRows: View {
    @ObservedObject var model: AppModel
    @ObservedObject var trainer: VoiceTrainer

    var body: some View {
        SettingRow("Only listen to my voice", detail: detail, controlWidth: nil) {
            Toggle("Only listen to my voice", isOn: $model.preferences.onlyMyVoice).labelsHidden().toggleStyle(.warmSwitch)
                .disabled(!trainer.trained)
        }
        SettingRow(trainer.trained ? "Your voice" : "Train my voice", detail: actionDetail, controlWidth: nil) {
            HStack(spacing: 6) {
                switch trainer.step {
                case .reading:
                    Button("Cancel") { trainer.cancel() }.buttonStyle(.compact)
                    Button("Done") { trainer.finish() }.buttonStyle(.compact)
                case .working:
                    ProgressView().controlSize(.small)
                default:
                    if trainer.trained {
                        Button("Retrain") { start() }.buttonStyle(.compact)
                        Button("Forget my voice") { trainer.forget(); model.preferences.onlyMyVoice = false }.buttonStyle(.compact)
                    } else {
                        Button("Train my voice") { start() }.buttonStyle(.compact)
                    }
                }
            }
        }
        if trainer.step == .reading {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(VoicePrint.sentences, id: \.self) { sentence in
                    Text(sentence).font(MouthyType.body).foregroundStyle(MouthyTheme.cream)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).fill(MouthyTheme.night.opacity(0.55)))
            .padding(.bottom, 12)
        }
    }

    private var detail: String {
        trainer.trained ? "Other voices, a TV and music are turned down." : "Train your voice first."
    }

    private var actionDetail: String {
        switch trainer.step {
        case .reading: "Read these out loud, then click Done."
        case .working: "Learning your voice…"
        case let .failed(message): message
        case .idle: trainer.trained ? "Kept on this Mac as a voiceprint, never as audio." : "Read three short sentences out loud, about 15 seconds."
        }
    }

    private func start() {
        trainer.start(inputDeviceUID: model.preferences.inputDeviceUID)
    }
}
