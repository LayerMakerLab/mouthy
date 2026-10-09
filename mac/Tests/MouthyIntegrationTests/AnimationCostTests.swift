import AppKit
import SwiftUI
import Testing
@testable import MouthyKit
@testable import MouthyNotch

// MOUTHY_TEST_CPU=1 swift test --filter animationCost
// Gate: every animated notch element costs at most 1% CPU while it runs. Each element is hosted in a borderless
// window far off screen (never on a display, never key, no focus taken) at the hub window's size, ordered in so
// the display cycle runs, and the process CPU time (getrusage, all threads) is read before and after 10 s.

private func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// WindowServer's CPU seconds so far (`ps`; it runs as another user, so getrusage cannot read it), or nil.
private func windowServerCPUSeconds() -> Double? {
    func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let pid = run("/usr/bin/pgrep", ["-x", "WindowServer"])?.split(separator: "\n").first,
          let time = run("/bin/ps", ["-o", "cputime=", "-p", String(pid)]) else { return nil }
    // [[hh:]mm:]ss.cc
    return time.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
}

private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? { a.flatMap { a in b.map { (a, $0) } } }

@MainActor private final class TickProbe { var ticks = 0 }

/// Counts animation-schedule ticks, to prove the off-screen window really drives animations (else a 0% reading
/// would mean nothing).
private struct ProbeView: View {
    let probe: TickProbe
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let _ = { probe.ticks += 1 }()
            Color.black.frame(width: 2, height: 2).opacity(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) > 0.5 ? 1 : 0.9)
        }
    }
}

/// The hub window's size.
@MainActor private let hubWindowSize = CGSize(width: NotchGeometry.openSize.width + 2 * NotchGeometry.shadowMargin,
                                               height: NotchGeometry.openSize.height + NotchGeometry.shadowMargin)

/// CPU percent of one core while `view` runs for `seconds`, hosted at `size` (the hub window's by default).
/// WindowServer's CPU percent over the last `hostedCPUPercent` reading. Informational only: it includes whatever
/// else the Mac draws meanwhile, and a window off every display may not be composited at all.
@MainActor private var lastWindowServerPercent: Double?
@MainActor private final class MeasuredView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

@MainActor private func hostedCPUPercent(_ view: some View, seconds: TimeInterval, size: CGSize = hubWindowSize) -> Double {
    var observed: [MeasuredView] = []
    // NSApplication normally drains an autorelease pool after each event. This headless test pumps a nested
    // run loop: without its own pool, previous hosts survive and double-count the shared model's level updates.
    let percent = autoreleasepool {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.contentView = host
        window.orderFrontRegardless()
        @MainActor func remember(_ view: NSView) {
            if view === host || view is WaveformLayerView || view is LevelGlowView { observed.append(MeasuredView(view)) }
            view.subviews.forEach(remember)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        remember(host)
        let serverBefore = windowServerCPUSeconds()
        let before = processCPUSeconds(), started = Date()
        RunLoop.main.run(until: started.addingTimeInterval(seconds))
        let used = processCPUSeconds() - before
        let wall = Date().timeIntervalSince(started)
        lastWindowServerPercent = zip2(serverBefore, windowServerCPUSeconds()).map { ($1 - $0) / wall * 100 }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        return used / wall * 100
    }
    let retained = observed.filter { $0.view != nil }.count
    print("CPU view teardown: \(observed.count) observed, \(retained) retained")
    #expect(retained == 0, "a closed benchmark host and its live layer views must release before the next case")
    return percent
}

/// True when Core Animation really moves `layers` (sampled 0.23 s apart on screen time), so a 0% reading means
/// "free", not "frozen". With MOUTHY_RENDER_DIR set, each sample's on-screen (presentation) frame is saved at 8x.
@MainActor private func moves(_ view: NSView, name: String, layers: () -> [CALayer], value: (CALayer) -> CGFloat) throws -> Bool {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: view.frame.width, height: view.frame.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .black
    window.contentView = view
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    var samples: [[CGFloat]] = []
    for index in 0..<2 {
        RunLoop.main.run(until: Date().addingTimeInterval(index == 0 ? 0.5 : 0.23))
        samples.append(layers().map { $0.presentation().map(value) ?? -1 })
        if let folder = ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"], let shown = view.layer?.presentation() {
            let scale = 8, size = view.bounds.size
            let context = try #require(CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(.black); context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            shown.render(in: context)
            let image = try #require(context.makeImage())
            let url = URL(fileURLWithPath: folder).appendingPathComponent("motion-\(name)-\(index).png")
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
            assertNoBlue(url)
        }
    }
    return !samples[0].contains(-1) && samples[0] != samples[1]
}

