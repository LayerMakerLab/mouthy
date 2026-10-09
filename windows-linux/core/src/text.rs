//! Text rules, kept behavior-identical to `mac/Sources/MouthyCore` (Swift) through the shared
//! fixtures in `shared/text-rules.json`.

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Replacement {
    pub phrase: String,
    pub replacement: String,
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Case-insensitive, whole-word matches of `alternatives` (already ordered longest first).
fn word_matches(text: &str, pattern: &Regex) -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    for m in pattern.find_iter(text) {
        let before = text[..m.start()].chars().next_back();
        let after = text[m.end()..].chars().next();
        if before.is_none_or(|c| !is_word_char(c)) && after.is_none_or(|c| !is_word_char(c)) {
            found.push((m.start(), m.end()));
        }
    }
    found
}

fn alternation(phrases: &[String]) -> Regex {
    let body = phrases.iter().map(|p| regex::escape(p)).collect::<Vec<_>>().join("|");
    Regex::new(&format!("(?i)(?:{body})")).expect("valid alternation")
}

const QUOTE_OPENERS: &[char] = &['(', '[', '{', '"', '\'', '“', '‘'];

/// Capitalizes the first word only when it starts with a letter: "20 minutes" and "$15 is" keep their case.
pub fn capitalize_first_word(text: &str) -> String {
    let Some((index, c)) = text.char_indices().find(|(_, c)| !c.is_whitespace() && !QUOTE_OPENERS.contains(c)) else { return text.to_string() };
    if !c.is_alphabetic() || !c.is_lowercase() {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    out.push_str(&text[..index]);
    out.extend(c.to_uppercase());
    out.push_str(&text[index + c.len_utf8()..]);
    out
}

const PROPER_WORDS: &[&str] = &[
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January", "February", "March",
    "April", "June", "July", "August", "September", "October", "November", "December",
];

pub fn lowercase_first_word(text: &str) -> String {
    let Some((index, c)) = text.char_indices().find(|(_, c)| !c.is_whitespace()) else { return text.to_string() };
    if !c.is_uppercase() {
        return text.to_string();
    }
    let word: String = text[index..].chars().take_while(|c| c.is_alphabetic() || *c == '\'' || *c == '’').collect();
    let rest_lower = word.chars().skip(1).all(|c| c.is_lowercase() || c == '\'' || c == '’');
    if word.chars().count() <= 1 || !rest_lower || word.starts_with("I'") || word.starts_with("I’") || PROPER_WORDS.contains(&word.as_str()) {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    out.push_str(&text[..index]);
    out.extend(c.to_lowercase());
    out.push_str(&text[index + c.len_utf8()..]);
    out
}

const OPENERS: &[char] = &['(', '[', '{', '"', '\'', '“', '‘', '/', '-', '—', '@', '#', '$'];
const CLOSERS: &[char] = &['.', ',', '!', '?', ':', ';', ')', ']', '}', '”', '’', '%'];
const SENTENCE_ENDS: &[char] = &['.', '!', '?'];

/// Fits dictated text to the characters around the cursor: separating spaces, sentence-start capitals,
/// lowercase and no stray period mid-sentence.
pub fn smart_insertion(text: &str, before: &str, after: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    let mut out = text.to_string();
    let previous = before.chars().next_back();
    let last_visible = before.chars().rev().find(|c| !c.is_whitespace());
    match last_visible {
        None => out = capitalize_first_word(&out),
        Some(c) if SENTENCE_ENDS.contains(&c) || before.ends_with('\n') => out = capitalize_first_word(&out),
        Some(c) if c.is_alphanumeric() || c == ',' || c == ';' || c == ':' => out = lowercase_first_word(&out),
        _ => {}
    }
    if let (Some(p), Some(start)) = (previous, out.chars().next()) {
        if !p.is_whitespace() && !OPENERS.contains(&p) && (start.is_alphanumeric() || OPENERS.contains(&start)) {
            out.insert(0, ' ');
        }
    }
    if let Some(next) = after.chars().find(|c| !c.is_whitespace()) {
        if next.is_lowercase() && out.chars().count() > 1 && out.ends_with('.') {
            out.pop();
        }
    }
    if let (Some(next), Some(end)) = (after.chars().next(), out.chars().next_back()) {
        if next.is_alphanumeric() && !end.is_whitespace() && !OPENERS.contains(&end) {
            out.push(' ');
        }
    }
    if let (Some(next), Some(end)) = (after.chars().next(), out.chars().next_back()) {
        if CLOSERS.contains(&next) && out.chars().count() > 1 && (SENTENCE_ENDS.contains(&end) || end == ',') {
            out.pop();
        }
    }
    out
}

fn backtrack_pattern() -> &'static Regex {
    static P: OnceLock<Regex> = OnceLock::new();
    P.get_or_init(|| Regex::new(r"(?i)(?:scratch that|delete that|strike that)").unwrap())
}

/// "scratch that / delete that / strike that" removes the sentence spoken before it.
pub fn backtrack(text: &str) -> String {
    let mut out = text.to_string();
    loop {
        let Some(&(start, mut end)) = word_matches(&out, backtrack_pattern()).first() else { break };
        if let Some(c) = out[end..].chars().next() {
            if ".,!?".contains(c) {
                end += c.len_utf8();
            }
        }
        let head = &out[..start];
        let trimmed = head.trim_end_matches(|c: char| c.is_whitespace() || c == ',');
        // Skip the scratched sentence's own terminator, then cut after the previous boundary.
        let search = match trimmed.char_indices().next_back() {
            Some((i, _)) => &trimmed[..i],
            None => "",
        };
        let cut = search
            .char_indices()
            .rev()
            .find(|(_, c)| SENTENCE_ENDS.contains(c) || *c == '\n')
            .map_or(0, |(i, c)| i + c.len_utf8());
        let kept = out[..cut].to_string();
        let mut tail = out[end..].trim_start_matches(' ').to_string();
        // What follows now opens the sentence the command removed.
        let kept_visible = kept.trim_end_matches([' ', '\t']).chars().next_back();
        if kept_visible.is_none_or(|c| c == '\n' || SENTENCE_ENDS.contains(&c)) {
            tail = capitalize_first_word(&tail);
        }
        let joiner = if kept.is_empty() || kept.ends_with(char::is_whitespace) || tail.is_empty() { "" } else { " " };
        out = format!("{kept}{joiner}{tail}");
    }
    out.trim().to_string()
}

const SYMBOLS: &[(&str, &str)] = &[
    ("new paragraph", "\n\n"), ("new line", "\n"), ("question mark", "?"), ("exclamation point", "!"),
    ("exclamation mark", "!"), ("full stop", "."), ("semicolon", ";"), ("period", "."), ("comma", ","), ("colon", ":"),
];
const ORDINARY_PREDECESSORS: &[&str] = &[
    "a", "an", "the", "this", "that", "each", "every", "one", "per", "any", "some", "my", "your", "our", "their", "his",
    "her", "its", "trial", "grace", "waiting", "cooling", "time", "billing",
];
const RECOGNIZER_PUNCTUATION: &[char] = &['.', ',', '!', '?', ';', ':'];

fn punctuation_pattern() -> &'static Regex {
    static P: OnceLock<Regex> = OnceLock::new();
    P.get_or_init(|| alternation(&SYMBOLS.iter().map(|s| s.0.to_string()).collect::<Vec<_>>()))
}

