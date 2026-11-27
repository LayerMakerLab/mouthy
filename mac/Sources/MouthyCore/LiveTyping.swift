import Foundation

/// "Type as I speak": decides what to type into the focused field while the person is still talking.
///
/// Live recognition guesses again several times a second, and the newest words of a guess are often wrong for a
/// moment: its audio ends mid-word or mid-sentence, so the recognizer finishes the sentence itself ("I will still
/// need to" came back as "need to be able to do it"), and a word can still change once the next words are heard
/// ("said it" becomes "set it"). What a pass over everything said hears once the person has paused is what the
/// finished text will say, nearly always.
///
/// With a recognizer that says when it heard a pause (`settlesAtPauses`, Parakeet and Whisper): nothing is typed from
/// the guesses. A phrase is typed when the pass at its pause has it (`hear(pause:)`), and is then `settled`: it
/// stays as it is for good, also where a later pass or the stop hears one of its words differently. So nothing is
/// ever taken back, and the stop (`finish`) only adds what was said after the last pause. (Typing from the guesses
/// and correcting at the stop is what this did before. With a person's voice, not a synthetic one, about one typed
/// word in thirty was made up or misheard, and the stop took back everything behind the first of them: half of a
/// long dictation, every time. Correcting as the guesses changed, before that, had words changing all through a
/// dictation.)
///
/// Without that (Apple's recognizer): a word is typed once three guesses in a row agree on it and `hold` newer words
/// follow it, or once no newer guess comes for a while (`settle`); a typed word stays while the person speaks, only
/// the newest word or two may be typed again (`newest`), a guess that hears an earlier typed word differently leaves
/// it and the words after it follow (`appending`), and the stop corrects the field once.
///
/// Guesses from the streaming recognizer are `firm`: typed whole, and corrected at every pause, which is that
/// setting's bargain. Pure: the caller posts the edits and says when the field is no longer this dictation's own
/// (`leave`). After that nothing more is typed unless the caller finds the cursor still right after the words
/// (`reclaim`); the stop delivers the rest (`remainder`).
public struct LiveTyping: Sendable {
    public enum Edit: Equatable, Sendable {
        /// Backspaces, one for each character.
        case delete(Int)
        case type(String)
    }

    /// What was typed before the cursor and is still this dictation's own.
    public private(set) var typed = ""
    /// How many characters of `typed`, from its start, are settled: a pass heard them at a pause and the field was
    /// written as it has them. They stay as they are for good, whatever a later guess or the stop says.
    private var settled = 0
    /// The words (plain) of the last pause's text, for the next pause to confirm.
    private var pauseBefore: [String] = []
    /// Words typed and then left where they are (the person typed, clicked or changed fields), lowercase and
    /// without punctuation. The stop delivers only what comes after them.
    public private(set) var left: [String] = []
    /// The newest guess, in words.
    private var heard: [String] = []
    /// How many words of the newest guess are in the field.
    private var shown = 0
    /// How many leading words the guess before the newest shared with the one before it.
    private var agreedBefore = 0
    /// The newest guess holds text that is never typed live (from a first line break, tab or character a key press
    /// cannot type): the field does not show everything that was said.
    public private(set) var heardMore = false
    /// The field's text around the cursor where typing began; nil when the app does not report it.
    private var before: String?
    private var after = ""
    /// Whether the newest guess came from the streaming recognizer ("Show words instantly").
    private var streamed = false
    /// The person's custom words, which keep their capitals mid-sentence.
    public var names: [String] = []
    /// The recognizer says when it heard a pause (`hear(pause:)`): words are typed only then, a phrase at a time,
    /// as the pass over everything said has them. Without it they are typed from the guesses (`hold`).
    public var settlesAtPauses = false
    /// The first stretch of changes in which two or more `settled` words (plain) in a row have nothing in their
    /// place in `text`, lined up word by word with the fewest changes (a word heard differently is a change in its
    /// place, not a word gone: "all right" for "alright" and "too there" for "to their" are no such stretch).
    /// `from`: where the stretch starts in `settled`; `to`: where it starts in `text`. Nil when there is none. Within `band` words of the diagonal,
    /// widened by the difference in length, so a long dictation's stop stays quick.
    static func removedRun(_ words: [String], from text: [String]) -> (from: Int, to: Int)? {
        guard words.count >= 2 else { return nil }
        // Two settled words the text writes as one ("all right", "alright"; "every day", "everyday") are that one
        // word, not one heard differently and one gone (review round 3).
        let joined = Set(text.flatMap(spellings))
        var settled: [String] = [], first: [Int] = [], k = 0
        while k < words.count {
            if k + 1 < words.count, spellings(words[k] + words[k + 1]).contains(where: joined.contains) { settled.append(words[k] + words[k + 1]); first.append(k); k += 2 }
            else { settled.append(words[k]); first.append(k); k += 1 }
        }
        guard settled.count >= 2 else { return nil }
        guard let (from, to) = removedStretch(settled, from: text) else { return nil }
        return (first[from], to)
    }

