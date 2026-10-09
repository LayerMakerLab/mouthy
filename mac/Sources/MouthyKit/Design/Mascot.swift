import SwiftUI
import AppKit
import MouthyNotch

/// The giraffe artwork shipped in MouthyKit's resource bundle.
///
/// Lookup never uses `Bundle.module`: its accessor calls fatalError when the bundle is missing, which would
/// crash host apps and their tests. Missing art returns nil and callers fall back to SF Symbols.
@MainActor
enum Mascot {
    private final class Token {}
    private static var images: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    /// The MouthyKit resource bundle's resource folder, or nil when it is not shipped.
    static let resourceRoot: URL? = {
        let fm = FileManager.default
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources) }
        folders.append(Bundle.main.bundleURL)
        let own = Bundle(for: Token.self).bundleURL
        folders.append(own.deletingLastPathComponent())
        if let resources = Bundle(for: Token.self).resourceURL { folders.append(resources) }
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where name.hasSuffix("_MouthyKit.bundle") {
                let bundleURL = folder.appendingPathComponent(name)
                let root = Bundle(url: bundleURL)?.resourceURL ?? bundleURL
                if fm.fileExists(atPath: root.appendingPathComponent("Mascot").path) { return root }
                if fm.fileExists(atPath: bundleURL.appendingPathComponent("Mascot").path) { return bundleURL }
            }
        }
        return nil
    }()

    /// A file inside the bundle, e.g. "Mascot/poses/listen.png", or nil when it is missing.
    static func resourceURL(_ path: String) -> URL? {
        guard let url = resourceRoot?.appendingPathComponent(path), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func load(_ path: String) -> NSImage? {
        if let cached = images[path] { return cached }
        if misses.contains(path) { return nil }
        guard let url = resourceURL(path), let image = NSImage(contentsOf: url) else { misses.insert(path); return nil }
        images[path] = image
        return image
    }

    /// The full-body pose (512 px, transparent).
    static func image(_ pose: MascotPose) -> NSImage? { load("Mascot/poses/\(pose.rawValue).png") }

    /// A square head crop for small glyphs (128 px), when shipped.
    static func head(_ pose: MascotPose) -> NSImage? { load("Mascot/heads/\(pose.rawValue).png") }

    /// Square head crops of each 512 px pose, used for small glyphs until dedicated head art ships.
    static let headCrops: [MascotPose: CGRect] = [
        .listen: CGRect(x: 0.30, y: 0.0, width: 0.56, height: 0.56),
        .talk: CGRect(x: 0.20, y: 0.01, width: 0.63, height: 0.63),
        .type: CGRect(x: 0.21, y: 0.0, width: 0.68, height: 0.68),
        .sleep: CGRect(x: 0.22, y: 0.08, width: 0.76, height: 0.76),
        .wave: CGRect(x: 0.21, y: 0.0, width: 0.62, height: 0.62),
        .cheer: CGRect(x: 0.22, y: 0.0, width: 0.62, height: 0.62)
    ]
    private static var crops: [MascotPose: NSImage] = [:]

    /// The head for small glyphs: shipped head art, else a crop of the pose, else nil.
    static func glyphImage(_ pose: MascotPose) -> NSImage? {
        if let head = head(pose) { return head }
        if let cached = crops[pose] { return cached }
        guard let full = image(pose), let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let unit = headCrops[pose] else { return nil }
        let rect = CGRect(x: unit.minX * CGFloat(cg.width), y: unit.minY * CGFloat(cg.height),
                          width: unit.width * CGFloat(cg.width), height: unit.height * CGFloat(cg.height)).integral
        guard let cropped = cg.cropping(to: rect) else { return nil }
        let image = NSImage(cgImage: cropped, size: NSSize(width: rect.width / 2, height: rect.height / 2))
        crops[pose] = image
        return image
    }

    /// The menu bar icon: a template giraffe, or a microphone symbol until the art ships.
    static func menuBarImage(listening: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        if let art = load("Mascot/menubar/\(listening ? "listening" : "idle").png")?.copy() as? NSImage {
            art.size = size; art.isTemplate = true
            return art
        }
        let symbol = NSImage(systemSymbolName: listening ? "mic.circle.fill" : "mic.fill", accessibilityDescription: "Mouthy")
            ?? NSImage(size: size)
        let configured = symbol.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? symbol
        configured.isTemplate = true
        return configured
    }

    /// The 3D giraffe for RealityKit, when shipped.
    static var usdzURL: URL? { resourceURL("Mascot/Mouthy.usdz") }

    /// Where the two microphone horns sit in each 512 px pose, as unit points.
    static let hornAnchors: [MascotPose: [UnitPoint]] = [
        .listen: [UnitPoint(x: 0.497, y: 0.097), UnitPoint(x: 0.701, y: 0.142)],
        .talk: [UnitPoint(x: 0.424, y: 0.128), UnitPoint(x: 0.582, y: 0.085)],
        .type: [UnitPoint(x: 0.433, y: 0.094), UnitPoint(x: 0.660, y: 0.119)],
        .sleep: [UnitPoint(x: 0.562, y: 0.183), UnitPoint(x: 0.814, y: 0.270)],
        .wave: [UnitPoint(x: 0.452, y: 0.077), UnitPoint(x: 0.639, y: 0.109)],
        .cheer: [UnitPoint(x: 0.451, y: 0.079), UnitPoint(x: 0.658, y: 0.117)]
    ]

    /// Hands the giraffe's head to the notch and other glyphs,, which otherwise draws SF Symbols.
    static func install() {
        NotchArt.mascot = { pose in Mascot.glyphImage(pose).map { Image(nsImage: $0) } }
    }
}

/// The giraffe in a pose. Pose changes cross-fade with a small scale; while listening, `glowLevel` lights
/// the microphone horns with the input level (`glowFeed`, when given, drives the glow layers directly).
struct MascotView: View {
    let pose: MascotPose
    var size: CGFloat = 160
    var glowLevel: Float?
    var glowFeed: VoiceLevelFeed?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(pose: MascotPose, size: CGFloat = 160, glowLevel: Float? = nil, glowFeed: VoiceLevelFeed? = nil) {
        self.pose = pose; self.size = size; self.glowLevel = glowLevel; self.glowFeed = glowFeed
    }

    var body: some View {
        ZStack {
            if let image = Mascot.image(pose) {
                ZStack {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    if let glowLevel {
                        LevelGlow(anchors: Mascot.hornAnchors[pose] ?? [], halo: false, size: size, level: glowLevel,
                                  animated: !reduceMotion, spread: 0.3, feed: glowFeed)
                    }
                    if pose == .talk { TalkBubble(size: size) }
                }
                .id(pose)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            } else {
                MascotGlyph(pose: pose, size: size * 0.5)
                    .id(pose)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: pose)
        .accessibilityElement()
        .accessibilityLabel("Mouthy the giraffe")
        .accessibilityValue(pose.rawValue)
    }
}

/// The talk pose's small glowing speech bubble beside the head, so an agent question never reads as hello.
/// It bounces once when it appears; nothing runs afterwards.
struct TalkBubble: View {
    let size: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: "bubble.left.fill")
            .font(.system(size: size * 0.16, weight: .semibold))
            .foregroundStyle(MouthyTheme.glow)
            .shadow(color: MouthyTheme.glow.opacity(0.55), radius: size * 0.03)
            .symbolEffect(.bounce, options: .nonRepeating, value: shown)
            .position(x: size * 0.86, y: size * 0.13)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { if !reduceMotion { shown = true } }
    }
}

