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
    /// Whether `liveText` is a pass's text at a pause (`DictationSpeech.previewPause`).
    private var liveTextPause: LiveTyping.Pause?
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
    /// The chosen modifier shortcut waits on Accessibility; ⌃⌥Space starts dictation meanwhile (`HotkeyService.standsIn`).
    @Published var shortcutStandsIn = false
    /// ⌃⌥Space could not stand in: another app or a mode shortcut already uses it. Set with `shortcutStandsIn`.
    @Published var standInTaken = false
    /// ⌃⌥Space is the shortcut that starts dictation right now.
    var standInActive: Bool { shortcutStandsIn && !standInTaken }
    /// The preset that describes the active shortcut's gesture: 0 (press ⌃⌥Space, a toggle) while it stands in.
    var activeShortcut: Int { standInActive ? 0 : preferences.shortcut }
    /// Whether this process is trusted under Accessibility (`refreshPermissions` and the shortcuts ask it; a seam for tests).
    let accessibilityCheck: @MainActor () -> Bool
    @Published var speechAssetsReady = false
    /// "Show words instantly": whether its model is on this Mac.
    @Published var instantWordsInstalled = LiveWords.installed
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
    /// "Type as I speak": types this dictation's words into the focused field as they are heard. Nil when the
    /// setting is off or this dictation's words go somewhere else (a rewrite, the clipboard, an agent's answer).
    private(set) var liveTyper: LiveTyper? { didSet { if liveTyper == nil, typingLive { typingLive = false } } }
    /// The live words are going into the focused field ("Type as I speak"), so the notch and the island do not show
    /// them as well: the words are already in front of the person.
    /// True from the start of such a dictation, false once no field takes the words or they were left behind: then
    /// the card is how the person sees them.
    @Published private(set) var typingLive = false
    /// The live words for the notch card and the island: none while they go into the field.
    var shownLiveText: String { typingLive ? "" : liveText }
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
        if phase == .listening { silence.receive(level: value) }
        let value = phase == .listening ? value : 0
        levelDecay.fireDate = value > 0 ? Date().addingTimeInterval(0.25) : .distantFuture
        guard value == 0 || Date().timeIntervalSince(lastLevelUpdate) >= 0.08 else { return }
        lastLevelUpdate = Date()
        level = value
    }
    private var stopRequested = false
    /// A dictation stops itself after this long and says so (a seam for the state tests).
    var dictationLimit: TimeInterval = 600
    static func limitNotice(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "Stopped at the \(Int((seconds / 60).rounded()))-minute limit." : "Stopped at the \(Int(seconds))-second limit."
    }
    /// Whether this recording heard any level above the noise floor (`MicrophoneSilence`, shared with `DictationSession`).
    private var silence = MicrophoneSilence()
    private var generation = UUID()
    private var config = Preferences()
    private var isFailing = false
    private let enablesHotkey: Bool
    var busy: Bool { batchToken != nil || [.preparing, .listening, .finishing, .delivering, .cancelling].contains(phase) }
    /// The shortcut that starts dictation right now: ⌃⌥Space while it stands in for the chosen one.
    var shortcutLabel: String { standInActive ? HotkeyService.labels[0] : chosenShortcutLabel }
    var chosenShortcutLabel: String { preferences.shortcut == 5 ? "Hold Fn" : preferences.shortcut == 4 ? "Double-tap Right ⌘" : preferences.shortcut == 3 ? preferences.customShortcutLabel : HotkeyService.labels[max(0, min(2, preferences.shortcut))] }

    init(store suppliedStore: LocalStore? = nil, enablesHotkey: Bool = true, speech suppliedSpeech: (any DictationSpeech)? = nil,
         accessibilityCheck: (@MainActor () -> Bool)? = nil) {
        let store = suppliedStore ?? LocalStore()
        self.store = store
        self.enablesHotkey = enablesHotkey
        // A headless model (tests, hosts) has no global shortcut to lose: it counts as trusted unless told otherwise.
        let check: @MainActor () -> Bool = accessibilityCheck ?? (enablesHotkey ? { TextDelivery.accessibilityAllowed } : { true })
        self.accessibilityCheck = check
        speech = suppliedSpeech ?? SpeechService()
        hotkey = HotkeyService(live: enablesHotkey)
        hotkey.trusted = check
        do {
            preferences = try store.load("preferences.json", as: Preferences.self) ?? Preferences()
        } catch { status = "Settings could not be read: \(error.localizedDescription)" }
        stats = (try? store.load("stats.json", as: UsageStats.self)) ?? UsageStats()
        if let kept = try? store.load("scores.json", as: [DictationScore].self) { scores = kept; keepsScores = true }
        do {
            history = try store.load("history.json", as: [MouthyCore.Transcript].self) ?? []
        } catch { status = "History could not be read: \(error.localizedDescription)" }
        speech.onPreview = { [weak self] text in
            guard let self else { return }
            self.liveText = text
            self.liveTextPause = self.speech.previewPause
            self.liveTyper?.hear(text, firm: self.speech.previewIsFirm, pause: self.liveTextPause)
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
            // ⌃⌥Space standing in for a modifier shortcut that Accessibility blocks: a plain toggle.
            if self.hotkey.standsIn { self.toggle(captureTarget: true); return }
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
            // The stand-in's release stops nothing, so it leaves no cut for a later stop to use.
            if self.hotkey.standsIn { return }
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
        returnTap.onActivity = { [weak self] key, flags in
            guard let self, let typer = self.liveTyper else { return }
            // Mouthy's own shortcuts and controls (Stop and Cancel in the notch, the island and the menu bar) are
            // not the person typing or clicking in the field.
            if let key { if self.hotkey.isOwnShortcut(key, flags: flags) { return } }
            else if Self.pointerIsOverOwnWindow() { return }
            typer.touched()
        }
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
        lastSynced = preferences
        autosave = $preferences.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persistPreferences() }
        // The notch's AI usage tab shows the services the person picked; its own picker writes back here.
        aiPicks = $preferences.map(\.aiServices).removeDuplicates().sink { raw in
            UsageTab.shared.setPicks(raw.map { names in AIService.allCases.filter { names.contains($0.rawValue) } })
        }
        UsageTab.shared.onPick = { [weak self] service, on in
            guard let self else { return }
            var picks = self.preferences.aiPicks
            if on { if !picks.contains(service) { picks.append(service) } } else { picks.removeAll { $0 == service } }
            self.preferences.aiPicks = picks
        }
        Task { await refreshCapabilities() }
    }
    private var autosave: AnyCancellable?
    private var aiPicks: AnyCancellable?
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
        hotkey.onLateRegistration = { [weak self] in
            guard let self else { return }
            if self.hotkey.standsIn { self.standInTaken = false }
            if self.status == inUse { self.status = "Ready." }
            else if self.hotkey.standsIn, Self.standInStatuses.contains(self.status) { self.status = Self.standInStatus(shortcut: self.preferences.shortcut, taken: false) }
        }
        let registered = hotkey.register(preset: preferences.shortcut, customKeyCode: preferences.customKeyCode, customModifiers: preferences.customModifiers, modeShortcuts: preferences.modes.map(\.shortcut))
        let wasStandingIn = shortcutStandsIn
        shortcutStandsIn = hotkey.standsIn
        standInTaken = shortcutStandsIn && !registered
        if shortcutStandsIn {
            // Only a neutral status gives way: an error from loading settings or history stays visible.
            if Self.neutralStatuses.contains(status) || Self.standInStatuses.contains(status) { status = Self.standInStatus(shortcut: preferences.shortcut, taken: !registered) }
        } else {
            if wasStandingIn, Self.standInStatuses.contains(status) { status = "Ready." }
            if !registered { status = inUse }
        }
    }
    /// What the status says while the chosen modifier shortcut waits on Accessibility (`taken`: ⌃⌥Space is already in use, by another app or a mode shortcut).
    static func standInStatus(shortcut: Int, taken: Bool) -> String {
        let chosen = shortcut == 5 ? "Hold Fn" : "Double-tap right ⌘"
        let meanwhile = taken ? "\(HotkeyService.labels[0]) would stand in, but another shortcut already uses it." : "Until then, press \(HotkeyService.labels[0]) to dictate."
        return "\(chosen) works once Mouthy is allowed in System Settings → Privacy & Security → Accessibility. " + meanwhile
    }
    static let standInStatuses = [4, 5].flatMap { shortcut in [false, true].map { standInStatus(shortcut: shortcut, taken: $0) } }
    static let neutralStatuses = ["", "Ready.", "Ready to record."]
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
        let localOnly = preferences.localOnly, instantWords = preferences.instantWords
        prewarmTask = Task(priority: .utility) {
            guard !Task.isCancelled else { return }
            await SpeechModels.keepOnly(engine, whisperModel: model, vocabulary: vocabulary)
            guard !Task.isCancelled else { return }
            let ready = engine == .parakeet ? ParakeetRecognizer.installed : engine == .whisper ? WhisperRecognizer.installed(model) : false
            // Silero (about 1 MB) for installs made before it shipped, or Whisper-only ones; never during dictation.
            if ready && !localOnly { await VoiceActivity.download() }
            // "Show words instantly": its recognizer stays warm with Parakeet, and goes when it is switched off.
            if instantWords && engine == .parakeet { await LiveWords.shared.prepare() } else { await LiveWords.shared.releaseIfIdle() }
        }
    }
    func refreshCapabilities() async {
        instantWordsInstalled = LiveWords.installed
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
        accessibilityAllowed = accessibilityCheck()
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
            switch await SpeechService.permission(timeout: .seconds(10)) {
            case true?: microphoneAllowed = true; status = "Microphone allowed. You can start dictation."
            case false?: microphoneAllowed = false; status = "Microphone access is off. Enable Mouthy in System Settings → Privacy & Security → Microphone."
            case nil:
                // No dialog came: send the person to the switch instead of waiting on macOS.
                microphoneAllowed = false
                status = "macOS didn't show its microphone dialog. Turn Mouthy on in System Settings → Privacy & Security → Microphone."
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
            }
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
    /// "Show words instantly": downloads the streaming recognizer's model (an explicit action) and switches it on.
    func installInstantWords() {
        guard !setupBusy, !busy else { return }
        guard !preferences.localOnly else { status = "Network use is blocked. Allow it in Settings to download models."; return }
        setupBusy = true
        status = "Downloading the model for instant words (\(LiveWords.megabytes) MB)…"
        operation = Task {
            defer { setupBusy = false }
            do {
                try await LiveWords.shared.download()
                instantWordsInstalled = LiveWords.installed
                preferences.instantWords = instantWordsInstalled
                status = "Words now show as you say them."
            } catch { status = error.localizedDescription }
        }
    }
    func removeInstantWords() {
        guard !setupBusy, !busy else { return }
        preferences.instantWords = false
        setupBusy = true
        operation = Task {
            defer { setupBusy = false }
            do {
                try await LiveWords.shared.removeDownload()
                status = "The model for instant words moved to Trash."
            } catch { status = error.localizedDescription }
            instantWordsInstalled = LiveWords.installed
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
        liveTyper?.abandon(); liveTyper = nil
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
        captureNotice = nil; silence = MicrophoneSilence()
        // A new dictation ends the watch on the last one's text (learning from its last edit) and its Undo.
        learnedTerms = []; lastLearned = nil; correctionWatch?.finish()
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
        speech.instantWords = config.instantWords
        operation = Task {
            do {
                try await speech.start(locale: speechLocale(config.locale), vocabulary: config.vocabulary, inputDeviceUID: config.inputDeviceUID, provider: config.speechEngine, whisperModel: config.whisperModel, whisperLanguage: config.whisperLanguage, translate: config.whisperTranslateToEnglish) { self.status = $0 }
                try Task.checkCancellation()
                guard generation == token else { return }
                watchdog?.cancel()
                phase = .listening; status = "Listening…"; started = Date(); segmentStart = started
                silence.start(at: started.timeIntervalSinceReferenceDate)
                let insertsText = (activeOutput == .insert || activeOutput == .insertAndReturn) && config.autoInsert && !(config.rewriteSelection && selectedForRewrite)
                let typesInto = target != nil && agentReply == nil && insertsText
                // Typing live would replace a selection at the first word; the paste at the stop replaces it then.
                let typesLive = typesInto && config.typeAsYouSpeak && !selectedForRewrite
                if typesInto, interactive, !returnTap.start(watchingMouse: typesLive) {
                    status = "Listening… (Enter-to-send is unavailable: allow Mouthy under Privacy & Security → Input Monitoring.)"
                }
                // Typing live needs the key tap, which tells it when the person types or clicks in the field.
                if typesLive, returnTap.isActive || !interactive {
                    let config = config, code = codeDictation
                    liveTyper = LiveTyper(shape: { DictationText.shape($0, code: code, config: config, live: true) },
                                          smartFormatting: config.smartFormatting, names: VocabularyLearner.terms(config.vocabulary),
                                          settlesAtPauses: speech.previewMarksPauses)
                    typingLive = true
                    liveTyper?.onTyping = { [weak self, weak typer = liveTyper] typing in
                        guard let self, let typer, self.liveTyper === typer, self.typingLive != typing else { return }
                        self.typingLive = typing
                    }
                    if !liveText.isEmpty { liveTyper?.hear(liveText, firm: speech.previewIsFirm, pause: liveTextPause) }
                }
                startupSeconds = started.timeIntervalSince(requested)
                currentInputName = speech.inputDeviceName
                if !preferences.microphoneHintSeen, microphoneHint == nil, let device = speech.inputDevice, isBluetoothInput(device) {
                    builtInMicrophone = usableBuiltInInput()
                    microphoneHint = Self.microphoneHint(input: device.name, builtInAvailable: builtInMicrophone != nil)
                }
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
                if now >= self.dictationLimit { self.captureNotice = Self.limitNotice(self.dictationLimit); self.stop() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// Enter while dictating: send what was said so far and keep listening. Taken whenever a split can run,
    /// even with no live text yet (Parakeet and Whisper preview late); a split with no words presses Return
    /// itself, so Enter still reaches the app exactly once. Returns false (Enter passes through) otherwise.
    func sendAndContinue() -> Bool {
        // A Return while the last send is still being recognized or pasted is swallowed: passed through, it would
        // submit the field before those words arrive.
        if phase == .listening, splitting { return true }
        return splitNow(endWithReturn: true)
    }

    /// Takes the speech since the last split without stopping the session and sends it.
    private func splitNow(endWithReturn: Bool) -> Bool {
        guard phase == .listening, target != nil, !splitting else { return false }
        splitting = true
        // Guesses from here on belong to the next part.
        liveTyper?.pause()
        let token = generation
        splitTask = Task {
            defer { splitting = false; splitTask = nil }
            do {
                let raw = try await speech.split()
                guard generation == token else { return }
                await sendSegments(raw, endWithReturn: endWithReturn, token: token)
                if Self.delivered(status), phase == .listening { status = "Listening…" }
            } catch {
                guard generation == token else { return }
                status = "That part could not be sent: " + error.localizedDescription
                splitFailure = status
                // The Enter was taken by the tap; nothing went in, so still let it reach the app once. Not when
                // "Type as I speak" already put this part's unfinished words in the field: Return would send them.
                let typedLive = liveTyper?.typedAnything ?? false
                restartTyping()
                if endWithReturn, !typedLive { pressReturn() }
            }
        }
        return true
    }

    /// The text rules every result goes through (`DictationText`): one set for the finish and the Enter split.
    private func shape(_ raw: String, code: Bool) -> String { DictationText.shape(raw, code: code, config: config) }
    /// Pastes text taken at an Enter split and sends it with Return when `endWithReturn`.
    /// Stops before pasting if the session was cancelled meanwhile (`token` no longer current).
    private func sendSegments(_ raw: String, endWithReturn: Bool, token: UUID) async {
        for part in [(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), submit: endWithReturn)] {
            // A pause can come back as bare punctuation ("..."); never paste text without words, but still
            // deliver the Return the person pressed.
            guard generation == token, !Task.isCancelled else { return }
            guard part.text.contains(where: { $0.isLetter || $0.isNumber }) else {
                // Words a guess typed that the finished part does not hold go before the Return.
                let wordsRemain = await liveTyper?.takeBack() ?? false
                restartTyping()
                if part.submit, !wordsRemain { pressReturn() }
                continue
            }
            var text = shape(part.text, code: codeDictation)
            if activeMode != .verbatim {
                let unrefined = text, mode = activeMode
                if case .done(let edited) = await refine({ [self] in try await enhance(unrefined, mode: mode) }) { text = edited }
            }
            guard generation == token, !Task.isCancelled else { return }
            let spokenUntil = Date()
            TextDelivery.customWords = VocabularyLearner.terms(config.vocabulary)
            status = await deliver(text, to: nil, replacingSelection: false, submit: part.submit)
            restartTyping()
            if Self.delivered(status) {
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
    /// Whether the pointer is over one of Mouthy's windows that takes clicks (the closed notch hub lets them through).
    static func pointerIsOverOwnWindow() -> Bool {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard let window = NSApp?.window(withWindowNumber: number) else { return false }
        return !window.ignoresMouseEvents
    }
    /// Stops the key tap once nothing needs it: not while listening, and not while "Type as I speak" is still
    /// bringing the field to the finished text (it has to hear the person's keys and clicks until then).
    private func releaseTap() { if liveTyper == nil, phase != .listening { returnTap.stop() } }
    /// Whether a delivery status says the words reached the app.
    static func delivered(_ status: String) -> Bool { ["Sent", "Inserted", "Pasted", "Typed"].contains { status.hasPrefix($0) } }
    /// Delivers a finished text. With "Type as I speak" most of it is in the field already: the field is brought to
    /// the finished text and only what could not be typed (text after a line break, or everything when no text
    /// field took the words) is pasted.
    private func deliver(_ text: String, to target: InsertionTarget?, replacingSelection: Bool, submit: Bool) async -> String {
        typingCounts = nil
        guard let typer = liveTyper, !replacingSelection else {
            return await deliverText(text, target, config.smartFormatting, replacingSelection, submit)
        }
        let name = { typer.appName }
        let outcome = await typer.finish(text)
        if typer.typedAnything { typingCounts = typer.counts }
        switch outcome {
        case .typed(let rest, let verified):
            // All of the words are in the one field (text after a first line break goes in by paste).
            if !rest.isEmpty {
                // Only into the field that holds the first line.
                guard await typer.stillThere() else { return "Typed into \(name()) up to the first line break. Focus changed, so the rest was not inserted." }
                let pasted = await deliverText(rest, nil, false, false, submit)
                return Self.delivered(pasted) ? pasted : "Typed into \(name()) up to the first line break. " + pasted
            }
            guard submit else { return (verified ? "Inserted into " : "Typed into ") + name() + "." }
            // A moment for the app to take the last key presses before Return.
            try? await Task.sleep(for: .milliseconds(verified ? 50 : 150))
            guard await typer.stillThere() else { return "Typed into \(name()). Not sent, because focus changed." }
            pressReturn()
            return "Sent in \(name())."
        case .untyped(let remainder):
            guard typer.typedAnything else { return await deliverText(remainder, target, config.smartFormatting, false, submit) }
            // Some of the words are in a field already, left where they were typed. The rest goes in at the cursor,
            // and Return never follows: it would send a text that is not all in one place.
            let unsent = submit ? " Not sent, because part of the text was left where it was typed." : ""
            guard !remainder.isEmpty else { return "Typed into \(name())." + unsent }
            let pasted = await deliverText(remainder, target, config.smartFormatting, false, false)
            return Self.delivered(pasted) ? pasted + unsent : pasted
        }
    }
    /// The Enter-split part is done: the typer starts over at the cursor, with the guess for the next part that came
    /// while it was busy (nothing sends that one again).
    private func restartTyping() {
        guard let typer = liveTyper else { return }
        typer.restart()
        // With the pause it came with: a phrase heard at a pause during the split is typed now, not at the next one.
        if phase == .listening, !liveText.isEmpty { typer.hear(liveText, pause: liveTextPause) }
    }
    /// Takes back words "Type as I speak" typed for a result that is not inserted (a command, an empty result).
    private func takeBackTyped() async {
        guard let typer = liveTyper else { return }
        await typer.takeBack()
        liveTyper = nil
        releaseTap()
    }
    /// Where the recording ends: the moment the stop shortcut began (its key clicks, and music resuming, come after).
    private var stopCut: TimeInterval?

    func stop() {
        let cut = stopCut ?? ProcessInfo.processInfo.systemUptime
        stopCut = nil
        // "Type as I speak" still corrects the field after the stop: the tap keeps telling it of keys and clicks.
        if liveTyper == nil { returnTap.stop() }
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
            await takeBackTyped()
            // Everything was already sent with Enter: report that, never re-offer the stale preview. A failed last
            // split keeps its own message and clipboard text. Status comes before hide(), which reads it.
            if let splitFailure { status = splitFailure }
            else if sentSegments > 0 { output = lastSentText; status = "Sent." }
            else if liveText.isEmpty, silence.isSilent(at: (stopTime ?? Date()).timeIntervalSinceReferenceDate, after: MicrophoneSilence.reportAfter) {
                status = MicrophoneHealth.silenceMessage(input: currentInputName) + " Nothing was inserted."
            }
            else if liveText.isEmpty { status = "No speech detected. Nothing was inserted." }
            else { output = liveText; status = "No final transcript arrived. The preview is preserved; nothing was inserted." }
            watchdog?.cancel(); phase = .idle; overlay?.hide()
            return
        }
        if dictation, let command = voiceRouter.command(in: raw, fromNotch: startedInNotch, replacements: config.replacements) {
            // A command or question lands in the notch: never pasted, never in history. The dictation ends first
            // (quietly: this status shows no outcome) so the notch is free for its peek. Words said to Mouthy by
            // name from any app are kept for Paste last, in case they were meant as text.
            status = "Handled in the notch."
            await takeBackTyped()
            if !startedInNotch { output = shape(raw, code: false) }
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
        // A mode chosen by a trigger word may send the result elsewhere: words typed live then come back out.
        if activeOutput == .clipboard { await takeBackTyped(); TextDelivery.copy(text); status = "Copied to the clipboard." }
        else if activeOutput == .historyOnly { await takeBackTyped(); status = historyNote ?? "Saved to history."; historyNote = nil }
        else if shouldInsert && target != nil {
            phase = .delivering
            TextDelivery.customWords = VocabularyLearner.terms(config.vocabulary)
            status = await deliver(text, to: target, replacingSelection: rewroteSelection, submit: activeOutput == .insertAndReturn)
            liveTyper = nil; returnTap.stop()
            // (The score first: the corrections watched from here on are noted in it.)
            if Self.delivered(status) { recordUsage(text, until: stopTime ?? Date()) }
            if status.hasPrefix("Inserted") { learnFromCorrections() }
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
    /// Reads text aloud and waits until it finishes: Mouthy's own voice (on-device), or the system voice when that
    /// isn't installed or fails.
    private static func say(_ text: String) async {
        do { try await MouthyVoicePlayer.shared.speak(String(text.prefix(2_000))); return } catch {}
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
    /// Watches the inserted text for up to 60 s: every edit is noted as it happens, and when the person sends or
    /// clears the field, starts the next dictation, or the minute ends, the last edit is compared with what Mouthy
    /// wrote. Corrected words and short phrases are added to the vocabulary so recognition gets them right next
    /// time. Reads only the inserted range; apps without value notifications are read at 10 and 30 s instead.
    private var correctionWatch: (finish: () -> Void, watcher: TextDelivery.FieldWatcher?)?
    private func learnFromCorrections() {
        correctionWatch?.finish()
        guard config.learnWords, let insertion = TextDelivery.lastInsertion else { return }
        TextDelivery.lastInsertion = nil
        let count = insertion.text.split(whereSeparator: { $0.isWhitespace }).count
        let scored = lastScore
        /// The inserted range as it reads now (nil once the field no longer holds it: sent or cleared).
        func region() -> String? {
            guard let value = TextDelivery.value(of: insertion.element) else { return nil }
            let source = value as NSString
            guard insertion.location < source.length else { return nil }
            let length = min(source.length - insertion.location, (insertion.text as NSString).length + 60)
            return source.substring(with: NSRange(location: insertion.location, length: length))
        }
        var latest = insertion.text
        var done = false
        /// The dictation's score gets the number of words that read differently now.
        let note = { [weak self] in self?.score(scored, corrected: DictationScore.changedWords(inserted: insertion.text, within: latest)) }
        let finish = { [weak self] in
            guard !done else { return }
            done = true
            self?.correctionWatch?.watcher?.stop(); self?.correctionWatch = nil
            self?.learn(inserted: insertion.text, region: latest, wordCount: count)
            note()
        }
        var pid: pid_t = 0
        AXUIElementGetPid(insertion.element, &pid)
        let watcher = TextDelivery.FieldWatcher(pid: pid, element: insertion.element) {
            MainActor.assumeIsolated {
                guard !done else { return }
                if let now = region(), !now.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { latest = now } else { finish() }
            }
        }
        correctionWatch = (finish, watcher)
        Task { [weak self] in
            if watcher == nil {
                for delay in [10, 20] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !done else { return }
                    if let now = region() { latest = now }
                    if self?.learn(inserted: insertion.text, region: latest, wordCount: count, finalRead: false) == true { done = true; self?.correctionWatch = nil; note(); return }
                }
                finish()
            } else {
                try? await Task.sleep(for: .seconds(60))
                finish()
            }
        }
    }
    /// Learns from one read of the inserted range; true when something was learned.
    @discardableResult
    func learn(inserted: String, region: String, wordCount: Int, finalRead: Bool = true) -> Bool {
        let words = region.split(whereSeparator: { $0.isWhitespace })
        let edited = words.prefix(wordCount).joined(separator: " ")
        let wider = words.prefix(wordCount + 4).joined(separator: " ")
        let isKnownWord = DictationText.knownWord(locale: preferences.locale)
        let learned = VocabularyLearner.corrections(inserted: inserted, edited: wider, isKnownWord: isKnownWord)
        let soundAlikes = VocabularyLearner.soundAlikes(inserted: inserted, edited: edited, isKnownWord: isKnownWord)
            .filter { pair in !preferences.replacements.contains { $0.phrase.caseInsensitiveCompare(pair.heard) == .orderedSame } }
        guard !learned.isEmpty || !soundAlikes.isEmpty else { return false }
        let before = (vocabulary: preferences.vocabulary, replacements: preferences.replacements)
        preferences.vocabulary = VocabularyLearner.merge(learned + soundAlikes.map(\.meant), into: preferences.vocabulary)
        preferences.replacements += soundAlikes.map { Replacement(phrase: $0.heard, replacement: $0.meant) }
        savePreferences()
        lastLearned = before
        let terms = learned + soundAlikes.map(\.meant)
        learnedTerms = terms
        if !busy { status = "Learned " + terms.map { "“\($0)”" }.joined(separator: ", ") + " for next time." }
        return true
    }
    /// What the vocabulary and replacements were before the last thing Mouthy learned, for Undo.
    private var lastLearned: (vocabulary: String, replacements: [Replacement])?
    /// The words or phrases the last correction taught (shown with Undo until the next dictation).
    @Published private(set) var learnedTerms: [String] = []
    /// Takes back the last thing Mouthy learned from a correction.
    /// One-time hint while dictating through a Bluetooth headset, offered only when the built-in microphone can be used.
    @Published var microphoneHint: String?
    private var builtInMicrophone: InputDevice?
    /// Seams for the state tests: whether an input is a Bluetooth headset, and the built-in microphone when it can be used.
    var isBluetoothInput: (InputDevice) -> Bool = MicrophoneHealth.isBluetoothHeadset
    var usableBuiltInInput: () -> InputDevice? = { AudioDevices.lidClosed ? nil : AudioDevices.inputs().first(where: AudioDevices.isBuiltIn) }
    static func microphoneHint(input: String, builtInAvailable: Bool) -> String? {
        builtInAvailable ? "\(input) records at call quality over Bluetooth. The built-in microphone hears words more clearly." : nil
    }
    /// Answers the hint: `useBuiltIn` makes the built-in microphone Mouthy's input (Settings → Speech changes it back).
    func answerMicrophoneHint(useBuiltIn: Bool) {
        if useBuiltIn, let builtInMicrophone {
            preferences.inputDeviceUID = builtInMicrophone.id
            if !busy { status = "Mouthy now uses \(builtInMicrophone.name). Change it in Settings → Speech." }
        }
        preferences.microphoneHintSeen = true
        savePreferences()
        microphoneHint = nil; builtInMicrophone = nil
    }

    func undoLearned() {
        guard let lastLearned else { return }
        preferences.vocabulary = lastLearned.vocabulary
        preferences.replacements = lastLearned.replacements
        savePreferences()
        self.lastLearned = nil
        status = "Forgot " + learnedTerms.map { "“\($0)”" }.joined(separator: ", ") + "."
        learnedTerms = []
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
    /// The settings as of the last sync (or launch), so what was removed since is not merged back in.
    private var lastSynced: Preferences?
    /// Merges "Mouthy Sync.json" in the sync folder into these settings, then writes the union back.
    func syncNow(quiet: Bool = false) {
        guard !preferences.syncFolder.isEmpty, !syncing else { return }
        syncing = true; defer { syncing = false }
        let file = URL(fileURLWithPath: preferences.syncFolder).appendingPathComponent(SyncDocument.fileName)
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let remote = try JSONDecoder().decode(SyncDocument.self, from: Data(contentsOf: file))
                let removed = SyncDocument.Removed(from: lastSynced ?? preferences, to: preferences)
                if remote.apply(to: &preferences, removed: removed) {
                    try store.save(preferences, as: "preferences.json"); persistedPreferences = Self.encoded(preferences)
                    registerHotkeyIfChanged()
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(SyncDocument(preferences)).write(to: file, options: .atomic)
            lastSynced = preferences
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
        if (try? store.save(preferences, as: "preferences.json")) != nil { persistedPreferences = Self.encoded(preferences) }
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
    /// Counts delivered words and the speaking time behind them, and keeps the dictation's score (no text is stored).
    private func recordUsage(_ text: String, until end: Date = Date()) {
        let seconds = max(0, end.timeIntervalSince(segmentStart))
        stats.record(text: text, seconds: seconds)
        segmentStart = Date()
        try? store.save(stats, as: "stats.json")
        guard keepsScores else { typingCounts = nil; return }
        let score = DictationScore(seconds: seconds, words: text.split(whereSeparator: \.isWhitespace).count, typed: typingCounts?.typed,
                                   tookBack: typingCounts?.back, tookBackAtStop: typingCounts?.backAtStop,
                                   delivery: String(status.prefix { $0.isLetter }))
        typingCounts = nil
        scores = Array((scores + [score]).suffix(DictationScore.limit))
        lastScore = score.id
        try? store.save(scores, as: "scores.json")
    }
    func resetStats() {
        stats = UsageStats(); try? store.save(stats, as: "stats.json")
        scores = []; lastScore = nil
        if keepsScores { try? store.save(scores, as: "scores.json") }
    }
    /// Each dictation in numbers (`DictationScore`), the newest last.
    private(set) var scores: [DictationScore] = []
    /// A testing tool, off unless `scores.json` is already in the application folder at launch: Mouthy never creates it.
    private var keepsScores = false
    private var lastScore: UUID?
    /// What "Type as I speak" typed and took back for the text being delivered.
    private var typingCounts: (typed: Int, back: Int, backAtStop: Int)?
    /// Notes in a dictation's score how many of its words the person changed afterwards.
    private func score(_ id: UUID?, corrected: Int) {
        guard let id, let index = scores.lastIndex(where: { $0.id == id }) else { return }
        scores[index].corrected = corrected
        try? store.save(scores, as: "scores.json")
    }
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
        media.release()
        finishAgent("(The user cancelled the spoken answer.)")
        // "Type as I speak" stops typing at once; the tap stays until its words are taken back, so a key or click
        // meanwhile still counts.
        let cancelledOperation = operation, cancelledSplit = splitTask, typer = liveTyper
        typer?.pause()
        if typer == nil { returnTap.stop() }
        generation = UUID(); let cancellation = generation
        splitTask?.cancel(); operation?.cancel(); batchToken = nil; watchdog?.cancel(); timer?.invalidate(); timer = nil
        for index in fileResults.indices where fileResults[index].document == nil && ["Queued", "Transcribing"].contains(fileResults[index].state) { fileResults[index].state = "Cancelled" }
        // Keep the lifecycle busy until the old analyzer, and a split still decoding, have released the recognizer.
        phase = .cancelling; status = "Cancelling…"
        Task {
            await cancelledOperation?.value; await cancelledSplit?.value; await speech.cancel()
            // "Type as I speak" takes its words back; ones the person had already moved on from stay.
            let wordsRemain = await typer?.takeBack() ?? false
            if let typer, liveTyper === typer { liveTyper = nil }
            returnTap.stop()
            guard generation == cancellation else { return }
            phase = .idle; status = wordsRemain ? "Cancelled. The words already typed were left in place." : "Cancelled. Nothing was inserted."
            overlay?.hide(); level = 0
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
        // Words typed live stay: they are still what was said.
        liveTyper?.abandon(); liveTyper = nil
        if output.isEmpty && !liveText.isEmpty { output = liveText }
        let failedOperation = operation, failedSplit = splitTask
        generation = UUID(); let failure = generation
        operation?.cancel(); splitTask?.cancel(); watchdog?.cancel(); timer?.invalidate(); timer = nil
        phase = .finishing; status = message
        Task {
            // Like cancel: a split still decoding holds the recognizer until it ends.
            await failedOperation?.value; await failedSplit?.value; await speech.cancel()
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
    typealias RefineResult = TextEnhancer.Outcome
    /// Runs cleanup or a rewrite against `cleanupTimeout` (`TextEnhancer.bounded`, shared with `DictationPolish`).
    func refine(_ work: @escaping @MainActor () async throws -> String) async -> RefineResult {
        await TextEnhancer.bounded(timeout: cleanupTimeout, work)
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
            persistedPreferences = Self.encoded(imported)
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
        let log = Diagnostics.dictation
        log.notice("shutdown: meeting"); await meeting.stop()
        log.notice("shutdown: speech"); await speech.cancel()
        log.notice("shutdown: parakeet"); await ParakeetRecognizer.shared.releaseIfIdle()
        log.notice("shutdown: whisper"); await WhisperRecognizer.shared.releaseIfIdle()
        log.notice("shutdown: done")
    }
}
