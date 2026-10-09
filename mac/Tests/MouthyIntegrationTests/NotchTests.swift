import AppKit
import SwiftUI
import Testing
@testable import MouthyKit
@testable import MouthyNotch

@MainActor @Test func levelTicksRedrawOnlyTheMeterNotTheHub() {
    let hub = NotchHub()
    var hubChanges = 0
    let watch = hub.objectWillChange.sink { hubChanges += 1 }
    defer { watch.cancel() }
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.2))
    let afterStart = hubChanges
    #expect(afterStart > 0 && hub.voice.level == 0.2)
    for level: Float in [0.3, 0.5, 0.7, 0.9] { hub.presentDictation(NotchDictation(target: "Notes", level: level)) }
    #expect(hubChanges == afterStart, "a level tick must not re-render the whole hub")
    #expect(abs(hub.voice.level - 0.9) < 0.001 && abs((hub.dictation?.level ?? 0) - 0.9) < 0.001)
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.5, partialText: "hello"))
    #expect(hubChanges > afterStart, "new words re-render the hub")
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.5, partialText: "hello", transcribing: true))
    #expect(hub.voice.level == 0, "finishing rests the meter")
    hub.endDictation()
    #expect(hub.voice.level == 0 && hub.dictation == nil)
}

@Test func notchGeometryCoversTheHardwareNotchAndStaysOnScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
    let notched = NotchGeometry.on(screen: screen, visible: visible, notchLeft: 655, notchRight: 857, safeTop: 38)
    #expect(notched.notchWidth == 202 && notched.notchHeight == 38)
    #expect(notched.closed.minX < 655 && notched.closed.maxX > 857 && notched.closed.maxY == screen.maxY)
    let margin = NotchGeometry.shadowMargin
    #expect(notched.open.width == NotchGeometry.openSize.width + 2 * margin && notched.open.maxY == screen.maxY)
    #expect(notched.open.height == NotchGeometry.openSize.height + margin)
    #expect(abs(notched.open.midX - 756) < 0.5)

    let external = NotchGeometry.on(screen: NSRect(x: 1512, y: 0, width: 1920, height: 1080),
                                    visible: NSRect(x: 1512, y: 0, width: 1920, height: 1055), notchLeft: nil, notchRight: nil, safeTop: 0)
    #expect(external.notchWidth == 0 && external.notchHeight == 25)
    #expect(external.open.minX + NotchGeometry.shadowMargin >= 1512 + 16 && external.open.maxX - NotchGeometry.shadowMargin <= 1512 + 1920 - 16)
}

@Test(arguments: [
    (NSRect(x: 0, y: 0, width: 1512, height: 982), CGFloat(32), CGFloat(656), CGFloat(856)),   // 14-inch
    (NSRect(x: 0, y: 0, width: 1728, height: 1117), CGFloat(38), CGFloat(764), CGFloat(964)),  // 16-inch
    (NSRect(x: 0, y: 0, width: 1512, height: 982), CGFloat(32), CGFloat(663.5), CGFloat(848.5)), // 185 pt notch
])
func notchBandAndHoverTargetAgreeOnEveryNotch(screen: NSRect, safeTop: CGFloat, left: CGFloat, right: CGFloat) {
    let visible = NSRect(x: 0, y: 0, width: screen.width, height: screen.height - safeTop)
    let geometry = NotchGeometry.on(screen: screen, visible: visible, notchLeft: left, notchRight: right, safeTop: safeTop)
    let notch = right - left
    #expect(geometry.closed.height == safeTop && geometry.closedWide.height == safeTop)
    #expect(geometry.closedWide.width == notch + 2 * NotchGeometry.compactSide)
    #expect(geometry.closedWide.width == notch + 92)
    #expect(geometry.cameraWidth == notch)
    #expect(abs(geometry.closedWide.midX - (left + right) / 2) < 0.01 && abs(geometry.closed.midX - geometry.closedWide.midX) < 0.01)
}