    /// How far from the end of the field removed words are taken out at the stop. "Scratch that" takes back what
    /// was just said; a stretch the recognizer made up further back stays, as a word heard differently does:
    /// correcting it retyped everything after it (844 characters in one recorded reading, review round 3).
    static let nearRemoved = 200

    /// A word as written, and with one letter of a doubled pair left out: "all right" and "alright" meet as
    /// "alright". Only one: with every doubled letter squeezed, "www www" met a lone "w" and a word was skipped.
    static func spellings(_ word: String) -> [String] {
        let letters = Array(word)
        return [word] + letters.indices.dropLast().filter { letters[$0] == letters[$0 + 1] }.map { i in
            var shorter = letters
            shorter.remove(at: i)
            return String(shorter)
        }
    }

    /// Whether two words joined and one word are the same spelling (`spellings`).
    static func sameJoined(_ two: String, _ one: String) -> Bool {
        two == one || spellings(two).contains(one) || spellings(one).contains(two)
    }

    private static func removedStretch(_ settled: [String], from text: [String]) -> (from: Int, to: Int)? {
        let n = settled.count, m = text.count, width = band + abs(n - m)
        let far = Int.max / 4
        // cost[i][j]: changes to turn settled[i...] into text[j...]; only |i - j| <= width is filled.
        var cost = [[Int]](repeating: [], count: n + 1)
        func at(_ i: Int, _ j: Int) -> Int {
            guard j >= 0, j <= m, abs(i - j) <= width else { return far }
            return cost[i][j - max(0, i - width)]
        }
        for i in stride(from: n, through: 0, by: -1) {
            let low = max(0, i - width), high = min(m, i + width)
            var row = [Int](repeating: far, count: high - low + 1)
            for j in stride(from: high, through: low, by: -1) {
                var best = far
                if i == n { best = m - j } else if j == m { best = n - i } else {
                    best = min(at(i + 1, j + 1) + (settled[i] == text[j] ? 0 : 1), at(i + 1, j) + 1)
                    // (a word of `text` with nothing in `settled` at j + 1 is read from this same row)
                    if j + 1 <= high { best = min(best, row[j + 1 - low] + 1) }
                }
                row[j - low] = best
            }
            cost[i] = row
        }
        // Walk the cheapest line-up. A stretch of changes (words heard differently, gone or new) starts where the
        // last same word ends; one with two settled words gone in a row is corrected from the stretch's start, so a
        // word heard in place of the removed ones ("milk" for "bread" in "Buy milk and eggs. Scratch that. Buy
        // bread.") is corrected with them.
        var i = 0, j = 0, run = 0, removed = false, stretch = (0, 0), changing = false
        while i < n || j < m {
            let here = at(i, j)
            if i < n, j < m, settled[i] == text[j], at(i + 1, j + 1) == here {
                if removed { return stretch }
                changing = false; run = 0; i += 1; j += 1
                continue
            }
            if !changing { changing = true; stretch = (i, j) }
            if i < n, j < m, at(i + 1, j + 1) + 1 == here { run = 0; i += 1; j += 1 }
            else if i < n, at(i + 1, j) + 1 == here { run += 1; if run >= 2 { removed = true }; i += 1 }
            else { run = 0; j += 1 }
        }
        return removed ? stretch : nil
    }

    /// How many words the first pause's text needs before it is typed.
    static let fewest = 3
    /// How many last words of a pause's text wait when the person talked on. Waiting for the next pause to hear
    /// every word again left the same words wrong in six recorded dictations and was 15 to 25% slower; two left a
    /// made-up "and" in the field twice.
    static let unsure = 3
    /// A pause the recognizer heard, and whether the person was still silent when its pass was done.
    public enum Pause: Sendable { case held, talkedOn }
    /// The words that were left behind, in case the cursor turns out to be right after them still.
    private var abandoned: (typed: String, before: String?, after: String)?

    public init(names: [String] = []) { self.names = names }

    /// Starts typing at the cursor. `before` and `after` are the field's text around it (nil: unknown, so the text is
    /// typed as it is, as a paste into such a field is).
    public mutating func attach(before: String?, after: String?) {
        typed = ""; settled = 0
        left = []; abandoned = nil
        self.before = before
        self.after = after ?? ""
    }

