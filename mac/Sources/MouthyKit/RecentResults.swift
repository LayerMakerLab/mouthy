import Foundation

/// The last few dictation results for the menu bar panel. Memory only: never written to disk or logged.
@MainActor
final class RecentResults: ObservableObject {
    static let shared = RecentResults()
    static let limit = 8
    @Published private(set) var items: [String] = []

    /// Adds a result at the front, dropping blanks, an exact repeat of the newest and anything past the limit.
    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, items.first != trimmed else { return }
        items.insert(trimmed, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    func clear() { items.removeAll() }
}
