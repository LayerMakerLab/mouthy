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

fn is_contraction_tail(rest: &str) -> bool {
    let mut chars = rest.chars();
    matches!(chars.next(), Some('\'' | '’')) && matches!(chars.next(), Some('t' | 'T')) && chars.next().is_none_or(|c| !is_word_char(c))
}

fn alternation(phrases: &[String]) -> Regex {
    let body = phrases.iter().map(|p| regex::escape(p)).collect::<Vec<_>>().join("|");
    Regex::new(&format!("(?i)(?:{body})")).expect("valid alternation")
}

const QUOTE_OPENERS: &[char] = &['(', '[', '{', '"', '\'', '“', '‘'];

/// Capitalizes the first word only when it starts with a letter: "20 minutes" and "$15 is" keep their case, and so
/// does an address ("name@example.com", "mouthy.dev", "https://…").
pub fn capitalize_first_word(text: &str) -> String {
    let Some((index, c)) = text.char_indices().find(|(_, c)| !c.is_whitespace() && !QUOTE_OPENERS.contains(c)) else { return text.to_string() };
    if !c.is_alphabetic() || !c.is_lowercase() || is_address(text[index..].split_whitespace().next().unwrap_or("")) {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    out.push_str(&text[..index]);
    out.extend(c.to_uppercase());
    out.push_str(&text[index + c.len_utf8()..]);
    out
}

/// An email address, a URL or a domain ("mouthy.dev"): letters, then a dot and at least two letters, or "@" or "://".
fn is_address(word: &str) -> bool {
    let word = word.trim_matches(|c: char| ".,;:!?)]}\"'”’".contains(c));
    word.contains('@') || word.contains("://") || word.to_lowercase() == "www"
        || Regex::new(r"^[\p{L}\p{N}-]+(\.[\p{L}\p{N}-]+)*\.\p{L}{2,}(/\S*)?$").unwrap().is_match(word)
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
    let article = word == "A" && text[index..].chars().nth(1).is_some_and(char::is_whitespace);
    if (word.chars().count() <= 1 && !article) || !rest_lower || word.starts_with("I'") || word.starts_with("I’") || PROPER_WORDS.contains(&word.as_str()) {
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
        } else if (p.is_alphanumeric() || CLOSERS.contains(&p)) && starts_dot_file(&out) {
            // A dot-file is a word of its own after a word or a closing mark ("the .env"), never after "=" or "`".
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

/// Spoken sentence ends, still words here: spoken punctuation is applied after backtracking.
fn spoken_end_pattern() -> &'static Regex {
    static P: OnceLock<Regex> = OnceLock::new();
    P.get_or_init(|| Regex::new(r"(?i)(?:period|full stop|question mark|exclamation point|exclamation mark|new line|new paragraph)").unwrap())
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
        // "Buy milk period buy eggs scratch that": a spoken sentence end is a boundary too, unless it closes the
        // very sentence being scratched.
        let spoken = word_matches(trimmed, spoken_end_pattern()).into_iter()
            // "The grace period ends": spoken punctuation keeps "period" a word after these, so it is no boundary.
            .filter(|&(s, _)| {
                if trimmed[s..].to_lowercase().starts_with("new ") { return true; }
                let previous = trimmed[..s].split(|c: char| !c.is_alphabetic()).filter(|w| !w.is_empty()).next_back().unwrap_or("").to_lowercase();
                !ORDINARY_PREDECESSORS.contains(&previous.as_str())
            })
            .map(|(_, e)| match trimmed[e..].chars().next() { Some(c) if ".,!?".contains(c) => e + c.len_utf8(), _ => e })
            .filter(|&e| e < trimmed.len())
            .last();
        let spoken_boundary = spoken.is_some_and(|e| e > cut);
        let cut = if spoken_boundary { spoken.unwrap() } else { cut };
        let kept = out[..cut].to_string();
        let mut tail = out[end..].trim_start_matches(' ').to_string();
        // What follows now opens the sentence the command removed.
        let kept_visible = kept.trim_end_matches([' ', '\t']).chars().next_back();
        if spoken_boundary || kept_visible.is_none_or(|c| c == '\n' || SENTENCE_ENDS.contains(&c)) {
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

const MARKS: &[&str] = &["dash", "hyphen", "dot", "slash", "underscore"];
/// Web endings and file endings: "dot" before one of these is written onto the word before.
const ENDINGS: &[&str] = &[
    "com", "org", "dev", "io", "ai", "app", "co", "edu", "gov", "uk", "md", "txt", "json", "swift", "py", "js", "ts", "html",
    "css", "pdf", "png", "jpg", "zip", "sh", "toml", "yaml", "yml", "rs", "csv", "xml", "plist",
];
/// File names that start with a dot: "dot env" → .env, whatever comes before.
const DOT_FILES: &[&str] = &["env", "gitignore", "zshrc", "bashrc", "git", "github", "claude", "ssh", "vscode", "npmrc", "dockerignore"];
const ORDINARY_BEFORE: &[&str] = &[
    "a", "an", "the", "this", "that", "each", "every", "any", "some", "my", "your", "our", "their", "his", "her",
    "its", "mad", "quick", "door", "em", "en", "to", "i", "we", "you", "they", "i'll", "we'll", "you'll", "they'll", "let's",
    "gotta", "say", "says", "said", "saying", "word",
];
const ORDINARY_AFTER: &[&str] = &["cam", "is", "was", "means"];
/// A dot-file is named after one of these or at the very start ("the dot env file", "in dot gitignore"); after any
/// other word "dot github" is part of an address ("api dot github dot com").
const DOT_FILE_BEFORE: &[&str] = &["in", "into", "from", "of", "add", "edit", "open", "check", "see", "and", "or", "called", "named", "with", "at", "on"];
/// "an underscore between the words", "you should underscore that point".
const UNDERSCORE_BEFORE: &[&str] = &[
    "a", "an", "the", "to", "should", "will", "would", "with", "and", "add", "of", "that", "this", "one", "single", "double",
    "leading", "trailing", "say", "says", "said", "saying", "word",
];
const UNDERSCORE_AFTER: &[&str] = &[
    "the", "that", "this", "how", "a", "an", "between", "before", "after", "in", "is", "to", "for", "and", "or", "character",
    "key", "symbol", "sign", "means", "was", "why", "what", "when", "where", "who", "one", "our", "my", "your", "his", "her",
    "their", "its", "just", "all", "some", "any", "these", "those", "each", "every", "both", "it",
];
/// "type slash help" → type /help. Only after "type": "try slash catch" and "send slash receive" are pairs.
const SLASH_TYPED: &[&str] = &["type", "typed"];
/// And a dictation that is nothing but "slash" and one word is a command, "slash clear" → /clear; not before one of these.
const SLASH_AFTER: &[&str] = &[
    "the", "a", "an", "and", "or", "command", "commands", "prices", "costs", "is", "was", "means", "my", "your", "our", "their",
    "his", "her", "its", "it", "that", "this", "these", "those", "through", "at",
];

/// Whether `text` starts with a dot-file name that is a word of its own (".env", ".claude/hooks", ".gitignore,"),
/// not the start of something longer (".github.com" going on after "www"): `smart_insertion` gives it a space.
fn starts_dot_file(text: &str) -> bool {
    let Some(after) = text.strip_prefix('.') else { return false };
    let name: String = after.chars().take_while(|c| c.is_alphabetic()).collect();
    if !DOT_FILES.contains(&name.to_lowercase().as_str()) { return false; }
    let mut rest = after[name.len()..].chars();
    match rest.next() {
        None => true,
        // ".env's" and ".env-specific" are the file; ".github.com" goes on, and so does ".env2" or ".env_file".
        Some(first) => !first.is_alphanumeric() && first != '_' && !(first == '.' && rest.next().is_some_and(char::is_alphanumeric)),
    }
}

/// Spoken marks in ordinary dictation, written as the mark where the words around them say so: "Maple dash Design"
/// → Maple-Design, "commit dash m" → commit -m, "dash dash help" → --help, "example dot com" → example.com, "readme
/// dot md" → readme.md, "dot env" → .env, "type slash help" → type /help, "user underscore name" → user_name.
/// Strict on purpose, so the words stay words wherever they could be meant: only on one line with nothing but spaces
/// between the spoken mark and its neighbours ("say dash, I mean" and a "dash" that ends the text are left), never
/// next to another mark, never after or before a word that makes it ordinary ("a dash of salt", "the dot com years",
/// "an underscore between"), "dot" and "slash" only in the shapes listed below, and never a mark that is one of the
/// person's own words (`vocabulary`: "Dash" the app stays "Dash"). Every rule looks only at the word before and the
/// word after, never further ahead. Code modes have their own table (`code_dictation`).
pub fn spoken_joiners(text: &str, vocabulary: &str) -> String {
    let (written, command) = write_joiners(text, vocabulary, true);
    // A command is one word. Where a mark in it did not join ("slash to dash do": "to dash" is ordinary), the text
    // is no command after all.
    if command && written.trim().contains(char::is_whitespace) { write_joiners(text, vocabulary, false).0 } else { written }
}

/// `commands` false: a text that begins with "slash" is never written as a command. The flag returned: it was.
fn write_joiners(text: &str, vocabulary: &str, commands: bool) -> (String, bool) {
    // The words and the gap before each one; `tail` is the whitespace after the last word.
    let mut words: Vec<&str> = Vec::new();
    let mut gaps: Vec<&str> = Vec::new();
    let mut index = 0usize;
    while let Some(offset) = text[index..].find(|c: char| !c.is_whitespace()) {
        let start = index + offset;
        let end = text[start..].find(char::is_whitespace).map_or(text.len(), |o| start + o);
        gaps.push(&text[index..start]);
        words.push(&text[start..end]);
        index = end;
    }
    let tail = &text[index..];
    let lower: Vec<String> = words.iter().map(|w| w.to_lowercase()).collect();
    let vocabulary = vocabulary.to_lowercase();
    // The person's own words: whole vocabulary entries ("Dash"), not a word inside one ("Polka Dot Studio").
    let own: Vec<&str> = vocabulary.split([',', '\n', '\r']).map(str::trim).collect();
    let spaces = |gap: &str| !gap.is_empty() && gap.chars().all(|c| c == ' ');
    let starts_word = |word: &str| word.chars().next().is_some_and(char::is_alphanumeric);
    let lead = |at: usize| -> String { words[at].chars().take_while(|c| c.is_alphabetic()).collect::<String>().to_lowercase() };
    // The word at `at` with its leading letters in lowercase, when those letters are one of `names` and no digit or
    // underscore follows them ("com", "com." and "com/docs", not "community" or "com2").
    let named = |at: usize, names: &[&str]| -> Option<String> {
        let letters: usize = words[at].chars().take_while(|c| c.is_alphabetic()).map(char::len_utf8).sum();
        let rest = &words[at][letters..];
        (names.contains(&lead(at).as_str()) && rest.chars().next().is_none_or(|c| !c.is_numeric() && c != '_')).then(|| format!("{}{rest}", lead(at)))
    };
    let mark = |at: usize| -> Option<&str> {
        let word = lower[at].as_str();
        (MARKS.contains(&word) && !own.contains(&word)).then_some(word)
    };
    let mut out = String::new();
    // The last word written so far, with what was joined onto it ("up-to").
    let mut written = String::new();
    // Whether the whole text can be one spoken command: "slash", a word, and nothing after it but more words
    // joined on by a mark ("slash code dash review"), all with single spaces between. A sentence that only begins
    // with "slash" ("Slash spending by half") is no command.
    let command_only = commands && words.len() >= 2 && words.len() % 2 == 0 && (1..words.len()).all(|at| {
        spaces(gaps[at]) && (at % 2 == 0) == ["dash", "hyphen", "underscore"].contains(&mark(at).unwrap_or("")) && (at % 2 == 0 || !MARKS.contains(&lead(at).as_str()))
    });
    let mut command = false;
    let mut i = 0usize;
    while i < words.len() {
        let Some(word) = mark(i) else {
            written = words[i].to_string();
            out.push_str(gaps[i]); out.push_str(words[i]);
            i += 1;
            continue;
        };
        let next = (i + 1 < words.len() && spaces(gaps[i + 1])).then_some(i + 1);
        if word == "dash" && next.is_some_and(|n| mark(n) == Some("dash")) {
            out.push_str(gaps[i]);
            if i + 2 < words.len() && spaces(gaps[i + 2]) && starts_word(words[i + 2]) && !MARKS.contains(&lead(i + 2).as_str()) {
                written = format!("--{}", words[i + 2]);
                out.push_str(&written);
                i += 3;
            } else {
                written = words[i + 1].to_string();
                out.push_str(words[i]); out.push_str(gaps[i + 1]); out.push_str(words[i + 1]);
                i += 2;
            }
            continue;
        }
        // The word before, as the ordinary words are listed: lowercase, a straight apostrophe, no opening quote.
        let before = written.to_lowercase().replace('’', "'");
        let before = before.trim_start_matches(|c: char| !c.is_alphanumeric());
        // Onto the word before: one space between them, and that word is no spoken mark itself.
        let joins = spaces(gaps[i]) && written.chars().next_back().is_some_and(char::is_alphanumeric) && !MARKS.contains(&before);
        let begins = i == 0 || spaces(gaps[i]);
        // Never before another spoken mark either ("with dash dash." stays words).
        if let Some(next) = next.filter(|&n| starts_word(words[n]) && !MARKS.contains(&lead(n).as_str())) {
            let after = lead(next);
            let after = after.as_str();
            let rest = words[next];
            let (mut joined, mut begun): (Option<String>, Option<String>) = (None, None);
            match word {
                "dot" => {
                    if joins && before == "www" { joined = Some(format!(".{rest}")); }
                    else if let (true, Some(end)) = (joins && !ORDINARY_BEFORE.contains(&before), named(next, ENDINGS)) { joined = Some(format!(".{end}")); }
                    else if let (true, Some(file)) = (begins && (!joins || ORDINARY_BEFORE.contains(&before) || DOT_FILE_BEFORE.contains(&before)), named(next, DOT_FILES)) { begun = Some(format!(".{file}")); }
                }
                "slash" => {
                    let address = written.contains(['.', '/']);
                    let numbers = written.chars().all(char::is_numeric) && rest.chars().next().is_some_and(char::is_numeric);
                    if joins && (address || numbers || (before == "and" && after == "or")) { joined = Some(format!("/{rest}")); }
                    else if spaces(gaps[i]) && SLASH_TYPED.contains(&before) && !after.is_empty() && !SLASH_AFTER.contains(&after) { begun = Some(format!("/{rest}")); }
                    // A dictation that is nothing but a command ("slash clear" → /clear), its ASCII letters in lowercase.
                    else if i == 0 && command_only && !after.is_empty() && !SLASH_AFTER.contains(&after) {
                        begun = Some(format!("/{}", rest.to_ascii_lowercase()));
                        command = true;
                    }
                }
                "underscore" => {
                    if joins && !UNDERSCORE_BEFORE.contains(&before) && !UNDERSCORE_AFTER.contains(&after) { joined = Some(format!("_{rest}")); }
                }
                _ => {
                    if joins && !ORDINARY_BEFORE.contains(&before) && !ORDINARY_AFTER.contains(&after) {
                        // One letter after a longer word that starts with a letter is an option of a command: "commit dash m"
                        // → commit -m ("10 dash K" and "x dash y" join), whatever mark the recognizer put after the letter.
                        let letter = after.chars().count() == 1 && after != "a" && after != "i"
                            && !rest.chars().skip_while(|c| c.is_alphabetic()).any(char::is_alphanumeric);
                        let command = before.chars().count() > 1 && before.chars().next().is_some_and(char::is_alphabetic);
                        if letter && command { begun = Some(format!("-{rest}")); } else { joined = Some(format!("-{rest}")); }
                    }
                }
            }
            if let Some(joined) = joined {
                written.push_str(&joined);
                out.push_str(&joined);
                i += 2;
                continue;
            }
            if let Some(begun) = begun {
                out.push_str(gaps[i]); out.push_str(&begun);
                written = begun;
                i += 2;
                continue;
            }
        }
        written = words[i].to_string();
        out.push_str(gaps[i]); out.push_str(words[i]);
        i += 1;
    }
    // The period a recognizer ends every dictation with is no part of a command ("/clear." is not one).
    if command && out.ends_with('.') && !out.ends_with("..") { out.pop(); }
    out.push_str(tail);
    (out, command)
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
            // Never the start of a "n't" contraction: a learned "won" → "Juan" must leave "won't" alone.
            if is_contraction_tail(&out[end..]) { continue; }
            let found = &out[start..end];
            if let Some(rule) = rules.iter().find(|r| r.phrase.to_lowercase() == found.to_lowercase()) {
                // A lowercase rule that only repeats the word ("claude" → "claude") would just lower its capitals.
                if rule.replacement == rule.replacement.to_lowercase() && rule.replacement.to_lowercase() == found.to_lowercase() { continue; }
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
