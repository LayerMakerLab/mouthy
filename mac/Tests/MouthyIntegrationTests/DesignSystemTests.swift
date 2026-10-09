import AppKit
import SwiftUI
import Testing
@testable import MouthyKit
@testable import MouthyNotch

@Test func themeTokensAreNeverBlue() {
    for token in MouthyTheme.tokens {
        let (h, _, _) = hsb(r: Double((token.hex >> 16) & 0xFF) / 255, g: Double((token.hex >> 8) & 0xFF) / 255, b: Double(token.hex & 0xFF) / 255)
        #expect(!(190...260).contains(h), "\(token.name) has hue \(h)")
    }
}

@Test func themeHexValuesRoundTrip() {
    for token in MouthyTheme.tokens {
        #expect(MouthyTheme.hexValue(Color(hex: token.hex)) == token.hex, "\(token.name)")
    }
    #expect(MouthyTheme.hexValue(MouthyTheme.orange) == 0xE08A2E)
    #expect(MouthyTheme.hexValue(Palette.background) == 0x140C07)
    #expect(MouthyTheme.hexValue(Palette.ink) == 0xF6E3C1)
}

@Test func motionResolvesToAShortEaseWithReduceMotion() {
    #expect(MouthyMotion.resolve(MouthyMotion.page, reduceMotion: true) == MouthyMotion.reduced)
    #expect(MouthyMotion.resolve(MouthyMotion.page, reduceMotion: false) == MouthyMotion.page)
}

