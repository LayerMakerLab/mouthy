//! Modes and settings, JSON-compatible with the Mac app's `Preferences`/`DictationMode`.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::text::{capitalize_first_word, Replacement};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum WritingMode {
    #[default]
    #[serde(rename = "Verbatim")]
    Verbatim,
    #[serde(rename = "Natural")]
    Natural,
    #[serde(rename = "Grammar")]
    Grammar,
    #[serde(rename = "Clean up")]
    CleanUp,
    #[serde(rename = "Concise")]
    Concise,
    #[serde(rename = "Custom")]
    Custom,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SpeechEngine {
    #[default]
    #[serde(rename = "Parakeet")]
    Parakeet,
    #[serde(rename = "Whisper")]
    Whisper,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum OutputAction {
    #[default]
    #[serde(rename = "Insert")]
    Insert,
    #[serde(rename = "Insert and press Return")]
    InsertAndReturn,
    #[serde(rename = "Copy to clipboard")]
    Clipboard,
    #[serde(rename = "History only")]
    HistoryOnly,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum MediaWhileDictating {
    #[default]
    #[serde(rename = "Leave playing")]
    Nothing,
    #[serde(rename = "Mute")]
    Mute,
    #[serde(rename = "Pause")]
    Pause,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct DictationMode {
    pub id: Uuid,
    pub name: String,
    pub writing_mode: WritingMode,
    pub instructions: String,
    pub engine: Option<SpeechEngine>,
    pub output: OutputAction,
    /// Executable names (Windows "slack.exe") or Linux app ids / window classes.
    pub apps: Vec<String>,
    pub websites: Vec<String>,
    pub trigger_word: String,
    /// Accelerator string such as "Ctrl+Alt+E".
    pub shortcut: Option<String>,
    pub include_context: bool,
    pub code_dictation: bool,
}

impl Default for DictationMode {
    fn default() -> Self {
        Self {
            id: Uuid::new_v4(),
            name: "Mode".into(),
            writing_mode: WritingMode::Verbatim,
            instructions: String::new(),
            engine: None,
            output: OutputAction::Insert,
            apps: vec![],
            websites: vec![],
            trigger_word: String::new(),
            shortcut: None,
            include_context: false,
            code_dictation: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub engine: SpeechEngine,
    pub whisper_model: String,
    /// "Ctrl+Alt+Space" etc.; "RightCtrl double-tap" style modifier gestures are handled by the app.
    pub shortcut: String,
    pub hold_to_talk: bool,
    pub auto_insert: bool,
    pub smart_formatting: bool,
    pub punctuation_commands: bool,
    pub media_while_dictating: MediaWhileDictating,
    pub play_sounds: bool,
    pub keep_history: bool,
    pub history_limit: usize,
    pub vocabulary: String,
    pub replacements: Vec<Replacement>,
    pub modes: Vec<DictationMode>,
    pub input_device: String,
    pub local_only: bool,
    pub remove_fillers: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            engine: SpeechEngine::Parakeet,
            whisper_model: "base.en".into(),
            shortcut: "Ctrl+Alt+Space".into(),
            hold_to_talk: false,
            auto_insert: true,
            smart_formatting: true,
            punctuation_commands: true,
            media_while_dictating: MediaWhileDictating::Nothing,
            play_sounds: false,
            keep_history: false,
            history_limit: 100,
            vocabulary: String::new(),
            replacements: vec![],
            modes: vec![],
            input_device: String::new(),
            local_only: false,
            remove_fillers: true,
        }
    }
}

fn host_of(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).or_else(|_| url::Url::parse(&format!("https://{url}"))).ok()?;
    parsed.host_str().map(|h| h.to_lowercase())
}

fn host_matches(host: &str, site: &str) -> bool {
    let mut site = host_of(site.trim()).unwrap_or_else(|| site.trim().to_lowercase());
    if let Some(stripped) = site.strip_prefix("www.") {
        site = stripped.to_string();
    }
    !site.is_empty() && (host == site || host.ends_with(&format!(".{site}")))
}

/// Mode priority at start: mode shortcut, website, app (the trigger word is resolved at the end).
pub fn start_mode<'a>(modes: &'a [DictationMode], shortcut_mode: Option<Uuid>, url: Option<&str>, app: &str) -> Option<&'a DictationMode> {
    if let Some(id) = shortcut_mode {
        if let Some(mode) = modes.iter().find(|m| m.id == id) {
            return Some(mode);
        }
    }
    if let Some(host) = url.and_then(host_of) {
        if let Some(mode) = modes.iter().find(|m| m.websites.iter().any(|s| host_matches(&host, s))) {
            return Some(mode);
        }
    }
    let app = app.to_lowercase();
    if !app.is_empty() {
        return modes.iter().find(|m| m.apps.iter().any(|a| a.to_lowercase() == app));
    }
    None
}

/// The mode whose trigger word opens the transcript, and the transcript without it.
pub fn trigger<'a>(text: &str, modes: &'a [DictationMode]) -> Option<(&'a DictationMode, String)> {
    let trimmed = text.trim();
    let mut sorted: Vec<&DictationMode> = modes.iter().collect();
    sorted.sort_by(|a, b| b.trigger_word.chars().count().cmp(&a.trigger_word.chars().count()));
    for mode in sorted {
        let word = mode.trigger_word.trim();
        if word.is_empty() || trimmed.len() < word.len() || !trimmed.is_char_boundary(word.len()) {
            continue;
        }
        if trimmed[..word.len()].to_lowercase() != word.to_lowercase() {
            continue;
        }
        let rest = &trimmed[word.len()..];
        if rest.chars().next().is_some_and(|c| c.is_alphanumeric()) {
            continue;
        }
        let rest = rest.trim_start_matches(|c: char| c.is_whitespace() || ",.:;!?".contains(c));
        return Some((mode, capitalize_first_word(rest)));
    }
    None
}
