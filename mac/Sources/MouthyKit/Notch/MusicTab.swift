import AppKit
import MouthyNotch
import SwiftUI

/// Now playing from Apple Music and Spotify (their own track-change broadcasts; no polling, no
/// automation permission), media-key controls, and synced lyrics from LRCLIB.
@MainActor final class MusicTab: ObservableObject, NotchTab {
    static let shared = MusicTab()
    struct Track: Equatable {
        var title: String; var artist: String; var album: String
        var duration: TimeInterval; var player: String
    }
    struct LyricLine: Equatable { let time: TimeInterval; let text: String }

    let id = "mouthy.music"
    let title = "Music"
    let symbolName = "music.note"
    @Published private(set) var track: Track?
    @Published private(set) var playing = false
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var plainLyrics: String?
    @Published private(set) var lyricsStatus = ""
    @Published var lyricsEnabled = true
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artColor: Color?
    var ambientColor: Color? { track == nil ? nil : artColor ?? NotchStyle.accent }
    private var artworkTask: Task<Void, Never>?
    /// Playback position at `positionDate`.
    private var position: TimeInterval = 0
    private var positionDate = Date()
    private var observers: [NSObjectProtocol] = []
    private var lyricsTask: Task<Void, Never>?

    private init() {}

    func startWatching() {
        guard observers.isEmpty else { return }
        defer { askWhatIsPlaying() }
        let center = DistributedNotificationCenter.default()
        observers = [
            center.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { note in
                let info = note.userInfo ?? [:]
                Task { @MainActor in MusicTab.shared.update(info, player: "Music") }
            },
            center.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { note in
                let info = note.userInfo ?? [:]
                Task { @MainActor in MusicTab.shared.update(info, player: "Spotify") }
            }
        ]
    }

    func stopWatching() {
        let center = DistributedNotificationCenter.default()
        observers.forEach(center.removeObserver)
        observers = []
        lyricsTask?.cancel(); lyricsTask = nil
    }