    /// A new guess at everything said so far. `typing` false only remembers it (nothing can be typed right now).
    /// `firm`: its newest words will not change by themselves (they come from the streaming recognizer, which never
    /// takes a word back), so all of it is typed at once.
    public mutating func hear(_ text: String, typing: Bool = true, firm: Bool = false, pause: Pause? = nil) -> [Edit] {
        let (line, rest) = Self.typable(text)
        heardMore = !rest.isEmpty
        let words = Self.words(line)
        let agreed = zip(heard, words).prefix { Self.plain($0.0) == Self.plain($0.1) }.count
        let before = agreedBefore
        agreedBefore = agreed
        heard = words
        // Once the streaming recognizer has written words here, this text is its text until the part ends (a guess
        // that is only remembered says nothing about where it came from).
        streamed = streamed || firm
        guard streamed else {
            guard typing else { return [] }
            // A recognizer that says when a pause was heard: the pass over everything said up to it is what was
            // said, and is settled. Its guesses in between are only remembered.
            if settlesAtPauses {
                guard let pause else { return [] }
                // The person talked on: the pass heard its last words with nothing after them, and it makes an
                // ending up now and then ("and we" came back as "and we can do."). Its last `unsure` words wait
                // for the next pause, unless the pause before heard them too.
                let confirmed = zip(pauseBefore, words).prefix { $0.0 == Self.plain($0.1) }.count
                let count = pause == .held ? words.count : max(confirmed, words.count - Self.unsure)
                pauseBefore = words.map(Self.plain)
                // Not a first word or two: the pass had hardly any sound to go by, and the next one often hears
                // them differently ("All right" became "Alright", "Hi." became "High, gaunt").
                guard count > 0, settled > 0 || count >= Self.fewest else { return [] }
                shown = count
                return settle(on: words[..<count].joined(separator: " "), beyond: words[count...].map(Self.plain), final: false)
            }
            // Three guesses in a row agree on a word, and `hold` newer words follow it.
            return show(upTo: min(agreed, before, words.count - Self.hold))
        }
        // The streaming recognizer's text: three guesses in a row agree on a word, or two on the next word after
        // the field, and a guess that changes a word already in the field waits for the next guess to say so too.
        let steady = max(min(agreed, before), min(agreed, shown + 1))
        if typing, !firm, agreed < min(shown, words.count),
           !zip(Self.words(typed[...]), words).allSatisfy({ Self.plain($0.0) == Self.plain($0.1) }) { return [] }
        return typing ? show(upTo: firm ? words.count : max(steady, shown)) : []
    }

    /// How many newer words a word waits for before it is typed. With none, the stop had to type five times as much
    /// again (a wrong word stayed in the field eleven times as often); with one or with two it is the same. Two was
    /// the first choice and felt slow: a word was in the field a median 0.47 s after it was said, and the word before
    /// a pause 1.0 s after. With one that is 0.39 s and 0.33 s, for about twice the characters of a newest word typed
    /// again (0.9% of what is typed, from 0.5%), in as many places (fourteen recorded monologues, 2026-11-26). The
    /// last word before a pause still waits for `settle`: a shorter wait there, or two agreeing guesses instead of
    /// three, left seven to twelve times as many wrong words in the field.
    static let hold = 1

    /// The field as a pass's `text` of everything said has it. The settled words stay as they are; what was typed
    /// since (from guesses, where they are typed) is written as the pass has it from the first word it has
    /// differently, and the rest of the text follows. Then all of it is settled. `final`: the stop, which types the
    /// closing mark too and may still change a comma or capital in its newest words (`calm`).
    private mutating func settle(on text: String, beyond: [String] = [], final: Bool) -> [Edit] {
        var text = text
        // A closing mark waits for the words after it, or for the end: a pass ends every pause with a period.
        if !final { while let last = text.last, Self.closingMarks.contains(last) { text.removeLast() } }
        if !final, let before, !text.isEmpty {
            text = SmartInsertion.adjust(text, before: before, after: after, names: names)
            // The space it puts in front of the text after the cursor belongs to the end: settled text that ended
            // with it took the next phrase's mark and capital away (review round 1).
            while text.last == " " { text.removeLast() }
        }
        let head = String(typed.prefix(settled))
        var next = Self.appending(text, to: head, beyond: beyond, newest: 0)
        if !final { while next.count > head.count, let last = next.last, Self.closingMarks.contains(last) { next.removeLast() } }
        // Nothing was said after the settled words: the mark held back after the last of them is typed at the stop.
        if final, next.count == head.count, let last = Self.spans(head).last, Self.closing(head[last]).isEmpty {
            let words = Self.spans(text)
            let count = Self.covered(Self.spans(head).map { Self.plain(String(head[$0])) }, in: words.map { Self.plain(String(text[$0])) })
            if count == words.count, count > 0 { next += Self.closing(text[words[count - 1]]) }
        }
        let edits = retype(Self.calm(next, over: typed, near: final ? Self.nearAtTheStop : 0))
        settled = typed.count
        return edits
    }

