import AppKit
import Combine
import SwiftUI

/// The notch hub: one borderless panel over the notch that opens on hover into a tabbed panel.
/// Idle cost is zero: it reacts to hover, screen and Space changes and to pushes from tabs.
@MainActor public final class NotchHub: ObservableObject {
    public static let shared = NotchHub()

    @Published public private(set) var tabIDs: [String] = []
    @Published public var selectedID: String? {
        didSet {
            guard let old = oldValue.flatMap({ tabIDs.firstIndex(of: $0) }), let new = selectedID.flatMap({ tabIDs.firstIndex(of: $0) }) else { return }
            if new != old { selectionDirection = new > old ? 1 : -1 }
        }
    }
    /// +1 when the last tab change moved right, -1 left; tab content slides that way.
    @Published public private(set) var selectionDirection = 1
    /// A short-lived card that drops out of the closed notch (a new song, a finished timer, power plugged in).
    @Published public private(set) var peekView: AnyView?
    /// What a peek shows in the menu-bar band beside the camera until the pointer hovers the notch.
    @Published private(set) var peekEars: (leading: AnyView?, trailing: AnyView?) = (nil, nil)
    /// The word in the band while a peek shows, when the peek sets no trailing ear.
    @Published private(set) var peekTitle = ""
    /// Live states (dictation, a result, a peek) stay in the menu-bar band; hovering grows only a peek into its card.
    /// Expanding widens the hover target back to the full band (see `trackerFrame(on:)`).
    @Published public private(set) var liveExpanded = false { didSet { if liveExpanded != oldValue { refreshStrips() } } }
    var hasLiveState: Bool { dictation != nil || result != nil || peekView != nil }
    /// Whether a peek has something for the right ear: the caller's own, or its title when that fits whole.
    var peekHasTrailing: Bool { peekEars.trailing != nil || MorphingNotch.titleFits(peekTitle) }
    /// A peek with nothing for the right ear sits in the band on the left only (until hovered).
    var peekGrowsLeftOnly: Bool { !isOpen && dictation == nil && peekView != nil && !liveExpanded && !peekHasTrailing }

    /// The invisible hover target over the home notch: the same span as the band drawn there, so the pointer
    /// never wakes the hub over empty menu bar.
    func trackerFrame(on geometry: NotchGeometry) -> NSRect {
        if peekGrowsLeftOnly { return geometry.closedLeftLive }
        if hasLiveState || liveExpanded { return geometry.closedWide }
        if geometry.notchWidth == 0 { return pillShown ? geometry.pill(wide: pillWide) : geometry.closed }
        return compactTab != nil ? geometry.closedWide : geometry.closed
    }
    private var peekToken = UUID()
    /// True while the shape springs back into the old display's edge before the panel moves to another display, so
    /// following the work from one display to the next is two springs, never a jump.
    @Published private(set) var hopping = false
    private var hopTask: Task<Void, Never>?
    @Published public private(set) var isOpen = false
    /// The tab that shows a running dictation when the hub is open (Mouthy's own tab). Closed, the band is the whole
    /// dictation; open, the tab shows it bigger. Nil in hosts that bring their own dictation: the band stays the only surface.
    public var dictationTabID: String?
    /// Whether the hub may open (or stay open) while dictating.
    var opensDuringDictation: Bool { dictationTabID.map { tabs[$0] != nil } ?? false }
    /// Level ticks (12 a second) go only to `voice`, which feeds the glow and bar layers directly; the hub
    /// re-renders only when the dictation's words, target, phase or prompt change.
    public private(set) var dictation: NotchDictation? {
        willSet {
            var old = dictation, new = newValue
            old?.level = 0; new?.level = 0
            if old != new { objectWillChange.send() }
            let level = newValue.map { $0.transcribing ? 0 : $0.level } ?? 0
            voice.send(level)
        }
    }
    /// The live voice level while dictating.
    public let voice = VoiceLevelFeed()
    @Published public private(set) var result: (text: String, ok: Bool)?
    /// Bumped whenever a tab reports a change, so the rail and body redraw.
    @Published public private(set) var revision = 0
    @Published public private(set) var geometry: NotchGeometry?
    /// True while the hub's shape rests as the live-activity pill on a display without a notch (music, a timer, AI
    /// usage). The pill is the hub's own shape, so dictation and results morph out of it and back into it.
    @Published private(set) var pillShown = false
    /// The pill shows the accessory readout beside a tab's live content.
    var pillWide: Bool { compactTab != nil && pillAccessory?() != nil }
    private var hasPillContent: Bool { compactTab != nil || pillAccessory?() != nil }
    /// A tab's notice (a shortcut that finished) that arrived while dictating: it waits for the dictation's own
    /// outcome instead of replacing the live band.
    private var pendingNotice: (text: String, ok: Bool)?