    func update(_ info: [AnyHashable: Any], player: String) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" { track = nil; playing = false; lyrics = []; plainLyrics = nil; artwork = nil; changed(); return }
        let title = info["Name"] as? String ?? track?.title ?? ""
        let artist = info["Artist"] as? String ?? track?.artist ?? ""
        let album = info["Album"] as? String ?? ""
        let milliseconds = (info["Total Time"] as? NSNumber ?? info["Duration"] as? NSNumber)?.doubleValue ?? 0
        let next = Track(title: title, artist: artist, album: album, duration: milliseconds / 1000, player: player)
        let newTrack = next.title != track?.title || next.artist != track?.artist
        let now = currentPosition
        if let reported = (info["Playback Position"] as? NSNumber)?.doubleValue {
            position = reported   // Spotify reports where it is.
        } else {
            position = newTrack ? 0 : now   // Music only says it changed; carry our own clock.
        }
        positionDate = Date()
        playing = state == "Playing"
        track = next
        if newTrack {
            fetchLyrics(next); fetchArtwork(next, url: (info["Artwork URL"] as? String).flatMap(URL.init(string:)))
            // Let the art arrive first so the card shows it.
            Task { [weak self] in try? await Task.sleep(for: .milliseconds(700)); if self?.playing == true { self?.peekNewTrack() } }
        }
        changed()
    }

    var currentPosition: TimeInterval {
        playing ? position + Date().timeIntervalSince(positionDate) : position
    }

    func currentLineIndex(at time: TimeInterval) -> Int? {
        lyrics.lastIndex { $0.time <= time + 0.3 }
    }

    /// When each upcoming lyric line starts, so the lyrics redraw only when the line changes (a pause, seek or
    /// new track republishes the model and recomputes this).
    func lyricChanges(from now: Date = Date()) -> [Date] {
        guard playing else { return [] }
        let at = currentPosition
        return lyrics.compactMap { $0.time - 0.3 > at ? now.addingTimeInterval($0.time - 0.3 - at) : nil }
    }

    /// Renders and the CPU harness: synced lyrics without a network fetch.
    func showLyricsForPreview(_ lines: [LyricLine]) { lyricsTask?.cancel(); lyrics = lines; plainLyrics = nil; changed() }

    private func fetchLyrics(_ track: Track) {
        lyricsTask?.cancel(); lyrics = []; plainLyrics = nil
        guard lyricsEnabled, !track.title.isEmpty else { lyricsStatus = ""; return }
        guard MouthyTabs.networkAllowed() else { lyricsStatus = "Off while network use is blocked"; return }
        lyricsStatus = "Looking for lyrics…"
        lyricsTask = Task { [weak self] in
            let result = await LyricsClient.fetch(track)
            guard !Task.isCancelled, let self, self.track == track else { return }
            self.lyrics = result.synced; self.plainLyrics = result.plain
            self.lyricsStatus = result.synced.isEmpty && result.plain == nil ? "No lyrics for this song" : ""
        }
    }

    /// Cover art from Apple's public iTunes lookup, matched on artist and title.
    private func fetchArtwork(_ track: Track, url: URL? = nil) {
        artworkTask?.cancel(); artwork = nil; artColor = nil
        guard !track.title.isEmpty, MouthyTabs.networkAllowed() else { return }
        artworkTask = Task { [weak self] in
            var image: NSImage?
            if let url, MouthyTabs.networkAllowed(), let (data, _) = try? await URLSession.shared.data(from: url) { image = NSImage(data: data) }
            if image == nil { image = await ArtworkClient.fetch(track) }
            guard !Task.isCancelled, let self, self.track == track else { return }
            self.artwork = image
            self.artColor = image.flatMap(ambientColor(of:))
            self.changed()
        }
    }

    /// The players only broadcast changes, so at launch ask whichever is running what is playing now.
    /// Asks only apps that are already open (never launches them); macOS asks once for permission.
    func askWhatIsPlaying() {
        let players: [(id: String, name: String, script: String)] = [
            ("com.spotify.client", "Spotify", """
            tell application id "com.spotify.client"
                if player state is not playing then return {}
                set t to current track
                return {name of t, artist of t, album of t, (duration of t) as real, player position as real, artwork url of t}
            end tell
            """),
            ("com.apple.Music", "Music", """
            tell application id "com.apple.Music"
                if player state is not playing then return {}
                set t to current track
                return {name of t, artist of t, album of t, ((duration of t) * 1000) as real, player position as real, ""}
            end tell
            """)]
        for player in players where !NSRunningApplication.runningApplications(withBundleIdentifier: player.id).isEmpty {
            let source = player.script, name = player.name
            Task.detached(priority: .utility) {
                var error: NSDictionary?
                guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), result.numberOfItems == 6 else { return }
                let item = { (index: Int) in result.atIndex(index)?.stringValue ?? "" }
                let info: [String: Any] = ["Name": item(1), "Artist": item(2), "Album": item(3), "Player State": "Playing",
                                           "Duration": NSNumber(value: Double(item(4)) ?? 0), "Playback Position": NSNumber(value: Double(item(5)) ?? 0),
                                           "Artwork URL": item(6)]
                await MainActor.run { MusicTab.shared.update(info, player: name) }
            }
        }
    }

    // MARK: Controls — system media keys reach whichever app is playing.
    func playPause() { MediaKeys.press(16) }
    func next() { MediaKeys.press(17) }
    func previous() { MediaKeys.press(18) }

    private func changed() { NotchHub.shared.tabDidChange(id: id) }

    func makeBody() -> AnyView { AnyView(MusicView(model: self)) }
    /// Playing music keeps the band over a running timer (its ears only exist while something plays): a missing
    /// cover reads as a broken hub. Only the minutes before a meeting outrank it.
    var compactPriority: Int { Self.playingPriority }
    static let playingPriority = 25
    func compactLeading() -> AnyView? {
        guard playing, track != nil else { return nil }
        return AnyView(MiniArt(image: artwork, tint: artColor ?? MouthyTheme.orange, size: 20))
    }
    var compactCaption: String? { playing ? track?.title : nil }
    func compactBody() -> AnyView? {
        guard playing, track != nil else { return nil }
        // Always the theme's glow: tinted with the cover, red art drew a red squiggle that read as a stray glyph.
        return AnyView(EqualizerBars(playing: playing, tint: MouthyTheme.glow))
    }

    /// The card that drops out of the notch when the song changes.
    private func peekNewTrack() {
        guard let track else { return }
        NotchHub.shared.peek(AnyView(TrackPeek(model: self, track: track)), seconds: 3.5,
                             leading: compactLeading(), trailing: compactBody(), title: track.title)
    }
}