    /// No newer guess came for a moment (the person paused): the newest one stands.
    public mutating func settle() -> [Edit] { show(upTo: heard.count) }

    /// The finished text. `edits` bring the field to its first line; `rest` (from the first line break, tab or
    /// character a key press cannot type) is for the caller to paste after them. Words typed a while ago keep the
    /// commas and capitals they were typed with (`calm`): the stop is when the person's own keys and Return reach
    /// the app again, so it must not take a long stretch back. `typed` is what the field holds afterwards.
    public mutating func finish(_ text: String) -> (edits: [Edit], rest: String) {
        var fitted = text
        if let before, !fitted.isEmpty { fitted = SmartInsertion.adjust(fitted, before: before, after: after, names: names) }
        let (line, rest) = Self.typable(fitted)
        heard = []; shown = 0
        guard !streamed else { return (retype(String(line)), String(rest)) }
        // Settled words stay, unless the finished text has nothing in the place of two or more of them in a row:
        // "scratch that" took them back, or the recognizer made them up at a pause. Then the field is corrected from
        // the first of them on; the settled words before them stay (review rounds 1 and 2).
        let head = String(typed.prefix(settled)), finished = String(line)
        let old = Self.spans(head), new = Self.spans(finished)
        if settled > 0, let (from, to) = Self.removedRun(old.map { Self.plain(String(head[$0])) }, from: new.map { Self.plain(String(finished[$0])) }),
           typed.distance(from: old[from].lowerBound, to: typed.endIndex) <= Self.nearRemoved {
            settled = 0
            let kept = String(typed[..<old[from].lowerBound])
            if to < new.count { return (retype(kept + finished[new[to].lowerBound...]), String(rest)) }
            // The stretch runs to the end: the finished text's own ending (its closing mark, and the space in front
            // of text after the cursor) follows the kept words (review round 3).
            let trimmed = String(kept.reversed().drop { $0 == " " }.reversed())
            guard to > 0 else { return (retype(trimmed), String(rest)) }
            // (The kept last word was settled without the mark the pause held back.)
            let mark = Self.closing(finished[new[to - 1]])
            return (retype(trimmed + (trimmed.hasSuffix(mark) ? "" : mark) + finished[new[to - 1].upperBound...]), String(rest))
        }
        return (settle(on: finished, final: true), String(rest))
    }

    /// The person typed, clicked or changed fields: the words typed so far are theirs now and stay as they are.
    /// `holding` is what is really in the field when a run of key presses was cut short.
    public mutating func leave(holding: String? = nil) {
        let inField = holding ?? typed
        abandoned = inField.isEmpty ? nil : (inField, before, after)
        left = Self.words(inField[...]).map(Self.plain)
        typed = ""; settled = 0
        before = nil; after = ""
    }

    /// The text `leave` left in its field, while it can still be taken up again.
    public var abandonedText: String? { abandoned?.typed }

    /// The cursor is still right after the words `leave` left behind (the person only clicked in the same place):
    /// they are this dictation's own again, to correct and finish like the rest.
    public mutating func reclaim() {
        guard let abandoned else { return }
        self.abandoned = nil
        typed = abandoned.typed; settled = settlesAtPauses ? typed.count : 0
        left = []
        before = abandoned.before; after = abandoned.after
        shown = min(heard.count, Self.words(typed[...]).count)
    }

    /// The key presses never reached the field: nothing counts as typed, so the stop delivers everything.
    public mutating func disown() {
        typed = ""; settled = 0
        left = []; abandoned = nil
        before = nil; after = ""
        shown = 0
    }

