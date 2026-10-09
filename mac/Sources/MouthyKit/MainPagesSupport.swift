import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreImage
import MouthyCore
import MouthyNotch

// Shared pieces for the Dictate, History, Files and Modes pages: pure state logic (tested in
// MainPagesTests) and a few small controls built on the design system.

// MARK: - Dictate

@MainActor final class DictationClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

/// Only this small subtree observes each elapsed second. The surrounding workspace, menu or island stays still.
struct ElapsedTimeView<Content: View>: View {
    @ObservedObject var clock: DictationClock
    @ViewBuilder var content: (TimeInterval) -> Content
    var body: some View { content(clock.elapsed) }
}

/// What the Dictate hero shows for the current state.
enum DictateHero {
    /// Pose = state: listen while recording, talk for an agent question, type while finishing, cheer briefly
    /// after a result, wave on the very first run and sleep otherwise.
    static func pose(phase: AppModel.Phase, agentQuestion: String?, cheering: Bool, firstRun: Bool) -> MascotPose {
        switch phase {
        case .preparing, .listening: return agentQuestion == nil ? .listen : .talk
        case .finishing, .delivering: return .type
        case .cancelling, .failed: return .sleep
        case .idle: return cheering ? .cheer : firstRun ? .listen : .sleep
        }
    }

    /// The hero headline. While listening the live text (or the agent's question) is shown instead.
    static func headline(phase: AppModel.Phase, shortcut: String, cheering: Bool, status: String) -> String {
        switch phase {
        case .preparing: return "Getting ready"
        case .listening: return "Listening"
        case .finishing: return "Finishing"
        case .delivering: return "Typing"
        case .cancelling: return "Cancelled"
        case .failed: return "That didn't work"
        case .idle:
            if cheering, let word = outcomeWord(status) { return word }
            return startPrompt(shortcut)
        }
    }

    /// "Press ⌃⌥Space to start" / "Hold Fn to start" / "Double-tap Right ⌘ to start".
    static func startPrompt(_ shortcut: String) -> String {
        let label = shortcut.trimmingCharacters(in: .whitespaces)
        for verb in ["Hold ", "Double-tap "] where label.hasPrefix(verb) { return label + " to start" }
        return "Press " + label + " to start"
    }

    /// The gesture beside the shortcut's keycaps, which drop the "Hold "/"Double-tap " prefix: "Double-tap",
    /// "Hold" or "Press". The double tap ignores hold-to-talk, as `AppModel` does.
    static func gesture(preset: Int, holdToTalk: Bool) -> String {
        preset == 4 ? "Double-tap" : preset == 5 || holdToTalk ? "Hold" : "Press"
    }

    /// The short success word for a finished status, or nil when the status is not a success.
    static func outcomeWord(_ status: String) -> String? {
        if status.hasPrefix("Answer sent") { return "Sent to the agent" }
        for word in ["Inserted", "Pasted", "Sent", "Copied", "Saved", "Exported"] where status.hasPrefix(word) { return word }
        if status.hasPrefix("Ready. Review") { return "Done" }
        return nil
    }

    /// m:ss for the elapsed recording time.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The one thing standing between the person and a working dictation, named exactly, with its fix.
enum DictateReadiness: Equatable {
    case microphone
    case speechModel(engine: String)
    case downloading
    case localOnly(engine: String)
    case accessibility
    case ready

    static func evaluate(microphone: Bool, speechAssets: Bool, accessibility: Bool, localOnly: Bool, setupBusy: Bool, engine: SpeechEngine) -> DictateReadiness {
        if !microphone { return .microphone }
        if setupBusy { return .downloading }
        if !speechAssets { return localOnly ? .localOnly(engine: engine.label) : .speechModel(engine: engine.label) }
        if !accessibility { return .accessibility }
        return .ready
    }

    var isReady: Bool { self == .ready }

    var message: String {
        switch self {
        case .microphone: "I can't hear anything without the microphone."
        case .speechModel(let engine): "\(engine) isn't downloaded yet. It downloads once, then works offline."
        case .downloading: "Downloading the speech model…"
        case .localOnly: "Network use is blocked, so I can't download a speech model."
        case .accessibility: "I can't paste into other apps without Accessibility. Results stay here."
        case .ready: "Ready. Works in any app with a text field."
        }
    }

