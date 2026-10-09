import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch

// Controls and small pure helpers for Settings, Vocabulary, onboarding, the menu bar panel and About.
// System pickers and segmented controls draw the system accent (often blue) in places `.tint` does not
// reach, so these surfaces use warm hand-drawn equivalents.

/// A pop-up choice drawn as a raised cocoa capsule with a glow chevron. The choices open in a warm popover
/// (system menus highlight in the system accent colour, which is often blue).
struct WarmPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var fullWidth = false
    @State private var open = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, selection: Binding<Value>, options: [(value: Value, label: String)], fullWidth: Bool = false) {
        self.title = title; self._selection = selection; self.options = options; self.fullWidth = fullWidth
    }

    private var currentLabel: String { options.first { $0.value == selection }?.label ?? title }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(currentLabel).lineLimit(1).truncationMode(.tail)
                if fullWidth { Spacer(minLength: 4) }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MouthyTheme.glow)
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(MouthyTheme.cream)
            .padding(.horizontal, 12)
            .frame(height: fullWidth ? 36 : 28)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Capsule(style: .circular).fill(MouthyTheme.raised))
            .overlay(Capsule(style: .circular).fill(MouthyTheme.cream.opacity(hovering && enabled ? 0.05 : 0)))
            .overlay(Capsule(style: .circular).strokeBorder(open ? MouthyTheme.glow : MouthyTheme.hoof, lineWidth: open ? 1.5 : 1))
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .popover(isPresented: $open, arrowEdge: .bottom) { choices }
        .accessibilityLabel(title)
        .accessibilityValue(currentLabel)
        .help(title)
    }

    private var choices: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        let selected = option.value == selection
                        Button {
                            selection = option.value
                            open = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(MouthyTheme.glow)
                                    .opacity(selected ? 1 : 0)
                                Text(option.label)
                                    .font(.system(size: 13, weight: selected ? .semibold : .regular, design: .rounded))
                                    .foregroundStyle(selected ? MouthyTheme.cream : MouthyTheme.cream2)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 28)
                        }
                        .buttonStyle(MouthyPressableStyle(radius: 8))
                        .id(index)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(6)
            }
            .onAppear {
                if let index = options.firstIndex(where: { $0.value == selection }) { proxy.scrollTo(index, anchor: .center) }
            }
        }
        .frame(width: 250, height: min(CGFloat(options.count) * 30 + 12, 340))
        .background(MouthyTheme.surface.opacity(0.6))
        .tint(MouthyTheme.orange)
        .preferredColorScheme(.dark)
    }
}

/// The one on/off switch, drawn by hand so it stays giraffe orange in windows that are not key (the system
/// switch turns grey there, in the notch panel and offscreen). `.mini` is the notch size; `showsLabel` draws the
/// toggle's own title before it.
struct WarmSwitchStyle: ToggleStyle {
    var mini = false
    var showsLabel = false
    func makeBody(configuration: Configuration) -> some View { WarmSwitch(configuration: configuration, mini: mini, showsLabel: showsLabel) }

