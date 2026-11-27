import Foundation
import NaturalLanguage

/// Text to phonemes for Mouthy's own voice: a Swift port of misaki's English G2P (Apache-2.0, github.com/hexgrad/misaki,
/// `en.py`), the one the voice was trained with. Same dictionaries (US gold and silver, `Resources/Voice/lexicon.tsv`),
/// same stress, suffix (-s, -ed, -ing), number and function-word rules. Differences: Apple's NaturalLanguage tagger stands
/// in for spaCy's part-of-speech tags, a small clean-up spells out what misaki leaves unknown (clock times, degrees,
/// file extensions), and an unknown word is spelled letter by letter instead of dropped.
public final class VoicePhonemes: @unchecked Sendable {
    /// One dictionary entry: a plain pronunciation, or one per part of speech (`DEFAULT` always present; a nil value
    /// means "no pronunciation for this tag").
    enum Entry { case plain(String), tagged([String: String?]) }
    let golds: [String: Entry]
    let silvers: [String: Entry]

    /// Loads `lexicon.tsv` (`word<TAB>g|s<TAB>phonemes`, or `TAG=phonemes|...`).
    public init(lexicon url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var golds = [String: Entry](minimumCapacity: 100_000), silvers = [String: Entry](minimumCapacity: 100_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let value = String(parts[2])
            let entry: Entry
            if value.contains("=") {
                var tagged = [String: String?]()
                for pair in value.split(separator: "|") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard kv.count == 2 else { continue }
                    tagged[String(kv[0])] = kv[1].isEmpty ? .some(nil) : String(kv[1])
                }
                entry = .tagged(tagged)
            } else { entry = .plain(value) }
            if parts[1] == "g" { golds[String(parts[0])] = entry } else { silvers[String(parts[0])] = entry }
        }
        self.golds = Self.grow(golds)
        self.silvers = Self.grow(silvers)
    }

    /// misaki's `grow_dictionary`: a lowercase word is also found capitalized, and a capitalized one in lowercase.
    static func grow(_ d: [String: Entry]) -> [String: Entry] {
        var e = [String: Entry]()
        for (k, v) in d where k.count >= 2 {
            if k == k.lowercased() {
                let c = capitalize(k)
                if k != c { e[c] = v }
            } else if k == capitalize(k.lowercased()) {
                e[k.lowercased()] = v
            }
        }
        return e.merging(d) { _, new in new }
    }

    // MARK: - Public

    /// Phonemes for `text` in the voice's symbol set (spaces between words, punctuation kept).
    public func phonemes(_ text: String) -> String {
        let cleaned = Self.clean(text)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let tokens = tokenize(cleaned)
        let words = retokenize(tokens)
        var ctx = Context()
        for w in words.reversed() {
            switch w {
            case .single(let tk):
                if tk.phonemes == nil { (tk.phonemes, tk.rating) = word(tk, ctx) }
                ctx = tokenContext(ctx, tk.phonemes, tk)
            case .group(let group):
                var left = 0, right = group.count
                while left < right {
                    let slice = Array(group[left..<right])
                    let tk: Tok? = slice.contains { $0.alias != nil || $0.phonemes != nil } ? nil : merge(slice)
                    let (ps, rating) = tk.map { word($0, ctx) } ?? (nil, nil)
                    if let ps, let tk {
                        group[left].phonemes = ps; group[left].rating = rating
                        for x in group[(left + 1)..<right] { x.phonemes = ""; x.rating = rating }
                        ctx = tokenContext(ctx, ps, tk)
                        right = left; left = 0
                    } else if left + 1 < right {
                        left += 1
                    } else {
                        right -= 1
                        let tk = group[right]
                        if tk.phonemes == nil, tk.text.allSatisfy({ Self.subtokenJunks.contains($0) }) { tk.phonemes = ""; tk.rating = 3 }
                        left = 0
                    }
                }
                resolve(group)
            }
        }
        var out = ""
        for w in words {
            let tk: Tok
            switch w { case .single(let t): tk = t; case .group(let g): tk = merge(g, unknown: "") }
            out += (tk.phonemes ?? spellUnknown(tk.text)) + tk.whitespace
        }
        return out.replacingOccurrences(of: "ɾ", with: "T").replacingOccurrences(of: "ʔ", with: "t")
            .trimmingCharacters(in: .whitespaces)
    }

    /// An unknown word: its letters, as `get_NNP` would say them; nothing for symbols.
    func spellUnknown(_ text: String) -> String {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty, let (ps, _) = nnp(letters) else { return "" }
        return ps
    }

    // MARK: - Clean-up before G2P (things misaki leaves unknown)

    static func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\n", with: " ")
        // 9:30 -> nine thirty, 9:05 -> nine oh five, 9:00 -> nine o'clock
        s = replace(s, #"\b(\d{1,2}):(\d{2})\b"#) { m in
            guard let h = Int(m[1]), let mm = Int(m[2]), h < 25, mm < 60 else { return m[0] }
            if mm == 0 { return "\(numberWords(h)) o'clock" }
            return "\(numberWords(h)) " + (mm < 10 ? "oh \(numberWords(mm))" : numberWords(mm))
        }
        s = replace(s, #"°\s?C\b"#) { _ in " degrees Celsius" }
        s = replace(s, #"°\s?F\b"#) { _ in " degrees Fahrenheit" }
        s = s.replacingOccurrences(of: "°", with: " degrees")
        // name.ext -> name dot E X T (short lowercase file extensions after a word)
        s = replace(s, #"(?<=[\p{L}\d])\.([a-z]{1,4})\b(?![\p{L}.])"#) { m in
            " dot " + m[1].uppercased().map(String.init).joined(separator: " ")
        }
        // Long runs with no space ("a/b/c/...", hashes) are split at separators and every 40 characters: the
        // subtoken search is cubic in a word's length, and nobody wants a 600-letter word read out anyway.
        s = replace(s, #"\S{41,}"#) { m in
            m[0].replacingOccurrences(of: #"[/_\\-]+"#, with: " ", options: .regularExpression)
                .split(separator: " ").map { piece -> String in
                    let chars = Array(piece)
                    return stride(from: 0, to: chars.count, by: 40).map { String(chars[$0..<min($0 + 40, chars.count)]) }.joined(separator: " ")
                }.joined(separator: " ")
        }
        return s
    }

    static func replace(_ s: String, _ pattern: String, _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let groups = (0..<m.numberOfRanges).map { i -> String in
                guard let r = Range(m.range(at: i), in: s) else { return "" }
                return String(s[r])
            }
            if let r = Range(m.range, in: out) { out.replaceSubrange(r, with: f(groups)) }
        }
        return out
    }

    // MARK: - Tokens

    final class Tok {
        var text: String
        var tag: String
        var whitespace: String
        var phonemes: String?
        var isHead = true
        var alias: String?
        var stress: Double?
        var currency: String?
        var numFlags = ""
        var prespace = false
        var rating: Int?
        init(text: String, tag: String, whitespace: String) { self.text = text; self.tag = tag; self.whitespace = whitespace }
        func copy(text: String, whitespace: String) -> Tok {
            let t = Tok(text: text, tag: tag, whitespace: whitespace); t.numFlags = numFlags; t.stress = stress; return t
        }
    }

    enum Word { case single(Tok), group([Tok]) }

    /// misaki's TokenContext: whether the next word starts with a vowel (nil at the end or before punctuation).
    struct Context { var futureVowel: Bool? = nil; var futureTo = false }

    /// Abbreviations spaCy keeps whole and the dictionary knows with their dot (not "No.", which ends sentences).
    static let titles: Set<String> = ["Mr.", "Mrs.", "Ms.", "Dr.", "St.", "Jr.", "Sr.", "Prof.", "Gen.", "Col.", "Capt.", "Lt.", "Sgt.", "Rev.", "Gov.", "Sen.", "Rep.", "Mt.", "vs.", "etc."]
    static let leading: Set<Character> = ["\"", "“", "‘", "(", "[", "{", "$", "£", "€", "#", "«", "¿", "¡"]
    static let trailing: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "\"", "”", "’", "…", "»", "%"]

    /// spaCy-like tokens: whitespace chunks with leading and trailing punctuation split off, each tagged with a Penn
    /// Treebank tag derived from Apple's lexical classes.
    func tokenize(_ text: String) -> [Tok] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        var tokens: [Tok] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex else { break }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            var k = j
            while k < text.endIndex, text[k].isWhitespace { k = text.index(after: k) }
            let space = text[j..<k].isEmpty ? "" : " "
            var start = i, end = j
            var pre: [Range<String.Index>] = [], post: [Range<String.Index>] = []
            while start < end, Self.leading.contains(text[start]) {
                let n = text.index(after: start); pre.append(start..<n); start = n
            }
            while start < end {
                let p = text.index(before: end)
                let c = text[p]
                guard Self.trailing.contains(c) else { break }
                if c == ".", Self.titles.contains(String(text[start..<end])) { break }   // "Mr." keeps its dot (one word)
                // keep "U.S." and "e.g." whole; keep "%" on a number for misaki's own handling
                if c == ".", text[start..<p].contains("."), text[start..<p].allSatisfy({ $0.isLetter || $0 == "." }) { break }
                if c == "%", p > start, text[text.index(before: p)].isNumber { break }
                post.insert(p..<end, at: 0); end = p
            }
            // "..." is one token
            var mergedPost: [Range<String.Index>] = []
            for r in post {
                if let last = mergedPost.last, text[last].allSatisfy({ $0 == "." }), text[r] == "." { mergedPost[mergedPost.count - 1] = last.lowerBound..<r.upperBound }
                else { mergedPost.append(r) }
            }
            let pieces = pre + (start < end ? [start..<end] : []) + mergedPost
            for (n, r) in pieces.enumerated() {
                let t = String(text[r])
                tokens.append(Tok(text: t, tag: tag(t, at: r.lowerBound, tagger: tagger, sentenceStart: tokens.last.map { [".", "!", "?"].contains($0.text) } ?? true),
                                  whitespace: n == pieces.count - 1 ? space : ""))
            }
            i = k
        }
        return tokens
    }

    func tag(_ t: String, at index: String.Index, tagger: NLTagger, sentenceStart: Bool) -> String {
        if t == "$" || t == "£" || t == "€" { return "$" }
        if t == "#" { return "#" }
        if t.allSatisfy({ $0 == "." || $0 == "!" || $0 == "?" }) { return "." }
        if t == "," { return "," }
        if t == ":" || t == ";" || t == "-" || t == "–" || t == "—" || t == "…" { return ":" }
        if t == "(" || t == "[" || t == "{" { return "-LRB-" }
        if t == ")" || t == "]" || t == "}" { return "-RRB-" }
        if t == "\"" || t == "“" || t == "‘" { return "``" }
        if t == "”" || t == "’" { return "''" }
        if t.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return "NFP" }
        let lower = t.lowercased()
        if lower == "to" { return "TO" }
        if t.first?.isNumber == true || (t.first == "-" && t.dropFirst().first?.isNumber == true) { return "CD" }
        let (cls, _) = tagger.tag(at: index, unit: .word, scheme: .lexicalClass)
        let (name, _) = tagger.tag(at: index, unit: .word, scheme: .nameType)
        let letters = t.filter(\.isLetter)
        if letters.count >= 2, letters == letters.uppercased(), golds[t] == nil { return "NNP" }
        if [NLTag.personalName, .placeName, .organizationName].contains(name) { return "NNP" }
        switch cls {
        case .noun: return (!sentenceStart && t.first?.isUppercase == true) ? "NNP" : "NN"
        case .verb:
            if ["was", "were", "had", "did", "said", "made", "went", "got", "took", "came", "used"].contains(lower) { return "VBD" }
            return "VB"
        case .adjective: return "JJ"
        case .adverb: return "RB"
        case .pronoun: return lower == "i" || ["you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them"].contains(lower) ? "PRP" : "PRP$"
        case .determiner: return "DT"
        case .preposition: return "IN"
        case .particle: return "RP"
        case .number: return "CD"
        case .conjunction: return "CC"
        case .interjection: return "UH"
        default: return "NN"
        }
    }

    static let subtoken = try! NSRegularExpression(pattern:
        #"^['‘’]+|\p{Lu}(?=\p{Lu}\p{Ll})|(?:^-)?(?:\d?[,.]?\d)+|[-_]+|['‘’]{2,}|\p{L}*?(?:['‘’]\p{L})*?\p{Ll}(?=\p{Lu})|\p{L}+(?:['‘’]\p{L})*|[^-_\p{L}'‘’\d]|['‘’]+$"#)
    static func subtokenize(_ word: String) -> [String] {
        subtoken.matches(in: word, range: NSRange(word.startIndex..., in: word)).compactMap { Range($0.range, in: word).map { String(word[$0]) } }
    }

    static let subtokenJunks: Set<Character> = ["'", ",", "-", ".", "_", "‘", "’", "/"]
    static let puncts: Set<Character> = [";", ":", ",", ".", "!", "?", "—", "…", "\"", "“", "”"]
    static let nonQuotePuncts: Set<Character> = [";", ":", ",", ".", "!", "?", "—", "…"]
    static let punctTags: Set<String> = [".", ",", "-LRB-", "-RRB-", "``", "\"\"", "''", ":", "$", "#", "NFP"]
    static let punctTagPhonemes = ["-LRB-": "(", "-RRB-": ")", "``": "\u{201C}", "\"\"": "\u{201D}", "''": "\u{201D}"]
    static let currencies: [String: (String, String)] = ["$": ("dollar", "cent"), "£": ("pound", "pence"), "€": ("euro", "cent")]

    /// misaki's `retokenize`: subtokens, punctuation, currency, and runs of subtokens with no space grouped together.
    func retokenize(_ tokens: [Tok]) -> [Word] {
        var words: [Word] = []
        var currency: String?
        for (i, token) in tokens.enumerated() {
            let tks: [Tok] = (token.alias == nil && token.phonemes == nil)
                ? Self.subtokenize(token.text).map { token.copy(text: $0, whitespace: "") }
                : [token]
            guard !tks.isEmpty else { continue }
            tks[tks.count - 1].whitespace = token.whitespace
            for (j, tk) in tks.enumerated() {
                if tk.alias != nil || tk.phonemes != nil {
                } else if tk.tag == "$", Self.currencies[tk.text] != nil {
                    currency = tk.text; tk.phonemes = ""; tk.rating = 4
                } else if tk.tag == ":", tk.text == "-" || tk.text == "–" {
                    tk.phonemes = "—"; tk.rating = 3
                } else if Self.punctTags.contains(tk.tag), !tk.text.lowercased().allSatisfy({ ("a"..."z").contains($0) }) {
                    tk.phonemes = Self.punctTagPhonemes[tk.tag] ?? String(tk.text.filter { Self.puncts.contains($0) }); tk.rating = 4
                } else if let c = currency {
                    if tk.tag != "CD" { currency = nil }
                    else if j + 1 == tks.count, i + 1 == tokens.count || tokens[i + 1].tag != "CD" { tk.currency = c }
                } else if j > 0, j < tks.count - 1, tk.text == "2",
                          let a = tks[j - 1].text.last, let b = tks[j + 1].text.first, a.isLetter, b.isLetter {
                    tk.alias = "to"
                }
                if tk.alias != nil || tk.phonemes != nil {
                    words.append(.single(tk))
                } else if case .group(var g)? = words.last, g.last?.whitespace.isEmpty == true {
                    tk.isHead = false; g.append(tk); words[words.count - 1] = .group(g)
                } else {
                    words.append(tk.whitespace.isEmpty ? .group([tk]) : .single(tk))
                }
            }
        }
        return words.map { if case .group(let g) = $0, g.count == 1 { return .single(g[0]) }; return $0 }
    }

    func merge(_ tokens: [Tok], unknown: String? = nil) -> Tok {
        let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + tokens[tokens.count - 1].text
        let tagSource = tokens.max { a, b in
            a.text.reduce(0) { $0 + ($1.isLowercase || !$1.isLetter ? 1 : 2) } < b.text.reduce(0) { $0 + ($1.isLowercase || !$1.isLetter ? 1 : 2) }
        } ?? tokens[0]
        let t = Tok(text: text, tag: tagSource.tag, whitespace: tokens[tokens.count - 1].whitespace)
        if let unknown {
            var ps = ""
            for tk in tokens {
                if tk.prespace, let last = ps.last, !last.isWhitespace, tk.phonemes?.isEmpty == false { ps += " " }
                ps += tk.phonemes ?? (unknown.isEmpty ? spellUnknown(tk.text) : unknown)
            }
            t.phonemes = ps
        }
        let stresses = Set(tokens.compactMap(\.stress))
        t.stress = stresses.count == 1 ? stresses.first : nil
        t.currency = tokens.compactMap(\.currency).max()
        t.numFlags = String(Set(tokens.flatMap { Array($0.numFlags) }).sorted())
        t.isHead = tokens[0].isHead
        t.prespace = tokens[0].prespace
        return t
    }

    static let vowels: Set<Character> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
    static let consonants: Set<Character> = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")

    func tokenContext(_ ctx: Context, _ ps: String?, _ token: Tok) -> Context {
        var vowel = ctx.futureVowel
        if let ps {
            for c in ps where Self.vowels.contains(c) || Self.consonants.contains(c) || Self.nonQuotePuncts.contains(c) {
                vowel = Self.nonQuotePuncts.contains(c) ? nil : Self.vowels.contains(c)
                break
            }
        }
        let futureTo = token.text == "to" || token.text == "To" || (token.text == "TO" && (token.tag == "TO" || token.tag == "IN"))
        return Context(futureVowel: vowel, futureTo: futureTo)
    }

    func resolve(_ tokens: [Tok]) {
        let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + tokens[tokens.count - 1].text
        let kinds = Set(text.filter { !Self.subtokenJunks.contains($0) }.map { c -> Int in c.isLetter ? 0 : (c.isASCII && c.isNumber ? 1 : 2) })
        let prespace = text.contains(" ") || text.contains("/") || kinds.count > 1
        for (i, tk) in tokens.enumerated() {
            if tk.phonemes == nil {
                if i == tokens.count - 1, tk.text.count == 1, Self.nonQuotePuncts.contains(tk.text.first!) { tk.phonemes = tk.text; tk.rating = 3 }
                else if tk.text.allSatisfy({ Self.subtokenJunks.contains($0) }) { tk.phonemes = ""; tk.rating = 3 }
            } else if i > 0 { tk.prespace = prespace }
        }
        if prespace { return }
        var indices = tokens.enumerated().compactMap { i, tk -> (Bool, Int, Int)? in
            guard let ps = tk.phonemes, !ps.isEmpty else { return nil }
            return (ps.contains(Self.primary), Self.stressWeight(ps), i)
        }
        if indices.count == 2, tokens[indices[0].2].text.count == 1 {
            let i = indices[1].2; tokens[i].phonemes = Self.applyStress(tokens[i].phonemes, -0.5); return
        }
        if indices.count < 2 || indices.filter(\.0).count <= (indices.count + 1) / 2 { return }
        indices.sort { ($0.0 ? 1 : 0, $0.1, $0.2) < ($1.0 ? 1 : 0, $1.1, $1.2) }
        for (_, _, i) in indices.prefix(indices.count / 2) { tokens[i].phonemes = Self.applyStress(tokens[i].phonemes, -0.5) }
    }

    static func stressWeight(_ ps: String) -> Int { ps.reduce(0) { $0 + ("AIOQWYʤʧ".contains($1) ? 2 : 1) } }

    // MARK: - Stress

    static let primary: Character = "ˈ", secondary: Character = "ˌ"

    static func applyStress(_ ps: String?, _ stress: Double?) -> String? {
        guard let ps else { return nil }
        guard let stress else { return ps }
        let hasPrimary = ps.contains(primary), hasAny = ps.contains(primary) || ps.contains(secondary)
        if stress < -1 { return ps.replacingOccurrences(of: "ˈ", with: "").replacingOccurrences(of: "ˌ", with: "") }
        if stress == -1 || ((stress == 0 || stress == -0.5) && hasPrimary) {
            return ps.replacingOccurrences(of: "ˌ", with: "").replacingOccurrences(of: "ˈ", with: "ˌ")
        }
        if [0, 0.5, 1].contains(stress), !hasAny {
            if !ps.contains(where: { vowels.contains($0) }) { return ps }
            return restress(String(secondary) + ps)
        }
        if stress >= 1, !hasPrimary, ps.contains(secondary) { return ps.replacingOccurrences(of: "ˌ", with: "ˈ") }
        if stress > 1, !hasAny {
            if !ps.contains(where: { vowels.contains($0) }) { return ps }
            return restress(String(primary) + ps)
        }
        return ps
    }

    /// Moves each stress mark to just before the next vowel.
    static func restress(_ ps: String) -> String {
        let chars = Array(ps)
        var keyed = chars.enumerated().map { (Double($0.offset), $0.element) }
        for (i, c) in chars.enumerated() where c == primary || c == secondary {
            if let j = chars[i...].firstIndex(where: { vowels.contains($0) }) { keyed[i] = (Double(j) - 0.5, c) }
        }
        return String(keyed.sorted { $0.0 < $1.0 }.map(\.1))
    }

    // MARK: - Lexicon

    static let symbols = ["%": "percent", "&": "and", "+": "plus", "@": "at"]
    static let addSymbols = [".": "dot", "/": "slash"]
    static let lexiconChars: Set<Character> = Set("'-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let ordinals: Set<String> = ["st", "nd", "rd", "th"]

    func goldString(_ w: String) -> String? { if case .plain(let s)? = golds[w] { return s }; return nil }

    func nnp(_ word: String) -> (String, Int)? {
        var ps = ""
        for c in word where c.isLetter {
            guard let p = goldString(String(c).uppercased()) else { return nil }
            ps += p
        }
        guard let stressed = Self.applyStress(ps, 0) else { return nil }
        guard let r = stressed.range(of: "ˌ", options: .backwards) else { return (stressed, 3) }
        return (stressed.replacingCharacters(in: r, with: "ˈ"), 3)
    }

    static func parentTag(_ tag: String?) -> String? {
        guard let tag else { return nil }
        if tag.hasPrefix("VB") { return "VERB" }
        if tag.hasPrefix("NN") { return "NOUN" }
        if tag.hasPrefix("ADV") || tag.hasPrefix("RB") { return "ADV" }
        if tag.hasPrefix("ADJ") || tag.hasPrefix("JJ") { return "ADJ" }
        return tag
    }

    func specialCase(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: Context) -> (String, Int)? {
        let tag = tag ?? ""
        if tag == "ADD", let s = Self.addSymbols[word] { return lookup(s, nil, -0.5, ctx) }
        if let s = Self.symbols[word] { return lookup(s, nil, nil, ctx) }
        let inner = word.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if inner.contains("."), word.replacingOccurrences(of: ".", with: "").allSatisfy(\.isLetter),
           (word.split(separator: ".").map(\.count).max() ?? 0) < 3 { return nnp(word) }
        if word == "a" || word == "A" { return (tag == "DT" ? "ɐ" : "ˈA", 4) }
        if ["am", "Am", "AM"].contains(word) {
            if tag.hasPrefix("NN") { return nnp(word) }
            if ctx.futureVowel == nil || word != "am" || (stress ?? 0) > 0 { return (goldString("am") ?? "ˈæm", 4) }
            return ("ɐm", 4)
        }
        if ["an", "An", "AN"].contains(word) {
            if word == "AN", tag.hasPrefix("NN") { return nnp(word) }
            return ("ɐn", 4)
        }
        if word == "I", tag == "PRP" { return ("ˌI", 4) }
        if ["by", "By", "BY"].contains(word), Self.parentTag(tag) == "ADV" { return ("bˈI", 4) }
        if word == "to" || word == "To" || (word == "TO" && (tag == "TO" || tag == "IN")) {
            switch ctx.futureVowel {
            case nil: return (goldString("to") ?? "tu", 4)
            case true?: return ("tʊ", 4)
            default: return ("tə", 4)
            }
        }
        if word == "in" || word == "In" || (word == "IN" && tag != "NNP") {
            return ((ctx.futureVowel == nil || tag != "IN" ? "ˈ" : "") + "ɪn", 4)
        }
        if word == "the" || word == "The" || (word == "THE" && tag == "DT") {
            return (ctx.futureVowel == true ? "ði" : "ðə", 4)
        }
        if tag == "IN", word.range(of: #"^(?i)vs\.?$"#, options: .regularExpression) != nil { return lookup("versus", nil, nil, ctx) }
        if ["used", "Used", "USED"].contains(word), case .tagged(let t)? = golds["used"] {
            if (tag == "VBD" || tag == "JJ") && ctx.futureTo, let p = t["VBD"] ?? nil { return (p, 4) }
            if let p = t["DEFAULT"] ?? nil { return (p, 4) }
        }
        return nil
    }

    func isKnown(_ word: String, _ tag: String?) -> Bool {
        if golds[word] != nil || Self.symbols[word] != nil || silvers[word] != nil { return true }
        if !word.allSatisfy(\.isLetter) || !word.allSatisfy({ Self.lexiconChars.contains($0) }) { return false }
        if word.count == 1 { return true }
        if word == word.uppercased(), golds[word.lowercased()] != nil { return true }
        let rest = String(word.dropFirst())
        return rest == rest.uppercased()
    }

    func lookup(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: Context?) -> (String, Int)? {
        var word = word, tag = tag
        var isNNP = false
        if word == word.uppercased(), golds[word] == nil { word = word.lowercased(); isNNP = tag == "NNP" }
        var entry = golds[word], rating = 4
        if entry == nil, !isNNP { entry = silvers[word]; rating = 3 }
        var ps: String?
        switch entry {
        case .plain(let s)?: ps = s
        case .tagged(let t)?:
            if let ctx, ctx.futureVowel == nil, t["None"] != nil { tag = "None" }
            else if tag.map({ t[$0] == nil }) ?? true { tag = Self.parentTag(tag) }
            if let tag, let v = t[tag] { ps = v } else { ps = t["DEFAULT"] ?? nil }
        case nil: ps = nil
        }
        if ps == nil || (isNNP && !(ps!.contains(Self.primary))) {
            if let r = nnp(word) { return r }
        }
        guard let ps else { return nil }
        return (Self.applyStress(ps, stress) ?? ps, rating)
    }

    func sSuffix(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if "ptkfθ".contains(last) { return stem + "s" }
        if "szʃʒʧʤ".contains(last) { return stem + "ᵻz" }
        return stem + "z"
    }

    func stemS(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: Context?) -> (String, Int)? {
        guard word.count >= 3, word.hasSuffix("s") else { return nil }
        let stem: String
        if !word.hasSuffix("ss"), isKnown(String(word.dropLast()), tag) { stem = String(word.dropLast()) }
        else if (word.hasSuffix("'s") || (word.count > 4 && word.hasSuffix("es") && !word.hasSuffix("ies"))), isKnown(String(word.dropLast(2)), tag) { stem = String(word.dropLast(2)) }
        else if word.count > 4, word.hasSuffix("ies"), isKnown(String(word.dropLast(3)) + "y", tag) { stem = String(word.dropLast(3)) + "y" }
        else { return nil }
        guard let (ps, rating) = lookup(stem, tag, stress, ctx), let s = sSuffix(ps) else { return nil }
        return (s, rating)
    }

    static let usTaus: Set<Character> = Set("AIOWYiuæɑəɛɪɹʊʌ")

    func edSuffix(_ stem: String?) -> String? {
        guard let stem, let last = stem.last else { return nil }
        if "pkfθʃsʧ".contains(last) { return stem + "t" }
        if last == "d" { return stem + "ᵻd" }
        if last != "t" { return stem + "d" }
        if stem.count < 2 { return stem + "ɪd" }
        if Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) { return String(stem.dropLast()) + "ɾᵻd" }
        return stem + "ᵻd"
    }

    func stemEd(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: Context?) -> (String, Int)? {
        guard word.count >= 4, word.hasSuffix("d") else { return nil }
        let stem: String
        if !word.hasSuffix("dd"), isKnown(String(word.dropLast()), tag) { stem = String(word.dropLast()) }
        else if word.count > 4, word.hasSuffix("ed"), !word.hasSuffix("eed"), isKnown(String(word.dropLast(2)), tag) { stem = String(word.dropLast(2)) }
        else { return nil }
        guard let (ps, rating) = lookup(stem, tag, stress, ctx), let s = edSuffix(ps) else { return nil }
        return (s, rating)
    }

    func ingSuffix(_ stem: String?) -> String? {
        guard let stem, !stem.isEmpty else { return nil }
        if stem.count > 1, stem.last == "t", Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) { return String(stem.dropLast()) + "ɾɪŋ" }
        return stem + "ɪŋ"
    }

    func stemIng(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: Context?) -> (String, Int)? {
        guard word.count >= 5, word.hasSuffix("ing") else { return nil }
        let base = String(word.dropLast(3))
        let stem: String
        if word.count > 5, isKnown(base, tag) { stem = base }
        else if isKnown(base + "e", tag) { stem = base + "e" }
        else if word.count > 5, word.range(of: #"([bcdgklmnprstvxz])\1ing$|cking$"#, options: .regularExpression) != nil, isKnown(String(word.dropLast(4)), tag) { stem = String(word.dropLast(4)) }
        else { return nil }
        guard let (ps, rating) = lookup(stem, tag, stress, ctx), let s = ingSuffix(ps) else { return nil }
        return (s, rating)
    }

    func getWord(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: Context) -> (String, Int)? {
        if let r = specialCase(word, tag, stress, ctx) { return r }
        var word = word
        let wl = word.lowercased()
        if word.count > 1, word.replacingOccurrences(of: "'", with: "").allSatisfy(\.isLetter), word != wl,
           tag != "NNP" || word.count > 7, golds[word] == nil, silvers[word] == nil,
           word == word.uppercased() || String(word.dropFirst()) == String(word.dropFirst()).lowercased(),
           golds[wl] != nil || silvers[wl] != nil || stemS(wl, tag, stress, ctx) != nil || stemEd(wl, tag, stress, ctx) != nil || stemIng(wl, tag, stress, ctx) != nil {
            word = wl
        }
        if isKnown(word, tag) { return lookup(word, tag, stress, ctx) }
        if word.hasSuffix("s'"), isKnown(String(word.dropLast(2)) + "'s", tag) { return lookup(String(word.dropLast(2)) + "'s", tag, stress, ctx) }
        if word.hasSuffix("'"), isKnown(String(word.dropLast()), tag) { return lookup(String(word.dropLast()), tag, stress, ctx) }
        if let r = stemS(word, tag, stress, ctx) { return r }
        if let r = stemEd(word, tag, stress, ctx) { return r }
        if let r = stemIng(word, tag, stress ?? 0.5, ctx) { return r }
        return nil
    }

    /// misaki's `Lexicon.__call__`.
    func word(_ tk: Tok, _ ctx: Context) -> (String?, Int?) {
        var w = (tk.alias ?? tk.text).replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
        w = w.precomposedStringWithCompatibilityMapping
        let stress: Double? = w == w.lowercased() ? nil : (w == w.uppercased() ? 2 : 0.5)
        if let (ps, rating) = getWord(w, tk.tag, stress, ctx) {
            return (Self.applyStress(appendCurrency(ps, tk.currency), tk.stress), rating)
        }
        if Self.isNumber(w, tk.isHead), let (ps, rating) = number(w, tk.currency, tk.isHead, tk.numFlags) {
            return (Self.applyStress(ps, tk.stress), rating)
        }
        return (nil, nil)
    }

    func appendCurrency(_ ps: String, _ currency: String?) -> String {
        guard let currency, let unit = Self.currencies[currency], let s = stemS(unit.0 + "s", nil, nil, nil)?.0 else { return ps }
        return ps + " " + s
    }

    // MARK: - Numbers

    static func isDigits(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
    static func isDigits(_ s: String) -> Bool { isDigits(Substring(s)) }

    static func isNumber(_ word: String, _ isHead: Bool) -> Bool {
        guard word.contains(where: { $0.isASCII && $0.isNumber }) else { return false }
        var w = word
        for s in ["ing", "'d", "ed", "'s", "st", "nd", "rd", "th", "s"] where w.hasSuffix(s) { w = String(w.dropLast(s.count)); break }
        return w.enumerated().allSatisfy { i, c in (c.isASCII && c.isNumber) || c == "," || c == "." || (isHead && i == 0 && c == "-") }
    }

    func number(_ word: String, _ currency: String?, _ isHead: Bool, _ flags: String) -> (String, Int)? {
        var word = word
        var suffix: String?
        if let r = word.range(of: #"[a-z']+$"#, options: .regularExpression) { suffix = String(word[r]); word.removeSubrange(r) }
        var result: [(String, Int)] = []
        if word.hasPrefix("-") { if let m = lookup("minus", nil, nil, nil) { result.append(m) }; word.removeFirst() }
        func extend(_ num: String, first: Bool = true, escape: Bool = false) {
            let text = escape ? num : (Int(num).map(Self.numberWords) ?? num)
            let splits = text.split(whereSeparator: { !("a"..."z").contains($0) }).map(String.init)
            for (i, w) in splits.enumerated() {
                if w != "and" || flags.contains("&") {
                    if first, i == 0, splits.count > 1, w == "one", flags.contains("a") { result.append(("ə", 4)) }
                    else if let p = lookup(w, nil, w == "point" ? -2 : nil, nil) { result.append(p) }
                } else if w == "and", flags.contains("n"), let last = result.last {
                    result[result.count - 1] = (last.0 + "ən", last.1)
                }
            }
        }
        if word.filter(\.isNumber).count > 15 {   // past what Int holds safely: read the digits one by one
            for c in word where c.isNumber { extend(String(c), first: false) }
        } else if Self.isDigits(word), let s = suffix, Self.ordinals.contains(s), let n = Int(word) {
            extend(Self.ordinalWords(n), escape: true)
        } else if result.isEmpty, word.count == 4, currency == nil || Self.currencies[currency!] == nil, Self.isDigits(word), let n = Int(word) {
            extend(Self.yearWords(n), escape: true)
        } else if !isHead, !word.contains(".") {
            let num = word.replacingOccurrences(of: ",", with: "")
            if num.first == "0" || num.count > 3 { for c in num { extend(String(c), first: false) } }
            else if num.count == 3, !num.hasSuffix("00") {
                let d = Array(num)
                extend(String(d[0]))
                if d[1] == "0" { if let o = lookup("O", nil, -2, nil) { result.append(o) }; extend(String(d[2]), first: false) }
                else { extend(String(d[1...]), first: false) }
            } else { extend(num) }
        } else if word.filter({ $0 == "." }).count > 1 || !isHead {
            var first = true
            for num in word.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false) {
                if num.isEmpty {
                } else if num.first == "0" || (num.count != 2 && num.dropFirst().contains(where: { $0 != "0" })) {
                    for c in num { extend(String(c), first: false) }
                } else { extend(String(num), first: first) }
                first = false
            }
        } else if let c = currency, let units = Self.currencies[c], Self.isCurrency(word) {
            var pairs = zip(word.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 },
                            [units.0, units.1]).map { ($0, $1) }
            if pairs.count > 1 { if pairs[1].0 == 0 { pairs = Array(pairs.prefix(1)) } else if pairs[0].0 == 0 { pairs = Array(pairs.dropFirst()) } }
            for (i, (n, unit)) in pairs.enumerated() {
                if i > 0, let a = lookup("and", nil, nil, nil) { result.append(a) }
                extend(String(n), first: i == 0)
                if abs(n) != 1 && unit != "pence" { if let s = stemS(unit + "s", nil, nil, nil) { result.append(s) } }
                else if let s = lookup(unit, nil, nil, nil) { result.append(s) }
            }
        } else {
            var text: String
            if Self.isDigits(word), let n = Int(word) { text = Self.numberWords(n) }
            else if !word.contains("."), let n = Int(word.replacingOccurrences(of: ",", with: "")) {
                text = suffix.map { Self.ordinals.contains($0) } == true ? Self.ordinalWords(n) : Self.numberWords(n)
            } else {
                let w = word.replacingOccurrences(of: ",", with: "")
                if w.first == "." { text = "point " + w.dropFirst().map { Self.numberWords(Int(String($0)) ?? 0) }.joined(separator: " ") }
                else {
                    let parts = w.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                    text = Self.numberWords(Int(parts[0]) ?? 0)
                    if parts.count > 1 { text += " point " + parts[1].map { Self.numberWords(Int(String($0)) ?? 0) }.joined(separator: " ") }
                }
            }
            extend(text, escape: true)
        }
        guard !result.isEmpty else { return nil }
        let ps = result.map(\.0).joined(separator: " "), rating = result.map(\.1).min() ?? 3
        switch suffix {
        case "s", "'s": return sSuffix(ps).map { ($0, rating) }
        case "ed", "'d": return edSuffix(ps).map { ($0, rating) }
        case "ing": return ingSuffix(ps).map { ($0, rating) }
        default: return (ps, rating)
        }
    }

    static func isCurrency(_ word: String) -> Bool {
        guard word.contains(".") else { return true }
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 { return false }
        return parts[1].count < 3 || Set(parts[1]) == ["0"]
    }

    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                       "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// Cardinal words like num2words: "one thousand, five hundred and seventy-two" (the "and" and commas are dropped
    /// by the caller, as misaki does).
    static func numberWords(_ n: Int) -> String {
        if n < 0 { return "minus " + numberWords(-n) }
        if n < 20 { return ones[n] }
        if n < 100 { return tens[n / 10] + (n % 10 == 0 ? "" : "-" + ones[n % 10]) }
        if n < 1000 { return ones[n / 100] + " hundred" + (n % 100 == 0 ? "" : " and " + numberWords(n % 100)) }
        for (value, name) in [(1_000_000_000_000, "trillion"), (1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")] where n >= value {
            let rest = n % value
            return numberWords(n / value) + " " + name + (rest == 0 ? "" : (rest < 100 ? " and " : ", ") + numberWords(rest))
        }
        return String(n)
    }

    static func ordinalWords(_ n: Int) -> String {
        let cardinal = numberWords(n)
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]
        var parts = cardinal.components(separatedBy: CharacterSet(charactersIn: " -"))
        guard let last = parts.popLast() else { return cardinal }
        let ord = irregular[last] ?? (last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th")
        let sepIndex = cardinal.index(cardinal.endIndex, offsetBy: -last.count)
        return String(cardinal[..<sepIndex]) + ord
    }

    /// Years like num2words(to="year"): 2026 "twenty twenty-six", 1905 "nineteen oh-five", 2009 "two thousand and nine",
    /// 1900 "nineteen hundred".
    static func yearWords(_ n: Int) -> String {
        let high = n / 100, low = n % 100
        if n % 1000 < 10, n >= 2000, n < 2010 || n % 1000 == 0 { return numberWords(n) }
        if low == 0 { return numberWords(high) + " hundred" }
        if low < 10 { return numberWords(high) + " oh-" + ones[low] }
        return numberWords(high) + " " + numberWords(low)
    }

    static func capitalize(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst().lowercased() }
}
