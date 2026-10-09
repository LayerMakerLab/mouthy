import SwiftUI
import RealityKit
import MouthyNotch

/// The live 3D giraffe (RealityKit), used on the onboarding hello step and in About.
///
/// The bundled `Mascot/Mouthy.usdz` (about 31k triangles, 1k textures) loads asynchronously
/// while the 2D pose holds its place, then fades in. The giraffe turns toward the cursor (yaw ±25°, pitch ±12°)
/// on a critically damped spring and settles back to centre when the cursor leaves. The RealityView exists only
/// while the model is loaded and the view is on screen: on disappear the entity is removed and the view torn
/// down, so nothing renders while hidden. Without the model, or if it fails to load, the 2D pose stays.
struct Giraffe3DView: View {
    var fallbackPose: MascotPose = .cheer
    var size: CGFloat = 260
    /// The model to show. Nil uses the bundled giraffe; tests pass a missing or broken file to exercise the fallback.
    var modelURL: URL?
    private var usesBundledModel = true

    init(fallbackPose: MascotPose = .cheer, size: CGFloat = 260) {
        self.fallbackPose = fallbackPose; self.size = size
    }

    /// Shows a specific model file (nil = none), for tests.
    init(fallbackPose: MascotPose = .cheer, size: CGFloat = 260, modelURL: URL?) {
        self.fallbackPose = fallbackPose; self.size = size; self.modelURL = modelURL; usesBundledModel = false
    }

    @State private var scene: Giraffe3DScene?
    @State private var failed = false
    @State private var target = HeadFollow.Angles.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let scene {
                RealityView { content in
                    content.camera = .virtual
                    content.add(scene.root)
                } update: { _ in
                    scene.follow(target, reduceMotion: reduceMotion)
                }
                .realityViewCameraControls(.none)
                .background(Color.clear)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point): target = HeadFollow.target(for: point, in: CGSize(width: size, height: size))
                    case .ended: target = .zero
                    }
                }
            } else {
                MascotView(pose: fallbackPose, size: size)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: scene != nil)
        .task {
            guard scene == nil, !failed, let url = usesBundledModel ? Mascot.usdzURL : modelURL else { return }
            do {
                let model = try await Entity(contentsOf: url)
                guard !Task.isCancelled else { return }
                scene = Giraffe3DScene(model: model)
            } catch {
                failed = true
            }
        }
        .onDisappear {
            scene?.root.removeFromParent()
            scene = nil
            target = .zero
        }
        .accessibilityElement()
        .accessibilityLabel("Mouthy the giraffe")
    }
}

/// The giraffe's stage: the model centred and scaled to one unit tall inside a pivot that turns toward the cursor,
/// a camera framing it, a warm key light, a soft cream fill and an amber rim from behind (the mic-horn glow).
@MainActor
final class Giraffe3DScene {
    let root = Entity()
    let pivot = Entity()
    let camera = PerspectiveCamera()
    let model: Entity

    /// Camera field of view and the share of the frame's height the giraffe fills.
    static let fieldOfView: Float = 30
    static let fill: Float = 0.8
    /// Just in front of the two microphone heads, in the unit-tall model's space (measured from offscreen renders).
    static let hornLights: [SIMD3<Float>] = [[-0.107, 0.46, 0.06], [0.107, 0.46, 0.06]]

    init(model: Entity) {
        self.model = model
        root.name = "Giraffe3DRoot"
        let fit = Entity()
        fit.addChild(model)
        let bounds = model.visualBounds(relativeTo: nil)
        let extents = bounds.extents
        let height = max(extents.x, extents.y, extents.z, 0.0001)
        model.position -= bounds.center
        fit.scale = SIMD3(repeating: 1 / height)
        pivot.addChild(fit)
        // The microphone horns glow: a small amber point light just in front of each mic head, riding the pivot so
        // the glow turns with the giraffe.
        for anchor in Self.hornLights {
            let glow = PointLight()
            glow.light.color = NSColor(srgbRed: 1, green: 0.71, blue: 0.28, alpha: 1)
            glow.light.intensity = 60000
            glow.light.attenuationRadius = 0.18
            glow.position = anchor
            pivot.addChild(glow)
        }
        pivot.components.set(HeadFollowComponent())
        root.addChild(pivot)

        camera.camera.fieldOfViewInDegrees = Self.fieldOfView
        camera.look(at: [0, -0.01, 0], from: [0, -0.01, Self.cameraDistance], relativeTo: nil)
        root.addChild(camera)

        root.addChild(Self.light(color: NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 1), intensity: 2600, from: [-1.2, 1.6, 2.2]))
        root.addChild(Self.light(color: NSColor(srgbRed: 0.965, green: 0.89, blue: 0.757, alpha: 1), intensity: 900, from: [1.6, 0.2, 1.4]))
        root.addChild(Self.light(color: NSColor(srgbRed: 1, green: 0.71, blue: 0.28, alpha: 1), intensity: 1400, from: [0.4, 1.4, -2.0]))

