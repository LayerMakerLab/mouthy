import AppKit
import MouthyNotch
import SwiftUI
import UniformTypeIdentifiers

/// A shelf for files: drop them on the notch, drag them out later, AirDrop or share them.
/// Holds references to the original files, never copies.
@MainActor final class ShelfTab: ObservableObject, NotchTab {
    static let shared = ShelfTab()
    let id = "mouthy.shelf"
    let title = "Shelf"
    let symbolName = "tray"
    @Published private(set) var files: [URL] { didSet { NotchFile.save(files.map(\.path), "shelf.json") } }
    @Published var targeted = false

    private init() {
        files = (NotchFile.load([String].self, "shelf.json") ?? []).map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var badge: NotchBadge? { files.isEmpty ? nil : NotchBadge(count: files.count) }

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
        NotchHub.shared.tabDidChange(id: id)
    }
    func remove(_ url: URL) { files.removeAll { $0 == url }; NotchHub.shared.tabDidChange(id: id) }
    func clear() { files.removeAll(); NotchHub.shared.tabDidChange(id: id) }

    func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            NotchHub.shared.presentResult("AirDrop isn't available", ok: false); return
        }
        service.perform(withItems: urls)
    }

    func accept(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ShelfTab.shared.add([url]) }
            }
        }
        return true
    }

    func makeBody() -> AnyView { AnyView(ShelfView(model: self)) }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The band already names the tab; the row only counts what is kept and acts on it.
            if !model.files.isEmpty {
                HStack(spacing: 8) {
                    Text("\(model.files.count) item\(model.files.count == 1 ? "" : "s")")
                        .font(.system(size: 12.5)).foregroundStyle(MouthyTheme.cream2)
                    Spacer(minLength: 0)
                    PillButton(title: "AirDrop all", symbol: "dot.radiowaves.left.and.right") { model.airDrop(model.files) }
                    PillButton(title: "Clear") { model.clear() }
                }
            }
            ZStack {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(MouthyTheme.glow.opacity(model.targeted ? 0.08 : 0))
                shape.strokeBorder(model.targeted ? MouthyTheme.glow : MouthyTheme.cream2.opacity(0.35),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                if model.files.isEmpty {
                    VStack(spacing: 6) {
                        MascotGlyph(pose: model.targeted ? .listen : .sleep, size: 40)
                            .contentTransition(.opacity)
                        Text(model.targeted ? "Let go to keep it here" : "Drop files on the notch to keep them here")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(model.targeted ? MouthyTheme.cream : MouthyTheme.cream2)
                        if !model.targeted {
                            Text("Drag them out later, or AirDrop them.").font(.system(size: 12.5)).foregroundStyle(MouthyTheme.cream3)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.files, id: \.self) { url in ShelfItem(url: url, model: model) }
                        }
                        .padding(12)
                    }
                }
            }
            .scaleEffect(model.targeted ? 1.01 : 1)
            .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: model.targeted)
            .onDrop(of: [.fileURL], isTargeted: $model.targeted) { model.accept($0) }
        }
    }
}

struct ShelfItem: View {
    let url: URL
    let model: ShelfTab
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: AppIcons.warm(NSWorkspace.shared.icon(forFile: url.path), side: 48)).warmIcon().frame(width: 48, height: 48)
                .scaleEffect(hovering ? 1.06 : 1)
            Text(url.lastPathComponent).font(.system(size: 12)).foregroundStyle(MouthyTheme.cream)
                .lineLimit(2).multilineTextAlignment(.center).frame(width: 84)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MouthyTheme.cream.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(MouthyMotion.press, value: hovering)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("AirDrop") { model.airDrop([url]) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open") { NSWorkspace.shared.open(url) }
            Divider()
            Button("Remove from shelf") { model.remove(url) }
        }
        .help(url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(url.lastPathComponent)
    }
}
