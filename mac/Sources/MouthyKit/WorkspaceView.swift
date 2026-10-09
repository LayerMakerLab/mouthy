import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch

/// The main window's pages, in sidebar order. Raw values are the `AppModel.selectedPage` strings.
enum WorkspacePage: String, CaseIterable, Identifiable {
    case dictate = "Dictate", modes = "Modes", files = "Files", meetings = "Meetings", history = "History", vocabulary = "Vocabulary", settings = "Settings"
    var id: String { rawValue }
    var title: String { rawValue }
    var symbol: String {
        switch self {
        case .dictate: "mic"
        case .modes: "square.stack.3d.up"
        case .files: "doc.on.doc"
        case .meetings: "person.2.wave.2"
        case .history: "clock.arrow.circlepath"
        case .vocabulary: "text.book.closed"
        case .settings: "slider.horizontal.3"
        }
    }
    /// The page for a stored selection; unknown strings open Dictate.
    init(selected: String) { self = WorkspacePage(rawValue: selected) ?? .dictate }
}

/// The main window: warm backdrop, a floating glass sidebar and the selected page.
struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var page: WorkspacePage { WorkspacePage(selected: model.selectedPage) }

    var body: some View {
        ZStack {
            MouthyBackdrop(listening: model.phase == .listening)
            HStack(spacing: 0) {
                WorkspaceSidebar(model: model, page: page) { model.selectedPage = $0.rawValue }
                    .padding(10)
                ZStack {
                    pageView(page)
                        .id(page)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.985, anchor: .top)),
                            removal: .opacity))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 14)
                .animation(MouthyMotion.resolve(MouthyMotion.page, reduceMotion: reduceMotion), value: page)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) {
            StatusToast(model: model).padding(.bottom, 22).padding(.leading, 240)
        }
        .tint(MouthyTheme.orange)
        .preferredColorScheme(.dark)
        .foregroundStyle(MouthyTheme.cream)
        .sensoryFeedback(.selection, trigger: page)
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refreshCapabilities() } } }
    }

    @ViewBuilder private func pageView(_ page: WorkspacePage) -> some View {
        switch page {
        case .files: FilesView(model: model)
        case .meetings: MeetingsView(model: model, meeting: model.meeting)
        case .modes: ModesView(model: model)
        case .history: HistoryView(model: model)
        case .vocabulary: VocabularyView(model: model)
        case .settings: PreferencesView(model: model)
        case .dictate: DictationView(model: model)
        }
    }
}

/// The floating glass sidebar: the giraffe and wordmark, the pages, and the shortcut.
struct WorkspaceSidebar: View {
    @ObservedObject var model: AppModel
    let page: WorkspacePage
    let select: (WorkspacePage) -> Void
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Group {
                        if let head = Mascot.glyphImage(.wave) {
                            Image(nsImage: head).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        } else {
                            MascotGlyph(pose: .wave, size: 30)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                    Text("mouthy").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                    Spacer(minLength: 0)
                    if model.phase == .listening {
                        Circle().fill(MouthyTheme.glow).frame(width: 8, height: 8)
                            .shadow(color: MouthyTheme.glow, radius: 6)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityLabel("Listening")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 40)
                .padding(.bottom, 22)
                .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: model.phase == .listening)

                VStack(spacing: 2) {
                    ForEach(WorkspacePage.allCases) { item in
                        SidebarRow(page: item, selected: item == page, namespace: selection) { select(item) }
                    }
                }
                .animation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion), value: page)

                Spacer(minLength: 16)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        KeycapRow(shortcut: model.shortcutLabel)
                        Text(DictateHero.gesture(preset: model.preferences.shortcut, holdToTalk: model.preferences.holdToTalk) + " to talk")
                            .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .mouthyGlass(Capsule(style: .circular))
                    Label("On this Mac", systemImage: "lock.fill")
                        .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                        .padding(.leading, 8)
                }
                .padding(.bottom, 6)
            }
            .padding(12)
            .frame(width: 220)
            .frame(maxHeight: .infinity)
            .mouthyGlass(RoundedRectangle(cornerRadius: MouthyTheme.Radius.sidebar, style: .continuous))
        }
    }
}

struct SidebarRow: View {
    let page: WorkspacePage
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @State private var bounces = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(selected ? MouthyTheme.glow : MouthyTheme.cream2)
                    .symbolEffect(.bounce, value: bounces)
                Text(page.title).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? MouthyTheme.cream : MouthyTheme.cream2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous)
                        .fill(MouthyTheme.raised)
                        .overlay(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous)
                            .strokeBorder(MouthyTheme.cream.opacity(0.06), lineWidth: 1))
                        .matchedGeometryEffect(id: "sel", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).fill(MouthyTheme.hoverFill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .onChange(of: selected) { _, now in if now && !reduceMotion { bounces += 1 } }
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A glass capsule at the bottom of the window for status changes; it hides itself after 2.6 s.
struct StatusToast: View {
    @ObservedObject var model: AppModel
    @State private var message: Message?
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tone: Equatable { case info, success, failure }
    struct Message: Equatable { let id = UUID(); let text: String; let tone: Tone }

    static let attentionPrefixes = ["Ready to copy", "No speech", "No final transcript", "Microphone", "Transcription timed out", "Command failed", "Couldn't", "Could not"]
    static let successPrefixes = ["Inserted", "Pasted", "Answer sent", "Sent", "Copied", "Saved", "Opened", "Searched", "Ran", "Ready. Review", "Exported"]

    /// Whether a status deserves a toast (not the resting "Ready.").
    static func shouldShow(_ status: String) -> Bool {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "Ready." && trimmed != "Ready"
    }

    static func tone(for status: String, failed: Bool) -> Tone {
        if failed || attentionPrefixes.contains(where: status.hasPrefix) || status.localizedCaseInsensitiveContains("failed") { return .failure }
        if successPrefixes.contains(where: status.hasPrefix) { return .success }
        return .info
    }

    var body: some View {
        ZStack {
            if let message {
                HStack(spacing: 8) {
                    Image(systemName: symbol(message.tone))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color(message.tone))
                    Text(message.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MouthyTheme.cream)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .modifier(ToastWidth(long: message.text.count > 64))
                .mouthyGlass(Capsule(style: .circular))
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                .id(message.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { dismiss() }
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.toast, reduceMotion: reduceMotion), value: message)
        .onChange(of: model.status) { _, status in present(status) }
        .onDisappear { hideTask?.cancel() }
    }

    private func present(_ status: String) {
        hideTask?.cancel()
        guard Self.shouldShow(status) else { message = nil; return }
        message = Message(text: status, tone: Self.tone(for: status, failed: model.phase == .failed))
        AccessibilityNotification.Announcement(status).post()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            message = nil
        }
    }

    private func dismiss() { hideTask?.cancel(); message = nil }

    private func symbol(_ tone: Tone) -> String {
        switch tone { case .failure: "exclamationmark.circle.fill"; case .success: "checkmark"; case .info: "info.circle.fill" }
    }

    private func color(_ tone: Tone) -> Color {
        switch tone { case .failure: MouthyTheme.ember; case .success: MouthyTheme.glow; case .info: MouthyTheme.cream2 }
    }
}

/// Short toasts hug their text; long ones wrap at 520 pt.
private struct ToastWidth: ViewModifier {
    let long: Bool
    func body(content: Content) -> some View {
        if long { content.frame(width: 520) } else { content.fixedSize() }
    }
}