@Test func externalPillAndHubBandShareTheMenuBarHeight() {
    for menuBar in [CGFloat(0), 24, 25, 30, 37, 44] {
        let screen = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let visible = NSRect(x: 1512, y: 0, width: 1920, height: 1080 - menuBar)
        let hub = NotchGeometry.on(screen: screen, visible: visible, notchLeft: nil, notchRight: nil, safeTop: 0)
        // The pill is the hub's own band at rest: same height and width, so dictation never changes its size.
        #expect(hub.pill().height == hub.notchHeight && hub.pill().width == hub.closedWide.width, "menu bar \(menuBar)")
        #expect(hub.pill(wide: true).width == NotchGeometry.widePillWidth)
        #expect(hub.notchHeight == NotchGeometry.menuBarHeight(screen: screen, visible: visible))
    }
}

@Test func compactRailDotsOnlyLiveBadges() {
    #expect(!NotchBadge(count: 3).isLive, "a plain count waits for the tab")
    #expect(NotchBadge(count: 0, tone: .active).isLive)
    #expect(NotchBadge(count: 2, tone: .attention).isLive)
}

@MainActor final class SampleTab: NotchTab {
    let id: String
    var title = "Sample"
    var symbolName = "star"
    var prefersAttention = false
    var badge: NotchBadge?
    init(id: String, title: String = "Sample", symbolName: String = "star", badge: NotchBadge? = NotchBadge(count: 2, tone: .attention)) {
        self.id = id; self.title = title; self.symbolName = symbolName; self.badge = badge
    }
    func makeBody() -> AnyView { AnyView(Text("Body")) }
}

@MainActor @Test func notchHubRegistersSelectsAndFollowsAttention() {
    let hub = NotchHub.shared
    let first = SampleTab(id: "test.first"), second = SampleTab(id: "test.second")
    hub.register(first); hub.register(second)
    defer { hub.unregister(id: first.id); hub.unregister(id: second.id) }
    #expect(hub.tabIDs.suffix(2) == ["test.first", "test.second"])
    let before = hub.revision
    hub.tabDidChange(id: second.id)
    #expect(hub.revision != before)
    // Without a running panel, attention selects but cannot open anything on screen.
    second.prefersAttention = true
    hub.tabDidChange(id: second.id)
    #expect(hub.selectedID == second.id && !hub.isOpen)
    hub.unregister(id: second.id)
    #expect(hub.selectedID != second.id)
}

@MainActor @Test func notchStateSizesFollowTheSpec() {
    let nh: CGFloat = 38
    let rest = CGSize(width: 202, height: nh)
    let panel = CGSize(width: 600, height: 296)
    func size(_ stage: NotchStage, measured: CGSize = .zero) -> CGSize {
        NotchMetrics.size(for: stage, notchHeight: nh, rest: rest, compactWidth: 306, panel: panel, measured: measured)
    }
    #expect(size(.rest) == rest)
    #expect(size(.compact) == CGSize(width: 306, height: nh))
    #expect(size(.open) == CGSize(width: 600 + 2 * MorphingNotch.openShoulder, height: 296))
    #expect(size(.dictation(prompt: false)) == CGSize(width: 420, height: nh + 46))
    #expect(size(.dictation(prompt: true)) == CGSize(width: 460, height: nh + 70))
    #expect(size(.result) == CGSize(width: 340, height: nh + 30))
    // Live content larger than the stage's size wins, so nothing is cut off.
    #expect(size(.dictation(prompt: false), measured: CGSize(width: 436, height: 120)) == CGSize(width: 436, height: 120))
    #expect(size(.peek).width == NotchMetrics.peekWidth)
    #expect(NotchMetrics.shoulder(for: .rest) == 0 && NotchMetrics.shoulder(for: .open) == MorphingNotch.openShoulder)
}

@MainActor @Test func hoverTargetFollowsALeftOnlyPeek() {
    let hub = NotchHub()
    let geometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 944),
                                    notchLeft: 656, notchRight: 856, safeTop: 32)
    #expect(hub.trackerFrame(on: geometry) == geometry.closed)
    // A title too long for the right ear: the band grows left only, and so does the hover target.
    hub.stageForPreview(peek: AnyView(Text("Peek")), title: "A very long track title")
    #expect(hub.peekGrowsLeftOnly)
    let left = hub.trackerFrame(on: geometry)
    #expect(left.minX == 656 - NotchGeometry.compactSide && left.maxX == geometry.closed.maxX && left.maxX < geometry.closedWide.maxX)
    #expect(left.height == 32 && left.maxY == 982)
    // Hovered, the peek grows into its card, so the whole band answers the pointer again.
    hub.hover(true)
    #expect(!hub.peekGrowsLeftOnly && hub.trackerFrame(on: geometry) == geometry.closedWide)
    hub.hover(false)
    // A title that fits the 40 pt ear keeps both ears and the full band; a longer one never shows cut.
    hub.stageForPreview(peek: AnyView(Text("Peek")), title: "Done")
    #expect(!hub.peekGrowsLeftOnly && hub.trackerFrame(on: geometry) == geometry.closedWide)
    #expect(!MorphingNotch.titleFits("Charging"))
}

