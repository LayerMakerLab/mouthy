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

/// Spoken marks in ordinary dictation, written as the mark where the words around them say so: "Maple dash Design"
/// → Maple-Design, "commit dash m" → commit -m, "dash dash help" → --help, "example dot com" → example.com, "readme
/// dot md" → readme.md, "dot env" → .env, "type slash help" → type /help, "slash clear" alone → /clear, "user
/// underscore name" → user_name.
/// Strict on purpose, so the words stay words wherever they could be meant: only on one line with nothing but spaces
/// between the spoken mark and its neighbours ("say dash, I mean" and a "dash" that ends the text are left), never
/// next to another mark, never after or before a word that makes it ordinary ("a dash of salt", "the dot com years",
/// "an underscore between"), "dot" and "slash" only in the shapes listed below, and never a mark that is one of the
/// person's own words (`vocabulary`: "Dash" the app stays "Dash"). Every rule looks only at the word before and the
/// word after, never further ahead: a live guess then never has to take back a join, and what was typed stays the
/// start of what is typed next. Code modes have their own table (`CodeDictation`). Works one code point at a time,
/// as the Rust twin does.
public enum SpokenJoiners {
    static let marks: Set<String> = ["dash", "hyphen", "dot", "slash", "underscore"]
    /// Web endings and file endings: "dot" before one of these is written onto the word before.
    static let endings: Set<String> = ["com", "org", "dev", "io", "ai", "app", "co", "edu", "gov", "uk",
        "md", "txt", "json", "swift", "py", "js", "ts", "html", "css", "pdf", "png", "jpg", "zip", "sh", "toml", "yaml", "yml",
        "rs", "csv", "xml", "plist"]
    /// File names that start with a dot: "dot env" → .env, whatever comes before.
    static let dotFiles: Set<String> = ["env", "gitignore", "zshrc", "bashrc", "git", "github", "claude", "ssh", "vscode", "npmrc",
        "dockerignore"]
    static let ordinaryBefore: Set<String> = ["a", "an", "the", "this", "that", "each", "every", "any", "some", "my", "your",
        "our", "their", "his", "her", "its", "mad", "quick", "door", "em", "en", "to", "i", "we", "you", "they", "i'll", "we'll",
        "you'll", "they'll", "let's", "gotta", "say", "says", "said", "saying", "word"]
    static let ordinaryAfter: Set<String> = ["cam", "is", "was", "means"]
    /// A dot-file is named after one of these or at the very start ("the dot env file", "in dot gitignore"); after any
    /// other word "dot github" is part of an address ("api dot github dot com").
    static let dotFileBefore: Set<String> = ["in", "into", "from", "of", "add", "edit", "open", "check", "see", "and", "or", "called",
        "named", "with", "at", "on"]
    /// "an underscore between the words", "you should underscore that point".
    static let underscoreBefore: Set<String> = ["a", "an", "the", "to", "should", "will", "would", "with", "and", "add", "of", "that",
        "this", "one", "single", "double", "leading", "trailing", "say", "says", "said", "saying", "word"]
    static let underscoreAfter: Set<String> = ["the", "that", "this", "how", "a", "an", "between", "before", "after", "in", "is", "to",
        "for", "and", "or", "character", "key", "symbol", "sign", "means", "was", "why", "what", "when", "where", "who", "one", "our",
        "my", "your", "his", "her", "their", "its", "just", "all", "some", "any", "these", "those", "each", "every", "both", "it"]
    /// "type slash help" → type /help. Only after "type": "try slash catch" and "send slash receive" are pairs. And a
    /// dictation that is nothing but "slash" and one word is a command, "slash clear" → /clear (for working
    /// hands free: the person presses send themselves, so a command is spoken like any other text; speech never
    /// presses Return). Only the whole dictation: a sentence that begins with "slash" stays one ("Slash spending by half"),
    /// and so does the word before one of these ("Slash it").
    static let slashTyped: Set<String> = ["type", "typed"]
    static let slashAfter: Set<String> = ["the", "a", "an", "and", "or", "command", "commands", "prices", "costs", "is", "was", "means",
        "my", "your", "our", "their", "his", "her", "its", "it", "that", "this", "these", "those", "through", "at"]

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isAlphabetic }
    static func isNumber(_ scalar: Unicode.Scalar) -> Bool {
        [.decimalNumber, .letterNumber, .otherNumber].contains(scalar.properties.generalCategory)
    }

    /// `open`: more words may follow (a live guess). The text then stops before a spoken mark until two words follow
    /// it, the second being what shows that the first is whole. So the field never shows a "dash" that turns into
    /// "-" a moment later or a join that a longer word takes back, and words left in a field never end on a mark.
    public static func apply(_ text: String, vocabulary: String = "", open: Bool = false) -> String {
        let (written, command) = write(text, vocabulary: vocabulary, open: open, commands: true)
        // A command is one word. Where a mark in it did not join ("slash to dash do": "to dash" is ordinary), the
        // text is no command after all.
        let inner = written.unicodeScalars.drop(while: \.properties.isWhitespace).reversed().drop(while: \.properties.isWhitespace)
        return command && inner.contains(where: \.properties.isWhitespace) ? write(text, vocabulary: vocabulary, open: open, commands: false).text : written
    }

    /// `commands` false: a text that begins with "slash" is never written as a command. `command`: it was.
    private static func write(_ text: String, vocabulary: String, open: Bool, commands: Bool) -> (text: String, command: Bool) {
        typealias Piece = ArraySlice<Unicode.Scalar>
        let scalars = Array(text.unicodeScalars)
        // The words and the gap before each one; `tail` is the whitespace after the last word.
        var words: [Piece] = [], gaps: [Piece] = []
        var index = 0
        while let start = scalars[index...].firstIndex(where: { !$0.properties.isWhitespace }) {
            let end = scalars[start...].firstIndex(where: { $0.properties.isWhitespace }) ?? scalars.count
            gaps.append(scalars[index..<start]); words.append(scalars[start..<end])
            index = end
        }
        func string(_ piece: Piece) -> String { String(String.UnicodeScalarView(piece)) }
        let lower = words.map { string($0).lowercased() }
        // The person's own words: whole vocabulary entries ("Dash"), not a word inside one ("Polka Dot Studio").
        let own = Set(vocabulary.lowercased().unicodeScalars.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" })
            .map { String(String.UnicodeScalarView($0.drop(while: \.properties.isWhitespace).reversed().drop(while: \.properties.isWhitespace).reversed())) })
        func spaces(_ gap: Piece) -> Bool { !gap.isEmpty && gap.allSatisfy { $0 == " " } }
        func startsWord(_ word: Piece) -> Bool { word.first.map { isLetter($0) || isNumber($0) } ?? false }
        func lead(_ at: Int) -> String { string(words[at].prefix(while: isLetter)).lowercased() }
        /// The word at `at` with its leading letters in lowercase, when those letters are one of `names` and no digit
        /// or underscore follows them ("com", "com." and "com/docs", not "community" or "com2").
        func named(_ at: Int, _ names: Set<String>) -> String? {
            let rest = words[at].drop(while: isLetter)
            guard names.contains(lead(at)), rest.first.map({ !isNumber($0) && $0 != "_" }) ?? true else { return nil }
            return lead(at) + string(rest)
        }
        let last = words.count - 1
        let closing = Set(".,!?;:…".unicodeScalars)
        /// The spoken mark a word is, unless it is one of the person's own words: the bare word ("dash," is a word,
        /// the recognizer heard a break there), or in a live guess the last word with the mark a pause puts after it
        /// ("dash." while the person is still speaking).
        func mark(_ at: Int) -> String? {
            var word = lower[at]
            if open, at == last, words[at].drop(while: isLetter).allSatisfy({ closing.contains($0) }) { word = lead(at) }
            return marks.contains(word) && !own.contains(word) ? word : nil
        }
        var out = String.UnicodeScalarView()
        // The last word written so far, with what was joined onto it ("up-to").
        var written = ""
        func write(_ gap: Piece, _ word: String) { out.append(contentsOf: gap); out.append(contentsOf: word.unicodeScalars); written = word }
        // Whether the whole text can be one spoken command: "slash", a word, and nothing after it but more words
        // joined on by a mark ("slash code dash review"), all with single spaces between. A sentence that only begins
        // with "slash" ("Slash spending by half") is no command.
        // (A live guess is one while its words so far could still become one, "slash code dash", and its last word
        // may still grow into anything: "slash user under" into "underscore".)
        let alternates = words.indices.dropFirst().dropLast(open ? 1 : 0).allSatisfy { at in
            spaces(gaps[at]) && (at % 2 == 0) == ["dash", "hyphen", "underscore"].contains(mark(at) ?? "") && (at % 2 == 0 || !marks.contains(lead(at)))
        }
        let commandOnly = commands && alternates && (open ? words.count < 2 || spaces(gaps[last]) : words.count >= 2 && words.count % 2 == 0)
        var command = false
        var i = 0
        scan: while i < words.count {
            guard let word = mark(i) else { write(gaps[i], string(words[i])); i += 1; continue }
            let next = i + 1 < words.count && spaces(gaps[i + 1]) ? i + 1 : nil
            if word == "dash", let next, mark(next) == "dash" {
                if open, next + 1 >= last {
                    // A live guess: the word after the two is not there yet, or may still grow.
                    break
                } else if next < last, spaces(gaps[next + 1]), startsWord(words[next + 1]), !marks.contains(lead(next + 1)) {
                    write(gaps[i], "--" + string(words[next + 1])); i += 3
                } else {
                    write(gaps[i], string(words[i])); write(gaps[next], string(words[next])); i += 2
                }
                continue
            }
            // A live guess shows a spoken mark only once the word after it is whole, which is when another word
            // follows that one: the last word of a guess may still grow ("k" into "kiwi", "co" into "come", "i" into
            // "is"), and with it what the mark is. Until then the text stops before the mark.
            if open, i + 1 >= last { break }
            // The word before, as the ordinary words are listed: lowercase, a straight apostrophe, no opening quote.
            let before = String(written.lowercased().replacingOccurrences(of: "’", with: "'").unicodeScalars.drop { !isLetter($0) && !isNumber($0) })
            // Onto the word before: one space between them, and that word is no spoken mark itself.
            let joins = spaces(gaps[i]) && (written.unicodeScalars.last.map { isLetter($0) || isNumber($0) } ?? false) && !marks.contains(before)
            let begins = i == 0 || spaces(gaps[i])
            // Never before another spoken mark either ("with dash dash." stays words).
            if let next, startsWord(words[next]), !marks.contains(lead(next)) {
                let after = lead(next), rest = string(words[next])
                var joined: String?, begun: String?
                switch word {
                case "dot":
                    if joins, before == "www" { joined = "." + rest }
                    else if joins, !ordinaryBefore.contains(before), let end = named(next, endings) { joined = "." + end }
                    else if begins, !joins || ordinaryBefore.contains(before) || dotFileBefore.contains(before),
                            let file = named(next, dotFiles) { begun = "." + file }
                case "slash":
                    let address = written.unicodeScalars.contains { $0 == "." || $0 == "/" }
                    let numbers = written.unicodeScalars.allSatisfy(isNumber) && (words[next].first.map(isNumber) ?? false)
                    if joins, address || numbers || (before == "and" && after == "or") { joined = "/" + rest }
                    else if spaces(gaps[i]), slashTyped.contains(before), !after.isEmpty, !slashAfter.contains(after) { begun = "/" + rest }
                    // A dictation that is nothing but a command ("slash clear" → /clear), its ASCII letters in lowercase.
                    else if i == 0, commandOnly, !after.isEmpty, !slashAfter.contains(after) {
                        // A live guess cannot know yet that nothing more follows ("slash com dash is" may go on as a
                        // sentence): it shows nothing while the words so far could be a command.
                        if open { break scan }
                        begun = "/" + String(String.UnicodeScalarView(words[next].map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 }))
                        command = true
                    }
                case "underscore":
                    if joins, !underscoreBefore.contains(before), !underscoreAfter.contains(after) { joined = "_" + rest }
                default:
                    guard joins, !ordinaryBefore.contains(before), !ordinaryAfter.contains(after) else { break }
                    // One letter after a longer word that starts with a letter is an option of a command: "commit dash m"
                    // → commit -m ("10 dash K" and "x dash y" join), whatever mark the recognizer put after the letter.
                    let letter = after.unicodeScalars.count == 1 && after != "a" && after != "i"
                        && !words[next].drop(while: isLetter).contains { isLetter($0) || isNumber($0) }
                    let command = before.unicodeScalars.count > 1 && (before.unicodeScalars.first.map(isLetter) ?? false)
                    if letter, command { begun = "-" + rest } else { joined = "-" + rest }
                }
                if let joined { out.append(contentsOf: joined.unicodeScalars); written += joined; i += 2; continue }
                if let begun { write(gaps[i], begun); i += 2; continue }
            }
            write(gaps[i], string(words[i])); i += 1
        }
        // The period a recognizer ends every dictation with is no part of a command ("/clear." is not one).
        if command, i == words.count, out.last == ".", out.dropLast().last != "." { out.removeLast() }
        if i == words.count { out.append(contentsOf: scalars[index...]) }
        return (String(out), command)
    }

    /// Whether `text` starts with a dot-file name that is a word of its own (".env", ".claude/hooks", ".gitignore,"),
    /// not the start of something longer (".github.com" going on after "www"): `SmartInsertion` gives it a space.
    static func startsDotFile(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.first == "." else { return false }
        let name = scalars.dropFirst().prefix(while: isLetter), rest = Array(scalars.dropFirst(1 + name.count))
        guard dotFiles.contains(String(String.UnicodeScalarView(name)).lowercased()) else { return false }
        func inWord(_ scalar: Unicode.Scalar) -> Bool { isLetter(scalar) || isNumber(scalar) }
        guard let first = rest.first else { return true }
        // ".env's" and ".env-specific" are the file; ".github.com" goes on, and so does ".env2" or ".env_file".
        return !inWord(first) && first != "_" && !(first == "." && rest.count > 1 && inWord(rest[1]))
    }
}
