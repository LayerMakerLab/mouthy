import SwiftUI

/// Sizes of the notch's dictation surfaces (the hub's morph contract): the pill while dictating, a taller
/// and wider pill when an agent's question sits above the words, and a short result line.
enum DictationPillMetrics {
    static let dictationWidth: CGFloat = 420
    static let dictationExtra: CGFloat = 46
    static let promptWidth: CGFloat = 460
    static let promptExtra: CGFloat = 70
    static let resultWidth: CGFloat = 340
    static let resultExtra: CGFloat = 30
    /// The black shape's concave shoulders reach this far past the content on each side.
    static let shoulder: CGFloat = 8

    static func hasPrompt(_ dictation: NotchDictation) -> Bool {
        !(dictation.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    static func size(for dictation: NotchDictation, notchHeight: CGFloat) -> CGSize {
        hasPrompt(dictation) ? CGSize(width: promptWidth, height: notchHeight + promptExtra)
                             : CGSize(width: dictationWidth, height: notchHeight + dictationExtra)
    }

    static func resultSize(notchHeight: CGFloat) -> CGSize { CGSize(width: resultWidth, height: notchHeight + resultExtra) }

    /// The giraffe's pose for a dictation state: type while finishing, talk while answering an agent, else listen.
    static func pose(for dictation: NotchDictation) -> MascotPose {
        dictation.transcribing ? .type : hasPrompt(dictation) ? .talk : .listen
    }

    /// The line under the notch when no words have arrived yet.
    static func label(for dictation: NotchDictation) -> String {
        let target = dictation.target.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = dictation.transcribing ? "Finishing" : "Listening"
        return target.isEmpty ? word : word + " · " + target
    }
}

/// The giraffe's head with its two microphone horns lit by the input level. Core Animation eases the glow
/// when the level changes; nothing ticks in Mouthy while it does.
public struct MascotLevelGlyph: View {
    let pose: MascotPose
    let size: CGFloat
    let level: Float
    let lit: Bool
    /// The live level, fed straight to the glow layers; nil shows `level`.
    let feed: VoiceLevelFeed?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(pose: MascotPose, size: CGFloat = 20, level: Float = 0, lit: Bool = true, feed: VoiceLevelFeed? = nil) {
        self.pose = pose; self.size = size; self.level = level; self.lit = lit; self.feed = feed
    }

    /// Horn tips in the shipped 128 px head art (Mascot/heads, measured by make-mascot-assets.swift), as unit points.
    static func hornAnchors(_ pose: MascotPose) -> [UnitPoint] {
        switch pose {
        case .listen: [UnitPoint(x: 0.32, y: 0.14), UnitPoint(x: 0.68, y: 0.22)]
        case .talk: [UnitPoint(x: 0.32, y: 0.16), UnitPoint(x: 0.68, y: 0.17)]
        case .type: [UnitPoint(x: 0.34, y: 0.14), UnitPoint(x: 0.70, y: 0.18)]
        default: []
        }
    }

    public var body: some View {
        let artwork = NotchArt.mascot != nil
        ZStack {
            if lit && !artwork {
                // SF Symbol stand-in: one warm halo behind the microphone.
                LevelGlow(anchors: [], halo: true, size: size, level: level, animated: !reduceMotion, feed: feed)
            }
            // Only the pose swaps, as a short dissolve in place: the head itself never leaves.
            MascotGlyph(pose: pose, size: size)
                .id(pose)
                .transition(.opacity.animation(MouthyMotion.dissolve))
            if lit && artwork {
                LevelGlow(anchors: Self.hornAnchors(pose), halo: false, size: size, level: level, animated: !reduceMotion, feed: feed)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A short horizontal shake for results that need attention.
struct MouthyShake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 4 * sin(amount * .pi * 4), y: 0))
    }
}

/// The notch while dictating: the giraffe in the left wing, live level bars in the right wing, and below the
/// camera band the agent's question, then the live words (or "Listening · target").
struct DictationPill: View {
    let dictation: NotchDictation
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    /// The hub's live level, fed straight to the glow and bars; nil shows `dictation.level` (renders and tests).
    var voice: VoiceLevelFeed? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = DictationPillMetrics.size(for: dictation, notchHeight: notchHeight)
        let pose = DictationPillMetrics.pose(for: dictation)
        let prompt = DictationPillMetrics.hasPrompt(dictation) ? dictation.prompt : nil
        let partial = dictation.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 0) {
            // The camera band: content lives only in the two wings.
            HStack(spacing: 0) {
                MascotLevelGlyph(pose: pose, size: 20, level: dictation.level, lit: !dictation.transcribing, feed: voice)
                    .contentTransition(.opacity)
                    .id(pose)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                Spacer(minLength: notchWidth)
                LevelBars(level: dictation.level, busy: dictation.transcribing, feed: voice)
            }
            .padding(.horizontal, 22)
            .frame(height: notchHeight)

            VStack(alignment: .leading, spacing: 4) {
                if let prompt {
                    Text(prompt)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(MouthyTheme.cream)
                        .lineLimit(1).truncationMode(.tail)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
                if dictation.transcribing {
                    HStack(spacing: 6) {
                        Text("Finishing").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.glow)
                        if !partial.isEmpty {
                            Text(partial).font(.system(size: 13)).foregroundStyle(MouthyTheme.cream2)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                } else if partial.isEmpty {
                    Text(DictationPillMetrics.label(for: dictation))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(MouthyTheme.cream2)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(partial)
                        .font(.system(size: 13))
                        .foregroundStyle(MouthyTheme.cream)
                        .lineLimit(2).truncationMode(.head)
                        .contentTransition(.interpolate)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: partial)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: prompt == nil && partial.isEmpty ? .center : .leading)
            .padding(.horizontal, 24)
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
        .frame(width: size.width, height: size.height)
        .padding(.horizontal, DictationPillMetrics.shoulder)
        .background(NotchShape(bottomRadius: prompt == nil ? 22 : 26, shoulder: DictationPillMetrics.shoulder).fill(Color.black)
            .shadow(color: .black.opacity(0.3), radius: 7, y: 3))
        .animation(MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: reduceMotion), value: prompt != nil)
        .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: pose)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(prompt: prompt, partial: partial))
    }