/// Spoken punctuation table.
pub fn spoken_punctuation(text: &str) -> String {
    #[derive(PartialEq)]
    enum Case { None, Upper, Lower }
    let mut result = String::new();
    let mut pending = Case::None;
    let mut cursor = 0usize;
    let append = |result: &mut String, chunk: &str, pending: &mut Case| {
        let piece = match pending {
            Case::Upper => capitalize_first_word(chunk),
            Case::Lower => lowercase_first_word(chunk),
            Case::None => chunk.to_string(),
        };
        if piece.chars().any(|c| c.is_alphanumeric()) {
            *pending = Case::None;
        }
        result.push_str(&piece);
    };
    for (start, end) in word_matches(text, punctuation_pattern()) {
        if start < cursor {
            continue;
        }
        append(&mut result, &text[cursor..start], &mut pending);
        let spoken = text[start..end].to_lowercase();
        let symbol = SYMBOLS.iter().find(|s| s.0 == spoken).unwrap().1;
        let previous_word = result.split(|c: char| !c.is_alphabetic()).filter(|w| !w.is_empty()).next_back().map(str::to_lowercase).unwrap_or_default();
        if !symbol.starts_with('\n') && ORDINARY_PREDECESSORS.contains(&previous_word.as_str()) {
            result.push_str(&text[start..end]);
            cursor = end;
            continue;
        }
        while result.ends_with(|c: char| c == ' ' || RECOGNIZER_PUNCTUATION.contains(&c)) {
            result.pop();
        }
        result.push_str(symbol);
        pending = if symbol.starts_with('\n') || ".?!".contains(symbol) { Case::Upper } else { Case::Lower };
        cursor = end;
        while let Some(c) = text[cursor..].chars().next() {
            if c == ' ' || RECOGNIZER_PUNCTUATION.contains(&c) { cursor += c.len_utf8() } else { break }
        }
        if !symbol.starts_with('\n') {
            if let Some(c) = text[cursor..].chars().next() {
                if c != '\n' {
                    result.push(' ');
                }
            }
        }
    }
    append(&mut result, &text[cursor..], &mut pending);
    result.trim().to_string()
}