    /// The part of the finished `text` that is in no field yet: all of it, unless words were left behind. With
    /// `seam` (the cursor is still after the left words, in a field that cannot be read, so nothing else will fit
    /// the two together) it starts with what belongs between them: the closing mark held back after the last left
    /// word, and a space.
    public func remainder(of text: String, seam: Bool = false) -> String {
        guard !left.isEmpty else { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        let skip = Self.covered(left, in: words.map { Self.plain(String($0)) })
        guard skip > 0 else { return text }
        // A finished word that goes on past the last left word behind a mark ("maple-design" after "maple", "3:30"
        // after "3", "example.com" after "example"): the rest of that word is in no field yet.
        if let more = Self.goingOn(words[skip - 1], past: left[left.count - 1]) { return String(text[more...]) }
        let end = words[skip - 1].endIndex
        let marks = seam ? Self.closing(words[skip - 1]) : ""
        guard skip < words.count else { return marks }
        // With the seam: from the end of the last left word, so a line break after it is kept. Without: from the
        // next word (the paste fits the space and capital to the real surroundings).
        guard seam else { return String(text[words[skip].startIndex...]) }
        return marks + (text[end].isNewline ? "" : " ") + String(text[end...].drop { $0 == " " })
    }

    /// Takes the typed words back (a cancelled dictation). Words that were left behind cannot be taken back.
    public mutating func erase() -> [Edit] {
        defer { typed = ""; settled = 0 }
        return typed.isEmpty ? [] : [.delete(typed.count)]
    }

    private mutating func show(upTo count: Int) -> [Edit] {
        let end = max(0, min(heard.count, count))
        // A closing mark waits for the words after it, or for the end: a guess ends every pause with a period.
        var text = heard[..<end].joined(separator: " ")
        while let last = text.last, Self.closingMarks.contains(last) { text.removeLast() }
        if let before, !text.isEmpty { text = SmartInsertion.adjust(text, before: before, after: after, names: names) }
        guard !streamed else { shown = end; return retype(text) }
        shown = max(shown, end)
        let unsettled = settled == 0 ? Self.newest : Self.spans(typed).count - Self.spans(String(typed.prefix(settled))).count
        var next = Self.appending(text, to: typed, beyond: heard[end...].map(Self.plain), newest: min(Self.newest, unsettled))
        while next.count > typed.count, let last = next.last, Self.closingMarks.contains(last) { next.removeLast() }
        return retype(next)
    }

    /// What the field holds once the guess's newer words are typed behind `typed`. Everything but the newest
    /// `newest` typed words stays, whatever the guess says. The typed words are lined up with the guess (`covered`):
    /// - The guess still has the last typed word where the typed words end: the words after it follow.
    /// - It has the word before the newest one or two there instead ("All right" came back as "Alright", a made-up
    ///   "be able" as "go home", a word was heard in front of the last one): those one or two are typed again as the
    ///   guess has them. This is looked for from the end of the typed words, not from their start, so a word that
    ///   stayed wrong far back does not switch it off.
    /// - Neither (more than two made-up words): the typed words stay and the guess goes on behind them from where
    ///   `covered` puts their end, its first word that differs when it has none of them.
    ///
    /// `beyond`: the guess's words after `text` (held back for now). They are not typed, but the typed words are
    /// lined up with the whole guess: cut off before the word the two share, two respelled words looked made up
    /// and the words after them went in a second time (review round 2). Lined up by count instead of by the words,
    /// real words were left out ("yeah" after "All right", "go home" after "be able": review round 1).
    static func appending(_ text: String, to typed: String, beyond: [String] = [], newest: Int = newest) -> String {
        guard !typed.isEmpty else { return text }
        if text.hasPrefix(typed) { return text }
        let old = spans(typed), new = spans(text)
        guard !old.isEmpty, !new.isEmpty else { return typed }
        let was = old.map { plain(String(typed[$0])) }
        let guess = new.map { plain(String(text[$0])) } + beyond
        // Settled words are never typed again: where the text goes on past the last of them behind a mark
        // ("maple-design" after "maple", "3:30" after "3"), the rest of that word is typed behind it (review round 1).
        if newest == 0, let last = was.last {
            let count = covered(was, in: guess)
            if count > 0, count <= new.count, let more = goingOn(text[new[count - 1]], past: last) { return typed + text[more...] }
        }
        /// The guess from `index` on, behind the typed text up to `end`, beginning as the typed mark before it says.
        func joined(_ end: String.Index, from index: Int, after: (old: Int, new: Int)?) -> String {
            var tail = String(text[new[index].lowerBound...])
            if let after {
                let was = endsSentence(typed[old[after.old]]), now = endsSentence(text[new[after.new]])
                if was, !now { tail = SmartInsertion.capitalizingFirstWord(tail) }
                if now, !was { tail = SmartInsertion.lowercasingFirstWord(tail) }
            }
            let head = typed[..<end]
            return head + (head.isEmpty || head.last == " " ? "" : " ") + tail
        }
        // The cheapest of: the guess goes on behind the last typed word, or behind the one or two before it (the
        // newest then typed again). Among equals, the one that takes nothing back.
        var chosen: (drop: Int, count: Int, cost: Int)?, reach = 0
        for drop in 0...min(newest, was.count) {
            let kept = Array(was.dropLast(drop))
            guard let found = kept.isEmpty ? (count: 0, cost: 0) : lineUp(kept, with: guess, ending: true) else { continue }
            if drop == 0 { reach = found.count }
            if chosen == nil || found.cost < chosen!.cost { chosen = (drop, found.count, found.cost) }
        }
        if let chosen {
            let (drop, count) = (chosen.drop, chosen.count)
            // Not from a guess shown only up to a word before the last typed one (its newest words are held back):
            // that would take a typed word away and bring it back with the next guess. So the shown text has as
            // many words as are taken back, and where the guess still has the last typed word, it reaches it.
            guard new.count - count >= max(drop, 1), drop == 0 || new.count >= reach else { return typed }
            guard drop == 0 else {
                return joined(old[old.count - drop].lowerBound, from: count, after: drop == old.count ? nil : (old.count - drop - 1, count - 1))
            }
            // The mark after the last typed word was held back until words follow it: it is typed with them now.
            // (Not in front of a word, where the typed text ends with the space before that word: the mark stays
            // out, and a capital it would bring with it.)
            if closing(typed[old[old.count - 1]]).isEmpty, typed.last != " " {
                return typed + closing(text[new[count - 1]]) + " " + text[new[count].lowerBound...]
            }
            return joined(typed.endIndex, from: count, after: (old.count - 1, count - 1))
        }
        // The guess has none of the newest three typed words where they would be: they stay, and it goes on behind them.
        let count = covered(was, in: guess)
        guard count < new.count else { return typed }
        return joined(typed.endIndex, from: count, after: count > 0 ? (old.count - 1, count - 1) : nil)
    }

    /// How many of the newest typed words a guess may still change.
    static let newest = 2

    /// Where the words of `string` are.
    static func spans(_ string: String) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = [], index = string.startIndex
        while let start = string[index...].firstIndex(where: { $0 != " " }) {
            let end = string[start...].firstIndex(of: " ") ?? string.endIndex
            spans.append(start..<end); index = end
        }
        return spans
    }

