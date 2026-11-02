import Foundation

/// Checks an on-device polish or rewrite before a host app uses it (`DictationPolish`). The model also sees reference
/// context (a terminal screen, a chat) that may carry text written to steer it; these checks turn an answer that is
/// not an edit of the person's words back into the person's words.
public enum PolishGuard {
    /// Polish: within half to twice the length (plus 20 characters), nothing lost (every name and number of the input,
    /// at least `minimumOverlap` of its content words) and nothing added (no new name, number, URL, path, flag or
    /// command word, and at most `polishNewContent` of the result's content words new).
    public static func acceptsPolish(_ result: String, of input: String) -> Bool {
        let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count >= input.count / 2, result.count <= input.count * 2 + 20 else { return false }
        return keepsFacts(result, of: input) && contentOverlap(result, of: input) >= minimumOverlap
            && newRiskyTokens(result, allowed: input, names: true).isEmpty && newContentShare(result, vocabulary: input) <= polishNewContent
    }

    /// Rewrite: a fifth to three times the selection (plus 20 characters for short ones), never over `maximum`; no URL,
    /// path, flag, command word or number that is not in the selection or the instruction; and since a rewrite
    /// rephrases, at most `rewriteNewContent` of the result's content words new.
    public static func acceptsRewrite(_ result: String, of selection: String, instruction: String = "", maximum: Int = 8_000) -> Bool {
        let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count >= selection.count / 5, result.count <= min(maximum, selection.count * 3 + 20) else { return false }
        let allowed = selection + "\n" + instruction
        return newRiskyTokens(result, allowed: allowed, names: false).isEmpty && newContentShare(result, vocabulary: allowed) <= rewriteNewContent
    }

    public static let minimumOverlap = 0.5
    /// Cleanup adds punctuation and a few function words; "Also push to main." on a one-line brief is 22% new.
    public static let polishNewContent = 0.2
    public static let rewriteNewContent = 0.6

    /// Names, numbers, file names and other exact terms of `input`: tokens with a digit, a capital letter (other than "I"
    /// or a sentence's first word that is a common word: "Book", "Please"; "Dana" counts), or a dot, slash or underscore
    /// between letters ("Package.swift", "src/main.rs").
    public static func facts(_ input: String) -> [String] {
        var facts: [String] = []
        var sentenceStart = true
        for raw in input.split(whereSeparator: { $0.isWhitespace }) {
            let token = normalized(String(raw))
            defer { sentenceStart = raw.last.map { ".!?\n:".contains($0) } ?? false }
            guard !token.isEmpty else { continue }
            let hasDigit = token.contains(where: \.isNumber)
            let capital = token.dropFirst().contains(where: \.isUppercase)
                || (token.first?.isUppercase == true && (!sentenceStart || !commonWords.contains(token.lowercased())))
            let path = token.dropFirst().dropLast().contains(where: { ".:/_".contains($0) })
            guard hasDigit || capital || path, !["I", "I'm", "I'll", "I've", "I'd"].contains(token) else { continue }
            facts.append(token.lowercased())
        }
        return facts
    }

    /// Every fact of `input` appears in `result` (a number may come back as its word, "4" as "four").
    public static func keepsFacts(_ result: String, of input: String) -> Bool {
        let tokens = Set(Self.tokens(result).map { $0.lowercased() })
        let lower = result.lowercased()
        return facts(input).allSatisfy { fact in
            if tokens.contains(fact) || (fact.count >= 4 && lower.contains(fact)) { return true }
            guard let number = Int(fact), numberWords.indices.contains(number) else { return false }
            return tokens.contains(numberWords[number])
        }
    }