/// Removes hesitation fillers ("um", "uh", "erm") with the commas around them. A filler that opened a
/// sentence hands its capital to the next word; one that closed a sentence leaves the period in place.
/// Nothing else is touched, so "p.m.", "e.g." and "mouthy.dev" read as spoken. Words that can carry
/// meaning ("like", "you know") are left alone.
pub fn remove_fillers(text: &str) -> String {
    static P: OnceLock<Regex> = OnceLock::new();
    let pattern = P.get_or_init(|| Regex::new(r"(?i)(,\s*)?\b(?:u+h*m+|u+h+|e+r+m+|h+m+m+)\b(?:\s*([,.])(?:\s|$))?").unwrap());
    // (start, end, the filler closed a sentence, the whitespace the match swallowed after it)
    let mut found: Vec<(usize, usize, bool, Option<char>)> = Vec::new();
    for caps in pattern.captures_iter(text) {
        let m = caps.get(0).unwrap();
        // \b treats apostrophes as boundaries; skip matches glued to letters or apostrophes.
        let before = text[..m.start()].chars().next_back();
        let core_start = m.as_str().find(|c: char| c.is_alphabetic()).map(|i| m.start() + i).unwrap_or(m.start());
        let prev = text[..core_start].chars().next_back();
        if prev.is_some_and(|c| c == '\'' || c == '’') || before.is_some_and(|c| c.is_alphanumeric() && core_start == m.start()) { continue; }
        let closes = caps.get(2).is_some_and(|p| p.as_str() == ".");
        let swallowed = m.as_str().chars().next_back().filter(|c| c.is_whitespace());
        found.push((m.start(), m.end(), closes, swallowed));
    }
    let mut out = text.to_string();
    // Back to front, so each match's offsets still hold.
    for (start, end, closes, swallowed) in found.into_iter().rev() {
        let head = out[..start].to_string();
        let visible = head.trim_end_matches([' ', '\t']).chars().next_back();
        let opens = visible.is_none_or(|c| c == '\n' || SENTENCE_ENDS.contains(&c));
        let mut tail = out[end..].to_string();
        if opens || closes { tail = capitalize_first_word(&tail); }
        let mut middle = String::new();
        if closes && !opens { middle.push('.'); }
        if let Some(space) = swallowed { middle.push(space); }
        out = format!("{head}{middle}{tail}");
    }
    let spaces = Regex::new(r"[ \t]{2,}").unwrap();
    let before_punct = Regex::new(r"\s+([,.;:!?])").unwrap();
    let out = spaces.replace_all(&out, " ");
    strip_leading_punctuation(&before_punct.replace_all(&out, "$1"))
}

/// Hesitations written as "..." or "…" are dropped, with the commas left behind tidied.
pub fn remove_hesitation_dots(text: &str) -> String {
    let dots = Regex::new(r"\s*(?:\.{2,}|…)+").unwrap();
    let commas = Regex::new(r"\s*,(?:\s*,)+").unwrap();
    let spaced = Regex::new(r"\s+([,.;:!?])").unwrap();
    let out = dots.replace_all(text, "");
    let out = commas.replace_all(&out, ",");
    spaced.replace_all(&out, "$1").into_owned()
}

/// Removes pause artifacts ("...", "…", stray commas) before the first word.
pub fn strip_leading_punctuation(text: &str) -> String {
    text.trim_start_matches(|c: char| c.is_whitespace() || ".,;:…!?-–—".contains(c)).trim().to_string()
}

pub fn process(text: &str, replacements: &[Replacement], punctuation: bool) -> String {
    let mut out = strip_leading_punctuation(&remove_hesitation_dots(text));
    if punctuation {
        out = backtrack(&out);
    }
    let mut rules: Vec<&Replacement> = replacements.iter().filter(|r| !r.phrase.trim().is_empty()).collect();
    rules.sort_by(|a, b| b.phrase.chars().count().cmp(&a.phrase.chars().count()));
    if !rules.is_empty() {
        let pattern = alternation(&rules.iter().map(|r| r.phrase.clone()).collect::<Vec<_>>());
        let mut rebuilt = String::new();
        let mut cursor = 0;
        for (start, end) in word_matches(&out, &pattern) {
            let found = &out[start..end];
            if let Some(rule) = rules.iter().find(|r| r.phrase.to_lowercase() == found.to_lowercase()) {
                rebuilt.push_str(&out[cursor..start]);
                rebuilt.push_str(&rule.replacement);
                cursor = end;
            }
        }
        rebuilt.push_str(&out[cursor..]);
        out = rebuilt;
    }
    if punctuation {
        out = spoken_punctuation(&out);
    }
    let spaced = Regex::new(r" *\n *").unwrap();
    spaced.replace_all(&out, "\n").trim().to_string()
}