    /// Whether a sentence ends with this word.
    static func endsSentence(_ word: Substring) -> Bool {
        word.reversed().prefix { !($0.isLetter || $0.isNumber) }.contains { SmartInsertion.sentenceEnds.contains($0) }
    }

    /// How far back the stop may change how words are written.
    static let nearAtTheStop = 40

    /// The finished text as the stop types it: only its newest words change how they are written. Where it differs
    /// further back than `near` characters only in how the same words are written (the comma a pass puts in front of
    /// a clause once it has heard the clause, a capital, a period), those words stay as typed, for good: taking a
    /// long stretch back for a comma would erase it at the moment the person's own keys reach the app again. A word
    /// that changed is corrected, wherever it is. Not for the streaming recognizer's words (`streamed`), which have
    /// no capitals or marks of their own and get all of them from the passes.
    static func calm(_ text: String, over typed: String, near: Int = nearAtTheStop) -> String {
        let same = zip(typed, text).prefix { $0.0 == $0.1 }.count
        guard typed.count - same > near else { return text }
        let old = spans(typed), new = spans(text)
        func says(_ index: Int) -> Bool { written(typed[old[index]]) == written(text[new[index]]) }
        // The words that say the same and end before the newest `near` characters keep their typed spelling.
        let limit = typed.index(typed.endIndex, offsetBy: -near)
        var kept = 0
        while kept < old.count, kept < new.count, old[kept].upperBound <= limit, says(kept) { kept += 1 }
        guard kept > 0 else { return text }
        var tail = String(text[new[kept - 1].upperBound...])
        // The words after them begin as the kept word's typed mark says, not as the guess's mark would have them: a
        // period that was held back takes its capital with it ("plan. And so" stays "plan and so", never "plan And
        // so"), and a period that was typed keeps the capital after it when the guess makes it a comma.
        let was = endsSentence(typed[old[kept - 1]]), now = endsSentence(text[new[kept - 1]])
        if was, !now { tail = SmartInsertion.capitalizingFirstWord(tail) }
        if now, !was { tail = SmartInsertion.lowercasingFirstWord(tail) }
        return String(typed[..<old[kept - 1].upperBound]) + tail
    }