    private struct WarmSwitch: View {
        let configuration: Configuration
        let mini: Bool
        let showsLabel: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            let on = configuration.isOn
            HStack(spacing: 8) {
                if showsLabel { configuration.label }
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule(style: .circular).fill(on ? AnyShapeStyle(MouthyTheme.primaryFill) : AnyShapeStyle(MouthyTheme.night.opacity(0.8)))
                    Capsule(style: .circular).strokeBorder(on ? MouthyTheme.glow.opacity(0.35) : MouthyTheme.hoof, lineWidth: mini ? 0.8 : 1)
                    Circle()
                        .fill(on ? MouthyTheme.cream : MouthyTheme.cream2)
                        .shadow(color: .black.opacity(0.35), radius: mini ? 1 : 2, y: mini ? 0.5 : 1)
                        .padding(mini ? 2 : 2.5)
                }
                .frame(width: mini ? 28 : 38, height: mini ? 16 : 22)
                .shadow(color: MouthyTheme.orange.opacity(on && enabled ? 0.3 : 0), radius: mini ? 4 : 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { if enabled { configuration.isOn.toggle() } }
            .opacity(enabled ? 1 : 0.45)
            .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: on)
            .sensoryFeedback(.selection, trigger: on)
            .accessibilityElement(children: .ignore)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

extension ToggleStyle where Self == WarmSwitchStyle {
    static var warmSwitch: WarmSwitchStyle { WarmSwitchStyle() }
    /// The notch-sized switch.
    static var warmSwitchMini: WarmSwitchStyle { WarmSwitchStyle(mini: true) }
}

/// A segmented choice: one orange capsule slides under the selected option.
struct WarmSegmented<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self.title = title; self._selection = selection; self.options = options
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? MouthyTheme.night : MouthyTheme.cream2)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 24)
                        .background {
                            if selected {
                                Capsule(style: .circular).fill(MouthyTheme.primaryFill)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Capsule(style: .circular))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule(style: .circular).fill(MouthyTheme.night.opacity(0.7)))
        .overlay(Capsule(style: .circular).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A compact capsule button for setting rows: warm glass, or the orange fill for the one thing to do next.
struct CompactButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { CompactBody(configuration: configuration, prominent: prominent) }

    private struct CompactBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            let label = configuration.label
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(prominent && enabled ? MouthyTheme.night : MouthyTheme.cream)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .contentShape(Capsule(style: .circular))
            Group {
                if prominent {
                    // Disabled: the fill fades but the label turns cream, so a dimmed parent never fades it twice.
                    label.background(Capsule(style: .circular).fill(MouthyTheme.primaryFill).opacity(enabled ? 1 : 0.45)
                        .shadow(color: MouthyTheme.orange.opacity(enabled ? 0.3 : 0), radius: 8, y: 2))
                } else {
                    label.mouthyGlass(Capsule(style: .circular), interactive: true)
                }
            }
            .overlay(Capsule(style: .circular).fill(MouthyTheme.cream.opacity(hovering && enabled ? 0.06 : 0)).allowsHitTesting(false))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled || prominent ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        }
    }
}

extension ButtonStyle where Self == CompactButtonStyle {
    static var compact: CompactButtonStyle { CompactButtonStyle() }
    static var compactProminent: CompactButtonStyle { CompactButtonStyle(prominent: true) }
}

/// A permission's state: a glowing dot while it is still needed, a cream check that draws itself once allowed.
struct PermissionMark: View {
    let granted: Bool
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(MouthyTheme.cream)
                    .transition(.drawOnCheck(reduceMotion: reduceMotion))
            } else {
                Circle().fill(MouthyTheme.glow)
                    .frame(width: size * 0.5, height: size * 0.5)
                    .shadow(color: MouthyTheme.glow.opacity(0.8), radius: size * 0.4)
                    .transition(.opacity)
            }
        }
        .frame(width: size + 2, height: size + 2)
        .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: granted)
        .accessibilityLabel(granted ? "Allowed" : "Needed")
    }
}

/// One permission in the SettingRow layout: the mark, a title with its detail, and a single action.
struct PermissionRow<Action: View>: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: Action
    init(_ title: String, detail: String, granted: Bool, @ViewBuilder action: () -> Action) {
        self.title = title; self.detail = detail; self.granted = granted; self.action = action()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PermissionMark(granted: granted)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(MouthyType.body).foregroundStyle(MouthyTheme.cream)
                Text(detail).font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action.frame(width: 220, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

/// The note shown instead of silently greying out Settings while a dictation runs.
struct BusyCapsule: View {
    var text = "Settings unlock when dictation ends"
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
            Text(text).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundStyle(MouthyTheme.cream)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .mouthyGlass(Capsule(style: .circular))
        .accessibilityElement(children: .combine)
    }
}

/// A tile of settings: header, then rows separated by hairlines (the rows supply their own dividers).
struct SettingsTile<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content
    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.content = content()
    }
    var body: some View {
        Tile(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TileHeader(title, symbol: symbol)
                    .padding(.top, 18).padding(.bottom, 6)
                content
            }
            .padding(.horizontal, 20).padding(.bottom, 8)
        }
    }
}

