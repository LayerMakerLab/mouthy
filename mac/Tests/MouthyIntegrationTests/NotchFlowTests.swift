import AppKit
import SwiftUI
import Testing
@testable import MouthyKit
@testable import MouthyNotch

// Dictation and the notch are one surface. The state-machine checks run in ./scripts/test.sh; the renders run with
// MOUTHY_RENDER_DIR=<dir> swift test --filter notchFlow.

private let realNotch: (left: CGFloat, right: CGFloat) = (663.5, 848.5)
private let renderGate = ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil

@MainActor private func flowNotch() -> (NotchHub, MorphingNotch, NotchGeometry) {
    // An M5 MacBook Pro built-in display as NSScreen reports it: 185 pt camera housing, 32 pt safe top.
    let geometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 949),
                                    notchLeft: realNotch.left, notchRight: realNotch.right, safeTop: 32)
    let hub = NotchHub()
    return (hub, MorphingNotch(hub: hub, geometry: geometry, panel: NotchGeometry.openSize), geometry)
}

/// Starting dictation (the shortcut) while the panel is open must morph the panel into the dictation state in
/// place, not leave the dictation invisible behind the open tabs.
@MainActor @Test func notchFlowDictationStartedWhileOpenMorphsInPlace() {
    let (hub, notch, _) = flowNotch()
    hub.stageForPreview(open: true)
    #expect(notch.stage == .open)
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    #expect(notch.stage == .dictation(prompt: false), "stage stayed \(notch.stage) with dictation running")
    #expect(!hub.isOpen)
}

/// With a dictation tab (Mouthy's own), the open hub stays open and shows the dictation in that tab, bigger; closed,
/// the band shows it.
@MainActor @Test func notchFlowOpenHubShowsTheDictationInItsTab() {
    let (hub, notch, _) = flowNotch()
    let tab = PlayingMusicTab()
    hub.register(tab)
    hub.dictationTabID = tab.id
    hub.stageForPreview(open: true)
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    #expect(hub.isOpen && notch.stage == .open, "stage \(notch.stage)")
    #expect(hub.selectedID == tab.id)
    hub.stageForPreview(open: false)
    #expect(notch.stage == .dictation(prompt: false))
}

/// The dictation (and result, peek) band must never reach past the wings the music ears already use, so
/// starting dictation while music plays covers no extra menu-bar items and the shape does not jump wider.
@MainActor @Test func notchFlowDictationEarsNoWiderThanLiveWings() {
    let (hub, notch, geometry) = flowNotch()
    hub.register(PlayingMusicTab())
    #expect(notch.stage == .compact)
    let music = notch.shapeSize(for: notch.stage)
    #expect(music.width == geometry.closedWide.width)
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    let dictation = notch.shapeSize(for: notch.stage)
    hub.presentResult("Inserted · Notes", ok: true)
    let result = notch.shapeSize(for: notch.stage)
    hub.stageForPreview(peek: AnyView(Text("Song")), title: "Song")
    let peek = notch.shapeSize(for: notch.stage)
    for (name, size) in [("dictation", dictation), ("result", result), ("peek", peek)] {
        #expect(size.width <= music.width && size.height == music.height, "\(name) band \(size) vs music ears \(music)")
    }
    // The hover target is the same band, never wider.
    #expect(hub.trackerFrame(on: geometry).width <= geometry.closedWide.width)
}

/// Hovering dictation, an agent's question or a result never grows the band past the wings (it would cover menu-bar
/// items); the question drops below the band instead. Only a peek opens into its card, and only while hovered.
@MainActor @Test func notchFlowHoverNeverWidensLiveStates() {
    let (hub, notch, geometry) = flowNotch()
    hub.register(PlayingMusicTab())
    let wings = geometry.closedWide.width
    let states: [(String, () -> Void)] = [
        ("dictation", { hub.presentDictation(NotchDictation(target: "Notes", level: 0.4)) }),
        ("prompt", { hub.presentDictation(NotchDictation(target: "Claude Code", prompt: "Which branch should I deploy to staging, main or the release branch? Say it.")) }),
        ("result", { hub.endDictation(result: "Inserted", ok: true) }),
        ("attention", { hub.endDictation(result: "Copied · paste it yourself", ok: false) }),
    ]
    for (name, configure) in states {
        configure()
        let resting = notch.shapeSize(for: notch.stage)
        hub.hover(true)
        let hovered = notch.shapeSize(for: notch.stage)
        #expect(hovered == resting && hovered.width <= wings && notch.inBand(notch.stage), "\(name): \(resting) → \(hovered) hovered, wings \(wings)")
        #expect(hub.trackerFrame(on: geometry).width <= wings, "\(name): hover target wider than the wings")
        hub.hover(false)
    }
    // An agent's question reads in up to three lines under the band.
    let tall = MorphingNotch.promptHeight(String(repeating: "Which branch should I deploy? ", count: 12), width: wings - 12)
    #expect(tall <= 3 * 17 + 10 && tall > MorphingNotch.promptHeight("Which branch?", width: wings - 12))
}

/// Following the work to another display: the shape springs back to rest where it is, then out on the new display,
/// never a jump. Only an open panel (it follows the pointer) or nothing drawn moves in one step.
@MainActor @Test func notchFlowDisplayMoveSpringsBackThenOut() {
    let (hub, notch, _) = flowNotch()
    hub.register(PlayingMusicTab())
    #expect(notch.stage == .compact)
    hub.stageForPreview(hopping: true)
    #expect(notch.stage == .rest)
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    #expect(notch.stage == .rest, "dictation must wait for the hop to land")
    hub.stageForPreview(hopping: false)
    #expect(notch.stage == .dictation(prompt: false))
    #expect(NotchHub.movesBySpring(open: false, opening: false, drawn: true))
    #expect(!NotchHub.movesBySpring(open: false, opening: false, drawn: false))
    #expect(!NotchHub.movesBySpring(open: true, opening: false, drawn: true))
    #expect(!NotchHub.movesBySpring(open: false, opening: true, drawn: true))
}

/// Opening the panel (from the host or ⌃⌥N) while dictating is refused: the band stays the one surface.
@MainActor @Test func notchFlowDictationKeepsThePanelClosed() {
    let (hub, notch, _) = flowNotch()
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    hub.setOpenFromHost(true)
    hub.toggleFromKeyboard()
    #expect(!hub.isOpen && notch.stage == .dictation(prompt: false))
}

