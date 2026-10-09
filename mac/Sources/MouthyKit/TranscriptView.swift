import SwiftUI
import AppKit
import AVFoundation
import MouthyNotch

/// A meeting's transcript: click a line to hear that moment, edit words or speaker names, save
/// back to "Meeting notes.md".
struct TranscriptView: View {
    let folder: URL
    @State private var saved: MeetingNotes.Saved
    @State private var player: AVAudioPlayer?
    @State private var playing: UUID?
    @State private var changed = false
    @State private var message = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let close: () -> Void

    init?(folder: URL, close: @escaping () -> Void) {
        guard let saved = MeetingNotes.load(folder) else { return nil }
        self.folder = folder; self.close = close
        _saved = State(initialValue: saved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array($saved.lines.enumerated()), id: \.element.id) { index, $line in
                        if index > 0 { SettingDivider().opacity(0.6) }
                        TranscriptLineRow(line: $line, playing: playing == line.id, play: { play(line) }) { changed = true }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background { TileBackground(style: .standard) }
                .padding(.bottom, 24)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .frame(maxWidth: MouthyTheme.Layout.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, MouthyTheme.Layout.pageHorizontal)
        .padding(.top, MouthyTheme.Layout.pageTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear { player?.stop() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            MouthyIconButton(symbol: "chevron.left", help: "Back to meetings") { player?.stop(); close() }
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.lastPathComponent)
                    .font(MouthyType.headline).foregroundStyle(MouthyTheme.cream)
                    .lineLimit(1).truncationMode(.middle)
                Text(message.isEmpty ? subtitle : message)
                    .font(MouthyType.caption).foregroundStyle(message.isEmpty ? MouthyTheme.cream2 : MouthyTheme.glow)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    MouthyIconButton(symbol: "person.text.rectangle", help: "Rename a speaker") { renameSpeaker() }
                    Button { save() } label: { Label("Save", systemImage: changed ? "square.and.arrow.down.fill" : "checkmark") }
                        .buttonStyle(.compactGlass)
                        .disabled(!changed)
                        .keyboardShortcut("s")
                }
                .padding(2)
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: message)
    }

    private var subtitle: String {
        let speakers = Set(saved.lines.map(\.speaker)).count
        let lines = saved.lines.count
        return "\(lines) \(lines == 1 ? "line" : "lines") · \(speakers) \(speakers == 1 ? "speaker" : "speakers") · click play to hear a moment"
    }

    private func play(_ line: MeetingNotes.Line) {
        if playing == line.id { player?.stop(); playing = nil; return }
        let file = folder.appendingPathComponent(line.speaker == "You" ? "Microphone.wav" : "System audio.wav")
        guard let audio = try? AVAudioPlayer(contentsOf: file) else { message = "Audio file not found."; return }
        audio.currentTime = max(0, line.start - 0.3)
        audio.play()
        player = audio; playing = line.id
    }

    private func renameSpeaker() {
        let alert = NSAlert(); alert.messageText = "Rename a speaker"
        let names = Array(Set(saved.lines.map(\.speaker))).sorted()
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 240, height: 26)); picker.addItems(withTitles: names)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); field.placeholderString = "New name"
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 58)); stack.addSubview(picker); stack.addSubview(field)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let old = picker.titleOfSelectedItem else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty else { return }
        for index in saved.lines.indices where saved.lines[index].speaker == old { saved.lines[index].speaker = new }
        // The summary refers to speakers by label too.
        saved.summary = saved.summary.replacingOccurrences(of: old, with: new)
        changed = true
    }

    private func save() {
        do { try MeetingNotes.write(saved, to: folder); changed = false; message = "Saved." }
        catch { message = "Could not save: \(error.localizedDescription)" }
    }
}

/// One transcript line: play, time, speaker, and the editable words.
private struct TranscriptLineRow: View {
    @Binding var line: MeetingNotes.Line
    let playing: Bool
    let play: () -> Void
    let edited: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: play) {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(playing ? MouthyTheme.night : MouthyTheme.cream)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(playing ? AnyShapeStyle(MouthyTheme.primaryFill) : AnyShapeStyle(MouthyTheme.raised)))
                    .overlay(Circle().strokeBorder(playing ? .clear : MouthyTheme.hoof, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || playing ? 1 : 0.7)
            .help("Play from \(MeetingNotes.clock(line.start))")
            .accessibilityLabel(playing ? "Stop" : "Play from \(MeetingNotes.clock(line.start))")
            .padding(.top, -4)
            Text(MeetingNotes.clock(line.start))
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(MouthyTheme.cream2)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 1)
            Text(line.speaker)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(MouthyTheme.glow)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
                .padding(.top, 0.5)
            WarmTextEditor(text: $line.text, font: .systemFont(ofSize: 14), accessibilityLabel: "Words spoken by \(line.speaker)") { edited() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous)
            .fill(playing ? MouthyTheme.orange.opacity(0.08) : hovering ? MouthyTheme.hoverFill : .clear)
            .padding(.horizontal, -10))
        .onHover { hovering = $0 }
    }
}
