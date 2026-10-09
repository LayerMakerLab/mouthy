import EventKit
import Foundation
import Testing
@testable import MouthyKit

/// The tab entry points the notch's spoken commands call. Nothing here touches real Reminders or
/// Mouthy's real notch folder.

@MainActor @Test func spokenTimerRunsAndStopsWithNothingLeft() async throws {
    let timers = TimersTab.shared
    timers.stop()
    timers.start(seconds: 1)
    #expect(timers.running?.kind == .countdown && timers.running?.length == 1)
    #expect(timers.selected == .countdown)
    timers.stop()
    #expect(timers.running == nil)
    // The alarm was cancelled: once its time has passed, nothing finishes.
    try await Task.sleep(for: .seconds(1.5))
    #expect(timers.running == nil && timers.finished == nil)
}

@MainActor @Test func spokenNoteAppendsALineToTheSavedNote() throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-notes-\(UUID().uuidString)")
    let originalFolder = MouthyTabs.storageFolder
    MouthyTabs.storageFolder = scratch.appendingPathComponent("Notch")
    let notes = NotesTab.shared
    let (originalNote, originalTodos) = (notes.note, notes.todos)
    defer {
        notes.note = originalNote; notes.todos = originalTodos
        MouthyTabs.storageFolder = originalFolder
        try? FileManager.default.removeItem(at: scratch)
    }
    notes.todos = []
    notes.note = ""
    notes.addNote("call mom")
    notes.addNote("  buy milk \n")
    notes.addNote("   ")
    #expect(notes.note == "call mom\nbuy milk")
    let saved = try JSONDecoder().decode(NotesTab.Document.self,
                                         from: Data(contentsOf: MouthyTabs.storageFolder.appendingPathComponent("notes.json")))
    #expect(saved.note == "call mom\nbuy milk" && saved.todos.isEmpty)
}

@MainActor final class SpyReminders: ReminderStore {
    var status: EKAuthorizationStatus = .notDetermined
    var grants = true
    var failsToSave = false
    private(set) var requests = 0
    private(set) var saved: [(title: String, due: Date)] = []

    func authorizationStatus() -> EKAuthorizationStatus { status }
    func requestAccess() async -> Bool {
        requests += 1
        status = grants ? .fullAccess : .denied
        return grants
    }
    func save(title: String, due: Date) throws {
        if failsToSave { throw CocoaError(.fileWriteUnknown) }
        saved.append((title, due))
    }
}

@MainActor @Test func spokenReminderAsksOnceThenReachesTheStore() async throws {
    let calendar = CalendarTab.shared
    let original = calendar.reminderStore
    defer { calendar.reminderStore = original }
    let spy = SpyReminders()
    calendar.reminderStore = spy
    let due = Date(timeIntervalSinceNow: 3600)

    try await calendar.addReminder("call mom", due: due)
    try await calendar.addReminder("buy milk", due: due)
    #expect(spy.requests == 1, "access is asked only on first use")
    #expect(spy.saved.map(\.title) == ["call mom", "buy milk"] && spy.saved.allSatisfy { $0.due == due })

    spy.failsToSave = true
    await #expect(throws: (any Error).self) { try await calendar.addReminder("water the plants", due: due) }
    #expect(spy.saved.count == 2)
}

@MainActor @Test func spokenReminderReportsDeniedAccess() async throws {
    let calendar = CalendarTab.shared
    let original = calendar.reminderStore
    defer { calendar.reminderStore = original }
    let spy = SpyReminders()
    spy.grants = false
    calendar.reminderStore = spy

    do {
        try await calendar.addReminder("call mom", due: Date(timeIntervalSinceNow: 3600))
        Issue.record("a denied reminder must fail, not vanish")
    } catch {
        #expect(error.localizedDescription.contains("Privacy & Security"))
    }
    #expect(spy.requests == 1 && spy.saved.isEmpty)
    // Already denied: no second prompt.
    await #expect(throws: (any Error).self) { try await calendar.addReminder("call mom", due: Date()) }
    #expect(spy.requests == 1)
}
