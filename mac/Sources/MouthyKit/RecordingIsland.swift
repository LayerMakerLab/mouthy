import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch

/// Lifecycle of the island, driven by OverlayController.
@MainActor
final class IslandPresenter: ObservableObject {
    enum Outcome { case none, success, attention, neutral }
    @Published var presented = false
    @Published var outcome: Outcome = .none
    /// The outcome line, e.g. "Inserted · Notes".
    @Published var message = ""
    @Published var shakes = 0
}

/// The island's outline: flat top joined to the screen edge with small outward fillets (like the
/// hardware notch) and soft continuous bottom corners.
struct IslandShape: Shape {
    var width: CGFloat
    var radius: CGFloat? = nil
    var animatableData: CGFloat { get { width } set { width = newValue } }
    func path(in rect: CGRect) -> Path {
        let s = IslandGeometry.shoulder
        let w = max(width, 2 * s + 8)
        let h = rect.height
        let left = rect.midX - w / 2 + s, right = rect.midX + w / 2 - s
        let r = min(radius ?? h * 0.46, h * 0.5, (right - left) / 2)
        var p = Path()
        p.move(to: CGPoint(x: left - s, y: 0))
        p.addQuadCurve(to: CGPoint(x: left, y: s), control: CGPoint(x: left, y: 0))
        p.addLine(to: CGPoint(x: left, y: h - r))
        p.addCurve(to: CGPoint(x: left + r, y: h), control1: CGPoint(x: left, y: h - r * 0.45), control2: CGPoint(x: left + r * 0.45, y: h))
        p.addLine(to: CGPoint(x: right - r, y: h))
        p.addCurve(to: CGPoint(x: right, y: h - r), control1: CGPoint(x: right - r * 0.45, y: h), control2: CGPoint(x: right, y: h - r * 0.45))
        p.addLine(to: CGPoint(x: right, y: s))
        p.addQuadCurve(to: CGPoint(x: right + s, y: 0), control: CGPoint(x: right, y: 0))
        p.closeSubpath()
        return p
    }
}

/// What the island shows for a moment in a run. Pure, so the mapping is tested without a window.
struct IslandFace: Equatable {
    enum Trailing: Equatable { case waveform, sweep, check, attention, quiet }
    var pose: MascotPose
    /// Main line: a state word, the live words or the outcome.
    var label: String
    /// The agent's question (expanded state), or nil.
    var question: String?
    var trailing: Trailing
    /// The label is the live words rather than a state word.
    var live: Bool

    static let questionHint = "Speak, then press your shortcut · Escape cancels"

    static func make(phase: AppModel.Phase, liveText: String, agentQuestion: String?, outcome: IslandPresenter.Outcome, message: String) -> IslandFace {
        switch outcome {
        // Outcomes add no words: words that landed need none, and a problem is a small ember dot (the notch tab says what).
        case .success: return IslandFace(pose: .cheer, label: "", question: nil, trailing: .quiet, live: false)
        case .attention: return IslandFace(pose: .sleep, label: "", question: nil, trailing: .attention, live: false)
        case .neutral: return IslandFace(pose: .sleep, label: "", question: nil, trailing: .quiet, live: false)
        case .none: break
        }
        let words = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = agentQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let asking = !(question?.isEmpty ?? true) && [.preparing, .listening].contains(phase)
        switch phase {
        case .preparing:
            return IslandFace(pose: asking ? .talk : .listen, label: "", question: asking ? question : nil, trailing: .sweep, live: false)
        case .listening:
            return IslandFace(pose: asking ? .talk : .listen, label: words, question: asking ? question : nil, trailing: .waveform, live: !words.isEmpty)
        case .finishing, .delivering:
            return IslandFace(pose: .type, label: "", question: nil, trailing: .sweep, live: false)
        case .cancelling, .idle:
            return IslandFace(pose: .sleep, label: "", question: nil, trailing: .quiet, live: false)
        case .failed:
            return IslandFace(pose: .sleep, label: "", question: nil, trailing: .attention, live: false)
        }
    }
}