/// Sends a new voice level every 80 ms, the rate AppModel sends `level` while dictating, so the real update
/// cost is part of the reading. The level goes to `feed` (as AppModel's does) and to `forward`.
@MainActor private final class LevelDriver {
    var level: Float = 0.3
    let feed = VoiceLevelFeed()
    private var timer: Timer?
    private var step = 0
    /// Also receives each level (the hub gets its level through presentDictation, as NotchDictationBridge does).
    var forward: ((Float) -> Void)?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.step += 1
                self.level = Float(0.2 + 0.6 * abs(sin(Double(self.step) * 0.7)))
                self.feed.send(self.level)
                self.forward?(self.level)
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}


@MainActor private final class EarsTab: NotchTab {
    let id = "cost.music"
    let title = "Music"
    let symbolName = "music.note"
    func makeBody() -> AnyView { AnyView(Text("Body")) }
    func compactBody() -> AnyView? { AnyView(EqualizerBars(playing: true, tint: MouthyTheme.glow)) }
    var compactPriority: Int { 10 }
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_CPU"] == "1"))
func animationCostOfEveryAnimatedNotchElement() throws {
    let probe = TickProbe()
    _ = hostedCPUPercent(ProbeView(probe: probe), seconds: 3)
    print("CPU probe: \(probe.ticks) animation ticks in 3 s off screen")
    try #require(probe.ticks >= 30, "the off-screen window did not drive animations, so the readings below would be meaningless")

    let geometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 944),
                                    notchLeft: 655, notchRight: 857, safeTop: 38)
    let hub = NotchHub()
    hub.register(EarsTab())
    let driver = LevelDriver()
    let dictating = NotchHub()
    dictating.register(EarsTab())
    // The open Music panel while a track plays, synced lyrics showing; the Timers panel with the stopwatch running.
    let panels = NotchHub()
    MouthyTabs.registerAll(in: panels)
    MusicTab.shared.lyricsEnabled = false
    MusicTab.shared.update(["Name": "Northern Lights", "Artist": "Mouthy Radio", "Player State": "Playing", "Duration": 180000, "Playback Position": 20.0], player: "Music")
    MusicTab.shared.showLyricsForPreview((0..<60).map { MusicTab.LyricLine(time: Double($0) * 2.5, text: "Line \($0) of the song") })
    panels.stageForPreview(open: true)
    // The closed band showing a running timer's ring and clock (the timer is the only tab, so its ears show).
    let timerHub = NotchHub()
    timerHub.register(TimersTab.shared)
    // The main window on Dictate while listening.
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-cpu-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let model = AppModel(store: LocalStore(directory: support), enablesHotkey: false)
    model.selectedPage = "Dictate"
    let elements: [(String, AnyView)] = [
        ("baseline (empty black window)", AnyView(Color.black)),
        ("music ears alone (EqualizerBars playing)", AnyView(EqualizerBars(playing: true, tint: MouthyTheme.glow).frame(width: 40, height: 32))),
        ("whole hub with playing music ears", AnyView(NotchRootView(hub: hub, geometryOverride: geometry))),
        ("dictation waveform (MouthyWaveform active)", AnyView(MouthyWaveform(level: 0.5, active: true, bars: 9, height: 16, barWidth: 2.5))),
        ("finishing sweep (MouthyWaveform sweep)", AnyView(MouthyWaveform(level: 0, active: false, bars: 9, height: 16, barWidth: 2.5, sweep: true))),
        ("dictation waveform, level changing every 80 ms", AnyView(MouthyWaveform(level: 0, active: true, bars: 9, height: 16, barWidth: 2.5, feed: driver.feed))),
        ("main window waveform (21 bars, sweep)", AnyView(MouthyWaveform(level: 0, active: false, sweep: true))),
        ("music panel ears (5 bars)", AnyView(EqualizerBars(playing: true, tint: MouthyTheme.glow, bars: 5, height: 18))),
        ("mic button listening (MicButton)", AnyView(MicButton(listening: true))),
        ("indeterminate progress (file transcribing)", AnyView(ProgressView().progressViewStyle(MouthyBarProgressStyle()).frame(width: 320))),
        ("loading skeleton (notch tab)", AnyView(Text("Loading the weather for Lisbon").notchSkeleton(loading: true))),
        ("whole hub dictating over music, level every 80 ms", AnyView(NotchRootView(hub: dictating, geometryOverride: geometry))),
        ("active mode ring (Modes page while dictating)", AnyView(ActiveGlowRing().frame(width: 220, height: 120))),
        ("music panel open, playing with synced lyrics", AnyView(NotchRootView(hub: panels, geometryOverride: geometry))),
        ("timers panel, stopwatch running", AnyView(NotchRootView(hub: panels, geometryOverride: geometry))),
        ("closed hub, focus timer ears", AnyView(NotchRootView(hub: timerHub, geometryOverride: geometry))),
        ("closed hub, 1-minute timer ears", AnyView(NotchRootView(hub: timerHub, geometryOverride: geometry))),
        ("timers panel, focus running", AnyView(NotchRootView(hub: panels, geometryOverride: geometry))),
        ("main window Dictate page listening, level every 80 ms", AnyView(WorkspaceView(model: model))),
        ("main window Dictate page listening, level and clock", AnyView(WorkspaceView(model: model))),
    ]
    var over: [String] = []
    // MOUTHY_CPU_ONLY=<substring> measures only the matching elements.
    let only = ProcessInfo.processInfo.environment["MOUTHY_CPU_ONLY"]
    for (name, view) in elements where only.map({ name.contains($0) }) ?? true {
        if name.hasPrefix("dictation waveform, level") { driver.start() }
        if name.hasPrefix("whole hub dictating") {
            dictating.presentDictation(NotchDictation(target: "Notes", level: 0.3))
            driver.forward = { dictating.presentDictation(NotchDictation(target: "Notes", level: $0)) }
            driver.start()
        }
        if name.hasPrefix("music panel") { panels.selectedID = MusicTab.shared.id }
        if name.hasPrefix("timers panel") { panels.selectedID = TimersTab.shared.id }
        if name == "timers panel, stopwatch running", TimersTab.shared.stopwatchStart == nil { TimersTab.shared.toggleStopwatch() }
        if name.hasSuffix("focus timer ears") || name.hasSuffix("focus running") { TimersTab.shared.start(.focus) }
        if name.hasSuffix("1-minute timer ears") {
            TimersTab.shared.countdownMinutes = 1
            TimersTab.shared.start(.countdown)
        }
        if name.hasPrefix("main window") {
            model.phase = .listening
            let started = Date()
            driver.forward = {
                model.level = $0
                let elapsed = floor(Date().timeIntervalSince(started))
                if name.hasSuffix("level and clock"), floor(model.elapsed) != elapsed { model.elapsed = elapsed }
            }
            driver.start()
        }
        defer {
            driver.stop(); driver.forward = nil
            if name.hasPrefix("timers panel") { TimersTab.shared.resetStopwatch() }
            if name.contains("timer ears") || name.hasSuffix("focus running") { TimersTab.shared.stop() }
        }
        let percent = hostedCPUPercent(view, seconds: 10, size: name.hasPrefix("main window") ? CGSize(width: 1080, height: 760) : hubWindowSize)
        print(String(format: "CPU %@: %.2f%% (WindowServer %@)", name, percent,
                     lastWindowServerPercent.map { String(format: "%.1f%%", $0) } ?? "unread"))
        if percent > 1.0 { over.append(name) }
    }
    #expect(over.isEmpty, "over 1% CPU: \(over.joined(separator: ", "))")
}

