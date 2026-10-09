import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch

/// History: past dictations grouped by day, kept only on this Mac.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var clearConfirmation = false
    @State private var pageWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entries: [MouthyCore.Transcript] { HistoryGrouping.filter(model.history, query: query) }

    var body: some View {
        Group {
            if model.history.isEmpty {
                VStack(spacing: 0) {
                    PageHeader("History", subtitle: "Your dictations, only on this Mac")
                        .frame(maxWidth: MouthyTheme.Layout.contentMaxWidth, alignment: .leading)
                        .padding(.horizontal, MouthyTheme.Layout.pageHorizontal)
                        .padding(.top, MouthyTheme.Layout.pageTop)
                    emptyState
                        .padding(.bottom, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
            } else {
                list
                    .transition(.opacity)
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.page, reduceMotion: reduceMotion), value: model.history.isEmpty)
        .confirmationDialog("Delete all saved dictations?", isPresented: $clearConfirmation) {
            Button("Delete all", role: .destructive) {
                withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { model.clearHistory() }
            }
        } message: {
            Text("This removes every dictation saved on this Mac. It can't be undone.")
        }
    }

    // MARK: Empty

    @ViewBuilder private var emptyState: some View {
        if model.preferences.keepHistory {
            MascotEmptyState(pose: .sleep, title: "Nothing here yet",
                             message: "Your dictations will show up here.",
                             actionTitle: "Dictate something") { model.selectedPage = WorkspacePage.dictate.rawValue }
        } else {
            MascotEmptyState(pose: .sleep, title: "History is off",
                             message: "Nothing is kept. Turn it on to keep your dictations on this Mac only.",
                             actionTitle: "Turn on history") {
                model.preferences.keepHistory = true
                model.savePreferences()
            }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MouthyTheme.Layout.tileGap, pinnedViews: [.sectionHeaders]) {
                PageHeader("History", subtitle: subtitle) { moreMenu }
                MouthyField("Search dictations", text: $query)
                    .overlay(alignment: .trailing) {
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(MouthyTheme.cream2)
                            }
                            .buttonStyle(.plain).padding(.trailing, 8).help("Clear search")
                        }
                    }
                    .padding(.bottom, 4)
                if entries.isEmpty {
                    Text("No dictations match “\(query)”.")
                        .font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(HistoryGrouping.days(entries)) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            HistoryEntryTile(entry: entry,
                                             copy: { copy(entry) },
                                             open: { open(entry) },
                                             export: { model.export(entry.text) },
                                             delete: { delete(entry) })
                                .transition(.scale(scale: 0.96).combined(with: .opacity))
                        }
                    } header: {
                        DayHeader(title: day.title, count: day.entries.count)
                    }
                }
            }
            .pageColumn(pageWidth: pageWidth)
            .padding(.top, MouthyTheme.Layout.pageTop)
            .padding(.bottom, 40)
            .animation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion), value: entries.map(\.id))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var subtitle: String {
        let count = model.history.count
        let base = count == 1 ? "1 dictation" : "\(count) dictations"
        return base + (model.preferences.keepHistory ? " · only on this Mac" : " · history is off, nothing new is kept")
    }

    private var moreMenu: some View {
        Menu {
            Toggle("Keep new dictations", isOn: Binding(get: { model.preferences.keepHistory },
                                                         set: { model.preferences.keepHistory = $0; model.savePreferences() }))
            Divider()
            Button("Clear history…", role: .destructive) { clearConfirmation = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MouthyTheme.cream)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .mouthyGlass(Circle(), interactive: true)
        .help("History options")
        .accessibilityLabel("History options")
    }

    // MARK: Actions

    private func copy(_ entry: MouthyCore.Transcript) {
        TextDelivery.copy(entry.text)
        model.status = "Copied to the clipboard."
    }

    private func open(_ entry: MouthyCore.Transcript) {
        model.output = entry.text
        model.document = TranscriptionDocument(text: "")
        model.selectedPage = WorkspacePage.dictate.rawValue
    }

    private func delete(_ entry: MouthyCore.Transcript) {
        withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { model.deleteHistory(entry.id) }
    }
}

/// A sticky day label floating over the list as a small glass capsule.
private struct DayHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(MouthyType.section).foregroundStyle(MouthyTheme.cream)
            Text("\(count)").font(MouthyType.caption.monospacedDigit()).foregroundStyle(MouthyTheme.cream2)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .mouthyGlass(Capsule(style: .circular))
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One past dictation: where and when, its mode, the words, and a hover cluster of actions.
struct HistoryEntryTile: View {
    let entry: MouthyCore.Transcript
    let copy: () -> Void
    let open: () -> Void
    let export: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Tile(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SourceIcon(source: entry.source)
                    Text(sourceName).font(MouthyType.callout.weight(.medium)).foregroundStyle(MouthyTheme.cream).lineLimit(1)
                    Text("·").foregroundStyle(MouthyTheme.cream3)
                    Text(entry.date, format: .relative(presentation: .named))
                        .font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                        .help(entry.date.formatted(date: .complete, time: .shortened))
                    if entry.duration >= 1 {
                        Text("·").foregroundStyle(MouthyTheme.cream3)
                        Text(DictateHero.clock(entry.duration)).font(MouthyType.callout.monospacedDigit()).foregroundStyle(MouthyTheme.cream2)
                    }
                    Spacer(minLength: 8)
                    ZStack(alignment: .trailing) {
                        MouthyChip(entry.mode, symbol: "wand.and.stars", tone: .glow)
                            .opacity(hovering ? 0 : 1)
                        HoverCluster(visible: hovering) {
                            MouthyIconButton(symbol: "doc.on.doc", help: "Copy", action: copy)
                            MouthyIconButton(symbol: "arrow.up.forward.app", help: "Open in Dictate", action: open)
                            MouthyIconButton(symbol: "square.and.arrow.up", help: "Export as text", action: export)
                            MouthyIconButton(symbol: "trash", help: "Delete", role: .destructive, action: delete)
                        }
                    }
                    .frame(height: 28)
                }
                Text(entry.text)
                    .font(MouthyType.body)
                    .foregroundStyle(MouthyTheme.cream)
                    .lineSpacing(2)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc", action: copy)
            Button("Open in Dictate", systemImage: "arrow.up.forward.app", action: open)
            Button("Export as Text…", systemImage: "square.and.arrow.up", action: export)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Copy", copy)
        .accessibilityAction(named: "Open in Dictate", open)
        .accessibilityAction(named: "Delete", delete)
    }

    private var sourceName: String {
        switch EntrySource.classify(entry.source) {
        case .mouthy: "Mouthy"
        case .file, .app: entry.source
        }
    }
}
