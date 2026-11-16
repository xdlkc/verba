use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

pub fn default_data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("VERBA_DATA_DIR") {
        let p = PathBuf::from(dir);
        if !p.as_os_str().is_empty() {
            return p;
        }
    }
    home_dir().join("Library/Application Support/Verba")
}

pub fn default_loom_data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("MODEL_HUB_DATA_DIR") {
        let p = PathBuf::from(dir);
        if !p.as_os_str().is_empty() {
            return p;
        }
    }
    let mac = home_dir().join("Library/Application Support/ModelHub/.local");
    if mac.exists() {
        return mac;
    }
    let linux = home_dir().join(".local/share/ModelHub/.local");
    if linux.exists() {
        return linux;
    }
    mac
}

pub fn write_atomic(path: &Path, bytes: &[u8], mode_0600: bool) -> Result<()> {
    let parent = path.parent().ok_or("missing parent directory")?;
    fs::create_dir_all(parent)?;
    #[cfg(unix)]
    if mode_0600 {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = path.with_extension(format!("tmp-{stamp}-{}", std::process::id()));
    let mut opts = fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    if mode_0600 {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut file = opts.open(&tmp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(&tmp, path)?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct VocabEntry {
    pub word: String,
    #[serde(default)]
    pub heard: Vec<String>,
    #[serde(default = "default_vocab_source")]
    pub source: String,
    #[serde(default)]
    pub fixes: u32,
    #[serde(default)]
    pub used: Option<DateTime<Utc>>,
}

fn default_vocab_source() -> String {
    "user".to_string()
}

impl VocabEntry {
    pub fn key(s: &str) -> String {
        s.trim()
            .to_lowercase()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    }

    pub fn learnable(heard: &str, word: &str) -> Option<(String, String)> {
        let trim_edge = |c: char| c.is_whitespace() || is_punct_or_symbol(c);
        let h = heard.trim_matches(trim_edge);
        let w = word.trim_matches(trim_edge);
        if h.is_empty()
            || w.is_empty()
            || h.chars().count() > 20
            || w.chars().count() > 40
            || Self::key(h) == Self::key(w)
            || w.contains(h)
            || h.contains(w)
        {
            return None;
        }
        if h.chars().any(is_punct_or_symbol) {
            return None;
        }
        if w.chars().any(|c| is_punct_or_symbol(c) && c != '.' && c != '-') {
            return None;
        }
        Some((h.to_string(), w.to_string()))
    }
}

fn is_punct_or_symbol(c: char) -> bool {
    let u = c as u32;
    c.is_ascii_punctuation()
        || matches!(
            u,
            0x2000..=0x206F
                | 0x3000..=0x303F
                | 0xFF01..=0xFF0F
                | 0xFF1A..=0xFF20
                | 0xFF3B..=0xFF40
                | 0xFF5B..=0xFF65
        )
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    pub loom_url: String,
    pub loom_data_dir: String,
    pub translate_model: String,
    pub notes_model: String,
    pub source_lang: String,
    pub target_lang: String,
    pub notes_lang: String,
    pub loom_only: bool,
    pub draft_translate: bool,
    pub live_fix_enabled: bool,
    pub overlay_mode: String,
    pub overlay_hide_after: f64,
    pub notes_capturable: bool,
    pub export_enabled: bool,
    pub export_folder: String,
    pub vocabulary: Vec<VocabEntry>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            loom_url: "http://127.0.0.1:4319/v1".to_string(),
            loom_data_dir: String::new(),
            translate_model: String::new(),
            notes_model: String::new(),
            source_lang: "auto".to_string(),
            target_lang: "zh-CN".to_string(),
            notes_lang: "Simplified Chinese".to_string(),
            loom_only: true,
            draft_translate: true,
            live_fix_enabled: true,
            overlay_mode: "auto".to_string(),
            overlay_hide_after: 4.0,
            notes_capturable: false,
            export_enabled: false,
            export_folder: String::new(),
            vocabulary: Vec::new(),
        }
    }
}

impl AppSettings {
    pub fn resolved_loom_dir(&self) -> PathBuf {
        if self.loom_data_dir.trim().is_empty() {
            default_loom_data_dir()
        } else {
            PathBuf::from(self.loom_data_dir.trim())
        }
    }

    pub fn resolved_target(&self, source_code: Option<&str>) -> String {
        if let Some(src) = source_code
            && (src == self.target_lang || (src.starts_with("zh") && self.target_lang.starts_with("zh"))) {
                return if self.target_lang.starts_with("zh") {
                    "en".to_string()
                } else {
                    "zh-CN".to_string()
                };
            }
        self.target_lang.clone()
    }

    pub fn knows_vocab(&self, heard: &str, word: &str) -> bool {
        let h = VocabEntry::key(heard);
        let w = VocabEntry::key(word);
        self.vocabulary.iter().any(|entry| {
            VocabEntry::key(&entry.word) == w
                && entry.heard.iter().any(|x| VocabEntry::key(x) == h)
        })
    }

    pub fn confirm_vocab(&mut self, heard: &str, word: &str, source: &str) {
        if !heard.trim().is_empty() {
            let Some((h, w)) = VocabEntry::learnable(heard, word) else {
                return;
            };
            if source != "user" && crate::correction::is_plain_translation(&h, &w) {
                return;
            }
            self.add_vocab_entry(&h, &w, source);
        } else {
            let w = word.trim();
            if !w.is_empty() {
                self.add_vocab_entry("", w, source);
            }
        }
    }

    fn add_vocab_entry(&mut self, heard: &str, word: &str, source: &str) {
        let wk = VocabEntry::key(word);
        if let Some(existing) = self
            .vocabulary
            .iter_mut()
            .find(|e| VocabEntry::key(&e.word) == wk)
        {
            if !heard.is_empty()
                && !existing
                    .heard
                    .iter()
                    .any(|h| VocabEntry::key(h) == VocabEntry::key(heard))
            {
                existing.heard.push(heard.to_string());
            }
        } else {
            self.vocabulary.push(VocabEntry {
                word: word.to_string(),
                heard: if heard.is_empty() {
                    vec![]
                } else {
                    vec![heard.to_string()]
                },
                source: source.to_string(),
                fixes: 0,
                used: None,
            });
        }
    }

    pub fn mark_vocab_used(&mut self, word: &str) {
        let wk = VocabEntry::key(word);
        if let Some(entry) = self
            .vocabulary
            .iter_mut()
            .find(|e| VocabEntry::key(&e.word) == wk)
        {
            entry.fixes = entry.fixes.saturating_add(1);
            entry.used = Some(Utc::now());
        }
    }

    pub fn vocab_prompt_lines(&self) -> Vec<String> {
        let mut sorted = self.vocabulary.clone();
        sorted.sort_by_key(|a| std::cmp::Reverse(a.used));
        sorted
            .into_iter()
            .take(300)
            .map(|e| {
                if e.heard.is_empty() {
                    e.word
                } else {
                    format!("{} (heard as {})", e.word, e.heard.join(", "))
                }
            })
            .collect()
    }
}

pub fn load_settings(data_dir: &Path) -> AppSettings {
    let path = data_dir.join("settings.json");
    if let Ok(bytes) = fs::read(&path)
        && let Ok(mut settings) = serde_json::from_slice::<AppSettings>(&bytes) {
            let vocab_path = data_dir.join("vocabulary.json");
            if settings.vocabulary.is_empty()
                && let Ok(vb) = fs::read(&vocab_path)
                    && let Ok(v) = serde_json::from_slice::<Vec<VocabEntry>>(&vb) {
                        settings.vocabulary = v;
                    }
            return settings;
        }
    AppSettings::default()
}

pub fn save_settings(data_dir: &Path, settings: &AppSettings) -> Result<()> {
    let path = data_dir.join("settings.json");
    let json = serde_json::to_vec_pretty(settings)?;
    write_atomic(&path, &json, false)?;
    let vocab_path = data_dir.join("vocabulary.json");
    let vocab_json = serde_json::to_vec_pretty(&settings.vocabulary)?;
    write_atomic(&vocab_path, &vocab_json, false)?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ObsidianVault {
    pub name: String,
    pub path: String,
}

pub fn discover_obsidian_vaults() -> Vec<ObsidianVault> {
    let file = home_dir().join("Library/Application Support/obsidian/obsidian.json");
    let Ok(bytes) = fs::read(&file) else {
        return Vec::new();
    };
    parse_obsidian_vaults(&bytes, |p| Path::new(p).exists())
}

pub fn parse_obsidian_vaults<F>(json_bytes: &[u8], exists: F) -> Vec<ObsidianVault>
where
    F: Fn(&str) -> bool,
{
    let Ok(root) = serde_json::from_slice::<serde_json::Value>(json_bytes) else {
        return Vec::new();
    };
    let Some(vaults) = root.get("vaults").and_then(|v| v.as_object()) else {
        return Vec::new();
    };
    let mut rows: Vec<(f64, ObsidianVault)> = vaults
        .values()
        .filter_map(|v| {
            let path = v.get("path")?.as_str()?.to_string();
            if !exists(&path) {
                return None;
            }
            let ts = v.get("ts").and_then(|t| t.as_f64()).unwrap_or(0.0);
            let name = Path::new(&path)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("Vault")
                .to_string();
            Some((ts, ObsidianVault { name, path }))
        })
        .collect();
    rows.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    rows.into_iter().map(|(_, v)| v).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn settings_round_trip() {
        let dir = TempDir::new().unwrap();
        let mut s = AppSettings::default();
        s.confirm_vocab("莫拉", "Morpho", "user");
        s.translate_model = "zenmux/inclusionai/ling-3.1-flash".to_string();
        save_settings(dir.path(), &s).unwrap();
        let loaded = load_settings(dir.path());
        assert_eq!(loaded.translate_model, "zenmux/inclusionai/ling-3.1-flash");
        assert!(loaded.knows_vocab("莫拉", "Morpho"));
    }

    #[test]
    fn obsidian_vaults_sorted_newest_first() {
        let json = br#"{"vaults":{"a":{"path":"/tmp/v1","ts":100},"b":{"path":"/tmp/v2","ts":500},"c":{"path":"/tmp/missing","ts":999}}}"#;
        let out = parse_obsidian_vaults(json, |p| p != "/tmp/missing");
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].path, "/tmp/v2");
        assert_eq!(out[1].path, "/tmp/v1");
    }
}
