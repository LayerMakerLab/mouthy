import Foundation
import MouthyCore

@MainActor
final class LocalStore {
    let directory: URL
    private var unreadableFiles: Set<String> = []
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.supportDirectory
    }

    /// ~/Library/Application Support/Mouthy: settings, history, Whisper models and the MCP bridge.
    nonisolated static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mouthy", isDirectory: true)
    func load<T: Decodable>(_ name: String, as: T.Type) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch { unreadableFiles.insert(name); throw error }
    }
    func save<T: Encodable>(_ value: T, as name: String) throws {
        guard !unreadableFiles.contains(name) else {
            throw MouthyFailure("The original \(name) could not be read and has been preserved. Export your text before repairing saved data.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent(name)
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