    /// The share of `input`'s content words (four letters or more, not filler) that `result` keeps; 1 when there are none.
    public static func contentOverlap(_ result: String, of input: String) -> Double {
        let kept = Set(words(result))
        let content = Set(words(input).filter { $0.count >= 4 && !filler.contains($0) })
        guard !content.isEmpty else { return 1 }
        return Double(content.filter(kept.contains).count) / Double(content.count)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Surrounding punctuation, currency signs and a possessive "'s" removed.
    static func normalized(_ token: String) -> String {
        var token = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’<>*$€£#@"))
        for ending in ["'s", "’s"] where token.hasSuffix(ending) { token.removeLast(2) }
        return token
    }

    static let numberWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                              "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
    static let filler: Set<String> = ["basically", "actually", "really", "just", "okay", "like", "know", "mean", "that", "this",
                                      "with", "then", "there", "they", "what", "when", "will", "would", "could", "should", "have",
                                      "from", "your", "about", "into", "also", "some", "been", "were", "well", "yeah", "gonna",
                                      "wanna", "kind", "sort", "thing", "stuff", "maybe", "please", "make", "sure", "need",
                                      "want", "think", "guess", "right", "something", "literally", "pretty", "very", "much"]

    /// Tokens of `result` that carry exact content the person did not say: a number (unless `allowed` has it or its
    /// word, "4" for "four"), a URL or domain, a path, a flag ("-rf", "--force"), shell syntax or a command word
    /// ("rm", "curl", "git"), and with `names` a capitalized word inside a sentence; each only when `allowed` lacks it.
    public static func newRiskyTokens(_ result: String, allowed: String, names: Bool) -> [String] {
        let known = Set(tokens(allowed).map { $0.lowercased() })
        let knownWords = Set(words(allowed))
        var risky: [String] = []
        var sentenceStart = true
        for raw in result.split(whereSeparator: { $0.isWhitespace || $0 == "\u{2014}" || $0 == "\u{2013}" }) {
            let token = normalized(String(raw)), lower = token.lowercased()
            defer { sentenceStart = raw.last.map { ".!?:\n".contains($0) } ?? false }
            guard !token.isEmpty, !known.contains(lower), !abbreviations.contains(lower) else { continue }
            if lower.contains(where: \.isNumber) {
                let digits = lower.trimmingCharacters(in: CharacterSet.letters)
                if known.contains(digits) { continue }   // "12th" for "12"
                if let number = Int(digits), numberWords.indices.contains(number), knownWords.contains(numberWords[number]) { continue }
                risky.append(token); continue
            }
            let command = commandWords.contains(lower)
            let flag = lower.count > 1 && lower.first == "-" && lower.dropFirst().first.map { $0.isLetter || $0 == "-" } == true
            let shell = ["`", "$(", "&&", "||", "|", ">", "<", ";", "="].contains(where: { lower.contains($0) })
            let path = lower.contains("/") || lower.contains("\\") || lower.hasPrefix("~") || lower.contains("://") || lower.hasPrefix("www.")
                || lower.dropFirst().dropLast().contains(".") || lower.contains("@")
            let name = names && !sentenceStart && token.first?.isUppercase == true && !knownWords.contains(lower)
                && !["I", "I'm", "I'll", "I've", "I'd", "AM", "PM"].contains(token)
            if command || flag || shell || path || name { risky.append(token) }
        }
        return risky
    }

    /// The share of `result`'s content words (stemmed) that `vocabulary` does not have; 0 when it has none.
    public static func newContentShare(_ result: String, vocabulary: String) -> Double {
        let known = Set(words(vocabulary).map(stem))
        let content = words(result).filter { $0.count >= 4 && !filler.contains($0) && !editingWords.contains($0) }.map(stem)
        guard !content.isEmpty else { return 0 }
        return Double(content.filter { !known.contains($0) }.count) / Double(content.count)
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "\u{2014}" || $0 == "\u{2013}" }).map { normalized(String($0)) }.filter { !$0.isEmpty }
    }

    /// "failing" and "fails" are one word; good enough to tell rephrasing from new topics.
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s", "ly"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// Words the on-device model brings in when it rephrases without adding anything ("Examine Package.swift and fix the
    /// issue", "similar to what happens"): not counted as new content.
    static let editingWords: Set<String> = ["similar", "similarly", "happen", "happens", "happening", "examine", "ensure",
                                            "issue", "issues", "problem", "problems", "correct", "verify", "confirm", "check",
                                            "review", "resolve", "regarding", "following", "additionally", "however",
                                            "therefore", "instead", "again", "once", "kindly", "provide", "currently",
                                            "specifically", "occurs", "occur", "appears", "seems", "case", "cases", "thanks",
                                            "thank", "hello", "could", "would", "should", "able", "help"]
    static let abbreviations: Set<String> = ["e.g", "i.e", "a.m", "p.m", "etc", "vs", "e.g.", "i.e.", "a.m.", "p.m."]
    static let commandWords: Set<String> = ["rm", "sudo", "curl", "wget", "chmod", "chown", "ssh", "scp", "rsync", "git", "npm",
                                            "npx", "pip", "pip3", "brew", "kill", "pkill", "killall", "eval", "exec", "bash",
                                            "sh", "zsh", "python", "python3", "node", "mv", "cp", "dd", "mkfs", "launchctl",
                                            "osascript", "security", "xattr", "spctl", "csrutil", "diskutil"]
    /// Common words that start a sentence without being names.
    static let commonWords: Set<String> = Set("""
    a an the this that these those it its i you he she we they me him her us them my your his our their what which who \
    whom whose when where why how all any both each every few more most other some such no nor not only own same so than \
    too very can could will would shall should may might must do does did done have has had be is am are was were been \
    being and but or if then else because as until while of at by for with about against between into through during \
    before after above below to from up down in out on off over under again further once here there also just now please \
    okay ok hey hi hello um uh so well yeah yes like actually basically anyway right sure thanks thank sorry oh wait let \
    lets let's make take give get go come look see check tell ask say send write read add remove delete rename move copy \
    set put keep use run build test fix change update bump create open close start stop show find try book call meet \
    email ship merge review push pull plan need want think know mean guess also then next first last finally new one two \
    three four five six seven eight nine ten maybe still even really instead otherwise besides however today tomorrow \
    tonight yesterday monday tuesday wednesday thursday friday saturday sunday hey listen note remember
    """.split(whereSeparator: { $0.isWhitespace || $0 == "\\" }).map(String.init))
}
