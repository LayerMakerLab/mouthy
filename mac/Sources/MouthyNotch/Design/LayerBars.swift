import AppKit
import Combine
import SwiftUI

/// A decorative view whose sublayers Core Animation animates in the render server: a running animation costs
/// Mouthy no per-frame work (no timeline, no SwiftUI body, no redraw of the hub window). Clicks pass through.
open class RenderServerView: NSView {
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError("not used") }
    open override var wantsUpdateLayer: Bool { true }
    open override func hitTest(_ point: NSPoint) -> NSView? { nil }
    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        func rescale(_ layer: CALayer) { layer.contentsScale = scale; layer.sublayers?.forEach(rescale) }
        layer.map(rescale)
    }
    /// Unit-space y of the top edge for gradients drawn in this view's layers.
    public var topY: CGFloat { layer?.contentsAreFlipped() == true ? 0 : 1 }

    public static func withoutActions(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }
    /// Caps a looping decorative animation at 30 fps, so the render server composites it at that rate instead
    /// of the display's 120 Hz.
    @discardableResult public static func decorative<A: CAAnimation>(_ animation: A) -> A {
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        return animation
    }
    /// Animates each layer's height from what is on screen now to its model height.
    static func settle(_ layers: [CALayer], duration: CFTimeInterval = 0.25) {
        for layer in layers {
            let shown = layer.presentation()?.bounds.height ?? layer.bounds.height
            layer.removeAllAnimations()
            guard abs(shown - layer.bounds.height) > 0.01 else { continue }
            let settle = CABasicAnimation(keyPath: "bounds.size.height")
            settle.fromValue = shown
            settle.toValue = layer.bounds.height
            settle.duration = duration
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(settle, forKey: "settle")
        }
    }
}

// MARK: - Live voice level

/// The live voice level, handed straight to the layer views that draw it (bars, horn glow, orb halo): a level
/// tick sets a few layer properties and runs no SwiftUI body. Changes smaller than `step` are dropped.
@MainActor public final class VoiceLevelFeed {
    public static let step: Float = 0.015
    private let subject = CurrentValueSubject<Float, Never>(0)
    public init() {}
    public var level: Float { subject.value }
    /// Every level change, starting with the current one.
    public var levels: AnyPublisher<Float, Never> { subject.eraseToAnyPublisher() }
    public func send(_ level: Float) {
        let level = min(max(level, 0), 1)
        guard level != subject.value, abs(level - subject.value) >= Self.step || level == 0 else { return }
        subject.send(level)
    }
}

/// Keeps one layer view subscribed to at most one `VoiceLevelFeed`.
@MainActor final class FeedLink {
    private weak var feed: VoiceLevelFeed?
    private var link: AnyCancellable?
    func follow(_ feed: VoiceLevelFeed?, _ receive: @escaping (Float) -> Void) {
        guard feed !== self.feed || (feed == nil && link != nil) else { return }
        self.feed = feed
        link = feed?.levels.sink { receive($0) }
    }
}

// MARK: - Music ears

final class EqualizerLayerView: RenderServerView {
    static let barWidth: CGFloat = 2.5, spacing: CGFloat = 2, rest: CGFloat = 3
    static func width(bars: Int) -> CGFloat { CGFloat(bars) * barWidth + CGFloat(max(0, bars - 1)) * spacing }

    enum Mode { case rest, still, dancing }
    private var barLayers: [CAGradientLayer] = []
    private var height: CGFloat = 14
    private var tint: CGColor?
    private(set) var mode: Mode = .rest

    func apply(bars: Int, height: CGFloat, tint: CGColor, playing: Bool, still: Bool) {
        let rebuilt = bars != barLayers.count || height != self.height
        self.height = height
        if rebuilt {
            barLayers.forEach { $0.removeFromSuperlayer() }
            barLayers = (0..<bars).map { _ in
                let bar = CAGradientLayer()
                bar.cornerRadius = Self.barWidth / 2
                bar.contentsScale = window?.backingScaleFactor ?? 2
                layer?.addSublayer(bar)
                return bar
            }
            place()
        }
        if tint != self.tint || rebuilt {
            self.tint = tint
            let faded = tint.copy(alpha: tint.alpha * 0.6) ?? tint
            Self.withoutActions { barLayers.forEach { $0.colors = [tint, faded] } }
        }
        let next: Mode = !playing ? .rest : still ? .still : .dancing
        guard next != mode || rebuilt else { return }
        mode = next
        Self.withoutActions { for (i, bar) in barLayers.enumerated() { bar.bounds.size.height = restingHeight(i) } }
        Self.settle(barLayers)
        if mode == .dancing { barLayers.enumerated().forEach { dance($1, index: $0) } }
    }

