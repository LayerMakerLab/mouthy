import AppKit
import SwiftUI
import Testing
@testable import MouthyKit
import MouthyNotch

/// Renders a view in a real offscreen window (never ImageRenderer, which skips AppKit-backed controls) and
/// writes a PNG to MOUTHY_RENDER_DIR. Returns nil when the variable is unset.
///
/// `cacheDisplay` cannot capture Liquid Glass: a `glassEffect` view and everything it samples draw blank.
/// By default the render sets `mouthyFlatGlass`, so `mouthyGlass` surfaces (and `.mouthySecondary` buttons)
/// draw their base fill and rim instead. System `.buttonStyle(.glass)` still draws only its label here.
/// `afterAppear` runs once the view is on screen, for state changes that only animate after appearing (toasts).
///
/// `cacheDisplay` draws layers at their model values, so Core Animation motion (music ears, finishing
/// sweep, orb rings) would render at rest. When the view holds any `RenderServerView`, the window is ordered in
/// far off screen (never on a display, never key) so that motion runs, and each such view is drawn from its
/// on-screen (presentation) layer instead.
@MainActor
func renderOffscreen(_ view: some View, size: CGSize, name: String, settle: TimeInterval = 0.5, flatGlass: Bool = true, afterAppear: (() -> Void)? = nil) throws -> URL? {
    guard let folder = ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] else { return nil }
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark).environment(\.mouthyFlatGlass, flatGlass))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let moving = !renderServerViews(in: host).isEmpty
    if moving { window.orderFrontRegardless() }
    defer { window.orderOut(nil) }
    if let afterAppear {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        afterAppear()
    }
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.layoutSubtreeIfNeeded()
    // What Core Animation shows now, captured before those views are hidden for the cached drawing.
    let shots: [(frame: CGRect, layer: CALayer)] = moving ? renderServerViews(in: host).compactMap { view in
        guard !view.isHiddenOrHasHiddenAncestor, let shown = view.layer?.presentation() else { return nil }
        return (view.convert(view.bounds, to: nil), shown)
    } : []
    let hidden = moving ? renderServerViews(in: host).filter { !$0.isHidden } : []
    hidden.forEach { $0.isHidden = true }
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    hidden.forEach { $0.isHidden = false }
    var image = try #require(rep.cgImage)
    if !shots.isEmpty {
        let scale = CGFloat(image.width) / host.bounds.width
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for shot in shots {
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: shot.frame.minX, y: shot.frame.minY)
            shot.layer.render(in: context)
            context.restoreGState()
        }
        image = try #require(context.makeImage())
    }
    let url = URL(fileURLWithPath: folder).appendingPathComponent(name.hasSuffix(".png") ? name : name + ".png")
    try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    window.contentView = nil
    window.close()
    return url
}

/// Every `RenderServerView` (Core Animation motion) under `view`.
@MainActor func renderServerViews(in view: NSView) -> [RenderServerView] {
    view.subviews.flatMap { child -> [RenderServerView] in
        (child as? RenderServerView).map { [$0] } ?? renderServerViews(in: child)
    }
}

/// The share of pixels that read as blue: hue 190–260°, saturation above 0.35 and brightness above 0.25.
func bluePixelFraction(_ url: URL) -> Double {
    guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
    let width = cg.width, height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn, width * height > 0 else { return 1 }
    var blue = 0
    for i in stride(from: 0, to: pixels.count, by: 4) where isBlue(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2]) { blue += 1 }
    return Double(blue) / Double(width * height)
}

func isBlue(r: UInt8, g: UInt8, b: UInt8) -> Bool {
    let (h, s, v) = hsb(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)
    return h >= 190 && h <= 260 && s > 0.35 && v > 0.25
}

/// Hue in degrees, saturation and brightness in 0...1.
func hsb(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
    let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
    var hue = 0.0
    if delta > 0 {
        if maxC == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
    }
    if hue < 0 { hue += 360 }
    return (hue, maxC == 0 ? 0 : delta / maxC, maxC)
}

/// Fails the test when more than 0.1% of a render is blue.
func assertNoBlue(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
    let fraction = bluePixelFraction(url)
    #expect(fraction <= 0.001, "\(url.lastPathComponent) is \(String(format: "%.3f", fraction * 100))% blue", sourceLocation: sourceLocation)
}