    /// The button that fixes it, or nil when nothing needs doing.
    var actionTitle: String? {
        switch self {
        case .microphone: "Allow microphone"
        case .speechModel: "Download model"
        case .localOnly: "Open privacy settings"
        case .accessibility: "Open Accessibility settings"
        case .downloading, .ready: nil
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic.slash.fill"
        case .speechModel, .localOnly: "arrow.down.circle.fill"
        case .downloading: "arrow.down.circle"
        case .accessibility: "hand.raised.fill"
        case .ready: "checkmark.circle.fill"
        }
    }
}

// MARK: - History

/// History entries grouped by day, newest first.
enum HistoryGrouping {
    struct Day: Identifiable {
        let start: Date
        let title: String
        let entries: [MouthyCore.Transcript]
        var id: Date { start }
    }

    static func days(_ entries: [MouthyCore.Transcript], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let groups = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { start in
            Day(start: start, title: title(for: start, now: now, calendar: calendar),
                entries: groups[start, default: []].sorted { $0.date > $1.date })
        }
    }

    /// "Today", "Yesterday", a weekday within the last week, otherwise the date.
    static func title(for day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 { return day.formatted(.dateTime.weekday(.wide)) }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return sameYear ? day.formatted(.dateTime.weekday(.wide).month(.wide).day()) : day.formatted(.dateTime.month(.wide).day().year())
    }

    static func filter(_ entries: [MouthyCore.Transcript], query: String) -> [MouthyCore.Transcript] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query) || $0.mode.localizedCaseInsensitiveContains(query) }
    }
}

/// App icons by display name (history keeps the app's name, not its bundle identifier).
@MainActor
enum AppIcons {
    private static var byName: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    private static var byBundle: [String: NSImage] = [:]

    static let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                          NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]

    /// The icon of an installed app called `name`, or nil.
    static func icon(named name: String) -> NSImage? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        if let cached = byName[name] { return cached }
        if missing.contains(name) { return nil }
        for folder in folders {
            let path = folder + "/" + name + ".app"
            if FileManager.default.fileExists(atPath: path) {
                let icon = warm(NSWorkspace.shared.icon(forFile: path))
                byName[name] = icon
                return icon
            }
        }
        missing.insert(name)
        return nil
    }

    /// The icon of the app with this bundle identifier, or nil when it is not installed.
    static func icon(bundleID: String) -> NSImage? {
        if let cached = byBundle[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = warm(NSWorkspace.shared.icon(forFile: url.path))
        byBundle[bundleID] = icon
        return icon
    }

    /// A system icon recoloured into the giraffe palette: its brightness mapped onto cream, so Mail, Xcode or a
    /// blue folder never puts blue on screen. Returns the original when Core Image can't draw it.
    static func warm(_ image: NSImage, side: CGFloat = 64) -> NSImage {
        var rect = CGRect(x: 0, y: 0, width: side * 2, height: side * 2)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let mono = CIFilter(name: "CIColorMonochrome", parameters: [
                  kCIInputImageKey: CIImage(cgImage: cg),
                  kCIInputColorKey: CIColor(red: 0xF6 / 255.0, green: 0xE3 / 255.0, blue: 0xC1 / 255.0),
                  kCIInputIntensityKey: 1.0]),
              let output = mono.outputImage,
              let warmed = warmContext.createCGImage(output, from: output.extent) else { return image }
        return NSImage(cgImage: warmed, size: NSSize(width: side, height: side))
    }
    private static let warmContext = CIContext(options: [.useSoftwareRenderer: false])

    static func name(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return ModeExamples.knownAppNames[bundleID] ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Where a history entry came from: an app, a file, or Mouthy itself.
enum EntrySource {
    case mouthy, file(symbol: String), app(String)

    static func classify(_ source: String) -> EntrySource {
        if source == "Mouthy workspace" || source == "Mouthy" || source.isEmpty { return .mouthy }
        let ext = (source as NSString).pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 5, !source.hasSuffix(".app"), let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .movie) { return .file(symbol: "film") }
            if type.conforms(to: .audio) { return .file(symbol: "waveform") }
        }
        return .app(source)
    }
}

extension Image {
    /// A third-party app or file icon, sized to fit. Pass an image already recoloured by `AppIcons.warm` (the
    /// app-icon caches do this) so system icons never put blue on screen.
    func warmIcon() -> some View {
        resizable().interpolation(.high).aspectRatio(contentMode: .fit)
    }
}