/// A display without a notch, 1920 × 1080 with a 30 pt menu bar.
@MainActor private func externalNotch() -> (NotchHub, MorphingNotch, NotchGeometry) {
    let geometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1920, height: 1080), visible: NSRect(x: 0, y: 0, width: 1920, height: 1050),
                                    notchLeft: nil, notchRight: nil, safeTop: 0)
    let hub = NotchHub()
    return (hub, MorphingNotch(hub: hub, geometry: geometry, panel: NotchGeometry.openSize), geometry)
}

/// Hover targets are no windows at all: nothing of Mouthy sits under the pointer at the notch or a display's top
/// edge while the hub is closed, so the pointer and clicks there behave as if Mouthy were not running. They fire
/// enter and exit once per crossing.
@MainActor @Test func notchFlowStripsDrawNothing() throws {
    let screen = try #require(NSScreen.screens.first)
    let frame = NotchGeometry.strip(on: screen.frame)
    let strip = NotchStrip(frame: frame, screen: screen)
    defer { strip.close() }
    #expect(!((strip as AnyObject) is NSWindow))
    let before = NSApp?.windows.count ?? 0
    strip.orderFrontRegardless()
    #expect((NSApp?.windows.count ?? 0) == before, "a hover target must not open a window")
    var entered = 0, exited = 0
    strip.onEnter = { entered += 1 }; strip.onExit = { exited += 1 }
    let inside = NSPoint(x: frame.midX, y: frame.midY), outside = NSPoint(x: frame.midX, y: frame.minY - 50)
    strip.pointerMoved(to: outside); strip.pointerMoved(to: inside); strip.pointerMoved(to: inside)
    strip.pointerMoved(to: outside); strip.pointerMoved(to: outside)
    #expect(entered == 1 && exited == 1)

    // A file dragged in opens the drop tab once per drag; a text drag or a drag from before the press does not.
    var dropped = 0
    strip.onDrag = { dropped += 1 }
    let drag = NSPasteboard(name: NSPasteboard.Name("mouthy-test-drag-\(UUID().uuidString)"))
    defer { drag.releaseGlobally() }
    drag.clearContents(); drag.setString("text", forType: .string)
    strip.pressed(at: outside, drag: drag)
    drag.clearContents(); drag.setString("words", forType: .string)
    strip.dragged(to: inside, drag: drag)
    #expect(dropped == 0, "a text drag must not open the drop tab")
    strip.pressed(at: outside, drag: drag)
    strip.dragged(to: inside, drag: drag)
    #expect(dropped == 0, "nothing new was dragged since the press")
    drag.clearContents(); drag.writeObjects([URL(fileURLWithPath: NSTemporaryDirectory()) as NSURL])
    strip.dragged(to: outside, drag: drag)
    strip.dragged(to: inside, drag: drag); strip.dragged(to: inside, drag: drag)
    #expect(dropped == 1)
}

/// On a display without a notch the music pill is the hub's own shape at rest: dictation, its result and the way
/// back are the same shape changing state, never a second window, and it never has to grow from nothing.
@MainActor @Test func notchFlowExternalPillMorphsIntoDictationAndBack() {
    let (hub, notch, geometry) = externalNotch()
    hub.register(PlayingMusicTab())
    hub.stageForPreview(pill: true)
    let band = geometry.closedWide.size
    var steps: [(String, NotchStage, CGSize)] = []
    func record(_ name: String) { steps.append((name, notch.stage, notch.shapeSize(for: notch.stage))) }
    record("pill")
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.5)); record("dictation")
    hub.presentDictation(NotchDictation(target: "Notes", transcribing: true)); record("finishing")
    hub.endDictation(result: "Inserted", ok: true); record("result")
    hub.expireResult(); record("back")
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.5)); record("again")
    hub.endDictation(); record("cancelled")
    #expect(steps.map(\.1) == [.compact, .dictation(prompt: false), .dictation(prompt: false), .result, .compact, .dictation(prompt: false), .compact])
    for (name, _, size) in steps {
        #expect(size == band, "\(name): \(size) vs the band \(band)")
    }
}

/// A tab's notice (a shortcut finishing) while dictating must not replace the live band: it waits for the
/// dictation's own outcome and shows after it.
@MainActor @Test func notchFlowNoticeWaitsForTheDictation() {
    let (hub, notch, _) = flowNotch()
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    hub.presentResult("Ran Focus", ok: true)
    #expect(notch.stage == .dictation(prompt: false) && hub.result == nil)
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.6))   // the next level tick is not a fresh start
    #expect(notch.stage == .dictation(prompt: false))
    hub.endDictation(result: "Inserted", ok: true)
    #expect(hub.result?.text == "Inserted")
    hub.expireResult(); hub.settle()
    #expect(hub.result?.text == "Ran Focus")
    hub.expireResult(); hub.settle()
    #expect(hub.result == nil && notch.stage == .rest)
}

/// Outcomes add no words: one that needs the person is a dot in the band (the Mouthy tab says what), so the shape
/// never grows down or wider than the wings.
@MainActor @Test func notchFlowAttentionAddsNoWords() {
    let (hub, notch, geometry) = flowNotch()
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    hub.endDictation(result: "Copied · paste it yourself", ok: false)
    #expect(notch.shapeSize(for: notch.stage) == geometry.closedWide.size)
    hub.endDictation(result: "Inserted · Notes", ok: true)
    #expect(notch.shapeSize(for: notch.stage) == geometry.closedWide.size)
}

/// A peek that was up when dictation started must not come back after the dictation ends (flash of old news).
@MainActor @Test func notchFlowPeekDoesNotReturnAfterDictation() {
    let (hub, notch, _) = flowNotch()
    hub.stageForPreview(peek: AnyView(Text("Now playing")), title: "Song")
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    hub.endDictation()
    #expect(notch.stage == .rest, "stage after dictation ended: \(notch.stage)")
    #expect(hub.peekView == nil)
}

/// rest → dictation → result → rest stays one surface: the result replaces the dictation in the same band.
@MainActor @Test func notchFlowDictationHandsOffToResultInTheSameBand() {
    let (hub, notch, _) = flowNotch()
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    #expect(notch.inBand(notch.stage))
    hub.endDictation(result: "Inserted", ok: true)
    #expect(notch.stage == .result && hub.dictation == nil)
    #expect(notch.inBand(notch.stage))
}