@MainActor @Test func mascotFindsEveryPoseAndToleratesMissingArt() {
    #expect(Mascot.resourceRoot != nil)
    for pose in MascotPose.allCases {
        let image = Mascot.image(pose)
        #expect(image != nil, "missing pose \(pose.rawValue)")
        #expect(Mascot.hornAnchors[pose]?.count == 2)
    }
    #expect(Mascot.resourceURL("Mascot/heads/does-not-exist.png") == nil)
    // Heads may not ship yet; asking must not crash, and glyphs fall back to SF Symbols.
    _ = Mascot.head(.listen)
    let menu = Mascot.menuBarImage(listening: true)
    #expect(menu.isTemplate)
    Mascot.install()
    #expect(NotchArt.mascot != nil)
    for pose in MascotPose.allCases { #expect(Mascot.glyphImage(pose) != nil, "no glyph for \(pose.rawValue)") }
    NotchArt.mascot = nil
}

@MainActor @Test func waveformDoesNotTickWhileInactive() {
    #expect(MouthyWaveform(level: 0.9, active: false).paused)
    #expect(!MouthyWaveform(level: 0.9, active: true).paused)
    #expect(!MouthyWaveform(level: 0, active: false, sweep: true).paused)
    // Shapes: silence rests as a low arch (never a flat row of dots), a voice stands tallest in the middle.
    let resting = WaveformShape.live(count: 9, level: 0)
    #expect(resting == (0..<9).map { WaveformShape.rest($0, of: 9) })
    #expect(resting[4] > resting[0] && resting[0] >= WaveformShape.rest)
    let live = WaveformShape.live(count: 9, level: 0.8)
    #expect(live[4] > 0.5 && live.allSatisfy { $0 <= WaveformShape.peak && $0 >= WaveformShape.rest })
    #expect(live[4] > live[0] && live[4] > live[8])
    // An ordinary speaking level (a MacBook microphone gives about 0.2) visibly lifts every bar off its rest.
    let speaking = WaveformShape.live(count: 5, level: 0.2)
    #expect(zip(speaking, (0..<5).map { WaveformShape.rest($0, of: 5) }).allSatisfy { $0 - $1 >= 0.1 })
    let sweep = (0..<9).map { WaveformShape.sweep(bar: $0, count: 9) }
    #expect(sweep.allSatisfy { ($0.max() ?? 0) > 0.55 && ($0.min() ?? 1) >= WaveformShape.rest })

    // The motion is Core Animation's: the sweep loops on layers; live bars move only with the voice (silence
    // rests still, so a microphone that went quiet shows), and resting bars carry no animation.
    let view = WaveformLayerView(frame: NSRect(x: 0, y: 0, width: 60, height: 16))
    view.layout()
    func keys() -> Set<String> { Set(view.layer!.sublayers!.first!.mask!.sublayers!.flatMap { $0.animationKeys() ?? [] }) }
    view.apply(level: 0.6, active: true, sweep: false, bars: 9, barWidth: 2.5, still: false)
    #expect(view.mode == .live && !keys().contains { !$0.hasPrefix("ripple") && $0 != "settle" }, "no decorative loop while listening")
    view.apply(level: 0, active: false, sweep: true, bars: 9, barWidth: 2.5, still: false)
    #expect(view.mode == .sweep && keys().contains("sweep"))
    view.apply(level: 0, active: false, sweep: false, bars: 9, barWidth: 2.5, still: false)
    #expect(view.mode == .rest && !keys().contains("sweep"))
    view.apply(level: 0.6, active: true, sweep: false, bars: 9, barWidth: 2.5, still: true)
    #expect(!keys().contains { $0.hasPrefix("ripple") }, "Reduce Motion sets live heights without motion")

    let ears = EqualizerLayerView(frame: NSRect(x: 0, y: 0, width: 20, height: 14))
    func earKeys() -> Set<String> { Set(ears.layer!.sublayers!.flatMap { $0.animationKeys() ?? [] }) }
    ears.apply(bars: 4, height: 14, tint: NSColor.orange.cgColor, playing: true, still: false)
    #expect(ears.mode == .dancing && earKeys() == ["dance"])
    ears.apply(bars: 4, height: 14, tint: NSColor.orange.cgColor, playing: false, still: false)
    #expect(ears.mode == .rest && !earKeys().contains("dance"))
    ears.apply(bars: 4, height: 14, tint: NSColor.orange.cgColor, playing: true, still: true)
    #expect(ears.mode == .still && !earKeys().contains("dance"))
}

/// The live level reaches the bars and the horn glow straight from the feed, with no SwiftUI update. A tick
/// too small to see is dropped, a change ripples from the centre bar outward, and the loops run at 30 fps.
@MainActor @Test func levelFeedDrivesTheLayersDirectly() {
    let feed = VoiceLevelFeed()
    let view = WaveformLayerView(frame: NSRect(x: 0, y: 0, width: 60, height: 16))
    view.layout()
    view.apply(level: 0, active: true, sweep: false, bars: 9, barWidth: 2.5, still: false, feed: feed)
    let bars = view.layer!.sublayers!.first!.mask!.sublayers!
    #expect(bars.allSatisfy { ($0.animationKeys() ?? []).allSatisfy { $0 == "settle" } }, "silence rests still")
    let drawn = view.drawnLevels
    feed.send(0.6)
    #expect(view.drawnLevels == drawn + 1 && bars[4].bounds.height > 8 && bars[4].bounds.height > bars[0].bounds.height)
    func rippleStart(_ bar: CALayer) -> CFTimeInterval {
        (bar.animationKeys() ?? []).filter { $0.hasPrefix("ripple") }.compactMap { bar.animation(forKey: $0)?.beginTime }.max() ?? -1
    }
    #expect(rippleStart(bars[4]) >= 0 && rippleStart(bars[4]) < rippleStart(bars[2]) && rippleStart(bars[2]) < rippleStart(bars[0]),
            "a level change starts at the centre and ripples outward")
    feed.send(0.6 + VoiceLevelFeed.step * 1.2)
    #expect(view.drawnLevels == drawn + 1, "a tick that moves no bar by half a point is skipped")
    feed.send(0)
    #expect(view.drawnLevels == drawn + 2 && abs(bars[4].bounds.height - 16 * WaveformShape.rest(4, of: 9)) < 0.5)
    // Finishing stops following the level.
    view.apply(level: 0, active: false, sweep: true, bars: 9, barWidth: 2.5, still: false, feed: nil)
    feed.send(0.9)
    #expect(view.drawnLevels == drawn + 2)

    let ears = EqualizerLayerView(frame: NSRect(x: 0, y: 0, width: 20, height: 14))
    ears.apply(bars: 4, height: 14, tint: NSColor.orange.cgColor, playing: true, still: false)
    #expect(ears.layer!.sublayers!.allSatisfy { $0.animation(forKey: "dance")?.preferredFrameRateRange.maximum == 30 })
}