    /// Dragging files over the closed notch opens this tab (the shelf).
    public var fileDropTabID: String?
    /// Small status items drawn either side of the notch at the top of the open panel (date, now playing).
    public var headerLeading: (() -> AnyView)?
    public var headerTrailing: (() -> AnyView)?
    /// Extra live readout for the pill on displays without a notch (AI usage). Nil or returning nil: none.
    public var pillAccessory: (() -> AnyView?)?
    /// How long the pointer rests on the notch before it opens.
    public var openDelay: Duration = .milliseconds(200)
    /// A light trackpad tap when the hub opens.
    public var haptics = true
    /// Opened from the keyboard: stays open until Esc, the shortcut again, or a click elsewhere.
    @Published public private(set) var keyboardOpen = false
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var swipeTravel: CGFloat = 0
    private var tabs: [String: any NotchTab] = [:]
    private var panel: NotchPanel?
    private var observers: [NSObjectProtocol] = []
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var hiddenForFullScreen = false
    /// The display the open panel or a live state (dictation, a result, a peek) is on; nil means the resting
    /// place: the pill's display, else the notch.
    private var visitingScreen: NSScreen?
    /// The display whose notch or strip the pointer last entered; opening from a hover happens there.
    private var hoverScreen: NSScreen?
    /// The display being worked on (the frontmost app's window), refreshed on app, Space and display changes.
    private var workScreen: NSScreen?
    /// Where the panel is drawn right now; nil while it is off screen.
    private var panelScreen: NSScreen?
    private var strips: [NotchStrip] = []
    /// Invisible tracker over the resting notch: the panel ignores the mouse while closed, so this receives
    /// the hover, clicks and file drags there.
    private var homeTracker: NotchStrip?
    private var opening = false
    private var attentionFlags: [String: Bool] = [:]

    /// Internal so renders and tests can draw a hub of their own; apps use `shared`.
    init() {}

    public var isRunning: Bool { panel != nil }
    /// True while a full-screen app covers the notch screen and the hub keeps itself off screen.
    public var isHiddenForFullScreen: Bool { hiddenForFullScreen }
    /// Called on the main actor when the hub hides for, or returns from, a full-screen app.
    public var onFullScreenChange: ((Bool) -> Void)?

    public func tab(_ id: String) -> (any NotchTab)? { tabs[id] }
    public var orderedTabs: [any NotchTab] { tabIDs.compactMap { tabs[$0] } }

    public func register(_ tab: any NotchTab) {
        if tabs[tab.id] == nil { tabIDs.append(tab.id) }
        tabs[tab.id] = tab
        attentionFlags[tab.id] = tab.prefersAttention
        if selectedID == nil { selectedID = tab.id }
        revision &+= 1
    }

    public func unregister(id: String) {
        tabs[id] = nil; tabIDs.removeAll { $0 == id }; attentionFlags[id] = nil
        if selectedID == id { selectedID = tabIDs.first }
        revision &+= 1
    }

    /// Opens the hub on a tab.
    public func show(tabID: String) {
        guard tabs[tabID] != nil else { return }
        selectedID = tabID
        setOpen(true)
    }

    /// The global shortcut: opens the hub with keyboard focus, or closes it.
    public func toggleFromKeyboard() {
        guard panel != nil, dictation == nil else { return }
        if isOpen { setOpen(false); return }
        hoverScreen = NotchGeometry.pointerScreen()
        keyboardOpen = true
        setOpen(true)
        panel?.makeKey()
    }

    /// Moves to the next or previous tab, wrapping around.
    public func selectAdjacent(_ step: Int) {
        guard !tabIDs.isEmpty else { return }
        let index = selectedID.flatMap { tabIDs.firstIndex(of: $0) } ?? 0
        select(tabIDs[(index + step + tabIDs.count) % tabIDs.count])
    }

