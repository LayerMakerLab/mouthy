import Foundation

public struct TimedSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start.isFinite ? max(0, start) : 0
        self.end = end.isFinite ? max(self.start, end) : self.start
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct TranscriptionDocument: Codable, Sendable {
    public var text: String
    public var language: String?
    public var segments: [TimedSegment]
    public init(text: String, language: String? = nil, segments: [TimedSegment] = []) {
        self.text = text; self.language = language; self.segments = segments
    }
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case text, json, srt, vtt
        public var id: String { rawValue }
        public var fileExtension: String { self == .text ? "txt" : rawValue }
    }
    public func exported(as format: Format) throws -> Data {
        if format == .json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
        if format == .text { return Data((text + "\n").utf8) }
        let separator = format == .srt ? "," : "."
        func timestamp(_ value: Double) -> String {
            let ms = Int((max(0, min(value, 359_999)) * 1000).rounded())
            return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
        }
        let cues = segments.filter { !$0.text.isEmpty && $0.end > $0.start }.enumerated().map { index, segment in
            let number = format == .srt ? "\(index + 1)\n" : ""
            return number + timestamp(segment.start) + " --> " + timestamp(segment.end) + "\n" + segment.text.replacingOccurrences(of: "\n\n", with: "\n")
        }
        guard !cues.isEmpty || text.isEmpty else { throw ExportError.missingTimings }
        return Data(((format == .vtt ? "WEBVTT\n\n" : "") + cues.joined(separator: "\n\n") + "\n").utf8)
    }
    public enum ExportError: LocalizedError {
        case missingTimings
        public var errorDescription: String? { "No segment timestamps are available. Export plain text or JSON instead." }
    }
}