    /// Paused bars rest low; with Reduce Motion, playing bars stand still at varied heights.
    private func restingHeight(_ index: Int) -> CGFloat {
        guard mode == .still else { return Self.rest }
        let pattern: [CGFloat] = [0.55, 0.9, 0.7, 0.45, 0.8]
        return max(Self.rest, height * pattern[index % pattern.count])
    }

    /// One looping keyframe track per bar, sampled from overlapping sines (reads as music without any audio
    /// access). Each bar has its own length, so the bars never fall into step.
    private func dance(_ bar: CALayer, index: Int) {
        let i = Double(index), samples = 12
        let duration = 1.05 + 0.17 * i
        var values: [CGFloat] = (0..<samples).map { k in
            let t = duration * Double(k) / Double(samples)
            let wave = 0.5 + 0.25 * sin(t * (5.1 + i * 1.3) + i * 1.7) + 0.25 * sin(t * (8.3 - i * 0.9) + i)
            return max(Self.rest, height * CGFloat(wave))
        }
        values.append(values[0])
        let track = CAKeyframeAnimation(keyPath: "bounds.size.height")
        track.values = values
        track.duration = duration
        track.calculationMode = .cubic
        track.repeatCount = .infinity
        track.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + 0.05
        track.fillMode = .backwards
        bar.add(Self.decorative(track), forKey: "dance")
    }

    private func place() {
        let x0 = (bounds.width - Self.width(bars: barLayers.count)) / 2
        Self.withoutActions {
            for (i, bar) in barLayers.enumerated() {
                bar.startPoint = CGPoint(x: 0.5, y: topY); bar.endPoint = CGPoint(x: 0.5, y: 1 - topY)
                bar.bounds.size.width = Self.barWidth
                if bar.bounds.height == 0 { bar.bounds.size.height = restingHeight(i) }
                bar.position = CGPoint(x: x0 + CGFloat(i) * (Self.barWidth + Self.spacing) + Self.barWidth / 2, y: bounds.midY)
            }
        }
    }
    override func layout() { super.layout(); place() }
}

struct EqualizerLayers: NSViewRepresentable {
    let playing: Bool
    let tint: Color
    let bars: Int
    let height: CGFloat
    let still: Bool
    func makeNSView(context: Context) -> EqualizerLayerView { EqualizerLayerView(frame: .zero) }
    func updateNSView(_ view: EqualizerLayerView, context: Context) {
        view.apply(bars: bars, height: height, tint: tint.resolve(in: context.environment).cgColor, playing: playing, still: still)
    }
}

// MARK: - Dictation waveform

