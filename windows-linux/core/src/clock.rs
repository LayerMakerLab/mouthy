//! Clock times the recognizer wrote as anything but "11:58": with a period ("at 3.30"), run together ("at 1158",
//! "6 45 pm") or in words ("at eleven fifty-eight", "ten oh five p.m."). Only where the text says it is a time: after a
//! word that introduces one, or before a.m./p.m., and never before a unit, so prices, counts and measurements keep
//! their form. Same rules as `ClockTimes.swift`, word by word because the `regex` crate has no lookaround.

use regex::Regex;
use std::sync::OnceLock;

const UNITS: &[&str] = &["%", "percent", "dollar", "dollars", "euro", "euros", "pound", "pounds", "cent", "cents", "each",
    "apiece", "per", "kg", "km", "mm", "cm", "mile", "miles", "meter", "meters", "metre", "metres", "inch", "inches", "feet",
    "times", "people", "item", "items", "minute", "minutes", "hour", "hours", "second", "seconds", "day", "days", "year", "years"];
const ONES: &[&str] = &["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];
const HOURS: &[&str] = &["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"];
const TEENS: &[&str] = &["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"];
const TENS: &[&str] = &["twenty", "thirty", "forty", "fifty"];
/// Cues for "3.30"; run-together digits ("1158") only after the first three ("by 150" is usually a count).
const DIGIT_CUES: &[&str] = &["at", "until", "till", "by", "before", "after", "around"];
const WORD_CUES: &[&str] = &["at", "until", "till", "by", "before", "after", "around", "about", "from", "it's", "it’s"];
/// Words after which a bare "am" is a.m. ("at six am"), unlike "which one am I".
const AM_CUES: &[&str] = &["at", "until", "till", "by", "before", "after", "around", "about", "from"];

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex { cell.get_or_init(|| Regex::new(pattern).unwrap()) }
fn period() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); re(&R, r"^(1[0-2]|0?[1-9])\.([0-5][0-9])$") }
fn run_together() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); re(&R, r"^(1[0-2]|[1-9])(0[1-9]|[1-5][0-9])$") }
fn joined() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); re(&R, r"^(1[0-2]|[1-9])\.?([0-5][0-9])$") }
fn before_meridiem() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"(?i)^(1[0-2]|0?[1-9])\.?([0-5][0-9])((?:a|p)\.?m\.?[.,!?;:]*)?$")
}
fn hour_only() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); re(&R, r"^(1[0-2]|0?[1-9])$") }
fn minutes_only() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); re(&R, r"^[0-5][0-9]$") }
fn attached() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"(?i)^((?:1[0-2]|0?[1-9])(?::[0-5][0-9])?)([ap])\.?m\.?([.,!?;:]*)$")
}
fn meridiem() -> &'static Regex { static R: OnceLock<Regex> = OnceLock::new(); re(&R, r"(?i)^(?:a|p)\.?m\.?[.,!?;:]*$") }

/// A token's word and the punctuation after it ("1158." -> "1158", ".").
fn split(token: &str) -> (&str, &str) {
    let core = token.trim_end_matches(|c: char| ".,!?;:".contains(c));
    (core, &token[core.len()..])
}
fn lower(tokens: &[&str], i: usize) -> String { tokens.get(i).map(|t| split(t).0.to_lowercase()).unwrap_or_default() }
fn is_unit(tokens: &[&str], i: usize) -> bool {
    let word = lower(tokens, i);
    UNITS.contains(&word.as_str()) || (word == "a" && lower(tokens, i + 1) == "piece")
}
fn digit(word: &str) -> Option<u32> { ONES.iter().position(|w| *w == word).map(|i| i as u32 + 1) }