/// A level tick never publishes AppModel, so the main window and the menu bar panel do not re-render with it.
@MainActor @Test func levelTicksDoNotRepublishTheAppModel() {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-level-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let model = AppModel(store: LocalStore(directory: support), enablesHotkey: false)
    var changes = 0
    let watch = model.objectWillChange.sink { changes += 1 }
    defer { watch.cancel() }
    var seen: [Float] = []
    let link = model.voice.levels.sink { seen.append($0) }
    defer { link.cancel() }
    for level: Float in [0.2, 0.5, 0.8, 0] { model.level = level }
    #expect(changes == 0)
    #expect(seen == [0, 0.2, 0.5, 0.8, 0] && model.level == 0)
}

@Test func keycapsSplitModifiersFromTheKey() {
    #expect(KeycapRow.keys(for: "⌃⌥Space") == ["⌃", "⌥", "Space"])
    #expect(KeycapRow.keys(for: "Hold Fn") == ["Fn"])
    #expect(KeycapRow.keys(for: "⌘⇧D") == ["⌘", "⇧", "D"])
    #expect(KeycapRow.keys(for: "Double-tap Right ⌘") == ["Right ⌘"])
}

@Test func flowLayoutWrapsGreedily() {
    let layout = FlowLayout(spacing: 8)
    let rows = layout.arrange(width: 100, sizes: [CGSize(width: 40, height: 20), CGSize(width: 40, height: 24), CGSize(width: 40, height: 20), CGSize(width: 200, height: 20)])
    #expect(rows.map(\.indices) == [[0, 1], [2], [3]])
    #expect(rows[0].width == 88 && rows[0].height == 24)
}

@Test func workspacePagesMapToStoredSelections() {
    #expect(WorkspacePage.allCases.map(\.rawValue) == ["Dictate", "Modes", "Files", "Meetings", "History", "Vocabulary", "Settings"])
    #expect(WorkspacePage(selected: "History") == .history)
    #expect(WorkspacePage(selected: "nonsense") == .dictate)
}

@Test func statusToastClassifiesOutcomes() {
    #expect(!StatusToast.shouldShow("Ready."))
    #expect(StatusToast.shouldShow("Inserted into Notes."))
    #expect(StatusToast.tone(for: "Inserted into Notes.", failed: false) == .success)
    #expect(StatusToast.tone(for: "No speech detected.", failed: false) == .failure)
    #expect(StatusToast.tone(for: "Preparing speech…", failed: true) == .failure)
    #expect(StatusToast.tone(for: "Listening…", failed: false) == .info)
}

@MainActor @Test func recentResultsKeepTheLastEightInMemory() {
    let recent = RecentResults()
    for i in 1...10 { recent.add("result \(i)") }
    recent.add("   ")
    recent.add("result 10")
    #expect(recent.items.count == 8)
    #expect(recent.items.first == "result 10" && recent.items.last == "result 3")
}

