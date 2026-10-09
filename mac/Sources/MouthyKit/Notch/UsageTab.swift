import CoreServices
import Foundation
import MouthyNotch
import SwiftUI

/// How much of each AI service's limits is used, as percentages counting up to 100%: Claude Code's from
/// its status line (see ClaudeLimitsBridge), Codex's from its own session logs. No token counts.
@MainActor final class UsageTab: ObservableObject, NotchTab {
    static let shared = UsageTab()
    let id = "mouthy.usage"
    let title = "AI usage"
    let symbolName = "gauge.with.dots.needle.50percent"
    @Published private(set) var claude: ServiceLimits?
    @Published private(set) var codex: ServiceLimits?
    @Published private(set) var scanning = false
    @Published private(set) var scannedAt: Date?
    private var stream: FSEventStreamRef?

    private init() {}

    var hasData: Bool { claude?.week != nil || codex?.week != nil }

    /// Reloads when Claude Code saves new limits or Codex writes to its logs: macOS file-system events,
    /// not a timer. Installs the tiny status-line script Claude Code calls (it prints nothing).
    func startWatching() {
        guard stream == nil else { return }
        ClaudeLimitsBridge.install()
        let paths = [ClaudeLimitsBridge.folder.path, Self.codexRoot].filter { FileManager.default.fileExists(atPath: $0) }
        // Claude Code rewrites its limits every few seconds while it works, and Mouthy saves its own files in the same
        // folder: an event there only re-reads that one small file. Codex's logs are scanned only when they change.
        let callback: FSEventStreamCallback = { _, _, _, eventPaths, _, _ in
            let changed = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            let codex = changed.contains { $0.hasPrefix(UsageTab.codexRoot) }
            DispatchQueue.main.async { MainActor.assumeIsolated { UsageTab.shared.refresh(scanCodex: codex) } }
        }
        if !paths.isEmpty, let created = FSEventStreamCreate(nil, callback, nil, paths as CFArray,
                                                             FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                                             FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) {
            FSEventStreamSetDispatchQueue(created, .main)
            FSEventStreamStart(created)
            stream = created
        }
        refresh(force: true)
    }

    func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }

    nonisolated static let codexRoot = UsageScanner.home.appendingPathComponent(".codex/sessions").path

    /// Re-reads Claude's limits and, when asked (or the last scan is 20 s old), scans Codex's logs. The hub and every
    /// view showing usage hear about it only when a number changed, so file activity that changes nothing costs nothing
    /// (each needless publish redrew the notch: 7-13% CPU spikes every few seconds while Claude Code was working).
    func refresh(force: Bool = false, scanCodex: Bool? = nil) {
        let latest = ClaudeLimitsBridge.read()
        let claudeChanged = latest != claude
        if claudeChanged { claude = latest }
        let stale = scannedAt.map { Date().timeIntervalSince($0) >= 20 } ?? true
        guard scanCodex ?? (force || stale), !scanning else {
            if claudeChanged { publish() }
            return
        }
        scanning = true
        Task.detached(priority: .utility) {
            let now = Date()
            let summary = UsageScanner.lock.withLock { UsageScanner.codex(now: now) }
            await MainActor.run {
                let tab = UsageTab.shared
                let codex = summary.map { ServiceLimits(codexLimits: $0.limits) }
                let codexChanged = codex != tab.codex
                if codexChanged { tab.codex = codex }
                tab.scanning = false
                tab.scannedAt = now
                if claudeChanged || codexChanged { tab.publish() }
            }
        }
    }

    private func publish() {
        NotchHub.shared.tabDidChange(id: id)
        NotchHub.shared.accessoryDidChange()
    }

    func makeBody() -> AnyView { refresh(); return AnyView(UsageView(model: self)) }
}

/// One limit window: percent used (0…100, counting up) and when it resets.
struct UsageLimit: Equatable, Sendable {
    let percent: Double
    let resets: Date?
    /// A window that has already reset counts as 0% until the service reports again.
    func current(at now: Date = Date()) -> Double { (resets.map { $0 > now } ?? true) ? percent : 0 }
}

