import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MouthyCore
import MouthyNotch

/// Modes. The Settings page is the main mode; each mode here overrides it when its
/// trigger word, shortcut, website or app matches (in that order).
///
/// Edits change `model.preferences` directly; AppModel's autosave persists them. Only discrete actions
/// (add, delete, a new shortcut) save and re-register hotkeys right away.
struct ModesView: View {
    @ObservedObject var model: AppModel
    @State private var editing: UUID?
    @State private var recordingFor: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, editing: UUID? = nil) {
        self.model = model
        _editing = State(initialValue: editing)
    }

    private var modes: [DictationMode] { model.preferences.modes }

    var body: some View {
        Group {
            if modes.isEmpty {
                emptyState.transition(.opacity)
            } else {
                grid.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(MouthyMotion.resolve(MouthyMotion.page, reduceMotion: reduceMotion), value: modes.isEmpty)
        .inspector(isPresented: inspectorShown) {
            if let id = editing, let mode = binding(for: id) {
                ModeEditor(mode: mode, model: model, recordingFor: $recordingFor,
                           delete: { delete(id) }, close: { editing = nil })
                    .id(id)
                    .inspectorColumnWidth(min: 420, ideal: 470, max: 580)
            }
        }
        .onChange(of: editing) { _, _ in
            if recordingFor != nil { recordingFor = nil; model.registerHotkey() }
        }
        // Leaving the page mid-capture (another page, closing the window) must bring every shortcut back.
        .onDisappear {
            if recordingFor != nil { recordingFor = nil; model.registerHotkey() }
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { editing.map { id in modes.contains { $0.id == id } } ?? false },
                set: { if !$0 { editing = nil } })
    }

    // MARK: Grid

    private var grid: some View {
        PageScroll {
            PageHeader("Modes", subtitle: "A mode is a style, an engine and a result for one app, website, shortcut or trigger word.")
            // Two even columns at every window size: three modes and "New mode" make a full 2×2 grid instead of
            // a row of three and an orphan, and the wider tiles keep their summaries on one line.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MouthyTheme.Layout.tileGap), count: 2), spacing: MouthyTheme.Layout.tileGap) {
                ForEach(modes) { mode in
                    ModeTile(mode: mode,
                             selected: editing == mode.id,
                             active: model.busy && model.activeModeName == mode.name) {
                        withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { editing = mode.id }
                    }
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .contextMenu {
                        Button("Edit", systemImage: "slider.horizontal.3") { editing = mode.id }
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(mode) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(mode.id) }
                    }
                }
                NewModeTile { addBlank() }
            }
            .animation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion), value: modes.map(\.id))
            ModeOrder()
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        ScrollView {
        VStack(spacing: 0) {
            PageHeader("Modes")
                .frame(maxWidth: MouthyTheme.Layout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, MouthyTheme.Layout.pageHorizontal)
                .padding(.top, MouthyTheme.Layout.pageTop)
            VStack(spacing: 14) {
                MascotView(pose: .wave, size: 140)
                Text("One mode so far: Settings")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                Text("A mode is a style, an engine and a result for one app, website, shortcut or trigger word.")
                    .font(.system(size: 14)).foregroundStyle(MouthyTheme.cream2)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button { addExamples() } label: { Label("Add example modes", systemImage: "sparkles") }
                        .buttonStyle(.mouthyPrimary)
                    Button { addBlank() } label: { Label("Start from scratch", systemImage: "plus") }
                        .buttonStyle(.mouthySecondary)
                }
                .padding(.top, 6)
                Text("Examples: Email for the word “email”, Code in Terminal and Xcode, Chat on ChatGPT and Claude.")
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    // MARK: Actions

    private func binding(for id: UUID) -> Binding<DictationMode>? {
        guard modes.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.preferences.modes.first { $0.id == id } ?? DictationMode(name: "") },
            set: { new in
                guard let index = model.preferences.modes.firstIndex(where: { $0.id == id }), model.preferences.modes[index] != new else { return }
                model.preferences.modes[index] = new
            })
    }

    private func addExamples() {
        let examples = ModeExamples.missing(from: modes)
        guard !examples.isEmpty else { return }
        withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { model.preferences.modes.append(contentsOf: examples) }
        model.savePreferences()
    }

    private func addBlank() {
        let mode = DictationMode(name: ModeExamples.newName(existing: modes))
        withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) {
            model.preferences.modes.append(mode)
            editing = mode.id
        }
        model.savePreferences()
    }

    private func duplicate(_ mode: DictationMode) {
        var copy = mode
        copy.id = UUID()
        copy.name = mode.name + " copy"
        copy.shortcut = nil
        copy.triggerWord = ""
        withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { model.preferences.modes.append(copy) }
        model.savePreferences()
    }

    private func delete(_ id: UUID) {
        if editing == id { editing = nil }
        withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { model.preferences.modes.removeAll { $0.id == id } }
        model.savePreferences()
    }
}