extension AnyTransition {
    /// A success check that draws itself in; a plain fade with Reduce Motion.
    static func drawOnCheck(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.symbolEffect(.drawOn))
    }
}

// MARK: - Pure helpers

/// The version line for About: CFBundleShortVersionString plus the source revision the build stamped.
enum AppVersion {
    static func line(_ info: [String: Any]?) -> String {
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let revision = (info?["MouthySourceRevision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch (version, revision) {
        case let (version?, revision?): return "Version \(version) (\(revision))"
        case let (version?, nil): return "Version \(version)"
        case let (nil, revision?): return "Development build (\(revision))"
        case (nil, nil): return "Development build"
        }
    }
    static var current: String {
        // Only Mouthy's own bundle carries the version; a test runner or host app would report its own.
        guard Bundle.main.bundleIdentifier?.hasPrefix("dev.mouthy.") == true else { return line(nil) }
        return line(Bundle.main.infoDictionary)
    }
    /// The bundled third-party licence folder, when this is a packaged app.
    static var licensesFolder: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("ThirdParty"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// Editing the newline-separated vocabulary as a list of chips.
enum VocabularyEditing {
    static func words(_ vocabulary: String) -> [String] { VocabularyLearner.terms(vocabulary) }

    /// Adds what was typed (commas separate several words), skipping ones already there in any case.
    static func adding(_ typed: String, to vocabulary: String) -> String {
        let new = VocabularyLearner.terms(typed)
        guard !new.isEmpty else { return vocabulary }
        return VocabularyLearner.merge(new, into: vocabulary)
    }

    static func removing(_ word: String, from vocabulary: String) -> String {
        words(vocabulary).filter { $0 != word }.joined(separator: "\n")
    }

    /// A replacement rule from the add row, or nil when the phrase is blank.
    static func replacement(phrase: String, replacement: String) -> Replacement? {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return nil }
        return Replacement(phrase: phrase, replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Adds a rule, replacing an existing rule for the same phrase (any case).
    static func adding(_ rule: Replacement, to rules: [Replacement]) -> [Replacement] {
        rules.filter { $0.phrase.caseInsensitiveCompare(rule.phrase) != .orderedSame } + [rule]
    }
}

/// What the menu bar panel and onboarding say and show for the dictation state.
enum MenuPanelState {
    static let successPrefixes = ["Inserted", "Pasted", "Sent", "Copied", "Saved to history"]

    static func isSuccess(_ status: String) -> Bool { successPrefixes.contains(where: status.hasPrefix) }

    /// Cheer lasts only while `cheering` (1.2 s after a delivery); otherwise idle is sleep.
    static func pose(phase: AppModel.Phase, status: String, agentQuestion: String?, meeting: Bool = false, cheering: Bool = false) -> MascotPose {
        if agentQuestion != nil { return .talk }
        switch phase {
        case .preparing, .listening: return .listen
        case .finishing, .delivering: return .type
        case .cancelling, .failed: return .sleep
        case .idle:
            if meeting { return .type }
            return cheering && isSuccess(status) ? .cheer : .sleep
        }
    }

    static func headline(phase: AppModel.Phase, agentQuestion: String?, meeting: Bool = false) -> String {
        if agentQuestion != nil { return "An agent is asking" }
        if meeting { return phase == .listening ? "Recording a meeting" : "Finishing the meeting" }
        switch phase {
        case .idle: return "Ready"
        case .preparing: return "Getting ready"
        case .listening: return "Listening"
        case .finishing: return "Finishing"
        case .delivering: return "Typing"
        case .cancelling: return "Cancelling"
        case .failed: return "Needs attention"
        }
    }

    /// The status under the headline, or nil when it would only repeat it.
    static func detail(status: String, phase: AppModel.Phase, agentQuestion: String?) -> String? {
        if let agentQuestion { return agentQuestion }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
        if trimmed.isEmpty || ["Ready", "Ready to record", "Listening", "Preparing microphone"].contains(plain) { return nil }
        return trimmed
    }
}
