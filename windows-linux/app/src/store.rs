//! Settings and optional history, stored as JSON in the user's config directory.
//! Unreadable files are preserved (renamed) instead of overwritten.

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::path::{Path, PathBuf};
use mouthy_core::Settings;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntry {
    pub id: String,
    pub date: u64,
    pub raw: String,
    pub text: String,
    pub app: String,
    pub mode: String,
    pub seconds: f32,
}

/// App settings beyond the shared core settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct AppSettings {
    #[serde(flatten)]
    pub core: Settings,
    pub whisper_language: String,
    pub writing_mode: mouthy_core::WritingMode,
    pub custom_instructions: String,
    pub ollama_model: String,
    pub agent_voice: bool,
    pub launch_at_login: bool,
    pub show_overlay: bool,
    /// "Automatic" style: tap toggles, a long press records until release.
    pub automatic_activation: bool,
    /// Folder holding "Mouthy Sync.json", shared with other machines (empty = off).
    pub sync_folder: String,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            core: Settings::default(),
            whisper_language: "auto".into(),
            writing_mode: mouthy_core::WritingMode::Verbatim,
            custom_instructions: "Preserve my wording and organize it into clear paragraphs.".into(),
            ollama_model: String::new(),
            agent_voice: true,
            launch_at_login: false,
            show_overlay: true,
            automatic_activation: false,
            sync_folder: String::new(),
        }
    }
}

/// Local usage counts (no text): words, sessions and speaking time.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct UsageStats { pub words: u64, pub sessions: u64, pub speaking_seconds: f64 }

impl UsageStats {
    pub fn record(&mut self, text: &str, seconds: f64) {
        let words = text.split_whitespace().count() as u64;
        if words == 0 { return; }
        self.words += words; self.sessions += 1; self.speaking_seconds += seconds.max(0.0);
    }
}

/// Merges "Mouthy Sync.json" in the sync folder with these settings (vocabulary and replacements; the
/// Mac-only modes in the file are preserved) and writes the union back. Returns true if settings changed.
pub fn sync(settings: &mut AppSettings) -> Result<bool, String> {
    if settings.sync_folder.trim().is_empty() { return Ok(false); }
    let file = PathBuf::from(&settings.sync_folder).join("Mouthy Sync.json");
    let mut doc: serde_json::Value = match std::fs::read(&file) {
        Ok(data) => serde_json::from_slice(data.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&data)).map_err(|e| format!("Sync file unreadable, left untouched: {e}"))?,
        Err(_) => serde_json::json!({"version": 1, "vocabulary": [], "replacements": [], "macModes": []}),
    };
    let mut words: Vec<String> = settings.core.vocabulary.split([',', '\n']).map(|w| w.trim().to_string()).filter(|w| !w.is_empty()).collect();
    let before = (words.clone(), settings.core.replacements.clone());
    for word in doc["vocabulary"].as_array().cloned().unwrap_or_default().iter().filter_map(|w| w.as_str()) {
        if !words.iter().any(|w| w.eq_ignore_ascii_case(word)) { words.push(word.to_string()); }
    }
    for rule in doc["replacements"].as_array().cloned().unwrap_or_default() {
        let (Some(phrase), Some(replacement)) = (rule["phrase"].as_str(), rule["replacement"].as_str()) else { continue };
        if !settings.core.replacements.iter().any(|r| r.phrase.eq_ignore_ascii_case(phrase)) {
            settings.core.replacements.push(mouthy_core::Replacement { phrase: phrase.into(), replacement: replacement.into() });
        }
    }
    let changed = before != (words.clone(), settings.core.replacements.clone());
    settings.core.vocabulary = words.join("\n");
    doc["version"] = 1.into();
    doc["vocabulary"] = serde_json::json!(words);
    let existing: Vec<serde_json::Value> = doc["replacements"].as_array().cloned().unwrap_or_default();
    doc["replacements"] = serde_json::Value::Array(settings.core.replacements.iter().map(|r| {
        let id = existing.iter().find(|e| e["phrase"].as_str().is_some_and(|p| p.eq_ignore_ascii_case(&r.phrase))).and_then(|e| e["id"].as_str().map(String::from))
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string().to_uppercase());
        serde_json::json!({"id": id, "phrase": r.phrase, "replacement": r.replacement})
    }).collect());
    if doc.get("macModes").is_none() { doc["macModes"] = serde_json::json!([]); }
    write_atomic(&file, &serde_json::to_vec_pretty(&doc).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    Ok(changed)
}