struct ServiceLimits: Equatable, Sendable {
    var week: UsageLimit?
    var fiveHour: UsageLimit?

    init(week: UsageLimit?, fiveHour: UsageLimit?) { self.week = week; self.fiveHour = fiveHour }

    /// Codex logs a primary (5-hour) and a secondary (weekly) window with their lengths in minutes.
    init(codexLimits: [(percent: Double, minutes: Int, resets: Date?)]) {
        let weekly = codexLimits.filter { $0.minutes >= 24 * 60 }.max { $0.minutes < $1.minutes }
        let short = codexLimits.filter { $0.minutes > 0 && $0.minutes < 24 * 60 }.min { $0.minutes < $1.minutes }
        week = weekly.map { UsageLimit(percent: $0.percent, resets: $0.resets) }
        fiveHour = short.map { UsageLimit(percent: $0.percent, resets: $0.resets) }
    }
}

/// Claude Code hands its status-line command the same limits `/usage` shows (`rate_limits.five_hour` and
/// `.seven_day`, each with `used_percentage` and `resets_at`). Mouthy's script saves just those numbers to
/// `claude-limits.json` in Mouthy's folder and prints nothing, so the status line stays empty. It is
/// switched on by `"statusLine": {"type": "command", "command": "<scriptURL>"}` in ~/.claude/settings.json.
enum ClaudeLimitsBridge {
    static let folder = LocalStore.supportDirectory
    static let file = folder.appendingPathComponent("claude-limits.json")
    static let scriptURL = folder.appendingPathComponent("claude-statusline.sh")

    static let script = """
    #!/bin/sh
    # Mouthy: saves Claude Code's usage-limit percentages (and nothing else) for the notch. Prints nothing.
    # Uses only tools every Mac has (no Python or developer tools).
    dir="$HOME/Library/Application Support/Mouthy"
    /bin/mkdir -p "$dir" || exit 0
    tmp=$(/usr/bin/mktemp "$dir/.claude-limits.XXXXXX") || exit 0
    if /usr/bin/plutil -extract rate_limits json -o "$tmp" -- - 2>/dev/null; then
        /bin/mv -f "$tmp" "$dir/claude-limits.json"
    else
        /bin/rm -f "$tmp"
    fi
    exit 0
    """

    /// Writes the script when it is missing or out of date. Never edits Claude Code's settings.
    static func install() {
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) == script { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    static func read() -> ServiceLimits? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func limit(_ key: String) -> UsageLimit? {
            guard let window = object[key] as? [String: Any], let used = (window["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return UsageLimit(percent: used, resets: parseReset(window["resets_at"]))
        }
        let limits = ServiceLimits(week: limit("seven_day"), fiveHour: limit("five_hour"))
        return limits.week == nil && limits.fiveHour == nil ? nil : limits
    }

    /// `resets_at` as epoch seconds (or milliseconds) or an ISO 8601 string.
    static func parseReset(_ value: Any?) -> Date? {
        if let number = (value as? NSNumber)?.doubleValue { return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number) }
        return UsageScanner.parseDate(value)
    }
}

enum UsageScanner {
    struct Summary: Identifiable, Equatable, Sendable {
        var id: String { name }
        let name: String
        /// Tokens excluding cache reads, in the last five hours and since midnight.
        let fiveHours: Int
        let today: Int
        let week: Int
        /// Tokens per hour for the last 24 hours, oldest first.
        let hourly: [Int]
        /// Codex reports its own limits: (used percent, window minutes, resets at).
        let limits: [(percent: Double, minutes: Int, resets: Date?)]
        static func == (a: Summary, b: Summary) -> Bool {
            a.name == b.name && a.fiveHours == b.fiveHours && a.today == b.today && a.week == b.week && a.hourly == b.hourly
        }
    }