/// An hour and its minutes in words starting at `k`: (hour, minute, index of the last word).
fn spoken(tokens: &[&str], k: usize) -> Option<(u32, u32, usize)> {
    let (hour_word, trail) = split(tokens.get(k)?);
    let hour = HOURS.iter().position(|w| *w == hour_word.to_lowercase())? as u32 + 1;
    if !trail.is_empty() { return None; }
    let (next, next_trail) = split(tokens.get(k + 1)?);
    let next = next.to_lowercase();
    if next == "oh" && next_trail.is_empty() { return digit(&lower(tokens, k + 2)).map(|m| (hour, m, k + 2)); }
    if let Some(i) = TEENS.iter().position(|w| *w == next) { return Some((hour, 10 + i as u32, k + 1)); }
    if let Some((tens, ones)) = next.split_once('-') {
        let t = TENS.iter().position(|w| *w == tens)? as u32;
        return digit(ones).map(|o| (hour, 20 + 10 * t + o, k + 1));
    }
    let t = TENS.iter().position(|w| *w == next)? as u32;
    match digit(&lower(tokens, k + 2)) {
        Some(o) if next_trail.is_empty() => Some((hour, 20 + 10 * t + o, k + 2)),
        _ => Some((hour, 20 + 10 * t, k + 1)),
    }
}
/// Nothing that makes the time part of a bigger number or an amount follows the word at `end`.
fn ends_cleanly(tokens: &[&str], end: usize, check_unit: bool) -> bool {
    if !split(tokens[end]).1.is_empty() { return true; }
    let next = lower(tokens, end + 1);
    !(ONES.contains(&next.as_str()) || next == "hundred" || next == "thousand" || (check_unit && is_unit(tokens, end + 1)))
}

