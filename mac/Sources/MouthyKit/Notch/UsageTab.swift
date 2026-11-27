import CoreServices
import Foundation
import MouthyCore
import MouthyNotch
import SQLite3
import SwiftUI

/// The AI services the person pays for (`Preferences.aiServices`), each as its mark inside a ring that fills with the
/// share of its limit used: Claude Code's from its status line (`ClaudeLimitsBridge`), Codex's from its session logs,
/// OpenCode Go's from the costs in OpenCode's database against Go's published limits. Gemini, Cursor and Grok keep no
/// limits on this Mac, so their rings only show whether they are in use. A service is awake while its tool keeps
/// writing and falls asleep 10 minutes after the last write. File-system events only: no timer, no network.
@MainActor final class UsageTab: ObservableObject, NotchTab {
    static let shared = UsageTab()
    let id = "mouthy.usage"
    let title = "AI usage"
    let symbolName = "gauge.with.dots.needle.50percent"
    @Published private(set) var claude: ServiceLimits?
    @Published private(set) var codex: ServiceLimits?
    @Published private(set) var opencode: ServiceLimits?
    /// Which services are awake; changes only when one wakes or falls asleep (never per file write).
    @Published private(set) var awake: Set<AIService> = []
    /// The person's picks; nil until they choose. Set by Mouthy from its settings.
    @Published private(set) var picks: [AIService]?
    /// The page of rings shown when there are more than fit (`ringsPerPage`); a sideways swipe turns it.
    @Published private(set) var page = 0
    private(set) var scannedAt: Date?
    var scanning: Bool { scanningCodex || scanningOpenCode }
    /// Turns a service on or off from the tab's own picker (Mouthy writes it to its settings).
    var onPick: ((AIService, Bool) -> Void)?
    private var stream: FSEventStreamRef?
    /// Watching was asked for (the hub is attached), even when no picked service has a folder yet.
    private var watching = false
    private var watchedRoots: [String] = []
    private var scanningCodex = false, scanningOpenCode = false, pendingCodex = false, pendingOpenCode = false
    /// OpenCode's costs from the last read, so its rolling windows count down without reading the database again.
    private var openCodeCosts: [(date: Date, dollars: Double)] = []
    private var openCodeDecay: DispatchWorkItem?
    private var lastActivity: [AIService: Date] = [:]
    private var sleepers: [AIService: DispatchWorkItem] = [:]
    private var openCodeScannedAt: Date?

    static let ringsPerPage = 3
    private init() {}

    var shown: [AIService] { picks ?? [] }
    /// Rings with made-up limits, for renders: nothing is read or watched.
    func showForPreview(picks: [AIService], claude: ServiceLimits? = nil, codex: ServiceLimits? = nil, opencode: ServiceLimits? = nil, awake: Set<AIService> = []) {
        self.picks = picks; self.claude = claude; self.codex = codex; self.opencode = opencode; self.awake = awake; page = 0
        previewing = !picks.isEmpty
    }
    /// A render is showing made-up limits: `refresh` reads nothing (it would put this Mac's real numbers in the picture).
    private var previewing = false
    var isWatching: Bool { watching }
    func hasSleeper(for service: AIService) -> Bool { sleepers[service].map { !$0.isCancelled } ?? false }
    var pageCount: Int { max(1, (shown.count + Self.ringsPerPage - 1) / Self.ringsPerPage) }
    var hasData: Bool { shown.contains { limits(for: $0)?.binding != nil } }

    func limits(for service: AIService) -> ServiceLimits? {
        switch service {
        case .claude: claude
        case .chatgpt: codex
        case .opencode: opencode
        case .gemini, .cursor, .grok: nil
        }
    }

    func setPicks(_ new: [AIService]?) {
        guard new != picks else { return }
        picks = new
        page = min(page, pageCount - 1)
        if watching { stopWatching(); startWatching() }
        publish()
    }

