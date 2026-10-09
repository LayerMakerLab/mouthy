import AppKit
import Carbon
import Combine
import SwiftUI
import Speech
import AVFoundation
import FoundationModels
import UniformTypeIdentifiers
import MouthyCore
import MouthyNotch
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    enum Phase: String { case idle = "Ready", preparing = "Preparing", listening = "Listening", finishing = "Finishing", delivering = "Inserting", cancelling = "Cancelling", failed = "Needs attention" }
    @Published var phase: Phase = .idle {
        didSet { if phase != oldValue { Diagnostics.dictation.notice("phase \(oldValue.rawValue, privacy: .public) -> \(self.phase.rawValue, privacy: .public)") } }
    }
    @Published var status = "Ready."
    @Published var liveText = ""
    @Published var output = ""
    @Published var document = TranscriptionDocument(text: "")
    @Published var fileResults: [FileResult] = []
    /// The live input level. It is not published: a tick goes straight to the layer views that draw it
    /// (`voice`), so the windows observing AppModel do not re-render 12 times a second.
    let voice = VoiceLevelFeed()
    var level: Float {
        get { voice.level }
        set { voice.send(newValue) }
    }
    @Published var history: [MouthyCore.Transcript] = []
    @Published var preferences = Preferences()
    @Published var stats = UsageStats()
    /// Start of the speech counted for the next stats entry (reset at each Enter split).
    private var segmentStart = Date()
    @Published var languages: [String] = ["en-US"]
    @Published var inputDevices: [InputDevice] = []
    @Published var microphoneAllowed = false
    @Published var microphoneRequestPending = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var accessibilityAllowed = false
    @Published var speechAssetsReady = false
    @Published var intelligenceReady = false
    @Published var selectedPage = "Dictate"
    @Published var targetName = "Mouthy workspace"
    @Published var currentInputName = "Microphone"
    @Published private(set) var startupSeconds: Double?
    @Published private(set) var finishSeconds: Double?
    @Published var activeMode: WritingMode = .verbatim
    @Published var activeModeName: String?
    private var activeOutput: OutputAction = .insert
    private var pressStarted: Date?
    private var includeContext = false
    private var codeDictation = false
    /// App, website, nearby text and clipboard, for modes that include context.
    private func contextSummary() -> String {
        guard includeContext else { return "" }
        var lines = ["App: " + targetName]
        if let url = target?.url { lines.append("Website: " + url) }
        if let nearby = target?.nearbyText, !nearby.isEmpty { lines.append("Text around the cursor (‸ marks it): " + nearby) }
        if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty { lines.append("Clipboard: " + String(clip.prefix(500))) }
        return lines.joined(separator: "\n")
    }
    @Published var agentQuestion: String?
    private var agentReply: CheckedContinuation<String, Never>?
    /// The server exchange the open question belongs to (nil when asked directly, as in tests).
    private var agentExchange: UUID?
    lazy var agentServer = AgentVoiceServer(
        answer: { [weak self] questions in await self?.askUser(questions) ?? "Mouthy is not running." },
        problem: { [weak self] message in self?.status = message },
        abandoned: { [weak self] exchange in self?.agentAbandoned(exchange) }
    )
    /// The agent's bridge hung up while its question was open: stop recording an answer nobody will read.
    /// Another agent's hang-up (its question never got the floor) leaves the open question alone.
    func agentAbandoned(_ exchange: UUID? = nil) {
        guard agentReply != nil else { return }
        if let exchange, let open = agentExchange, exchange != open { return }
        if busy { cancel() } else { finishAgent("(The agent stopped waiting.)") }
    }
    /// Clock ticks belong to the time labels, not every view observing the app.
    let clock = DictationClock()
    var elapsed: TimeInterval {
        get { clock.elapsed }
        set { clock.elapsed = newValue }
    }
    @Published var setupBusy = false
    @Published var selectedForRewrite = false
    let speech: any DictationSpeech
    /// Spoken commands and questions for the notch ("Mouthy, note …"), checked before delivery.
    let voiceRouter = NotchVoiceRouter()
    /// Settings' "Train my voice" ("Only listen to my voice").
    private(set) lazy var voiceTrainer: VoiceTrainer = {
        let trainer = VoiceTrainer(directory: store.directory)
        trainer.onTrained = { [weak self] in self?.preferences.onlyMyVoice = true }
        return trainer
    }()
    /// This dictation began at the notch's own mic, where bare commands count without "Mouthy".
    private var startedInNotch = false
    // Seams for the state tests. They default to the real system and are never used to drive real apps.
    var captureTarget: () -> InsertionTarget? = { TextDelivery.capture() }
    var deliverText: (_ text: String, _ target: InsertionTarget?, _ smartFormatting: Bool, _ replacingSelection: Bool, _ submit: Bool) async -> String = {
        await TextDelivery.deliver($0, to: $1, smartFormatting: $2, replacingSelection: $3, submit: $4)
    }
    var pressReturn: () -> Void = { TextDelivery.pressReturn() }
    /// Cleanup (writing style): text, style, custom instructions, context.
    var enhancer: (String, WritingMode, String, String) async throws -> String = {
        try await TextEnhancer.edit($0, mode: $1, customInstructions: $2, context: $3)
    }
    /// Selection rewrite: selection, spoken instruction.
    var rewriter: (String, String) async throws -> String = { try await TextEnhancer.rewrite(selection: $0, instruction: $1) }
    /// Cleanup and rewrites that take longer keep the original wording instead of failing the dictation.
    var cleanupTimeout: Duration = .seconds(20)
    /// Scales watchdog limits (tests shorten them).
    var watchdogSeconds: (Double) -> Double = { $0 }
    static let cleanupTimeoutNote = "Cleanup took too long; original wording kept."
    /// Global key taps, system audio and cue sounds belong to the app; headless models (tests) never touch them.
    private var interactive: Bool { enablesHotkey }
    let meeting = MeetingRecorder()
    let media = MediaControl()
    let returnTap = ReturnKeyTap()
    /// An Enter-key split is being sent.
    private var splitting = false
    /// Parts of this dictation already delivered by Enter splits, and the last of them.
    private(set) var sentSegments = 0
    private var lastSentText = ""
    /// The message of an Enter split that failed to go in. Finishing restores it (stop() has replaced the
    /// status with "Finishing your words…") rather than claim "Sent.".
    private var splitFailure: String?
    private var splitTask: Task<Void, Never>?
    /// A meeting is recording. Dictation shortcuts and Escape leave it alone; only Stop Meeting ends it.
    var meetingCapture = false
    /// Ends the meeting recording (a seam so tests can observe it without screen capture).
    lazy var cancelMeeting: () -> Void = { [meeting] in meeting.cancel() }
    /// Live for the app; a dry service (records registrations only) for headless models.
    let hotkey: HotkeyService
    /// A shortcut is being recorded: the global shortcuts stay released and nothing re-registers them (settings
    /// saves, wake, permission changes) until this is set back to false, which registers the current shortcuts.
    var hotkeySuspended: Bool {
        get { hotkey.isSuspended }
        set {
            objectWillChange.send()
            if newValue { hotkey.suspend() } else if hotkey.isSuspended { registerHotkey() }
        }
    }
    let store: LocalStore
    var overlay: OverlayController?
    var openWorkspace: (() -> Void)?
    private var operation: Task<Void, Never>?
    private var batchToken: UUID?
    private var watchdog: Task<Void, Never>?
    private var timer: Timer?
    private var target: InsertionTarget?
    private var started = Date()
    private var requested = Date()
    private var stopTime: Date?
    private var lastLevelUpdate = Date.distantPast
    /// Rests the level at 0 once no audio has arrived for 0.25 s, so a stalled input never leaves the bars high.
    /// One timer, re-armed by moving its fire date: no repeating wakeups.
    private lazy var levelDecay: Timer = {
        let timer = Timer(fire: .distantFuture, interval: 3600, repeats: true) { [weak self] timer in
            timer.fireDate = .distantFuture
            MainActor.assumeIsolated { self?.level = 0 }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }()

    /// A microphone level (dictation or meeting), sent on at most every 80 ms while listening.
    func receiveLevel(_ value: Float) {
        let value = phase == .listening ? value : 0
        levelDecay.fireDate = value > 0 ? Date().addingTimeInterval(0.25) : .distantFuture
        guard value == 0 || Date().timeIntervalSince(lastLevelUpdate) >= 0.08 else { return }
        lastLevelUpdate = Date()
        level = value
    }
    private var stopRequested = false
    private var generation = UUID()
    private var config = Preferences()
    private var isFailing = false
    private let enablesHotkey: Bool
    var busy: Bool { batchToken != nil || [.preparing, .listening, .finishing, .delivering, .cancelling].contains(phase) }
    var shortcutLabel: String { preferences.shortcut == 5 ? "Hold Fn" : preferences.shortcut == 4 ? "Double-tap Right ⌘" : preferences.shortcut == 3 ? preferences.customShortcutLabel : HotkeyService.labels[max(0, min(2, preferences.shortcut))] }

    init(store suppliedStore: LocalStore? = nil, enablesHotkey: Bool = true, speech suppliedSpeech: (any DictationSpeech)? = nil) {
        let store = suppliedStore ?? LocalStore()
        self.store = store
        self.enablesHotkey = enablesHotkey
        speech = suppliedSpeech ?? SpeechService()
        hotkey = HotkeyService(live: enablesHotkey)
        do {
            preferences = try store.load("preferences.json", as: Preferences.self) ?? Preferences()
        } catch { status = "Settings could not be read: \(error.localizedDescription)" }
        stats = (try? store.load("stats.json", as: UsageStats.self)) ?? UsageStats()
        do {
            history = try store.load("history.json", as: [MouthyCore.Transcript].self) ?? []
        } catch { status = "History could not be read: \(error.localizedDescription)" }
        speech.onPreview = { [weak self] text in
            guard let self else { return }
            self.liveText = text
        }
        speech.onLevel = { [weak self] value in self?.receiveLevel(value) }
        speech.onFailure = { [weak self] message in self?.fail(message) }
        speech.onInterruption = { [weak self] message in self?.interrupt(message) }
        meeting.onWaveform = { [weak self] frame in
            // The notch pill's bars follow `level`; meetings feed it from their microphone track.
            guard let self, self.meetingCapture else { return }
            self.receiveLevel(frame.level)
        }
        meeting.onState = { [weak self] recording, working, message in
            guard let self, self.meetingCapture else { return }
            self.status = message
            self.phase = recording ? .listening : working ? .preparing : .idle
            if !recording { self.level = 0 }
            if !recording && !working { self.meetingCapture = false; self.overlay?.hide() }
        }
        // While a meeting records, the dictation shortcuts, mode shortcuts and Escape are ignored: a stray
        // press must never stop or discard the meeting.
        hotkey.onPress = { [weak self] in
            guard let self, !self.meetingCapture else { return }
            self.stopCut = self.busy ? self.hotkey.gestureStartedAt : nil
            if self.preferences.shortcut == 5 { if !self.busy { self.begin(captureTarget: true) }; return }
            if self.preferences.automaticActivation && self.preferences.shortcut != 4 {
                if self.busy { self.stop() } else { self.begin(captureTarget: true); self.pressStarted = Date() }
                return
            }
            if self.preferences.holdToTalk && self.preferences.shortcut != 4 { if !self.busy { self.begin(captureTarget: true) } }
            else { self.toggle(captureTarget: true) }
        }
        hotkey.onRelease = { [weak self] in
            guard let self, !self.meetingCapture else { return }
            self.stopCut = self.busy ? self.hotkey.gestureStartedAt : nil
            if self.preferences.shortcut == 5 { self.stop(); return }
            if self.preferences.automaticActivation, let pressed = self.pressStarted {
                self.pressStarted = nil
                if Date().timeIntervalSince(pressed) >= 0.45 { self.stop() }
                return
            }
            guard self.preferences.holdToTalk, self.preferences.shortcut != 4 else { return }
            self.stop()
        }
        hotkey.onPasteLast = { [weak self] in self?.pasteLast() }
        hotkey.onToggleHub = { NotchHub.shared.toggleFromKeyboard() }
        returnTap.onReturn = { [weak self] in self?.sendAndContinue() ?? false }
        returnTap.onEscape = { [weak self] in self?.cancel() }
        hotkey.onModeShortcut = { [weak self] index in
            guard let self, !self.meetingCapture, index < self.preferences.modes.count else { return }
            if self.busy { self.stop() } else { self.begin(captureTarget: true, modeID: self.preferences.modes[index].id) }
        }
        // Escape anywhere cancels only an active dictation or a question still being answered in the notch,
        // never downloads, file batches or rewrites.
        hotkey.onCancel = { [weak self] in
            guard let self, !self.meetingCapture else { return }
            if self.phase == .idle, self.voiceRouter.answerTask != nil { self.cancel(); return }
            guard [.preparing, .listening, .finishing].contains(self.phase), self.batchToken == nil, !self.setupBusy else { return }
            self.cancel()
        }
        registerHotkey()
        // Settings save themselves: 0.4 s after the last change, written once, shortcuts re-registered only
        // when they changed. No timer runs while nothing changes.
        persistedPreferences = Self.encoded(preferences)
        autosave = $preferences.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persistPreferences() }
        Task { await refreshCapabilities() }
    }
    private var autosave: AnyCancellable?
    /// The settings as last written, to skip writes when nothing changed.
    private var persistedPreferences: Data?
    private static func encoded(_ preferences: Preferences) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(preferences)
    }
    /// What the global shortcuts depend on.
    struct HotkeyKeys: Equatable {
        var shortcut: Int, keyCode: UInt32, modifiers: UInt32, modes: [ModeShortcut?]
        init(_ preferences: Preferences) {
            shortcut = preferences.shortcut; keyCode = preferences.customKeyCode; modifiers = preferences.customModifiers
            modes = preferences.modes.map(\.shortcut)
        }
    }
    private var registeredHotkeyKeys: HotkeyKeys?
    /// Writes changed settings, schedules the sync and re-registers the shortcuts only if they changed.
    func persistPreferences() {
        let data = Self.encoded(preferences)
        if data == nil || data != persistedPreferences {
            do {
                try store.save(preferences, as: "preferences.json")
                persistedPreferences = data
                scheduleSync()
            } catch { status = "Settings could not be saved: \(error.localizedDescription)" }
        }
        registerHotkeyIfChanged()
    }
    /// Re-registers when the shortcut, custom key, modifiers or mode shortcuts changed; never while one is being recorded.
    func registerHotkeyIfChanged() {
        guard !hotkey.isSuspended, HotkeyKeys(preferences) != registeredHotkeyKeys else { return }
        registerHotkey()
    }
    /// Registers the current shortcuts now (and ends a shortcut recording).
    func registerHotkey() {
        registeredHotkeyKeys = HotkeyKeys(preferences)
        let inUse = "That shortcut is already in use. Choose another in Settings."
        hotkey.onLateRegistration = { [weak self] in if self?.status == inUse { self?.status = "Ready." } }
        if !hotkey.register(preset: preferences.shortcut, customKeyCode: preferences.customKeyCode, customModifiers: preferences.customModifiers, modeShortcuts: preferences.modes.map(\.shortcut)) { status = inUse }
    }
    /// Teaches a word: adds it to the vocabulary (Parakeet boosts it, Apple gets it as context) and, when
    /// the misheard form is given, an exact replacement from it.
    func teach(heard: String, meant: String) {
        let meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meant.isEmpty else { return }
        preferences.vocabulary = VocabularyLearner.merge([meant], into: preferences.vocabulary)
        if !heard.isEmpty, heard.caseInsensitiveCompare(meant) != .orderedSame {
            preferences.replacements.removeAll { $0.phrase.caseInsensitiveCompare(heard) == .orderedSame }
            preferences.replacements.append(Replacement(phrase: heard, replacement: meant))
        }
        savePreferences()
        status = heard.isEmpty ? "Learned \(meant)" : "Learned \(heard) → \(meant)"
    }

    /// Saves now (quit, explicit Save buttons). Settings also save themselves after every change, so views
    /// need not call this. Re-registers shortcuts only when they changed, or to end a recording that an older
    /// view started with `hotkey.suspend()`.
    func savePreferences(showConfirmation: Bool = false) {
        do {
            try store.save(preferences, as: "preferences.json")
            persistedPreferences = Self.encoded(preferences)
            if showConfirmation { status = "Settings saved." }
            if hotkey.isSuspended || HotkeyKeys(preferences) != registeredHotkeyKeys { registerHotkey() }
            scheduleSync()
        }
        catch { status = "Settings could not be saved: \(error.localizedDescription)" }
    }
    /// Loads the chosen local model in the background so the first dictation is as fast as every later one, and
    /// releases the models of engines that are no longer chosen.
    private var prewarmTask: Task<Void, Never>?
    func prewarmSpeech() {
        guard !busy, !setupBusy else { return }
        prewarmTask?.cancel()
        let engine = preferences.speechEngine, model = preferences.whisperModel, vocabulary = preferences.vocabulary
        let localOnly = preferences.localOnly
        prewarmTask = Task(priority: .utility) {
            guard !Task.isCancelled else { return }
            await SpeechModels.keepOnly(engine, whisperModel: model, vocabulary: vocabulary)
            guard !Task.isCancelled else { return }
            let ready = engine == .parakeet ? ParakeetRecognizer.installed : engine == .whisper ? WhisperRecognizer.installed(model) : false
            // Silero (about 1 MB) for installs made before it shipped, or Whisper-only ones; never during dictation.
            if ready && !localOnly { await VoiceActivity.download() }
        }
    }
    func refreshCapabilities() async {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        inputDevices = AudioDevices.inputs()
        refreshPermissions()
        intelligenceReady = SystemLanguageModel.default.isAvailable
        // Apple's on-device speech requires Apple silicon; Intel Macs use Parakeet (or Whisper).
        if !WhisperRecognizer.supported && preferences.speechEngine == .whisper {
            preferences.speechEngine = .parakeet
            savePreferences()
        }
        if !SpeechTranscriber.isAvailable && preferences.speechEngine == .apple {
            preferences.speechEngine = .parakeet
            savePreferences()
            status = "Apple speech isn't available on this Mac, so Mouthy uses NVIDIA Parakeet. Download it in Settings."
        }
        let available = await SpeechTranscriber.supportedLocales
        languages = available.map { $0.identifier(.bcp47) }.sorted()
        let installed = await SpeechTranscriber.installedLocales
        switch preferences.speechEngine {
        case .apple: speechAssetsReady = installed.contains { $0.identifier(.bcp47) == speechLocale(preferences.locale) }
        case .parakeet: speechAssetsReady = ParakeetRecognizer.installed
        case .whisper: speechAssetsReady = WhisperRecognizer.installed(preferences.whisperModel)
        }
    }
    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let hadAccessibility = accessibilityAllowed
        accessibilityAllowed = TextDelivery.accessibilityAllowed
        // Global modifier monitors created before a TCC grant do not start receiving
        // events automatically. Recreate them when permission changes.
        if accessibilityAllowed != hadAccessibility && (preferences.shortcut == 4 || preferences.shortcut == 5) && !hotkey.isSuspended {
            registerHotkey()
        }
        if accessibilityAllowed && status == "Enable Mouthy in System Settings → Privacy & Security → Accessibility to insert text into other apps." {
            status = "Ready to record."
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { status = "Approve Mouthy in System Settings → General → Login Items." }
        } catch { status = "Login startup could not be changed: \(error.localizedDescription)" }
    }
    func requestMicrophone() {
        guard !microphoneRequestPending else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            status = "Enable Mouthy in System Settings → Privacy & Security → Microphone."
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
            return
        }
        microphoneRequestPending = true
        status = "Waiting for macOS microphone approval. Allow Mouthy in the system dialog."
        Task {
            defer { microphoneRequestPending = false }
            microphoneAllowed = await SpeechService.permission()
            status = microphoneAllowed ? "Microphone allowed. You can start dictation." : "Microphone access is off. Enable Mouthy in System Settings → Privacy & Security → Microphone."
            await refreshCapabilities()
        }
    }
    func installAssets() {
        let id: SpeechModelID = switch preferences.speechEngine {
        case .apple: .apple
        case .parakeet: .parakeet
        case .whisper: .whisper(preferences.whisperModel)
        }
        installModel(id)
    }
    /// An explicit row action never changes the selected dictation engine or Whisper model.
    func installModel(_ id: SpeechModelID) {
        guard !setupBusy, !busy else { return }
        guard !preferences.localOnly else { status = "Network use is blocked. Allow it in Settings to download models."; return }
        let locale = speechLocale(preferences.locale)
        setupBusy = true
        status = "Preparing \(id.title)…"
        operation = Task {
            defer { setupBusy = false }
            do {
                switch id {
                case .parakeet:
                    await WhisperRecognizer.shared.releaseIfIdle()
                    try await ParakeetRecognizer.shared.prepare(download: true) { [self] message in
                        Task { @MainActor in self.status = message }
                    }
                case let .whisper(selected):
                    await ParakeetRecognizer.shared.releaseIfIdle()
                    try await WhisperRecognizer.shared.prepare(model: selected, download: true) { [self] message in
                        Task { @MainActor in self.status = message }
                    }
                    await VoiceActivity.download()
                case .apple:
                    _ = try await SpeechService.transcriber(locale: locale, install: true) { self.status = $0 }
                }
                status = "\(id.title) ready. Dictation can run offline."
                await refreshCapabilities()
            } catch { status = error.localizedDescription }
        }
    }
    func removeModel(_ id: SpeechModelID) {
        guard !setupBusy, !busy else { return }
        let locale = speechLocale(preferences.locale)
        setupBusy = true
        operation = Task {
            defer { setupBusy = false }
            do {
                switch id {
                case .apple: try await SpeechModelCatalog.releaseApple(locale: locale)
                case .parakeet: try await ParakeetRecognizer.shared.removeDownload()
                case let .whisper(selected): try await WhisperRecognizer.shared.removeDownload(selected)
                }
                await refreshCapabilities()
                status = id == .apple ? "Apple speech reservation released. macOS manages when shared files are removed." : "\(id.title) moved to Trash."
            } catch { status = error.localizedDescription }
        }
    }
    func toggle(captureTarget: Bool = false, fromNotch: Bool = false) {
        if busy { stop() } else { begin(captureTarget: captureTarget, fromNotch: fromNotch) }
    }
    /// Applies a mode over the global settings (the main mode). The engine only changes before recording starts.
    private func apply(_ mode: DictationMode, engine: Bool) {
        activeMode = mode.writingMode
        if !mode.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.customInstructions = mode.instructions; activeMode = .custom
        }
        if engine, let selected = mode.engine { config.speechEngine = selected }
        activeOutput = mode.output; activeModeName = mode.name; includeContext = mode.includeContext; codeDictation = mode.codeDictation
    }
    func begin(captureTarget: Bool, modeID: UUID? = nil, fromNotch: Bool = false) {
        guard !busy, !setupBusy else { return }
        // A new dictation takes the notch: a question still being answered there is dropped.
        voiceRouter.cancelAnswer()
        startedInNotch = fromNotch
        isFailing = false
        generation = UUID(); let token = generation
        config = preferences
        // "Only listen to my voice" (Parakeet and Whisper): the saved voiceprint, read fresh so "Forget my voice" holds.
        VoicePrint.active = config.onlyMyVoice && config.speechEngine != .apple ? VoicePrint.load(in: store.directory) : nil
        target = captureTarget ? self.captureTarget() : nil
        targetName = target?.name ?? "Mouthy workspace"
        let bundleID = target.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier } ?? ""
        activeMode = config.mode
        activeOutput = .insert; activeModeName = nil; includeContext = false; codeDictation = false
        let chosenMode = modeID ?? pickedModeID; pickedModeID = nil
        if let mode = ModeResolver.startMode(config.modes, shortcutMode: chosenMode, url: target?.url, bundleID: bundleID) {
            apply(mode, engine: true)
        }
        selectedForRewrite = !(target?.selectedText.isEmpty ?? true)
        phase = .preparing; status = "Preparing microphone…"; liveText = ""; output = ""; document = TranscriptionDocument(text: ""); elapsed = 0; stopRequested = false
        captureNotice = nil
        Diagnostics.dictation.notice("dictation start: engine \(self.config.speechEngine.rawValue, privacy: .public)")
        sentSegments = 0; lastSentText = ""; splitFailure = nil
        requested = Date(); stopTime = nil; startupSeconds = nil; finishSeconds = nil
        if config.showOverlay { overlay?.show() }
        if config.playSounds { NSSound(named: "Tink")?.play() }
        let quietMode = config.mediaWhileDictating
        if interactive { Task {
            // Let the start sound finish before muting the output it plays on.
            if config.playSounds { try? await Task.sleep(for: .milliseconds(250)) }
            guard generation == token, phase == .preparing || phase == .listening else { return }
            media.engage(quietMode)
        } }
        armWatchdog(seconds: 120, message: "Preparation took too long. Check the language assets and microphone.")
        operation = Task {
            do {
                try await speech.start(locale: speechLocale(config.locale), vocabulary: config.vocabulary, inputDeviceUID: config.inputDeviceUID, provider: config.speechEngine, whisperModel: config.whisperModel, whisperLanguage: config.whisperLanguage, translate: config.whisperTranslateToEnglish) { self.status = $0 }
                try Task.checkCancellation()
                guard generation == token else { return }
                watchdog?.cancel()
                phase = .listening; status = "Listening…"; started = Date(); segmentStart = started
                let insertsText = (activeOutput == .insert || activeOutput == .insertAndReturn) && config.autoInsert && !(config.rewriteSelection && selectedForRewrite)
                if target != nil, agentReply == nil, insertsText, interactive, !returnTap.start() {
                    status = "Listening… (Enter-to-send is unavailable: allow Mouthy under Privacy & Security → Input Monitoring.)"
                }
                startupSeconds = started.timeIntervalSince(requested)
                currentInputName = speech.inputDeviceName
                startElapsedTimer()
                if stopRequested { stop() }
            } catch {
                guard generation == token else { return }
                await speech.cancel()
                if !(error is CancellationError) { fail(error.localizedDescription) }
            }
        }
    }
    private func startElapsedTimer() {
        timer?.invalidate()
        let nextSecond = floor(Date().timeIntervalSince(started)) + 1
        let timer = Timer(fire: started.addingTimeInterval(nextSecond), interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date().timeIntervalSince(self.started)
                if Int(now) != Int(self.elapsed) { self.elapsed = now }
                if now >= 600 { self.stop() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// Enter while dictating: send what was said so far and keep listening. Taken whenever a split can run,
    /// even with no live text yet (Parakeet and Whisper preview late); a split with no words presses Return
    /// itself, so Enter still reaches the app exactly once. Returns false (Enter passes through) otherwise.
    func sendAndContinue() -> Bool {
        splitNow(endWithReturn: true)
    }

    /// Takes the speech since the last split without stopping the session and sends it.
    private func splitNow(endWithReturn: Bool) -> Bool {
        guard phase == .listening, target != nil, !splitting else { return false }
        splitting = true
        let token = generation
        splitTask = Task {
            defer { splitting = false; splitTask = nil }
            do {
                let raw = try await speech.split()
                guard generation == token else { return }
                await sendSegments(raw, endWithReturn: endWithReturn, token: token)
                let delivered = ["Sent", "Inserted", "Pasted"].contains { status.hasPrefix($0) }
                if delivered, phase == .listening { status = "Listening…" }
            } catch {
                guard generation == token else { return }
                status = "That part could not be sent: " + error.localizedDescription
                splitFailure = status
                // The Enter was taken by the tap; nothing went in, so still let it reach the app once.
                if endWithReturn { pressReturn() }
            }
        }
        return true
    }

    /// The text rules every result goes through before a style or delivery: one set for the finish and the Enter
    /// split. Prose opens a sentence, so a recognizer that wrote its first word in lowercase gets the capital here;
    /// code dictation keeps its case ("git commit -m").
    private func shape(_ raw: String, code: Bool) -> String {
        var text = TextPipeline.process(raw, replacements: config.replacements, punctuation: config.punctuationCommands)
        if config.removeFillers { text = Fillers.remove(text) }
        return code ? CodeDictation.apply(text) : SmartInsertion.capitalizingFirstWord(text)
    }
    /// Pastes text taken at an Enter split and sends it with Return when `endWithReturn`.
    /// Stops before pasting if the session was cancelled meanwhile (`token` no longer current).
    private func sendSegments(_ raw: String, endWithReturn: Bool, token: UUID) async {
        for part in [(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), submit: endWithReturn)] {
            // A pause can come back as bare punctuation ("..."); never paste text without words, but still
            // deliver the Return the person pressed.
            guard generation == token, !Task.isCancelled else { return }
            guard part.text.contains(where: { $0.isLetter || $0.isNumber }) else {
                if part.submit { pressReturn() }
                continue
            }
            var text = shape(part.text, code: codeDictation)
            if activeMode != .verbatim {
                let unrefined = text, mode = activeMode
                if case .done(let edited) = await refine({ [self] in try await enhance(unrefined, mode: mode) }) { text = edited }
            }
            guard generation == token, !Task.isCancelled else { return }
            let spokenUntil = Date()
            status = await deliverText(text, nil, config.smartFormatting, false, part.submit)
            if status.hasPrefix("Sent") || status.hasPrefix("Inserted") || status.hasPrefix("Pasted") {
                recordUsage(text, until: spokenUntil)
                sentSegments += 1; lastSentText = text; splitFailure = nil
                RecentResults.shared.add(text)
            }
            else { TextDelivery.copy(text); status += " The text is on the clipboard."; splitFailure = status }
            output = text
            if config.keepHistory {
                history.insert(MouthyCore.Transcript(raw: part.text, text: text, duration: elapsed, source: targetName, mode: activeMode.rawValue), at: 0)
                _ = persistHistory()
            }
        }
    }
    /// Where the recording ends: the moment the stop shortcut began (its key clicks, and music resuming, come after).
    private var stopCut: TimeInterval?

    func stop() {
        let cut = stopCut ?? ProcessInfo.processInfo.systemUptime
        stopCut = nil
        returnTap.stop()
        if meetingCapture { cancelMeeting(); return }
        if phase == .preparing { stopRequested = true; return }
        guard phase == .listening else { return }
        level = 0
        media.release()
        if config.playSounds { NSSound(named: "Pop")?.play() }
        stopTime = Date()
        timer?.invalidate(); timer = nil
        elapsed = Date().timeIntervalSince(started)
        phase = .finishing; status = "Finishing your words…"
        let token = generation
        armWatchdog(seconds: config.speechEngine == .apple ? 30 : 120, message: "Transcription timed out. Your preview remains available to copy.")
        operation = Task {
            do {
                // Let a mid-dictation split finish sending first so pieces stay in order and the
                // recognizer is free (it handles one request at a time).
                await splitTask?.value
                let raw = try await speech.finish(cutAt: cut)
                try Task.checkCancellation()
                guard generation == token else { return }
                await complete(raw: raw, sourceName: targetName, token: token, shouldInsert: config.autoInsert)
                // A recording the microphone cut short was still delivered; say why it ended early.
                if let notice = captureNotice, generation == token { status += " " + notice }
                captureNotice = nil
            } catch {
                guard generation == token else { return }
                await speech.cancel(); fail(error.localizedDescription)
            }
        }
    }
    /// Where a result came from. File results skip trigger words, mode actions and delivery, and leave the
    /// phase to the batch that owns it.
    enum ResultSource { case dictation, file }
    private func complete(raw: String, sourceName: String, source: ResultSource = .dictation, token: UUID, shouldInsert: Bool) async {
        // The words are here: the transcription watchdog's job is done. Cleanup has its own time limit and
        // never fails the dictation.
        watchdog?.cancel()
        document = speech.document
        let dictation = source == .dictation
        if dictation, agentReply != nil {
            let answer = TextPipeline.process(raw, replacements: config.replacements, punctuation: config.punctuationCommands)
            finishAgent(answer.isEmpty ? "(No speech was detected.)" : answer)
            // The outcome pill reads `status` when the overlay hides, so set it first.
            output = answer
            status = answer.isEmpty ? "No speech detected; the agent was told." : "Answer sent to the agent."
            watchdog?.cancel(); phase = .idle; overlay?.hide(); level = 0
            return
        }
        guard raw.contains(where: { $0.isLetter || $0.isNumber }) else {
            guard dictation else { status = "No speech found in \(sourceName)."; return }
            // Everything was already sent with Enter: report that, never re-offer the stale preview. A failed last
            // split keeps its own message and clipboard text. Status comes before hide(), which reads it.
            if let splitFailure { status = splitFailure }
            else if sentSegments > 0 { output = lastSentText; status = "Sent." }
            else if liveText.isEmpty { status = "No speech detected. Nothing was inserted." }
            else { output = liveText; status = "No final transcript arrived. The preview is preserved; nothing was inserted." }
            watchdog?.cancel(); phase = .idle; overlay?.hide()
            return
        }
        if dictation, let command = voiceRouter.command(in: raw, fromNotch: startedInNotch) {
            // A command or question lands in the notch: never pasted, never in history or Paste last. The
            // dictation ends first (quietly: this status shows no outcome) so the notch is free for its peek.
            status = "Handled in the notch."
            watchdog?.cancel(); phase = .idle; overlay?.hide(); level = 0
            status = await voiceRouter.run(command)
            return
        }
        var raw = raw
        if dictation, let (mode, rest) = ModeResolver.trigger(in: raw, modes: config.modes) {
            apply(mode, engine: false); raw = rest
            // Speech only ever types: a mode chosen by a spoken trigger word never presses Return.
            if activeOutput == .insertAndReturn { activeOutput = .insert }
        }
        var text = shape(raw, code: dictation && codeDictation)
        var enhancementNote: String?
        var rewroteSelection = false
        var historyNote: String?
        if dictation, config.rewriteSelection, let selected = target?.selectedText, !selected.isEmpty {
            status = "Rewriting selected text on your Mac…"
            let instruction = raw, rewriter = rewriter
            let outcome = await refine { try await rewriter(selected, instruction) }
            guard generation == token else { return }
            switch outcome {
            case .done(let rewritten): text = rewritten; rewroteSelection = true
            case .failed(let error):
                output = raw
                status = "Selection was not changed: " + error.localizedDescription
                phase = .idle; overlay?.hide()
                return
            case .timedOut:
                output = raw
                status = "Selection was not changed. " + Self.cleanupTimeoutNote
                phase = .idle; overlay?.hide()
                return
            }
        } else if activeMode != .verbatim {
            status = "Refining on your Mac…"
            let unrefined = text, mode = activeMode
            switch await refine({ [self] in try await enhance(unrefined, mode: mode) }) {
            case .done(let refined): text = refined
            case .failed: enhancementNote = "Cleanup unavailable; original wording preserved."
            case .timedOut: enhancementNote = Self.cleanupTimeoutNote
            }
        }
        guard generation == token, !Task.isCancelled else { return }
        output = text
        // Memory only, for the menu bar panel; never written or logged.
        if dictation { RecentResults.shared.add(text) }
        let entry = MouthyCore.Transcript(raw: raw, text: text, duration: elapsed, source: sourceName, mode: activeMode.rawValue)
        if config.keepHistory || (dictation && activeOutput == .historyOnly) {
            history.insert(entry, at: 0)
            history = Array(history.prefix(max(1, min(1000, config.historyLimit))))
            if !persistHistory() { historyNote = status }
        }
        watchdog?.cancel()
        if !dictation {
            // A file result is reviewed and exported from Files; the batch keeps its phase and overlay.
            status = "Ready. Review, copy, or export your words."
            if let enhancementNote { status += " " + enhancementNote }
            if let historyNote { status += " " + historyNote }
            return
        }
        if activeOutput == .clipboard { TextDelivery.copy(text); status = "Copied to the clipboard." }
        else if activeOutput == .historyOnly { status = historyNote ?? "Saved to history."; historyNote = nil }
        else if shouldInsert && target != nil {
            phase = .delivering
            status = await deliverText(text, target, config.smartFormatting, rewroteSelection, activeOutput == .insertAndReturn)
            if status.hasPrefix("Inserted") { learnFromCorrections() }
            if status.hasPrefix("Inserted") || status.hasPrefix("Pasted") || status.hasPrefix("Sent") { recordUsage(text, until: stopTime ?? Date()) }
        }
        else { status = "Ready. Review, copy, or export your words." }
        if let enhancementNote { status += " " + enhancementNote }
        if let historyNote { status += " " + historyNote }
        guard generation == token else { return }
        if let stopTime { finishSeconds = Date().timeIntervalSince(stopTime) }
        watchdog?.cancel(); phase = .idle; overlay?.hide(); level = 0
    }
    /// Inserts the most recent result again into the app that is focused now.
    func pasteLast() {
        guard !busy else { return }
        let text = output.isEmpty ? history.first?.text ?? "" : output
        guard !text.isEmpty else { status = "Nothing to paste yet."; return }
        let target = TextDelivery.capture()
        guard target != nil else { TextDelivery.copy(text); status = "Last result copied."; return }
        phase = .delivering
        Task {
            status = await TextDelivery.deliver(text, to: target, smartFormatting: preferences.smartFormatting)
            if phase == .delivering { phase = .idle }
        }
    }
    /// Records a spoken answer for an AI agent's question. Finish with the dictation shortcut; Escape cancels.
    func askUser(_ questions: [String]) async -> String {
        guard preferences.agentVoice else { return "Spoken answers for agents are turned off in Mouthy settings." }
        guard !busy, !setupBusy, agentReply == nil else { return "Mouthy is busy with another dictation. Ask again in a moment." }
        let exchange = AgentVoiceServer.current
        if preferences.speakAgentQuestions { await Self.say(questions.joined(separator: " ")) }
        // The agent may have given up while its question was read aloud: never record an answer for nobody.
        if let exchange, !exchange.isWaiting() { return "(The agent stopped waiting.)" }
        guard !busy, !setupBusy, agentReply == nil else { return "Mouthy is busy with another dictation. Ask again in a moment." }
        return await withCheckedContinuation { continuation in
            agentReply = continuation
            agentExchange = exchange?.id
            agentQuestion = questions.joined(separator: "\n")
            if interactive { NSSound(named: "Glass")?.play() }
            begin(captureTarget: false)
            // begin() can decline (busy); never leave the agent waiting or capture a later dictation.
            guard phase == .preparing || phase == .listening else { finishAgent("Mouthy is busy with another dictation. Ask again in a moment."); return }
            status = "Agent question: " + (agentQuestion ?? "") + " — speak, then use your shortcut to send."
        }
    }
    /// Reads text aloud with the system voice (on-device) and waits until it finishes.
    private static func say(_ text: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = [String(text.prefix(2_000))]
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch { done.resume() }
        }
    }
    /// Mode picker: changes the current dictation's mode, or picks one for the next dictation.
    @Published var pickedModeID: UUID?
    func pick(mode id: UUID?) {
        if busy, let id, let mode = preferences.modes.first(where: { $0.id == id }) { apply(mode, engine: false); return }
        pickedModeID = id
    }
    private func finishAgent(_ answer: String) {
        guard let reply = agentReply else { return }
        agentReply = nil; agentQuestion = nil; agentExchange = nil
        reply.resume(returning: answer)
    }
    /// Looks at the inserted text again after 10 and 30 seconds; a word the person corrected is added
    /// to the vocabulary so recognition gets it right next time. Reads only the inserted range.
    private func learnFromCorrections() {
        guard config.learnWords, let insertion = TextDelivery.lastInsertion else { return }
        TextDelivery.lastInsertion = nil
        Task { [weak self] in
            for delay in [10, 20] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, let value = TextDelivery.value(of: insertion.element) else { return }
                let source = value as NSString
                guard insertion.location < source.length else { return }
                let length = min(source.length - insertion.location, (insertion.text as NSString).length + 60)
                let region = source.substring(with: NSRange(location: insertion.location, length: length))
                let count = insertion.text.split(whereSeparator: { $0.isWhitespace }).count
                let edited = region.split(whereSeparator: { $0.isWhitespace }).prefix(count).joined(separator: " ")
                let isKnownWord = { (word: String) in NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound }
                let learned = VocabularyLearner.corrections(inserted: insertion.text, edited: edited, isKnownWord: isKnownWord)
                let soundAlikes = VocabularyLearner.soundAlikes(inserted: insertion.text, edited: edited, isKnownWord: isKnownWord)
                    .filter { pair in !self.preferences.replacements.contains { $0.phrase.caseInsensitiveCompare(pair.heard) == .orderedSame } }
                guard !learned.isEmpty || !soundAlikes.isEmpty else { continue }
                self.preferences.vocabulary = VocabularyLearner.merge(learned + soundAlikes.map(\.meant), into: self.preferences.vocabulary)
                self.preferences.replacements += soundAlikes.map { Replacement(phrase: $0.heard, replacement: $0.meant) }
                self.savePreferences()
                let words = learned + soundAlikes.map(\.meant)
                if !self.busy { self.status = "Learned " + words.map { "“\($0)”" }.joined(separator: ", ") + " for next time." }
                return
            }
        }
    }
    /// Engines this Mac can run: Apple speech and Whisper need Apple silicon; Parakeet runs everywhere.
    var availableEngines: [SpeechEngine] {
        SpeechEngine.allCases.filter { ($0 != .apple || SpeechTranscriber.isAvailable) && ($0 != .whisper || WhisperRecognizer.supported) }
    }
    /// "auto" follows the active keyboard language (no extra recognition work).
    func speechLocale(_ setting: String) -> String {
        guard setting == "auto" else { return setting }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String],
              let language = languages.first else { return "en-US" }
        return LocaleMatcher.best(language: language, region: Locale.current.region?.identifier, available: self.languages, fallback: "en-US")
    }
    // MARK: Sync folder

    private var syncTask: Task<Void, Never>?
    /// Writes changes to the sync folder shortly after they happen (coalesced).
    private func scheduleSync() {
        guard !preferences.syncFolder.isEmpty, !syncing else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.syncNow(quiet: true)
        }
    }
    private var syncing = false
    /// Merges "Mouthy Sync.json" in the sync folder into these settings, then writes the union back.
    func syncNow(quiet: Bool = false) {
        guard !preferences.syncFolder.isEmpty, !syncing else { return }
        syncing = true; defer { syncing = false }
        let file = URL(fileURLWithPath: preferences.syncFolder).appendingPathComponent(SyncDocument.fileName)
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let remote = try JSONDecoder().decode(SyncDocument.self, from: Data(contentsOf: file))
                if remote.apply(to: &preferences) {
                    try store.save(preferences, as: "preferences.json"); persistedPreferences = Self.encoded(preferences)
                    registerHotkeyIfChanged()
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(SyncDocument(preferences)).write(to: file, options: .atomic)
            if !quiet { status = "Synced with \(file.deletingLastPathComponent().lastPathComponent)." }
        } catch {
            // An unreadable sync file is left untouched.
            status = "Sync skipped: \(error.localizedDescription)"
        }
    }
    func chooseSyncFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Sync here"; panel.message = "Choose a folder your machines share. Mouthy keeps one small file there."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.syncFolder = url.path
        try? store.save(preferences, as: "preferences.json")
        syncNow()
    }

    /// Builds "Meeting notes.md" (speakers, summary, action items) for a recorded meeting folder.
    /// The meeting folder whose transcript is open in the viewer.
    @Published var openTranscript: URL?
    func makeMeetingNotes(folder: URL) {
        guard !busy, !setupBusy else { return }
        setupBusy = true
        Task {
            defer { setupBusy = false }
            do {
                let notes = try await MeetingNotes.make(folder: folder, localOnly: preferences.localOnly) { self.status = $0 }
                status = "Meeting notes saved to \(notes.lastPathComponent)."
                openTranscript = folder
            } catch { status = "Meeting notes failed: " + error.localizedDescription }
        }
    }
    func chooseMeetingForNotes() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Make notes"; panel.message = "Choose a meeting folder recorded by Mouthy."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Already has notes: open them; otherwise make them.
        if MeetingNotes.load(url) != nil { openTranscript = url } else { makeMeetingNotes(folder: url) }
    }
    /// Counts delivered words and the speaking time behind them (no text is stored).
    private func recordUsage(_ text: String, until end: Date = Date()) {
        stats.record(text: text, seconds: end.timeIntervalSince(segmentStart))
        segmentStart = Date()
        try? store.save(stats, as: "stats.json")
    }
    func resetStats() { stats = UsageStats(); try? store.save(stats, as: "stats.json") }
    func enhance(_ text: String, mode: WritingMode) async throws -> String {
        try await enhancer(text, mode, config.customInstructions, contextSummary())
    }

    func rewriteOutput() {
        guard !busy, !setupBusy, !output.isEmpty else { return }
        isFailing = false
        config = preferences; activeMode = preferences.mode == .verbatim ? .tidy : preferences.mode
        phase = .finishing; status = "Refining on your Mac…"; generation = UUID(); let token = generation
        armWatchdog(seconds: 30, message: "Cleanup timed out. Your original text is preserved.")
        let original = output
        operation = Task {
            do {
                let result = try await enhance(original, mode: activeMode)
                guard generation == token else { return }
                output = result; status = "Refined. Review your text before using it."
            } catch { if generation == token { status = error.localizedDescription } }
            if generation == token { watchdog?.cancel(); phase = .idle }
        }
    }
    func cancel() {
        if meetingCapture { cancelMeeting(); return }
        if !busy, !setupBusy, voiceRouter.cancelAnswer() { status = "Cancelled. Nothing was inserted."; return }
        guard phase != .delivering, phase != .cancelling, busy || setupBusy else { return }
        level = 0
        media.release(); returnTap.stop()
        finishAgent("(The user cancelled the spoken answer.)")
        let cancelledOperation = operation, cancelledSplit = splitTask
        generation = UUID(); let cancellation = generation
        splitTask?.cancel(); operation?.cancel(); batchToken = nil; watchdog?.cancel(); timer?.invalidate(); timer = nil
        for index in fileResults.indices where fileResults[index].document == nil && ["Queued", "Transcribing"].contains(fileResults[index].state) { fileResults[index].state = "Cancelled" }
        // Keep the lifecycle busy until the old analyzer, and a split still decoding, have released the recognizer.
        phase = .cancelling; status = "Cancelling…"
        Task {
            await cancelledOperation?.value; await cancelledSplit?.value; await speech.cancel()
            guard generation == cancellation else { return }
            phase = .idle; status = "Cancelled. Nothing was inserted."; overlay?.hide(); level = 0
        }
    }
    /// Why the microphone ended the current recording early, shown after its words are delivered.
    private var captureNotice: String?
    /// The microphone went away mid-recording (a route or display change). Capture has already stopped; the words
    /// recorded so far are recognized and delivered exactly like a stop, never thrown away, then the notice says why.
    func interrupt(_ message: String) {
        Diagnostics.dictation.notice("capture interrupted in \(self.phase.rawValue, privacy: .public): \(message, privacy: .public)")
        guard !meetingCapture, phase == .listening || phase == .preparing else { return }
        captureNotice = message
        stop()
    }
    func fail(_ message: String) {
        guard phase != .failed, phase != .delivering, phase != .cancelling, !isFailing else { return }
        Diagnostics.dictation.error("dictation failed in \(self.phase.rawValue, privacy: .public): \(message, privacy: .public)")
        captureNotice = nil
        level = 0
        media.release(); returnTap.stop()
        finishAgent("(Mouthy could not record an answer: \(message))")
        isFailing = true
        if output.isEmpty && !liveText.isEmpty { output = liveText }
        let failedOperation = operation
        generation = UUID(); let failure = generation
        operation?.cancel(); splitTask?.cancel(); watchdog?.cancel(); timer?.invalidate(); timer = nil
        phase = .finishing; status = message
        Task {
            await failedOperation?.value; await speech.cancel()
            // A cancel or new run that started meanwhile owns the phase now.
            guard generation == failure else { return }
            phase = .failed; overlay?.hide(); level = 0
        }
    }
    private func armWatchdog(seconds: Double, message: String) {
        watchdog?.cancel()
        let seconds = watchdogSeconds(seconds)
        watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(seconds)); try Task.checkCancellation()
                Diagnostics.dictation.error("watchdog fired after \(seconds, privacy: .public) s in \(self.phase.rawValue, privacy: .public)")
                fail(message)
            }
            catch {}
        }
    }
    enum RefineResult { case done(String), failed(Error), timedOut }
    /// Runs cleanup or a rewrite against `cleanupTimeout`. Whichever ends first wins and the other is cancelled;
    /// a model that ignores cancellation is simply not waited for (a task group would wait for it).
    func refine(_ work: @escaping @MainActor () async throws -> String) async -> RefineResult {
        let timeout = cleanupTimeout
        let gate = RefineGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RefineResult, Never>) in
                gate.continuation = continuation
                gate.work = Task { @MainActor in
                    do { gate.finish(.done(try await work())) } catch { gate.finish(.failed(error)) }
                }
                gate.timer = Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    if !Task.isCancelled { gate.finish(.timedOut) }
                }
            }
        } onCancel: {
            Task { @MainActor in gate.finish(.failed(CancellationError())) }
        }
    }
    func startMeeting() {
        guard !busy, !setupBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Save meeting here"
        panel.message = "Mouthy will save microphone and system-audio tracks inside a new meeting folder. Screen video is not recorded."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        // The pill must never show the previous dictation's words during a meeting.
        liveText = ""; level = 0
        meetingCapture = true; selectedPage = "Meetings"; targetName = "Meeting audio files"
        currentInputName = AudioDevices.inputs().first { $0.id == preferences.inputDeviceUID }?.name ?? AudioDevices.defaultInput()?.name ?? "Microphone"
        meeting.start(folder: parent.appendingPathComponent("Mouthy meeting " + stamp), inputUID: preferences.inputDeviceUID)
        overlay?.show()
    }
    func importAudio() {
        guard !busy, !setupBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        transcribe(urls: panel.urls)
    }
    func transcribe(url: URL) { transcribe(urls: [url], showFiles: false) }
    func transcribe(urls: [URL], showFiles: Bool = true) {
        guard !busy, !setupBusy else { return }
        guard !urls.isEmpty else { return }
        guard urls.count <= 100 else { status = "Choose up to 100 files per batch."; return }
        isFailing = false
        config = preferences; activeMode = config.mode; target = nil; generation = UUID(); let token = generation
        // Nothing from the last dictation's mode carries into a file batch.
        activeOutput = .insert; activeModeName = nil; includeContext = false; codeDictation = false
        selectedPage = showFiles ? "Files" : "Dictate"; phase = .finishing; liveText = ""; output = ""; document = TranscriptionDocument(text: "")
        fileResults = urls.map { FileResult(url: $0) }
        batchToken = token
        operation = Task {
            defer { if batchToken == token { batchToken = nil; objectWillChange.send(); overlay?.hide() } }
            for (index, url) in urls.enumerated() {
                guard generation == token, !Task.isCancelled else { return }
                phase = .finishing; fileResults[index].state = "Transcribing"
                status = "File \(index + 1) of \(urls.count) · \(url.lastPathComponent)"
                // A long file is allowed proportional processing time; capture remains bounded.
                armWatchdog(seconds: 3600, message: "File processing timed out. Completed files remain available.")
                do {
                    let prepared = try await MediaInput.prepare(url)
                    defer { prepared.removeTemporary() }
                    let file = try AVAudioFile(forReading: prepared.url)
                    elapsed = Double(file.length) / file.processingFormat.sampleRate
                    let text = try await speech.transcribeFile(prepared.url, locale: speechLocale(config.locale), vocabulary: config.vocabulary, provider: config.speechEngine, whisperModel: config.whisperModel, whisperLanguage: config.whisperLanguage, translate: config.whisperTranslateToEnglish) { self.status = $0 }
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    await complete(raw: text, sourceName: url.lastPathComponent, source: .file, token: token, shouldInsert: false)
                    guard generation == token else { return }
                    fileResults[index].document = speech.document
                    fileResults[index].state = "Ready"
                } catch {
                    guard generation == token else { return }
                    await speech.cancel()
                    fileResults[index].state = "Failed: " + error.localizedDescription
                }
            }
            guard generation == token else { return }
            watchdog?.cancel()
            let completed = fileResults.filter { $0.document != nil }.count
            phase = completed == 0 ? .failed : .idle
            if showFiles { status = "Batch finished. \(completed) of \(urls.count) files ready." }
            else if completed == 0 { status = fileResults.first?.state ?? "File could not be transcribed." }
        }
    }
    func exportDocument(_ document: TranscriptionDocument, format: TranscriptionDocument.Format, name: String = "Transcript") {
        do {
            let data = try document.exported(as: format)
            let panel = NSSavePanel(); panel.nameFieldStringValue = name + "." + format.fileExtension
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            status = "Exported \(url.lastPathComponent)."
        } catch { status = error.localizedDescription }
    }
    func exportSettings() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Mouthy-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(SettingsBackup(preferences)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            status = "Settings exported. Transcript history and audio are excluded."
        } catch { status = error.localizedDescription }
    }
    func importSettings() {
        guard !busy, !setupBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw MouthyFailure("Settings backup is larger than 1 MB.") }
            let imported = try SettingsBackup.read(Data(contentsOf: url))
            // Persist successfully before changing the active runtime.
            try store.save(imported, as: "preferences.json")
            preferences = imported; registerHotkey(); overlay?.hide()
            status = "Settings imported. Review voice actions before enabling them."
            Task { await refreshCapabilities() }
        } catch { status = "Settings were not changed: " + error.localizedDescription }
    }
    func export(_ text: String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8); status = "Exported \(url.lastPathComponent)." }
        catch { status = error.localizedDescription }
    }
    @discardableResult
    func persistHistory() -> Bool {
        do { try store.save(history, as: "history.json"); return true }
        catch { status = "History could not be saved: \(error.localizedDescription)"; return false }
    }
    func deleteHistory(_ id: UUID) { history.removeAll { $0.id == id }; persistHistory() }
    func clearHistory() { history = []; persistHistory() }
    func shutdown() async {
        generation = UUID(); operation?.cancel(); watchdog?.cancel(); timer?.invalidate(); level = 0; media.release()
        await meeting.stop()
        await speech.cancel()
        await ParakeetRecognizer.shared.releaseIfIdle()
        await WhisperRecognizer.shared.releaseIfIdle()
    }
}

/// Resumes `AppModel.refine` once, with the first of: the work's result, the timeout or cancellation.
@MainActor
private final class RefineGate {
    var continuation: CheckedContinuation<AppModel.RefineResult, Never>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    func finish(_ result: AppModel.RefineResult) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel(); timer?.cancel()
        continuation.resume(returning: result)
    }
}