    /// A word as `calm` compares two spellings of it: its case and the marks that only punctuate a sentence around it
    /// make no difference. A sign that is part of what was said does: "--verbose", "$5", "12%" and "-5" are not
    /// "verbose", "5" and "12", and are corrected like any changed word.
    static func written(_ word: Substring) -> String {
        let around = Set(".,!?;:…\"'“”‘’()[]{}¿¡„«»‹›—–")
        var bare = word[...]
        // (A period in front is part of what was said: ".5", ".env", ".NET".)
        while let first = bare.first, first != ".", around.contains(first) { bare = bare.dropFirst() }
        while let last = bare.last, around.contains(last) { bare = bare.dropLast() }
        return bare.isEmpty ? String(word) : bare.lowercased()
    }

    private mutating func retype(_ text: String) -> [Edit] {
        let same = zip(typed, text).prefix { $0.0 == $0.1 }.count
        var edits: [Edit] = []
        if typed.count > same { edits.append(.delete(typed.count - same)) }
        if text.count > same { edits.append(.type(String(text.dropFirst(same)))) }
        typed = text
        settled = min(settled, same)
        return edits
    }

    static let closingMarks: Set<Character> = [".", ",", "!", "?", ";", ":", "…"]

    static func words(_ line: Substring) -> [String] { line.split(separator: " ").map(String.init) }

    /// The closing marks a word ends with ("passed." → ".").
    static func closing(_ word: Substring) -> String {
        String(word.reversed().prefix { closingMarks.contains($0) }.reversed())
    }

    /// A word as two guesses are compared: case and the marks around it do not make it a different word.
    static func plain(_ word: String) -> String {
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        return bare.isEmpty ? word : bare
    }

    /// The start of `text` that key presses can type and take back one character at a time, and the rest: a line
    /// break or tab would press Return or leave the field, and one backspace does not always remove a character
    /// built from several code points (an emoji with a skin tone).
    static func typable(_ text: String) -> (line: Substring, rest: Substring) {
        let cut = text.firstIndex { $0.isNewline || $0 == "\t" || $0.unicodeScalars.count > 1 || $0.unicodeScalars.contains { $0.value > 0xFFFF } }
            ?? text.endIndex
        return (text[..<cut], text[cut...])
    }

    /// Where `word` goes on past `last` (a left word, plain) behind a mark: "maple-design" after "maple", "3:30" after
    /// "3", "example.com" after "example". Nil when it is the same word, a longer one ("there" after "the") or a
    /// contraction ("it's" after "it").
    static func goingOn(_ word: Substring, past last: String) -> Substring.Index? {
        let body = word.drop { !($0.isLetter || $0.isNumber) }
        let more = body.dropFirst(last.count)
        guard plain(String(word)) != last, body.prefix(last.count).lowercased() == last,
              let mark = more.first, !(mark.isLetter || mark.isNumber || mark == "'" || mark == "’"),
              more.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return more.startIndex
    }

    /// How many of `words` say what `left` already says: the words after them are the ones no field has yet.
    static func covered(_ left: [String], in words: [String]) -> Int { lineUp(left, with: words)?.count ?? 0 }

