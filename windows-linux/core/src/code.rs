//! Developer dictation, identical to the Mac app's CodeDictation (shared fixtures):
//! spoken casing ("camel case user name" → userName) and symbols ("file dot swift" → file.swift).

#[derive(Clone, Copy)]
enum Casing { Camel, Pascal, Snake, Kebab, Constant, Upper, Lower }

const CASINGS: &[(&str, Casing)] = &[
    ("screaming snake case", Casing::Constant), ("camel case", Casing::Camel), ("pascal case", Casing::Pascal),
    ("snake case", Casing::Snake), ("kebab case", Casing::Kebab), ("constant case", Casing::Constant),
    ("all caps", Casing::Upper), ("lower case", Casing::Lower),
];

#[derive(Clone, Copy, PartialEq)]
enum Fit { Join, Prefix, Open, Close, Quote, Spaced }

const SYMBOLS: &[(&str, &str, Fit)] = &[
    ("open paren", "(", Fit::Open), ("close paren", ")", Fit::Close), ("open parenthesis", "(", Fit::Open), ("close parenthesis", ")", Fit::Close),
    ("open bracket", "[", Fit::Open), ("close bracket", "]", Fit::Close), ("open brace", "{", Fit::Open), ("close brace", "}", Fit::Close),
    ("open curly", "{", Fit::Open), ("close curly", "}", Fit::Close), ("open angle", "<", Fit::Open), ("close angle", ">", Fit::Close),
    ("fat arrow", "=>", Fit::Spaced), ("arrow", "->", Fit::Spaced), ("double equals", "==", Fit::Spaced), ("triple equals", "===", Fit::Spaced),
    ("not equals", "!=", Fit::Spaced), ("equals", "=", Fit::Spaced), ("plus equals", "+=", Fit::Spaced), ("greater than", ">", Fit::Spaced),
    ("less than", "<", Fit::Spaced), ("pipe", "|", Fit::Spaced), ("ampersand", "&", Fit::Spaced), ("asterisk", "*", Fit::Spaced),
    ("backslash", "\\", Fit::Join), ("slash", "/", Fit::Join), ("dot", ".", Fit::Join), ("underscore", "_", Fit::Join), ("double colon", "::", Fit::Join),
    ("dash", "-", Fit::Prefix), ("at sign", "@", Fit::Prefix), ("hash", "#", Fit::Prefix), ("dollar sign", "$", Fit::Prefix),
    ("tilde", "~", Fit::Prefix), ("bang", "!", Fit::Prefix), ("caret", "^", Fit::Join), ("percent sign", "%", Fit::Join),
    ("backtick", "`", Fit::Quote), ("single quote", "'", Fit::Quote), ("double quote", "\"", Fit::Quote),
];

fn tokenize(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    for c in text.chars() {
        if c.is_whitespace() {
            if !current.is_empty() { tokens.push(std::mem::take(&mut current)); }
        } else if ",.;:!?".contains(c) {
            if !current.is_empty() { tokens.push(std::mem::take(&mut current)); }
            tokens.push(c.to_string());
        } else {
            current.push(c);
        }
    }
    if !current.is_empty() { tokens.push(current); }
    tokens
}

fn matches(tokens: &[String], index: usize, phrase: &str) -> bool {
    let words: Vec<&str> = phrase.split(' ').collect();
    index + words.len() <= tokens.len() && tokens[index..index + words.len()].iter().zip(&words).all(|(t, w)| t.to_lowercase() == *w)
}

fn by_length<T: Copy>(items: &[(&'static str, T)]) -> Vec<(&'static str, T)> {
    let mut sorted = items.to_vec();
    sorted.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
    sorted
}

fn format(words: &[String], casing: Casing) -> String {
    let cap = |w: &String| { let mut c = w.chars(); c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default() };
    match casing {
        Casing::Camel => words[0].clone() + &words[1..].iter().map(cap).collect::<String>(),
        Casing::Pascal => words.iter().map(cap).collect(),
        Casing::Snake => words.join("_"),
        Casing::Kebab => words.join("-"),
        Casing::Constant => words.iter().map(|w| w.to_uppercase()).collect::<Vec<_>>().join("_"),
        Casing::Upper => words.iter().map(|w| w.to_uppercase()).collect::<Vec<_>>().join(" "),
        Casing::Lower => words.join(" "),
    }
}

fn apply_casing(tokens: Vec<String>) -> Vec<String> {
    let casings = by_length(CASINGS);
    let mut out = Vec::new();
    let mut i = 0;
    while i < tokens.len() {
        let Some(&(phrase, casing)) = casings.iter().find(|(p, _)| matches(&tokens, i, p)) else {
            out.push(tokens[i].clone()); i += 1; continue;
        };
        i += phrase.split(' ').count();
        let mut words = Vec::new();
        while i < tokens.len()
            && tokens[i].chars().next().is_some_and(|c| c.is_alphanumeric())
            && !CASINGS.iter().any(|(p, _)| matches(&tokens, i, p))
            && !SYMBOLS.iter().any(|(p, _, _)| matches(&tokens, i, p))
        {
            words.push(tokens[i].to_lowercase()); i += 1;
        }
        if words.is_empty() { continue; }
        out.push(format(&words, casing));
        if i < tokens.len() && tokens[i] == "." { i += 1; }
    }
    out
}

fn join_symbols(tokens: &[String]) -> String {
    let mut ordered = SYMBOLS.to_vec();
    ordered.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
    let mut out = String::new();
    let mut glue_next = false;
    let mut open_quotes: Vec<&str> = Vec::new();
    let trim = |out: &mut String| while out.ends_with(' ') { out.pop(); };
    let mut i = 0;
    while i < tokens.len() {
        if let Some(&(phrase, symbol, fit)) = ordered.iter().find(|(p, _, _)| matches(tokens, i, p)) {
            i += phrase.split(' ').count();
            if i < tokens.len() && (tokens[i] == "," || tokens[i] == ".") && fit != Fit::Close { i += 1; }
            let space = |out: &mut String, glue: bool| if !out.is_empty() && !out.ends_with(' ') && !glue { out.push(' ') };
            match fit {
                Fit::Join => { trim(&mut out); out.push_str(symbol); glue_next = true; }
                Fit::Prefix => { space(&mut out, glue_next); out.push_str(symbol); glue_next = true; }
                Fit::Open => {
                    if symbol == "(" || symbol == "[" { trim(&mut out) } else { space(&mut out, glue_next) }
                    out.push_str(symbol); glue_next = true;
                }
                Fit::Close => { trim(&mut out); out.push_str(symbol); glue_next = false; }
                Fit::Spaced => { trim(&mut out); if !out.is_empty() { out.push(' '); } out.push_str(symbol); out.push(' '); glue_next = true; }
                Fit::Quote => {
                    if let Some(pos) = open_quotes.iter().position(|q| *q == symbol) {
                        open_quotes.remove(pos); trim(&mut out); out.push_str(symbol); glue_next = false;
                    } else {
                        space(&mut out, glue_next); out.push_str(symbol); open_quotes.push(symbol); glue_next = true;
                    }
                }
            }
            continue;
        }
        let token = &tokens[i];
        if token.len() == 1 && ",.;:!?".contains(token.as_str()) { out.push_str(token); glue_next = false; i += 1; continue; }
        if !out.is_empty() && !out.ends_with(' ') && !glue_next { out.push(' '); }
        out.push_str(token); glue_next = false; i += 1;
    }
    trim(&mut out);
    out
}

pub fn code_dictation(text: &str) -> String {
    join_symbols(&apply_casing(tokenize(text)))
}
