import Foundation

/// The file Mouthy keeps in a sync folder (iCloud Drive, Dropbox, a network share…). Merging only
/// adds, except what the person removed on this machine since the last sync: words and replacements are
/// unioned, modes are matched by id. No server, no account.
public struct SyncDocument: Codable, Equatable {
    public var version = 1
    public var vocabulary: [String] = []
    public var replacements: [Replacement] = []
    /// Mac modes (app identities differ on Windows and Linux, so those apps ignore this field).
    public var macModes: [DictationMode] = []
    public init() {}

    public static let fileName = "Mouthy Sync.json"

    static func words(_ vocabulary: String) -> [String] {
        VocabularyLearner.terms(vocabulary)
    }

    /// Words, replacement phrases and modes the person removed on this machine since the last sync. They are
    /// not merged back in, so the removal reaches the shared file too (as `Removed` in the Windows/Linux store).
    public struct Removed: Equatable {
        public var words: Set<String> = [], phrases: Set<String> = [], modes: Set<UUID> = []
        public init() {}
        /// What `before` had that `after` no longer has.
        public init(from before: Preferences, to after: Preferences) {
            let (old, new) = (SyncDocument(before), SyncDocument(after))
            words = Set(old.vocabulary.map { $0.lowercased() }).subtracting(new.vocabulary.map { $0.lowercased() })
            phrases = Set(old.replacements.map { $0.phrase.lowercased() }).subtracting(new.replacements.map { $0.phrase.lowercased() })
            modes = Set(old.macModes.map(\.id)).subtracting(new.macModes.map(\.id))
        }
    }

    /// Folds another document into this one, skipping what was removed here.
    public mutating func merge(_ other: SyncDocument, removed: Removed = Removed()) {
        for word in other.vocabulary where !removed.words.contains(word.lowercased()) && !vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { vocabulary.append(word) }
        for rule in other.replacements where !removed.phrases.contains(rule.phrase.lowercased()) && !replacements.contains(where: { $0.phrase.caseInsensitiveCompare(rule.phrase) == .orderedSame }) { replacements.append(rule) }
        for mode in other.macModes where !removed.modes.contains(mode.id) && !macModes.contains(where: { $0.id == mode.id }) { macModes.append(mode) }
    }

    /// The document describing these preferences.
    public init(_ preferences: Preferences) {
        vocabulary = Self.words(preferences.vocabulary)
        replacements = preferences.replacements
        macModes = preferences.modes
    }

    /// Applies merged content to preferences; returns true when anything changed.
    @discardableResult
    public func apply(to preferences: inout Preferences, removed: Removed = Removed()) -> Bool {
        var local = SyncDocument(preferences)
        let before = local
        local.merge(self, removed: removed)
        guard local != before else { return false }
        preferences.vocabulary = local.vocabulary.joined(separator: "\n")
        preferences.replacements = local.replacements
        preferences.modes = local.macModes
        return true
    }
}
