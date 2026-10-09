import Testing
import Foundation
import MouthyCore

@Test func headlessOptionsRequireSafeBatchDestinations() throws {
    #expect(throws: MouthyCommand.ArgumentError.self) { try MouthyCommand.parse(["transcribe", "a.wav", "b.wav"]) }
    #expect(throws: MouthyCommand.ArgumentError.self) { try MouthyCommand.parse(["transcribe", "a.wav", "--translate"]) }
    #expect(throws: MouthyCommand.ArgumentError.self) { try MouthyCommand.parse(["transcribe", "a.wav", "--engine"]) }
    #expect(throws: MouthyCommand.ArgumentError.self) { try MouthyCommand.parse(["download", "whisper", "--engine", "apple"]) }
    #expect(throws: MouthyCommand.ArgumentError.self) { try MouthyCommand.parse(["transcribe", "a.wav", "--engine", "whisper", "--model", "turbo", "--translate"]) }
    guard case let .transcribe(options) = try MouthyCommand.parse(["transcribe", "a.wav", "b.wav", "--output-dir", "out", "--engine", "whisper", "--model", "small", "--translate", "--format", "srt"]) else { Issue.record("Expected transcription command"); return }
    #expect(options.inputs == ["a.wav", "b.wav"])
    #expect(options.engine == .whisper && options.model == .small && options.translate)
    #expect(options.format == .srt)
}

@Test func timedExportUsesRealSegmentsAndRejectsMissingTimings() throws {
    let doc = TranscriptionDocument(text: "Hello.", segments: [TimedSegment(start: 1.125, end: 2.25, text: "Hello.")])
    let srt = String(decoding: try doc.exported(as: .srt), as: UTF8.self)
    #expect(srt == "1\n00:00:01,125 --> 00:00:02,250\nHello.\n")
    let vtt = String(decoding: try doc.exported(as: .vtt), as: UTF8.self)
    #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.125"))
    let decoded = try JSONDecoder().decode(TranscriptionDocument.self, from: doc.exported(as: .json))
    #expect(decoded.segments == doc.segments)
    #expect(throws: TranscriptionDocument.ExportError.self) { try TranscriptionDocument(text: "No times").exported(as: .srt) }
}
