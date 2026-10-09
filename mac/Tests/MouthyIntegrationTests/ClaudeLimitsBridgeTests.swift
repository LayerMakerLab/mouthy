import Testing
import Foundation
@testable import MouthyKit

/// The status-line script Claude Code runs must work on any Mac: only /bin and /usr/bin tools, no Python.
@Test func claudeStatusLineScriptSavesOnlyRateLimits() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let script = home.appendingPathComponent("statusline.sh")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try ClaudeLimitsBridge.script.write(to: script, atomically: true, encoding: .utf8)
    #expect(!ClaudeLimitsBridge.script.contains("python"))
    func run(_ input: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8)); try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
    let saved = home.appendingPathComponent("Library/Application Support/Mouthy/claude-limits.json")
    try run(#"{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":12},"seven_day":{"used_percentage":40,"resets_at":1791200000}}}"#)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any])
    #expect(object["model"] == nil)
    #expect(((object["seven_day"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue == 40)
    // Input without limits leaves the saved file alone.
    try run(#"{"model":{"id":"x"}}"#)
    #expect(FileManager.default.fileExists(atPath: saved.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: saved.deletingLastPathComponent().path).filter { $0.hasPrefix(".claude-limits") }
    #expect(leftovers.isEmpty)
}