    /// A sideways swipe inside the tab: turns the page of rings, or returns false at either end so the hub moves to
    /// the next tab.
    func page(_ step: Int) -> Bool {
        let next = page + step
        guard next >= 0, next < pageCount else { return false }
        withAnimation(MouthyMotion.resolve(MouthyMotion.tab, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { page = next }
        return true
    }

    // MARK: Watching

    nonisolated static let codexRoot = UsageScanner.home.appendingPathComponent(".codex/sessions").path
    nonisolated static let openCodeRoot = UsageScanner.home.appendingPathComponent(".local/share/opencode").path

    /// Folders whose writes mean the service is in use. Claude's limits file lives in Mouthy's own folder, which
    /// Mouthy also writes, so only that file counts there.
    nonisolated static func activityRoots(_ service: AIService) -> [String] {
        let home = UsageScanner.home
        switch service {
        case .claude: return [ClaudeLimitsBridge.folder.path, home.appendingPathComponent(".claude/projects").path]
        case .chatgpt: return [codexRoot]
        case .opencode: return [openCodeRoot]
        case .gemini: return [home.appendingPathComponent(".gemini").path]
        case .cursor: return [home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage").path]
        case .grok: return [home.appendingPathComponent(".grok").path]
        }
    }

    /// Which service a changed file belongs to (nil for Mouthy's own files). Mouthy's own reads must never count:
    /// reading OpenCode's database touches its `-shm` index, so only the database and its write-ahead log do.
    nonisolated static func service(for path: String) -> AIService? {
        if path == ClaudeLimitsBridge.folder.path || path.hasPrefix(ClaudeLimitsBridge.folder.path + "/") {
            return path.hasSuffix("/claude-limits.json") || path.contains("/.claude-limits.") ? .claude : nil
        }
        if path == openCodeRoot || path.hasPrefix(openCodeRoot + "/") {
            let name = (path as NSString).lastPathComponent
            return name == "opencode.db" || name == "opencode.db-wal" || path.hasPrefix(openCodeRoot + "/log/") ? .opencode : nil
        }
        return AIService.allCases.first { service in activityRoots(service).contains { path.hasPrefix($0 + "/") || path == $0 } }
    }

    /// Reloads when a picked service's tool writes: macOS file-system events, not a timer. Installs the tiny status-line
    /// script Claude Code calls (it prints nothing).
    func startWatching() {
        guard !watching else { return }
        watching = true
        if shown.contains(.claude) { ClaudeLimitsBridge.install() }
        let roots = shown.flatMap(Self.activityRoots).filter { FileManager.default.fileExists(atPath: $0) }
        watchedRoots = roots
        for service in shown { seedActivity(service) }
        // Services awake before a restart (picks changed) get their sleep back; ones no longer picked go quiet.
        for service in awake {
            if shown.contains(service) { noteActivity(service, at: lastActivity[service] ?? .distantPast) }
            else { awake.remove(service) }
        }
        let callback: FSEventStreamCallback = { _, _, _, eventPaths, _, _ in
            let changed = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            let services = Set(changed.compactMap(UsageTab.service(for:)))
            DispatchQueue.main.async { MainActor.assumeIsolated { UsageTab.shared.filesChanged(services) } }
        }
        if !roots.isEmpty, let created = FSEventStreamCreate(nil, callback, nil, roots as CFArray,
                                                             FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                                             FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)) {
            FSEventStreamSetDispatchQueue(created, .main)
            FSEventStreamStart(created)
            stream = created
        }
        refresh(force: true)
    }

    func stopWatching() {
        watching = false
        sleepers.values.forEach { $0.cancel() }; sleepers.removeAll()
        openCodeDecay?.cancel(); openCodeDecay = nil
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// At start, a service that wrote in the last 10 minutes is already awake (its newest known file's date).
    private func seedActivity(_ service: AIService) {
        let paths: [String]
        switch service {
        case .claude: paths = [ClaudeLimitsBridge.file.path]
        case .opencode: paths = [Self.openCodeRoot + "/opencode.db-wal", Self.openCodeRoot + "/opencode.db"]
        default: paths = Self.activityRoots(service)
        }
        let newest = paths.compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max()
        if let newest { noteActivity(service, at: newest) }
    }

    func filesChanged(_ services: Set<AIService>) {
        let now = Date()
        for service in services where shown.contains(service) { noteActivity(service, at: now) }
        refresh(scanCodex: services.contains(.chatgpt), scanOpenCode: services.contains(.opencode))
    }

    /// Records a write; publishes only when the service wakes, and schedules the moment it falls asleep.
    func noteActivity(_ service: AIService, at date: Date, now: Date = Date()) {
        lastActivity[service] = max(lastActivity[service] ?? date, date)
        let isAwake = AIActivity.isAwake(lastActivity: lastActivity[service], now: now)
        if isAwake != awake.contains(service) {
            if isAwake { awake.insert(service) } else { awake.remove(service) }
            publish()
        }
        sleepers[service]?.cancel()
        guard isAwake, let last = lastActivity[service] else { return }
        let sleeper = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.noteActivity(service, at: .distantPast) }
        }
        sleepers[service] = sleeper
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, last.addingTimeInterval(AIActivity.awakeFor).timeIntervalSince(now)), execute: sleeper)
    }

    // MARK: Reading

    /// Re-reads Claude's limits and, when asked (or the last scan is 20 s old), scans Codex's logs and OpenCode's
    /// costs. The hub and every view showing usage hear about it only when a number changed, so file activity that
    /// changes nothing costs nothing (each needless publish redrew the notch: 7-13% CPU spikes every few seconds while
    /// Claude Code was working).
    func refresh(force: Bool = false, scanCodex: Bool? = nil, scanOpenCode: Bool? = nil) {
        guard !previewing else { return }
        var changed = false
        if shown.contains(.claude) {
            let latest = ClaudeLimitsBridge.read()
            if latest != claude { claude = latest; changed = true }
        }
        let stale = scannedAt.map { Date().timeIntervalSince($0) >= 20 } ?? true
        let openStale = openCodeScannedAt.map { Date().timeIntervalSince($0) >= 20 } ?? true
        // A scan asked for while the same one runs is remembered and runs right after, so the last write is read.
        if shown.contains(.chatgpt), scanCodex ?? (force || stale) {
            if scanningCodex { pendingCodex = true } else { scanCodexLogs() }
        }
        if shown.contains(.opencode), scanOpenCode ?? (force || openStale) {
            if scanningOpenCode { pendingOpenCode = true } else { scanOpenCodeCosts() }
        }
        if changed { publish() }
    }

    private func scanCodexLogs() {
        scanningCodex = true
        Task.detached(priority: .utility) {
            let now = Date()
            let summary = UsageScanner.lock.withLock { UsageScanner.codex(now: now) }
            await MainActor.run {
                let tab = UsageTab.shared
                let codex = summary.map { ServiceLimits(codexLimits: $0.limits) }
                tab.scannedAt = now
                tab.scanningCodex = false
                if codex != tab.codex { tab.codex = codex; tab.publish() }
                if tab.pendingCodex { tab.pendingCodex = false; tab.scanCodexLogs() }
            }
        }
    }

    private func scanOpenCodeCosts() {
        scanningOpenCode = true
        Task.detached(priority: .utility) {
            let now = Date()
            let costs = OpenCodeCosts.read(since: now.addingTimeInterval(-30 * 86400))
            await MainActor.run {
                let tab = UsageTab.shared
                tab.openCodeScannedAt = now
                tab.scanningOpenCode = false
                tab.openCodeCosts = costs ?? []
                tab.updateOpenCode(present: costs != nil, now: now)
                if tab.pendingOpenCode { tab.pendingOpenCode = false; tab.scanOpenCodeCosts() }
            }
        }
    }

    /// Recomputes OpenCode's windows from the costs already read and wakes again when the oldest cost in a window
    /// leaves it, so the ring counts down while OpenCode is idle (one timer at that moment, no polling).
    private func updateOpenCode(present: Bool = true, now: Date = Date()) {
        let open = present ? ServiceLimits(openCodeCosts: openCodeCosts, now: now) : nil
        // Publish only what the ring and chip can show (whole percents): a tiny cost leaving a window redraws nothing.
        func shown(_ l: ServiceLimits?) -> [Int?]? { l.map { [$0.fiveHour, $0.week, $0.month].map { $0.map { Int($0.percent.rounded()) } } } }
        if shown(open) != shown(opencode) { opencode = open; publish() } else { opencode = open }
        openCodeDecay?.cancel(); openCodeDecay = nil
        let next = [5 * 3600.0, 7 * 86400.0, 30 * 86400.0]
            .compactMap { OpenCodeGo.nextDrop(costs: openCodeCosts, window: $0, now: now) }.min()
        guard present, watching, let next else { return }
        let decay = DispatchWorkItem { MainActor.assumeIsolated { UsageTab.shared.updateOpenCode() } }
        openCodeDecay = decay
        // A minute late on purpose: costs made seconds apart leave together, in one wake instead of a burst.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSince(now) + 60), execute: decay)
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
    /// The number comes from another tool's file, so it is never taken as a sane percent: anything that is not a
    /// number counts as 0 and the rest is held to 0...999 (a huge one crashed every whole-number conversion below).
    init(percent: Double, resets: Date?) {
        self.percent = percent.isFinite ? min(max(percent, 0), 999) : 0
        self.resets = resets
    }
    /// A window that has already reset counts as 0% until the service reports again.
    func current(at now: Date = Date()) -> Double { (resets.map { $0 > now } ?? true) ? percent : 0 }
}

