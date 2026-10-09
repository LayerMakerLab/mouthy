import SwiftUI
import AppKit

/// The hardware notch, grown: black, with concave shoulders where it meets the top edge of the screen
/// and continuous rounded corners at the bottom.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat = 0
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulder) }
        set { bottomRadius = newValue.first; shoulder = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 4), r = min(bottomRadius, (rect.width - 2 * s) / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s), control: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s + r, y: rect.maxY), control: CGPoint(x: rect.minX + s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r), control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - s, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Content that shows only where the shape already covers it. `progress` runs with the shape's own spring (0 where
/// the shape starts, 1 where it ends), so nothing is ever drawn at its final place while the edge is still moving
/// across it: the opacity ramps from `from` to `to`, and `drop` lets content ride a band that grows down from the
/// menu bar's edge instead of waiting for it.
struct ShapeReveal: ViewModifier, Animatable {
    var progress: Double
    let from: Double
    let to: Double
    var drop: CGFloat = 0
    var animatableData: Double { get { progress } set { progress = newValue } }
    static func opacity(_ progress: Double, from: Double, to: Double) -> Double {
        min(1, max(0, (progress - from) / max(0.01, to - from)))
    }
    func body(content: Content) -> some View {
        content
            .opacity(Self.opacity(progress, from: from, to: to))
            .offset(y: -drop * CGFloat(1 - min(1, max(0, progress))))
    }
}

extension AnyTransition {
    /// Shows (and hides) content in step with the shape's spring: see `ShapeReveal`.
    static func reveal(from: Double, to: Double, drop: CGFloat = 0) -> AnyTransition {
        .modifier(active: ShapeReveal(progress: 0, from: from, to: to, drop: drop),
                  identity: ShapeReveal(progress: 1, from: from, to: to, drop: drop))
    }
}

/// Notch chrome on the giraffe palette. The shape itself stays pure black (it blends with the hardware);
/// only light, rims and accents are warm. The names are the old roles, kept for host apps.
public enum NotchPalette {
    /// Bright highlight (mic-glow high).
    public static let shine = MouthyTheme.glowHi
    /// The accent: rings, glow, live states (mic glow).
    public static let silver = MouthyTheme.glow
    /// Quiet secondary ink (cream 2).
    public static let graphite = MouthyTheme.cream2
    public static let ember = MouthyTheme.ember
    /// Warm polished fill: glow high, giraffe orange, amber patch.
    public static let metal = MouthyTheme.metal
    /// Vertical bars and progress: glow high fading to giraffe orange.
    public static let sheen = LinearGradient(colors: [MouthyTheme.glowHi, MouthyTheme.orange], startPoint: .top, endPoint: .bottom)
    // Old names kept so existing views compile against the new look.
    static let copper = silver
    static let amber = shine
}

/// What the notch is showing, in priority order. Each state has one size; the single black shape morphs
/// between them.
enum NotchStage: Equatable {
    case rest, compact, open, dictation(prompt: Bool), result, peek
}

/// Sizes, shoulders and corner radii for each stage (spec section 7).
enum NotchMetrics {
    static let dictationSize = CGSize(width: 420, height: 46)
    static let promptSize = CGSize(width: 460, height: 70)
    static let resultSize = CGSize(width: 340, height: 30)
    static let peekWidth: CGFloat = 380

    /// The shape's size for a stage. `extra` heights are below the notch; `measured` is the live content's
    /// own size, which wins when it is larger so content is never cut off.
    static func size(for stage: NotchStage, notchHeight: CGFloat, rest: CGSize, compactWidth: CGFloat,
                     panel: CGSize, measured: CGSize = .zero) -> CGSize {
        func fit(_ base: CGSize) -> CGSize {
            CGSize(width: max(base.width, measured.width), height: max(notchHeight + base.height, measured.height))
        }
        switch stage {
        case .rest: return rest
        case .compact: return CGSize(width: compactWidth, height: notchHeight)
        case .open: return CGSize(width: panel.width + 2 * MorphingNotch.openShoulder, height: panel.height)
        case .dictation(let prompt): return fit(prompt ? promptSize : dictationSize)
        case .result: return fit(resultSize)
        case .peek: return CGSize(width: max(peekWidth, measured.width), height: max(notchHeight + 50, measured.height))
        }
    }

    static func shoulder(for stage: NotchStage) -> CGFloat {
        switch stage {
        case .rest: 0
        case .compact: MorphingNotch.restShoulder
        case .open: MorphingNotch.openShoulder
        case .dictation, .result, .peek: 9
        }
    }

    static func bottomRadius(for stage: NotchStage) -> CGFloat {
        switch stage {
        case .rest, .compact: 12
        case .open: 30
        case .dictation(let prompt): prompt ? 24 : 20
        case .result: 16
        case .peek: 24
        }
    }
}

struct NotchRootView: View {
    @ObservedObject var hub: NotchHub
    /// Renders and tests: a display to draw for when the hub has no panel.
    var geometryOverride: NotchGeometry?