/// A 16 pt source icon: the app's own icon, a file symbol, or the giraffe.
struct SourceIcon: View {
    let source: String
    var size: CGFloat = 16
    var body: some View {
        Group {
            switch EntrySource.classify(source) {
            case .mouthy: MascotGlyph(pose: .listen, size: size)
            case .file(let symbol): Image(systemName: symbol).font(.system(size: size * 0.75, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
            case .app(let name):
                if let icon = AppIcons.icon(named: name) {
                    Image(nsImage: icon).warmIcon()
                } else {
                    Image(systemName: "app.dashed").font(.system(size: size * 0.8)).foregroundStyle(MouthyTheme.cream2)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Files

enum FileDrop {
    /// Only audio and video files are transcribed; anything else dropped is ignored.
    static func transcribable(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL else { return false }
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
            return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
        }
    }

    static func symbol(for url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .movie) == true { return "film" }
        return "waveform"
    }
}

/// A file row's state, read from `FileResult.state`.
enum FileState: Equatable {
    case queued, transcribing, ready, cancelled, failed(String)
    init(_ state: String) {
        if state == "Transcribing" { self = .transcribing }
        else if state == "Ready" { self = .ready }
        else if state == "Cancelled" { self = .cancelled }
        else if state.hasPrefix("Failed") {
            let reason = state.dropFirst("Failed".count).drop { $0 == ":" || $0 == " " }
            self = .failed(reason.isEmpty ? "Couldn't transcribe this file." : String(reason))
        } else { self = .queued }
    }
}

// MARK: - Modes

enum ModeExamples {
    static let knownAppNames = ["com.apple.Terminal": "Terminal", "com.apple.dt.Xcode": "Xcode"]

    /// Three starting points: Email (trigger word, clean-up style), Code (Terminal and Xcode, code dictation)
    /// and Chat (ChatGPT and Claude on the web, insert and press Return).
    static func make() -> [DictationMode] {
        var email = DictationMode(name: "Email")
        email.triggerWord = "email"
        email.writingMode = .tidy
        var code = DictationMode(name: "Code")
        code.apps = ["com.apple.Terminal", "com.apple.dt.Xcode"]
        code.codeDictation = true
        var chat = DictationMode(name: "Chat")
        chat.websites = ["chatgpt.com", "claude.ai"]
        chat.output = .insertAndReturn
        return [email, code, chat]
    }

    /// The examples whose names are not taken yet, so tapping twice never duplicates them.
    static func missing(from modes: [DictationMode]) -> [DictationMode] {
        let names = Set(modes.map { $0.name.lowercased() })
        return make().filter { !names.contains($0.name.lowercased()) }
    }

    /// A symbol that says what the mode does.
    static func symbol(for mode: DictationMode) -> String {
        if mode.codeDictation { return "chevron.left.forwardslash.chevron.right" }
        switch mode.output {
        case .insertAndReturn: return "paperplane.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .historyOnly: return "clock.fill"
        case .insert: return mode.triggerWord.isEmpty ? "text.cursor" : "envelope.fill"
        }
    }

    /// One line under the name: style and result.
    static func summary(for mode: DictationMode) -> String {
        var parts = [mode.instructions.isEmpty ? mode.writingMode.rawValue : "Custom instructions"]
        parts.append(mode.output.rawValue)
        return parts.joined(separator: " · ")
    }

    /// The new name for a blank mode: "New mode", "New mode 2", ...
    static func newName(existing: [DictationMode]) -> String {
        let names = Set(existing.map(\.name))
        if !names.contains("New mode") { return "New mode" }
        var n = 2
        while names.contains("New mode \(n)") { n += 1 }
        return "New mode \(n)"
    }
}

// MARK: - Controls

/// A 28 pt glass circle that opens a menu (export formats, page actions).
struct MouthyIconMenu<Items: View>: View {
    let symbol: String
    let help: String
    let items: Items
    init(symbol: String, help: String, @ViewBuilder items: () -> Items) {
        self.symbol = symbol; self.help = help; self.items = items()
    }
    var body: some View {
        Menu { items } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MouthyTheme.cream)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .mouthyGlass(Circle(), interactive: true)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A row of glass icon buttons that fades in on hover (and stays for keyboard/VoiceOver users).
struct HoverCluster<Content: View>: View {
    let visible: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(visible: Bool, @ViewBuilder content: () -> Content) { self.visible = visible; self.content = content() }
    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) { content }
                .padding(3)
        }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.94, anchor: .trailing)
        .allowsHitTesting(visible)
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: visible)
    }
}

/// A small status dot: glow when fine, ember when something is missing.
struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? MouthyTheme.glow : MouthyTheme.ember)
            .frame(width: 7, height: 7)
            .shadow(color: (ok ? MouthyTheme.glow : MouthyTheme.ember).opacity(0.6), radius: 4)
            .accessibilityHidden(true)
    }
}