// MARK: - Tiles

/// One mode as a floating tile: what it does, and the chips that activate it.
struct ModeTile: View {
    let mode: DictationMode
    let selected: Bool
    let active: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: ModeExamples.symbol(for: mode))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MouthyTheme.glow)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(MouthyTheme.glow.opacity(0.14)))
                        .overlay(Circle().strokeBorder(MouthyTheme.glow.opacity(0.28), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.name.isEmpty ? "Untitled mode" : mode.name)
                            .font(MouthyType.headline).foregroundStyle(MouthyTheme.cream).lineLimit(1)
                        Text(ModeExamples.summary(for: mode))
                            .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if active {
                        MouthyChip("Active", symbol: "waveform", tone: .glow)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                FlowLayout(spacing: 6) { chips }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
            .background { TileBackground(style: .standard) }
            .overlay {
                RoundedRectangle(cornerRadius: MouthyTheme.Radius.tile, style: .continuous)
                    .strokeBorder(MouthyTheme.glow.opacity(selected ? 0.8 : 0), lineWidth: 1.5)
            }
            .overlay { if active { ActiveGlowRing() } }
            .contentShape(RoundedRectangle(cornerRadius: MouthyTheme.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .tileHover()
        .pointerStyle(.link)
        .accessibilityLabel(mode.name)
        .accessibilityHint("Edit this mode")
    }

    @ViewBuilder private var chips: some View {
        let word = mode.triggerWord.trimmingCharacters(in: .whitespaces)
        if !word.isEmpty { MouthyChip("“\(word)”", symbol: "quote.bubble") }
        if let shortcut = mode.shortcut { MouthyChip(shortcut.label, symbol: "command") }
        if !mode.apps.isEmpty { AppIconsChip(bundleIDs: mode.apps) }
        ForEach(mode.websites.prefix(2), id: \.self) { site in MouthyChip(site, symbol: "globe") }
        if mode.websites.count > 2 { MouthyChip("+\(mode.websites.count - 2)") }
        if mode.codeDictation { MouthyChip("Code", symbol: "chevron.left.forwardslash.chevron.right") }
        if let engine = mode.engine { MouthyChip(engine.label, symbol: "cpu") }
        if word.isEmpty && mode.shortcut == nil && mode.apps.isEmpty && mode.websites.isEmpty {
            MouthyChip("Not activated yet", symbol: "exclamationmark.circle", tone: .ember)
        }
    }
}

/// The order a mode is picked in, as a row under the grid: the same symbols as the tiles' chips, ending on
/// Settings, the main mode. It replaces the sentence the page used to end on and gives the grid a calm second
/// band instead of an empty page.
struct ModeOrder: View {
    static let steps: [(symbol: String, title: String, detail: String)] = [
        ("quote.bubble", "Trigger word", "Said first"),
        ("command", "Shortcut", "Its own keys"),
        ("globe", "Website", "The page you’re on"),
        ("macwindow", "App", "The app you’re in"),
        ("slider.horizontal.3", "Settings", "The main mode"),
    ]

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 16) {
                TileHeader("How a mode is picked")
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(MouthyTheme.cream3)
                                .frame(width: 18, height: 32)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: step.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(index == Self.steps.count - 1 ? MouthyTheme.glow : MouthyTheme.cream2)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(MouthyTheme.cream.opacity(0.05)))
                                .overlay(Circle().strokeBorder(MouthyTheme.cream.opacity(0.1), lineWidth: 1))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(MouthyType.callout.weight(.semibold)).foregroundStyle(MouthyTheme.cream)
                                    .lineLimit(1)
                                // Wraps instead of truncating when the inspector narrows the page.
                                Text(step.detail).font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Settings is the main mode. A mode takes over when its trigger word, shortcut, website or app matches, in that order.")
    }
}

