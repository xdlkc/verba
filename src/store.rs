use crate::config::{Result, write_atomic};
use crate::correction;
use chrono::{DateTime, Local, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LineFix {
    pub from: String,
    pub to: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ask: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub off: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<bool>,
}

impl LineFix {
    pub fn is_applied(&self) -> bool {
        self.ask != Some(true) && self.off != Some(true)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptLine {
    pub id: String,
    pub t: f64,
    pub speaker: String,
    pub src: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dst: Option<String>,
    pub src_lang: String,
    pub dst_lang: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voice: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fixes: Option<Vec<LineFix>>,
}

impl TranscriptLine {
    pub fn shown(&self) -> String {
        match &self.fixes {
            Some(fixes) if !fixes.is_empty() => correction::apply_fixes(fixes, &self.src).0,
            _ => self.src.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct FishboneBranch {
    pub label: String,
    pub detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub t: Option<f64>,
    pub support: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Fishbone {
    pub question: String,
    pub branches: Vec<FishboneBranch>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct NoteTopic {
    pub start: f64,
    pub title: String,
    pub summary: String,
    pub points: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fishbone: Option<Fishbone>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub point_times: Option<Vec<Option<f64>>>,
}

impl NoteTopic {
    pub fn point_time(&self, idx: usize) -> Option<f64> {
        self.point_times
            .as_ref()
            .and_then(|v| v.get(idx))
            .copied()
            .flatten()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct NoteItem {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    pub support: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub t: Option<f64>,
}

impl NoteItem {
    pub fn with_owner(&self) -> String {
        match &self.owner {
            Some(o) if !o.trim().is_empty() => format!("{}（{}）", self.text, o),
            _ => self.text.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct NoteTerm {
    pub name: String,
    pub note: String,
    pub heard: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct MeetingNotes {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub summary: String,
    pub topics: Vec<NoteTopic>,
    pub conclusions: Vec<NoteItem>,
    pub todos: Vec<NoteItem>,
    pub terms: Vec<NoteTerm>,
    pub covered: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(rename = "final")]
    pub is_final: bool,
}

impl MeetingNotes {
    pub fn is_empty(&self) -> bool {
        self.summary.is_empty() && self.topics.is_empty()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub id: String,
    pub title: String,
    pub started_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub lines: Vec<TranscriptLine>,
    #[serde(default)]
    pub has_audio: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<MeetingNotes>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub renamed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voice_names: Option<HashMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub importing: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<bool>,
}

impl Session {
    pub fn default_title(dt: DateTime<Utc>) -> String {
        let local = dt.with_timezone(&Local);
        format!("会议 {}", local.format("%-m月%-d日 %H:%M"))
    }

    pub fn display_title(&self) -> String {
        let explicitly_renamed = self.renamed.unwrap_or_else(|| !self.title.starts_with("会议 "));
        if explicitly_renamed {
            return self.title.clone();
        }
        if let Some(notes) = &self.notes
            && let Some(name) = &notes.title
                && !name.trim().is_empty() {
                    let local = self.started_at.with_timezone(&Local);
                    let now = Local::now();
                    let date_part = if local.format("%Y").to_string() == now.format("%Y").to_string() {
                        local.format("%-m月%-d日").to_string()
                    } else {
                        local.format("%Y年%-m月%-d日").to_string()
                    };
                    return format!("{date_part} {name}");
                }
        if let Some(file) = &self.source_file {
            return Path::new(file)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or(file)
                .to_string();
        }
        self.title.clone()
    }

    pub fn duration_seconds(&self) -> f64 {
        let end = self.ended_at.unwrap_or_else(Utc::now);
        (end - self.started_at).num_milliseconds().max(0) as f64 / 1000.0
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub id: String,
    pub title: String,
    pub display_title: String,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub duration_seconds: f64,
    pub line_count: usize,
    pub has_audio: bool,
    pub has_notes: bool,
    pub importing: bool,
    pub source_file: Option<String>,
    pub room: bool,
    pub language_pair: Option<String>,
}

impl SessionSummary {
    pub fn from_session(s: &Session) -> Self {
        Self {
            id: s.id.clone(),
            title: s.title.clone(),
            display_title: s.display_title(),
            started_at: s.started_at,
            ended_at: s.ended_at,
            duration_seconds: s.duration_seconds(),
            line_count: s.lines.len(),
            has_audio: s.has_audio,
            has_notes: s.notes.as_ref().is_some_and(|n| !n.is_empty()),
            importing: s.importing == Some(true),
            source_file: s.source_file.clone(),
            room: s.room == Some(true),
            language_pair: compute_language_pair(&s.lines),
        }
    }
}

fn compute_language_pair(lines: &[TranscriptLine]) -> Option<String> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for l in lines.iter().filter(|l| l.speaker != "me") {
        let src = norm_lang(&l.src_lang);
        let dst = norm_lang(&l.dst_lang);
        if src != dst && !src.is_empty() && !dst.is_empty() {
            *counts.entry(format!("{src}→{dst}")).or_insert(0) += 1;
        }
    }
    let best = counts.into_iter().max_by_key(|(_, c)| *c)?.0;
    let mut parts = best.split('→');
    let s = short_lang(parts.next()?);
    let d = short_lang(parts.next()?);
    Some(format!("{s} → {d}"))
}

fn norm_lang(code: &str) -> String {
    if code.starts_with("zh") {
        if code.contains("Hant") || code.ends_with("TW") || code.ends_with("HK") {
            "zh-TW".to_string()
        } else {
            "zh-CN".to_string()
        }
    } else {
        code.split(['-', '_']).next().unwrap_or(code).to_string()
    }
}

fn short_lang(code: &str) -> String {
    match code {
        "en" => "英",
        "ja" => "日",
        "zh-CN" => "中",
        "zh-TW" => "繁",
        "ko" => "韩",
        "es" => "西",
        "fr" => "法",
        "de" => "德",
        "pt" => "葡",
        other => return other.to_uppercase(),
    }
    .to_string()
}

pub struct SessionStore {
    pub root: PathBuf,
    pub sessions: Vec<Session>,
    pub live_id: Option<String>,
}

impl SessionStore {
    pub fn open(data_dir: &Path) -> Self {
        let root = data_dir.join("Sessions");
        let _ = fs::create_dir_all(&root);
        let mut store = Self {
            root,
            sessions: Vec::new(),
            live_id: None,
        };
        store.reload();
        store
    }

    pub fn folder(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }

    pub fn system_audio_path(&self, id: &str) -> PathBuf {
        self.folder(id).join("system.m4a")
    }

    pub fn reload(&mut self) {
        let mut out = Vec::new();
        if let Ok(entries) = fs::read_dir(&self.root) {
            for entry in entries.flatten() {
                let path = entry.path().join("session.json");
                if let Ok(bytes) = fs::read(&path)
                    && let Ok(mut session) = serde_json::from_slice::<Session>(&bytes) {
                        if session.ended_at.is_none() {
                            let extra_secs = session.lines.last().map(|l| l.t + 5.0).unwrap_or(0.0);
                            session.ended_at = Some(
                                session.started_at
                                    + chrono::Duration::milliseconds((extra_secs * 1000.0) as i64),
                            );
                        }
                        if self.system_audio_path(&session.id).exists()
                            || self.folder(&session.id).join("system.aac").exists()
                        {
                            session.has_audio = true;
                        }
                        out.push(session);
                    }
            }
        }
        out.sort_by_key(|a| std::cmp::Reverse(a.started_at));
        self.sessions = out;
    }

    pub fn get(&self, id: &str) -> Option<&Session> {
        self.sessions.iter().find(|s| s.id == id)
    }

    pub fn get_mut(&mut self, id: &str) -> Option<&mut Session> {
        self.sessions.iter_mut().find(|s| s.id == id)
    }

    pub fn begin(&mut self, room: bool) -> Result<Session> {
        let now = Utc::now();
        let local = now.with_timezone(&Local);
        let base_id = local.format("%Y%m%d-%H%M%S").to_string();
        let id = if self.get(&base_id).is_some() {
            format!("{base_id}-{}", local.timestamp_subsec_millis())
        } else {
            base_id
        };
        let session = Session {
            id: id.clone(),
            title: Session::default_title(now),
            started_at: now,
            ended_at: None,
            lines: Vec::new(),
            has_audio: false,
            notes: None,
            renamed: None,
            voice_names: None,
            source_file: None,
            source_path: None,
            importing: None,
            room: if room { Some(true) } else { None },
        };
        fs::create_dir_all(self.folder(&id))?;
        self.sessions.insert(0, session.clone());
        self.live_id = Some(id.clone());
        self.save(&id)?;
        Ok(session)
    }

    pub fn end(&mut self, keep_empty_with_audio: bool) -> Result<Option<Session>> {
        let Some(id) = self.live_id.take() else {
            return Ok(None);
        };
        let has_audio = self.system_audio_path(&id).exists()
            || self.folder(&id).join("system.aac").exists()
            || self.folder(&id).join("room.m4a").exists();
        let Some(idx) = self.sessions.iter().position(|s| s.id == id) else {
            return Ok(None);
        };
        self.sessions[idx].ended_at = Some(Utc::now());
        self.sessions[idx].has_audio = has_audio;
        if self.sessions[idx].lines.is_empty() && !(keep_empty_with_audio && has_audio) {
            let _ = fs::remove_dir_all(self.folder(&id));
            self.sessions.remove(idx);
            return Ok(None);
        }
        self.save(&id)?;
        Ok(Some(self.sessions[idx].clone()))
    }

    pub fn begin_import(&mut self, file_name: &str, source_path: &str, recorded_at: Option<DateTime<Utc>>, duration_secs: f64) -> Result<Session> {
        let now = Utc::now();
        let started = recorded_at.unwrap_or(now);
        let local = now.with_timezone(&Local);
        let id = format!("import-{}-{:04x}", local.format("%Y%m%d-%H%M%S"), (now.timestamp_subsec_nanos() & 0xffff));
        let ended = started + chrono::Duration::milliseconds((duration_secs.max(1.0) * 1000.0) as i64);
        let session = Session {
            id: id.clone(),
            title: Session::default_title(started),
            started_at: started,
            ended_at: Some(ended),
            lines: Vec::new(),
            has_audio: false,
            notes: None,
            renamed: None,
            voice_names: None,
            source_file: Some(file_name.to_string()),
            source_path: Some(source_path.to_string()),
            importing: Some(true),
            room: None,
        };
        self.sessions.push(session.clone());
        self.sessions.sort_by_key(|a| std::cmp::Reverse(a.started_at));
        self.save(&id)?;
        Ok(session)
    }

    pub fn finish_import(&mut self, id: &str) -> Result<()> {
        if let Some(s) = self.get_mut(id) {
            s.importing = None;
            self.save(id)?;
        }
        Ok(())
    }

    pub fn append_line(&mut self, id: &str, line: TranscriptLine) -> Result<()> {
        if let Some(s) = self.get_mut(id) {
            s.lines.push(line);
            self.save(id)?;
        }
        Ok(())
    }

    pub fn replace_last_line(&mut self, id: &str, line: TranscriptLine) -> Result<()> {
        if let Some(s) = self.get_mut(id)
            && let Some(last) = s.lines.last_mut() {
                *last = line;
                self.save(id)?;
            }
        Ok(())
    }

    pub fn set_translation(&mut self, id: &str, line_id: &str, dst: String) -> Result<bool> {
        let Some(s) = self.get_mut(id) else {
            return Ok(false);
        };
        let Some(l) = s.lines.iter_mut().find(|l| l.id == line_id) else {
            return Ok(false);
        };
        l.dst = Some(dst);
        self.save(id)?;
        Ok(true)
    }

    pub fn set_fixes(&mut self, id: &str, line_id: &str, fixes: Vec<LineFix>) -> Result<bool> {
        let Some(s) = self.get_mut(id) else {
            return Ok(false);
        };
        let Some(l) = s.lines.iter_mut().find(|l| l.id == line_id) else {
            return Ok(false);
        };
        let next = if fixes.is_empty() { None } else { Some(fixes) };
        if l.fixes == next {
            return Ok(false);
        }
        l.fixes = next;
        self.save(id)?;
        Ok(true)
    }

    pub fn set_notes(&mut self, id: &str, notes: MeetingNotes) -> Result<()> {
        if let Some(s) = self.get_mut(id) {
            s.notes = Some(notes);
            self.save(id)?;
        }
        Ok(())
    }

    pub fn rename(&mut self, id: &str, title: &str) -> Result<()> {
        let Some(s) = self.get_mut(id) else {
            return Ok(());
        };
        let t = title.trim();
        if t.is_empty() {
            s.title = Session::default_title(s.started_at);
            s.renamed = Some(false);
        } else {
            s.title = t.to_string();
            s.renamed = Some(true);
        }
        self.save(id)?;
        Ok(())
    }

    pub fn set_voice_name(&mut self, id: &str, voice: i32, name: &str) -> Result<()> {
        let Some(s) = self.get_mut(id) else {
            return Ok(());
        };
        let map = s.voice_names.get_or_insert_with(HashMap::new);
        let trimmed = name.trim();
        if trimmed.is_empty() {
            map.remove(&voice.to_string());
        } else {
            map.insert(voice.to_string(), trimmed.to_string());
        }
        self.save(id)?;
        Ok(())
    }

    pub fn delete(&mut self, id: &str) -> Result<bool> {
        if self.live_id.as_deref() == Some(id) {
            return Ok(false);
        }
        let Some(idx) = self.sessions.iter().position(|s| s.id == id) else {
            return Ok(false);
        };
        self.sessions.remove(idx);
        let _ = fs::remove_dir_all(self.folder(id));
        Ok(true)
    }

    pub fn save(&self, id: &str) -> Result<()> {
        let Some(s) = self.get(id) else {
            return Ok(());
        };
        let path = self.folder(id).join("session.json");
        let json = serde_json::to_vec_pretty(s)?;
        write_atomic(&path, &json, false)?;
        Ok(())
    }
}

pub fn format_clock(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
    } else {
        format!("{:02}:{:02}", s / 60, s % 60)
    }
}

pub fn format_date_ymd_hm(dt: DateTime<Utc>) -> String {
    let local = Local.from_utc_datetime(&dt.naive_utc());
    local.format("%Y-%m-%d %H%M").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn session_crud_and_reload() {
        let dir = TempDir::new().unwrap();
        let mut store = SessionStore::open(dir.path());
        let s = store.begin(false).unwrap();
        store
            .append_line(
                &s.id,
                TranscriptLine {
                    id: "1".into(),
                    t: 1.5,
                    speaker: "them".into(),
                    src: "Hello world".into(),
                    dst: Some("你好世界".into()),
                    src_lang: "en".into(),
                    dst_lang: "zh-CN".into(),
                    voice: None,
                    via: Some("system".into()),
                    fixes: None,
                },
            )
            .unwrap();
        store.rename(&s.id, "产品评审").unwrap();
        store.end(false).unwrap();

        let reloaded = SessionStore::open(dir.path());
        assert_eq!(reloaded.sessions.len(), 1);
        assert_eq!(reloaded.sessions[0].display_title(), "产品评审");
        assert_eq!(reloaded.sessions[0].lines[0].dst.as_deref(), Some("你好世界"));
    }
}
