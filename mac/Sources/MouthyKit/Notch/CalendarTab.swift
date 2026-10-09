import AppKit
import EventKit
import MouthyNotch
import SwiftUI

/// Today and the next two days, plus open reminders you can check off. Access is asked only when the
/// person taps Allow; updates arrive through EventKit's change notification.
@MainActor final class CalendarTab: ObservableObject, NotchTab {
    static let shared = CalendarTab()
    struct Event: Identifiable, Equatable {
        let id: String; let title: String; let start: Date; let end: Date; let allDay: Bool; let color: CGColor?
        var joinURL: URL? = nil
    }

    /// The first video-call link in an event's URL, location or notes.
    nonisolated static func joinLink(in texts: [String?]) -> URL? {
        let pattern = #"https://[^\s<>"]*(zoom\.us/(j|my|w)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet|facetime\.apple\.com/join|webex\.com/(meet|join)|whereby\.com/)[^\s<>"]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range), let found = Range(match.range, in: text) {
                return URL(string: String(text[found]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;")))
            }
        }
        return nil
    }
    struct Reminder: Identifiable, Equatable { let id: String; let title: String; let due: Date? }

    let id = "mouthy.calendar"
    let title = "Calendar"
    let symbolName = "calendar"
    private let store = EKEventStore()
    /// Where spoken reminders go: EventKit in the app, a spy in tests.
    lazy var reminderStore: any ReminderStore = EventKitReminders(store: store)
    @Published private(set) var events: [Event] = []
    @Published private(set) var reminders: [Reminder] = []
    @Published private(set) var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
    private var observer: NSObjectProtocol?
    private var soonTask: Task<Void, Never>?

    private init() {}