/// Every shared component on one sheet, for review.
struct DesignSampler: View {
    @State private var text = ""
    @State private var toggle = true
    var body: some View {
        ZStack {
            MouthyBackdrop()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader("Design system", subtitle: "Every shared piece, warm and glowing") { MouthyIconButton(symbol: "ellipsis", help: "More") {} }
                    Tile(style: .hero) {
                        VStack(spacing: 12) {
                            MascotView(pose: .listen, size: 180, glowLevel: 0.8)
                            MouthyWaveform(level: 0.7, active: false)
                            HStack {
                                Button { } label: { Label("Record in Mouthy", systemImage: "mic.fill") }.buttonStyle(.mouthyPrimaryLarge)
                                Button { } label: { Label("Import audio", systemImage: "arrow.up.doc") }.buttonStyle(.mouthySecondaryLarge)
                            }
                            Button("Disabled") {}.buttonStyle(.mouthyPrimary).disabled(true)
                        }.frame(maxWidth: .infinity)
                    }
                    Tile {
                        VStack(alignment: .leading, spacing: 0) {
                            TileHeader("Settings", symbol: "slider.horizontal.3") { MouthyChip("Glow", symbol: "sparkles", tone: .glow) }
                            SettingRow("Paste into the focused app when finished", detail: "Off copies the text instead.") { Toggle("", isOn: $toggle).labelsHidden() }
                            SettingDivider()
                            SettingRow("Shortcut", detail: "Press once to start, once to finish.") { KeycapRow(shortcut: "⌃⌥Space") }
                            SettingDivider()
                            SettingRow("Add word") { MouthyField("Add word", text: $text) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Tile(style: .raised) {
                        VStack(alignment: .leading, spacing: 10) {
                            TileHeader("Chips")
                            FlowLayout {
                                ForEach(["Parakeet", "email", "⌃⌥E", "Xcode", "Clean up", "claude.ai"], id: \.self) { MouthyChip($0) }
                                MouthyChip("Needs attention", symbol: "exclamationmark.circle.fill", tone: .ember)
                            }
                            HStack { MouthyIconButton(symbol: "doc.on.doc", help: "Copy") {}; MouthyIconButton(symbol: "trash", help: "Delete", role: .destructive) {} }
                        }
                    }
                    Tile(style: .dashed) {
                        MascotEmptyState(pose: .sleep, title: "Nothing here yet", message: "Your dictations will show up here.", actionTitle: "Dictate something") {}
                            .frame(height: 300)
                    }
                    HStack(spacing: 8) {
                        ForEach(MascotPose.allCases, id: \.self) { MascotView(pose: $0, size: 56) }
                    }
                    HStack(spacing: 8) {
                        ForEach(MascotPose.allCases, id: \.self) { MascotGlyph(pose: $0, size: 24) }
                        Divider().frame(height: 24)
                        ForEach(MascotPose.allCases, id: \.self) { pose in
                            Image(nsImage: Mascot.glyphImage(pose) ?? NSImage()).resizable().frame(width: 40, height: 40)
                        }
                    }
                }
            }
            .padding(32)
        }
        .tint(MouthyTheme.orange)
        .foregroundStyle(MouthyTheme.cream)
    }
}

/// MOUTHY_RENDER_DIR=<dir>: the component sampler and the workspace shell on Dictate and Settings.
@MainActor @Test func designSystemRenders() throws {
    guard ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil else { return }
    if let url = try renderOffscreen(DesignSampler(), size: CGSize(width: 1180, height: 900), name: "design-sampler") { assertNoBlue(url) }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-design-render-\(UUID().uuidString)")
    let model = AppModel(store: LocalStore(directory: support), enablesHotkey: false)
    for page in ["Dictate", "Settings"] {
        model.selectedPage = page
        if let url = try renderOffscreen(WorkspaceView(model: model), size: CGSize(width: 1080, height: 760), name: "shell-\(page)") { assertNoBlue(url) }
    }
    model.phase = .listening
    model.selectedPage = "Dictate"
    if let url = try renderOffscreen(WorkspaceView(model: model), size: CGSize(width: 1080, height: 760), name: "shell-Dictate-listening", settle: 1.0,
                                     afterAppear: { model.status = "Inserted into Notes." }) { assertNoBlue(url) }
    model.phase = .idle
}