struct ServiceLimits: Equatable, Sendable {
    var week: UsageLimit?
    var fiveHour: UsageLimit?
    var month: UsageLimit?

    init(week: UsageLimit?, fiveHour: UsageLimit?, month: UsageLimit? = nil) { self.week = week; self.fiveHour = fiveHour; self.month = month }

    /// The outer ring's limit: the week or the month, whichever is closer to its cap (OpenCode Go has both, and with
    /// steady use the month is the fuller one), so the number in the middle of the rings is always one a ring shows.
    var long: (percent: Double, name: String)? {
        [(week, "week"), (month, "month")].compactMap { limit, name in limit.map { ($0.current(), name) } }
            .max { $0.0 < $1.0 }.map { (percent: $0.0, name: $0.1) }
    }

    /// The window closest to its limit: the one that maxes the service out first, and so the ring's fill.
    var binding: (percent: Double, window: String, resets: Date?)? {
        [(fiveHour, "5-hour"), (week, "week"), (month, "month")]
            .compactMap { limit, name in limit.map { ($0.current(), name, $0.resets) } }
            .max { $0.0 < $1.0 }
    }

    /// OpenCode Go: this Mac's metered costs against the plan's rolling 5-hour, weekly and monthly dollar limits.
    init(openCodeCosts costs: [(date: Date, dollars: Double)], now: Date = Date()) {
        let p = OpenCodeGo.percents(costs: costs, now: now)
        // Rolling windows have no reset moment (each cost leaves on its own), so no reset date that would zero them.
        fiveHour = UsageLimit(percent: p.fiveHour, resets: nil)
        week = UsageLimit(percent: p.week, resets: nil)
        month = UsageLimit(percent: p.month, resets: nil)
    }

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
    /// Always Mouthy's folder, even in a host app that moves the tabs' storage: Claude Code runs one status-line
    /// command, so Mouthy and host apps share this script and file. `install()` writes only when the text differs.
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

/// OpenCode's own record of what each answer cost (its SQLite database, opened read-only; message rows only, never
/// its credential or account tables).
enum OpenCodeCosts {
    static var database: String { UsageTab.openCodeRoot + "/opencode.db" }