/// Plain text editing in an AppKit text view with warm selection (orange at 0.35) and a mic-glow caret,
/// instead of the system's blue selection. Grows to fit its text.
struct WarmTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 14)
    var minHeight: CGFloat = 0
    var placeholder: String = ""
    var accessibilityLabel: String = "Text"
    var onEdit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = WarmTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.focusRingType = .none
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel(accessibilityLabel)
        Self.style(view, font: font)
        view.placeholder = placeholder
        view.string = text
        return view
    }

    static func style(_ view: NSTextView, font: NSFont) {
        let cream = NSColor(MouthyTheme.cream)
        view.font = font
        view.textColor = cream
        view.insertionPointColor = NSColor(MouthyTheme.glow)
        view.selectedTextAttributes = [.backgroundColor: NSColor(MouthyTheme.orange).withAlphaComponent(0.35), .foregroundColor: cream]
        view.typingAttributes = [.font: font, .foregroundColor: cream]
        view.linkTextAttributes = [.foregroundColor: NSColor(MouthyTheme.glow), .underlineStyle: NSUnderlineStyle.single.rawValue]
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text { view.string = text; view.invalidateIntrinsicContentSize() }
        (view as? WarmTextView)?.placeholder = placeholder
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 400)
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let line = layout.defaultLineHeight(for: font)
        return CGSize(width: width, height: max(minHeight, ceil(max(used, line))))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WarmTextEditor
        init(_ parent: WarmTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
            view.needsDisplay = true
            parent.onEdit()
        }
    }

    /// Draws the placeholder while empty.
    final class WarmTextView: NSTextView {
        var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor(MouthyTheme.cream2).withAlphaComponent(0.6)]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
        }
        override func didChangeText() { super.didChangeText(); needsDisplay = true }
    }
}

/// A compact glass capsule (30 pt) for actions inside rows and tiles.
struct CompactGlassButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { CompactBody(configuration: configuration, prominent: prominent) }

    private struct CompactBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(prominent ? MouthyTheme.night : MouthyTheme.cream)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .background { if prominent { Capsule(style: .circular).fill(MouthyTheme.primaryFill) } }
                .contentShape(Capsule(style: .circular))
                .modifier(CompactGlassBackground(enabled: !prominent))
                .overlay(Capsule(style: .circular).fill(MouthyTheme.cream.opacity(hovering && enabled ? 0.06 : 0)).allowsHitTesting(false))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        }
    }

    private struct CompactGlassBackground: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled { content.mouthyGlass(Capsule(style: .circular), interactive: true) } else { content }
        }
    }
}

extension ButtonStyle where Self == CompactGlassButtonStyle {
    static var compactGlass: CompactGlassButtonStyle { CompactGlassButtonStyle() }
    static var compactPrimary: CompactGlassButtonStyle { CompactGlassButtonStyle(prominent: true) }
}

/// Progress drawn by hand in the mic-glow gradient, so it stays orange in windows that are not key
/// (AppKit's bar turns grey there). Indeterminate progress sweeps a glow segment across the track.
struct MouthyBarProgressStyle: ProgressViewStyle {
    var height: CGFloat = 5
    func makeBody(configuration: Configuration) -> some View {
        BarBody(fraction: configuration.fractionCompleted, height: height)
    }

    private struct BarBody: View {
        let fraction: Double?
        let height: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .circular).fill(MouthyTheme.cream.opacity(0.08))
                    if let fraction {
                        Capsule(style: .circular).fill(horizontalBarFill)
                            .frame(width: max(height, width * min(1, max(0, fraction))))
                            .shadow(color: MouthyTheme.glow.opacity(0.45), radius: 4)
                            .animation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion), value: fraction)
                    } else {
                        // Core Animation slides the segment while a file transcribes: no per-frame work in Mouthy.
                        SlidingSegment(still: reduceMotion)
                    }
                }
            }
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
        }
    }
}

/// The bar fill turned sideways: orange at the start, glowHi at the leading edge of progress.
private let horizontalBarFill = LinearGradient(colors: [MouthyTheme.orange, MouthyTheme.glowHi], startPoint: .leading, endPoint: .trailing)

/// A pop-up choice drawn in the cocoa palette (AppKit pop-up buttons follow the system appearance and accent).
struct MouthyMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    private var current: String { options.first { $0.value == selection }?.label ?? title }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { option in Text(option.label).tag(option.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(current).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(MouthyTheme.cream2)
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(MouthyTheme.cream)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).fill(MouthyTheme.raised))
        .overlay(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
        .accessibilityLabel(title)
        .accessibilityValue(current)
    }
}