/// App icons in one chip.
private struct AppIconsChip: View {
    let bundleIDs: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(bundleIDs.prefix(4), id: \.self) { id in
                Group {
                    if let icon = AppIcons.icon(bundleID: id) {
                        Image(nsImage: icon).warmIcon()
                    } else {
                        Image(systemName: "app.dashed").font(.system(size: 11)).foregroundStyle(MouthyTheme.cream2)
                    }
                }
                .frame(width: 16, height: 16)
                .help(AppIcons.name(bundleID: id))
            }
            Text(bundleIDs.count == 1 ? AppIcons.name(bundleID: bundleIDs[0]) : "\(bundleIDs.count) apps")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(MouthyTheme.cream2)
                .lineLimit(1)
        }
        .padding(.leading, 5).padding(.trailing, 8).padding(.vertical, 3)
        .background(Capsule(style: .circular).fill(MouthyTheme.raised))
        .overlay(Capsule(style: .circular).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Apps: " + bundleIDs.map(AppIcons.name(bundleID:)).joined(separator: ", "))
    }
}

/// A soft glow ring around the mode in use. Exists only while a dictation is running. It holds still: a
/// breathing glow redrew the window every frame for the whole dictation.
struct ActiveGlowRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: MouthyTheme.Radius.tile, style: .continuous)
            .strokeBorder(MouthyTheme.glow, lineWidth: 2).shadow(color: MouthyTheme.glow.opacity(0.6), radius: 10)
            .allowsHitTesting(false)
    }
}

/// The last tile: a dashed outline that adds a blank mode.
private struct NewModeTile: View {
    let add: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: add) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(hovering ? MouthyTheme.glow : MouthyTheme.cream2)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(MouthyTheme.cream.opacity(hovering ? 0.08 : 0.04)))
                Text("New mode").font(MouthyType.headline).foregroundStyle(MouthyTheme.cream)
                Text("For one app, website, shortcut or word")
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    .multilineTextAlignment(.center)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: MouthyTheme.Radius.tile, style: .continuous)
                    .fill(MouthyTheme.cream.opacity(hovering ? 0.04 : 0))
                TileBackground(style: .dashed)
            }
            .contentShape(RoundedRectangle(cornerRadius: MouthyTheme.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .tileHover()
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .pointerStyle(.link)
        .accessibilityLabel("New mode")
    }
}

// MARK: - Editor

/// The inspector is narrower than Settings, so its controls get a narrower column and the labels keep room for their details.
private enum ModeEditorLayout { static let controlWidth: CGFloat = 190 }

