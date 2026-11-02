import AppKit
import SwiftUI
import Testing
@testable import MouthyKit
@testable import MouthyNotch

/// The notch frames for mouthy.dev's film: the real hub (NotchRootView, M5 geometry, the Mouthy tab from a scratch
/// model) hosted far off screen and captured while one dictation plays out in real time: rest, the band grows, the
/// hub opens on the live words (as the pointer on the notch opens it), it closes, the finishing sweep, rest. Each frame is a transparent PNG with its time,
/// so the film can place the real pixels over its own backdrop.
///   MOUTHY_SITE_FILM=<dir> swift test --filter siteFilmFrames
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_SITE_FILM"] != nil))
func siteFilmFrames() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOUTHY_SITE_FILM"]!)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-film-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let originalFolder = MouthyTabs.storageFolder
    defer { MouthyTabs.storageFolder = originalFolder }
    MouthyTabs.storageFolder = scratch.appendingPathComponent("Notch")
    let model = AppModel(store: LocalStore(directory: scratch), enablesHotkey: false)

    Mascot.install()
    let geometry = NotchGeometry.on(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), visible: NSRect(x: 0, y: 0, width: 1512, height: 949),
                                    notchLeft: 663.5, notchRight: 848.5, safeTop: 32)
    let hub = NotchHub()
    let tab = PreviewVoiceTab(model: model)
    hub.register(tab)
    hub.dictationTabID = tab.id
    hub.selectedID = tab.id

    let size = geometry.open.size
    let host = NSHostingView(rootView: NotchRootView(hub: hub, geometryOverride: geometry)
        .frame(width: size.width, height: size.height).mouthyAppearance(.dark).environment(\.mouthyFlatGlass, true).environment(\.notchFlatGlass, true))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.contentView = nil; window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))

    let drawScale = CGFloat(Double(ProcessInfo.processInfo.environment["MOUTHY_SITE_FILM_SCALE"] ?? "") ?? Double(window.backingScaleFactor))

    /// The hub as it shows now: the cached drawing plus every Core Animation view from its presentation layer.
    func capture() throws -> CGImage {
        host.layoutSubtreeIfNeeded()
        let moving = renderServerViews(in: host)
        let shots: [(frame: CGRect, layer: CALayer)] = moving.compactMap { view in
            guard !view.isHiddenOrHasHiddenAncestor, let shown = view.layer?.presentation() else { return nil }
            return (view.convert(view.bounds, to: nil), shown)
        }
        let hidden = moving.filter { !$0.isHidden }
        hidden.forEach { $0.isHidden = true }
        // MOUTHY_SITE_FILM_SCALE draws above the screen's backing scale (3 for a 4K film), from the views themselves.
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * drawScale), pixelsHigh: Int(host.bounds.height * drawScale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        hidden.forEach { $0.isHidden = false }
        let base = try #require(rep.cgImage)
        let context = try #require(CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let scale = CGFloat(base.width) / host.bounds.width
        for shot in shots {
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: shot.frame.minX, y: shot.frame.minY)
            shot.layer.render(in: context)
            context.restoreGState()
        }
        return try #require(context.makeImage())
    }

    // The script, in seconds. The sentence is said word by word between `speakFrom` and `speakTo`.
    let sentence = "Book the dentist for Thursday at nine."
    let words = sentence.split(separator: " ").map(String.init)
    let start = 0.7, open = 1.5, speakFrom = 1.9, speakTo = 4.3, close = 4.9, finish = 5.2, done = 5.8, total = 6.8
    var began: Date?
    var stage = 0
    var stamps: [String] = []
    var events: [String] = []   // when each scripted step really ran, so several runs can be merged on its timeline
    let writer = DispatchQueue(label: "film.writer")
    let clock = Date()
    var index = 0
    while true {
        let t = Date().timeIntervalSince(clock)
        if t > total { break }
        if stage == 0, t >= start {
            events.append("start\t\(String(format: "%.4f", t))"); stage = 1; began = Date()
            model.phase = .listening; model.targetName = "Notes"
            hub.presentDictation(NotchDictation(target: "Notes", level: 0.2, startedAt: began))
        }
        if stage == 1, t >= open {
            // What the pointer resting on the notch does (NotchHub.setOpen): the same spring, on the dictation's tab.
            events.append("open\t\(String(format: "%.4f", t))"); stage = 2; hub.selectedID = tab.id
            withAnimation(MouthyMotion.notchOpen) { hub.stageForPreview(open: true) }
        }
        if stage >= 1, stage < 4 {
            // Words arrive as they are said, a little behind the voice, like live recognition.
            let said = t < speakFrom ? 0 : min(words.count, Int((t - speakFrom) / (speakTo - speakFrom) * Double(words.count)) + 1)
            let text = words.prefix(max(0, said - 1)).joined(separator: " ") + (said >= words.count && t > speakTo + 0.15 ? " " + words.last! : "")
            let live = text.trimmingCharacters(in: .whitespaces)
            if model.liveText != live { model.liveText = live; hub.presentDictation(NotchDictation(target: "Notes", level: 0.4, partialText: live, startedAt: began)) }
            model.elapsed = Date().timeIntervalSince(began ?? Date())
            // A speaking voice: syllables at about 5 Hz while words are said, quiet before and after.
            let speaking = t >= speakFrom - 0.1 && t <= speakTo + 0.1
            let level: Float = speaking ? Float(0.35 + 0.3 * abs(sin(t * 15.7)) + 0.15 * abs(sin(t * 6.1))) : 0.04
            model.level = level
            hub.voice.send(level)
        }
        if stage == 2, t >= close { events.append("close\t\(String(format: "%.4f", t))"); stage = 3; withAnimation(MouthyMotion.notchClose) { hub.stageForPreview(open: false) } }
        if stage == 3, t >= finish {
            stage = 4
            events.append("finish\t\(String(format: "%.4f", t))")
            model.phase = .finishing
            hub.presentDictation(NotchDictation(target: "Notes", partialText: sentence, transcribing: true, startedAt: began))
        }
        if stage == 4, t >= done { events.append("done\t\(String(format: "%.4f", t))"); stage = 5; model.phase = .idle; hub.endDictation() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.004))
        let image = try capture()
        let name = String(format: "notch-%05d.png", index)
        stamps.append("\(name)\t\(String(format: "%.4f", Date().timeIntervalSince(clock)))")
        index += 1
        writer.async {
            let url = folder.appendingPathComponent(name)
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try? data.write(to: url) }
        }
    }
    writer.sync {}
    try stamps.joined(separator: "\n").write(to: folder.appendingPathComponent("stamps.tsv"), atomically: true, encoding: .utf8)
    try events.joined(separator: "\n").write(to: folder.appendingPathComponent("events.tsv"), atomically: true, encoding: .utf8)
    let geometryNote = "open \(geometry.open) notch \(geometry.notchHeight) closedWide \(geometry.closedWide) scale \(window.backingScaleFactor)"
    try geometryNote.write(to: folder.appendingPathComponent("geometry.txt"), atomically: true, encoding: .utf8)
    print("FILM frames \(index) in \(total) s; \(geometryNote)")
    #expect(index > Int(total * 20), "only \(index) frames")
}
