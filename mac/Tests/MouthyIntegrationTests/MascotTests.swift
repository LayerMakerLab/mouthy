import AppKit
import Foundation
import Metal
import RealityKit
import SwiftUI
import Testing
import MouthyNotch
@testable import MouthyKit

/// The giraffe artwork MouthyKit ships (poses, head crops, menu bar glyphs, the 3D model) and the live 3D view.
@MainActor
struct MascotTests {
    private func pixelWidth(_ image: NSImage?) -> Int? {
        image?.representations.compactMap { $0 as? NSBitmapImageRep }.first?.pixelsWide
    }

    /// The share of a template image's pixels that are opaque.
    private func coverage(_ image: NSImage) -> Double {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else { return 0 }
        var opaque = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 } }
        return Double(opaque) / Double(rep.pixelsWide * rep.pixelsHigh)
    }

    @Test func everyPoseAndHeadLoads() throws {
        #expect(Mascot.resourceRoot != nil)
        for pose in MascotPose.allCases {
            let full = try #require(Mascot.image(pose), "missing pose \(pose)")
            #expect(pixelWidth(full) == 512, "\(pose) pose should be 512 px")
            let head = try #require(Mascot.head(pose), "missing head \(pose)")
            #expect(pixelWidth(head) == 128, "\(pose) head should be 128 px")
            #expect(head.size.width == head.size.height)
            // Small glyphs use the dedicated head art, not a crop of the pose.
            #expect(Mascot.glyphImage(pose) === head)
        }
    }

    @Test func menuBarGlyphsAreTemplates() throws {
        for listening in [false, true] {
            let url = try #require(Mascot.resourceURL("Mascot/menubar/\(listening ? "listening" : "idle").png"))
            let file = try #require(NSImage(contentsOf: url))
            #expect(pixelWidth(file) == 36)
            let image = Mascot.menuBarImage(listening: listening)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
            // The shipped art, not the SF Symbol fallback.
            #expect(pixelWidth(image) == 36)
        }
        // Listening is the filled, awake glyph: solid microphones and more ink than the sleeping idle glyph.
        let idleURL = try #require(Mascot.resourceURL("Mascot/menubar/idle.png"))
        let listeningURL = try #require(Mascot.resourceURL("Mascot/menubar/listening.png"))
        let idle = try #require(NSImage(contentsOf: idleURL))
        let listening = try #require(NSImage(contentsOf: listeningURL))
        #expect(coverage(listening) > coverage(idle))
        #expect(coverage(idle) > 0.2)
    }

    @Test func mascotResourcesStayWithinBudget() throws {
        let root = try #require(Mascot.resourceRoot).appendingPathComponent("Mascot")
        var total = 0
        for folder in ["poses", "heads", "menubar"] {
            let url = root.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                total += (try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            }
        }
        #expect(total < 10_000_000, "2D mascot art is \(total) bytes")
        let usdz = try #require(Mascot.usdzURL)
        let usdzSize = (try FileManager.default.attributesOfItem(atPath: usdz.path)[.size] as? Int) ?? .max
        #expect(usdzSize <= 8_000_000, "Mouthy.usdz is \(usdzSize) bytes")
    }

    @Test func headFollowMapsTheCursorToBoundedAngles() {
        let size = CGSize(width: 260, height: 260)
        #expect(HeadFollow.target(for: CGPoint(x: 130, y: 130), in: size) == .zero)
        let topRight = HeadFollow.target(for: CGPoint(x: 260, y: 0), in: size)
        #expect(abs(topRight.yaw - HeadFollow.maxYaw) < 1e-5)
        #expect(abs(topRight.pitch + HeadFollow.maxPitch) < 1e-5)
        // Outside the view clamps to the limits.
        let far = HeadFollow.target(for: CGPoint(x: -900, y: 900), in: size)
        #expect(abs(far.yaw + HeadFollow.maxYaw) < 1e-5)
        #expect(abs(far.pitch - HeadFollow.maxPitch) < 1e-5)
        #expect(HeadFollow.target(for: .zero, in: .zero) == .zero)
        #expect(abs(HeadFollow.maxYaw - 25 * .pi / 180) < 1e-6)
        #expect(abs(HeadFollow.maxPitch - 12 * .pi / 180) < 1e-6)
    }

    @Test func headFollowSpringSettlesWithoutOvershoot() {
        var value: Float = 0, velocity: Float = 0
        let target = HeadFollow.maxYaw
        var peak: Float = 0
        for _ in 0..<120 { // two seconds at 60 fps
            (value, velocity) = HeadFollow.step(value: value, velocity: velocity, target: target, dt: 1 / 60)
            peak = max(peak, value)
        }
        #expect(abs(value - target) < 0.001)
        #expect(peak <= target * 1.01)
        // A long frame hitch is capped, so the spring cannot explode.
        let hitch = HeadFollow.step(value: 0, velocity: 0, target: target, dt: 2)
        #expect(hitch.value.isFinite && hitch.value < target)
    }

    @Test func sceneCameraFramesAUnitTallModel() {
        let distance = Giraffe3DScene.cameraDistance
        let visibleHeight = 2 * distance * tan(Giraffe3DScene.fieldOfView * .pi / 360)
        #expect(abs(1 / visibleHeight - Giraffe3DScene.fill) < 1e-4)
    }

    @Test func sceneCentresAndScalesAnyModel() {
        let box = ModelEntity(mesh: .generateBox(width: 2, height: 4, depth: 1), materials: [SimpleMaterial()])
        box.position = [3, 5, -2]
        let scene = Giraffe3DScene(model: box)
        let bounds = scene.pivot.visualBounds(relativeTo: nil)
        #expect(abs(bounds.extents.y - 1) < 0.01)
        #expect(simd_length(bounds.center) < 0.01)
        #expect(scene.pivot.components[HeadFollowComponent.self] != nil)
        scene.follow(.init(yaw: 0.2, pitch: -0.1), reduceMotion: false)
        #expect(scene.pivot.components[HeadFollowComponent.self]?.target == .init(yaw: 0.2, pitch: -0.1))
        // Reduce Motion keeps the giraffe facing forward.
        scene.follow(.init(yaw: 0.2, pitch: -0.1), reduceMotion: true)
        #expect(scene.pivot.components[HeadFollowComponent.self]?.target == .zero)
    }

    // MARK: Gated: RealityKit model

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] != nil))
    func bundledModelLoadsInRealityKit() async throws {
        let url = try #require(Mascot.usdzURL)
        let model = try await Entity(contentsOf: url)
        let bounds = model.visualBounds(relativeTo: nil)
        #expect(!bounds.isEmpty)
        #expect(bounds.extents.y > 0)
        let scene = Giraffe3DScene(model: model)
        #expect(abs(max(scene.pivot.visualBounds(relativeTo: nil).extents.y, scene.pivot.visualBounds(relativeTo: nil).extents.z) - 1) < 0.02)
    }

    // MARK: Gated: renders

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil))
    func giraffe3DFallbackRenders() async throws {
        let missing = Giraffe3DView(fallbackPose: .wave, size: 260, modelURL: nil)
        let stage = ZStack { MouthyBackdrop(); missing }
        let url = try #require(try renderOffscreen(stage, size: CGSize(width: 320, height: 320), name: "giraffe3d-fallback"))
        assertNoBlue(url)
        // A broken model file also falls back to the 2D pose.
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).usdz")
        try Data("not a model".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        let failing = ZStack { MouthyBackdrop(); Giraffe3DView(fallbackPose: .cheer, size: 260, modelURL: broken) }
        let failed = try #require(try renderOffscreen(failing, size: CGSize(width: 320, height: 320), name: "giraffe3d-broken", settle: 1.0))
        assertNoBlue(failed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil))
    func mascotArtRenders() throws {
        let sheet = VStack(spacing: 18) {
            HStack(spacing: 14) {
                ForEach(MascotPose.allCases, id: \.self) { pose in
                    VStack(spacing: 6) {
                        MascotGlyph(pose: pose, size: 64)
                        MascotGlyph(pose: pose, size: 20)
                        Text(pose.rawValue).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream2)
                    }
                }
            }
            HStack(spacing: 24) {
                ForEach([false, true], id: \.self) { listening in
                    Image(nsImage: Mascot.menuBarImage(listening: listening)).renderingMode(.template).foregroundStyle(MouthyTheme.cream)
                        .frame(width: 22, height: 22).scaleEffect(2)
                }
            }
        }
        .padding(24)
        .onAppear { Mascot.install() }
        Mascot.install()
        let url = try #require(try renderOffscreen(ZStack { MouthyBackdrop(); sheet }, size: CGSize(width: 620, height: 260), name: "mascot-heads"))
        assertNoBlue(url)
    }

    /// Renders the 3D stage offscreen with RealityRenderer (cacheDisplay cannot capture Metal), facing forward
    /// and turned fully toward a cursor at the top right, to check framing, lighting and colour.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"] != nil && ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] != nil))
    func giraffe3DSceneRenders() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["MOUTHY_RENDER_DIR"])
        let modelURL = try #require(Mascot.usdzURL)
        let model = try await Entity(contentsOf: modelURL)
        let scene = Giraffe3DScene(model: model)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let side = 640
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: side, height: side, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let renderer = try RealityRenderer()
        renderer.entities.append(contentsOf: [scene.root])
        renderer.activeCamera = scene.camera
        renderer.cameraSettings.colorBackground = .color(CGColor(srgbRed: 0.078, green: 0.047, blue: 0.027, alpha: 1))
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        let turns: [(String, HeadFollow.Angles)] = [("front", .zero), ("turned", HeadFollow.target(for: CGPoint(x: 260, y: 0), in: CGSize(width: 260, height: 260)))]
        for (name, angles) in turns {
            scene.pivot.orientation = simd_quatf(angle: angles.yaw, axis: [0, 1, 0]) * simd_quatf(angle: angles.pitch, axis: [1, 0, 0])
            for _ in 0..<3 {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    do { try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in done.resume() }) }
                    catch { done.resume() }
                }
            }
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            texture.getBytes(&bytes, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
            let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
            let image = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let url = URL(fileURLWithPath: folder).appendingPathComponent("giraffe3d-\(name).png")
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
            assertNoBlue(url)
            // The giraffe fills the frame: plenty of warm, non-background pixels.
            var lit = 0
            for i in stride(from: 0, to: bytes.count, by: 4) where Int(bytes[i]) + Int(bytes[i + 1]) > 120 { lit += 1 }
            #expect(Double(lit) / Double(side * side) > 0.12, "\(name): giraffe covers too little of the frame")
        }
    }
}