/// The mode editor in the inspector: grouped setting rows with 190 pt trailing controls.
struct ModeEditor: View {
    @Binding var mode: DictationMode
    @ObservedObject var model: AppModel
    @Binding var recordingFor: UUID?
    let delete: () -> Void
    let close: () -> Void
    @State private var confirmDelete = false
    @State private var newSite = ""


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: ModeExamples.symbol(for: mode))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MouthyTheme.glow)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(MouthyTheme.glow.opacity(0.14)))
                        .overlay(Circle().strokeBorder(MouthyTheme.glow.opacity(0.28), lineWidth: 1))
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.name.isEmpty ? "Untitled mode" : mode.name)
                            .font(MouthyType.headline).foregroundStyle(MouthyTheme.cream).lineLimit(1)
                        Text(ModeExamples.summary(for: mode)).font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    MouthyIconButton(symbol: "xmark", help: "Close", action: close)
                }

                EditorGroup(nil) {
                    SettingRow("Name", controlWidth: ModeEditorLayout.controlWidth) { MouthyField("Mode name", text: $mode.name) }
                }

                EditorGroup("Writing") {
                    SettingRow("Style", detail: "Natural uses no AI.", controlWidth: ModeEditorLayout.controlWidth) {
                        MouthyMenuPicker(title: "Style", selection: $mode.writingMode,
                                         options: WritingMode.allCases.map { ($0, $0.rawValue) })
                    }
                    SettingDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instructions").font(MouthyType.body).foregroundStyle(MouthyTheme.cream)
                        Text("Optional. Your own words for Apple Intelligence replace the style.")
                            .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                        WarmTextEditor(text: $mode.instructions, font: .systemFont(ofSize: 13), minHeight: 56,
                                       placeholder: "e.g. Write a friendly, short email.", accessibilityLabel: "Mode instructions")
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).fill(MouthyTheme.raised))
                            .overlay(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
                    }
                    .padding(.vertical, 12)
                    SettingDivider()
                    SettingRow("Speech engine", controlWidth: ModeEditorLayout.controlWidth) {
                        MouthyMenuPicker(title: "Speech engine", selection: $mode.engine,
                                         options: [(SpeechEngine?.none, "Same as Settings")] + model.availableEngines.map { (SpeechEngine?.some($0), $0.label) })
                    }
                    SettingDivider()
                    SettingRow("When finished", controlWidth: ModeEditorLayout.controlWidth) {
                        MouthyMenuPicker(title: "When finished", selection: $mode.output,
                                         options: OutputAction.allCases.map { ($0, $0.rawValue) })
                    }
                    SettingDivider()
                    SettingRow("Code dictation", detail: "“camel case name” → camelName", controlWidth: nil) {
                        Toggle("Code dictation", isOn: $mode.codeDictation).labelsHidden().toggleStyle(.warmSwitch)
                    }
                    SettingDivider()
                    SettingRow("Include context", detail: "App, site, nearby text, clipboard.", controlWidth: nil) {
                        Toggle("Include context", isOn: $mode.includeContext).labelsHidden().toggleStyle(.warmSwitch)
                    }
                }

                EditorGroup("Turns on with") {
                    SettingRow("Trigger word", detail: "Said first, then removed.", controlWidth: ModeEditorLayout.controlWidth) {
                        MouthyField("e.g. email", text: $mode.triggerWord)
                    }
                    SettingDivider()
                    SettingRow("Shortcut", controlWidth: ModeEditorLayout.controlWidth) { shortcutControl }
                    SettingDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        SettingRow("Websites", detail: "Press Return to add. Subdomains match too.", controlWidth: ModeEditorLayout.controlWidth) {
                            MouthyField("Add a website", text: $newSite) { addSite() }
                        }
                        if !mode.websites.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(mode.websites, id: \.self) { site in
                                    RemovableChip(text: site, symbol: "globe") { mode.websites.removeAll { $0 == site } }
                                }
                            }
                            .padding(.bottom, 12)
                        }
                    }
                    SettingDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        SettingRow("Apps", controlWidth: ModeEditorLayout.controlWidth) {
                            Button { addApp() } label: { Label("Add app…", systemImage: "plus") }
                                .buttonStyle(.compactGlass)
                        }
                        ForEach(mode.apps, id: \.self) { bundleID in
                            HStack(spacing: 8) {
                                Group {
                                    if let icon = AppIcons.icon(bundleID: bundleID) { Image(nsImage: icon).warmIcon() }
                                    else { Image(systemName: "app.dashed").foregroundStyle(MouthyTheme.cream2) }
                                }
                                .frame(width: 18, height: 18)
                                Text(AppIcons.name(bundleID: bundleID)).font(MouthyType.callout).foregroundStyle(MouthyTheme.cream)
                                Spacer()
                                Button { mode.apps.removeAll { $0 == bundleID } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(MouthyTheme.cream2)
                                }
                                .buttonStyle(.plain).help("Remove \(AppIcons.name(bundleID: bundleID))")
                            }
                        }
                        if !mode.apps.isEmpty { Spacer().frame(height: 4) }
                    }
                }

                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete mode", systemImage: "trash")
                }
                .buttonStyle(DestructiveCapsuleStyle())
                .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(MouthyTheme.night2)
        .foregroundStyle(MouthyTheme.cream)
        .tint(MouthyTheme.orange)
        .confirmationDialog("Delete “\(mode.name)”?", isPresented: $confirmDelete) {
            Button("Delete mode", role: .destructive, action: delete)
        } message: {
            Text("Its trigger word, shortcut, websites and apps stop switching modes.")
        }
    }

    @ViewBuilder private var shortcutControl: some View {
        if recordingFor == mode.id {
            HStack(spacing: 8) {
                ShortcutCapture { key, modifiers, label in
                    if let key, let modifiers, let label { mode.shortcut = ModeShortcut(keyCode: key, modifiers: modifiers, label: label) }
                    recordingFor = nil
                    model.savePreferences()
                }
                .frame(width: 1, height: 1)
                Text("Press a key with ⌘, ⌃ or ⌥").font(MouthyType.caption).foregroundStyle(MouthyTheme.glow)
            }
        } else {
            HStack(spacing: 8) {
                if let shortcut = mode.shortcut {
                    KeycapRow(shortcut: shortcut.label.replacingOccurrences(of: " ", with: ""))
                    Button("Clear") { mode.shortcut = nil; model.savePreferences() }.buttonStyle(.compactGlass)
                } else {
                    Text("None").font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                }
                Button("Record") { recordingFor = mode.id; model.hotkeySuspended = true }.buttonStyle(.compactGlass)
            }
        }
    }

    private func addSite() {
        let site = newSite.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !site.isEmpty else { return }
        let parts = site.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for part in parts where !mode.websites.contains(part) { mode.websites.append(part) }
        newSite = ""
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Use for this mode"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !mode.apps.contains(id) else { return }
        mode.apps.append(id)
    }
}

/// A titled group of setting rows on a card: the inspector's grouped-form section in the cocoa palette.
private struct EditorGroup<Content: View>: View {
    let title: String?
    let content: Content
    init(_ title: String?, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(MouthyType.section).foregroundStyle(MouthyTheme.cream2).padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous).fill(MouthyTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: MouthyTheme.Radius.card, style: .continuous).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
        }
    }
}

/// The destructive action: ember text on a faint ember capsule.
private struct DestructiveCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(MouthyTheme.ember)
            .padding(.horizontal, 16).frame(minHeight: 32)
            .background(Capsule(style: .circular).fill(MouthyTheme.ember.opacity(configuration.isPressed ? 0.2 : 0.12)))
            .overlay(Capsule(style: .circular).strokeBorder(MouthyTheme.ember.opacity(0.3), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule(style: .circular))
    }
}

/// A chip with a remove button.
private struct RemovableChip: View {
    let text: String
    var symbol: String?
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).help("Remove \(text)")
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(MouthyTheme.cream2)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule(style: .circular).fill(MouthyTheme.raised))
        .overlay(Capsule(style: .circular).strokeBorder(MouthyTheme.hoof, lineWidth: 1))
    }
}
