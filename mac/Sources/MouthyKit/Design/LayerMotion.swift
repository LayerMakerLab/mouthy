import AppKit
import SwiftUI
import MouthyNotch

// Decorative motion on `RenderServerView` (MouthyNotch): Core Animation runs it in the render server at 30 fps,
// with no timeline, no per-frame SwiftUI body and no redraw in Mouthy while it plays.

// MARK: - Record orb rings

/// Two rings that grow from the orb and fade, half a cycle apart, while listening.
final class PulseRingsView: RenderServerView {
    static let from: CGFloat = 48, to: CGFloat = 70, period: CFTimeInterval = 1.6
    private var rings: [CALayer] = []

    func start(color: CGColor) {
        guard rings.isEmpty, let host = layer else { return }
        let begin = CACurrentMediaTime()
        rings = (0..<2).map { index in
            let ring = CALayer()
            ring.borderColor = color
            ring.borderWidth = 1.5
            ring.bounds = CGRect(x: 0, y: 0, width: Self.from, height: Self.from)
            ring.cornerRadius = Self.from / 2
            ring.opacity = 0
            host.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "bounds.size")
            grow.fromValue = CGSize(width: Self.from, height: Self.from)
            grow.toValue = CGSize(width: Self.to, height: Self.to)
            let round = CABasicAnimation(keyPath: "cornerRadius")
            round.fromValue = Self.from / 2
            round.toValue = Self.to / 2
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, round, fade]
            group.duration = Self.period
            group.repeatCount = .infinity
            group.beginTime = ring.convertTime(begin, from: nil) - Double(index) * Self.period / 2
            ring.add(Self.decorative(group), forKey: "pulse")
            return ring
        }
        needsLayout = true
    }
    var running: Bool { !rings.isEmpty }
    override func layout() {
        super.layout()
        Self.withoutActions { rings.forEach { $0.position = CGPoint(x: bounds.midX, y: bounds.midY) } }
    }
}

struct PulseRings: NSViewRepresentable {
    let color: Color
    func makeNSView(context: Context) -> PulseRingsView { PulseRingsView(frame: .zero) }
    func updateNSView(_ view: PulseRingsView, context: Context) { view.start(color: color.resolve(in: context.environment).cgColor) }
}

// MARK: - Indeterminate progress

/// A glowing segment sliding along the track (a file is transcribing). Reduce Motion pulses the whole bar instead.
final class SlidingSegmentView: RenderServerView {
    private let segment = CAGradientLayer()
    private var still: Bool?
    private var laidOutWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = true
        segment.colors = [NSColor(MouthyTheme.orange).cgColor, NSColor(MouthyTheme.glowHi).cgColor]
        segment.startPoint = CGPoint(x: 0, y: 0.5)
        segment.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(segment)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    func apply(still: Bool) {
        guard still != self.still else { return }
        self.still = still
        laidOutWidth = -1
        needsLayout = true
    }
    var animationKeys: [String] { segment.animationKeys() ?? [] }

    override func layout() {
        super.layout()
        guard bounds.width != laidOutWidth, let still else { return }
        laidOutWidth = bounds.width
        let width = bounds.width, height = bounds.height
        layer?.cornerRadius = height / 2
        segment.removeAllAnimations()
        Self.withoutActions {
            segment.cornerRadius = height / 2
            if still {
                segment.frame = bounds
            } else {
                let length = width * 0.28
                segment.bounds = CGRect(x: 0, y: 0, width: length, height: height)
                segment.position = CGPoint(x: -length / 2, y: bounds.midY)
            }
        }
        if still {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.9; pulse.toValue = 0.35
            pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            segment.add(Self.decorative(pulse), forKey: "pulse")
        } else {
            let length = width * 0.28
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = -length / 2
            slide.toValue = width + length / 2
            slide.duration = 1.6
            slide.repeatCount = .infinity
            segment.add(Self.decorative(slide), forKey: "slide")
        }
    }
}

struct SlidingSegment: NSViewRepresentable {
    let still: Bool
    func makeNSView(context: Context) -> SlidingSegmentView { SlidingSegmentView(frame: .zero) }
    func updateNSView(_ view: SlidingSegmentView, context: Context) { view.apply(still: still) }
}

// MARK: - Timer ring

/// A running timer's ring shows the time left: full when it starts, the warm-metal arc empties to nothing at `ends`
/// as one linear Core Animation over the time left, so a running Focus, Break or Timer costs Mouthy nothing per second.
/// Looks like `GlowRing`: a faint track, an arc from patch through the tint to mic-glow at its head, a soft glow.
final class TimerRingLayerView: RenderServerView {
    /// `arc` casts the glow; `clip` is cut to the arc by `arcMask` (on its own layer, so the gradient's mirror
    /// never mirrors the arc); `fill` is the gradient.
    private let track = CAShapeLayer(), arc = CALayer(), clip = CALayer(), fill = CAGradientLayer(), arcMask = CAShapeLayer()
    private var ends = Date.distantPast, length: TimeInterval = 1, lineWidth: CGFloat = 0, tint: CGColor?
    private var placedSize = CGSize.zero, placedFlip: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        track.fillColor = nil
        track.strokeColor = NSColor(MouthyTheme.cream).withAlphaComponent(0.07).cgColor
        arcMask.fillColor = nil
        arcMask.strokeColor = .black
        arcMask.lineCap = .round
        fill.type = .conic
        clip.mask = arcMask
        clip.addSublayer(fill)
        arc.shadowOffset = .zero
        arc.shadowRadius = 6
        arc.shadowOpacity = 0.5
        arc.addSublayer(clip)
        layer?.addSublayer(track)
        layer?.addSublayer(arc)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    /// The share of the time still left at `date`, 1…0.
    func left(at date: Date) -> Double { min(1, max(0, ends.timeIntervalSince(date) / length)) }
    var fillAnimation: CABasicAnimation? { arcMask.animation(forKey: "fill") as? CABasicAnimation }

