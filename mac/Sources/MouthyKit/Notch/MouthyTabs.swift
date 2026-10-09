import AppKit
import CoreImage
import MouthyNotch
import SwiftUI

/// Mouthy's own notch tabs. Host apps register the same set.
@MainActor public enum MouthyTabs {
    /// Where tab data lives. Defaults to Mouthy's support folder; a host app may point it at its own.
    public static var storageFolder = LocalStore.supportDirectory.appendingPathComponent("Notch", isDirectory: true)

    public static func all() -> [any NotchTab] {
        [TimersTab.shared, NotesTab.shared, MusicTab.shared, ClipboardTab.shared, ShelfTab.shared,
         CalendarTab.shared, WeatherTab.shared, ShortcutsTab.shared, UsageTab.shared]
    }

    /// Every tab this app offers, in default order. The Mouthy voice tab only inside Mouthy itself.
    static var catalog: [any NotchTab] {
        (isMouthyApp ? [VoiceTab.shared] : []) + all()
    }

    /// True inside Mouthy itself (release or dev), false in host apps and tests.
    static var isMouthyApp: Bool { Bundle.main.bundleIdentifier?.hasPrefix("dev.mouthy.") == true }

    /// Whether tabs may use the network (lyrics, artwork, weather). Inside Mouthy, Local Only Mode turns it off;
    /// a host app sets its own rule. Checked before every request.
    public static var networkAllowed: @MainActor () -> Bool = {
        isMouthyApp ? !AppModel.shared.preferences.localOnly : true
    }

    /// Tab order, hidden tabs and feel, saved in `layout.json`.
    struct Layout: Codable, Equatable {
        var order: [String] = []
        /// Five tabs by default; the rest are one switch away in Settings → Notch tabs.
        var hidden: Set<String> = Layout.quietTabs
        /// 2: the quiet tabs became hidden by default (2026-10-05).
        var version = 2
        static let quietTabs: Set<String> = ["mouthy.clipboard", "mouthy.shelf", "mouthy.weather", "mouthy.shortcuts", "mouthy.usage"]
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
            hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? Layout.quietTabs
            openDelay = try c.decodeIfPresent(Int.self, forKey: .openDelay) ?? 200
            haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            if version < 2 { hidden.formUnion(Layout.quietTabs); version = 2 }
        }
        var openDelay = 200
        var haptics = true
    }
    static var layout: Layout = {
        var saved = NotchFile.load(Layout.self, "layout.json") ?? Layout()
        // Older settings saved 0/150 ms (opened on any pass of the pointer) or the old 400/700 ms choices.
        if saved.openDelay < 200 || saved.openDelay == 400 { saved.openDelay = 200 }
        if saved.openDelay == 700 { saved.openDelay = 500 }
        return saved
    }() {
        didSet { NotchFile.save(layout, "layout.json"); if let attachedHub { apply(to: attachedHub) } }
    }

    /// Host tab ids kept ahead of Mouthy's tabs whatever order the user saves, e.g. ["host.agents"].
    static var leading: [String] = []
    /// The hub the tabs are attached to; nil while detached, so no watcher runs.
    static weak var attachedHub: NotchHub?

    /// Catalog tabs in the saved order; tabs added in a later version go at the end.
    static var orderedCatalog: [any NotchTab] {
        let tabs = catalog
        let saved = layout.order.compactMap { id in tabs.first { $0.id == id } }
        return saved + tabs.filter { tab in !saved.contains { $0.id == tab.id } }
    }

    public static func registerAll(in hub: NotchHub? = nil) {
        let hub = hub ?? .shared
        all().forEach(hub.register)
        hub.fileDropTabID = ShelfTab.shared.id
    }

    /// For a host app: registers the visible tabs after the host's `leading` tabs and starts only the
    /// visible tabs' change observers. Does not start the hub; the host owns that.
    public static func attach(to hub: NotchHub, leading: [String] = []) {
        self.leading = leading
        attachedHub = hub
        apply(to: hub)
        PowerEvents.shared.start()
    }

    /// Stops every observer and unregisters Mouthy's tabs. Leaves the hub and the host's own tabs running.
    public static func detach(from hub: NotchHub) {
        attachedHub = nil
        syncWatchers(visible: [])
        PowerEvents.shared.stop()
        catalog.forEach { hub.unregister(id: $0.id) }
        hub.fileDropTabID = nil; hub.dictationTabID = nil
        hub.headerLeading = nil; hub.headerTrailing = nil; hub.pillAccessory = nil
    }

    /// Runs a tab's observer only while that tab is visible and attached; hidden tabs cost nothing.
    static func syncWatchers(visible ids: Set<String>) {
        if ids.contains(MusicTab.shared.id) { MusicTab.shared.startWatching() } else { MusicTab.shared.stopWatching() }
        if ids.contains(ClipboardTab.shared.id) { ClipboardTab.shared.startWatching() } else { ClipboardTab.shared.stopWatching() }
        if ids.contains(CalendarTab.shared.id) { CalendarTab.shared.startWatching() } else { CalendarTab.shared.stopWatching() }
        // The dictation pill's usage chip reads the same data, so usage keeps watching while any tab is attached.
        if !ids.isEmpty { UsageTab.shared.startWatching() } else { UsageTab.shared.stopWatching() }
    }

    /// Registers the visible tabs in order and applies the feel settings.
    static func apply(to hub: NotchHub? = nil) {
        let hub = hub ?? .shared
        let visible = orderedCatalog.filter { !layout.hidden.contains($0.id) }
        for tab in catalog where layout.hidden.contains(tab.id) { hub.unregister(id: tab.id) }
        visible.forEach(hub.register)
        hub.reorder(leading + visible.map(\.id))
        if attachedHub === hub { syncWatchers(visible: Set(visible.map(\.id))) }
        hub.fileDropTabID = visible.contains { $0.id == ShelfTab.shared.id } ? ShelfTab.shared.id : nil
        // Open, the hub shows a running dictation in Mouthy's tab; closed, the band alone shows it.
        hub.dictationTabID = visible.contains { $0.id == VoiceTab.shared.id } ? VoiceTab.shared.id : nil
        hub.headerLeading = nil
        hub.pillAccessory = { UsageTab.shared.hasData ? AnyView(UsageChip(usage: UsageTab.shared)) : nil }
        // The band right of the camera: what the selected tab is doing. The menu bar already shows the clock.
        hub.headerTrailing = { AnyView(HeaderTabStatus(hub: hub)) }
        // Older settings saved 0 or 150 ms, which opened on any pass of the pointer.
        hub.openDelay = .milliseconds(max(layout.openDelay, 200))
        hub.haptics = layout.haptics
    }

    /// Starts or stops the hub with Mouthy's tabs and their change observers. Never in headless mode.
    public static func setHub(enabled: Bool) {
        let hub = NotchHub.shared
        if enabled, !CommandLine.arguments.contains("--headless") {
            attach(to: hub)
            hub.start()
        } else {
            attachedHub = nil
            syncWatchers(visible: [])
            PowerEvents.shared.stop()
            hub.stop()
        }
    }
}