/// The near-zero readings above are Core Animation running in the render server, not motion that stopped.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_CPU"] == "1"))
func animationCostMotionStillRuns() throws {
    let ears = EqualizerLayerView(frame: NSRect(x: 0, y: 0, width: 20, height: 18))
    ears.apply(bars: 4, height: 18, tint: NSColor(MouthyTheme.glow).cgColor, playing: true, still: false)
    #expect(try moves(ears, name: "ears", layers: { ears.layer?.sublayers ?? [] }, value: { $0.bounds.height }), "the music ears must dance")
    for (name, active, sweep) in [("waveform-live", true, false), ("waveform-sweep", false, true)] {
        let bars = WaveformLayerView(frame: NSRect(x: 0, y: 0, width: 50, height: 16))
        bars.layout()
        // Live bars move only with the voice: a level feed changing every 80 ms drives them.
        let driver = LevelDriver()
        bars.apply(level: 0.5, active: active, sweep: sweep, bars: 9, barWidth: 2.5, still: false, feed: active ? driver.feed : nil)
        if active { driver.start() }
        defer { driver.stop() }
        let layers = { bars.layer?.sublayers?.first?.mask?.sublayers ?? [] }
        #expect(try moves(bars, name: name, layers: layers, value: { $0.bounds.height * $0.transform.m22 }), "\(name) must move")
    }
    let rings = PulseRingsView(frame: NSRect(x: 0, y: 0, width: 70, height: 70))
    rings.start(color: NSColor(MouthyTheme.glow).cgColor)
    #expect(try moves(rings, name: "orb-rings", layers: { rings.layer?.sublayers ?? [] }, value: { CGFloat($0.opacity) }), "the orb rings must pulse")
    let ring = TimerRingLayerView(frame: NSRect(x: 0, y: 0, width: 84, height: 84))
    ring.apply(ends: Date().addingTimeInterval(45), length: 60, lineWidth: 7, tint: NSColor(MouthyTheme.orange).cgColor)
    #expect(try moves(ring, name: "timer-ring", layers: { [ring.layer!.sublayers![1].sublayers![0].mask!] },
                      value: { ($0 as? CAShapeLayer)?.strokeEnd ?? -1 }), "the timer ring must fill")
    // The same ring half full inside SwiftUI (a flipped host, as in the hub): the arc runs clockwise from 12
    // o'clock to 6 o'clock with its bright end at the head.
    if let url = try renderOffscreen(TimerRingLayers(ends: Date().addingTimeInterval(30), length: 60).frame(width: 84, height: 84).padding(8),
                                     size: CGSize(width: 100, height: 100), name: "timer-ring-half-hosted") {
        assertNoBlue(url)
        let image = try #require(NSImage(contentsOf: url).flatMap { NSBitmapImageRep(data: $0.tiffRepresentation!) })
        func brightness(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let color = image.colorAt(x: Int(x / 100 * CGFloat(image.pixelsWide)), y: Int(y / 100 * CGFloat(image.pixelsHigh)))
            return color.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) * $0.alphaComponent } ?? 0
        }
        // Points on the ring (centre 50,50, radius 38.5, image y down): right side lit, left side not; the head
        // near 6 o'clock brighter than the tail just past 12.
        #expect(brightness(88.5, 50) > brightness(11.5, 50) + 0.3, "the arc runs clockwise from the top")
        #expect(brightness(54, 88) > brightness(57, 13) + 0.2, "the gradient's bright end is the head")
    }
    let slider = SlidingSegmentView(frame: NSRect(x: 0, y: 0, width: 200, height: 5))
    slider.apply(still: false)
    #expect(try moves(slider, name: "progress", layers: { slider.layer?.sublayers ?? [] }, value: { $0.position.x }), "the progress segment must slide")
}