/// Bar heights (fractions of the full height) for the live waveform. Pure, so it is tested without a window.
enum WaveformShape {
    static let rest: CGFloat = 0.15
    /// Bars at rest form a low arch (a small waveform), tallest in the middle, never a flat row of dots.
    static func rest(_ index: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return rest }
        return rest + 0.32 * CGFloat(sin(Double.pi * (Double(index) + 0.5) / Double(count)))
    }
    /// Live bars stop just short of the full height.
    static let peak: CGFloat = 0.92
    /// The voice level shaped tallest in the middle. The voice lifts each bar from its resting height, so ordinary
    /// speech moves every bar (it used to have to outgrow the arch first, and a voice at an ordinary level barely did).
    static func live(count: Int, level: Float) -> [CGFloat] {
        // Perceptual curve so quiet speech still moves.
        let target = min(1, sqrt(CGFloat(max(0, level))) * 1.05)
        let mid = CGFloat(count - 1) / 2
        return (0..<count).map { i in
            let distance = mid > 0 ? abs(CGFloat(i) - mid) / mid : 0
            let envelope = 1 - 0.5 * pow(distance, 1.4)
            let resting = rest(i, of: count)
            return min(peak, resting + (peak - resting) * target * envelope)
        }
    }
    /// Seconds a level change takes to ripple one bar further from the centre.
    static let rippleDelay: CFTimeInterval = 0.035
    static let sweepDuration: CFTimeInterval = 1.4
    /// Where in its loop the sweep starts (0...1): the glow already over the second bar, so it reads as a sweep at once.
    static func sweepStart(count: Int) -> Double { 4 / Double(count + 6) }
    /// One bar's heights over a sweep: a soft glow crossing low bars from left to right.
    static func sweep(bar: Int, count: Int, samples: Int = 28) -> [CGFloat] {
        (0...samples).map { k in
            let position = Double(k) / Double(samples) * Double(count + 6) - 3
            let d = Double(bar) - position
            return rest + 0.45 * CGFloat(exp(-d * d / 4))
        }
    }
}

final class WaveformLayerView: RenderServerView {
    enum Mode { case rest, live, sweep }
    private let fill = CAGradientLayer()
    private let barMask = CALayer()
    private var barLayers: [CALayer] = []
    private var barWidth: CGFloat = 3
    private var still = false
    /// Nil until the first update, and after a resize, so the next update re-enters its mode at the new size.
    private(set) var mode: Mode?
    private var level: Float = -1
    private let feed = FeedLink()
    /// Level changes drawn so far (a tick that would move no bar by half a point is skipped).
    private(set) var drawnLevels = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.mask = barMask
        layer?.addSublayer(fill)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    /// `feed`, when set, supplies the live level directly (no SwiftUI update per tick); `level` is used otherwise.
    func apply(level: Float, active: Bool, sweep: Bool, bars: Int, barWidth: CGFloat, still: Bool, feed: VoiceLevelFeed? = nil) {
        let rebuilt = bars != barLayers.count || barWidth != self.barWidth || still != self.still
        self.barWidth = barWidth; self.still = still
        if rebuilt {
            barLayers.forEach { $0.removeFromSuperlayer() }
            barLayers = (0..<bars).map { _ in
                let bar = CALayer()
                bar.backgroundColor = .black
                bar.cornerRadius = barWidth / 2
                barMask.addSublayer(bar)
                return bar
            }
            place()
        }
        let next: Mode = active ? .live : sweep ? .sweep : .rest
        if next != mode || rebuilt {
            mode = next
            self.level = -1
            switch next {
            case .rest:
                setHeights((0..<bars).map { WaveformShape.rest($0, of: bars) })
                Self.settle(barLayers)
            case .sweep:
                if still {
                    setHeights(Array(repeating: WaveformShape.rest + 0.15, count: bars))
                    Self.settle(barLayers, duration: 0.2)
                } else {
                    startSweep()
                }
            case .live:
                // Silence rests still: no decorative motion that could hide a microphone that went quiet.
                Self.settle(barLayers, duration: 0.15)
            }
        }
        if let feed {
            self.feed.follow(feed) { [weak self] in self?.show($0) }
        } else {
            self.feed.follow(nil) { _ in }
            show(level)
        }
    }

    /// Sets the live heights for `level`. The change enters at the centre bar and ripples outward, each bar
    /// easing from where it is; Core Animation runs it, so Mouthy does nothing between ticks.
    private func show(_ level: Float) {
        guard mode == .live, level != self.level else { return }
        let targets = WaveformShape.live(count: barLayers.count, level: level).map(pixels)
        let current = barLayers.map(\.bounds.height)
        guard self.level < 0 || zip(targets, current).contains(where: { abs($0 - $1) >= 0.5 }) else { return }
        self.level = level
        drawnLevels += 1
        let mid = CGFloat(barLayers.count - 1) / 2
        Self.withoutActions {
            for (i, bar) in barLayers.enumerated() {
                let from = bar.bounds.height
                bar.bounds.size.height = targets[i]
                guard !still, abs(from - targets[i]) > 0.01 else { continue }
                // Additive, so overlapping ripples sum smoothly instead of cutting each other off.
                let ripple = CABasicAnimation(keyPath: "bounds.size.height")
                ripple.isAdditive = true
                ripple.fromValue = from - targets[i]
                ripple.toValue = 0
                ripple.duration = targets[i] > from ? 0.12 : 0.3
                ripple.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ripple.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + Double(abs(CGFloat(i) - mid)) * WaveformShape.rippleDelay
                ripple.fillMode = .backwards
                ripple.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                bar.add(ripple, forKey: "ripple\(drawnLevels)")
            }
        }
    }