/// Growing out of the bare notch, the ears wait for the wings: on the M5 (46 pt wings, 6 pt shoulder, a 22 pt ear
/// centred in its 40 pt wing) they show from 80% of the spring, the first point at which the wing's straight edge has
/// passed them; shrinking back they are gone by then. The line under the band shows only once the shape's bottom edge
/// has passed its lowest pixels (about 85% of the growth).
@MainActor @Test func notchFlowContentWaitsForTheShape() {
    let start = MorphingNotch.earRevealStart(growth: NotchGeometry.compactSide)
    #expect(abs(start - 0.8) < 0.001)
    let edge = (1 - start) * NotchGeometry.compactSide + start * MorphingNotch.restShoulder
    let ear = MorphingNotch.restShoulder + (NotchGeometry.compactSide - MorphingNotch.restShoulder - LiveBand.earSlot) / 2
    #expect(edge <= ear - 1)
    #expect(ShapeReveal.opacity(start - 0.01, from: start, to: start + 0.1) == 0)
    #expect(ShapeReveal.opacity(1, from: start, to: start + 0.1) == 1)
    #expect(ShapeReveal.opacity(0.85, from: 0.88, to: 0.98) == 0)
    #expect(MorphingNotch.earRevealStart(growth: 0) == 0)
}

/// Dictation starting on another display moves the hub at once and springs out there (one spring); anything else
/// still springs back here first, then out there.
@MainActor @Test func notchFlowDictationArrivesAtOnceOnAnotherDisplay() {
    #expect(NotchHub.arrivesAtOnce(dictating: true))
    #expect(!NotchHub.arrivesAtOnce(dictating: false))
}

/// While the frontmost app's menus reach the notch, macOS stops a real pointer at the notch's lower edge; the hover
/// target reaches below it so that pointer opens the hub.
@MainActor @Test func notchFlowHoverReachesBelowTheNotchEdge() {
    // Closed with nothing drawn and no spring running, the panel leaves the screen.
    #expect(NotchHub.leavesScreen(open: false, opening: false, closing: false, drawn: false))
    #expect(!NotchHub.leavesScreen(open: true, opening: false, closing: false, drawn: false))
    #expect(!NotchHub.leavesScreen(open: false, opening: true, closing: false, drawn: false))
    #expect(!NotchHub.leavesScreen(open: false, opening: false, closing: true, drawn: false))
    #expect(!NotchHub.leavesScreen(open: false, opening: false, closing: false, drawn: true))
    // macOS stops a real pointer at the notch's lower edge; the hover target reaches below it so that pointer opens it.
    let notch = NSRect(x: 659, y: 950, width: 193, height: 32)
    let hover = NotchHub.homeHover(notch)
    #expect(hover.maxY == notch.maxY && hover.minY < notch.minY - 1 && hover.width > notch.width)
    #expect(NSMouseInRect(NSPoint(x: notch.midX, y: notch.minY - 1), hover, false))
    // From the side along the menu bar the pointer stops short of the notch (x 658 for a notch from 663.5) or rests
    // just past it on the right (853-858 for a notch ending at 848.5); both open the hub.
    let real = NSRect(x: 659.5, y: 950, width: 193, height: 32)
    for x: CGFloat in [658, 853, 858] { #expect(NSMouseInRect(NSPoint(x: x, y: 975), NotchHub.homeHover(real), false), "x \(x)") }
}

/// Playing music keeps the band over a running timer (a missing cover is what read as broken); a meeting outranks
/// both only in the minutes before it starts.
@MainActor @Test func notchFlowMusicKeepsTheBandOverATimer() {
    #expect(MusicTab.playingPriority > TimersTab.runningPriority)
    #expect(CalendarTab.priority(startsIn: 240) > MusicTab.playingPriority)
    #expect(CalendarTab.priority(startsIn: -60) < TimersTab.runningPriority)
    #expect(CalendarTab.priority(startsIn: nil) < TimersTab.runningPriority)
}

/// A running timer's ring is the time left: full from second 0, emptying in one strokeEnd animation to 0 (never an
/// empty grey ring that fills in later).
@MainActor @Test func notchFlowTimerRingStartsFull() throws {
    let ring = TimerRingLayerView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    ring.layout()
    ring.apply(ends: Date().addingTimeInterval(25 * 60), length: 25 * 60, lineWidth: 2.5, tint: NSColor.orange.cgColor)
    let fill = try #require(ring.fillAnimation)
    #expect((fill.fromValue as? Double ?? 0) > 0.99 && (fill.toValue as? Double) == 0)
    #expect(abs(fill.duration - 25 * 60) < 2)
    ring.apply(ends: Date().addingTimeInterval(15), length: 60, lineWidth: 2.5, tint: NSColor.orange.cgColor)
    let quarter = try #require(ring.fillAnimation)
    #expect(abs((quarter.fromValue as? Double ?? 0) - 0.25) < 0.01 && (quarter.toValue as? Double) == 0)
}

/// Finishing shows its sweep on the first frame: the bars take the sweep's shape at once (no flat row of dots) and
/// the loop starts now, from that point.
@MainActor @Test func notchFlowFinishingSweepsFromTheFirstFrame() throws {
    let view = WaveformLayerView(frame: NSRect(x: 0, y: 0, width: 30, height: 16))
    view.layout()
    view.apply(level: 0.5, active: true, sweep: false, bars: 5, barWidth: 2.5, still: false)
    view.apply(level: 0, active: false, sweep: true, bars: 5, barWidth: 2.5, still: false)
    let bars = try #require(view.layer?.sublayers?.first?.mask?.sublayers)
    let heights = bars.map(\.bounds.height)
    #expect(heights.max()! > 2 * heights.min()!, "flat: \(heights)")
    let sweep = try #require(bars[0].animation(forKey: "sweep"))
    #expect(sweep.beginTime <= bars[0].convertTime(CACurrentMediaTime(), from: nil) + 0.001 && sweep.timeOffset > 0)
}

// MARK: Real notch geometry: music playing, then dictation

/// A playing music tab like `MusicTab`: cover art on the left ear, bars in the theme's glow on the right.
@MainActor private final class PlayingMusicTab: NotchTab {
    let id = "flow.music"
    let title = "Music"
    let symbolName = "music.note"
    func makeBody() -> AnyView { AnyView(Text("Music")) }
    var compactPriority: Int { 10 }
    var compactCaption: String? { "Song title" }
    func compactLeading() -> AnyView? { AnyView(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.85, green: 0.62, blue: 0.2)).frame(width: 20, height: 20)) }
    func compactBody() -> AnyView? { AnyView(EqualizerBars(playing: true, tint: MouthyTheme.glow)) }
}

/// Pixels inside `rect` (points, top-left origin) of a render that are lit (any channel above 40/255), or with
/// `dark`, that are the notch's black (every channel below 12/255).
@MainActor private func litPixels(in url: URL, rect: CGRect, pointWidth: CGFloat, dark: Bool = false) throws -> Int {
    let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
    let scale = CGFloat(rep.pixelsWide) / pointWidth
    var lit = 0
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let top = max(color.redComponent, color.greenComponent, color.blueComponent)
            if dark ? top < 12.0 / 255 : top > 40.0 / 255 { lit += 1 }
        }
    }
    return lit
}