        HeadFollowSystem.registerOnce()
    }

    /// How far the camera sits so a one-unit-tall model fills `fill` of the frame.
    static var cameraDistance: Float { 0.5 / Self.fill / tan(fieldOfView * .pi / 360) }

    private static func light(color: NSColor, intensity: Float, from position: SIMD3<Float>) -> Entity {
        let light = DirectionalLight()
        light.light.color = color
        light.light.intensity = intensity
        light.look(at: .zero, from: position, relativeTo: nil)
        return light
    }

    /// Hands the cursor's target angles to the spring that turns the pivot each frame.
    func follow(_ target: HeadFollow.Angles, reduceMotion: Bool) {
        guard var follow = pivot.components[HeadFollowComponent.self] else { return }
        follow.target = reduceMotion ? .zero : target
        follow.response = reduceMotion ? 0.2 : HeadFollow.response
        pivot.components.set(follow)
    }
}

/// Cursor-follow maths for the 3D giraffe, kept pure for tests.
enum HeadFollow {
    struct Angles: Equatable {
        var yaw: Float
        var pitch: Float
        static let zero = Angles(yaw: 0, pitch: 0)
    }

    static let maxYaw: Float = 25 * .pi / 180
    static let maxPitch: Float = 12 * .pi / 180
    /// Spring response in seconds (critically damped, so it never overshoots).
    static let response: Float = 0.45

    /// Target angles for a cursor point in a view: right turns the giraffe right, up tilts it up.
    static func target(for point: CGPoint, in size: CGSize) -> Angles {
        guard size.width > 0, size.height > 0 else { return .zero }
        let nx = Float(min(max(point.x / size.width, 0), 1) * 2 - 1)
        let ny = Float(min(max(point.y / size.height, 0), 1) * 2 - 1)
        return Angles(yaw: nx * maxYaw, pitch: ny * maxPitch)
    }

    /// One step of a critically damped spring toward `target` (semi-implicit Euler, `dt` capped at 1/30 s).
    static func step(value: Float, velocity: Float, target: Float, dt: Float, response: Float = response) -> (value: Float, velocity: Float) {
        let dt = min(max(dt, 0), 1 / 30)
        let omega = 2 * Float.pi / max(response, 0.01)
        let acceleration = omega * omega * (target - value) - 2 * omega * velocity
        let velocity = velocity + acceleration * dt
        return (value + velocity * dt, velocity)
    }
}

/// Spring state for the giraffe's turn toward the cursor.
struct HeadFollowComponent: Component {
    var target = HeadFollow.Angles.zero
    var current = HeadFollow.Angles.zero
    var velocity = HeadFollow.Angles.zero
    var response = HeadFollow.response
}

/// Eases every `HeadFollowComponent` toward its target each frame. It runs only while a RealityView showing the
/// giraffe renders, and does no work once the spring has settled.
struct HeadFollowSystem: System {
    private static let query = EntityQuery(where: .has(HeadFollowComponent.self))
    @MainActor private static var registered = false

    @MainActor static func registerOnce() {
        guard !registered else { return }
        registered = true
        HeadFollowComponent.registerComponent()
        registerSystem()
    }

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var follow = entity.components[HeadFollowComponent.self] else { continue }
            let settled = abs(follow.current.yaw - follow.target.yaw) < 0.0005 && abs(follow.current.pitch - follow.target.pitch) < 0.0005
                && abs(follow.velocity.yaw) < 0.0005 && abs(follow.velocity.pitch) < 0.0005
            if settled { continue }
            let yaw = HeadFollow.step(value: follow.current.yaw, velocity: follow.velocity.yaw, target: follow.target.yaw, dt: dt, response: follow.response)
            let pitch = HeadFollow.step(value: follow.current.pitch, velocity: follow.velocity.pitch, target: follow.target.pitch, dt: dt, response: follow.response)
            follow.current = .init(yaw: yaw.value, pitch: pitch.value)
            follow.velocity = .init(yaw: yaw.velocity, pitch: pitch.velocity)
            entity.components.set(follow)
            entity.orientation = simd_quatf(angle: yaw.value, axis: [0, 1, 0]) * simd_quatf(angle: pitch.value, axis: [1, 0, 0])
        }
    }
}