    struct Sample { let date: Date; let tokens: Int }

    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// Logs only grow, so each file is read once and afterwards only from where the last scan stopped.
    /// Guarded by `lock`; scans run one at a time off the main thread.
    static let lock = NSLock()
    final class FileCache {
        var identity: UInt64?
        var offset = 0
        var samples: [Sample] = []
        var limits: (Date, [(Double, Int, Date?)])?
    }
    nonisolated(unsafe) static var cache: [URL: FileCache] = [:]

    static func codex(now: Date, root: URL = home.appendingPathComponent(".codex/sessions")) -> Summary? {
        let files = Set(recentFiles(under: root, now: now))
        // An always-running app must not retain every session it has ever seen.
        cache = cache.filter { files.contains($0.key) }
        let weekStart = now.addingTimeInterval(-7 * 86400)
        var latestLimits: (Date, [(Double, Int, Date?)])?
        for file in files {
            var status = stat()
            guard stat(file.path, &status) == 0 else { continue }
            let entry = cache[file] ?? FileCache()
            // A truncated or atomically replaced log starts over; its old counts and limits do not survive.
            if entry.identity != status.st_ino || Int(status.st_size) < entry.offset {
                entry.offset = 0; entry.samples.removeAll(); entry.limits = nil
            }
            entry.identity = status.st_ino
            entry.samples.removeAll { $0.date < weekStart }
            cache[file] = entry
            entry.offset = forEachLine(file, from: entry.offset, containing: "token_count") { object in
                guard let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                      let date = parseDate(object["timestamp"]) else { return }
                if date >= weekStart, let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
                    let total = (last["total_tokens"] as? Int) ?? 0
                    let cached = (last["cached_input_tokens"] as? Int) ?? 0
                    entry.samples.append(Sample(date: date, tokens: max(0, total - cached)))
                }
                if let limits = payload["rate_limits"] as? [String: Any] {
                    let windows = ["primary", "secondary"].compactMap { key -> (Double, Int, Date?)? in
                        guard let window = limits[key] as? [String: Any], let used = window["used_percent"] as? Double else { return nil }
                        let resets = (window["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))
                        return (used, (window["window_minutes"] as? Int) ?? 0, resets)
                    }
                    if !windows.isEmpty, entry.limits.map({ $0.0 < date }) ?? true { entry.limits = (date, windows) }
                }
            }
            if let limits = entry.limits, latestLimits.map({ $0.0 < limits.0 }) ?? true { latestLimits = limits }
        }
        guard latestLimits != nil || cache.values.contains(where: { !$0.samples.isEmpty }) else { return nil }
        let limits = (latestLimits?.1 ?? []).filter { $0.2.map { $0 > now } ?? true }.map { (percent: $0.0, minutes: $0.1, resets: $0.2) }
        return summarize("Codex", cache.values.lazy.flatMap(\.samples), limits: limits, now: now)
    }

    static func summarize<S: Sequence>(_ name: String, _ samples: S, limits: [(percent: Double, minutes: Int, resets: Date?)], now: Date) -> Summary where S.Element == Sample {
        let midnight = Calendar.current.startOfDay(for: now)
        let fiveHoursStart = now.addingTimeInterval(-5 * 3600), weekStart = now.addingTimeInterval(-7 * 86400)
        var fiveHours = 0, today = 0, week = 0
        var hourly = Array(repeating: 0, count: 24)
        for sample in samples where sample.date <= now {
            if sample.date >= fiveHoursStart { fiveHours += sample.tokens }
            if sample.date >= midnight { today += sample.tokens }
            if sample.date >= weekStart { week += sample.tokens }
            let hoursAgo = Int(now.timeIntervalSince(sample.date) / 3600)
            if (0..<24).contains(hoursAgo) { hourly[23 - hoursAgo] += sample.tokens }
        }
        return Summary(name: name, fiveHours: fiveHours, today: today, week: week, hourly: hourly, limits: limits)
    }

    /// .jsonl files changed in the last eight days.
    static func recentFiles(under root: URL, now: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let cutoff = now.addingTimeInterval(-8 * 86400)
        return walker.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "jsonl" &&
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > cutoff
        }
    }

