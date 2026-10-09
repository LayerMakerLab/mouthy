import SwiftUI

/// Live level bars in the mic-glow gradient. Core Animation draws them: the heights change only when `level`
/// changes, the listening breath and the finishing sweep run in the render server, and inactive bars rest flat
/// at 15%. Nothing is scheduled per frame in Mouthy.
public struct MouthyWaveform: View {
    let level: Float
    let active: Bool
    var bars: Int
    var height: CGFloat
    var barWidth: CGFloat
    var sweep: Bool
    var feed: VoiceLevelFeed?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// With a `feed`, live bars follow its level directly (no SwiftUI update per tick) and `level` is ignored.
    public init(level: Float, active: Bool, bars: Int = 21, height: CGFloat = 44, barWidth: CGFloat = 3, sweep: Bool = false, feed: VoiceLevelFeed? = nil) {
        self.level = level; self.active = active; self.bars = max(1, bars); self.height = height; self.barWidth = barWidth; self.sweep = sweep; self.feed = feed
    }

    /// True when the bars rest flat and nothing moves.
    var paused: Bool { !(active || sweep) }

    public var body: some View {
        let spacing = max(2, barWidth * 0.9)
        let width = CGFloat(bars) * barWidth + CGFloat(bars - 1) * spacing
        WaveformLayers(level: active ? level : 0, active: active, sweep: sweep, bars: bars, barWidth: barWidth, still: reduceMotion, feed: feed)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}