/// Settings → Notch: which tabs show, their order, and how the notch opens.
public struct NotchSettingsView: View {
    @State private var layout = MouthyTabs.layout
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag to reorder. ⌃⌥N opens the notch with the keyboard; ⌘1–9 or a sideways swipe switches tabs.")
                .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                .fixedSize(horizontal: false, vertical: true)
            Tile(padding: 6, style: .raised) {
                List {
                    ForEach(order, id: \.self) { id in
                        if let tab = MouthyTabs.catalog.first(where: { $0.id == id }) {
                            NotchSettingsRow(title: tab.title, symbol: tab.symbolName, isOn: shown(id))
                                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .onMove { from, to in
                        var ids = order; ids.move(fromOffsets: from, toOffset: to); layout.order = ids
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(order.count) * NotchSettingsRow.height + 8)
            }
            SettingRow("Open after hovering", detail: "How long the pointer rests on the notch before it opens.", controlWidth: nil) {
                WarmPicker("Open after hovering", selection: $layout.openDelay,
                           options: [(200, "Quickly"), (300, "Normally"), (500, "Deliberately")])
            }
            SettingDivider()
            SettingRow("Haptic tap", detail: "A light tick on the trackpad when the notch opens and tabs change.", controlWidth: nil) {
                Toggle("Haptic tap", isOn: $layout.haptics).labelsHidden().toggleStyle(.warmSwitch)
            }
        }
        .onChange(of: layout) { _, value in MouthyTabs.layout = value }
    }
    private var order: [String] {
        let ids = MouthyTabs.catalog.map(\.id)
        let saved = layout.order.filter(ids.contains)
        return saved + ids.filter { !saved.contains($0) }
    }
    private func shown(_ id: String) -> Binding<Bool> {
        Binding(get: { !layout.hidden.contains(id) },
                set: { on in if on { layout.hidden.remove(id) } else { layout.hidden.insert(id) } })
    }
}

/// One tab in the settings list: drag handle, icon, title and a mini orange switch.
struct NotchSettingsRow: View {
    static let height: CGFloat = 36
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(MouthyTheme.cream3)
                .frame(width: 14)
                .help("Drag to reorder")
                .accessibilityHidden(true)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? MouthyTheme.glow : MouthyTheme.cream3)
                .frame(width: 22)
            Text(title).font(MouthyType.body).foregroundStyle(isOn ? MouthyTheme.cream : MouthyTheme.cream2)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden()
                .toggleStyle(.warmSwitchMini)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The notch palette for tabs. Names describe roles; values are the giraffe theme.
enum NotchStyle {
    /// Giraffe orange: rings, prominent controls.
    static let accent = MouthyTheme.orange
    /// Mic glow: live states, highlights.
    static let amber = MouthyTheme.glow
    /// Quiet second tone (a break, not focus).
    static let moss = MouthyTheme.cream2
    static let ember = MouthyTheme.ember
    static let ink = MouthyTheme.cream
    static let dim = MouthyTheme.cream2
    static let faint = MouthyTheme.cream.opacity(0.08)
}

/// Small JSON documents under `MouthyTabs.storageFolder`. Unreadable files are kept, never overwritten.
@MainActor enum NotchFile {
    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = MouthyTabs.storageFolder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
        return nil
    }
    static func save<T: Encodable>(_ value: T, _ name: String) {
        let folder = MouthyTabs.storageFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}

/// A tab's section title: rounded semibold cream, with an optional quiet detail.
struct TabHeader: View {
    let title: String
    var detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                .accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.system(size: 12.5)).foregroundStyle(MouthyTheme.cream2) }
            Spacer(minLength: 0)
        }
    }
}