    var body: some View {
        let geometry = geometryOverride ?? hub.geometry
        GeometryReader { proxy in
            // The window is always the open panel's size (it never resizes, so nothing can jump); the notch
            // itself is one shape that springs between its resting size and every other state.
            let margin = NotchGeometry.shadowMargin
            let panel = CGSize(width: max(0, proxy.size.width - 2 * margin), height: max(0, proxy.size.height - margin))
            MorphingNotch(hub: hub, geometry: geometry, panel: panel)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .tint(MouthyTheme.orange)
    }
}

/// One black shape that springs between the resting notch, the open panel, the dictation pill, a peek
/// card and a result line, like the Dynamic Island. Open content is laid out at its final size and
/// revealed by the growing shape, so nothing reflows.
struct MorphingNotch: View {
    @ObservedObject var hub: NotchHub
    let geometry: NotchGeometry?
    let panel: CGSize
    static let restShoulder: CGFloat = 6
    static let openShoulder: CGFloat = 14
    /// The live content's own size, kept per stage so one state's size never leaks into the next.
    @State private var measure = Measure(stage: .rest, size: .zero)
    @State private var lastStage: NotchStage = .rest
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var notchHeight: CGFloat { geometry?.notchHeight ?? 32 }
    /// Room the pills leave for the camera.
    private var cameraWidth: CGFloat { geometry?.cameraWidth ?? NotchGeometry.cameraWidth(notchWidth: 0) }
    private var hasNotch: Bool { (geometry?.notchWidth ?? 0) > 0 }

    /// Dictation comes first: it is the one surface while it runs, whatever was showing before. While the hub moves
    /// to another display the shape first springs back to rest, so it never jumps across.
    var stage: NotchStage {
        if hub.hopping { return .rest }
        if let dictation = hub.dictation, !(hub.isOpen && hub.opensDuringDictation) {
            return .dictation(prompt: dictation.prompt?.isEmpty == false)
        }
        if hub.isOpen { return .open }
        if hub.peekView != nil { return .peek }
        if hub.result != nil { return .result }
        // At rest: the music (or timer) ears around the camera, or the pill on a display without a notch.
        if hasNotch ? hub.compactTab != nil : hub.pillShown { return .compact }
        return .rest
    }

    /// Dictation, results and peeks stay inside the wings the music ears use, so nothing live ever covers more of the
    /// menu bar. Words that must be read (an agent's question, an outcome that needs the person) grow the band down,
    /// never wider. Only a peek opens into its card, and only while hovered.
    func inBand(_ stage: NotchStage) -> Bool {
        guard Self.measures(stage) else { return false }
        return !(stage == .peek && hub.liveExpanded)
    }

    var body: some View {
        let _ = hub.revision
        let stage = self.stage
        let band = inBand(stage)
        let leftOnly = band && stage == .peek && !hub.peekHasTrailing
        let size = shapeSize(for: stage, measured: measured(for: stage))
        let shape = band ? NotchShape(bottomRadius: NotchMetrics.bottomRadius(for: .compact), shoulder: NotchMetrics.shoulder(for: .compact))
            : NotchShape(bottomRadius: NotchMetrics.bottomRadius(for: stage), shoulder: NotchMetrics.shoulder(for: stage))
        ZStack(alignment: .top) {
            shape.fill(Color.black)
                // Blur + offset stay well inside the window's 30 pt margin, so the shadow fades out instead of
                // being cut off in a straight line at the window edge (which read as a faint box).
                .shadow(color: .black.opacity(stage == .open ? 0.35 : stage == .rest || stage == .compact || band ? 0 : 0.3),
                        radius: stage == .open ? 10 : 7, y: stage == .open ? 4 : 3)
            ZStack(alignment: .top) { content(for: stage, size: size) }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // Keeps the camera centred while only the left side has grown.
        .offset(x: leftOnly ? -NotchGeometry.compactSide / 2 : 0)
        .animation(animation(for: stage), value: StageKey(stage: stage, size: size, band: band))
        .onChange(of: stage) { _, next in lastStage = next }
        // The stage the hub first shows (music already playing, say) is where the first change starts from.
        .onAppear { lastStage = stage }
        .onHover { if stage == .open { hub.hover($0) } }
    }

    private struct StageKey: Equatable { let stage: NotchStage; let size: CGSize; let band: Bool }

    /// The shape's size for `stage`. Every closed state shares the compact band, so crowded menu bars keep their
    /// items and moving from music to dictation to a result never jumps wider. A peek with nothing for the right
    /// ear grows on the left only.
    func shapeSize(for stage: NotchStage, measured: CGSize = .zero) -> CGSize {
        let band = geometry?.closedWide.width ?? cameraWidth + 2 * NotchGeometry.compactSide
        if inBand(stage) {
            let leftOnly = stage == .peek && !hub.peekHasTrailing
            return CGSize(width: leftOnly ? cameraWidth + NotchGeometry.compactSide : band,
                          height: notchHeight + noteHeight(stage, width: band - 2 * Self.restShoulder))
        }
        // Without a notch the shape rests as a band with no height, so it drops down from the menu bar's edge.
        let rest = hasNotch ? CGSize(width: geometry?.notchWidth ?? 0, height: notchHeight) : CGSize(width: cameraWidth, height: 0)
        let compact = hasNotch ? band : geometry?.pill(wide: hub.pillWide).width ?? band
        return NotchMetrics.size(for: stage, notchHeight: notchHeight, rest: rest, compactWidth: compact,
                                 panel: panel, measured: measured)
    }

    /// The line under the band that says what an outcome needing attention is ("Copied · paste it yourself").
    static let noteHeight: CGFloat = 24
    static let noteFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// Room an agent's question gets under the band: up to three lines, wrapped to the band's width.
    static let promptLines = 3
    static let promptPadding: CGFloat = 14

    /// Only an agent's question grows the band down (its own height, up to three lines), never wider. Outcomes add no words.
    private func noteHeight(_ stage: NotchStage, width: CGFloat) -> CGFloat {
        switch stage {
        case .dictation(prompt: true): return Self.promptHeight(hub.dictation?.prompt ?? "", width: width)
        default: return 0
        }
    }

    /// The height an agent's question needs under the band at `width` (the band less its padding), capped at three lines.
    static func promptHeight(_ prompt: String, width: CGFloat) -> CGFloat {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }
        let line = ceil(noteFont.ascender - noteFont.descender + noteFont.leading) + 1
        let bounds = (text as NSString).boundingRect(with: NSSize(width: width - 2 * promptPadding, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: noteFont])
        let lines = min(CGFloat(promptLines), max(1, (ceil(bounds.height) / line).rounded()))
        return lines * line + 10
    }