/// Years the recognizer wrote in words: "twenty nineteen" -> "2019", "nineteen ninety-eight" -> "1998", "nineteen oh
/// five" -> "1905", "nineteen hundred" -> "1900", "two thousand nine" -> "2009". Never inside a longer run of numbers or
/// before a unit. Same rules as `SpokenYears.swift`.
const YEAR_TENS: &[&str] = &["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];
const CENTURIES: &[(&str, u32)] = &[("eighteen", 18), ("nineteen", 19), ("twenty", 20)];
fn number_word(word: &str) -> bool {
    ONES.contains(&word) || TEENS.contains(&word) || YEAR_TENS.contains(&word)
        || ["hundred", "thousand", "million", "oh", "zero"].contains(&word)
}
fn teen(word: &str) -> Option<u32> { TEENS.iter().position(|w| *w == word).map(|i| i as u32 + 10) }
fn ten(word: &str) -> Option<u32> { YEAR_TENS.iter().position(|w| *w == word).map(|i| i as u32 * 10 + 20) }

/// A token as (what comes before the word, the word: letters and hyphens, what follows it): "(nineteen" ->
/// ("(", "nineteen", ""), "eight)." -> ("", "eight", ").").
fn year_parts(token: &str) -> (&str, &str, &str) {
    let start = token.find(|c: char| c.is_alphanumeric()).unwrap_or(token.len());
    let word_len = token[start..].find(|c: char| !(c.is_alphabetic() || c == '-')).unwrap_or(token.len() - start);
    (&token[..start], &token[start..start + word_len], &token[start + word_len..])
}

pub fn spoken_years(text: &str) -> String {
    let tokens: Vec<&str> = text.split(' ').collect();
    let pieces: Vec<(&str, &str, &str)> = tokens.iter().map(|t| year_parts(t)).collect();
    // Every word part (hyphens split), with its token and whether it ends that token.
    let mut parts: Vec<(String, usize, bool)> = Vec::new();
    for (t, (_, word, _)) in pieces.iter().enumerate() {
        let split: Vec<&str> = word.split('-').collect();
        let n = split.len();
        for (k, piece) in split.into_iter().enumerate() { parts.push((piece.to_lowercase(), t, k + 1 == n)); }
    }
    let word = |k: usize| parts.get(k).map(|p| p.0.as_str()).unwrap_or("");
    let mut out: Vec<String> = Vec::with_capacity(tokens.len());
    let (mut t, mut k) = (0, 0);
    while t < tokens.len() {
        while k < parts.len() && parts[k].1 < t { k += 1; }
        let (lead, core, _) = pieces[t];
        let starts = !core.is_empty() && !lead.ends_with(['\'', '’', '-']) && k < parts.len() && parts[k].1 == t;
        let after_number = t > 0 && lead.is_empty() && pieces[t - 1].2.is_empty()
            && number_word(&pieces[t - 1].1.rsplit('-').next().unwrap_or("").to_lowercase());
        let mut found: Option<(u32, usize)> = None; // (year, last part)
        if starts && !after_number {
            if let Some(&(_, century)) = CENTURIES.iter().find(|(w, _)| *w == word(k)) {
                let rest = if let Some(tens) = ten(word(k + 1)) {
                    match digit(word(k + 2)) { Some(one) => Some((tens + one, k + 2)), None => Some((tens, k + 1)) }
                } else if let Some(t) = teen(word(k + 1)) { Some((t, k + 1)) }
                else if word(k + 1) == "oh" { digit(word(k + 2)).map(|one| (one, k + 2)) }
                // "eighteen hundred and fifty" is a number, not a year.
                else if word(k + 1) == "hundred" && word(k + 2) != "and" { Some((0, k + 1)) } else { None };
                found = rest.map(|(r, end)| (century * 100 + r, end));
            } else if word(k) == "two" && word(k + 1) == "thousand" {
                let s = if word(k + 2) == "and" { k + 3 } else { k + 2 };
                found = if let Some(tens) = ten(word(s)) {
                    match digit(word(s + 1)) { Some(one) => Some((2000 + tens + one, s + 1)), None => Some((2000 + tens, s)) }
                } else if let Some(t) = teen(word(s)) { Some((2000 + t, s)) }
                else { digit(word(s)).map(|one| (2000 + one, s)) };
            }
        }
        if let Some((year, end)) = found {
            let last = parts.get(end).map(|p| p.1);
            // Whole tokens only, nothing between the words, and no apostrophe, number word or unit right after.
            let ok = end < parts.len() && parts[end].2 && last.is_some_and(|last| {
                (t..last).all(|i| pieces[i].2.is_empty()) && (t + 1..=last).all(|i| pieces[i].0.is_empty())
                    && !pieces[last].2.starts_with(['\'', '’']) && !pieces[last].2.starts_with(|c: char| c.is_alphanumeric())
                    && (!pieces[last].2.is_empty() || (!number_word(word(end + 1)) && !is_unit(&tokens, last + 1)))
            });
            if ok {
                let last = last.unwrap();
                out.push(format!("{lead}{year}{}", pieces[last].2));
                t = last + 1;
                continue;
            }
        }
        out.push(tokens[t].to_string());
        t += 1;
    }
    out.join(" ")
}

pub fn clock_times(text: &str) -> String {
    let years = spoken_years(text);
    let tokens: Vec<&str> = years.split(' ').collect();
    let mut out: Vec<String> = Vec::with_capacity(tokens.len());
    let mut i = 0;
    while i < tokens.len() {
        let (word, trail) = split(tokens[i]);
        let word = word.to_lowercase();
        let it_is = trail.is_empty() && (word == "it's" || word == "it’s" || (word == "it" && lower(&tokens, i + 1) == "is"
            && split(tokens.get(i + 1).unwrap_or(&"")).1.is_empty()));
        let cue_end = if word == "it" { i + 1 } else { i };
        let cue = trail.is_empty() && (DIGIT_CUES.contains(&word.as_str()) || WORD_CUES.contains(&word.as_str()) || it_is);
        if cue {
            let n = cue_end + 1;
            if let Some(token) = tokens.get(n) {
                let (core, num_trail) = split(token);
                let unit_free = !num_trail.is_empty() || !is_unit(&tokens, n + 1);
                let digits = if DIGIT_CUES.contains(&word.as_str()) {
                    period().captures(core).filter(|_| unit_free)
                        .or_else(|| run_together().captures(core).filter(|_| unit_free && ["at", "until", "till"].contains(&word.as_str())))
                } else { None };
                if let Some(c) = digits {
                    out.extend(tokens[i..n].iter().map(|t| t.to_string()));
                    out.push(format!("{}:{}{}", &c[1], &c[2], num_trail));
                    i = n + 1;
                    continue;
                }
                if it_is {
                    // "it's 1158." / "it's 12 30 right now": a time that closes the clause.
                    // Run together, never :00 ("it's 100." is a count).
                    let found = joined().captures(core).filter(|c| core.contains('.') || &c[2] != "00")
                        .map(|c| (c[1].to_string(), c[2].to_string(), n, num_trail)).or_else(|| {
                        let (minutes, t) = split(tokens.get(n + 1)?);
                        (num_trail.is_empty() && hour_only().is_match(core) && !core.starts_with('0')
                            && minutes_only().is_match(minutes)).then(|| (core.to_string(), minutes.to_string(), n + 1, t))
                    });
                    if let Some((h, m, end, t)) = found {
                        let next = lower(&tokens, end + 1);
                        let closes = t.starts_with(|c: char| ".,!?;".contains(c)) || (t.is_empty() && (end + 1 == tokens.len()
                            || next == "now" || (next == "right" && lower(&tokens, end + 2) == "now")));
                        if closes {
                            out.extend(tokens[i..n].iter().map(|t| t.to_string()));
                            out.push(format!("{h}:{m}{t}"));
                            i = end + 1;
                            continue;
                        }
                    }
                }
                if WORD_CUES.contains(&word.as_str()) || it_is {
                    if let Some((h, m, end)) = spoken(&tokens, n) {
                        if ends_cleanly(&tokens, end, true) {
                            out.extend(tokens[i..n].iter().map(|t| t.to_string()));
                            out.push(format!("{h}:{m:02}{}", split(tokens[end]).1));
                            i = end + 1;
                            continue;
                        }
                    }
                }
            }
        }
        // Before a.m./p.m.: "645 p.m.", "6 45 pm", "645pm", "six forty-five a.m."; words also before o'clock.
        if let Some(c) = before_meridiem().captures(tokens[i]) {
            if c.get(3).is_some() || meridiem().is_match(tokens.get(i + 1).unwrap_or(&"")) {
                let suffix = c.get(3).map_or("", |m| m.as_str());
                // A whole hour run together is just the hour: "100 p.m." -> "1 p.m.", "1000 a.m." -> "10 a.m.".
                let whole = &c[2] == "00" && !tokens[i].contains('.') && !c[1].starts_with('0');
                out.push(if whole { format!("{}{suffix}", &c[1]) } else { format!("{}:{}{suffix}", &c[1], &c[2]) });
                i += 1;
                continue;
            }
        }
        if hour_only().is_match(tokens[i]) {
            if let Some(m) = tokens.get(i + 1).filter(|t| minutes_only().is_match(t)) {
                if meridiem().is_match(tokens.get(i + 2).unwrap_or(&"")) {
                    out.push(format!("{}:{}", tokens[i], m));
                    i += 2;
                    continue;
                }
            }
        }
        if let Some((h, m, end)) = spoken(&tokens, i) {
            let next = tokens.get(end + 1).unwrap_or(&"");
            let oclock = { let w = split(next).0.to_lowercase(); w == "o'clock" || w == "o’clock" };
            if split(tokens[end]).1.is_empty() && (meridiem().is_match(next) || oclock) {
                out.push(format!("{h}:{m:02}"));
                i = end + 1;
                continue;
            }
        }
        // A spoken hour on its own is a time only with a.m./p.m. or o'clock after it ("ten a.m." -> "10 a.m."); "at one",
        // "one idea" and "one, two, three" stay words. A bare "am" counts only after a word that introduces a time or
        // before punctuation, so "which one am I" stays.
        let (hour_word, hour_trail) = split(tokens[i]);
        if let Some(h) = HOURS.iter().position(|w| *w == hour_word.to_lowercase()).filter(|_| hour_trail.is_empty()) {
            let next = tokens.get(i + 1).unwrap_or(&"");
            let (next_word, next_trail) = split(next);
            let next_word = next_word.to_lowercase();
            let bare_am = next_word == "am";
            let after_cue = i > 0 && { let (w, t) = split(tokens[i - 1]); t.is_empty() && AM_CUES.contains(&w.to_lowercase().as_str()) };
            let marked = next_word == "o'clock" || next_word == "o’clock" || (!bare_am && meridiem().is_match(next))
                || (bare_am && (after_cue || next_trail.starts_with(|c: char| ".,!?;".contains(c)) || (next_trail.is_empty() && i + 2 == tokens.len())));
            if marked {
                out.push(format!("{}", h + 1));
                i += 1;
                continue;
            }
        }
        out.push(tokens[i].to_string());
        i += 1;
    }
    // "10am", "6:45PM." -> "10 a.m.", "6:45 p.m.": one way of writing a.m./p.m. whatever the recognizer chose.
    out.iter().map(|token| match attached().captures(token) {
        Some(c) => format!("{} {}.m.{}", &c[1], c[2].to_lowercase(), &c[3]),
        None => token.clone(),
    }).collect::<Vec<_>>().join(" ")
}