/// The notch's capsule button. Prominent: the orange primary fill with night ink. Otherwise: warm smoked glass.
struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 11).frame(minHeight: 26)
            .foregroundStyle(prominent ? MouthyTheme.night : MouthyTheme.cream)
            .background {
                if prominent {
                    Capsule(style: .circular).fill(MouthyTheme.primaryFill)
                        .overlay(Capsule(style: .circular).strokeBorder(LinearGradient(colors: [MouthyTheme.cream.opacity(0.4), .clear], startPoint: .top, endPoint: .center), lineWidth: 0.8))
                        .compositingGroup()
                        .shadow(color: MouthyTheme.orange.opacity(hovering ? 0.45 : 0.28), radius: hovering ? 10 : 6, y: 2)
                }
            }
            .modifier(OptionalSmokedGlass(enabled: !prominent, lit: hovering))
            .contentShape(Capsule(style: .circular))
            .brightness(hovering && prominent ? 0.04 : 0)
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(NotchPressStyle())
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
    }
}

/// Press feedback for notch controls: a small spring scale.
struct NotchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(MouthyMotion.press, value: configuration.isPressed)
    }
}

struct OptionalSmokedGlass: ViewModifier {
    let enabled: Bool
    let lit: Bool
    func body(content: Content) -> some View {
        if enabled { content.smokedGlass(Capsule(style: .circular), lit: lit) } else { content }
    }
}

/// A plain text field on smoked glass with a mic-glow ring while focused (system focus rings draw blue).
struct NotchField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(MouthyTheme.cream3))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(MouthyTheme.cream)
            .focusEffectDisabled()
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .smokedGlass(shape, lit: focused)
            .overlay(shape.strokeBorder(MouthyTheme.glow.opacity(focused ? 0.9 : 0), lineWidth: 1.5).allowsHitTesting(false))
            .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: focused)
            .accessibilityLabel(prompt)
    }
}

/// A progress ring in the warm metal gradient. Drawn inside its frame (inset strokes), so it never clips.
/// `dashed` draws the empty dashed ring used when there is no data.
struct GlowRing: View {
    let progress: Double
    var lineWidth: CGFloat = 7
    var tint: Color = MouthyTheme.orange
    var dashed = false
    var body: some View {
        ZStack {
            if dashed {
                Circle().inset(by: lineWidth / 2)
                    .stroke(MouthyTheme.cream2.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            } else {
                Circle().strokeBorder(MouthyTheme.cream.opacity(0.07), lineWidth: lineWidth)
                Circle().inset(by: lineWidth / 2)
                    .trim(from: 0, to: max(0.001, min(1, progress)))
                    .stroke(AngularGradient(colors: [MouthyTheme.patch, tint, MouthyTheme.glowHi], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(progress, 0.01))),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.5), radius: 6)
                    .animation(.smooth(duration: 0.8), value: progress)
            }
        }
    }
}

/// Bars and fills: mic-glow high at the top fading to giraffe orange.
let barGradient = NotchPalette.sheen

/// Hue of the mic-glow amber (#FFB547), 0…1.
let glowHue = 35.8 / 360

/// The glow for an image's average colour: a little brighter and richer so it glows rather than muddies.
/// House rule, no blue: cool art (teal through violet) glows mic-glow amber at 0.6 saturation instead.
func ambientHSB(hue: Double, saturation: Double, brightness: Double) -> (hue: Double, saturation: Double, brightness: Double) {
    if hue > 0.47 && hue < 0.83 { return (glowHue, 0.6, max(0.6, brightness)) }
    return (hue, min(1, saturation * 1.2), max(0.55, brightness))
}