    /// Selects a tab the same way for a click, ⌘1…9, ⌃Tab and a swipe: one spring, one haptic tick.
    func select(_ id: String) {
        guard tabs[id] != nil, id != selectedID else { return }
        withAnimation(MouthyMotion.resolve(MouthyMotion.tab, reduceMotion: Self.reduceMotion)) { selectedID = id }
        if haptics, isOpen { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// The system Reduce Motion setting, for animations started outside a view.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Renders and tests: puts a hub without a panel into the open or peeking state.
    func stageForPreview(open: Bool = false) {
        resultTask?.cancel(); result = nil
        isOpen = open
        peekView = nil; peekTitle = ""
    }

    /// Renders and tests: rests the hub as the pill on a display without a notch.
    func stageForPreview(pill: Bool) { pillShown = pill }
    /// Tests: holds the shape at rest as if moving to another display.
    func stageForPreview(hopping: Bool) { self.hopping = hopping }

    /// Renders and tests: shows `peek` in a closed hub, with `title` as the band's word.
    func stageForPreview(peek: AnyView, title: String, leading: AnyView? = nil, trailing: AnyView? = nil) {
        resultTask?.cancel(); result = nil
        isOpen = false
        peekView = peek; peekTitle = title; peekEars = (leading, trailing)
    }

    /// Replaces the tab order; ids not registered are ignored, registered ones not listed keep their place at the end.
    public func reorder(_ ids: [String]) {
        let known = ids.filter { tabs[$0] != nil }
        tabIDs = known + tabIDs.filter { !known.contains($0) }
        revision &+= 1
    }

    /// Closes (or opens) the hub on behalf of a tab, e.g. before dictation starts.
    public func setOpenFromHost(_ open: Bool) { setOpen(open) }

    /// A tab's badge, attention or content changed.
    public func tabDidChange(id: String) {
        guard let tab = tabs[id] else { return }
        revision &+= 1
        if panel != nil, !isOpen { layout() } else { refreshStrips() }
        let wants = tab.prefersAttention
        if wants, attentionFlags[id] != true, !isOpen, dictation == nil { show(tabID: id) }
        attentionFlags[id] = wants
    }

    // MARK: Dictation

    public func presentDictation(_ state: NotchDictation) {
        guard dictation == nil else { dictation = state; return }   // level ticks: the shape is already placed
        resultTask?.cancel(); settleTask?.cancel()
        if isOpen, opensDuringDictation, panel?.isKeyWindow != true, let id = dictationTabID {
            // Opened by the pointer: it stays open and its dictation tab shows the words, bigger.
            peekToken = UUID()
            peekView = nil; result = nil; liveExpanded = false
            selectedID = id
            dictation = state
            return
        }
        // One surface: an open panel, a peek, a result or the resting pill morphs into the dictation band in place,
        // in one spring, and the peek does not come back when the dictation ends.
        let wasOpen = isOpen
        if !wasOpen, result == nil, peekView == nil {
            // The words go to the app being worked on, so the band shows on its display: where the pill already rests.
            refreshWorkScreen()
            visitingScreen = workScreen ?? NotchGeometry.pointerScreen()
        }
        peekToken = UUID()
        withAnimation(MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: Self.reduceMotion)) {
            peekView = nil
            result = nil
            isOpen = false
            liveExpanded = false
            dictation = state
        }
        if wasOpen {
            openTask?.cancel(); openTask = nil
            removeMonitors()
            keyboardOpen = false
            // Opened from the keyboard, the panel holds key focus; hand it back so the words go to your app.
            if panel?.isKeyWindow == true { panel?.orderOut(nil) }
        }
        if panel != nil { layout() }
    }

    /// Ends the dictation with no outcome to show (cancelled, nothing to say): the band springs back to rest in place.
    public func endDictation() {
        let wasDictating = dictation != nil
        withAnimation(MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: Self.reduceMotion)) {
            dictation = nil
            liveExpanded = false
        }
        guard panel != nil else { return }
        guard wasDictating else { goHomeIfIdle(); return }
        // The panel stays on this display until the band has sprung back, then goes to its resting place.
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
            self?.settle()
        }
    }

    /// Ends the dictation with its outcome: the band turns into the result in the same shape.
    public func endDictation(result text: String, ok: Bool) {
        showResult(text, ok: ok)
    }

    /// Shows a small notice for a few seconds: `leading`/`trailing` in the menu-bar band beside the camera,
    /// the full card (`view`) only while the pointer hovers the notch. Each ear holds about 10 characters at
    /// 11 pt; longer text is cut with an ellipsis. `title` is what VoiceOver reads and what the band says when
    /// there is no trailing ear, only if it fits whole ("Charging"); otherwise the leading glyph stands alone.
    /// Ignored while open or dictating.
    public func peek(_ view: AnyView, seconds: Double = 3.5, leading: AnyView? = nil, trailing: AnyView? = nil, title: String) {
        guard panel != nil, !isOpen, dictation == nil else { return }
        placeLive()
        peekEars = (leading, trailing); peekTitle = title
        let token = UUID(); peekToken = token
        withAnimation(MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: Self.reduceMotion)) { peekView = view }
        layout()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.peekToken == token else { return }
            withAnimation(MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: Self.reduceMotion)) { self.peekView = nil }
            try? await Task.sleep(for: .milliseconds(380))
            if self.peekToken == token { self.goHomeIfIdle() }
        }
    }

    /// How long a result stays in the band.
    public static let resultDuration: Duration = .seconds(1.5)
    /// How long an outcome that needs reading ("Copied · paste it yourself") stays.
    public static let attentionDuration: Duration = .seconds(3)

    /// A one-line notice from a tab ("Ran Focus"), shown for 1.5 s (3 s when it needs attention). While a dictation
    /// runs it waits for the dictation to end, so it never replaces the live band.
    public func presentResult(_ text: String, ok: Bool) {
        if dictation != nil { pendingNotice = (text, ok); return }
        showResult(text, ok: ok)
    }

    private func showResult(_ text: String, ok: Bool) {
        resultTask?.cancel(); settleTask?.cancel()
        if dictation == nil, result == nil, peekView == nil { placeLive() }
        withAnimation(MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: Self.reduceMotion)) {
            dictation = nil
            liveExpanded = false
            result = (text, ok)
        }
        if panel != nil { layout() }
        let hold = ok ? Self.resultDuration : Self.attentionDuration
        let deadline = ContinuousClock.now.advanced(by: hold)
        resultTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self?.expireResult()
            do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
            self?.settle()
        }
    }

    /// The outcome leaves in one spring, back to rest in place (the notch, its ears or the pill).
    func expireResult() {
        withAnimation(MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: Self.reduceMotion)) { result = nil }
    }

    /// After a live state has sprung back: a held notice shows next, otherwise the hub goes to its resting place.
    func settle() {
        guard dictation == nil, result == nil else { return }
        if let notice = pendingNotice { pendingNotice = nil; showResult(notice.text, ok: notice.ok); return }
        if panel != nil { goHomeIfIdle() }
    }

    // MARK: Panel

    public func start() {
        guard panel == nil else { return }
        let panel = NotchPanel()
        panel.contentView = NSHostingView(rootView: NotchRootView(hub: self).preferredColorScheme(.dark).tint(MouthyTheme.orange))
        self.panel = panel
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        resignObserver = center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.keyboardOpen else { return }
                self.setOpen(false)
            }
        }
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.visitingScreen = nil; self?.hoverScreen = nil; self?.refreshWorkScreen()
                    self?.rebuildStrips(); self?.layout()
                }
            },
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshWorkScreen(); self?.refreshFullScreen(); self?.layout() }
            },
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                // The active app may be on another display now; the pill follows it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    self?.refreshWorkScreen(); self?.refreshFullScreen(); self?.layout()
                }
            }
        ]
        refreshWorkScreen()
        refreshFullScreen()
        rebuildStrips()
        layout()
    }

    public func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        openTask?.cancel(); closeTask?.cancel()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        removeMonitors()
        strips.forEach { $0.orderOut(nil) }; strips = []
        homeTracker?.orderOut(nil); homeTracker = nil
        hopTask?.cancel(); hopTask = nil; hopping = false
        panel?.orderOut(nil); panel = nil
        panelScreen = nil; pillShown = false
        isOpen = false
    }

    /// Pointer entered or left the hub's visible shape.
    func hover(_ inside: Bool) {
        // While something live sits in the band, hovering never opens the tabs. Dictation and results stay in the
        // wings (nothing more of the menu bar is ever covered); only a peek opens into its card.
        if !isOpen, hasLiveState || liveExpanded, !(dictation != nil && opensDuringDictation) {
            openTask?.cancel(); openTask = nil
            let grows = inside && dictation == nil && result == nil && peekView != nil
            if liveExpanded != grows {
                withAnimation(MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: Self.reduceMotion)) { liveExpanded = grows }
            }
            return
        }
        if inside {
            closeTask?.cancel(); closeTask = nil
            guard !isOpen, openTask == nil else { return }
            let delay = openDelay
            openTask = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.openTask = nil
                self?.setOpen(true)
            }
        } else {
            openTask?.cancel(); openTask = nil
            if !isOpen { hoverScreen = nil }
            guard isOpen, !keyboardOpen else { return }
            closeTask?.cancel()
            closeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                self.closeTask = nil
                // Hover events only arrive when the pointer moves. A pill or strip under the panel can report
                // "exited" while the pointer is resting on the panel, so ask where the pointer really is.
                if self.pointerIsOverPanel { return }
                self.setOpen(false)
            }
        }
    }

    func setOpen(_ open: Bool) {
        // While dictating the band is the surface, unless a tab shows the dictation (then it opens on that tab).
        guard open != isOpen, panel != nil, !(open && dictation != nil && !opensDuringDictation) else { return }
        if open {
            if dictation != nil, let id = dictationTabID { selectedID = id }
            hopTask?.cancel(); hopTask = nil; hopping = false
            peekToken = UUID(); peekView = nil
            // Open where the pointer is (or where the hub already shows), as one spring from that shape.
            visitingScreen = hoverScreen ?? visitingScreen ?? panelScreen ?? NotchGeometry.notchedScreen() ?? NotchGeometry.pointerScreen()
            hoverScreen = nil
            opening = true
            layout()   // place the (fixed-size) window on the right display first, then morph open
            opening = false
            withAnimation(MouthyMotion.resolve(MouthyMotion.notchOpen, reduceMotion: Self.reduceMotion)) { isOpen = true }
            panel?.ignoresMouseEvents = false
            if haptics { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            installMonitors()
        } else {
            removeMonitors()
            keyboardOpen = false
            withAnimation(MouthyMotion.resolve(MouthyMotion.notchClose, reduceMotion: Self.reduceMotion)) { isOpen = false }
            panel?.ignoresMouseEvents = true
            // Opened from the keyboard, the panel holds key focus; hand it back so typing goes to your app.
            if panel?.isKeyWindow == true { panel?.orderOut(nil); layout() }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(620))   // let the content leave and the notch spring back first
                guard let self, !self.isOpen else { return }
                self.goHomeIfIdle()
            }
        }
    }

    /// While open: Esc closes, ⌃Tab / ⌃⇧Tab and ⌘1…9 switch tabs, a sideways two-finger swipe pages tabs.
    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 { self.setOpen(false); return nil }
            if event.keyCode == 48, flags.contains(.control) { self.selectAdjacent(flags.contains(.shift) ? -1 : 1); return nil }
            if self.handleCommandDigit(event) { return nil }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.phase == .began { self.swipeTravel = 0 }
            // Only clearly sideways gestures page tabs; vertical scrolling stays with lists and lyrics.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 else { return event }
            self.swipeTravel += event.scrollingDeltaX
            if abs(self.swipeTravel) > 70 {
                self.selectAdjacent(self.swipeTravel > 0 ? -1 : 1)
                self.swipeTravel = 0
                return nil
            }
            return event
        }
    }

    /// ⌘1…9 picks a tab. Called from the key monitor and from the panel's key-equivalent path,
    /// which is where AppKit routes ⌘ shortcuts.
    func handleCommandDigit(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard isOpen, flags == .command, let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
              (1...9).contains(digit), digit <= tabIDs.count else { return false }
        select(tabIDs[digit - 1])
        return true
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil; scrollMonitor = nil
    }

    /// True while the pointer is over the visible open panel (not its transparent shadow margin).
    var pointerIsOverPanel: Bool {
        guard let panel, isOpen else { return false }
        let m = NotchGeometry.shadowMargin
        let visible = NSRect(x: panel.frame.minX + m, y: panel.frame.minY + m, width: panel.frame.width - 2 * m, height: panel.frame.height - m)
        return NSMouseInRect(NSEvent.mouseLocation, visible, false)
    }

    // MARK: Displays

    /// A live state with nothing showing yet appears where the hub already is (the notch or the pill), else under
    /// the pointer.
    private func placeLive() {
        guard visitingScreen == nil else { return }
        visitingScreen = panelScreen ?? NotchGeometry.pointerScreen()
    }

    private func refreshWorkScreen() {
        workScreen = Self.frontmostWindowScreen() ?? NotchGeometry.pointerScreen()
    }

    /// Back to the resting place (the pill's display, the notch, or hidden in clamshell) once nothing is showing.
    private func goHomeIfIdle() {
        if !isOpen, dictation == nil, result == nil, peekView == nil { visitingScreen = nil; liveExpanded = false }
        layout()
    }

    /// Displays without a notch get an invisible strip at the top centre; the hub drops down there on hover.
    private func rebuildStrips() {
        strips.forEach { $0.orderOut(nil) }
        homeTracker?.orderOut(nil); homeTracker = nil
        let home = NotchGeometry.notchedScreen()
        if let home {
            let tracker = NotchStrip(frame: NotchGeometry.on(home).closed, screen: home)
            tracker.onEnter = { [weak self] in self?.hoverScreen = home; self?.hover(true) }
            tracker.onExit = { [weak self] in self?.hover(false) }
            tracker.onDrag = { [weak self] in
                guard let self, let id = self.fileDropTabID else { return }
                self.hoverScreen = home; self.show(tabID: id)
            }
            tracker.orderFrontRegardless()
            homeTracker = tracker
        }
        strips = NSScreen.screens.filter { $0 != home }.map { screen in
            let strip = NotchStrip(frame: NotchGeometry.strip(on: screen.frame), screen: screen)
            strip.onEnter = { [weak self] in self?.hoverScreen = screen; self?.hover(true) }
            strip.onExit = { [weak self] in self?.hover(false) }
            strip.onDrag = { [weak self] in
                guard let self, let id = self.fileDropTabID else { return }
                self.hoverScreen = screen; self.show(tabID: id)
            }
            strip.orderFrontRegardless()
            return strip
        }
        refreshStrips()
    }

    /// The tab whose live content shows while closed (highest priority), if any.
    public var compactTab: (any NotchTab)? {
        orderedTabs.filter { $0.compactBody() != nil }.max { $0.compactPriority < $1.compactPriority }
    }

    /// The accessory's content changed (new usage numbers).
    public func accessoryDidChange() { revision &+= 1; if isOpen { refreshStrips() } else { layout() } }

    /// The pill shows on one display only, the one being worked on, and only when it has no notch: on the notch
    /// display the notch itself shows live content.
    private var pillTarget: NSScreen? {
        guard hasPillContent, !hiddenForFullScreen, let screen = visitingScreen ?? workScreen,
              screen != NotchGeometry.notchedScreen() else { return nil }
        return screen
    }

    /// The display holding the frontmost app's front window. (NSScreen.main describes this app's own key
    /// window, and the hub is never key, so it would always answer the menu-bar display.)
    static func frontmostWindowScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Window bounds are top-left based on the primary display; convert centres to AppKit coordinates.
        // The first real window wins: apps keep thin helper windows (toolbars, off-screen strips) too.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = window[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 160, (b["Height"] ?? 0) >= 120 else { continue }
            let centre = NSPoint(x: (b["X"] ?? 0) + (b["Width"] ?? 0) / 2, y: primaryHeight - ((b["Y"] ?? 0) + (b["Height"] ?? 0) / 2))
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(centre, $0.frame, false) }) { return screen }
        }
        return nil
    }

    /// Hover targets follow the shape: over the notch, the pill or the band wherever the hub is drawn, otherwise
    /// the bare notch and an invisible strip at the top of each other display.
    private func refreshStrips() {
        let closed = !isOpen
        if let homeTracker {
            let geometry = NotchGeometry.on(homeTracker.display)
            // The tracker covers the whole band whenever the band shows something (a compact tab, the dictation
            // level, a result, a peek), so hovering the ears expands it; the panel itself ignores the mouse while closed.
            let frame = panelScreen == homeTracker.display ? trackerFrame(on: geometry) : geometry.closed
            if homeTracker.frame != frame { homeTracker.setFrame(frame, display: false) }
        }
        for strip in strips {
            let screen = strip.display
            let drawn = closed && panelScreen == screen && (pillShown || hasLiveState || liveExpanded)
            let frame = drawn ? trackerFrame(on: NotchGeometry.on(screen)) : NotchGeometry.strip(on: screen.frame)
            if strip.frame != frame { strip.setFrame(frame, display: false) }
        }
    }

    /// Places the one panel: on the display of the open panel or live state, else the pill's display, else the notch.
    /// The window is always the open panel's size and never resizes, so every change is the shape springing inside it.
    private func layout() {
        guard let panel else { refreshStrips(); return }
        let pill = pillTarget
        guard !hiddenForFullScreen, let screen = visitingScreen ?? pill ?? NotchGeometry.notchedScreen() else {
            panel.orderOut(nil)
            panelScreen = nil
            if pillShown { pillShown = false }
            refreshStrips()
            return
        }
        // Moving to another display while something is drawn: spring back into this display's edge first.
        if let from = panelScreen, from != screen, panel.isVisible,
           Self.movesBySpring(open: isOpen, opening: opening, drawn: pillShown || hasLiveState || (from == NotchGeometry.notchedScreen() && compactTab != nil)) {
            if Self.arrivesAtOnce(dictating: dictation != nil) { arrive(); return }
            if hopTask == nil, !hopping { hop() }
            return
        }
        let showsPill = screen == pill
        if pillShown != showsPill { pillShown = showsPill }
        panelScreen = screen
        let next = NotchGeometry.on(screen)
        if next != geometry { geometry = next }
        // Closed, the panel lets clicks through; the home tracker and strips handle the pointer.
        if panel.frame != next.open { panel.setFrame(next.open, display: true) }
        panel.ignoresMouseEvents = !isOpen
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.mainMenu.rawValue + 2, Self.otherNotchAppLayer() + 1))
        panel.orderFrontRegardless()
        refreshStrips()
    }

    /// Whether a move to another display goes by spring (back to rest here, then out there) instead of in one step:
    /// whenever the closed hub draws something. An open panel moves with the pointer, and nothing drawn moves unseen.
    static func movesBySpring(open: Bool, opening: Bool, drawn: Bool) -> Bool { !open && !opening && drawn }

    /// Dictation that starts on another display cannot wait for the hop (back to rest here, then out there, about
    /// 0.65 s): the person is speaking now. The shape moves at once and springs out from rest there, one spring.
    static func arrivesAtOnce(dictating: Bool) -> Bool { dictating }

    /// Moves the panel now with the shape at rest, then springs it out on the new display.
    private func arrive() {
        hopTask?.cancel()
        var still = Transaction(); still.disablesAnimations = true
        withTransaction(still) { hopping = true }
        panelScreen = nil
        hopTask = nil
        layout()
        let spring = MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: Self.reduceMotion)
        // One frame at rest on the new display, so the spring starts from the notch's own edge.
        hopTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self else { return }
            self.hopTask = nil
            withAnimation(spring) { self.hopping = false }
        }
    }

    /// Springs the shape back to rest on its display, moves the panel, then springs it out again on the new one.
    private func hop() {
        let spring = MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: Self.reduceMotion)
        withAnimation(spring) { hopping = true }
        hopTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(320)) } catch { return }
            guard let self else { return }
            self.panelScreen = nil   // the shape is at rest: the move itself is unseen
            self.hopTask = nil
            self.layout()
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            withAnimation(spring) { self.hopping = false }
        }
    }

    /// Hides the hub while the frontmost app fills the notch screen (full-screen video, games, Keynote).
    private func refreshFullScreen() {
        let hidden = Self.frontmostIsFullScreen(on: NotchGeometry.preferredScreen())
        guard hidden != hiddenForFullScreen else { return }
        hiddenForFullScreen = hidden
        if hidden { setOpen(false) }
        layout()
        onFullScreenChange?(hidden)
    }

    /// While another notch app still runs, sit above its windows instead of under them.
    static func otherNotchAppLayer() -> Int {
        let owners: Set<String> = ["com.omninotch.app"]
        let pids = Set(NSWorkspace.shared.runningApplications.filter { owners.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
        guard !pids.isEmpty, let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return windows.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }
            .compactMap { $0[kCGWindowLayer as String] as? Int }.max() ?? 0
    }

    static func frontmostIsFullScreen(on screen: NSScreen?) -> Bool {
        guard let screen, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let size = screen.frame.size
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return abs((bounds["Width"] ?? 0) - size.width) < 1 && abs((bounds["Height"] ?? 0) - size.height) < 1
        }
    }
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false; isMovable = false
        setAccessibilitySubrole(.floatingWindow)
        setAccessibilityLabel("Mouthy notch")
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// The hub moves between displays and sits over the menu bar; AppKit must not pull it back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        MainActor.assumeIsolated { NotchHub.shared.handleCommandDigit(event) } || super.performKeyEquivalent(with: event)
    }
}