    /// Whether `title` fits whole in the band's right ear (40 pt less the ears' padding) at 11 pt semibold rounded.
    static func titleFits(_ title: String) -> Bool {
        guard !title.isEmpty else { return false }
        let base = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11) } ?? base
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        return width <= NotchGeometry.compactSide - restShoulder - 6
    }
    struct Measure: Equatable { var stage: NotchStage; var size: CGSize }

    private func measured(for stage: NotchStage) -> CGSize {
        Self.measures(stage) && measure.stage == stage ? measure.size : .zero
    }

    /// Opening springs open, closing springs back, everything else morphs: always one spring, never a wait, because
    /// the old content has already left (see `contentTransition`).
    private func animation(for stage: NotchStage) -> Animation {
        let chosen: Animation = stage == .open ? MouthyMotion.notchOpen
            : lastStage == .open ? MouthyMotion.notchClose
            : lastStage == .rest && stage != .rest ? MouthyMotion.grow
            : MouthyMotion.morph
        return MouthyMotion.resolve(chosen, reduceMotion: reduceMotion)
    }

    private static func measures(_ stage: NotchStage) -> Bool {
        switch stage { case .dictation, .result, .peek: true; default: false }
    }

    /// Every state's content cross-dissolves in place in 100 ms, starting at once: the new state shows on the first
    /// frame (no empty band between two states), and the old one is gone before the moving edge can cut it. One
    /// shape, one layer of content.
    static let contentTransition = AnyTransition.opacity.animation(MouthyMotion.dissolve)
    private var stateTransition: AnyTransition { Self.contentTransition }

    @ViewBuilder private func content(for stage: NotchStage, size: CGSize) -> some View {
        if inBand(stage) {
            bandContent(for: stage, size: size)
            // Its own layer, so it reveals with the shape's bottom edge whichever way the band arrives.
            if let line = bandLine(stage) {
                BandLine(text: line.text, question: line.question, width: size.width - 2 * Self.restShoulder, notchHeight: notchHeight)
                    .transition(LiveBand.lineReveal)
            }
        } else {
            fullContent(for: stage, size: size)
        }
    }

    /// The words under the band that must be read: an agent's question while dictating.
    private func bandLine(_ stage: NotchStage) -> (text: String, question: Bool)? {
        switch stage {
        case .dictation(prompt: true):
            let prompt = hub.dictation?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return prompt.isEmpty ? nil : (prompt, true)
        default:
            return nil
        }
    }

    /// The live state as two small ears beside the camera, inside the menu-bar band.
    @ViewBuilder private func bandContent(for stage: NotchStage, size: CGSize) -> some View {
        let width = size.width - 2 * Self.restShoulder
        // The ears sit in the wings on every display: beside the camera, or where it would be without a notch, so
        // the band reads the same everywhere and nothing is ever drawn under the camera housing.
        let notchWidth = cameraWidth
        Group {
            switch stage {
            case .dictation, .result:
                // One view from the first word to the outcome, so the giraffe never leaves its ear.
                LiveBand(hub: hub, width: width, height: size.height, notchHeight: notchHeight, notchWidth: notchWidth)
            case .peek:
                let leading = hub.peekEars.leading ?? AnyView(MascotGlyph(pose: .cheer, size: 18))
                // A cut word beside the camera reads worse than the leading glyph standing alone.
                if hub.peekHasTrailing {
                    BandEars(width: width, height: size.height, notchWidth: notchWidth) {
                        leading
                    } trailing: {
                        hub.peekEars.trailing ?? AnyView(Text(hub.peekTitle).fixedSize())
                    }
                } else {
                    // Only the left ear: the glyph centred in it, the right side kept at the notch's own edge.
                    HStack(spacing: 0) {
                        leading.frame(width: NotchGeometry.compactSide - Self.restShoulder)
                        Spacer(minLength: 0)
                    }
                    .frame(width: width, height: size.height)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(hub.peekTitle)
                }
            default:
                EmptyView()
            }
        }
        // Growing out of the bare notch, the ears show only once the wings cover them (and ride the band down from
        // the menu bar's edge on a display without a notch); shrinking back, they are gone before the edge arrives.
        // From another live state the shape stays put and the ears dissolve in place.
        .transition(restingTransition(size: size))
    }

    /// Ears (live or resting) coming and going: revealed with the wings when they grow out of the bare notch,
    /// dissolved in place from another state, and gone before a shrinking edge reaches them.
    private func restingTransition(size: CGSize) -> AnyTransition {
        .asymmetric(insertion: lastStage == .rest ? earReveal(size: size) : Self.contentTransition, removal: earReveal(size: size))
    }

    /// The ears' reveal for a band of `size` growing out of the resting shape: their opacity follows the shape's own
    /// spring and reaches them only when the wings have grown past their outer edge.
    private func earReveal(size: CGSize) -> AnyTransition {
        let rest = shapeSize(for: .rest)
        let growth = (size.width - rest.width) / 2
        let drop = max(0, notchHeight - rest.height)
        let from = Self.earRevealStart(growth: growth)
        return .reveal(from: from, to: min(1, from + 0.1), drop: drop)
    }

    /// The spring progress from which wings growing by `growth` on each side cover the ears. The widest ear content
    /// (22 pt) sits centred in its 40 pt wing, so this far in from the wing's straight edge; that edge sits
    /// (1 - p) × growth + p × shoulder in from the shape's final edge (the shoulder grows from the resting notch's 0).
    /// One point to spare.
    static func earRevealStart(growth: CGFloat) -> Double {
        let inset = (NotchGeometry.compactSide - restShoulder - LiveBand.earSlot) / 2
        guard growth > restShoulder + 1 else { return 0 }
        return Double(min(0.9, max(0, (growth - restShoulder - inset + 1) / (growth - restShoulder))))
    }

    @ViewBuilder private func fullContent(for stage: NotchStage, size: CGSize) -> some View {
        switch stage {
        case .open:
            // The panel is there as it springs open. Springing closed, its content fades within the spring's first few
            // frames, before the shrinking edge can reach any of it.
            OpenLayers(hub: hub, notchHeight: notchHeight, notchWidth: geometry?.notchWidth ?? 0, size: size)
                .transition(.asymmetric(insertion: .identity, removal: .reveal(from: 0.85, to: 1)))
        case .dictation(let prompt):
            if let dictation = hub.dictation {
                measuring(stage, width: (prompt ? NotchMetrics.promptSize : NotchMetrics.dictationSize).width) {
                    DictationPill(dictation: dictation, notchWidth: cameraWidth, notchHeight: notchHeight, voice: hub.voice)
                }
                .transition(stateTransition)
            }
        case .result:
            if let result = hub.result {
                measuring(stage, width: NotchMetrics.resultSize.width) {
                    ResultPill(text: result.text, ok: result.ok, notchWidth: cameraWidth, notchHeight: notchHeight)
                }
                .transition(stateTransition)
            }
        case .peek:
            if let peek = hub.peekView {
                measuring(stage, width: NotchMetrics.peekWidth) {
                    PeekCard(content: peek, notchWidth: cameraWidth, notchHeight: notchHeight)
                }
                .transition(stateTransition)
            }
        case .compact:
            if !hasNotch {
                PillContent(hub: hub, width: size.width - 2 * Self.restShoulder, height: size.height)
                    .transition(restingTransition(size: size))
            } else if let tab = hub.compactTab, let trailing = tab.compactBody() {
                RestingContent(tab: tab, trailing: trailing, width: size.width - 2 * Self.restShoulder, height: size.height, notchWidth: geometry?.notchWidth ?? 0) {
                    hub.show(tabID: tab.id)
                }
                .transition(restingTransition(size: size))
            }
        case .rest:
            EmptyView()
        }
    }

    /// Lays live content out at the stage's width (taller if it needs to be) and reports its real size, so
    /// the shape grows to fit instead of cutting it off.
    private func measuring<Content: View>(_ stage: NotchStage, width: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        let known = measured(for: stage)
        return content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if measure.stage != stage || abs(size.width - measure.size.width) > 0.5 || abs(size.height - measure.size.height) > 0.5 {
                    measure = Measure(stage: stage, size: size)
                }
            }
            .frame(width: max(width, known.width))
    }
}