/// The average colour of an image, as a glow (see `ambientHSB`).
func ambientColor(of image: NSImage) -> Color? {
    guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff),
          let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
          let output = filter.outputImage else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    CIContext(options: [.workingColorSpace: NSNull()]).render(output, toBitmap: &pixel, rowBytes: 4,
                                                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
    let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    let glow = ambientHSB(hue: hue, saturation: saturation, brightness: brightness)
    return Color(hue: glow.hue, saturation: glow.saturation, brightness: glow.brightness)
}

func formatClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    let h = total / 3600, m = total / 60 % 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// The open notch's right wing after the tab's title: the selected tab's own status, only when the tab body
/// doesn't already show it. Today that is the next event; Music and Timers show their time in the body, and a
/// tab with no status of its own shows nothing (no battery or usage fallback that would read as the tab's).
/// The menu-bar clock sits in the same bar, so no clock here.
struct HeaderTabStatus: View {
    @ObservedObject var hub: NotchHub
    @ObservedObject private var calendar = CalendarTab.shared
    @Environment(\.notchStatusShort) private var short
    init(hub: NotchHub) { self.hub = hub }

    var body: some View {
        if hub.selectedID == calendar.id, let event = calendar.nextEvent {
            HStack(spacing: 6) {
                // Whole or not at all: a tight band keeps the time and drops the event's name.
                if !short { Text(event.title).lineLimit(1).foregroundStyle(MouthyTheme.cream) }
                Text(event.start <= Date() ? "Now" : event.start.formatted(date: .omitted, time: .shortened))
                    .monospacedDigit().foregroundStyle(MouthyTheme.cream2).fixedSize()
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The standard peek card layout: a 24 pt icon, a 14 pt title, an optional second line and a trailing value.
struct NotchPeekRow<Icon: View>: View {
    let title: String
    var detail: String?
    var value: String?
    /// Trailing live content in place of a value (equalizer bars).
    var accessory: AnyView?
    let icon: Icon
    init(title: String, detail: String? = nil, value: String? = nil, accessory: AnyView? = nil, @ViewBuilder icon: () -> Icon) {
        self.title = title; self.detail = detail; self.value = value; self.accessory = accessory; self.icon = icon()
    }
    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(MouthyTheme.cream2).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.system(size: 16, weight: .regular, design: .rounded)).monospacedDigit()
                    .foregroundStyle(MouthyTheme.cream)
                    .contentTransition(.numericText())
            } else if let accessory {
                accessory
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small empty or unavailable state inside a tab: the giraffe's head, one line and at most one action.
/// Stacked when it fits the panel's height; otherwise the giraffe sits left of the words and the action,
/// so the button never runs into the panel's bottom edge.
struct NotchEmptyState: View {
    var pose: MascotPose = .sleep
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        ViewThatFits(in: .vertical) {
            stacked
            sideBySide
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var stacked: some View {
        VStack(spacing: 8) {
            MascotGlyph(pose: pose, size: 44)
            Text(title).font(.system(size: 13.5, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                .multilineTextAlignment(.center)
            if let message {
                Text(message).font(.system(size: 13.5)).foregroundStyle(MouthyTheme.cream2)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                PillButton(title: actionTitle, prominent: true, action: action).padding(.top, 2)
            }
        }
    }

    private var sideBySide: some View {
        HStack(spacing: 16) {
            MascotGlyph(pose: pose, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13.5, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                if let message {
                    Text(message).font(.system(size: 13.5)).foregroundStyle(MouthyTheme.cream2)
                        .frame(maxWidth: 340, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    PillButton(title: actionTitle, prominent: true, action: action).padding(.top, 6)
                }
            }
        }
    }
}

extension View {
    /// Placeholder skeleton of the real layout while it loads. It holds still: a loading sheen would redraw the
    /// hub every frame, and the load is short (NotchLoad.timeout).
    func notchSkeleton(loading: Bool) -> some View {
        redacted(reason: .placeholder)
            .accessibilityElement(children: .ignore).accessibilityLabel("Loading")
    }
}

/// Fades the bottom of a tab's scrolling list while more is below it, so a row cut by the panel's edge reads
/// as "more" instead of a clipping mistake. Every vertical list in the notch uses it; at the end of the list
/// the fade goes away and the last row shows whole.
struct NotchScrollFade: ViewModifier {
    @State private var more = false
    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY < $0.contentSize.height - 1 } action: { _, value in more = value }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(more ? 0 : 1)], startPoint: .top, endPoint: .bottom).frame(height: 22)
                }
            }
    }
}

extension View {
    func notchScrollFade() -> some View { modifier(NotchScrollFade()) }
}

enum NotchLoad {
    /// A load still running after this long shows Retry.
    static let timeout: Duration = .seconds(10)
}