    func apply(ends: Date, length: TimeInterval, lineWidth: CGFloat, tint: CGColor) {
        let restyled = lineWidth != self.lineWidth || tint != self.tint
        let retimed = ends != self.ends || length != self.length
        guard restyled || retimed else { return }
        self.ends = ends; self.length = max(1, length); self.lineWidth = lineWidth; self.tint = tint
        if restyled {
            let patch = NSColor(MouthyTheme.patch).cgColor, glowHi = NSColor(MouthyTheme.glowHi).cgColor
            Self.withoutActions {
                // Past the head the colour runs from mic-glow back to patch, so the round cap at the start of
                // the arc (just behind 12 o'clock, where the conic gradient ends) is patch, as the tail is.
                fill.colors = [patch, tint, glowHi, glowHi, patch]
                arc.shadowColor = tint
                track.lineWidth = lineWidth
                arcMask.lineWidth = lineWidth
            }
            placedSize = .zero
        }
        place()
        run()
    }

    /// The arc starts at 12 o'clock and runs clockwise; the conic gradient sweeps the same way from the same
    /// angle, so its bright end is always the head of the arc.
    private func place() {
        let flipped = layer?.contentsAreFlipped() == true
        guard bounds.width > 0, bounds.size != placedSize || flipped != placedFlip else { return }
        placedSize = bounds.size; placedFlip = flipped
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY), radius = side / 2 - lineWidth / 2
        // y runs up unless the layer is flipped.
        let top: CGFloat = flipped ? -.pi / 2 : .pi / 2
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: top, endAngle: flipped ? top + 2 * .pi : top - 2 * .pi, clockwise: !flipped)
        Self.withoutActions {
            track.frame = bounds
            track.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
            arc.frame = bounds; clip.frame = bounds; fill.frame = bounds; arcMask.frame = bounds
            arcMask.path = path
            // The conic gradient starts in endPoint's direction from startPoint (the centre): 12 o'clock.
            fill.startPoint = CGPoint(x: 0.5, y: 0.5)
            fill.endPoint = CGPoint(x: 0.5, y: topY == 1 ? 1 : 0)
            fill.transform = Self.conicTransform(flipped: flipped)
        }
    }

    /// Core Animation sweeps a conic gradient toward +y: counterclockwise on screen in an unflipped layer, so
    /// there the gradient is mirrored left to right to run clockwise with the arc.
    static func conicTransform(flipped: Bool) -> CATransform3D {
        flipped ? CATransform3DIdentity : CATransform3DMakeScale(-1, 1, 1)
    }

    private func run() {
        let now = Date(), r0 = left(at: now), remaining = max(0, ends.timeIntervalSince(now))
        arcMask.removeAnimation(forKey: "fill"); fill.removeAnimation(forKey: "fill")
        Self.withoutActions {
            arcMask.strokeEnd = r0
            fill.locations = Self.stops(r0).map { NSNumber(value: $0) }
        }
        guard remaining > 0, bounds.width > 0 else { return }
        // A long timer moves its head a fraction of a point a second; a few frames a second keep it smooth.
        let pointsPerSecond = Double.pi * Double(min(bounds.width, bounds.height) - lineWidth) / length
        let fps = Float(min(30, max(2, pointsPerSecond * 4)))
        let begin = CACurrentMediaTime()
        func linear(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from; animation.toValue = to
            animation.beginTime = begin
            animation.duration = remaining
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 2), maximum: fps, preferred: fps)
            return animation
        }
        // One animation: the ring is full from second 0 and empties as the time runs out.
        arcMask.add(linear("strokeEnd", from: r0, to: 0), forKey: "fill")
        fill.add(linear("locations", from: Self.stops(r0), to: Self.stops(0)), forKey: "fill")
    }

    /// Gradient stops for an arc of length `p`: patch at the tail, the tint midway, mic-glow at the head and a little
    /// past it (the head's round cap), then back to patch by the tail's cap.
    static func stops(_ p: Double) -> [Double] { [0, p / 2, p, min(1, p + 0.035), 1] }

    override func layout() {
        super.layout()
        let before = placedSize, flip = placedFlip
        place()
        if placedSize != before || placedFlip != flip { run() }
    }
}

/// A running timer's ring (see `TimerRingLayerView`): no timeline, no per-second redraw.
struct TimerRingLayers: NSViewRepresentable {
    let ends: Date
    let length: TimeInterval
    var lineWidth: CGFloat = 7
    var tint: Color = MouthyTheme.orange
    func makeNSView(context: Context) -> TimerRingLayerView { TimerRingLayerView(frame: .zero) }
    func updateNSView(_ view: TimerRingLayerView, context: Context) {
        view.apply(ends: ends, length: length, lineWidth: lineWidth, tint: tint.resolve(in: context.environment).cgColor)
    }
}
