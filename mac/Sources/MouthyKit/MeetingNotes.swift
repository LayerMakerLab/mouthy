import Foundation
import FluidAudio
import FoundationModels
import MouthyCore

/// Turns a recorded meeting folder into "Meeting notes.md": who said what (microphone = You,
/// system audio split by speaker), a summary and action items. Everything runs on this Mac.
enum MeetingNotes {
    struct Line: Codable, Identifiable, Equatable {
        var id = UUID()
        let start: Double
        var speaker: String
        var text: String
        init(start: Double, speaker: String, text: String) { self.start = start; self.speaker = speaker; self.text = text }
    }
    /// Lines saved beside the notes so the transcript viewer can play and edit them.
    static let linesFile = "Meeting transcript.json"
    struct Saved: Codable { var summary: String; var lines: [Line] }

    static var diarizerFiles: (segmentation: URL, embedding: URL) {
        let folder = DiarizerModels.defaultModelsDirectory()
        return (folder.appendingPathComponent(ModelNames.Diarizer.segmentationFile), folder.appendingPathComponent(ModelNames.Diarizer.embeddingFile))
    }

    /// Both speaker models are on disk (a partial cache does not count).
    static var diarizerInstalled: Bool {
        FileManager.default.fileExists(atPath: diarizerFiles.segmentation.path) && FileManager.default.fileExists(atPath: diarizerFiles.embedding.path)
    }

    @MainActor
    static func make(folder: URL, localOnly: Bool, progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        guard ParakeetRecognizer.installed else { throw MouthyFailure("Meeting notes use NVIDIA Parakeet. Download it in Settings first.") }
        let converter = AudioConverter()
        let mic = folder.appendingPathComponent("Microphone.wav")
        let system = folder.appendingPathComponent("System audio.wav")
        guard FileManager.default.fileExists(atPath: mic.path) || FileManager.default.fileExists(atPath: system.path) else {
            throw MouthyFailure("That folder has no Microphone.wav or System audio.wav.")
        }
        var lines: [Line] = []
        if FileManager.default.fileExists(atPath: mic.path) {
            progress("Transcribing your microphone…")
            lines += try await transcribe(try converter.resampleAudioFile(mic), speaker: "You")
        }
        if FileManager.default.fileExists(atPath: system.path) {
            let samples = try converter.resampleAudioFile(system)
            if diarizerInstalled || !localOnly {
                progress("Finding who spoke when…")
                // Local Only Mode loads the files on disk and never reaches the downloader.
                let models = localOnly
                    ? try DiarizerModels.load(localSegmentationModel: diarizerFiles.segmentation, localEmbeddingModel: diarizerFiles.embedding)
                    : try await DiarizerModels.downloadIfNeeded()
                let diarizer = DiarizerManager()
                diarizer.initialize(models: models)
                let segments = try diarizer.performCompleteDiarization(samples).segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
                lines += try await transcribe(samples, segments: segments, progress: progress)
            } else {
                progress("Transcribing system audio (speaker detection needs a one-time download)…")
                lines += try await transcribe(samples, speaker: "Others")
            }
        }
        lines.sort { $0.start < $1.start }
        var summary = "_Summary unavailable: turn on Apple Intelligence to summarize meetings on this Mac._"
        if SystemLanguageModel.default.isAvailable, !lines.isEmpty {
            progress("Writing the summary on this Mac…")
            summary = (try? await summarize(lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n"))) ?? summary
        }
        return try write(Saved(summary: summary, lines: lines), to: folder)
    }

    /// Writes "Meeting notes.md" and the editable line data.
    @discardableResult
    static func write(_ saved: Saved, to folder: URL) throws -> URL {
        let transcript = saved.lines.map { "[\(clock($0.start))] **\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
        let notes = """
        # \(folder.lastPathComponent)

        \(saved.summary)

        ## Transcript

        \(transcript.isEmpty ? "_No speech was detected._" : transcript)

        """
        let output = folder.appendingPathComponent("Meeting notes.md")
        try notes.write(to: output, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(saved).write(to: folder.appendingPathComponent(linesFile), options: .atomic)
        return output
    }

    static func load(_ folder: URL) -> Saved? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(linesFile)) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    /// One speaker: split near quiet moments into ≤25 s pieces.
    private static func transcribe(_ samples: [Float], speaker: String) async throws -> [Line] {
        var lines: [Line] = []
        for range in AudioChunks.ranges(samples, maxSamples: 16_000 * 25) {
            let text = try await ParakeetRecognizer.shared.transcribe(samples: Array(samples[range]))
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(Line(start: Double(range.lowerBound) / 16_000, speaker: speaker, text: text))
            }
        }
        return lines
    }

    /// Several speakers: merge consecutive segments of the same speaker (≤30 s) and transcribe each turn.
    @MainActor
    private static func transcribe(_ samples: [Float], segments: [TimedSpeakerSegment], progress: @escaping @MainActor (String) -> Void) async throws -> [Line] {
        var names: [String: String] = [:]
        var turns: [(speaker: String, start: Float, end: Float)] = []
        for segment in segments {
            if let last = turns.last, last.speaker == segment.speakerId, segment.startTimeSeconds - last.end < 1.0, segment.endTimeSeconds - last.start < 30 {
                turns[turns.count - 1].end = segment.endTimeSeconds
            } else {
                turns.append((segment.speakerId, segment.startTimeSeconds, segment.endTimeSeconds))
            }
        }
        var lines: [Line] = []
        for (index, turn) in turns.enumerated() {
            if index % 10 == 0 { progress("Transcribing speakers… \(index * 100 / max(1, turns.count))%") }
            let start = max(0, Int(turn.start * 16_000)), end = min(samples.count, Int(turn.end * 16_000))
            guard end - start >= 8_000 else { continue }
            let text = try await ParakeetRecognizer.shared.transcribe(samples: Array(samples[start..<end]))
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let name = names[turn.speaker] ?? { let n = "Speaker \(names.count + 1)"; names[turn.speaker] = n; return n }()
            lines.append(Line(start: Double(turn.start), speaker: name, text: text))
        }
        return lines
    }

    /// Summary and action items; long meetings are summarized in parts first.
    private static func summarize(_ transcript: String) async throws -> String {
        let instructions = "You write meeting notes from a transcript. Use only what was said; never invent names, dates or decisions. Be brief and plain."
        var material = transcript
        if material.count > 9_000 {
            var partials: [String] = []
            var part = ""
            for line in material.split(separator: "\n") {
                if part.count + line.count > 8_000 { partials.append(part); part = "" }
                part += line + "\n"
            }
            if !part.isEmpty { partials.append(part) }
            var summaries: [String] = []
            for piece in partials {
                let session = LanguageModelSession(instructions: instructions)
                summaries.append(try await session.respond(to: "Summarize this part of a meeting in a few bullet points, keeping any commitments and owners:\n\n" + piece).content)
            }
            material = summaries.joined(separator: "\n")
        }
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: """
        From this meeting material, write exactly two Markdown sections:
        ## Summary
        3–6 bullet points.
        ## Action items
        One checkbox per commitment that was actually stated, naming the person when the transcript does,
        for example "- [ ] You: send the revised quote by Friday" or "- [ ] Speaker 2: confirm the budget".
        If nobody committed to anything, write only "- None stated".

        \(material)
        """)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