/// Dictation, finishing and the outcome as one quiet view in the two wings: the time counting up on the left, the level
/// bars on the right (a soft sweep while finishing). An outcome adds no words: a check for a tab's notice, a small
/// ember dot when something needs the person (the Mouthy tab says what). Only the part that changes dissolves.
struct LiveBand: View {
    @ObservedObject var hub: NotchHub
    let width: CGFloat
    let height: CGFloat
    let notchHeight: CGFloat
    let notchWidth: CGFloat

    /// Each ear's one slot, as wide as the widest thing it holds (the level bars; the time at 10 pt fits too).
    static let earSlot: CGFloat = 22
    /// The line under the band grows in with the shape: it shows only once the shape's bottom edge has passed it
    /// (its lowest pixels sit at about 85% of the growth), and leaves before the edge comes back up to it.
    static let lineReveal = AnyTransition.reveal(from: 0.88, to: 0.98)

    var body: some View {
        let dictation = hub.dictation
        let result = dictation == nil ? hub.result : nil
        let prompt = dictation?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = prompt?.isEmpty == false ? prompt : nil
        BandEars(width: width, height: notchHeight, notchWidth: notchWidth) {
            ZStack {
                if let start = dictation?.startedAt {
                    Text(start, style: .timer)
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(MouthyTheme.cream2)
                        .fixedSize()
                        .transition(MorphingNotch.contentTransition)
                }
            }
            .frame(width: Self.earSlot, height: 20)
        } trailing: {
            ZStack {
                if let dictation {
                    LevelBars(level: dictation.level, busy: dictation.transcribing, feed: hub.voice)
                        .transition(MorphingNotch.contentTransition)
                } else if let result {
                    Group {
                        if result.ok {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(MouthyTheme.glow)
                        } else {
                            Circle().fill(MouthyTheme.ember).frame(width: 6, height: 6)
                        }
                    }
                    .transition(MorphingNotch.contentTransition)
                }
            }
            .frame(width: Self.earSlot, height: 20)
        }
        .frame(width: width, height: height, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(dictation.map { (($0.transcribing ? "Finishing for " : "Listening for ") + $0.target)
                                            + (question.map { ". Question: " + $0 } ?? "") } ?? result?.text ?? "")
    }
}

/// The words under the band that must be read: an agent's question (up to three lines) or what an outcome needs the
/// person to do, on one line.
struct BandLine: View {
    let text: String
    let question: Bool
    let width: CGFloat
    let notchHeight: CGFloat
    var body: some View {
        Group {
            if question {
                Text(text)
                    .font(Font(MorphingNotch.noteFont))
                    .multilineTextAlignment(.center)
                    .lineLimit(MorphingNotch.promptLines).truncationMode(.tail)
                    .padding(.horizontal, MorphingNotch.promptPadding)
            } else {
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.85).truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .frame(height: MorphingNotch.noteHeight)
            }
        }
        .foregroundStyle(MouthyTheme.cream)
        .frame(width: width, alignment: .top)
        .padding(.top, notchHeight)
        .accessibilityHidden(true)
    }
}