    private func pixels(_ fraction: CGFloat) -> CGFloat { max(barWidth, bounds.height * min(1, fraction)) }

    private func setHeights(_ fractions: [CGFloat]) {
        Self.withoutActions { for (bar, f) in zip(barLayers, fractions) { bar.bounds.size.height = pixels(f) } }
    }

    /// The sweep shows on the first frame: the bars take its shape with the glow already over the first bars (never a
    /// flat row first), and the loop runs on from that point.
    private func startSweep() {
        let count = barLayers.count, samples = 28
        let start = WaveformShape.sweepStart(count: count)
        let tracks = (0..<count).map { WaveformShape.sweep(bar: $0, count: count, samples: samples).map(pixels) }
        let now = CACurrentMediaTime()
        Self.withoutActions {
            for (i, bar) in barLayers.enumerated() {
                bar.removeAllAnimations()
                bar.bounds.size.height = tracks[i][Int((start * Double(samples)).rounded())]
            }
        }
        for (i, bar) in barLayers.enumerated() {
            let track = CAKeyframeAnimation(keyPath: "bounds.size.height")
            track.values = tracks[i]
            track.duration = WaveformShape.sweepDuration
            track.repeatCount = .infinity
            track.beginTime = bar.convertTime(now, from: nil)
            track.timeOffset = start * WaveformShape.sweepDuration
            bar.add(Self.decorative(track), forKey: "sweep")
        }
    }

    private func place() {
        let count = barLayers.count
        let spacing = max(2, barWidth * 0.9)
        let x0 = (bounds.width - (CGFloat(count) * barWidth + CGFloat(max(0, count - 1)) * spacing)) / 2
        Self.withoutActions {
            fill.frame = bounds
            fill.colors = [NSColor(MouthyTheme.glowHi).cgColor, NSColor(MouthyTheme.orange).cgColor]
            fill.startPoint = CGPoint(x: 0.5, y: topY); fill.endPoint = CGPoint(x: 0.5, y: 1 - topY)
            barMask.frame = bounds
            for (i, bar) in barLayers.enumerated() {
                bar.bounds.size.width = barWidth
                if bar.bounds.height == 0 { bar.bounds.size.height = pixels(WaveformShape.rest(i, of: count)) }
                bar.position = CGPoint(x: x0 + CGFloat(i) * (barWidth + spacing) + barWidth / 2, y: bounds.midY)
            }
        }
    }
    override func layout() {
        let resized = fill.frame.size != bounds.size
        super.layout()
        place()
        // Heights are fractions of the view's height; a new size restarts the current motion at that size.
        if resized, let current = mode {
            let shown = max(0, level)
            mode = nil
            barLayers.forEach { $0.removeAllAnimations() }
            apply(level: shown, active: current == .live, sweep: current == .sweep, bars: barLayers.count, barWidth: barWidth, still: still)
        }
    }
}

struct WaveformLayers: NSViewRepresentable {
    let level: Float
    let active: Bool
    let sweep: Bool
    let bars: Int
    let barWidth: CGFloat
    let still: Bool
    var feed: VoiceLevelFeed?
    func makeNSView(context: Context) -> WaveformLayerView { WaveformLayerView(frame: .zero) }
    func updateNSView(_ view: WaveformLayerView, context: Context) {
        view.apply(level: level, active: active, sweep: sweep, bars: bars, barWidth: barWidth, still: still, feed: active ? feed : nil)
    }
}

// MARK: - Mascot level glow