pub fn dir() -> PathBuf {
    dirs::config_dir().unwrap_or_else(std::env::temp_dir).join("Mouthy")
}

pub fn load<T: DeserializeOwned + Default>(name: &str) -> T {
    let path = dir().join(name);
    let Ok(data) = std::fs::read(&path) else { return T::default() };
    // Windows editors and PowerShell often prepend a UTF-8 byte-order mark.
    let data = data.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&data);
    match serde_json::from_slice(data) {
        Ok(value) => value,
        Err(_) => {
            let _ = std::fs::rename(&path, path.with_extension("unreadable.json"));
            T::default()
        }
    }
}

pub fn save<T: Serialize>(name: &str, value: &T) -> std::io::Result<()> {
    private_dir(&dir())?;
    write_atomic(&dir().join(name), &serde_json::to_vec_pretty(value)?)
}

/// Creates a folder only this user can open (on Windows the per-user profile folders already are).
pub fn private_dir(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    { use std::os::unix::fs::PermissionsExt; std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?; }
    Ok(())
}

/// Replaces `path` through a new, randomly named owner-only temporary file next to it. Creating it
/// exclusively means a planted file or symlink with that name is never followed.
pub fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = path.with_file_name(format!(".{name}.{}.tmp", uuid::Uuid::new_v4().simple()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
    let result = options.open(&tmp).and_then(|mut file| { file.write_all(data)?; file.sync_all() }).and_then(|_| std::fs::rename(&tmp, path));
    if result.is_err() { let _ = std::fs::remove_file(&tmp); }
    result
}

/// The secret shared by Mouthy and its MCP bridge, readable only by this user. Requests and replies are
/// signed with it, so other accounts on this computer can neither ask questions nor impersonate Mouthy.
pub fn agent_token() -> std::io::Result<String> {
    let path = dir().join("agent-token");
    if let Ok(token) = std::fs::read_to_string(&path) {
        if token.trim().len() >= 32 { return Ok(token.trim().to_string()); }
    }
    private_dir(&dir())?;
    let token = format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple());
    write_atomic(&path, token.as_bytes())?;
    Ok(token)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sync_merges_and_keeps_mac_modes() {
        let folder = std::env::temp_dir().join(format!("mouthy-sync-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join("Mouthy Sync.json"), r#"{"version":1,"vocabulary":["Zephyr"],"replacements":[{"id":"A1B2C3D4-0000-0000-0000-000000000000","phrase":"sig","replacement":"Thank you"}],"macModes":[{"name":"Code"}]}"#).unwrap();
        let mut settings = AppSettings { sync_folder: folder.to_string_lossy().into(), ..Default::default() };
        settings.core.vocabulary = "Nimbus".into();
        assert!(sync(&mut settings).unwrap());
        assert_eq!(settings.core.vocabulary, "Nimbus\nZephyr");
        assert_eq!(settings.core.replacements[0].phrase, "sig");
        let doc: serde_json::Value = serde_json::from_slice(&std::fs::read(folder.join("Mouthy Sync.json")).unwrap()).unwrap();
        assert_eq!(doc["macModes"][0]["name"], "Code");
        assert_eq!(doc["replacements"][0]["id"], "A1B2C3D4-0000-0000-0000-000000000000");
        assert!(!sync(&mut settings).unwrap());
        std::fs::write(folder.join("Mouthy Sync.json"), "not json").unwrap();
        assert!(sync(&mut settings).is_err());
        assert_eq!(std::fs::read_to_string(folder.join("Mouthy Sync.json")).unwrap(), "not json");
        let _ = std::fs::remove_dir_all(folder);
    }
    #[cfg(unix)]
    #[test]
    fn private_files_are_owner_only_and_never_follow_symlinks() {
        use std::os::unix::fs::PermissionsExt;
        let folder = std::env::temp_dir().join(format!("mouthy-private-{}", uuid::Uuid::new_v4()));
        private_dir(&folder).unwrap();
        assert_eq!(std::fs::metadata(&folder).unwrap().permissions().mode() & 0o777, 0o700);
        let victim = folder.join("victim");
        std::fs::write(&victim, "keep").unwrap();
        std::os::unix::fs::symlink(&victim, folder.join("Mouthy Sync.json.tmp")).unwrap();
        let file = folder.join("Mouthy Sync.json");
        write_atomic(&file, b"{}").unwrap();
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        let _ = std::fs::remove_dir_all(folder);
    }
}
