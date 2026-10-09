import SwiftUI
import AppKit
import AVFoundation
import MouthyNotch

/// A meeting folder Mouthy recorded (or that was opened for notes).
struct MeetingRecord: Identifiable, Equatable {
    let folder: URL
    let date: Date
    /// Length of the longer track, when readable.
    let duration: TimeInterval?
    let hasNotes: Bool
    var id: String { folder.path }

    /// Reads a meeting folder: its date, track length and whether notes exist. Nil when it holds no meeting.
    static func read(_ folder: URL) -> MeetingRecord? {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        let tracks = ["Microphone.wav", "System audio.wav"].map { folder.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        let notes = fm.fileExists(atPath: folder.appendingPathComponent("Meeting notes.md").path)
        guard !tracks.isEmpty || notes else { return nil }
        let values = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let lengths = tracks.compactMap { url -> TimeInterval? in
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }
        return MeetingRecord(folder: folder, date: stampDate(folder.lastPathComponent) ?? values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                             duration: lengths.max(), hasNotes: notes)
    }
}

extension MeetingRecord {
    /// The start time in a folder name Mouthy made ("Mouthy meeting 2026-10-05T14-30-00Z", written in UTC).
    static func stampDate(_ name: String) -> Date? {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.date(from: String(name[range]))
    }
}

/// The meetings recorded on this Mac, newest first: folder paths only (never audio or text), kept in defaults.
@MainActor
final class MeetingLibrary: ObservableObject {
    static let shared = MeetingLibrary()
    static let limit = 30
    @Published private(set) var records: [MeetingRecord] = []
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "recentMeetingFolders") {
        self.defaults = defaults; self.key = key
    }

    private var paths: [String] {
        get { defaults.stringArray(forKey: key) ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// Adds a meeting folder to the top of the list.
    func remember(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        paths = Array(([path] + paths.filter { $0 != path }).prefix(Self.limit))
        refresh()
    }

    func forget(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        paths = paths.filter { $0 != path }
        refresh()
    }

    /// Re-reads every remembered folder; folders that were moved or deleted drop out.
    func refresh() {
        let found = paths.compactMap { MeetingRecord.read(URL(fileURLWithPath: $0, isDirectory: true)) }
        let next = found.sorted { $0.date > $1.date }
        if next != records { records = next }
    }
}

struct MeetingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingRecorder
    @ObservedObject var library: MeetingLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor init(model: AppModel, meeting: MeetingRecorder, library: MeetingLibrary? = nil) {
        self.model = model; self.meeting = meeting; self.library = library ?? .shared
    }

    var body: some View {
        Group {
            if let folder = model.openTranscript, let viewer = TranscriptView(folder: folder, close: { model.openTranscript = nil }) {
                viewer
            } else {
                overview
            }
        }
        .task {
            if let folder = meeting.folder { library.remember(folder) } else { library.refresh() }
        }
        .onChange(of: meeting.folder) { _, folder in if let folder { library.remember(folder) } }
        .onChange(of: meeting.working) { _, working in if !working { library.refresh() } }
        .onChange(of: model.openTranscript) { _, folder in if let folder { library.remember(folder) } }
        .onChange(of: model.setupBusy) { _, busy in if !busy { library.refresh() } }
    }

    private var active: Bool { meeting.recording || meeting.working }
    private var locked: Bool { model.busy || model.setupBusy }

    private var overview: some View {
        PageScroll {
            PageHeader("Meetings", subtitle: "Your microphone and the call, saved as separate tracks on this Mac.") {
                Button { model.chooseMeetingForNotes() } label: { Label("Open a meeting…", systemImage: "folder") }
                    .buttonStyle(.compactGlass)
                    .disabled(locked)
            }
            hero
            if library.records.isEmpty {
                Tile(style: .dashed) {
                    MascotEmptyState(pose: .sleep, title: "No meetings recorded",
                                     message: "I record your microphone and the call's audio as separate files, only after you press record.")
                        .frame(minHeight: 280)
                }
                .transition(.opacity)
            } else {
                TileHeader("Past meetings", symbol: "clock.arrow.circlepath")
                    .padding(.top, 8)
                ForEach(library.records) { record in
                    MeetingRow(record: record, locked: locked,
                               makeNotes: { model.makeMeetingNotes(folder: record.folder) },
                               openNotes: { open(record) },
                               reveal: { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: record.folder.path) },
                               forget: { withAnimation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion)) { library.forget(record.folder) } })
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion), value: library.records)
    }

    private func open(_ record: MeetingRecord) {
        if MeetingNotes.load(record.folder) != nil { model.openTranscript = record.folder } else { model.makeMeetingNotes(folder: record.folder) }
    }

    // MARK: Hero

    private var hero: some View {
        Tile(padding: 24, style: .hero) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 22) {
                    MeetingRecordButton(recording: active, enabled: active || !locked) {
                        if active { meeting.cancel() } else { model.startMeeting() }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(heroTitle)
                            .font(MouthyType.headline)
                            .foregroundStyle(MouthyTheme.cream)
                            .contentTransition(.interpolate)
                        clock
                        Text(active || meeting.folder != nil ? meeting.message : "Press the button, then pick where the meeting folder goes.")
                            .font(MouthyType.caption)
                            .foregroundStyle(MouthyTheme.cream2)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                        meterRow("Mic", symbol: "mic.fill") {
                            if meeting.recording { MouthyWaveform(level: 0, active: true, bars: 21, height: 26, feed: model.voice) } else { MouthyWaveform(level: 0, active: false, bars: 21, height: 26) }
                        }
                        meterRow("System", symbol: "speaker.wave.2.fill") {
                            // System audio has no live level; while it records, a soft sweep shows the track is running.
                            MouthyWaveform(level: 0, active: false, bars: 21, height: 26, sweep: meeting.recording)
                        }
                    }
                    .opacity(meeting.recording ? 1 : 0.55)
                }
                SettingDivider()
                Label {
                    Text("Tell everyone before you record. Headphones keep the call from recording twice. Up to two hours.")
                        .lineLimit(1).truncationMode(.tail)
                } icon: {
                    Image(systemName: "person.2.wave.2").foregroundStyle(MouthyTheme.glow)
                }
                .font(MouthyType.caption)
                .foregroundStyle(MouthyTheme.cream2)
            }
        }
        .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: active)
    }

    private var heroTitle: String {
        if meeting.recording { return "Recording" }
        if meeting.working { return "Getting ready" }
        return "Record a meeting"
    }

    /// Elapsed time while recording; the system updates the text itself, only while it is shown.
    @ViewBuilder private var clock: some View {
        if meeting.recording, let start = recordingStart {
            Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: true)
                .font(MouthyType.numeralLarge)
                .foregroundStyle(MouthyTheme.cream)
        } else {
            Text("0:00")
                .font(MouthyType.numeralLarge)
                .foregroundStyle(MouthyTheme.cream3)
        }
    }

    /// The meeting folder is created when capture starts.
    private var recordingStart: Date? {
        guard let folder = meeting.folder else { return nil }
        return (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private func meterRow<Meter: View>(_ title: String, symbol: String, @ViewBuilder meter: () -> Meter) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(MouthyTheme.cream2)
                .frame(width: 70, alignment: .leading)
            meter()
        }
    }
}


