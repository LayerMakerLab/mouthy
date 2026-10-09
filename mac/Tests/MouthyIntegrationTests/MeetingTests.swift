import MouthyCore
import Testing
import Foundation
import AVFoundation
import ScreenCaptureKit
@testable import MouthyKit

@Test func meetingTracksStaySeparateAndRetainTimingGaps() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sink = MeetingAudioSink(folder: folder, onFailure: { _ in }, onWaveform: { _ in })
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    buffer.frameLength = 4800
    for channel in 0..<2 { for index in 0..<4800 { buffer.floatChannelData![channel][index] = sin(Float(index) * 0.05) * 0.2 } }
    try sink.write(buffer, timestamp: 100, type: .audio)
    try sink.write(buffer, timestamp: 101, type: .microphone)
    sink.close()
    let system = try AVAudioFile(forReading: folder.appendingPathComponent("System audio.wav"))
    let mic = try AVAudioFile(forReading: folder.appendingPathComponent("Microphone.wav"))
    #expect(abs(system.length - 1600) < 100)
    #expect(abs(mic.length - 17600) < 100)
    #expect(system.processingFormat.channelCount == 1 && system.processingFormat.sampleRate == 16_000)
    #expect(mic.length > system.length)
}

/// `MOUTHY_TEST_MEETING=/path/to/meeting-folder swift test --filter meetingNotesFromFolder`
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_MEETING"] != nil))
func meetingNotesFromFolder() async throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOUTHY_TEST_MEETING"]!)
    let notes = try await MeetingNotes.make(folder: folder, localOnly: false) { print("…", $0) }
    let text = try String(contentsOf: notes, encoding: .utf8)
    print(text)
    #expect(text.contains("**You:**") && text.contains("**Speaker 1:**"))
}

@MainActor @Test func twoMachinesShareVocabularyThroughASyncFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let shared = root.appendingPathComponent("Shared"); try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = AppModel(store: LocalStore(directory: root.appendingPathComponent("A")), enablesHotkey: false)
    let b = AppModel(store: LocalStore(directory: root.appendingPathComponent("B")), enablesHotkey: false)
    a.preferences.syncFolder = shared.path; b.preferences.syncFolder = shared.path
    a.preferences.vocabulary = "Zephyr"; a.syncNow()
    b.preferences.vocabulary = "Nimbus"; b.syncNow()
    a.syncNow()
    #expect(b.preferences.vocabulary == "Nimbus\nZephyr")
    #expect(a.preferences.vocabulary == "Zephyr\nNimbus")
    // An unreadable sync file is preserved, not overwritten.
    let file = shared.appendingPathComponent(SyncDocument.fileName)
    try Data("not json".utf8).write(to: file)
    a.syncNow()
    #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
}

@MainActor @Test func transcriptEditsSaveBackToNotes() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var saved = MeetingNotes.Saved(summary: "## Summary\n- Speaker 1 agreed.", lines: [
        .init(start: 0, speaker: "You", text: "Hello."), .init(start: 4, speaker: "Speaker 1", text: "Hi there.")])
    try MeetingNotes.write(saved, to: folder)
    saved.lines[1].speaker = "Dana"; saved.lines[1].text = "Hi there, thanks."
    saved.summary = saved.summary.replacingOccurrences(of: "Speaker 1", with: "Dana")
    let notes = try MeetingNotes.write(saved, to: folder)
    let text = try String(contentsOf: notes, encoding: .utf8)
    #expect(text.contains("[00:04] **Dana:** Hi there, thanks.") && text.contains("- Dana agreed."))
    #expect(MeetingNotes.load(folder)?.lines.map(\.speaker) == ["You", "Dana"])
}