    /// Decodes only complete lines after `offset` that contain `marker`, so message text is skipped without
    /// being parsed. Returns the offset after the last complete line; a file that shrank is read again.
    /// Reads 32 KB at a time into one buffer and keeps a line in it up to `longest` bytes. Large, uneven reads
    /// would leave their freed pages in Mouthy's memory: macOS malloc keeps them dirty (157 MB after 80 rescans of
    /// growing logs, see LaunchMemoryTests). A longer line is only searched for `marker` as it streams past; one
    /// that has it is read again whole, so its count is never dropped.
    @discardableResult
    static func forEachLine(_ file: URL, from offset: Int = 0, containing marker: String, longest: Int = 64 << 10,
                            _ body: ([String: Any]) -> Void) -> Int {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return offset }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return offset }
        let size = Int(status.st_size)
        let start = offset <= size ? offset : 0
        guard size > start, !marker.isEmpty else { return start }
        let needle = Array(marker.utf8)
        let chunk = 32 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var line: [UInt8] = []
        line.reserveCapacity(min(longest, 16 << 10))
        // A line over `longest`: whether `marker` was seen, and its last bytes for a marker split across reads.
        var tooLong = false, longHasMarker = false
        var tail: [UInt8] = []
        func keep(_ from: UnsafePointer<UInt8>, _ count: Int) {
            guard count > 0 else { return }
            if !tooLong {
                guard line.count + count > longest else { line.append(contentsOf: UnsafeBufferPointer(start: from, count: count)); return }
                tooLong = true
                longHasMarker = memmem(line, line.count, needle, needle.count) != nil
                tail = Array(line.suffix(needle.count - 1))
                line.removeAll(keepingCapacity: true)
            }
            guard !longHasMarker else { return }
            let bytes = UnsafeBufferPointer(start: from, count: count)
            let seam = tail + bytes.prefix(needle.count - 1)
            longHasMarker = memmem(seam, seam.count, needle, needle.count) != nil || memmem(from, count, needle, needle.count) != nil
            tail = Array((tail + bytes.suffix(needle.count - 1)).suffix(needle.count - 1))
        }
        func decode(_ bytes: Data) { if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { body(object) } }
        func finishLine(from lineStart: Int, to lineEnd: Int) {
            if tooLong {
                if longHasMarker {
                    var whole = Data(count: lineEnd - lineStart)
                    let read = whole.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, lineEnd - lineStart, off_t(lineStart)) }
                    if read == lineEnd - lineStart { decode(whole) }
                }
            } else if !line.isEmpty, memmem(line, line.count, needle, needle.count) != nil {
                decode(Data(line))
            }
            line.removeAll(keepingCapacity: true); tooLong = false; longHasMarker = false; tail.removeAll()
        }
        var position = start, consumed = start
        while position < size {
            let read = pread(descriptor, buffer, min(chunk, size - position), off_t(position))
            guard read > 0 else { break }
            var from = 0
            while from < read {
                guard let newline = memchr(buffer + from, Int32(UInt8(ascii: "\n")), read - from) else {
                    keep(buffer + from, read - from); break
                }
                let end = buffer.distance(to: newline.assumingMemoryBound(to: UInt8.self))
                keep(buffer + from, end - from)
                finishLine(from: consumed, to: position + end)
                from = end + 1
                consumed = position + from
            }
            position += read
        }
        return consumed
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()
    static func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }
}