/// Cover art, or a cocoa tile with the sleeping giraffe when there is none.
struct MiniArt: View {
    let image: NSImage?
    let tint: Color
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { ArtFallback(size: size) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// No artwork: warm cocoa with the giraffe asleep on it.
struct ArtFallback: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            LinearGradient(colors: [MouthyTheme.raised, MouthyTheme.surface], startPoint: .top, endPoint: .bottom)
            MascotGlyph(pose: .sleep, size: size * 0.66)
        }
    }
}

/// The card that drops out of the notch when the song changes: the standard peek layout.
struct TrackPeek: View {
    @ObservedObject var model: MusicTab
    let track: MusicTab.Track
    var body: some View {
        NotchPeekRow(title: track.title, detail: track.artist,
                     accessory: AnyView(EqualizerBars(playing: model.playing, tint: model.artColor ?? MouthyTheme.glow, bars: 5, height: 18))) {
            MiniArt(image: model.artwork, tint: model.artColor ?? MouthyTheme.orange, size: 24)
        }
    }
}

enum MediaKeys {
    /// NX_KEYTYPE_PLAY 16, NEXT 17, PREVIOUS 18, posted as the same system event the keyboard sends.
    static func press(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

enum ArtworkClient {
    private struct Response: Decodable { struct Item: Decodable { let artworkUrl100: String?; let artistName: String?; let trackName: String? }; let results: [Item] }
    /// Nil, without any request, in Local Only Mode.
    static func fetch(_ track: MusicTab.Track) async -> NSImage? {
        guard await MouthyTabs.networkAllowed() else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [.init(name: "term", value: "\(track.artist) \(track.title)"), .init(name: "entity", value: "song"), .init(name: "limit", value: "5")]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
              let items = try? JSONDecoder().decode(Response.self, from: data).results else { return nil }
        let match = items.first { $0.artistName?.localizedCaseInsensitiveContains(track.artist) == true } ?? items.first
        guard let small = match?.artworkUrl100, let url = URL(string: small.replacingOccurrences(of: "100x100", with: "300x300")),
              let (imageData, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: imageData)
    }
}

enum LyricsClient {
    struct Result { var synced: [MusicTab.LyricLine]; var plain: String? }
    private struct Response: Decodable { let plainLyrics: String?; let syncedLyrics: String? }

    /// Empty, without any request, in Local Only Mode.
    static func fetch(_ track: MusicTab.Track) async -> Result {
        guard await MouthyTabs.networkAllowed() else { return Result(synced: [], plain: nil) }
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            .init(name: "track_name", value: track.title), .init(name: "artist_name", value: track.artist),
            .init(name: "album_name", value: track.album)] + (track.duration > 0 ? [.init(name: "duration", value: String(Int(track.duration.rounded())))] : [])
        var request = URLRequest(url: components.url!, timeoutInterval: 8)
        request.setValue("Mouthy (https://mouthy.dev)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(Response.self, from: data) else { return Result(synced: [], plain: nil) }
        return Result(synced: parse(body.syncedLyrics ?? ""), plain: body.plainLyrics)
    }

    /// "[01:02.34] words" lines into timed lines.
    static func parse(_ lrc: String) -> [MusicTab.LyricLine] {
        lrc.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) else { return nil }
            return MusicTab.LyricLine(time: minutes * 60 + seconds, text: line[line.index(after: close)...].trimmingCharacters(in: .whitespaces))
        }
    }
}