    /// Lines `left` (words in a field) up with the start of `words` (a newer text of the same speech): how many of
    /// `words` they stand for, and what the line-up costs. The text may have changed since the words were typed, so
    /// this is the cheapest way to turn one into the other:
    /// - a word of the text that the field lacks, and a left word the text no longer has (an ending the recognizer
    ///   made up), cost 2 each;
    /// - the same word written differently (`alike`: "there" for "their", "walk" for "walked") costs 1;
    /// - any other word in a word's place costs 4, as much as one gone and one missing.
    /// So respelled words stay in step ("there going to" is all of "they're going too"), and made-up ones stand for
    /// nothing ("be able" covers none of "go home now"): the words said in their place are still delivered. With
    /// equal weights a made-up word counted as the next word said, which then never reached the field (review
    /// rounds 1 and 2). Among equals, a count that ends on the last left word comes first (a word the first pass
    /// missed, "I want to" for "I want you to", must not make "to" be typed again), then the smallest, so a word
    /// may be delivered that is there in another form but none is skipped. A last word written as two, or joined
    /// with the one before it ("icecream", "ice cream"), may cost a missing word more.
    ///
    /// `ending`: only line-ups that end on the last left word itself; nil where the text does not have it.
    static func lineUp(_ left: [String], with words: [String], ending: Bool = false) -> (count: Int, cost: Int)? {
        var same = 0
        while same < left.count, same < words.count, left[same] == words[same] { same += 1 }
        guard same < left.count else { return (same, 0) }
        // Everything matched up to the last left word, and the finished word there only goes on past it
        // ("maple-design" after "maple"): that word is the one, whatever comes after it.
        if same == left.count - 1, same < words.count, goingOn(words[same][...], past: left[same]) != nil {
            return ending ? nil : (same + 1, 0)
        }
        let old = Array(left[same...])
        let new = Array(words[same...].prefix(old.count * 2 + 8))
        // The cost of turning `old` into every prefix of `new`. Long stretches are lined up only within `band`
        // words of each other: after one word that stayed wrong early in a long dictation everything behind it is
        // lined up again with every guess, several times a second on the main actor, and the full table grows with
        // the square of the length (review round 3). A stretch of more made-up words than that is not expected.
        // A text much shorter than the field (a guess that lost a stretch) widens the band by that much: the rows
        // past its end must still lie inside the table.
        let far = Int.max / 2
        let band = old.count > 2 * Self.band ? Self.band + max(0, old.count - new.count) : far
        var row = (0...new.count).map { $0 <= band ? $0 * 2 : far }
        for (i, word) in old.enumerated() {
            let low = max(0, i + 1 - band), high = min(new.count, i + 1 + min(band, new.count))
            var diagonal = row[max(0, low - 1)]
            if low == 0 { diagonal = row[0]; row[0] = (i + 1) * 2 } else { row[low - 1] = far }
            for j in max(0, low - 1)..<high {
                let above = row[j + 1]
                let swap = word == new[j] ? 0 : alike(word, new[j]) ? 1 : 4
                row[j + 1] = min(diagonal + swap, above + 2, row[j] + 2)
                diagonal = above
            }
            if high < new.count { row[high + 1] = far }
        }
        let last = old[old.count - 1], lastTwo = old.suffix(2).joined()
        func ends(_ count: Int) -> Bool { count > 0 && new[count - 1] == last }
        let fewest = row.min() ?? 0
        if ending {
            // Only where ending on that word is as cheap as any line-up: a made-up "be able to" must not be pinned
            // to a "to" that was really said five words on, with "go home" paid for as "be able" written
            // differently. That swallowed the real words in between (review round 3).
            guard let count = row.indices.filter({ ends($0) && row[$0] == fewest }).min() else { return nil }
            return (same + count, fewest)
        }
        /// Whether the first `count` new words end on the last left word written differently: as two words, or
        /// joined with the one before it.
        func respelled(_ count: Int) -> Bool {
            guard count > 0 else { return false }
            /// A doubled letter where the two meet is the same spelling ("all right", "alright").
            func joins(_ two: String, _ one: String) -> Bool { Self.sameJoined(two, one) }
            if old.count > 1, joins(lastTwo, new[count - 1]) { return true }
            return count > 1 && joins(new[count - 2] + new[count - 1], last)
        }
        let best = row.indices.filter { row[$0] == fewest }
        if !best.contains(where: ends), let other = row.indices.filter({ row[$0] <= fewest + 2 && respelled($0) }).min(by: { row[$0] < row[$1] }) {
            return (same + other, row[other])
        }
        // One left word that the text has another word for, and no place it ends on: the text's word there stands
        // for it, as it always did ("at noon" covers "at nine"). Counted as made up instead, every word heard
        // differently at the end of the left words was delivered beside it ("said set it up", "a the banana":
        // review round 3); the price is the word said in place of a single made-up last word.
        if old.count == 1, !new.isEmpty, !best.contains(where: ends) { return (same + 1, row[1]) }
        let count = best.filter(ends).min() ?? best.min() ?? 0
        return (same + count, fewest)
    }

    /// How far apart two long stretches of words are lined up (`lineUp`).
    static let band = 24

    /// Whether two words (plain) are most likely the same word written differently: they begin alike and one goes on
    /// from the other ("walk", "walked"; "to", "too"), or at most half their letters differ ("there", "their",
    /// "they're"; "feed", "feet"). "noon" and "nine", "a" and "the" are different words.
    static func alike(_ a: String, _ b: String) -> Bool {
        guard let first = a.first, first == b.first else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        let one = Array(a.utf8), other = Array(b.utf8)
        guard abs(one.count - other.count) * 2 <= max(one.count, other.count) else { return false }
        var row = Array(0...other.count)
        for (i, letter) in one.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for j in 0..<other.count {
                let above = row[j + 1]
                row[j + 1] = min(diagonal + (letter == other[j] ? 0 : 1), above + 1, row[j] + 1)
                diagonal = above
            }
        }
        return row[other.count] * 2 <= max(one.count, other.count)
    }
}
