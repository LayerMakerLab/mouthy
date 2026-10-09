import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MouthyCore
import MouthyNotch

struct FileResult: Identifiable {
    let id = UUID()
    let url: URL
    var state = "Queued"
    var document: TranscriptionDocument?
}

/// Files: drop or choose audio and video, get text or subtitles, all on this Mac.
struct FilesView: View {
    @ObservedObject var model: AppModel
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var batchRunning: Bool { model.busy && model.fileResults.contains { FileState($0.state) == .transcribing || FileState($0.state) == .queued } }
    private var finished: Int { model.fileResults.filter { ![.queued, .transcribing].contains(FileState($0.state)) }.count }

    var body: some View {
        PageScroll {
            PageHeader("Files", subtitle: "Audio or video to text or subtitles, on this Mac. Nothing is uploaded.") {
                if batchRunning {
                    Button { model.cancel() } label: { Label("Cancel batch", systemImage: "xmark") }
                        .buttonStyle(.compactGlass)
                } else if !model.fileResults.isEmpty {
                    Button { model.importAudio() } label: { Label("Add files", systemImage: "plus") }
                        .buttonStyle(.compactGlass)
                        .disabled(model.busy || model.setupBusy)
                }
            }
            dropTile
            if !model.fileResults.isEmpty {
                if batchRunning {
                    batchProgress
                        .transition(.opacity)
                }
                ForEach(model.fileResults) { item in
                    FileRow(item: item, model: model)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                Text("Results stay in memory. Export them before you quit.")
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion), value: model.fileResults.map(\.id))
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: batchRunning)
    }

    // MARK: Drop zone

    private var compact: Bool { !model.fileResults.isEmpty }

    private var dropTile: some View {
        let shape = RoundedRectangle(cornerRadius: MouthyTheme.Radius.tile, style: .continuous)
        return Group {
            if compact {
                HStack(spacing: 16) {
                    MascotView(pose: batchRunning ? .type : .listen, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(targeted ? "Let go to transcribe" : "Drop more recordings here")
                            .font(MouthyType.headline).foregroundStyle(MouthyTheme.cream)
                        Text("Audio or video becomes text, JSON, SRT or VTT.")
                            .font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                    }
                    Spacer(minLength: 12)
                    Button("Choose files") { model.importAudio() }
                        .buttonStyle(.compactGlass)
                        .disabled(model.busy || model.setupBusy)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
            } else {
                VStack(spacing: 12) {
                    MascotView(pose: .listen, size: 150)
                    Text(targeted ? "Let go to transcribe" : "Drop a recording here")
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                    Text("Audio or video becomes text, JSON, SRT or VTT. Only models you have downloaded are used.")
                        .font(MouthyType.body).foregroundStyle(MouthyTheme.cream2)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button { model.importAudio() } label: { Label("Choose a file", systemImage: "doc.badge.plus") }
                            .buttonStyle(.mouthyPrimary)
                            .disabled(model.busy || model.setupBusy)
                        if !model.speechAssetsReady {
                            Button { model.installAssets() } label: { Label("Download a model", systemImage: "arrow.down.circle") }
                                .buttonStyle(.mouthySecondary)
                                .disabled(model.setupBusy || model.busy || model.preferences.localOnly)
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(.vertical, 40).padding(.horizontal, 24)
                .frame(maxWidth: .infinity, minHeight: 380)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                if targeted {
                    Color.clear.mouthyGlass(shape, tint: MouthyTheme.orange.opacity(0.18))
                        .transition(.opacity)
                }
                shape.strokeBorder(targeted ? MouthyTheme.glow : MouthyTheme.cream2.opacity(0.35),
                                   style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: targeted ? [] : [6, 5]))
                    .shadow(color: MouthyTheme.glow.opacity(targeted ? 0.45 : 0), radius: 14)
            }
        }
        .contentShape(shape)
        .scaleEffect(targeted ? 1.01 : 1)
        .animation(MouthyMotion.resolve(MouthyMotion.press, reduceMotion: reduceMotion), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            let files = FileDrop.transcribable(urls)
            guard !files.isEmpty, !model.busy, !model.setupBusy else {
                if !urls.isEmpty, files.isEmpty { model.status = "I can't read that file type." }
                return false
            }
            model.transcribe(urls: files)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop zone for audio or video files")
    }

    private var batchProgress: some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(finished), total: Double(max(1, model.fileResults.count)))
                .progressViewStyle(MouthyBarProgressStyle())
            Text("\(finished) of \(model.fileResults.count)")
                .font(MouthyType.callout.monospacedDigit()).foregroundStyle(MouthyTheme.cream2)
                .contentTransition(.numericText(value: Double(finished)))
        }
        .padding(.horizontal, 4)
    }
}