/// Pixels close to the ember accent (235, 97, 69) in `rect`; the backdrop (204, 84, 102) is bluer than green, ember is not.
@MainActor private func emberPixels(in url: URL, rect: CGRect, pointWidth: CGFloat) throws -> Int {
    let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
    let scale = CGFloat(rep.pixelsWide) / pointWidth
    var count = 0
    for y in max(0, Int(rect.minY * scale))..<min(rep.pixelsHigh, Int(rect.maxY * scale)) {
        for x in max(0, Int(rect.minX * scale))..<min(rep.pixelsWide, Int(rect.maxX * scale)) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let (r, g, b) = (c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255)
            if abs(r - 235) < 30, abs(g - 97) < 30, abs(b - 69) < 30, g > b { count += 1 }
        }
    }
    return count
}

/// Music, then dictation, a result, an attention mark, a peek and dictation started over the open panel, rendered
/// with the real notch geometry. Fails if anything is drawn under the camera housing (where it can never be seen)
/// or any black reaches past the compact wings (covering menu-bar items).
@MainActor @Test(.enabled(if: renderGate))
func notchFlowMusicThenDictationRealGeometry() throws {
    Mascot.install()
    let (hub, _, geometry) = flowNotch()
    hub.register(PlayingMusicTab())
    let window = geometry.open
    let size = window.size
    // Camera housing in window points (top-left origin), 1 pt inside its edges so antialiasing does not count.
    let (notchLeft, notchRight) = realNotch
    let camera = CGRect(x: notchLeft - window.minX + 1, y: 1, width: notchRight - notchLeft - 2, height: geometry.notchHeight - 2)
    let wingLeft = geometry.closedWide.minX - window.minX, wingRight = geometry.closedWide.maxX - window.minX
    var problems: [String] = []
    let states: [(String, () -> Void)] = [
        ("music", { hub.endDictation() }),
        ("music-dictation", { hub.presentDictation(NotchDictation(target: "Notes", level: 0)) }),
        ("music-dictation-loud", { hub.presentDictation(NotchDictation(target: "Notes", level: 0.8)) }),
        ("music-transcribing", { hub.presentDictation(NotchDictation(target: "Notes", transcribing: true)) }),
        ("music-result", { hub.presentResult("Inserted", ok: true) }),
        ("music-attention", { hub.presentResult("Check the microphone", ok: false) }),
        ("music-peek", { hub.stageForPreview(peek: AnyView(Text("Song")), title: "Song") }),
        // Hovering dictation or a result never grows it past the wings; an agent's question drops below the band.
        ("music-dictation-hovered", { hub.presentDictation(NotchDictation(target: "Notes", level: 0.5)); hub.hover(true) }),
        ("music-result-hovered", { hub.presentResult("Inserted", ok: true); hub.hover(true) }),
        ("music-prompt", { hub.presentDictation(NotchDictation(target: "Claude Code", level: 0.4, prompt: "Which branch should I deploy to staging, main or the release branch?")) }),
        // Starting dictation with the panel open morphs the panel into the band in place.
        ("open-then-dictation", {
            hub.stageForPreview(open: true)
            hub.presentDictation(NotchDictation(target: "Notes", level: 0.5))
        }),
    ]
    for (name, configure) in states {
        configure()
        let view = ZStack(alignment: .top) { Color(red: 0.8, green: 0.33, blue: 0.4); NotchRootView(hub: hub, geometryOverride: geometry) }
        guard let url = try renderOffscreen(view, size: size, name: "flow-\(name)", settle: 1.2) else { continue }
        assertNoBlue(url)
        let hidden = try litPixels(in: url, rect: camera, pointWidth: size.width)
        if hidden > 0 { problems.append("\(name): \(hidden) lit px under the camera housing") }
        // Black beyond the wings, inside the band's height, covers menu-bar items.
        let covering = try litPixels(in: url, rect: CGRect(x: 0, y: 2, width: wingLeft - 2, height: geometry.notchHeight - 4), pointWidth: size.width, dark: true)
            + litPixels(in: url, rect: CGRect(x: wingRight + 2, y: 2, width: size.width - wingRight - 2, height: geometry.notchHeight - 4), pointWidth: size.width, dark: true)
        if covering > 0 { problems.append("\(name): \(covering) black px beyond the wings") }
        // An outcome that needs the person is one small ember dot in the right ear (the Mouthy tab says what); nothing
        // else is ever ember there.
        let embers = try emberPixels(in: url, rect: CGRect(x: notchRight - window.minX, y: 0, width: wingRight - (notchRight - window.minX), height: geometry.notchHeight), pointWidth: size.width)
        if name.hasSuffix("attention") ? !(1...160).contains(embers) : embers > 0 { problems.append("\(name): \(embers) ember px in the right ear") }
        print("FLOW \(name): \(hidden) lit px under the camera, \(covering) black px beyond the wings, \(embers) ember px")
        hub.hover(false)
        hub.endDictation()
    }
    #expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
}

/// A screenshot (notch-real.png, 376 × 41 px at 1x) from an external display showed the old music pill (cover
/// at the far left, art-red bars at the far right) in its own window, with the hub's dictation band drawn on top of
/// it. The pill is now the hub's own shape. This renders music, dictation, a result and an attention outcome
/// through the hub alone and fails on black past the band or anything lit in the band's middle while live.
@MainActor @Test(.enabled(if: renderGate))
func notchFlowExternalDisplayOneSurface() throws {
    Mascot.install()
    let (hub, _, geometry) = externalNotch()
    hub.register(PlayingMusicTab())
    hub.stageForPreview(pill: true)
    let window = geometry.open
    let bandLeft = geometry.closedWide.minX - window.minX, bandRight = geometry.closedWide.maxX - window.minX
    var problems: [String] = []
    let states: [(String, Bool, () -> Void)] = [
        ("external-music", false, { hub.endDictation() }),
        ("external-dictation", true, { hub.presentDictation(NotchDictation(target: "Notes", level: 0.6)) }),
        ("external-result", true, { hub.endDictation(result: "Inserted", ok: true) }),
        ("external-attention", true, { hub.endDictation(result: "Copied · paste it yourself", ok: false) }),
    ]
    for (name, live, configure) in states {
        configure()
        let view = ZStack(alignment: .top) { Color(red: 0.8, green: 0.33, blue: 0.4); NotchRootView(hub: hub, geometryOverride: geometry) }
        guard let url = try renderOffscreen(view, size: window.size, name: "flow-\(name)", settle: 1.2) else { continue }
        assertNoBlue(url)
        let height = geometry.notchHeight
        let covering = try litPixels(in: url, rect: CGRect(x: 0, y: 2, width: bandLeft - 2, height: height - 4), pointWidth: window.width, dark: true)
            + litPixels(in: url, rect: CGRect(x: bandRight + 2, y: 2, width: window.width - bandRight - 2, height: height - 4), pointWidth: window.width, dark: true)
        let middle = CGRect(x: window.width / 2 - geometry.cameraWidth / 2 + 1, y: 1, width: geometry.cameraWidth - 2, height: height - 2)
        let lit = live ? try litPixels(in: url, rect: middle, pointWidth: window.width) : 0
        if covering > 0 { problems.append("\(name): \(covering) black px beyond the band (a second surface)") }
        if lit > 0 { problems.append("\(name): \(lit) lit px in the band's middle") }
        print("FLOW \(name): \(covering) black px beyond the band, \(lit) lit px in the middle")
    }
    #expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
}

