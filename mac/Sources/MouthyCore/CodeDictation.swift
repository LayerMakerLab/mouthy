import Foundation

/// Developer dictation: spoken casing ("camel case user name" → userName) and symbols
/// ("file dot swift" → file.swift, "open paren" → "("). Applied in developer apps and code modes.
public enum CodeDictation {
    // Opt-in per mode only: prose dictated into terminals (e.g. to coding agents) must stay prose.

    enum Casing: String, CaseIterable { case camel, pascal, snake, kebab, constant, upper, lower }
    static let casingPhrases: [(String, Casing)] = [
        ("camel case", .camel), ("pascal case", .pascal), ("snake case", .snake), ("kebab case", .kebab),
        ("constant case", .constant), ("screaming snake case", .constant), ("all caps", .upper), ("lower case", .lower)]

    /// How a symbol meets its neighbours: `join` glues both sides (file.swift), `prefix` keeps a space before
    /// and glues after (-m, @user), `open` glues after ("(" also glues before: f(), `close` glues before,
    /// `quote` opens or closes, `spaced` keeps spaces on both sides (=, ->).
    enum Fit { case join, prefix, open, close, quote, spaced }
    static let symbols: [(phrase: String, symbol: String, fit: Fit)] = [
        ("open paren", "(", .open), ("close paren", ")", .close), ("open parenthesis", "(", .open), ("close parenthesis", ")", .close),
        ("open bracket", "[", .open), ("close bracket", "]", .close), ("open brace", "{", .open), ("close brace", "}", .close),
        ("open curly", "{", .open), ("close curly", "}", .close), ("open angle", "<", .open), ("close angle", ">", .close),
        ("fat arrow", "=>", .spaced), ("arrow", "->", .spaced), ("double equals", "==", .spaced), ("triple equals", "===", .spaced),
        ("not equals", "!=", .spaced), ("equals", "=", .spaced), ("plus equals", "+=", .spaced), ("greater than", ">", .spaced),
        ("less than", "<", .spaced), ("pipe", "|", .spaced), ("ampersand", "&", .spaced), ("asterisk", "*", .spaced),
        ("backslash", "\\", .join), ("slash", "/", .join), ("dot", ".", .join), ("underscore", "_", .join), ("double colon", "::", .join),
        ("dash", "-", .prefix), ("at sign", "@", .prefix), ("hash", "#", .prefix), ("dollar sign", "$", .prefix),
        ("tilde", "~", .prefix), ("bang", "!", .prefix), ("caret", "^", .join), ("percent sign", "%", .join),
        ("backtick", "`", .quote), ("single quote", "'", .quote), ("double quote", "\"", .quote)]

    public static func apply(_ text: String) -> String {
        var tokens = tokenize(text)
        tokens = applyCasing(tokens)
        return joinSymbols(tokens)
    }

    /// Words and punctuation, keeping punctuation as separate tokens.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for c in text {
            if c.isWhitespace { if !current.isEmpty { tokens.append(current); current = "" } }
            else if ",.;:!?".contains(c) { if !current.isEmpty { tokens.append(current); current = "" }; tokens.append(String(c)) }
            else { current.append(c) }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func matches(_ tokens: [String], at index: Int, phrase: String) -> Bool {
        let words = phrase.split(separator: " ")
        guard index + words.count <= tokens.count else { return false }
        return zip(tokens[index..<index + words.count], words).allSatisfy { $0.lowercased() == $1 }
    }

    /// "camel case user name" → "userName": the casing applies to the words up to punctuation,
    /// another command or a spoken symbol.
    static func applyCasing(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            guard let (phrase, casing) = casingPhrases.sorted(by: { $0.0.count > $1.0.count }).first(where: { matches(tokens, at: i, phrase: $0.0) }) else {
                out.append(tokens[i]); i += 1; continue
            }
            i += phrase.split(separator: " ").count
            var words: [String] = []
            while i < tokens.count, tokens[i].first?.isLetter == true || tokens[i].first?.isNumber == true,
                  !casingPhrases.contains(where: { matches(tokens, at: i, phrase: $0.0) }),
                  !symbols.contains(where: { matches(tokens, at: i, phrase: $0.phrase) }) {
                words.append(tokens[i].lowercased()); i += 1
            }
            guard !words.isEmpty else { continue }
            out.append(format(words, casing))
            // A recognizer period after the identifier is not part of the code.
            if i < tokens.count, tokens[i] == "." { i += 1 }
        }
        return out
    }

    static func format(_ words: [String], _ casing: Casing) -> String {
        let capitalized = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        switch casing {
        case .camel: return words[0] + capitalized.dropFirst().joined()
        case .pascal: return capitalized.joined()
        case .snake: return words.joined(separator: "_")
        case .kebab: return words.joined(separator: "-")
        case .constant: return words.map { $0.uppercased() }.joined(separator: "_")
        case .upper: return words.map { $0.uppercased() }.joined(separator: " ")
        case .lower: return words.joined(separator: " ")
        }
    }

    /// Replaces spoken symbols and fits them to their neighbours.
    static func joinSymbols(_ tokens: [String]) -> String {
        var out = ""
        var glueNext = false
        var openQuotes: [String: Bool] = [:]
        var i = 0
        let ordered = symbols.sorted { $0.phrase.count > $1.phrase.count }
        func space() { if !out.isEmpty, !out.hasSuffix(" "), !glueNext { out += " " } }
        func trimSpace() { while out.hasSuffix(" ") { out.removeLast() } }
        while i < tokens.count {
            if let symbol = ordered.first(where: { matches(tokens, at: i, phrase: $0.phrase) }) {
                i += symbol.phrase.split(separator: " ").count
                // A recognizer comma or period right after a spoken symbol is not code.
                if i < tokens.count, [",", "."].contains(tokens[i]), symbol.fit != .close { i += 1 }
                switch symbol.fit {
                case .join: trimSpace(); out += symbol.symbol; glueNext = true
                case .prefix: space(); out += symbol.symbol; glueNext = true
                case .open:
                    if symbol.symbol == "(" || symbol.symbol == "[" { trimSpace() } else { space() }
                    out += symbol.symbol; glueNext = true
                case .close: trimSpace(); out += symbol.symbol; glueNext = false
                case .spaced: trimSpace(); if !out.isEmpty { out += " " }; out += symbol.symbol + " "; glueNext = true
                case .quote:
                    if openQuotes[symbol.symbol] == true { trimSpace(); out += symbol.symbol; openQuotes[symbol.symbol] = false; glueNext = false }
                    else { space(); out += symbol.symbol; openQuotes[symbol.symbol] = true; glueNext = true }
                }
                continue
            }
            let token = tokens[i]
            if ",.;:!?".contains(token) { out += token; glueNext = false; i += 1; continue }
            space(); out += token; glueNext = false; i += 1
        }
        trimSpace()
        return out
    }
}
