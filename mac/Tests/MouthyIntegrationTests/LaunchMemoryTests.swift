import Darwin
import Foundation
import Testing
@testable import MouthyKit

// MOUTHY_TEST_MEMORY=1 swift test -c release -Xswiftc -enable-testing --filter ModelMemoryTests
// Scanning the usage logs must hold nothing afterwards: it reads through one small buffer, because macOS malloc
// keeps freed blocks over 128 KB as dirty pages that count as Mouthy's memory (reading about 150 MB of Codex
// session logs in large chunks made them). The gate is the bytes malloc reports in use; the footprint moves with
// machine load, so it is printed as information only. Synthetic logs only. Part of the serialized ModelMemoryTests
// suite, so the model tests never measure while this scan runs.

private func inUseMB() -> Double {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Double(stats.size_in_use) / 1_048_576
}

private func heldMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// Session logs like Codex's: long lines of message text, a token count every few lines.
private func writeLogs(in folder: URL, files: Int, megabytes: Int) throws -> [URL] {
    let text = String(repeating: "lorem ipsum dolor sit amet ", count: 400)
    let message = #"{"timestamp":"2026-10-05T10:00:00.000Z","type":"response_item","payload":{"type":"message","text":"\#(text)"}}"# + "\n"
    let tokens = #"{"timestamp":"2026-10-05T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1200,"cached_input_tokens":200}}}}"# + "\n"
    let block = Data((String(repeating: message, count: 9) + tokens).utf8)
    let perFile = megabytes * 1_048_576 / files
    return try (0..<files).map { index in
        let url = folder.appendingPathComponent("rollout-\(index).jsonl")
        // Files of different sizes, as real sessions are.
        let size = perFile / 2 + (perFile * index) / max(1, files - 1)
        // Written block by block, so the test leaves no large freed buffers behind for the next test to measure.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written = 0
        while written < size { try handle.write(contentsOf: block); written += block.count }
        return url
    }
}

extension ModelMemoryTests {
    @Test func launchMemoryUsageScanHoldsNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeLogs(in: folder, files: 54, megabytes: 146)
        // The appends below write from fixed small buffers, so the test itself adds no large blocks.
        let piece = [UInt8](repeating: UInt8(ascii: "x"), count: 16 << 10)
        let token = Array((#"{"timestamp":"2026-10-05T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10,"cached_input_tokens":0}}}}"# + "\n").utf8)
        malloc_zone_pressure_relief(nil, 0)
        let before = heldMB(), beforeInUse = inUseMB()
        var counted = 0
        var offsets = files.map { UsageScanner.forEachLine($0, containing: "token_count") { _ in counted += 1 } }
        let scanned = heldMB(), firstCount = counted
        // Then what file-system events do while sessions run: logs grow by uneven amounts (a long message, then a
        // token count) and are read from where the last scan stopped, every few seconds.
        var generator = SystemRandomNumberGenerator()
        for round in 0..<80 {
            let index = round % 6
            let handle = try FileHandle(forWritingTo: files[index])
            try handle.seekToEnd()
            try handle.write(contentsOf: Array(#"{"payload":{"text":""#.utf8))
            for _ in 0..<Int.random(in: 1...180, using: &generator) { try handle.write(contentsOf: piece) }
            try handle.write(contentsOf: Array("\"}}\n".utf8))
            try handle.write(contentsOf: token)
            try handle.close()
            offsets[index] = UsageScanner.forEachLine(files[index], from: offsets[index], containing: "token_count") { _ in counted += 1 }
        }
        let after = heldMB(), afterInUse = inUseMB()
        print(String(format: "memory: usage scan of 146 MB, information only: footprint +%.1f MB, after 80 growing rescans +%.1f MB; gate: %+.2f MB in use; %d token counts",
                     scanned - before, after - before, afterInUse - beforeInUse, counted))
        // Counted from memory-mapped files: reading 146 MB into strings here would leave the test's own freed pages
        // dirty and make the model rounds that run next in this suite measure them.
        let needle = Data("\"token_count\"".utf8)
        let expected = try files.reduce(0) { total, file in
            let data = try Data(contentsOf: file, options: .alwaysMapped)
            var count = 0, from = data.startIndex
            while let found = data.range(of: needle, in: from..<data.endIndex) { count += 1; from = found.upperBound }
            return total + count
        }
        #expect(counted == expected && counted == firstCount + 80, "every token count is read once: \(counted) of \(expected)")
        #expect(afterInUse - beforeInUse < 2, "reading the usage logs must hold nothing afterwards: \(afterInUse - beforeInUse) MB in use")
    }
}