// MARK: Transitions, frame by frame

/// The black shape's horizontal extent in one row of a frame (points), nil when no black is in that row.
private func blackExtent(_ rep: NSBitmapImageRep, row: CGFloat, pointWidth: CGFloat) -> (min: CGFloat, max: CGFloat)? {
    let scale = CGFloat(rep.pixelsWide) / pointWidth
    let y = Int(row * scale)
    var first: Int?, last: Int?
    for x in 0..<rep.pixelsWide {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if max(c.redComponent, c.greenComponent, c.blueComponent) < 12.0 / 255 { first = first ?? x; last = x }
    }
    guard let first, let last else { return nil }
    return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
}

/// How far down the black shape reaches in one column of a frame (points from the top).
private func blackDepth(_ rep: NSBitmapImageRep, column: CGFloat, pointWidth: CGFloat) -> CGFloat {
    let scale = CGFloat(rep.pixelsWide) / pointWidth
    let x = Int(column * scale)
    var last = 0
    for y in 0..<rep.pixelsHigh {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if max(c.redComponent, c.greenComponent, c.blueComponent) < 12.0 / 255 { last = y }
    }
    return CGFloat(last) / scale
}

/// Which pixels of a frame are content: anything that is neither the notch's black, nor the backdrop, nor a blend of
/// the two (the shape's anti-aliased edge and its shadow). The backdrop is read from the frame's top-left corner.
private struct ContentMask {
    let width: Int, height: Int
    var bits: [Bool]
    init(_ rep: NSBitmapImageRep, threshold: Double = 36, x xs: Range<Int>? = nil, y ys: Range<Int>? = nil) {
        width = rep.pixelsWide; height = rep.pixelsHigh
        bits = Array(repeating: false, count: width * height)
        guard let data = rep.bitmapData, rep.bitsPerSample == 8 else { return }
        let stride = rep.bytesPerRow, step = rep.samplesPerPixel
        let offset = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        func pixel(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let p = data + y * stride + x * step + offset
            return (Double(p[0]), Double(p[1]), Double(p[2]))
        }
        let k = pixel(0, 0)
        let kk = k.0 * k.0 + k.1 * k.1 + k.2 * k.2
        for y in (ys ?? 0..<height).clamped(to: 0..<height) {
            for x in (xs ?? 0..<width).clamped(to: 0..<width) {
                let p = pixel(x, y)
                let t = (p.0 * k.0 + p.1 * k.1 + p.2 * k.2) / kk
                let off = abs(p.0 - t * k.0) + abs(p.1 - t * k.1) + abs(p.2 - t * k.2)
                bits[y * width + x] = off > threshold
            }
        }
    }
    /// Anything at all drawn in a region (a stricter threshold than `init`'s, for places nothing may be drawn).
    static func count(_ rep: NSBitmapImageRep, x: Range<Int>, y: Range<Int>, threshold: Double) -> Int {
        ContentMask(rep, threshold: threshold, x: x, y: y).count(in: (x, y))
    }
    /// Grown by `radius` pixels, so content that only shifts a pixel or two is not counted as gone.
    func dilated(_ radius: Int) -> ContentMask {
        var out = self
        for y in 0..<height {
            for x in 0..<width where bits[y * width + x] {
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < width, ny < height { out.bits[ny * width + nx] = true }
                    }
                }
            }
        }
        return out
    }
    /// Content pixels inside `rect` (pixels).
    func count(in rect: (x: Range<Int>, y: Range<Int>)) -> Int {
        var n = 0
        for y in rect.y.clamped(to: 0..<height) { for x in rect.x.clamped(to: 0..<width) where bits[y * width + x] { n += 1 } }
        return n
    }
    var total: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }
    /// Mean column (pixels) of the content inside `rect` and how many pixels it counts.
    func centroid(in rect: (x: Range<Int>, y: Range<Int>)) -> (x: Double, count: Int) {
        var sum = 0, n = 0
        for y in rect.y.clamped(to: 0..<height) { for x in rect.x.clamped(to: 0..<width) where bits[y * width + x] { sum += x; n += 1 } }
        return (n == 0 ? 0 : Double(sum) / Double(n), n)
    }
    /// Content pixels in `self` that sit on `old` content and not on `new` content: the old state still showing.
    func count(on old: ContentMask, notOn new: ContentMask) -> Int {
        var n = 0
        for i in 0..<bits.count where bits[i] && old.bits[i] && !new.bits[i] { n += 1 }
        return n
    }
}

/// One state change to watch. `checked` is false for setup (putting the hub in a state before the change under test).
private struct FlowStep {
    let name: String
    var checked = true
    /// The shape must end where it started (hovering dictation or a result never grows it).
    var holds = false
    /// The band must show the new state within this many milliseconds (feedback for the person speaking).
    var feedbackWithin: Int? = nil
    /// The right ear must show the finishing sweep (bars of different heights) from the first frame.
    var sweeps = false
    let change: () -> Void
}

/// How long one part of a state may dissolve in place into the next (MouthyMotion.dissolve plus a frame).
private let dissolveMs = 120

