import Foundation

public struct SettingsBackup: Codable {
    public let version: Int
    public let preferences: Preferences
    public init(_ preferences: Preferences) { version = 1; self.preferences = preferences }
    public static func read(_ data: Data) throws -> Preferences {
        guard data.count <= 1_048_576 else { throw BackupError("Settings backup is larger than 1 MB.") }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.version == 1 else { throw BackupError("This settings version is not supported.") }
        let prefs = backup.preferences
        guard (0...5).contains(prefs.shortcut), prefs.customKeyCode <= 127,
              prefs.replacements.count <= 1000, prefs.modes.count <= 100, prefs.vocabulary.count <= 50_000,
              prefs.customInstructions.count <= 10_000 else { throw BackupError("Settings contain unsupported limits or shortcut values.") }
        return prefs
    }
    public struct BackupError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
