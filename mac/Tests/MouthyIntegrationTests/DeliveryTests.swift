import Testing
import AppKit
import ApplicationServices
@testable import MouthyKit

// Headless delivery harness: drives scripts/delivery-target.swift, a background app with an
// off-screen text view. It never takes screen focus, sends no keystrokes and uses a private
// pasteboard. Requires Accessibility for the terminal running the tests.

private func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

@MainActor
final class Harness {
    let process = Process()
    let app: NSRunningApplication
    let field: AXUIElement
    let pasteboard = NSPasteboard(name: .init("dev.mouthy.Mouthy.delivery-test"))
    /// Pasteboard types present at the moment each paste keystroke would be sent.
    var typesAtPaste: [[NSPasteboard.PasteboardType]] = []

    init() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-delivery-target")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("target")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/delivery-target.swift")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", "-O", source.path, "-o", binary.path]
        try compile.run(); compile.waitUntilExit()
        try #require(compile.terminationStatus == 0)
        let output = Pipe()
        process.executableURL = binary; process.standardOutput = output
        try process.run()
        _ = output.fileHandleForReading.availableData // "ready"
        app = try #require(NSRunningApplication(processIdentifier: process.processIdentifier))
        var found: AXUIElement?
        for _ in 0..<20 where found == nil {
            found = TextDelivery.focusedElement(pid: app.processIdentifier)
            if found == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        field = try #require(found)
        let pid = app.processIdentifier
        // The target must never show on the screen (it once popped up): no window of it on screen and visible.
        let shown = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowAlpha as String] as? Double) ?? 1) > 0 }
        #expect(shown.isEmpty, "the delivery target showed \(shown.count) window(s)")
        TextDelivery.frontmost = { NSRunningApplication(processIdentifier: pid) }
        TextDelivery.pasteboard = pasteboard
        let board = pasteboard
        TextDelivery.postPaste = { [weak self] _, _ in
            self?.typesAtPaste.append(board.types ?? [])
            DistributedNotificationCenter.default().postNotificationName(.init("dev.mouthy.Mouthy.delivery-test.paste"), object: nil, deliverImmediately: true)
        }
    }
    func set(_ text: String, cursor: Int, length: Int = 0) {
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
        var range = CFRange(location: cursor, length: length)
        AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &range)!)
    }
    var value: String { axValue(field, kAXValueAttribute) as? String ?? "" }
    /// Never hands delivery back to the real frontmost app or clipboard: a test still dictating in another suite would
    /// paste into whatever app is open (it once pasted into a chat app). After a harness, nothing is focused.
    func stop() {
        process.terminate()
        TextDelivery.frontmost = { nil }
        TextDelivery.pasteboard = NSPasteboard(name: .init("dev.mouthy.Mouthy.delivery-test.idle"))
    }
}

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_DELIVERY"] == "1"))
struct HeadlessDelivery {
    @Test func smartInsertionIsVerifiedAndClipboardRestored() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.pasteboard.clearContents(); harness.pasteboard.setString("previous clipboard", forType: .string)
        harness.set("The cat sat down.", cursor: 7)
        let status = await TextDelivery.deliver("Really big.", to: TextDelivery.capture(), smartFormatting: true)
        #expect(status == "Inserted into target.")
        #expect(harness.value == "The cat really big sat down.")
        // Remembered for learning corrected words: where and what was inserted.
        #expect(TextDelivery.lastInsertion?.location == 7 && TextDelivery.lastInsertion?.text == " really big")
        #expect(harness.pasteboard.string(forType: .string) == "previous clipboard")
        // While the dictated words sit on the clipboard they are marked so clipboard managers skip them.
        #expect(harness.typesAtPaste.count == 1)
        #expect(harness.typesAtPaste.first?.contains(TextDelivery.transientType) == true)
        #expect(harness.typesAtPaste.first?.contains(TextDelivery.autoGeneratedType) == true)
        // The restored clipboard is marked auto-generated (not a new copy) and is not transient.
        let restored = harness.pasteboard.types ?? []
        #expect(restored.contains(TextDelivery.autoGeneratedType))
        #expect(!restored.contains(TextDelivery.transientType))
    }
    @Test func largeClipboardImageDoesNotBlockInsertion() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let item = NSPasteboardItem()
        item.setString("kept text", forType: .string)
        item.setData(Data(count: 20 * 1024 * 1024), forType: .tiff)
        harness.pasteboard.clearContents(); harness.pasteboard.writeObjects([item])
        harness.set("", cursor: 0)
        let status = await TextDelivery.deliver("hello there.", to: TextDelivery.capture(), smartFormatting: true)
        #expect(status == "Inserted into target.")
        #expect(harness.pasteboard.string(forType: .string) == "kept text")
    }
    @Test func emptyFieldGetsCapitalizedSentence() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("", cursor: 0)
        _ = await TextDelivery.deliver("hello there.", to: TextDelivery.capture(), smartFormatting: true)
        #expect(harness.value == "Hello there.")
    }
    @Test func followsTheCursorWhereverItIsAtFinish() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("Keep this text.", cursor: 4)
        let target = TextDelivery.capture()
        harness.set("Keep this text.", cursor: 9)
        let status = await TextDelivery.deliver("Inserted.", to: target, smartFormatting: true)
        #expect(status == "Inserted into target.")
        #expect(harness.value == "Keep this inserted text.")
    }
    @Test func rewriteRefusesAChangedSelection() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("Keep this text.", cursor: 5, length: 4)
        let target = TextDelivery.capture()
        harness.set("Keep this text.", cursor: 0, length: 4)
        let status = await TextDelivery.deliver("that", to: target, replacingSelection: true)
        #expect(status.hasPrefix("Ready to copy"))
        #expect(harness.value == "Keep this text.")
    }
    @Test func neverPastesIntoMouthyItself() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("Untouched.", cursor: 10)
        let target = TextDelivery.capture()
        TextDelivery.frontmost = { NSRunningApplication.current }
        let status = await TextDelivery.deliver("inserted", to: target, smartFormatting: true)
        #expect(status.hasPrefix("Ready to copy"))
        #expect(harness.value == "Untouched.")
    }
}
