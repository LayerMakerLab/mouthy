import AppKit
import Foundation
import MouthyNotch
import SwiftUI

/// Runs the person's Shortcuts through Apple's `shortcuts` command. The list loads when the tab opens.
@MainActor final class ShortcutsTab: ObservableObject, NotchTab {
    static let shared = ShortcutsTab()
    let id = "mouthy.shortcuts"
    let title = "Shortcuts"
    let symbolName = "square.stack.3d.up"
    @Published private(set) var names: [String] = []
    @Published private(set) var running: String?
    @Published private(set) var loading = false
    /// The list didn't arrive within `NotchLoad.timeout`; the tab offers Retry.
    @Published private(set) var timedOut = false
    @Published var search = ""
    @Published var pinned: [String] { didSet { NotchFile.save(pinned, "shortcuts.json") } }
    private var loadedAt: Date?
    private var timeoutTask: Task<Void, Never>?
    private var generation = 0

    private init() { pinned = NotchFile.load([String].self, "shortcuts.json") ?? [] }

    func load(force: Bool = false) {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 120 { return }
        if loading && !force { return }
        generation &+= 1
        let current = generation
        loading = true
        timedOut = false
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: NotchLoad.timeout) } catch { return }
            guard let self, self.generation == current, self.loading else { return }
            self.timedOut = true
        }
        Task.detached(priority: .utility) {
            let output = (try? Self.shortcuts(["list"])) ?? ""
            let names = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            await MainActor.run {
                let tab = ShortcutsTab.shared
                guard tab.generation == current else { return }
                tab.names = names; tab.loading = false; tab.timedOut = false; tab.loadedAt = Date()
                tab.timeoutTask?.cancel()
            }
        }
    }

    /// Renders and previews: shows `names` as if the list had just loaded, without running `shortcuts`.
    func showForPreview(names: [String]) {
        generation &+= 1
        timeoutTask?.cancel()
        self.names = names; loading = false; timedOut = false; loadedAt = Date()
    }

    func run(_ name: String) {
        guard running == nil else { return }
        running = name
        Task.detached(priority: .userInitiated) {
            let ok = (try? Self.shortcuts(["run", name])) != nil
            await MainActor.run {
                ShortcutsTab.shared.running = nil
                NotchHub.shared.presentResult(ok ? "Ran \(name)" : "\(name) didn't finish", ok: ok)
            }
        }
    }

    func togglePin(_ name: String) {
        if let index = pinned.firstIndex(of: name) { pinned.remove(at: index) } else { pinned.append(name) }
    }

    nonisolated static func shortcuts(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: data, as: UTF8.self)
    }

    func makeBody() -> AnyView { load(); return AnyView(ShortcutsView(model: self)) }
}

struct ShortcutsView: View {
    @ObservedObject var model: ShortcutsTab
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 8)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.names.isEmpty {
                if model.timedOut {
                    NotchEmptyState(pose: .sleep, title: "Shortcuts didn't answer", message: "That took too long.", actionTitle: "Retry") {
                        model.load(force: true)
                    }
                } else if model.loading {
                    skeleton
                } else {
                    NotchEmptyState(pose: .sleep, title: "No shortcuts yet", message: "Make one in the Shortcuts app and it shows up here.",
                                    actionTitle: "Open Shortcuts") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                    }
                }
            } else {
                NotchField(prompt: "Search shortcuts", text: $model.search)
                let shown = model.search.isEmpty ? model.names : model.names.filter { $0.localizedCaseInsensitiveContains(model.search) }
                let ordered = model.pinned.filter(shown.contains) + shown.filter { !model.pinned.contains($0) }
                if ordered.isEmpty {
                    NotchEmptyState(pose: .sleep, title: "No matches")
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(ordered, id: \.self) { name in
                                ShortcutButton(name: name, running: model.running == name, pinned: model.pinned.contains(name)) { model.run(name) }
                                    .contextMenu { Button(model.pinned.contains(name) ? "Unpin" : "Pin to top") { model.togglePin(name) } }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .notchScrollFade()
                }
            }
        }
    }

    /// The real layout with placeholder names, shimmering until the list arrives.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchField(prompt: "Search shortcuts", text: .constant(""))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(["Morning routine", "Log water", "Focus playlist", "Text arrival", "Resize image", "New note"], id: \.self) { name in
                    ShortcutButton(name: name, running: false, pinned: false) {}
                }
            }
        }
        .notchSkeleton(loading: model.loading)
        .allowsHitTesting(false)
    }
}

struct ShortcutButton: View {
    let name: String
    let running: Bool
    let pinned: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: running ? "hourglass" : pinned ? "pin.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(pinned || running || hovering ? MouthyTheme.glow : MouthyTheme.cream2)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14)
                Text(name).font(.system(size: 14)).foregroundStyle(MouthyTheme.cream).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(minHeight: 32)
            .smokedGlass(RoundedRectangle(cornerRadius: 10, style: .continuous), lit: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .help(running ? "Running…" : "Run \(name)")
    }
}