    func startWatching() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in CalendarTab.shared.reload() }
        }
        reload()
    }

    func stopWatching() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        soonTask?.cancel(); soonTask = nil
    }

    var badge: NotchBadge? {
        guard let next = events.first(where: { !$0.allDay && $0.start > Date() }), next.start.timeIntervalSinceNow < 15 * 60 else { return nil }
        return NotchBadge(count: 0, tone: .attention)
    }

    func requestCalendar() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            calendarAccess = EKEventStore.authorizationStatus(for: .event); reload()
        }
    }
    func requestReminders() {
        Task {
            _ = try? await store.requestFullAccessToReminders()
            reminderAccess = EKEventStore.authorizationStatus(for: .reminder); reload()
        }
    }
    /// One tap for both: Calendar's dialog first, then Reminders', never two at once.
    func requestBoth() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            calendarAccess = EKEventStore.authorizationStatus(for: .event)
            _ = try? await store.requestFullAccessToReminders()
            reminderAccess = EKEventStore.authorizationStatus(for: .reminder); reload()
        }
    }

    /// Before either has been asked, the tab shows one combined welcome instead of two half-empty columns.
    nonisolated static func asksTogether(calendar: EKAuthorizationStatus, reminders: EKAuthorizationStatus) -> Bool {
        calendar == .notDetermined && reminders == .notDetermined
    }

    /// The Privacy & Security pane for one kind of access.
    nonisolated static func privacyURL(reminders: Bool) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(reminders ? "Privacy_Reminders" : "Privacy_Calendars")")!
    }

    func reload() {
        if calendarAccess == .fullAccess {
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 3, to: start)!
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            events = store.events(matching: predicate).filter { $0.endDate > Date() }
                .sorted { $0.startDate < $1.startDate }.prefix(20)
                .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Untitled", start: $0.startDate,
                             end: $0.endDate, allDay: $0.isAllDay, color: $0.calendar?.cgColor,
                             joinURL: Self.joinLink(in: [$0.url?.absoluteString, $0.location, $0.notes])) }
            scheduleSoon()
        }
        if reminderAccess == .fullAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { found in
                let items = (found ?? []).map { Reminder(id: $0.calendarItemIdentifier, title: $0.title ?? "", due: $0.dueDateComponents?.date) }
                    .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                Task { @MainActor in CalendarTab.shared.reminders = Array(items.prefix(30)); CalendarTab.shared.changed() }
            }
        }
        changed()
    }

    func complete(_ reminder: Reminder) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        do { try store.save(item, commit: true); reminders.removeAll { $0.id == reminder.id } }
        catch { NotchHub.shared.presentResult("Couldn't update the reminder", ok: false) }
        changed()
    }

    /// A spoken reminder, saved to the default Reminders list. Asks for access only the first time it is
    /// needed; any failure is thrown with a plain reason, so the words are never silently dropped.
    func addReminder(_ text: String, due: Date) async throws {
        var status = reminderStore.authorizationStatus()
        if status == .notDetermined {
            _ = await reminderStore.requestAccess()
            status = reminderStore.authorizationStatus()
            reminderAccess = status
        }
        guard status == .fullAccess else { throw MouthyFailure("Reminders access is off. Turn it on in Privacy & Security.") }
        do { try reminderStore.save(title: text, due: due) } catch { throw MouthyFailure("Couldn't save the reminder") }
        changed()
    }

    /// The next timed event starting within ten minutes or begun under five minutes ago.
    /// The next timed event still to end today, for the open notch's header.
    var nextEvent: Event? {
        let now = Date()
        return events.first { !$0.allDay && $0.end > now }
    }

    var soonEvent: Event? {
        let now = Date()
        return events.first { !$0.allDay && $0.start.timeIntervalSince(now) <= 600 && now.timeIntervalSince($0.start) <= 300 }
    }

    /// Wakes exactly when the next event enters the heads-up window, starts, and leaves it; no polling.
    private func scheduleSoon() {
        soonTask?.cancel()
        let now = Date()
        let edges = events.filter { !$0.allDay }.flatMap { [$0.start.addingTimeInterval(-600), $0.start, $0.start.addingTimeInterval(300)] }.filter { $0 > now }
        guard let next = edges.min() else { return }
        soonTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.5)) } catch { return }
            self?.changed(); self?.scheduleSoon()
        }
    }

    /// First only in the minutes before the event starts; once it has begun, music or a timer take the band back.
    var compactPriority: Int { Self.priority(startsIn: soonEvent.map { $0.start.timeIntervalSinceNow }) }
    static func priority(startsIn seconds: TimeInterval?) -> Int { (seconds ?? 0) > 0 ? 30 : 15 }
    var compactCaption: String? { soonEvent?.title }
    func compactBody() -> AnyView? {
        guard let event = soonEvent else { return nil }
        return AnyView(TimelineView(.periodic(from: .now, by: 30)) { _ in
            let minutes = Int(ceil(event.start.timeIntervalSinceNow / 60))
            Text(minutes > 0 ? "\(minutes)m" : "now").foregroundStyle(MouthyTheme.glow)
        })
    }

    private func changed() { NotchHub.shared.tabDidChange(id: id) }

    func makeBody() -> AnyView { AnyView(CalendarView(model: self)) }

    /// A calendar's own colour, kept warm: cool calendar colours (blue, teal, purple) become mic glow.
    static func warm(_ color: CGColor?) -> Color {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return MouthyTheme.orange }
        let glow = ambientHSB(hue: rgb.hueComponent, saturation: rgb.saturationComponent, brightness: rgb.brightnessComponent)
        return Color(hue: glow.hue, saturation: min(glow.saturation, 0.85), brightness: glow.brightness)
    }
}

/// The Reminders calls a spoken reminder needs.
@MainActor protocol ReminderStore: AnyObject {
    func authorizationStatus() -> EKAuthorizationStatus
    func requestAccess() async -> Bool
    func save(title: String, due: Date) throws
}