/// An invisible hover target: over the resting notch, or at the top centre of a display without one (a 3 pt
/// strip, or the pill's or band's frame while the hub draws there). Hovering it opens the hub on that display.
/// Pointer and drags come from AppKit tracking, never polling. Sits just under the hub and draws nothing, so the
/// hub's one shape is the only surface.
final class NotchStrip: NSPanel {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onDrag: (() -> Void)?
    let display: NSScreen

    init(frame: NSRect, screen: NSScreen) {
        self.display = screen
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        hidesOnDeactivate = false
        let view = StripView(frame: NSRect(origin: .zero, size: frame.size))
        view.strip = self
        view.autoresizingMask = [.width, .height]
        contentView = view
    }
    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        contentView?.frame = NSRect(origin: .zero, size: frameRect.size)
    }

    final class StripView: NSView {
        weak var strip: NotchStrip?
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }
        required init?(coder: NSCoder) { nil }
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            super.updateTrackingAreas()
        }
        // Nearly invisible but not fully clear, so the window server delivers events to the bare strip.
        override func draw(_ dirtyRect: NSRect) { NSColor.black.withAlphaComponent(0.003).setFill(); bounds.fill() }
        override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { strip?.onEnter?() } }
        override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { strip?.onExit?() } }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            MainActor.assumeIsolated { strip?.onDrag?() }
            return []
        }
        // Clicks fall through the hosting view to here; a click opens the hub like a hover would.
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
        override func mouseDown(with event: NSEvent) { MainActor.assumeIsolated { strip?.onEnter?() } }
    }
}