@MainActor @Test func notchStagePriorityIsDictationThenOpenThenPeekThenResult() {
    let hub = NotchHub()
    let geometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 944),
                                    notchLeft: 655, notchRight: 857, safeTop: 38)
    let notch = MorphingNotch(hub: hub, geometry: geometry, panel: NotchGeometry.openSize)
    #expect(notch.stage == .rest)
    hub.presentResult("Inserted · Notes", ok: true)
    #expect(notch.stage == .result)
    hub.stageForPreview(peek: AnyView(Text("Peek")), title: "Peek")
    #expect(notch.stage == .peek)
    #expect(notch.inBand(.peek))
    hub.presentDictation(NotchDictation(target: "Notes", level: 0.4))
    #expect(notch.stage == .dictation(prompt: false) && hub.result == nil)
    // Dictation stays in the band, hovered or not; an agent's question grows the band down, never wider.
    #expect(notch.inBand(notch.stage))
    let plain = notch.shapeSize(for: notch.stage)
    hub.hover(true)
    #expect(!hub.liveExpanded && notch.inBand(notch.stage) && notch.shapeSize(for: notch.stage) == plain)
    hub.hover(false)
    hub.presentDictation(NotchDictation(target: "Claude", prompt: "Which branch?"))
    #expect(notch.stage == .dictation(prompt: true))
    #expect(notch.inBand(notch.stage))
    let asked = notch.shapeSize(for: notch.stage)
    #expect(asked.width == plain.width && asked.height > plain.height)
    // Dictation is the one surface while it runs, even over a panel opened behind it.
    hub.stageForPreview(open: true)
    #expect(notch.stage == .dictation(prompt: true))
    hub.stageForPreview(open: false)
    hub.endDictation()
    #expect(notch.stage == .rest && hub.dictation == nil)
    hub.stageForPreview(open: true)
    #expect(notch.stage == .open)
}

@MainActor @Test func tabSelectionMovesTheSameWayForClicksDigitsAndAdjacentSteps() throws {
    let hub = NotchHub()
    ["a", "b", "c"].forEach { hub.register(SampleTab(id: "pick.\($0)")) }
    #expect(hub.selectedID == "pick.a")
    hub.select("pick.c")
    #expect(hub.selectedID == "pick.c" && hub.selectionDirection == 1)
    hub.select("pick.b")
    #expect(hub.selectedID == "pick.b" && hub.selectionDirection == -1)
    hub.select("missing")
    #expect(hub.selectedID == "pick.b")
    hub.selectAdjacent(1)
    #expect(hub.selectedID == "pick.c" && hub.selectionDirection == 1)
    // ⌘1…9 only while open.
    let commandTwo = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                                    context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
    #expect(!hub.handleCommandDigit(commandTwo))
    hub.stageForPreview(open: true)
    #expect(hub.handleCommandDigit(commandTwo))
    #expect(hub.selectedID == "pick.b" && hub.selectionDirection == -1)
}

@MainActor @Test func resultLineDismissesAfterOneAndAHalfSeconds() async throws {
    #expect(NotchHub.resultDuration == .seconds(1.5))
    let hub = NotchHub()
    let presented = ContinuousClock.now
    hub.presentResult("Copied", ok: true)
    #expect(hub.result?.text == "Copied")
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while hub.result != nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(hub.result == nil)
    #expect(presented.duration(to: .now) >= NotchHub.resultDuration, "the result must remain for its full reading time")
}