/// The 64 pt round orange record button: a dot to start, a square to stop, with a glow ring while recording.
private struct MeetingRecordButton: View {
    let recording: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: recording ? "stop.fill" : "circle.fill")
                .font(.system(size: recording ? 20 : 17, weight: .bold))
                .foregroundStyle(MouthyTheme.night)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 64, height: 64)
                .background {
                    Circle().fill(MouthyTheme.primaryFill)
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [MouthyTheme.cream.opacity(0.4), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                        .shadow(color: MouthyTheme.orange.opacity(enabled ? (recording ? 0.55 : 0.35) : 0), radius: recording ? 18 : 12, y: 4)
                }
                .overlay {
                    Circle().strokeBorder(MouthyTheme.glow.opacity(recording ? 0.55 : 0), lineWidth: 2)
                        .padding(-6)
                }
                .contentShape(Circle())
        }
        .buttonStyle(RecordPressStyle())
        .brightness(hovering && enabled ? 0.05 : 0)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .animation(MouthyMotion.resolve(MouthyMotion.pose, reduceMotion: reduceMotion), value: recording)
        .help(recording ? "Stop and keep the audio" : "Start a meeting")
        .accessibilityLabel(recording ? "Stop meeting" : "Start meeting")
        .sensoryFeedback(.start, trigger: recording) { _, new in new }
    }

    private struct RecordPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(MouthyMotion.press, value: configuration.isPressed)
        }
    }
}

/// One past meeting: when, how long, and its notes action.
private struct MeetingRow: View {
    let record: MeetingRecord
    let locked: Bool
    let makeNotes: () -> Void
    let openNotes: () -> Void
    let reveal: () -> Void
    let forget: () -> Void

    var body: some View {
        Tile(padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: record.hasNotes ? "doc.text.fill" : "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MouthyTheme.glow)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).fill(MouthyTheme.raised))
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(MouthyTheme.cream)
                    Text(detail)
                        .font(MouthyType.caption)
                        .foregroundStyle(MouthyTheme.cream2)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if record.hasNotes {
                    Button("Open notes", action: openNotes).buttonStyle(.compactGlass)
                } else {
                    Button("Make notes", action: makeNotes).buttonStyle(.compactGlass).disabled(locked)
                }
                MouthyIconButton(symbol: "folder", help: "Show in Finder · \(record.folder.lastPathComponent)", action: reveal)
            }
        }
        .tileHover()
        .contextMenu {
            if record.hasNotes { Button("Open notes", action: openNotes) } else { Button("Make notes", action: makeNotes).disabled(locked) }
            Button("Show in Finder", action: reveal)
            Divider()
            Button("Remove from list", action: forget)
        }
    }

    /// "1 hr 5 min", "21 min", "45 sec".
    static func length(_ seconds: TimeInterval) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 60 ? [.seconds] : [.hours, .minutes]
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2))
    }

    private var detail: String {
        var parts: [String] = []
        if let duration = record.duration { parts.append(Self.length(duration)) }
        parts.append(record.hasNotes ? "Notes ready" : "Audio only")
        return parts.joined(separator: " · ")
    }
}