struct MusicView: View {
    @ObservedObject var model: MusicTab
    var body: some View {
        content
            .background(alignment: .leading) {
                if let art = model.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 320, height: 320).blur(radius: 60).opacity(0.3)
                        .offset(x: -80).allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.8), value: model.artwork)
    }
    @ViewBuilder private var content: some View {
        if let track = model.track {
            let tint = model.artColor ?? MouthyTheme.orange
            HStack(alignment: .center, spacing: 16) {
                // Cover
                MiniArt(image: model.artwork, tint: tint, size: 88)
                    .overlay(RoundedRectangle(cornerRadius: 88 * 0.24, style: .continuous).strokeBorder(MouthyTheme.cream.opacity(0.12), lineWidth: 0.6))
                    .compositingGroup()
                    .shadow(color: tint.opacity(0.45), radius: 16, y: 6)
                    .scaleEffect(model.playing ? 1 : 0.95)
                    .animation(MouthyMotion.pose, value: model.playing)

                // Title, progress, controls
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream).lineLimit(1)
                    Text(track.artist).font(.system(size: 13)).foregroundStyle(MouthyTheme.cream2).lineLimit(1).padding(.top, 2)
                    Spacer(minLength: 6)
                    if track.duration > 0 {
                        TimelineView(.periodic(from: .now, by: model.playing ? 1 : 3600)) { _ in
                            let position = min(model.currentPosition, track.duration)
                            VStack(spacing: 4) {
                                GeometryReader { bar in
                                    ZStack(alignment: .leading) {
                                        Capsule(style: .circular).fill(MouthyTheme.cream.opacity(0.12))
                                        Capsule(style: .circular).fill(LinearGradient(colors: [MouthyTheme.orange, MouthyTheme.glowHi], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: max(5, bar.size.width * position / track.duration))
                                    }
                                }
                                .frame(height: 5)
                                HStack {
                                    Text(formatClock(position)); Spacer(); Text("-" + formatClock(track.duration - position))
                                }
                                .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(MouthyTheme.cream2)
                            }
                        }
                    }
                    HStack(spacing: 18) {
                        Button { model.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 15)) }
                            .help("Previous").accessibilityLabel("Previous track")
                        Button { model.playPause() } label: {
                            Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 14))
                                .foregroundStyle(MouthyTheme.night)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(MouthyTheme.primaryFill))
                                .compositingGroup()
                                .shadow(color: MouthyTheme.orange.opacity(0.35), radius: 8, y: 2)
                        }
                        .help(model.playing ? "Pause" : "Play").accessibilityLabel(model.playing ? "Pause" : "Play")
                        Button { model.next() } label: { Image(systemName: "forward.fill").font(.system(size: 15)) }
                            .help("Next").accessibilityLabel("Next track")
                    }
                    .buttonStyle(NotchPressStyle())
                    .foregroundStyle(MouthyTheme.cream)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Lyrics only when this song has them, or a short note why not
                if !model.lyrics.isEmpty || model.plainLyrics != nil || !model.lyricsStatus.isEmpty {
                    LyricsPane(model: model).frame(width: 150)
                }
            }
            .padding(.vertical, 2)
        } else {
            NotchEmptyState(pose: .sleep, title: "Nothing playing", message: "Play something in Music or Spotify.")
        }
    }
}

struct LyricsPane: View {
    @ObservedObject var model: MusicTab
    var body: some View {
        Group {
            if !model.lyrics.isEmpty {
                TimelineView(.explicit(model.lyricChanges())) { _ in
                    let current = model.currentLineIndex(at: model.currentPosition)
                    ScrollViewReader { reader in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(model.lyrics.enumerated()), id: \.offset) { index, line in
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(.system(size: index == current ? 18 : 14, weight: index == current ? .bold : .medium, design: .rounded))
                                        .foregroundStyle(index == current ? MouthyTheme.cream : MouthyTheme.cream2.opacity(abs(index - (current ?? 0)) == 1 ? 0.7 : 0.4))
                                        .shadow(color: index == current ? (model.artColor ?? MouthyTheme.glow).opacity(0.6) : .clear, radius: 8)
                                        .blur(radius: abs(index - (current ?? 0)) > 2 ? 0.6 : 0)
                                        .animation(.smooth(duration: 0.35), value: current)
                                        .id(index)
                                }
                            }
                            .padding(.vertical, 40)
                        }
                        .onChange(of: current) { _, line in
                            guard let line else { return }
                            withAnimation(.smooth(duration: 0.35)) { reader.scrollTo(line, anchor: .center) }
                        }
                    }
                }
            } else if let plain = model.plainLyrics {
                ScrollView(showsIndicators: false) { Text(plain).font(.system(size: 14)).foregroundStyle(MouthyTheme.cream2) }
            } else {
                Text(model.lyricsEnabled ? model.lyricsStatus : "Lyrics are off").font(.system(size: 13.5)).foregroundStyle(MouthyTheme.cream2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                     .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}