@MainActor @Test func notchPaletteIsWarmAndNeverBlue() {
    let roles: [Color] = [NotchPalette.shine, NotchPalette.silver, NotchPalette.graphite, NotchPalette.ember]
    for color in roles {
        let hex = MouthyTheme.hexValue(color) ?? 0
        let r = UInt8((hex >> 16) & 0xFF), g = UInt8((hex >> 8) & 0xFF), b = UInt8(hex & 0xFF)
        #expect(!isBlue(r: r, g: g, b: b))
        #expect(r >= b, "notch roles are warm: red leads blue")
    }
    #expect(MouthyTheme.hexValue(NotchPalette.shine) == 0xFFD27A)
    #expect(MouthyTheme.hexValue(NotchPalette.silver) == 0xFFB547)
    #expect(MouthyTheme.hexValue(NotchPalette.graphite) == 0xCBB08C)
}

// MARK: Renders

/// A tab with live content beside the closed notch (a running timer).
@MainActor final class CompactSampleTab: NotchTab {
    let id = "render.compact"
    let title = "Timers"
    let symbolName = "timer"
    func makeBody() -> AnyView { AnyView(Text("Timers")) }
    func compactBody() -> AnyView? { AnyView(Text("12:34").foregroundStyle(MouthyTheme.cream)) }
    var compactCaption: String? { "Focus" }
}

/// A notched 14-inch MacBook Pro display for renders.
@MainActor private let renderGeometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1512, height: 982),
                                                         visible: NSRect(x: 0, y: 0, width: 1512, height: 944),
                                                         notchLeft: 656, notchRight: 856, safeTop: 38)
@MainActor private var renderWindowSize: CGSize { renderGeometry.open.size }

/// A light menu-bar strip behind the notch, so a stray hairline or clipped edge would show.
private struct RenderBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.66), Color(white: 0.48)], startPoint: .top, endPoint: .bottom)
    }
}

/// How far the black notch shape reaches down a render, in pixels: the last row that is mostly near-black.
/// Text inside the shape leaves most of a row black, and the grey backdrop never is.
private func notchHeight(in url: URL) throws -> Int {
    guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw RenderError.unreadable(url)
    }
    let width = cg.width, height = cg.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    var last = 0
    for y in 0..<height {
        var dark = 0
        for x in 0..<width {
            let i = (y * width + x) * 4
            if data[i] < 40 && data[i + 1] < 40 && data[i + 2] < 40 { dark += 1 }
        }
        if dark * 100 > width * 15 { last = y + 1 }
    }
    return last
}

private enum RenderError: Error { case unreadable(URL) }

