import Foundation

/// The file Mouthy keeps in a sync folder (iCloud Drive, Dropbox, a network share…). Merging only
/// adds: words and replacements are unioned, modes are matched by id. No server, no account.
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

    /// Folds another document into this one.
    public mutating func merge(_ other: SyncDocument) {
        for word in other.vocabulary where !vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { vocabulary.append(word) }
        for rule in other.replacements where !replacements.contains(where: { $0.phrase.caseInsensitiveCompare(rule.phrase) == .orderedSame }) { replacements.append(rule) }
        for mode in other.macModes where !macModes.contains(where: { $0.id == mode.id }) { macModes.append(mode) }
    }

    /// The document describing these preferences.
    public init(_ preferences: Preferences) {
        vocabulary = Self.words(preferences.vocabulary)
        replacements = preferences.replacements
        macModes = preferences.modes
    }

    /// Applies merged content to preferences; returns true when anything changed.
    @discardableResult
    public func apply(to preferences: inout Preferences) -> Bool {
        var local = SyncDocument(preferences)
        let before = local
        local.merge(self)
        guard local != before else { return false }
        preferences.vocabulary = local.vocabulary.joined(separator: "\n")
        preferences.replacements = local.replacements
        preferences.modes = local.macModes
        return true
    }
}