    static func read(since: Date, path: String = database) -> [(date: Date, dollars: Double)]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        // Only answers billed to the Go subscription: OpenCode also records costs for other providers (a person's own
        // API keys, local models), which don't count against Go's limits.
        let sql = "SELECT time_created, json_extract(data, '$.cost') FROM message WHERE time_created >= ? AND json_extract(data, '$.role') = 'assistant' AND json_extract(data, '$.providerID') = 'opencode-go'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))
        var rows: [(date: Date, dollars: Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let ms = sqlite3_column_int64(statement, 0)
            let cost = sqlite3_column_type(statement, 1) == SQLITE_NULL ? 0 : sqlite3_column_double(statement, 1)
            rows.append((Date(timeIntervalSince1970: Double(ms) / 1000), cost))
        }
        return rows
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
        if model.shown.isEmpty {
            UsagePicker(model: model)
        } else {
            VStack(spacing: 6) {
                GeometryReader { geo in
                    let pages = stride(from: 0, to: model.shown.count, by: UsageTab.ringsPerPage).map {
                        Array(model.shown[$0..<min($0 + UsageTab.ringsPerPage, model.shown.count)])
                    }
                    HStack(spacing: 0) {
                        ForEach(pages.indices, id: \.self) { index in
                            // Even columns across the tab, centred in its height: one, two or three rings sit the same.
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(pages[index]) { service in
                                    ServiceRing(service: service, limits: model.limits(for: service), awake: model.awake.contains(service),
                                                compact: model.pageCount > 1)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                        }
                    }
                    .offset(x: -CGFloat(model.page) * geo.size.width)
                    .frame(width: geo.size.width, alignment: .leading)
                }
                .clipped()
                if model.pageCount > 1 { PageDots(count: model.pageCount, current: model.page) }
            }
        }
    }
}

/// One service. Its limits are rings that fill with the share used (a quarter at 25%, full when maxed out): the long
/// one (week or month) outside and the 5-hour one inside when it has both, one ring otherwise. The number in the
/// middle is the limit it is closest to; its mark and name are beneath, then each limit's number on one line (or,
/// with one limit, which it is and when it resets). A service that shows no limits has its mark in a dashed ring.
/// Awake (its tool wrote in the last 10 minutes) the rings are lit and breathe softly; asleep they dim, hold still
/// and a small "zzz" follows the name.
struct ServiceRing: View {
    let service: AIService
    let limits: ServiceLimits?
    let awake: Bool
    /// More services than fit one page: the page dots take a line, so the rings are a size smaller.
    var compact = false
    var body: some View {
        let binding = limits?.binding
        let percent = binding?.percent
        let maxed = (percent ?? 0) >= 100, hot = (percent ?? 0) >= 80
        let long = limits?.long?.percent, short = limits?.fiveHour?.current()
        let side: CGFloat = compact ? 48 : 58
        VStack(spacing: 0) {
            ZStack {
                AwakeGlow(awake: awake).frame(width: side + 8, height: side + 8)
                if let long, let short {
                    GlowRing(progress: ringFill(percent: long), lineWidth: 5, tint: long >= 80 ? MouthyTheme.ember : MouthyTheme.orange)
                    GlowRing(progress: ringFill(percent: short), lineWidth: 5, tint: short >= 80 ? MouthyTheme.ember : MouthyTheme.glowHi)
                        .padding(compact ? 7 : 8)
                } else {
                    GlowRing(progress: ringFill(percent: percent ?? 0), lineWidth: 5.5,
                             tint: hot ? MouthyTheme.ember : MouthyTheme.orange, dashed: percent == nil)
                }
                if let percent {
                    Text(maxed ? "Max" : "\(Int(percent.rounded()))%")
                        .font(.system(size: (long != nil && short != nil ? 12 : (maxed ? 14 : 16)) - (compact ? 1.5 : 0), weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(hot ? MouthyTheme.ember : (awake ? MouthyTheme.cream : MouthyTheme.cream2))
                        .contentTransition(.numericText())
                } else {
                    Image(systemName: service.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(awake ? MouthyTheme.glow : MouthyTheme.cream3)
                }
            }
            .frame(width: side, height: side)
            .opacity(awake ? 1 : 0.6)
            .animation(.smooth(duration: 0.6), value: awake)
            HStack(spacing: 5) {
                if percent != nil {
                    Image(systemName: service.symbol).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(awake ? MouthyTheme.glow : MouthyTheme.cream2)
                }
                Text(service.name).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
                    .lineLimit(1)
                if !awake {
                    Image(systemName: "zzz").font(.system(size: 8.5, weight: .bold)).foregroundStyle(MouthyTheme.cream3)
                        .transition(.opacity)
                }
            }
            .padding(.top, compact ? 6 : 9)
            Text(caption(binding)).font(.system(size: 11, design: .rounded)).monospacedDigit()
                .foregroundStyle(hot ? MouthyTheme.ember : MouthyTheme.cream2)
                .lineLimit(1).minimumScaleFactor(0.85)
                .padding(.top, 3)
        }
        .padding(.horizontal, 6)
        .help(spoken(binding))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(service.name + ", " + spoken(binding) + (awake ? ", in use" : ", asleep"))
    }

    /// Under the name: each limit's number when there are two rings ("5h 12% · week 23%"); with one, which limit the
    /// ring shows and when it resets (its number is in the ring).
    private func caption(_ binding: (percent: Double, window: String, resets: Date?)?) -> String {
        guard let binding else {
            if !service.showsLimits { return awake ? "In use" : "Asleep" }
            return awake ? "In use, no limits yet" : "No data yet"
        }
        if let short = limits?.fiveHour, let long = limits?.long {
            return "5h \(Int(short.current().rounded()))% · \(long.name) \(Int(long.percent.rounded()))%"
        }
        var text = "\(binding.window) limit"
        if let resets = binding.resets, resets > Date() {
            text += " · resets " + resets.formatted(.dateTime.weekday(.abbreviated).hour())
        }
        return text
    }

    /// The whole reading in words, for VoiceOver and the tooltip: every limit shown, and when the closest one resets.
    private func spoken(_ binding: (percent: Double, window: String, resets: Date?)?) -> String {
        guard let binding else {
            if !service.showsLimits { return awake ? "In use" : "Asleep" }
            return awake ? "In use, no limits yet" : "No data yet"
        }
        if let short = limits?.fiveHour, let long = limits?.long {
            var text = "\(Int(short.current().rounded()))% of 5-hour, \(Int(long.percent.rounded()))% of \(long.name)"
            if binding.percent >= 100 { text += ", maxed out" }
            if let resets = binding.resets, resets > Date() {
                text += " · \(binding.window) resets " + resets.formatted(.dateTime.weekday(.abbreviated).hour())
            }
            return text
        }
        let percent = Int(binding.percent.rounded())
        if percent >= 100 { return "Maxed out · \(binding.window)" }
        var text = "\(percent)% of \(binding.window)"
        if let resets = binding.resets, resets > Date() {
            text += " · resets " + resets.formatted(.dateTime.weekday(.abbreviated).hour())
        }
        return text
    }
}

/// Where you are among the pages of rings.
struct PageDots: View {
    let count: Int, current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(index == current ? MouthyTheme.glow : MouthyTheme.cream.opacity(0.18))
                    .frame(width: index == current ? 14 : 5, height: 5)
            }
        }
        .animation(.smooth(duration: 0.3), value: current)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

/// Nothing picked yet: the services as chips to turn on, right in the tab (also in Settings and setup).
struct UsagePicker: View {
    @ObservedObject var model: UsageTab
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which AI do you pay for?").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(MouthyTheme.cream)
            Text("Pick yours and their limits show here. Read on this Mac only, never online.")
                .font(.system(size: 12)).foregroundStyle(MouthyTheme.cream2)
            AIServiceChips(selected: Set(model.shown)) { service, on in model.onPick?(service, on) }
            Spacer(minLength: 0)
        }
    }
}

/// Toggle chips for the AI services (the usage tab, Settings and setup).
struct AIServiceChips: View {
    let selected: Set<AIService>
    let toggle: (AIService, Bool) -> Void
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(AIService.allCases) { service in
                let on = selected.contains(service)
                Button { toggle(service, !on) } label: {
                    Label(service.name, systemImage: service.symbol)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .foregroundStyle(on ? MouthyTheme.onOrange : MouthyTheme.cream)
                        .background(Capsule().fill(on ? AnyShapeStyle(MouthyTheme.orange) : AnyShapeStyle(MouthyTheme.cream.opacity(0.08))))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The soft light behind an awake ring: one slow Core Animation breath in the render server, nothing per frame in
/// Mouthy. Asleep, the light is off and nothing animates. Reduce Motion keeps a steady light.
final class AwakeGlowView: RenderServerView {
    private let glow = CAGradientLayer()
    private var state: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        glow.type = .radial
        glow.colors = [NSColor(MouthyTheme.glow).withAlphaComponent(0.42).cgColor, NSColor(MouthyTheme.glow).withAlphaComponent(0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
        glow.opacity = 0
        layer?.addSublayer(glow)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
    var animationKeys: [String] { glow.animationKeys() ?? [] }

    func apply(awake: Bool) {
        guard awake != state else { return }
        state = awake
        glow.removeAllAnimations()
        Self.withoutActions { glow.opacity = awake ? 0.75 : 0 }
        guard awake, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.45; breathe.toValue = 1
        breathe.duration = 2.6; breathe.autoreverses = true; breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(Self.decorative(breathe), forKey: "breathe")
    }

    override func layout() {
        super.layout()
        Self.withoutActions { glow.frame = bounds }
    }
}

struct AwakeGlow: NSViewRepresentable {
    let awake: Bool
    func makeNSView(context: Context) -> AwakeGlowView { AwakeGlowView(frame: .zero) }
    func updateNSView(_ view: AwakeGlowView, context: Context) { view.apply(awake: awake) }
}

/// The tightest readout beside the recording pill: each picked service's fullest limit, as a percentage.
struct UsageChip: View {
    @ObservedObject var usage: UsageTab
    var body: some View {
        HStack(spacing: 9) {
            ForEach(usage.shown) { service in
                if let binding = usage.limits(for: service)?.binding {
                    entry(service.symbol, binding.percent, help: "\(service.name): \(binding.window) limit used")
                }
            }
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