/// MOUTHY_RENDER_DIR=/some/folder saves PNGs of the hub in every state for a visual check.
@MainActor @Test func notchRendersForVisualReview() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
    Mascot.install()
    let hub = NotchHub()
    hub.headerLeading = { AnyView(Text("Mon Oct 5").foregroundStyle(MouthyTheme.cream)) }
    hub.headerTrailing = { AnyView(Text("82%").foregroundStyle(MouthyTheme.cream2)) }
    // Real badges: a running timer (dot), open todos and clipboard items (counts, no dot beside the camera).
    let tabs = [SampleTab(id: "render.sample", title: "Mouthy", symbolName: "waveform", badge: nil),
                SampleTab(id: "render.timers", title: "Timers", symbolName: "timer", badge: NotchBadge(count: 0, tone: .active)),
                SampleTab(id: "render.notes", title: "Todos & notes", symbolName: "checklist", badge: NotchBadge(count: 3)),
                SampleTab(id: "render.music", title: "Music", symbolName: "music.note", badge: nil),
                SampleTab(id: "render.clip", title: "Clipboard", symbolName: "doc.on.clipboard", badge: NotchBadge(count: 5))]
    tabs.forEach(hub.register)
    hub.selectedID = "render.sample"
    @discardableResult
    func stage(_ name: String, settle: TimeInterval = 1.2, _ configure: () -> Void) throws -> URL? {
        hub.stageForPreview(open: false); hub.endDictation()
        configure()
        let view = ZStack(alignment: .top) { RenderBackdrop(); NotchRootView(hub: hub, geometryOverride: renderGeometry).environment(\.notchFlatGlass, true) }
        let url = try renderOffscreen(view, size: renderWindowSize, name: "notch-\(name)", settle: settle)
        if let url { assertNoBlue(url) }
        return url
    }
    try stage("open") { hub.stageForPreview(open: true) }
    try stage("open-other-tab") { hub.stageForPreview(open: true); hub.selectedID = "render.notes" }
    hub.selectedID = "render.sample"
    let plain = try stage("dictation") { hub.presentDictation(NotchDictation(target: "Notes", level: 0.7, partialText: "run the tests and fix whatever fails", startedAt: Date().addingTimeInterval(-7))) }
    let prompted = try stage("dictation-prompt") { hub.presentDictation(NotchDictation(target: "Claude Code", level: 0.5, partialText: "the main branch", prompt: "Which branch should I rebase onto?")) }
    // The question shows in the closed notch: the prompted pill is taller than the band the plain one keeps.
    if let plain, let prompted {
        let plainHeight = try notchHeight(in: plain), promptedHeight = try notchHeight(in: prompted)
        #expect(promptedHeight > plainHeight + 20, "prompt \(promptedHeight) px vs plain \(plainHeight) px")
    }
    try stage("transcribing") { hub.presentDictation(NotchDictation(target: "Notes", partialText: "run the tests", transcribing: true, startedAt: Date().addingTimeInterval(-9))) }
    try stage("result") { hub.presentResult("Inserted · Notes", ok: true) }
    try stage("attention") { hub.presentResult("Needs Accessibility", ok: false) }
    // The ears the real callers pass, then a title-only peek whose title fits and one whose title does not.
    try stage("peek-timer") {
        let ears = TimersTab.doneEars
        hub.stageForPreview(peek: AnyView(TimerDonePeek(kind: .focus, streak: 3)), title: "Focus done", leading: ears.leading, trailing: ears.trailing)
    }
    try stage("peek-power") {
        let ears = PowerEvents.ears(onPower: true, percent: 82)
        hub.stageForPreview(peek: AnyView(PowerPeek(charging: true, percent: 82)), title: "Charging", leading: ears.leading, trailing: ears.trailing)
    }
    try stage("peek-title") { hub.stageForPreview(peek: AnyView(Text("Peek")), title: "Charging") }
    try stage("peek-long-title") { hub.stageForPreview(peek: AnyView(Text("Peek")), title: "A very long track title") }
    let compact = CompactSampleTab()
    hub.register(compact)
    try stage("compact") {}
    // The pill on a display without a notch: notch-shaped, menu-bar high, live content.
    let external = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1920, height: 1080), visible: NSRect(x: 0, y: 0, width: 1920, height: 1050),
                                    notchLeft: nil, notchRight: nil, safeTop: 0)
    hub.stageForPreview(pill: true)
    let pill = ZStack(alignment: .top) { RenderBackdrop(); NotchRootView(hub: hub, geometryOverride: external) }
    if let url = try renderOffscreen(pill, size: external.open.size, name: "notch-external-pill", settle: 1.6) { assertNoBlue(url) }
    hub.stageForPreview(pill: false)
    hub.unregister(id: compact.id)
    try stage("rest") {}
}

/// Regression: opening must give the panel its open frame, not the closed strip.
@MainActor @Test func openingUsesTheOpenFrame() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_TEST_NOTCH_WINDOW"] == "1" else { return }
    let hub = NotchHub.shared
    let tab = SampleTab(id: "frame.check"); hub.register(tab); defer { hub.unregister(id: tab.id); hub.stop() }
    hub.start()
    hub.show(tabID: tab.id)
    let window = try #require(NSApp.windows.first { $0.accessibilityLabel() == "Mouthy notch" })
    #expect(window.frame.height == NotchGeometry.openSize.height + NotchGeometry.shadowMargin)
}

/// Always on: the dictation pill (plain and with an agent's question) and the result pill render at their
/// contract sizes, so a broken pill fails the default suite rather than only the gated renders.
@MainActor @Test func notchPillsRenderOffscreen() {
    let pill = DictationPill(dictation: NotchDictation(target: "Atlas", level: 0.6, partialText: "fix the build"), notchWidth: 200, notchHeight: 38)
    let image = ImageRenderer(content: pill).nsImage
    #expect(image != nil && image!.size.width >= 400)
    let asked = DictationPill(dictation: NotchDictation(target: "Claude Code", level: 0.4, prompt: "Which branch?"), notchWidth: 200, notchHeight: 38)
    let askedImage = ImageRenderer(content: asked).nsImage
    #expect(askedImage != nil && askedImage!.size.width >= image!.size.width && askedImage!.size.height > image!.size.height)
    let result = ImageRenderer(content: ResultPill(text: "Sent to Atlas", ok: true, notchWidth: 200, notchHeight: 38)).nsImage
    #expect(result != nil && result!.size.width >= 300)
}