/// The pill's content on a display without a notch, inside the hub's own shape: live content (cover · caption ·
/// moving bars) and/or the accessory readout (AI usage), separated by a hairline.
struct PillContent: View {
    @ObservedObject var hub: NotchHub
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        let _ = hub.revision
        let tab = hub.compactTab
        let trailing = tab?.compactBody()
        let accessory = hub.pillAccessory?()
        HStack(spacing: 9) {
            if let tab, let trailing {
                Group {
                    if let leading = tab.compactLeading() { leading }
                    else { Text(Image(systemName: tab.symbolName)).font(.system(size: 11, weight: .semibold)).foregroundStyle(MouthyTheme.glow) }
                }
                .frame(width: 22)
                if let caption = tab.compactCaption {
                    Text(caption).font(.system(size: 11.5, weight: .semibold, design: .rounded)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                trailing.font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1)
                    .frame(minWidth: 22)
            }
            if let accessory {
                if trailing != nil { Rectangle().fill(MouthyTheme.cream.opacity(0.18)).frame(width: 0.6, height: 12) }
                else { Spacer(minLength: 0) }
                accessory.font(.system(size: 11, weight: .semibold, design: .rounded)).fixedSize()
                if trailing == nil { Spacer(minLength: 0) }
            }
        }
        .foregroundStyle(MouthyTheme.cream)
        // 9 pt in, a 22 pt cover and a 22 pt trailing slot: both centred where the band's ears are, so the pill
        // turns into dictation (and back) in place.
        .padding(.horizontal, 9)
        .frame(width: width, height: height)
        .accessibilityElement(children: .combine)
    }
}
