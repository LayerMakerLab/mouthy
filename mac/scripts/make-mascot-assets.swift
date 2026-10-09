import AppKit
import CoreGraphics
import Foundation

// Generates the small giraffe artwork MouthyKit ships next to the full poses:
//   Mascot/heads/{pose}.png      128 px square head crops (face + both microphone horns)
//   Mascot/menubar/{idle,listening}.png   36 px black-on-clear template glyphs for the menu bar
// and prints where each pose's two microphone horns sit, as unit points (Mascot.hornAnchors).
//
// Usage (from mac/):
//   swift scripts/make-mascot-assets.swift [poses folder] [Mascot folder] [debug folder]
// The poses folder defaults to the bundled 512 px poses; pass a folder of 1024 px originals for sharper crops.
// Horn positions are unit points, so either size gives the same anchors.
// A debug folder, when given, receives each pose with the measured horns and head crop drawn on it.

let poses = ["listen", "talk", "type", "sleep", "wave", "cheer"]
let fm = FileManager.default
let args = CommandLine.arguments
let sourceDir = args.count > 1 ? args[1] : "Sources/MouthyKit/Resources/Mascot/poses"
let mascotDir = args.count > 2 ? args[2] : "Sources/MouthyKit/Resources/Mascot"
let debugDir: String? = args.count > 3 ? args[3] : nil

// MARK: Pixels

struct Bitmap {
    let width: Int, height: Int
    var data: [UInt8] // RGBA, premultiplied, rows top to bottom

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        data = [UInt8](repeating: 0, count: width * height * 4)
    }

    init(_ image: CGImage, side: Int) {
        self.init(width: side, height: side)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// Hue (0-360), saturation, brightness (un-premultiplied) and alpha of a pixel.
    func hsva(_ x: Int, _ y: Int) -> (h: Double, s: Double, v: Double, a: Double) {
        let i = (y * width + x) * 4
        let a = Double(data[i + 3]) / 255
        guard a > 0 else { return (0, 0, 0, 0) }
        let r = Double(data[i]) / 255 / a, g = Double(data[i + 1]) / 255 / a, b = Double(data[i + 2]) / 255 / a
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        var h = 0.0
        if d > 0 {
            if maxC == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, maxC > 0 ? d / maxC : 0, maxC, a)
    }
}

func loadImage(_ path: String) -> CGImage {
    guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("Cannot read \(path)")
    }
    return cg
}

func writePNG(_ image: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// MARK: Horn measurement

struct Component { var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0; var points: [(Int, Int)] = []; var lit: [(Int, Int)] = [] }

/// Finds the two microphone horns: grey chrome or lit-yellow grille pixels in the upper half of the silhouette.
/// Nearby hits are joined (the grille's bars break the glow into stripes), and the two topmost tall groups are
/// the microphones. Each anchor is the middle of the lit grille, or for an unlit microphone the middle of its
/// head (the rows at least 60% as wide as the widest row), in pixels.
func measureHorns(_ bmp: Bitmap) -> [CGPoint] {
    let w = bmp.width, h = bmp.height
    var top = h, bottom = 0
    for y in 0..<h { for x in 0..<w where bmp.hsva(x, y).a > 0.5 { top = min(top, y); bottom = max(bottom, y); break } }
    let limit = top + (bottom - top) / 2
    // 1 = chrome, 2 = lit grille.
    var kind = [UInt8](repeating: 0, count: w * h)
    for y in top...limit {
        for x in 0..<w {
            let p = bmp.hsva(x, y)
            guard p.a > 0.85 else { continue }
            // Unlit chrome is near grey; the lit grille is saturated yellow (fur stays at hue 20-32).
            if (40...64).contains(p.h) && p.s > 0.6 && p.v > 0.94 { kind[y * w + x] = 2 }
            else if p.s < 0.12 && p.v > 0.5 { kind[y * w + x] = 1 }
        }
    }
    let radius = max(2, w / 160)
    var joined = [Bool](repeating: false, count: w * h)
    for i in 0..<(w * h) where kind[i] != 0 {
        let x = i % w, y = i / w
        for ny in max(0, y - radius)...min(h - 1, y + radius) {
            for nx in max(0, x - radius)...min(w - 1, x + radius) { joined[ny * w + nx] = true }
        }
    }
    var seen = [Bool](repeating: false, count: w * h)
    var blobs: [Component] = []
    for start in 0..<(w * h) where joined[start] && !seen[start] {
        var blob = Component(), stack = [start]
        seen[start] = true
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if kind[i] != 0 {
                blob.points.append((x, y))
                if kind[i] == 2 { blob.lit.append((x, y)) }
                blob.minX = min(blob.minX, x); blob.maxX = max(blob.maxX, x)
                blob.minY = min(blob.minY, y); blob.maxY = max(blob.maxY, y)
            }
            for dy in -1...1 { for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                if joined[j] && !seen[j] { seen[j] = true; stack.append(j) }
            } }
        }
        if !blob.points.isEmpty { blobs.append(blob) }
    }
    let minHeight = Int(Double(bottom - top) * 0.04)
    let tall = blobs.filter { $0.maxY - $0.minY >= minHeight && $0.points.count >= 30 }.sorted { $0.minY < $1.minY }
    guard tall.count >= 2 else { fatalError("Found \(tall.count) horn candidates") }
    return tall.prefix(2).map { blob -> CGPoint in
        if blob.lit.count * 4 >= blob.points.count {
            let xs = blob.lit.map(\.0), ys = blob.lit.map(\.1)
            return CGPoint(x: Double(xs.min()! + xs.max()!) / 2, y: Double(ys.min()! + ys.max()!) / 2)
        }
        // Unlit: only the chrome rim and stem show, so take the widest rows' centre for x and drop
        // from the top of the capsule by 60% of its width (the capsule is about 1.2 widths tall).
        var rows: [Int: [Int]] = [:]
        for (x, y) in blob.points { rows[y, default: []].append(x) }
        let widths = rows.mapValues { ($0.max()! - $0.min()!) }
        let widest = widths.values.max() ?? 1
        let head = rows.filter { Double(widths[$0.key]!) >= Double(widest) * 0.6 }
        let xs = head.values.map { Double($0.min()! + $0.max()!) / 2 }
        return CGPoint(x: xs.reduce(0, +) / Double(xs.count), y: Double(blob.minY) + Double(widest) * 0.6)
    }.sorted { $0.x < $1.x }
}

