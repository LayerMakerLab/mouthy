import Foundation

/// What happens with the finished text.
public enum OutputAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case insert = "Insert", insertAndReturn = "Insert and press Return", clipboard = "Copy to clipboard", historyOnly = "History only"
    public var id: String { rawValue }
}

public struct ModeShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.label = label }
}

/// A saved dictation profile. The global settings act as the main mode; these override them when activated.
public struct DictationMode: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var writingMode: WritingMode = .verbatim
    public var instructions = ""
    /// nil keeps the engine chosen in Settings.
    public var engine: SpeechEngine?
    public var output: OutputAction = .insert
    /// Bundle identifiers that auto-activate this mode.
    public var apps: [String] = []
    /// Domains such as "github.com" (subdomains match too).
    public var websites: [String] = []
    /// Spoken at the start of a dictation to pick this mode; removed from the text.
    public var triggerWord = ""
    public var shortcut: ModeShortcut?
    /// Give the AI instructions the app, website, nearby text and clipboard.
    public var includeContext = false
    /// Spoken casing and symbols ("camel case user name" → userName, "file dot swift" → file.swift).
    public var codeDictation = false

    public init(name: String) { self.name = name }
    enum CodingKeys: String, CodingKey { case id, name, writingMode, instructions, engine, output, apps, websites, triggerWord, shortcut, includeContext, codeDictation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mode"
        writingMode = (try? c.decode(WritingMode.self, forKey: .writingMode)) ?? .verbatim
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        engine = try? c.decodeIfPresent(SpeechEngine.self, forKey: .engine)
        output = (try? c.decode(OutputAction.self, forKey: .output)) ?? .insert
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        websites = try c.decodeIfPresent([String].self, forKey: .websites) ?? []
        triggerWord = try c.decodeIfPresent(String.self, forKey: .triggerWord) ?? ""
        shortcut = try c.decodeIfPresent(ModeShortcut.self, forKey: .shortcut)
        includeContext = try c.decodeIfPresent(Bool.self, forKey: .includeContext) ?? false
        codeDictation = try c.decodeIfPresent(Bool.self, forKey: .codeDictation) ?? false
    }
}

/// Mode priority: trigger word, then the mode's own shortcut, then website, then app, then the main mode.
public enum ModeResolver {
    /// The mode known when recording starts (the trigger word is only known at the end).
    public static func startMode(_ modes: [DictationMode], shortcutMode: UUID?, url: String?, bundleID: String) -> DictationMode? {
        if let shortcutMode, let mode = modes.first(where: { $0.id == shortcutMode }) { return mode }
        if let host = url.flatMap(host(of:)),
           let mode = modes.first(where: { $0.websites.contains { matches(host: host, site: $0) } }) { return mode }
        if !bundleID.isEmpty, let mode = modes.first(where: { $0.apps.contains(bundleID) }) { return mode }
        return nil
    }

    /// A mode whose trigger word opens the transcript, and the transcript without it.
    public static func trigger(in text: String, modes: [DictationMode]) -> (DictationMode, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for mode in modes.sorted(by: { $0.triggerWord.count > $1.triggerWord.count }) {
            let word = mode.triggerWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, let range = trimmed.range(of: word, options: [.caseInsensitive, .anchored]) else { continue }
            if let next = trimmed[range.upperBound...].first, next.isLetter || next.isNumber { continue }
            let rest = trimmed[range.upperBound...].drop { $0.isWhitespace || ",.:;!?".contains($0) }
            return (mode, SmartInsertion.capitalizingFirstWord(String(rest)))
        }
        return nil
    }

    static func host(of url: String) -> String? {
        (URL(string: url)?.host ?? URL(string: "https://" + url)?.host)?.lowercased()
    }
    static func matches(host: String, site: String) -> Bool {
        var site = site.trimmingCharacters(in: .whitespaces).lowercased()
        if let parsed = Self.host(of: site) { site = parsed }
        if site.hasPrefix("www.") { site.removeFirst(4) }
        guard !site.isEmpty else { return false }
        return host == site || host.hasSuffix("." + site)
    }
}

/// Spoken punctuation: the symbol attaches to the previous word, duplicate recognizer
/// punctuation is removed, and the next word is capitalized after . ? ! and line breaks or rejoined in
/// lowercase after , : ;. Ordinary uses ("a period in history") are left alone.
public enum SpokenPunctuation {
    static let symbols: [(String, String)] = [
        ("new paragraph", "\n\n"), ("new line", "\n"), ("question mark", "?"), ("exclamation point", "!"),
        ("exclamation mark", "!"), ("full stop", "."), ("semicolon", ";"), ("period", "."), ("comma", ","), ("colon", ":")]
    static let ordinaryPredecessors: Set<String> = ["a", "an", "the", "this", "that", "each", "every", "one", "per", "any",
        "some", "my", "your", "our", "their", "his", "her", "its", "trial", "grace", "waiting", "cooling", "time", "billing"]
    static let pattern = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_])(" + symbols.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])",
        options: [.caseInsensitive])
    static let recognizerPunctuation = Set(".,!?;:")

    public static func apply(_ text: String) -> String {
        enum Case { case none, upper, lower }
        var result = ""
        var pending = Case.none
        var cursor = text.startIndex
        func append(_ chunk: Substring) {
            var piece = String(chunk)
            switch pending {
            case .upper: piece = SmartInsertion.capitalizingFirstWord(piece)
            case .lower: piece = SmartInsertion.lowercasingFirstWord(piece)
            case .none: break
            }
            if piece.contains(where: { $0.isLetter || $0.isNumber }) { pending = .none }
            result += piece
        }
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), range.lowerBound >= cursor else { continue }
            append(text[cursor..<range.lowerBound])
            let spoken = text[range].lowercased()
            let symbol = symbols.first { $0.0 == spoken }!.1
            let previousWord = result.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() } ?? ""
            if !symbol.hasPrefix("\n"), ordinaryPredecessors.contains(previousWord) {
                result += text[range]; cursor = range.upperBound; continue
            }
            while let last = result.last, last == " " || recognizerPunctuation.contains(last) { result.removeLast() }
            result += symbol
            pending = symbol.hasPrefix("\n") || ".?!".contains(symbol) ? .upper : .lower
            cursor = range.upperBound
            while cursor < text.endIndex, text[cursor] == " " || recognizerPunctuation.contains(text[cursor]) { cursor = text.index(after: cursor) }
            if !symbol.hasPrefix("\n"), cursor < text.endIndex, !text[cursor].isNewline { result += " " }
        }
        append(text[cursor...])
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