/// Content cut by the shape's edge: lit pixels (any channel over 120/255, not the backdrop) within 2 px inside the
/// shape's bottom edge (counted per column) or its side edges (per row of the band). A settled state has a small
/// baseline from its own corners; anything above that in a frame is content the moving edge is slicing.
private func edgeCuts(_ rep: NSBitmapImageRep) -> (bottom: Int, side: Int) {
    guard let data = rep.bitmapData, rep.bitsPerSample == 8 else { return (0, 0) }
    let w = rep.pixelsWide, h = rep.pixelsHigh, stride = rep.bytesPerRow, step = rep.samplesPerPixel
    let offset = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
    func px(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let p = data + y * stride + x * step + offset
        return (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
    }
    func backdrop(_ x: Int, _ y: Int) -> Bool { let p = px(x, y); return p.2 > p.1 + 0.02 && p.0 > p.2 && p.0 > 0.1 }
    // The shape's own anti-aliased edge is a blend of black and the backdrop (say 123, 67, 72 over 203, 114, 123):
    // bright enough, but not content. Content sits off that line.
    let k = px(0, 0), kk = max(1e-6, k.0 * k.0 + k.1 * k.1 + k.2 * k.2)
    func blend(_ p: (Double, Double, Double)) -> Bool {
        let t = (p.0 * k.0 + p.1 * k.1 + p.2 * k.2) / kk
        return abs(p.0 - t * k.0) + abs(p.1 - t * k.1) + abs(p.2 - t * k.2) < 36.0 / 255
    }
    func lit(_ x: Int, _ y: Int) -> Bool { let p = px(x, y); return max(p.0, p.1, p.2) > 120.0 / 255 && !backdrop(x, y) && !blend(p) }
    var bottom = 0, side = 0
    for x in 0..<w {
        var y = 0, sawShape = false
        while y < h - 1 { if backdrop(x, y) { if sawShape { break } } else { sawShape = true }; y += 1 }
        guard sawShape, y < h - 1, y > 4 else { continue }
        if lit(x, y - 1) || lit(x, y - 2) { bottom += 1 }
    }
    for y in 4..<min(h, 60) {
        var x = 0
        while x < w && backdrop(x, y) { x += 1 }
        if x > 0, x < w, (0...2).contains(where: { x + $0 < w && lit(x + $0, y) }) { side += 1 }
        var r = w - 1
        while r > 0 && backdrop(r, y) { r -= 1 }
        if r > 0, r < w - 1, (0...2).contains(where: { r - $0 > 0 && lit(r - $0, y) }) { side += 1 }
    }
    return (bottom, side)
}

/// Heights (pixels) of the lit columns in `rect`: the finishing sweep's bars differ, a flat row of dots does not.
private func columnHeights(_ mask: ContentMask, x: Range<Int>, y: Range<Int>) -> [Int] {
    x.clamped(to: 0..<mask.width).compactMap { column in
        let lit = y.clamped(to: 0..<mask.height).filter { mask.bits[$0 * mask.width + column] }
        return lit.isEmpty ? nil : (lit.max()! - lit.min()! + 1)
    }
}

/// Hosts the hub in a borderless window far off screen (never focused) and captures every frame while each state
/// change springs, so the transitions themselves are checked, not only where they end. In every frame:
/// - the shape's top row stays between where it started and where it ends (no gap, no jump, no flash, nothing past
///   the wider of the two, so no extra menu-bar items are covered);
/// - none of the old state's content still shows (two states at once, or old words cut off by the moving edge), once
///   a short in-place dissolve (`dissolveMs`) is over;
/// - between two states that both show something in the band, no frame shows an empty band (a blink);
/// - the first frame still shows the old state or already the new one: content is never cut before the shape moves;
/// - no content is cut by the moving edge: lit pixels just inside the shape's edge stay at the settled baseline;
/// - on the notched display nothing is lit under the camera.
@MainActor private func sampleTransitions(name: String, hub: NotchHub, geometry: NotchGeometry, camera: CGRect?,
                                          steps: [FlowStep]) throws -> [String] {
    let size = geometry.open.size
    let host = NSHostingView(rootView: ZStack(alignment: .top) { Color(red: 0.8, green: 0.33, blue: 0.4); NotchRootView(hub: hub, geometryOverride: geometry) }
        .frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.contentView = nil; window.close() }
    func capture() throws -> NSBitmapImageRep {
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let row = geometry.notchHeight / 2
    // The band's row, and its right ear, in pixels (the camera's middle is black either way).
    let scale = CGFloat(try capture().pixelsWide) / size.width
    let bandRows = 0..<Int(geometry.notchHeight * scale)
    let bandColumns = Int((geometry.closedWide.minX - geometry.open.minX) * scale)..<Int((geometry.closedWide.maxX - geometry.open.minX) * scale)
    let rightEar = Int((geometry.closedWide.midX - geometry.open.minX + geometry.cameraWidth / 2) * scale)..<bandColumns.upperBound
    // The two wings of the band (the camera's width between them).
    let leftEar = bandColumns.lowerBound..<bandColumns.lowerBound + Int(NotchGeometry.compactSide * scale)
    let rightWing = bandColumns.upperBound - Int(NotchGeometry.compactSide * scale)..<bandColumns.upperBound
    func band(_ mask: ContentMask) -> Int { mask.count(in: (bandColumns, bandRows)) }
    var problems: [String] = []
    var frames = 0
    let folder = ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"]
    var before = try capture()
    for step in steps {
        step.change()
        let start = Date()
        var shots: [(ms: Int, rep: NSBitmapImageRep)] = []
        while Date().timeIntervalSince(start) < 0.75 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
            shots.append((Int(Date().timeIntervalSince(start) * 1000), try capture()))
        }
        let after = shots[shots.count - 1].rep
        defer { before = after }
        guard step.checked else { continue }
        frames += shots.count
        let oldRaw = ContentMask(before), newRaw = ContentMask(after)
        let old = oldRaw, new = newRaw.dilated(3)
        let bandBefore = band(oldRaw), bandAfter = band(newRaw)
        // Content touching the shape's edge may never exceed what the two settled states show on their own.
        let settledBefore = edgeCuts(before), settledAfter = edgeCuts(after)
        let cutLimit = (bottom: max(settledBefore.bottom, settledAfter.bottom) + 2, side: max(settledBefore.side, settledAfter.side) + 2)
        // Both states show something in the band: no frame between them may be empty.
        let blinkFloor = bandBefore > 20 && bandAfter > 20 ? max(10, min(bandBefore, bandAfter) / 4) : nil
        if let first = shots.first {
            let shown = ContentMask(first.rep).total
            if oldRaw.total > 40, shown < oldRaw.total / 2, shown < newRaw.total / 2 {
                problems.append("\(step.name) +\(first.ms) ms: content cut before the shape moved (\(shown) of \(oldRaw.total) px)")
            }
        }
        if let within = step.feedbackWithin {
            let floor = max(20, bandAfter / 3)
            let first = shots.first { band(ContentMask($0.rep)) >= floor }?.ms
            print("FEEDBACK \(name) \(step.name): band shows the new state at +\(first.map(String.init) ?? "never") ms; " + shots.prefix(12).map { "\($0.ms):\(band(ContentMask($0.rep)))" }.joined(separator: " ") + " need \(floor)")
            if (first ?? .max) > within { problems.append("\(step.name): no feedback in the band within \(within) ms") }
        }
        let from = blackExtent(before, row: row, pointWidth: size.width), to = blackExtent(after, row: row, pointWidth: size.width)
        let inset = MorphingNotch.restShoulder + 2
        if let from, let to, abs(from.min - to.min) <= 1.5, abs(from.max - to.max) <= 1.5 {
            // The shape stays put: each ear's old and new content share one slot, so the swap is a dissolve in place
            // (no second layer beside the first, no jump).
            for (side, columns) in [("left", leftEar), ("right", rightWing)] {
                let a = oldRaw.centroid(in: (columns, bandRows)), b = newRaw.centroid(in: (columns, bandRows))
                if a.count > 40, b.count > 40, abs(a.x - b.x) / scale > 3 {
                    problems.append("\(step.name): the \(side) ear jumps \(Int((abs(a.x - b.x) / scale).rounded())) pt between the two states")
                }
            }
        }
        if step.holds, let from, let to, abs(from.min - to.min) > 1.5 || abs(from.max - to.max) > 1.5 {
            problems.append("\(step.name): the shape moved from \(Int(from.min))–\(Int(from.max)) to \(Int(to.min))–\(Int(to.max))")
        }
        if step.holds, let from {
            // Taller counts too: compare where the black ends below the band in the shape's centre column.
            let centre = (from.min + from.max) / 2
            if blackDepth(before, column: centre, pointWidth: size.width) != blackDepth(after, column: centre, pointWidth: size.width) {
                problems.append("\(step.name): the shape grew down")
            }
        }
        for (index, shot) in shots.enumerated() {
            let rep = shot.rep
            let extent = blackExtent(rep, row: row, pointWidth: size.width)
            let outer = [from, to].compactMap { $0 }
            if let extent, !outer.isEmpty {
                let lo = outer.map(\.min).min()!, hi = outer.map(\.max).max()!
                if extent.min < lo - 1.5 || extent.max > hi + 1.5 {
                    problems.append("\(step.name) +\(shot.ms) ms: shape \(Int(extent.min))–\(Int(extent.max)) past \(Int(lo))–\(Int(hi))")
                }
            }
            if let from, let to {
                // The body may never be narrower than both ends: no gap, no growing from nothing between two states.
                let lo = max(from.min, to.min) + inset, hi = min(from.max, to.max) - inset
                if let extent { if extent.min > lo || extent.max < hi { problems.append("\(step.name) +\(shot.ms) ms: shape short of both states") } }
                else { problems.append("\(step.name) +\(shot.ms) ms: no shape in the menu bar (a gap)") }
            }
            let cuts = edgeCuts(rep)
            if cuts.bottom > cutLimit.bottom || cuts.side > cutLimit.side {
                problems.append("\(step.name) +\(shot.ms) ms: content cut by the shape's edge (\(cuts.bottom) columns, \(cuts.side) rows)")
            }
            let mask = ContentMask(rep)
            let stale = mask.count(on: old, notOn: new)
            if stale > 24, shot.ms > dissolveMs { problems.append("\(step.name) +\(shot.ms) ms: \(stale) px of the old content still showing") }
            if let blinkFloor, band(mask) < blinkFloor {
                problems.append("\(step.name) +\(shot.ms) ms: empty band between two states (\(band(mask)) px)")
            }
            if step.sweeps {
                let heights = columnHeights(mask, x: rightEar, y: bandRows)
                if heights.isEmpty || heights.max()! < 2 * heights.min()! {
                    problems.append("\(step.name) +\(shot.ms) ms: finishing bars flat (\(heights.min() ?? 0)–\(heights.max() ?? 0) px)")
                }
            }
            if let camera {
                // Content only: at rest the shape is the notch itself, and the backdrop shows past its rounded
                // corners exactly as it does past the real housing's.
                let lit = ContentMask.count(rep, x: Int(camera.minX * scale)..<Int(camera.maxX * scale),
                                            y: Int(camera.minY * scale)..<Int(camera.maxY * scale), threshold: 12)
                if lit > 0 { problems.append("\(step.name) +\(shot.ms) ms: \(lit) lit px under the camera") }
            }
            if let folder, [0, 3, 6, 9, 14, shots.count - 1].contains(index) {
                let url = URL(fileURLWithPath: folder).appendingPathComponent("transition-\(name)-\(step.name)-\(String(format: "%03d", index)).png")
                try rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
    print("TRANSITION \(name): \(frames) frames, \(problems.count) problems")
    for problem in problems { print("PROBLEM \(name) \(problem)") }
    return problems
}

/// Every way into and out of dictation, frame by frame, on a display without a notch (the pill, with and without the
/// AI-usage readout) and on the M5's built-in display (the ears beside the camera): music, dictation, hovering it,
/// finishing, the result, an attention outcome, an agent's question, a peek and the open panel turning into dictation,
/// and a cancel.
@MainActor @Test(.enabled(if: renderGate))
func notchFlowTransitionsFrameByFrame() throws {
    Mascot.install()
    func steps(_ hub: NotchHub) -> [FlowStep] {
        [FlowStep(name: "dictation", feedbackWithin: 120) { hub.presentDictation(NotchDictation(target: "Notes", level: 0.5)) },
         FlowStep(name: "hover-dictation", holds: true) { hub.hover(true) },
         FlowStep(name: "unhover") { hub.hover(false) },
         FlowStep(name: "finishing", sweeps: true) { hub.presentDictation(NotchDictation(target: "Notes", transcribing: true)) },
         FlowStep(name: "result") { hub.endDictation(result: "Inserted", ok: true) },
         FlowStep(name: "hover-result", holds: true) { hub.hover(true) },
         FlowStep(name: "rest", checked: false) { hub.hover(false); hub.expireResult() },
         FlowStep(name: "again") { hub.presentDictation(NotchDictation(target: "Notes", level: 0.3)) },
         FlowStep(name: "attention") { hub.endDictation(result: "Copied · paste it yourself", ok: false) },
         FlowStep(name: "back") { hub.expireResult() },
         FlowStep(name: "prompt") { hub.presentDictation(NotchDictation(target: "Claude Code", level: 0.3, prompt: "Which branch should I deploy to staging?")) },
         FlowStep(name: "prompt-answered") { hub.endDictation(result: "Answered", ok: true) },
         FlowStep(name: "rest2", checked: false) { hub.expireResult() },
         FlowStep(name: "peek", checked: false) { hub.stageForPreview(peek: AnyView(Text("Song")), title: "Song") },
         FlowStep(name: "peek-to-dictation") { hub.presentDictation(NotchDictation(target: "Notes", level: 0.4)) },
         FlowStep(name: "cancelled") { hub.endDictation() },
         FlowStep(name: "open", checked: false) { hub.stageForPreview(open: true) },
         FlowStep(name: "open-to-dictation", feedbackWithin: 120) { hub.presentDictation(NotchDictation(target: "Notes", level: 0.4)) },
         FlowStep(name: "cancelled2") { hub.endDictation() },
         // The pointer leaves the open panel: it springs closed with its content dissolving, never blank first.
         FlowStep(name: "open2", checked: false) { hub.stageForPreview(open: true) },
         FlowStep(name: "hover-out") { hub.stageForPreview(open: false) },
         // Dictation starting on another display: the panel moves at once with the shape at rest (NotchHub.arrive)
         // and springs out into dictation in one spring.
         FlowStep(name: "away", checked: false) {
             var still = Transaction(); still.disablesAnimations = true
             withTransaction(still) { hub.stageForPreview(hopping: true) }
         },
         FlowStep(name: "arrive", feedbackWithin: 150) {
             hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
             withAnimation(MouthyMotion.morph) { hub.stageForPreview(hopping: false) }
         },
         FlowStep(name: "cancelled3") { hub.endDictation() }]
    }
    var problems: [String] = []
    do {
        let (hub, _, geometry) = externalNotch()
        hub.register(PlayingMusicTab())
        hub.stageForPreview(pill: true)
        problems += try sampleTransitions(name: "external", hub: hub, geometry: geometry, camera: nil, steps: steps(hub)).map { "external " + $0 }
    }
    do {
        // His exact case: music plus the AI-usage readout (the wide pill) going into dictation and back.
        let (hub, _, geometry) = externalNotch()
        hub.register(PlayingMusicTab())
        hub.pillAccessory = { AnyView(Text("Claude 42%").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)) }
        hub.stageForPreview(pill: true)
        problems += try sampleTransitions(name: "external-wide", hub: hub, geometry: geometry, camera: nil, steps: Array(steps(hub).prefix(5))).map { "external-wide " + $0 }
    }
    do {
        let (hub, _, geometry) = flowNotch()
        hub.register(PlayingMusicTab())
        let camera = CGRect(x: realNotch.left - geometry.open.minX + 1, y: 1, width: realNotch.right - realNotch.left - 2, height: geometry.notchHeight - 2)
        problems += try sampleTransitions(name: "m5", hub: hub, geometry: geometry, camera: camera, steps: steps(hub)).map { "m5 " + $0 }
    }
    do {
        // Nothing playing: dictation grows out of the bare notch and every outcome shrinks back into it.
        let (hub, _, geometry) = flowNotch()
        let camera = CGRect(x: realNotch.left - geometry.open.minX + 1, y: 1, width: realNotch.right - realNotch.left - 2, height: geometry.notchHeight - 2)
        let quiet = [FlowStep(name: "dictation", feedbackWithin: 150) { hub.presentDictation(NotchDictation(target: "Notes", level: 0.5)) },
                     FlowStep(name: "finishing", sweeps: true) { hub.presentDictation(NotchDictation(target: "Notes", transcribing: true)) },
                     FlowStep(name: "attention") { hub.endDictation(result: "Copied · paste it yourself", ok: false) },
                     FlowStep(name: "back") { hub.expireResult() },
                     FlowStep(name: "again", feedbackWithin: 150) { hub.presentDictation(NotchDictation(target: "Notes", level: 0.3)) },
                     FlowStep(name: "result") { hub.endDictation(result: "Inserted", ok: true) },
                     FlowStep(name: "rest") { hub.expireResult() },
                     FlowStep(name: "prompt") { hub.presentDictation(NotchDictation(target: "Claude Code", level: 0.3, prompt: "Which branch should I deploy to staging?")) },
                     FlowStep(name: "cancelled") { hub.endDictation() }]
        problems += try sampleTransitions(name: "m5-quiet", hub: hub, geometry: geometry, camera: camera, steps: quiet).map { "m5-quiet " + $0 }
    }
    #expect(problems.isEmpty, "\(problems.count) problems: \(problems.prefix(16).joined(separator: "; "))")
}

/// Replays pointer traces recorded while a person used the notch with a real trackpad (lines "<seconds> ptr <x>,<y> ...",
/// global display coordinates from the top left). Synthetic pointer events skip macOS's own stops at the notch's edges;
/// recorded ones carry them. Every place the pointer rested at the notch for 0.35 s or more must be inside the hover
/// target, so the hub opens there. `MOUTHY_TEST_POINTER_TRACE=<file>[:<file>...]`, on the Mac the traces were recorded on.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_POINTER_TRACE"] != nil))
func notchHoverReplaysRecordedPointerTraces() throws {
    let paths = ProcessInfo.processInfo.environment["MOUTHY_TEST_POINTER_TRACE"]!.split(separator: ":").map(String.init)
    let screen = try #require(NotchGeometry.notchedScreen())
    let primaryTop = try #require(NSScreen.screens.first).frame.maxY
    let target = NotchHub.homeHover(NotchGeometry.on(screen).closed)
    let notchLeft = try #require(screen.auxiliaryTopLeftArea).maxX, notchRight = try #require(screen.auxiliaryTopRightArea).minX
    var rests: [String] = [], missed: [String] = []
    for path in paths {
        var samples: [(t: Double, x: Double, y: Double)] = []
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[1] == "ptr", let t = Double(parts[0]) else { continue }
            let xy = parts[2].split(separator: ",")
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { continue }
            if let last = samples.last, last.x == x, last.y == y { continue }
            samples.append((t, x, y))
        }
        // The recorder writes a line only when something changes, so a rest is the time until the next sample.
        for (index, sample) in samples.enumerated() where index + 1 < samples.count {
            let rest = samples[index + 1].t - sample.t
            guard rest >= 0.35, sample.y >= 0, sample.y <= 34, sample.x >= notchLeft - 20, sample.x <= notchRight + 20 else { continue }
            let label = "\(URL(fileURLWithPath: path).lastPathComponent) +\(String(format: "%.2f", sample.t)) s at \(Int(sample.x)),\(Int(sample.y)) for \(String(format: "%.2f", rest)) s"
            rests.append(label)
            if !NSMouseInRect(NSPoint(x: sample.x, y: primaryTop - sample.y), target, false) { missed.append(label) }
        }
    }
    print("POINTER REPLAY \(rests.count) rests at the notch, \(rests.count - missed.count) inside the hover target")
    rests.forEach { print("  \(missed.contains($0) ? "OUTSIDE" : "inside ") \($0)") }
    #expect(!rests.isEmpty)
    #expect(missed.isEmpty, "\(missed)")
}