// MARK: Head crops

/// Horizontal nudge of the crop centre from the horns' midpoint, as a fraction of the crop side. The
/// sleeping giraffe's head tilts, so its face sits left of its horns.
let nudges: [String: CGFloat] = ["sleep": -0.10, "type": -0.02, "cheer": -0.03, "wave": -0.03]

func headCrop(_ horns: [CGPoint], tops: CGFloat, side: Int) -> CGRect {
    let span = hypot(horns[1].x - horns[0].x, horns[1].y - horns[0].y)
    let s = min(CGFloat(side), span * 2.75)
    let cx = (horns[0].x + horns[1].x) / 2
    var rect = CGRect(x: cx - s / 2, y: tops - s * 0.04, width: s, height: s)
    rect.origin.x = min(max(rect.minX, 0), CGFloat(side) - s)
    rect.origin.y = min(max(rect.minY, 0), CGFloat(side) - s)
    return rect.integral
}

func render(_ size: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    draw(ctx)
    return ctx.makeImage()!
}

// MARK: Menu bar glyphs

/// The giraffe's head from the front, drawn as vectors on a 36 px canvas (y up): a tall head with a wide round
/// muzzle, small upturned ears and two microphone horns. Idle sleeps (closed-eye arcs, hollow microphones);
/// listening is awake (round eyes, solid microphones with grille slots). Template images use alpha only, so the
/// face is knocked out with `.clear`.
func menuBarGlyph(listening: Bool) -> CGImage {
    render(36) { ctx in
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        let horns: [CGFloat] = [13.4, 22.6]
        // Ears, tilted up and out.
        for side in [-1.0, 1.0] {
            ctx.saveGState()
            ctx.translateBy(x: 18 + side * 9.4, y: 20.4)
            ctx.rotate(by: side * 0.38)
            ctx.fillEllipse(in: CGRect(x: -4.3, y: -2.0, width: 8.6, height: 4.0))
            ctx.restoreGState()
        }
        // Horn stalks.
        for x in horns { ctx.fill(CGRect(x: x - 0.8, y: 22, width: 1.6, height: 5.5)) }
        // Head and muzzle.
        ctx.fillEllipse(in: CGRect(x: 11.2, y: 9.5, width: 13.6, height: 15.5))
        ctx.fillEllipse(in: CGRect(x: 10.4, y: 2.2, width: 15.2, height: 11.2))
        // Microphone heads.
        for x in horns {
            let capsule = CGRect(x: x - 2.8, y: 26.4, width: 5.6, height: 8.2)
            if listening {
                ctx.addPath(CGPath(roundedRect: capsule, cornerWidth: 2.8, cornerHeight: 2.8, transform: nil)); ctx.fillPath()
                ctx.setBlendMode(.clear)
                for y in [29.2, 31.6] { ctx.fill(CGRect(x: capsule.minX + 1.3, y: y, width: capsule.width - 2.6, height: 0.9)) }
                ctx.setBlendMode(.normal)
            } else {
                ctx.setLineWidth(1.5)
                ctx.addPath(CGPath(roundedRect: capsule.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 2.05, cornerHeight: 2.05, transform: nil))
                ctx.strokePath()
            }
        }
        // Face knockouts: eyes and nostrils.
        ctx.setBlendMode(.clear)
        let eyes: [CGFloat] = [14.9, 21.1]
        if listening {
            for x in eyes { ctx.fillEllipse(in: CGRect(x: x - 2.0, y: 15.6, width: 4.0, height: 4.0)) }
        } else {
            ctx.setLineWidth(1.4); ctx.setLineCap(.round)
            for x in eyes {
                ctx.addArc(center: CGPoint(x: x, y: 18.4), radius: 1.9, startAngle: .pi * 1.18, endAngle: .pi * 1.82, clockwise: false)
                ctx.strokePath()
            }
        }
        for x in [15.7, 20.3] { ctx.fillEllipse(in: CGRect(x: x - 1.0, y: 6.4, width: 2.0, height: 2.0)) }
        ctx.setBlendMode(.normal)
    }
}