/// Small live content in the two wings beside the camera, never taller than the menu bar.
struct BandEars<Leading: View, Trailing: View>: View {
    let width: CGFloat
    let height: CGFloat
    let notchWidth: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    var body: some View {
        // Each ear is centred in its wing, the same slots the resting music or timer ears use, so going from one to
        // the other is a dissolve in place.
        HStack(spacing: 0) {
            leading.frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            trailing.font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(MouthyTheme.cream)
        .frame(width: width, height: height)
        .accessibilityElement(children: .combine)
    }
}

/// Cover on one wing, live content on the other, the camera between them.
struct RestingContent: View {
    let tab: any NotchTab
    let trailing: AnyView
    let width: CGFloat
    let height: CGFloat
    let notchWidth: CGFloat
    let open: () -> Void
    var body: some View {
        // Each ear centred in its wing: the same two slots dictation and its outcome use (`BandEars`), so the
        // cover and the giraffe, the music bars and the level bars, swap in place.
        HStack(spacing: 0) {
            Group {
                if let leading = tab.compactLeading() { leading }
                else { Text(Image(systemName: tab.symbolName)).font(.caption.weight(.semibold)).foregroundStyle(MouthyTheme.glow) }
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            trailing.font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(MouthyTheme.cream)
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(tab.title)")
    }
}

/// Everything inside the open panel: hairline rim, status line, tab rail and the selected tab.
struct OpenLayers: View {
    @ObservedObject var hub: NotchHub
    let notchHeight: CGFloat
    let notchWidth: CGFloat
    let size: CGSize
    @Namespace private var rail
    @State private var railIn = false
    @State private var bodyIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shoulder = MorphingNotch.openShoulder

    var body: some View {
        let _ = hub.revision
        let tabs = hub.orderedTabs
        let selected = hub.selectedID.flatMap { hub.tab($0) }
        let shape = NotchShape(bottomRadius: 30, shoulder: shoulder)
        ZStack(alignment: .top) {
            // Plain black like the closed notch, with only a hairline edge below the camera band.
            NotchRim(shape: shape, notchHeight: notchHeight, height: size.height)
            // The band beside the camera: tabs on the left, status on the right. No separate
            // tab row, so the open notch stays small.
            HStack(spacing: 0) {
                TabRail(tabs: tabs, selectedID: hub.selectedID, namespace: rail, compact: true) { hub.select($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: railIn ? 0 : -4)
                Color.clear.frame(width: max(notchWidth, 60))
                // The right wing names the selected tab, then the host's status: "Timers · 82%". The band then
                // reads left to right, icons to title, and the wing is not left holding a lone number.
                HStack(spacing: 5) {
                    if let selected {
                        Text(selected.title)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(MouthyTheme.cream)
                            .lineLimit(1).fixedSize()
                            .layoutPriority(1)
                            .contentTransition(.opacity)
                            .id(selected.id)
                    }
                    // The title always wins: the status shows whole, in its shorter form, or not at all.
                    if let status = hub.headerTrailing ?? hub.headerLeading {
                        ViewThatFits(in: .horizontal) {
                            statusLine(status, dot: selected != nil, short: false)
                            statusLine(status, dot: selected != nil, short: true)
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                }
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(MouthyTheme.cream2)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .animation(MouthyMotion.resolve(MouthyMotion.morph, reduceMotion: reduceMotion), value: selected?.id)
            }
            .frame(height: notchHeight)
            .padding(.horizontal, 14 + shoulder)
            .opacity(railIn ? 1 : 0)
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if let tab = selected {
                        tab.makeBody()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .id(tab.id)
                            .transition(.asymmetric(insertion: .modifier(active: TabSlide(hub: hub, phase: 1), identity: TabSlide(hub: hub, phase: 0)),
                                                    removal: .modifier(active: TabSlide(hub: hub, phase: -1), identity: TabSlide(hub: hub, phase: 0))))
                    } else {
                        VStack(spacing: 8) {
                            MascotGlyph(pose: .sleep, size: 36)
                            Text("Nothing here yet").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(MouthyTheme.cream2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(MouthyMotion.resolve(MouthyMotion.tab, reduceMotion: reduceMotion), value: hub.selectedID)
                .opacity(bodyIn ? 1 : 0)
                .blur(radius: bodyIn || reduceMotion ? 0 : 6)
                .scaleEffect(bodyIn || reduceMotion ? 1 : 0.985, anchor: .top)
            }
            .padding(.top, notchHeight + 10)
            .padding(.horizontal, 20 + shoulder)
            .padding(.bottom, 14)
            // A tab taller than the panel is cut at the bottom; it never pushes the band out of the camera row.
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .foregroundStyle(MouthyTheme.cream)
        .onAppear {
            withAnimation(MouthyMotion.resolve(MouthyMotion.notchOpen.delay(0.06), reduceMotion: reduceMotion)) { railIn = true }
            withAnimation(MouthyMotion.resolve(MouthyMotion.notchOpen.delay(0.10), reduceMotion: reduceMotion)) { bodyIn = true }
        }
    }
}

extension OpenLayers {
    /// The host's status after the title, whole or (`short`) without its extras.
    private func statusLine(_ status: () -> AnyView, dot: Bool, short: Bool) -> some View {
        StatusLine(status: status(), dot: dot).environment(\.notchStatusShort, short)
    }
}

/// A "·" and the status, the dot only once the status draws something, so a tab without a status of its own
/// shows its title alone instead of "Weather ·".
private struct StatusLine: View {
    let status: AnyView
    let dot: Bool
    @State private var drawn = false
    var body: some View {
        HStack(spacing: 5) {
            if dot && drawn { Text("·").foregroundStyle(MouthyTheme.cream2.opacity(0.7)) }
            status.fixedSize()
                .onGeometryChange(for: Bool.self) { $0.size.width > 0.5 } action: { drawn = $0 }
        }
    }
}

/// Tab content slides the way the selection moved: in from `dir * 24` with a blur, out to `-dir * 24`.
/// Reads the hub's live direction, so the leaving page goes the right way even though it was drawn before
/// the selection changed.
struct TabSlide: ViewModifier {
    @ObservedObject var hub: NotchHub
    /// 0 at rest, 1 arriving, -1 leaving.
    let phase: CGFloat
    func body(content: Content) -> some View {
        let direction = CGFloat(hub.selectionDirection)
        content
            .offset(x: phase * direction * 24)
            .opacity(phase == 0 ? 1 : 0)
            .blur(radius: phase > 0 ? 5 : 0)
    }
}

/// Clear from the top of the panel down to the bottom of the camera band, then fading in over 24 pt, so
/// strokes never draw a hairline along the top edge of the screen.
struct BelowNotchMask: View {
    let notchHeight: CGFloat
    let height: CGFloat
    var body: some View {
        let start = min(1, max(0, notchHeight / max(height, 1)))
        let end = min(1, (notchHeight + 24) / max(height, 1))
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: start),
                               .init(color: .black, location: end), .init(color: .black, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// The hairline rim: faint warm light, brightest along the bottom edge.
struct NotchRim: View {
    let shape: NotchShape
    let notchHeight: CGFloat
    let height: CGFloat
    var body: some View {
        shape.stroke(LinearGradient(colors: [MouthyTheme.glow.opacity(0), MouthyTheme.glow.opacity(0.06), MouthyTheme.glow.opacity(0.16)],
                                    startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .mask(BelowNotchMask(notchHeight: notchHeight, height: height))
            .allowsHitTesting(false)
    }
}

/// The open panel drawn statically (renders and tests).
struct OpenNotch: View {
    @ObservedObject var hub: NotchHub
    let notchHeight: CGFloat
    var notchWidth: CGFloat = 200
    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: proxy.size.width - 2 * (NotchGeometry.shadowMargin - MorphingNotch.openShoulder),
                              height: proxy.size.height - NotchGeometry.shadowMargin)
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: 30, shoulder: MorphingNotch.openShoulder).fill(Color.black)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                OpenLayers(hub: hub, notchHeight: notchHeight, notchWidth: notchWidth, size: size)
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .tint(MouthyTheme.orange)
    }
}

/// The tab rail: centred under the camera band, warm glass in a padded container, one selection capsule
/// drawn behind the buttons that springs to the selected tab, which opens up to show its title.
struct TabRail: View {
    let tabs: [any NotchTab]
    let selectedID: String?
    let namespace: Namespace.ID
    /// Icons only, sized for the band beside the camera.
    var compact = false
    let select: (String) -> Void
    /// With many tabs (a host adds its own) the selected one stays an icon so the rail still fits.
    static let titledLimit = 11
    /// Compact pitch per tab beside the camera. It never shrinks: tabs that do not fit go behind the overflow button.
    static let compactPitch: CGFloat = 26

    var body: some View {
        if compact {
            // The band beside the camera: only the tabs that fit at full pitch, the rest in a menu on a trailing
            // ellipsis. The selected tab is always on the rail, so the selection capsule never disappears.
            GeometryReader { proxy in
                let split = Self.split(tabs, selectedID: selectedID, available: proxy.size.width)
                rail(split.shown, overflow: split.overflow, showsTitle: false, pitch: Self.compactPitch)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) { rail(tabs, overflow: [], showsTitle: tabs.count <= Self.titledLimit, pitch: nil) }
                .scrollDisabled(true)
                .scrollClipDisabled(true)
                .fixedSize(horizontal: true, vertical: true)
        }
    }

    /// How many compact tabs fit beside the camera at full pitch (container padding is 2 pt each side).
    static func fitting(available: CGFloat, tabs: Int) -> Int {
        let slots = Int(((available - 4) / compactPitch).rounded(.down))
        return max(1, min(tabs, slots))
    }

    /// The tabs shown on the compact rail and the ones that move behind the overflow button, which takes a slot
    /// of its own. A selected tab that would overflow swaps into the last visible slot.
    static func split(_ tabs: [any NotchTab], selectedID: String?, available: CGFloat) -> (shown: [any NotchTab], overflow: [any NotchTab]) {
        let fit = fitting(available: available, tabs: tabs.count)
        guard fit < tabs.count else { return (tabs, []) }
        let visible = max(1, fit - 1)
        var shown = Array(tabs.prefix(visible))
        var overflow = Array(tabs.dropFirst(visible))
        if let selectedID, !shown.contains(where: { $0.id == selectedID }),
           let index = overflow.firstIndex(where: { $0.id == selectedID }) {
            let selected = overflow.remove(at: index)
            if let last = shown.popLast() { overflow.insert(last, at: 0) }
            shown.append(selected)
        }
        return (shown, overflow)
    }

    @ViewBuilder private func rail(_ shown: [any NotchTab], overflow: [any NotchTab], showsTitle: Bool, pitch: CGFloat?) -> some View {
        RailContainer {
            HStack(spacing: compact ? 2 : 8) {
                ForEach(shown, id: \.id) { tab in
                    RailButton(tab: tab, selected: selectedID == tab.id, showsTitle: showsTitle, compact: compact, pitch: pitch) { select(tab.id) }
                        .matchedGeometryEffect(id: tab.id, in: namespace, isSource: true)
                }
                if !overflow.isEmpty {
                    RailOverflowButton(tabs: overflow, pitch: pitch ?? Self.compactPitch, select: select)
                }
            }
            .padding(compact ? 2 : 4)
            .background {
                if let selectedID, shown.contains(where: { $0.id == selectedID }) {
                    Capsule(style: .circular)
                        .fill(MouthyTheme.cream.opacity(0.16))
                        .overlay(Capsule(style: .circular).strokeBorder(MouthyTheme.cream.opacity(0.08), lineWidth: 0.5))
                        .matchedGeometryEffect(id: selectedID, in: namespace, isSource: false)
                }
            }
            .modifier(RailGlass())
        }
        .padding(compact ? 0 : 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch tabs")
    }
}

extension EnvironmentValues {
    /// Draws the notch's glass flat. Offscreen renders cannot capture Liquid Glass (a glass view and
    /// everything it samples draw blank), so renders set this and get the base fill and rim instead.
    @Entry var notchFlatGlass = false
}

/// Groups the rail's glass so neighbouring shapes blend; skipped where glass is drawn flat.
struct RailContainer<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.notchFlatGlass) private var flat
    var body: some View {
        if flat { content } else { GlassEffectContainer(spacing: 8) { content } }
    }
}

/// Warm Liquid Glass over a smoked base fill (so renders and Reduce Transparency still show the rail).
struct RailGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.notchFlatGlass) private var flat
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Capsule(style: .circular).fill(MouthyTheme.solidGlass))
                .overlay(Capsule(style: .circular).strokeBorder(MouthyTheme.hoof, lineWidth: 1).allowsHitTesting(false))
        } else {
            content
                .background(Capsule(style: .circular).fill(LinearGradient(colors: [MouthyTheme.cream.opacity(0.09), MouthyTheme.cream.opacity(0.035)],
                                                          startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule(style: .circular).strokeBorder(LinearGradient(colors: [MouthyTheme.glow.opacity(0.16), MouthyTheme.glow.opacity(0.04)],
                                                               startPoint: .top, endPoint: .bottom), lineWidth: 0.6).allowsHitTesting(false))
                .modifier(LiquidGlassUnlessFlat(flat: flat))
        }
    }
}

struct LiquidGlassUnlessFlat: ViewModifier {
    let flat: Bool
    func body(content: Content) -> some View {
        if flat { content } else { content.glassEffect(.regular.tint(MouthyTheme.surface.opacity(0.55)), in: Capsule(style: .circular)) }
    }
}

struct RailButton: View {
    let tab: any NotchTab
    let selected: Bool
    let showsTitle: Bool
    var compact = false
    /// Compact: the rail's pitch per tab (the button is 2 pt narrower, the rail's spacing).
    var pitch: CGFloat? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Drawn as a text glyph: some symbols (waveform, timer, checklist, gauge) otherwise ignore the
                // foreground style and draw white.
                Text(Image(systemName: tab.symbolName))
                    .font(.system(size: compact ? 13 : 16, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? MouthyTheme.glow : hovering ? MouthyTheme.cream : MouthyTheme.cream2)
                    .frame(width: compact ? 16 : 20, height: compact ? 16 : 20)
                    .keyframeAnimator(initialValue: 1.0, trigger: selected) { glyph, scale in
                        glyph.scaleEffect(reduceMotion ? 1 : scale)
                    } keyframes: { _ in
                        // The symbol bounce on selection, as a spring that runs once per change.
                        SpringKeyframe(selected ? 1.2 : 1, duration: 0.14, spring: .snappy)
                        SpringKeyframe(1, duration: 0.32, spring: .bouncy)
                    }
                    .overlay(alignment: .topTrailing) {
                        // Beside the camera a count would overlap the next icon, so the compact rail shows a dot
                        // inside its own slot; the titled rail has room for the number.
                        if let badge = tab.badge {
                            if compact && (pitch ?? TabRail.compactPitch) < 30 {
                                // Only something live or waiting earns a dot; plain counts wait for the tab.
                                if badge.isLive { NotchBadgeView(badge: badge, dot: true).offset(x: 4, y: -3) }
                            } else {
                                NotchBadgeView(badge: badge).offset(x: 6, y: -6)
                            }
                        }
                    }
                if selected && showsTitle {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(MouthyTheme.cream)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .padding(.horizontal, compact ? 0 : 6)
            .frame(width: compact ? (pitch ?? TabRail.compactPitch) - 2 : nil)
            .frame(minWidth: compact ? nil : 32, minHeight: compact ? 24 : 32)
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // the system focus ring draws blue; the capsule shows the selection
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.badge.map(Self.badgeDescription) ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension RailButton {
    /// What VoiceOver reads for a badge: the count, or the dot's meaning.
    static func badgeDescription(_ badge: NotchBadge) -> String {
        if badge.count > 0 { return "\(badge.count)" }
        switch badge.tone {
        case .active: return "Running"
        case .attention: return "Needs attention"
        case .neutral: return "Updated"
        }
    }
}

/// The tabs that did not fit beside the camera: an ellipsis in the rail that opens a menu of them, with a dot
/// when any of them has something to show.
struct RailOverflowButton: View {
    let tabs: [any NotchTab]
    let pitch: CGFloat
    let select: (String) -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let badge = tabs.compactMap(\.badge).filter(\.isLive).max { ($0.tone == .attention ? 1 : 0) < ($1.tone == .attention ? 1 : 0) }
        Menu {
            ForEach(tabs, id: \.id) { tab in
                Button { select(tab.id) } label: {
                    Label(tab.badge.map { "\(tab.title) · \(RailButton.badgeDescription($0))" } ?? tab.title, systemImage: tab.symbolName)
                }
            }
        } label: {
            Text(Image(systemName: "ellipsis"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? MouthyTheme.cream : MouthyTheme.cream2)
                .frame(width: 16, height: 16)
                .overlay(alignment: .topTrailing) {
                    if let badge { NotchBadgeView(badge: badge, dot: true).offset(x: 4, y: -3) }
                }
                .frame(width: pitch - 2, height: 24)
                .contentShape(Capsule(style: .circular))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .help("More tabs")
        .accessibilityLabel("More tabs")
        .accessibilityValue(tabs.map(\.title).joined(separator: ", "))
    }
}

/// The one badge style: a mic-glow dot, or a count in night ink. A host's tint wins when it sets one.
/// `dot` draws a 6 pt dot whatever the count, for rails too tight for a number.
struct NotchBadgeView: View {
    let badge: NotchBadge
    var dot = false
    var body: some View {
        let tint = badge.tint ?? MouthyTheme.glow
        Group {
            if dot {
                Circle().fill(tint).frame(width: 6, height: 6)
            } else if badge.count > 0 {
                Text("\(min(badge.count, 99))")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(MouthyTheme.night)
                    .padding(.horizontal, 3.5)
                    .frame(minWidth: 13, minHeight: 13)
                    .background(tint, in: Capsule(style: .circular))
            } else {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
        }
        .shadow(color: tint.opacity(0.55), radius: 3)
        .accessibilityHidden(true)
    }
}

/// Glass for the black notch: a faint warm top-lit fill and a mic-glow hairline rim.
public struct SmokedGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var lit = false
    public func body(content: Content) -> some View {
        content
            .background(shape.fill(LinearGradient(colors: [MouthyTheme.cream.opacity(lit ? 0.16 : 0.09), MouthyTheme.cream.opacity(lit ? 0.07 : 0.035)],
                                                  startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [MouthyTheme.glow.opacity(0.16), MouthyTheme.glow.opacity(0.04)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.6).allowsHitTesting(false))
    }
}

public extension View {
    func smokedGlass<S: InsettableShape>(_ shape: S, lit: Bool = false) -> some View { modifier(SmokedGlass(shape: shape, lit: lit)) }
}

/// A card that drops out of the closed notch. The morphing shape draws the black; this lays the content
/// out below the camera band.
struct PeekCard: View {
    let content: AnyView
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var body: some View {
        content
            .padding(.top, notchHeight + 8)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .frame(width: NotchMetrics.peekWidth)
            .foregroundStyle(MouthyTheme.cream)
    }
}

/// Dancing equalizer bars for whatever is playing. Core Animation runs the dance in the render server, so
/// playing music costs Mouthy no per-frame work. Paused bars rest low and still; Reduce Motion holds them still.
public struct EqualizerBars: View {
    let playing: Bool
    let tint: Color
    var bars = 4
    var height: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(playing: Bool, tint: Color, bars: Int = 4, height: CGFloat = 14) {
        self.playing = playing; self.tint = tint; self.bars = bars; self.height = height
    }
    public var body: some View {
        EqualizerLayers(playing: playing, tint: tint, bars: bars, height: height, still: reduceMotion)
            .frame(width: EqualizerLayerView.width(bars: bars), height: height)
            .accessibilityHidden(true)
    }
}