/// Spoken reminders in the default list, due at the spoken time with an alert then.
@MainActor final class EventKitReminders: ReminderStore {
    private let store: EKEventStore
    init(store: EKEventStore) { self.store = store }
    func authorizationStatus() -> EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    func requestAccess() async -> Bool { (try? await store.requestFullAccessToReminders()) ?? false }
    func save(title: String, due: Date) throws {
        guard let list = store.defaultCalendarForNewReminders() else { throw MouthyFailure("No Reminders list to add to") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        reminder.dueDateComponents = Calendar.current.dateComponents([.timeZone, .year, .month, .day, .hour, .minute], from: due)
        reminder.addAlarm(EKAlarm(absoluteDate: due))
        try store.save(reminder, commit: true)
    }
}

struct CalendarView: View {
    @ObservedObject var model: CalendarTab
    var body: some View {
        if CalendarTab.asksTogether(calendar: model.calendarAccess, reminders: model.reminderAccess) {
            NotchEmptyState(pose: .wave, title: "Your next few days",
                            message: "Calendar and Reminders stay on this Mac.",
                            actionTitle: "Allow Calendar & Reminders") { model.requestBoth() }
        } else {
            columns
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                TabHeader(title: Date().formatted(.dateTime.weekday(.wide).month().day()))
                if model.calendarAccess != .fullAccess {
                    AccessPrompt(text: "Show your next few days here.", allowTitle: "Allow Calendar",
                                 denied: [.denied, .restricted].contains(model.calendarAccess),
                                 settingsURL: CalendarTab.privacyURL(reminders: false)) { model.requestCalendar() }
                } else if model.events.isEmpty {
                    NotchEmptyState(pose: .sleep, title: "Nothing scheduled", message: "The next few days are clear.")
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.events) { event in EventRow(event: event) }
                        }
                    }
                    .notchScrollFade()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(MouthyTheme.cream.opacity(0.08)).frame(width: 1).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 8) {
                TabHeader(title: "Reminders", detail: model.reminders.isEmpty ? nil : "\(model.reminders.count)")
                if model.reminderAccess != .fullAccess {
                    AccessPrompt(text: "Check off reminders here.", allowTitle: "Allow Reminders",
                                 denied: [.denied, .restricted].contains(model.reminderAccess),
                                 settingsURL: CalendarTab.privacyURL(reminders: true)) { model.requestReminders() }
                } else if model.reminders.isEmpty {
                    NotchEmptyState(pose: .cheer, title: "All done")
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.reminders) { reminder in ReminderRow(reminder: reminder) { model.complete(reminder) } }
                        }
                    }
                    .notchScrollFade()
                }
            }
            .frame(width: 214, alignment: .leading)
        }
    }
}

struct ReminderRow: View {
    let reminder: CalendarTab.Reminder
    let complete: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: complete) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: hovering ? "checkmark.circle" : "circle")
                    .foregroundStyle(hovering ? MouthyTheme.glow : MouthyTheme.cream2)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(reminder.title).font(.system(size: 14)).foregroundStyle(MouthyTheme.cream).lineLimit(1)
                    if let due = reminder.due {
                        Text(due, style: .relative).font(.system(size: 12))
                            .foregroundStyle(due < Date() ? MouthyTheme.ember : MouthyTheme.cream2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .hoverRow()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Mark as done")
    }
}

struct EventRow: View {
    let event: CalendarTab.Event
    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Capsule(style: .circular).fill(CalendarTab.warm(event.color)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 14, weight: .medium)).foregroundStyle(MouthyTheme.cream).lineLimit(1)
                Text(when).font(.system(size: 12.5)).foregroundStyle(MouthyTheme.cream2)
            }
            Spacer(minLength: 4)
            if let url = event.joinURL, event.end > Date(), event.start.timeIntervalSinceNow < 3600 {
                PillButton(title: "Join", symbol: "video.fill", prominent: event.start.timeIntervalSinceNow < 600) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var when: String {
        let day = Calendar.current.isDateInToday(event.start) ? "" : event.start.formatted(.dateTime.weekday(.abbreviated)) + " "
        if event.allDay { return day + "All day" }
        if event.start <= Date() { return "Now · until " + event.end.formatted(date: .omitted, time: .shortened) }
        return day + event.start.formatted(date: .omitted, time: .shortened) + "–" + event.end.formatted(date: .omitted, time: .shortened)
    }
}

/// Asks for access only when tapped: a warm glass "Allow …" button, or once denied, the way to the
/// Privacy & Security pane where it can be turned back on.
struct AccessPrompt: View {
    let text: String
    var allowTitle = "Allow"
    let denied: Bool
    var settingsURL: URL?
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(denied ? "Access is off. Turn it on in Privacy & Security." : text)
                .font(.system(size: 13.5)).foregroundStyle(MouthyTheme.cream2)
                .fixedSize(horizontal: false, vertical: true)
            if !denied {
                PillButton(title: allowTitle, symbol: "lock.open.fill", prominent: true, action: action)
            } else if let settingsURL {
                PillButton(title: "Open Privacy settings", symbol: "gearshape.fill") { NSWorkspace.shared.open(settingsURL) }
            }
        }
    }
}