// MARK: Main

try fm.createDirectory(atPath: "\(mascotDir)/heads", withIntermediateDirectories: true)
try fm.createDirectory(atPath: "\(mascotDir)/menubar", withIntermediateDirectories: true)
if let debugDir { try fm.createDirectory(atPath: debugDir, withIntermediateDirectories: true) }

var anchorLines: [String] = []
for pose in poses {
    let image = loadImage("\(sourceDir)/\(pose).png")
    let side = image.width
    let work = Bitmap(image, side: 512)
    let scale = CGFloat(side) / 512
    let horns = measureHorns(work).map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
    let units = horns.map { CGPoint(x: $0.x / CGFloat(side), y: $0.y / CGFloat(side)) }
    anchorLines.append(String(format: "    .%@: [UnitPoint(x: %.3f, y: %.3f), UnitPoint(x: %.3f, y: %.3f)],", pose, units[0].x, units[0].y, units[1].x, units[1].y))

    // The horns' tops: the lowest y of either microphone head minus its half height (≈ anchor - 6% of side).
    let tops = horns.map(\.y).min()! - CGFloat(side) * 0.06
    var crop = headCrop(horns, tops: tops, side: side)
    crop.origin.x = min(max(crop.minX + crop.width * (nudges[pose] ?? 0), 0), CGFloat(side) - crop.width)
    // CGImage cropping uses top-left origin rows, matching our measurements.
    guard let cropped = image.cropping(to: crop) else { fatalError("Crop failed for \(pose)") }
    let head = render(128) { ctx in
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        // Fade what reaches into the lower corners (hooves, a raised leg, the curled body) so the crop reads as a
        // head: full strength within half the side of a point 38% down, gone by 0.64 of the side.
        ctx.setBlendMode(.destinationIn)
        let centre = CGPoint(x: 64, y: 128 * 0.62)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
                                  locations: [0, 0.78, 1])!
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 128 * 0.64, options: [.drawsAfterEndLocation])
    }
    try writePNG(head, to: "\(mascotDir)/heads/\(pose).png")

    if let debugDir {
        let flipped = render(512) { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 512, height: 512))
            let k = 512 / CGFloat(side)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2)
            ctx.stroke(CGRect(x: crop.minX * k, y: 512 - crop.maxY * k, width: crop.width * k, height: crop.height * k))
            ctx.setFillColor(NSColor.green.cgColor)
            for p in horns { ctx.fillEllipse(in: CGRect(x: p.x * k - 5, y: 512 - p.y * k - 5, width: 10, height: 10)) }
        }
        try writePNG(flipped, to: "\(debugDir)/\(pose)-measure.png")
    }
}

for listening in [false, true] {
    try writePNG(menuBarGlyph(listening: listening), to: "\(mascotDir)/menubar/\(listening ? "listening" : "idle").png")
}

print("Wrote \(mascotDir)/heads and \(mascotDir)/menubar from \(sourceDir).")
print("Mascot.hornAnchors (unit points, top-left origin):")
anchorLines.forEach { print($0) }