/// One file in the batch: symbol, name, state, then its text and Copy/Export once ready.
private struct FileRow: View {
    let item: FileResult
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: FileState { FileState(item.state) }
    private var name: String { item.url.deletingPathExtension().lastPathComponent }

    var body: some View {
        Tile(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).fill(MouthyTheme.raised)
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(iconColor)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.url.lastPathComponent)
                            .font(MouthyType.body.weight(.medium)).foregroundStyle(MouthyTheme.cream)
                            .lineLimit(1).truncationMode(.middle)
                        stateLine
                    }
                    Spacer(minLength: 12)
                    if let document = item.document {
                        GlassEffectContainer(spacing: 6) {
                            HStack(spacing: 6) {
                                MouthyIconButton(symbol: "doc.on.doc", help: "Copy text") {
                                    TextDelivery.copy(document.text); model.status = "Copied to the clipboard."
                                }
                                MouthyIconMenu(symbol: "square.and.arrow.up", help: "Export") {
                                    ForEach(TranscriptionDocument.Format.allCases, id: \.self) { format in
                                        Button(label(format)) { model.exportDocument(document, format: format, name: name) }
                                    }
                                }
                            }
                            .padding(2)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                if state == .transcribing {
                    ProgressView()
                        .progressViewStyle(MouthyBarProgressStyle(height: 4))
                        .transition(.opacity)
                }
                if let document = item.document {
                    Text(document.text.isEmpty ? "No speech found in this file." : document.text)
                        .font(MouthyType.body)
                        .foregroundStyle(document.text.isEmpty ? MouthyTheme.cream2 : MouthyTheme.cream)
                        .lineSpacing(2)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion), value: item.state)
        .contextMenu {
            if let document = item.document {
                Button("Copy Text", systemImage: "doc.on.doc") { TextDelivery.copy(document.text) }
                Menu("Export") {
                    ForEach(TranscriptionDocument.Format.allCases, id: \.self) { format in
                        Button(label(format)) { model.exportDocument(document, format: format, name: name) }
                    }
                }
            }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    @ViewBuilder private var stateLine: some View {
        switch state {
        case .queued: Text("Waiting").font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
        case .cancelled: Text("Cancelled").font(MouthyType.caption).foregroundStyle(MouthyTheme.cream3)
        case .transcribing: Text("Transcribing on this Mac…").font(MouthyType.caption).foregroundStyle(MouthyTheme.glow)
        case .ready:
            let words = item.document?.text.split(whereSeparator: \.isWhitespace).count ?? 0
            Text(words == 1 ? "Ready · 1 word" : "Ready · \(words.formatted()) words").font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
        case .failed(let reason): Text(reason).font(MouthyType.caption).foregroundStyle(MouthyTheme.ember).lineLimit(2)
        }
    }

    private var symbol: String {
        switch state {
        case .ready: "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        case .queued: "clock"
        case .cancelled: "xmark.circle"
        case .transcribing: FileDrop.symbol(for: item.url)
        }
    }

    private var iconColor: Color {
        switch state {
        case .failed: MouthyTheme.ember
        case .queued: MouthyTheme.cream2
        case .cancelled: MouthyTheme.cream3
        default: MouthyTheme.glow
        }
    }

    private func label(_ format: TranscriptionDocument.Format) -> String {
        switch format {
        case .text: "Text…"
        case .json: "Recognition JSON…"
        case .srt: "Subtitles · SRT…"
        case .vtt: "Subtitles · VTT…"
        }
    }
}