struct UsageView: View {
    @ObservedObject var model: UsageTab
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The band already names the tab; this line only says how to read the rings.
            Text("Weekly limits, counting up to 100%").font(.system(size: 12.5)).foregroundStyle(MouthyTheme.cream2)
            HStack(alignment: .top, spacing: 14) {
                LimitCard(name: "Claude Code", symbol: "sparkle", limits: model.claude,
                          missing: "Shows after your next Claude Code message.")
                // Codex shows only when its logs report a limit; on a Mac without Codex, Claude takes the row.
                if let codex = model.codex {
                    LimitCard(name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", limits: codex, missing: "")
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.smooth(duration: 0.3), value: model.codex == nil)
            Spacer(minLength: 0)
        }
    }
}

/// A weekly ring with the percentage in the middle, the 5-hour window and the reset time beneath.
/// Without data the ring is dashed and says "No data", never 0%.
struct LimitCard: View {
    let name: String
    let symbol: String
    let limits: ServiceLimits?
    let missing: String
    var body: some View {
        HStack(spacing: 16) {
            let week = limits?.week?.current()
            let hot = (week ?? 0) > 80
            ZStack {
                GlowRing(progress: (week ?? 0) / 100, lineWidth: 5, tint: hot ? MouthyTheme.ember : MouthyTheme.orange, dashed: week == nil)
                VStack(spacing: 0) {
                    if let week {
                        Text("\(Int(week.rounded()))%")
                            .font(MouthyType.notchUsage)
                            .foregroundStyle(hot ? AnyShapeStyle(MouthyTheme.ember) : AnyShapeStyle(MouthyTheme.cream))
                            .contentTransition(.numericText())
                        Text("week").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(MouthyTheme.cream2)
                    } else {
                        Text("No data").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(MouthyTheme.cream2)
                    }
                }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(name).foregroundStyle(MouthyTheme.cream)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(MouthyTheme.glow)
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                if limits == nil {
                    Text(missing).font(.system(size: 13)).foregroundStyle(MouthyTheme.cream2).fixedSize(horizontal: false, vertical: true)
                } else {
                    if let short = limits?.fiveHour {
                        let value = short.current()
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("5-hour")
                                Spacer()
                                Text("\(Int(value.rounded()))%").monospacedDigit().contentTransition(.numericText())
                            }
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(MouthyTheme.cream2)
                            GeometryReader { bar in
                                ZStack(alignment: .leading) {
                                    Capsule(style: .circular).fill(MouthyTheme.cream.opacity(0.08))
                                    Capsule(style: .circular).fill(value > 80 ? AnyShapeStyle(MouthyTheme.ember) : AnyShapeStyle(LinearGradient(colors: [MouthyTheme.orange, MouthyTheme.glowHi], startPoint: .leading, endPoint: .trailing)))
                                        .frame(width: max(4, bar.size.width * min(1, value / 100)))
                                }
                            }
                            .frame(height: 4)
                        }
                    } else {
                        Text("No 5-hour window reported.").font(.system(size: 12)).foregroundStyle(MouthyTheme.cream3)
                    }
                    if let resets = limits?.week?.resets, resets > Date() {
                        Text("Week resets " + resets.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.system(size: 12)).foregroundStyle(MouthyTheme.cream2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .smokedGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The tightest readout: each service's weekly limit used, as a percentage.
struct UsageChip: View {
    @ObservedObject var usage: UsageTab
    var body: some View {
        HStack(spacing: 9) {
            if let week = usage.claude?.week { entry("sparkle", week.current(), help: "Claude Code: weekly limit used") }
            if let week = usage.codex?.week { entry("chevron.left.forwardslash.chevron.right", week.current(), help: "Codex: weekly limit used") }
        }
        .contentShape(Rectangle())
        .onTapGesture { NotchHub.shared.show(tabID: usage.id) }
    }
    private func entry(_ symbol: String, _ percent: Double, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(MouthyTheme.glow)
            Text("\(Int(percent.rounded()))%").monospacedDigit()
                .foregroundStyle(percent > 80 ? MouthyTheme.ember : MouthyTheme.cream)
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(help + ", \(Int(percent.rounded())) percent")
    }
}