/// The voice-lit glow on the giraffe's microphone horns (or one halo behind a stand-in symbol). The level sets
/// each glow's opacity and size as a Core Animation change the render server eases, so a level arriving
/// 12 times a second costs no SwiftUI work; changes too small to see are skipped.
final class LevelGlowView: RenderServerView {
    private var glows: [CAGradientLayer] = []
    private var anchors: [UnitPoint] = []
    private var halo = false
    private var size: CGFloat = 0
    private var spread: CGFloat = 0
    private var amount: CGFloat = -1
    private var animated = true
    private let feed = FeedLink()

    func apply(anchors: [UnitPoint], halo: Bool, size: CGFloat, spread: CGFloat, amount: CGFloat, animated: Bool, feed: VoiceLevelFeed? = nil) {
        self.animated = animated
        if anchors != self.anchors || halo != self.halo || size != self.size || spread != self.spread || glows.isEmpty {
            self.anchors = anchors; self.halo = halo; self.size = size; self.spread = spread
            glows.forEach { $0.removeFromSuperlayer() }
            let glow = NSColor(MouthyTheme.glow).cgColor
            glows = (halo ? [UnitPoint.center] : anchors).map { _ in
                let layer = CAGradientLayer()
                layer.type = .radial
                layer.startPoint = CGPoint(x: 0.5, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 1)
                layer.colors = halo
                    ? [glow.copy(alpha: 0.55) ?? glow, glow.copy(alpha: 0) ?? glow]
                    : [NSColor(MouthyTheme.glowHi).cgColor, glow.copy(alpha: 0.6) ?? glow, glow.copy(alpha: 0) ?? glow]
                layer.contentsScale = window?.backingScaleFactor ?? 2
                self.layer?.addSublayer(layer)
                return layer
            }
            self.amount = -1
            place()
        }
        if let feed {
            self.feed.follow(feed) { [weak self] in self?.show(CGFloat($0)) }
        } else {
            self.feed.follow(nil) { _ in }
            show(amount)
        }
    }

    private func show(_ amount: CGFloat) {
        guard self.amount < 0 || abs(amount - self.amount) >= 0.03 || (amount == 0 && self.amount != 0) else { return }
        self.amount = amount
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        for glow in glows {
            glow.opacity = Float(halo ? 0.25 + amount * 0.75 : 0.35 + amount * 0.65)
            if !halo { glow.transform = CATransform3DMakeScale(0.8 + amount * 0.5, 0.8 + amount * 0.5, 1) }
        }
        CATransaction.commit()
    }

    private func place() {
        Self.withoutActions {
            let points = halo ? [UnitPoint.center] : anchors
            for (glow, anchor) in zip(glows, points) {
                let side = size * spread
                glow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                let y = topY == 1 ? (1 - anchor.y) * bounds.height : anchor.y * bounds.height
                glow.position = CGPoint(x: anchor.x * bounds.width, y: y)
            }
        }
    }
    override func layout() { super.layout(); place() }
}

/// The voice-lit glow: horn glows at `anchors` (unit points in a `size` square), or one halo when `halo`. With
/// a `feed` the glow follows the live level directly; otherwise it shows `level`.
public struct LevelGlow: NSViewRepresentable {
    let anchors: [UnitPoint]
    let halo: Bool
    let size: CGFloat
    let level: Float
    let animated: Bool
    var spread: CGFloat?
    var feed: VoiceLevelFeed?
    public init(anchors: [UnitPoint], halo: Bool, size: CGFloat, level: Float, animated: Bool, spread: CGFloat? = nil, feed: VoiceLevelFeed? = nil) {
        self.anchors = anchors; self.halo = halo; self.size = size; self.level = level; self.animated = animated; self.spread = spread; self.feed = feed
    }
    public func makeNSView(context: Context) -> NSView { LevelGlowView(frame: .zero) }
    public func updateNSView(_ view: NSView, context: Context) {
        (view as? LevelGlowView)?.apply(anchors: anchors, halo: halo, size: size, spread: spread ?? (halo ? 1.5 : 0.32),
                                        amount: CGFloat(min(max(level, 0), 1)), animated: animated, feed: feed)
    }
}