    private func accessibilityText(prompt: String?, partial: String) -> String {
        var parts = [dictation.transcribing ? "Finishing for \(dictation.target)" : "Listening for \(dictation.target)"]
        if let prompt { parts.insert("Question: " + prompt, at: 0) }
        if !partial.isEmpty { parts.append(partial) }
        return parts.joined(separator: ". ")
    }
}

/// Live level bars, the same five (21.5 pt, fits the band's 40 pt ear) in the band and the grown pill, in the
/// mic-glow gradient, with a soft sweep while finishing. Frames are scheduled only while the pill is on screen and
/// listening or finishing (the pill exists only while dictating).
struct LevelBars: View {
    let level: Float
    let busy: Bool
    var bars = 5
    var feed: VoiceLevelFeed? = nil
    var body: some View {
        MouthyWaveform(level: busy ? 0 : level, active: !busy, bars: bars, height: 16, barWidth: 2.5, sweep: busy, feed: feed)
            .frame(height: 20)
    }
}

/// The outcome under the notch: the cheering giraffe and a drawn check for success, the sleepy giraffe and
/// an ember mark (with a shake) when something needs attention.
struct ResultPill: View {
    let text: String
    let ok: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @State private var appeared = false
    @State private var shakes: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = DictationPillMetrics.resultSize(notchHeight: notchHeight)
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 7) {
                MascotGlyph(pose: ok ? .cheer : .sleep, size: 20)
                ZStack {
                    if ok {
                        // One pink flourish ring as the check lands; it plays once.
                        Circle().strokeBorder(MouthyTheme.pink, lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                            .scaleEffect(appeared ? 1.7 : 0.6)
                            .opacity(appeared ? 0 : 0.9)
                    }
                    if appeared || reduceMotion {
                        Image(systemName: ok ? "checkmark" : "exclamationmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ok ? MouthyTheme.glow : MouthyTheme.ember)
                            .transition(.symbolEffect(.drawOn))
                    }
                }
                .frame(width: 16, height: 16)
                Text(text)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(ok ? MouthyTheme.cream : MouthyTheme.cream)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 4)
        }
        .frame(width: size.width, height: size.height)
        .padding(.horizontal, DictationPillMetrics.shoulder)
        .background(NotchShape(bottomRadius: 16, shoulder: DictationPillMetrics.shoulder).fill(Color.black)
            .shadow(color: .black.opacity(0.3), radius: 7, y: 3))
        .modifier(MouthyShake(amount: shakes))
        .sensoryFeedback(.success, trigger: appeared) { _, new in new && ok }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.6)) { appeared = true }
            if !ok && !reduceMotion { withAnimation(.easeOut(duration: 0.45)) { shakes += 1 } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