/// The recording island (used when the notch hub is off): the giraffe, the state or live words and the level
/// bars in one black capsule at the top edge (or a cocoa pill in a bottom corner). Nothing animates unless
/// it is presented.
struct RecordingIsland: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presenter: IslandPresenter
    let geometry: IslandGeometry
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasNotch: Bool { geometry.notchWidth > 0 }
    private var face: IslandFace {
        IslandFace.make(phase: model.phase, liveText: model.liveText, agentQuestion: model.agentQuestion, outcome: presenter.outcome, message: presenter.message)
    }
    private var expandedQuestion: Bool { presenter.presented && face.question != nil }
    /// The band is the whole island on a notched display: no second line (the notch tab shows the words, bigger).
    private var secondRow: Bool { false }

    private var width: CGFloat {
        guard presenter.presented else { return hasNotch ? geometry.notchWidth : 44 }
        if expandedQuestion { return geometry.restingWidth + IslandGeometry.questionGrowth }
        if presenter.outcome == .success { return geometry.restingWidth + IslandGeometry.successGrowth }
        return geometry.restingWidth + (hovering && model.busy ? IslandGeometry.hoverGrowth : 0)
    }
    private var height: CGFloat {
        guard presenter.presented else { return geometry.height }
        if expandedQuestion {
            // One or two lines of question (cream), then the one-line hint.
            let twoLines = (face.question?.count ?? 0) > (hasNotch ? 52 : 44)
            return geometry.height + (hasNotch ? (twoLines ? 54 : 38) : (twoLines ? 36 : 22))
        }
        if secondRow { return geometry.height + 24 }
        return geometry.height
    }
    private func motion(_ animation: Animation) -> Animation { MouthyMotion.resolve(animation, reduceMotion: reduceMotion) }

    var body: some View {
        let face = face
        ZStack(alignment: .top) {
            background
            content(face)
                .frame(width: max(0, width - (hasNotch ? 8 : 20)), height: height, alignment: .top)
                .opacity(presenter.presented ? 1 : 0)
        }
        .frame(width: geometry.floating ? width : width + 2 * IslandGeometry.shoulder, height: height)
        .offset(y: presenter.presented || hasNotch ? 0 : (geometry.floating ? geometry.height + 14 : -geometry.height - 4))
        .scaleEffect(geometry.floating && !presenter.presented ? 0.85 : 1)
        .padding(geometry.floating ? IslandGeometry.margin : 0)
        .frame(width: geometry.panel.width, height: geometry.panel.height, alignment: panelAlignment)
        .animation(motion(.spring(response: 0.46, dampingFraction: 0.8)), value: presenter.presented)
        .animation(motion(MouthyMotion.morph), value: width)
        .animation(motion(MouthyMotion.morph), value: height)
        .animation(motion(.spring(response: 0.32, dampingFraction: 0.78)), value: hovering)
        .sensoryFeedback(.success, trigger: presenter.outcome) { _, new in new == .success }
        .onHover { hovering = $0 }
        .onTapGesture { if model.phase == .listening { model.stop() } else if !model.busy { model.toggle(captureTarget: true) } }
        .contextMenu {
            if model.busy { Button("Cancel dictation") { model.cancel() }.disabled(model.phase == .delivering) }
            Text(model.status)
            Button("Open Mouthy") { model.selectedPage = "Dictate"; model.openWorkspace?() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(face))
        .accessibilityAddTraits(.isButton)
    }

    private var panelAlignment: Alignment {
        guard geometry.floating else { return .top }
        return geometry.corner == .bottomLeft ? .bottomLeading : .bottomTrailing
    }

    private func accessibilityText(_ face: IslandFace) -> String {
        if let question = face.question { return "Agent question: \(question). \(IslandFace.questionHint)" }
        if model.phase == .listening { return "Mouthy is listening. Click to finish." }
        return face.label.isEmpty ? "Mouthy" : "Mouthy: " + face.label
    }

    // MARK: Shape

    @ViewBuilder private var background: some View {
        if geometry.floating {
            // Bottom-corner pill: night cocoa with a warm lit rim, floating above the Dock.
            let shape = RoundedRectangle(cornerRadius: min(height / 2, 20), style: .continuous)
            shape.fill(MouthyTheme.night)
                .overlay(shape.fill(LinearGradient(colors: [MouthyTheme.cream.opacity(0.06), .clear], startPoint: .top, endPoint: .center)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [MouthyTheme.glow.opacity(0.32), MouthyTheme.hoof.opacity(0.6)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(presenter.presented ? 0.45 : 0), radius: 12, y: 5)
                .shadow(color: MouthyTheme.orange.opacity(presenter.presented && model.phase == .listening ? 0.18 : 0), radius: 16)
        } else {
            IslandShape(width: width + 2 * IslandGeometry.shoulder, radius: height > geometry.height ? 18 : nil)
                .fill(.black)
                .frame(height: height)
                .overlay(alignment: .bottom) {
                    // A faint warm rim along the bottom edge so the island reads on dark menu bars too.
                    IslandShape(width: width + 2 * IslandGeometry.shoulder, radius: height > geometry.height ? 18 : nil)
                        .stroke(LinearGradient(colors: [.clear, MouthyTheme.glow.opacity(presenter.presented ? 0.16 : 0)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: min(0.9, geometry.height / max(height, 1)))], startPoint: .top, endPoint: .bottom))
                }
                .shadow(color: .black.opacity(presenter.presented && !hasNotch ? 0.28 : 0), radius: 6, y: 2)
        }
    }

    // MARK: Content

    @ViewBuilder private func content(_ face: IslandFace) -> some View {
        Group {
            if let question = face.question {
                questionContent(face, question: question)
            } else if hasNotch {
                VStack(spacing: 0) {
                    // Giraffe in the left wing, bars in the right wing; the camera area stays clear.
                    HStack(spacing: 0) {
                        leading(face)
                        Spacer(minLength: geometry.notchWidth)
                        trailing(face)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: geometry.height)
                    if secondRow {
                        label(face, size: 12.5)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 14)
                            .frame(height: 22, alignment: .center)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
            } else if face.trailing == .check {
                // Success reads left to right: the cheering giraffe, the drawn check, then where it went.
                HStack(spacing: 7) {
                    leading(face)
                    trailing(face, compact: true)
                    label(face, size: 13)
                        .layoutPriority(1)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .frame(height: geometry.height)
            } else {
                HStack(spacing: 9) {
                    leading(face)
                    label(face, size: 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing(face)
                }
                .padding(.horizontal, 6)
                .frame(height: geometry.height)
            }
        }
        .animation(motion(MouthyMotion.pose), value: presenter.outcome)
        .animation(motion(MouthyMotion.pose), value: face.pose)
    }

    /// Expanded agent question: the talking giraffe, the question in cream (two lines) and how to answer.
    private func questionContent(_ face: IslandFace, question: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasNotch {
                HStack(spacing: 0) {
                    leading(face)
                    Spacer(minLength: geometry.notchWidth)
                    trailing(face)
                }
                .padding(.horizontal, 6)
                .frame(height: geometry.height)
            }
            HStack(alignment: .top, spacing: 9) {
                if !hasNotch { leading(face).padding(.top, 2) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(question)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(MouthyTheme.cream)
                        .lineLimit(2).truncationMode(.tail)
                    Text(IslandFace.questionHint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(MouthyTheme.cream2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !hasNotch { trailing(face).padding(.top, 2) }
            }
            .padding(.horizontal, hasNotch ? 14 : 6)
            .padding(.top, hasNotch ? 0 : 8)
        }
        .transition(.opacity)
    }

    /// Left: the time counting up while dictating.
    @ViewBuilder private func leading(_ face: IslandFace) -> some View {
        ZStack {
            if model.busy && presenter.outcome == .none {
                ElapsedTimeView(clock: model.clock) { elapsed in
                    Text(DictateHero.clock(elapsed)).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(MouthyTheme.cream2)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 30, height: 22)
    }

    /// Main line: state word, the newest live words (whole words only, after "…") or the outcome.
    private func label(_ face: IslandFace, size: CGFloat) -> some View {
        if face.live {
            // The longest run of whole trailing words that fits the line: never a word cut in half.
            return AnyView(ViewThatFits(in: .horizontal) {
                liveLine(TextTail.lastWords(face.label, maxCharacters: 60), size: size)
                liveLine(TextTail.lastWords(face.label, maxCharacters: 44), size: size)
                liveLine(TextTail.lastWords(face.label, maxCharacters: 32), size: size)
                liveLine(TextTail.lastWords(face.label, maxCharacters: 24), size: size)
                liveLine(TextTail.lastWords(face.label, maxCharacters: 18), size: size)
                liveLine(TextTail.lastWords(face.label, maxCharacters: 12), size: size)
                liveLine(TextTail.lastWords(face.label, maxCharacters: 8), size: size)
            }
            .frame(maxWidth: .infinity, alignment: hasNotch ? .center : .leading))
        }
        let text: String
        text = face.label
        return AnyView(Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(labelColor(face))
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.interpolate)
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: text))
    }

    private func liveLine(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .regular, design: .rounded))
            .foregroundStyle(MouthyTheme.cream)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func labelColor(_ face: IslandFace) -> Color {
        switch presenter.outcome {
        case .success: MouthyTheme.cream
        case .attention: MouthyTheme.cream
        case .neutral: MouthyTheme.cream2
        case .none: face.live ? MouthyTheme.cream : MouthyTheme.cream2
        }
    }

    /// Right: the level bars, a glow sweep while finishing, then a drawn check or an ember mark.
    @ViewBuilder private func trailing(_ face: IslandFace, compact: Bool = false) -> some View {
        Group {
            switch face.trailing {
            case .check:
                ZStack {
                    Circle().strokeBorder(MouthyTheme.pink, lineWidth: 1.2).frame(width: 16, height: 16)
                        .scaleEffect(presenter.outcome == .success ? 1.6 : 0.6)
                        .opacity(presenter.outcome == .success ? 0 : 0.9)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: presenter.outcome)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MouthyTheme.glow)
                        .transition(.symbolEffect(.drawOn))
                }
            case .attention:
                Circle().fill(MouthyTheme.ember).frame(width: 6, height: 6)
                    .transition(.opacity)
            case .quiet:
                Color.clear
            case .waveform, .sweep:
                MouthyWaveform(level: 0, active: presenter.presented && face.trailing == .waveform,
                               bars: 13, height: 16, barWidth: 2.2,
                               sweep: presenter.presented && face.trailing == .sweep, feed: model.voice)
                    .transition(.opacity)
            }
        }
        .frame(width: compact ? 18 : Self.barsWidth, height: 22, alignment: .center)
    }

    /// Width of 13 bars at 2.2 pt with 2 pt gaps.
    static let barsWidth: CGFloat = 13 * 2.2 + 12 * 2
}

/// A short horizontal shake for results that need attention.
struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 4 * sin(amount * .pi * 4), y: 0))
    }
}
