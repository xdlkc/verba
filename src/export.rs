use crate::config::{Result, write_atomic};
use crate::store::{MeetingNotes, Session, SessionStore, format_clock, format_date_ymd_hm};
use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

pub fn notes_markdown(notes: Option<&MeetingNotes>) -> String {
    let Some(n) = notes.filter(|n| !n.is_empty()) else {
        return String::new();
    };
    let mut out = format!("## 纪要\n\n{}\n\n", n.summary);
    for t in &n.topics {
        out.push_str(&format!("### {} {}\n\n", format_clock(t.start), t.title));
        if !t.summary.is_empty() {
            out.push_str(&format!("{}\n\n", t.summary));
        }
        for p in &t.points {
            out.push_str(&format!("- {p}\n"));
        }
        if let Some(f) = &t.fishbone {
            out.push_str(&format!("\n**{}**\n\n", f.question));
            for b in &f.branches {
                out.push_str(&format!("- {}：{}\n", b.label, b.detail));
            }
        }
        out.push('\n');
    }
    if !n.conclusions.is_empty() {
        out.push_str("### 结论\n\n");
        for c in &n.conclusions {
            out.push_str(&format!("- {}\n", c.text));
        }
        out.push('\n');
    }
    if !n.todos.is_empty() {
        out.push_str("### 待办\n\n");
        for td in &n.todos {
            out.push_str(&format!("- [ ] {}\n", td.with_owner()));
        }
        out.push('\n');
    }
    if !n.terms.is_empty() {
        out.push_str("### 人名和术语\n\n");
        for term in &n.terms {
            out.push_str(&format!("- **{}** {}\n", term.name, term.note));
        }
        out.push('\n');
    }
    out
}

pub fn session_markdown(s: &Session) -> String {
    let local = s.started_at.with_timezone(&Local);
    let mins = (s.duration_seconds() / 60.0) as u64;
    let dur_str = if mins < 1 {
        "不到 1 分钟".to_string()
    } else {
        format!("{mins} 分钟")
    };
    let mut out = format!(
        "# {}\n\n{} · {}\n\n",
        s.display_title(),
        local.format("%Y年%-m月%-d日 %H:%M"),
        dur_str
    );
    let nm = notes_markdown(s.notes.as_ref());
    if !nm.is_empty() {
        out.push_str(&nm);
        out.push_str("## 文字记录\n\n");
    }
    for l in &s.lines {
        let who = if l.speaker == "me" {
            " 你".to_string()
        } else if let Some(v) = l.voice {
            let name = s
                .voice_names
                .as_ref()
                .and_then(|m| m.get(&v.to_string()))
                .cloned()
                .unwrap_or_else(|| format!("说话人 {v}"));
            format!(" {name}")
        } else if l.via.as_deref() == Some("room") {
            " 现场".to_string()
        } else {
            " 对方".to_string()
        };
        let shown = l.shown();
        out.push_str(&format!("**[{}]{who}**  \n{shown}\n", format_clock(l.t)));
        if let Some(d) = &l.dst
            && d != &shown {
                out.push_str(&format!("> {d}\n"));
            }
        out.push('\n');
    }
    out
}

pub fn session_srt(s: &Session) -> String {
    let ts = |t: f64| -> String {
        let ms = (t.max(0.0) * 1000.0).round() as u64;
        format!(
            "{:02}:{:02}:{:02},{:03}",
            ms / 3_600_000,
            (ms / 60_000) % 60,
            (ms / 1000) % 60,
            ms % 1000
        )
    };
    let mut out = String::new();
    for (i, l) in s.lines.iter().enumerate() {
        let next = s.lines.get(i + 1).map(|x| x.t).unwrap_or(l.t + 4.0);
        let end = next.min(l.t + 8.0).max(l.t + 1.0);
        let tag = if l.speaker == "me" { "[我] " } else { "" };
        let shown = l.shown();
        out.push_str(&format!("{}\n{} --> {}\n{tag}{shown}\n", i + 1, ts(l.t), ts(end)));
        if let Some(d) = &l.dst
            && d != &shown {
                out.push_str(&format!("{d}\n"));
            }
        out.push('\n');
    }
    out
}

pub fn record_own_name(s: &Session) -> String {
    let renamed = s.renamed.unwrap_or_else(|| !s.title.starts_with("会议 "));
    if renamed {
        return s.title.clone();
    }
    if let Some(title) = s.notes.as_ref().and_then(|n| n.title.as_ref())
        && !title.trim().is_empty() {
            return title.trim().to_string();
        }
    if let Some(file) = &s.source_file {
        return Path::new(file)
            .file_stem()
            .and_then(|st| st.to_str())
            .unwrap_or(file)
            .to_string();
    }
    String::new()
}

pub fn safe_filename(name: &str) -> String {
    let banned = |c: char| {
        matches!(
            c,
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '#' | '^' | '[' | ']'
        ) || (c as u32) < 0x20
    };
    let spaced: String = name
        .chars()
        .map(|c| if banned(c) { ' ' } else { c })
        .collect();
    let collapsed = spaced.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out = String::new();
    for ch in collapsed.chars() {
        if out.len() + ch.len_utf8() > 120 {
            break;
        }
        out.push(ch);
    }
    out.trim_matches(|c| c == ' ' || c == '.').to_string()
}

pub fn frontmatter_document(s: &Session) -> String {
    let ended = s.ended_at.unwrap_or(s.started_at);
    let mut langs: Vec<String> = s
        .lines
        .iter()
        .map(|l| l.src_lang.clone())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    langs.sort();
    let notes_state = match &s.notes {
        Some(n) if !n.is_empty() => {
            if n.is_final {
                "final"
            } else {
                "draft"
            }
        }
        _ => "none",
    };
    let mins = ((ended - s.started_at).num_seconds().max(0) / 60) as u64;
    let started_iso = s.started_at.with_timezone(&Local).to_rfc3339();
    let ended_iso = ended.with_timezone(&Local).to_rfc3339();
    let langs_json = langs
        .iter()
        .map(|l| serde_json::to_string(l).unwrap_or_else(|_| "\"\"".into()))
        .collect::<Vec<_>>()
        .join(", ");
    let fm = format!(
        "---\nverba: 1\nid: {}\ntitle: {}\nstarted: {}\nended: {}\nminutes: {}\nlanguages: [{}]\nsource: {}\nnotes: {}\ntags: [\"verba\"]\n---\n\n",
        serde_json::to_string(&s.id).unwrap_or_default(),
        serde_json::to_string(&record_own_name(s)).unwrap_or_default(),
        serde_json::to_string(&started_iso).unwrap_or_default(),
        serde_json::to_string(&ended_iso).unwrap_or_default(),
        mins,
        langs_json,
        serde_json::to_string(if s.source_file.is_some() { "file" } else { "meeting" })
            .unwrap_or_default(),
        serde_json::to_string(notes_state).unwrap_or_default(),
    );
    format!("{fm}{}", session_markdown(s))
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct ExportIndex {
    pub folder: String,
    pub files: HashMap<String, String>,
    pub last_file: Option<String>,
    pub last_at: Option<DateTime<Utc>>,
}

pub fn sync_folder_export(
    data_dir: &Path,
    store: &SessionStore,
    folder_path: &str,
) -> Result<ExportIndex> {
    let folder = PathBuf::from(folder_path);
    fs::create_dir_all(&folder)?;

    let index_path = data_dir.join("FolderExport.json");
    let mut idx: ExportIndex = fs::read(&index_path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    if idx.folder != folder_path {
        idx = ExportIndex {
            folder: folder_path.to_string(),
            ..Default::default()
        };
    }

    for s in &store.sessions {
        if store.live_id.as_deref() == Some(s.id.as_str())
            || s.ended_at.is_none()
            || s.importing == Some(true)
            || s.lines.is_empty()
        {
            continue;
        }
        let stem = {
            let date = format_date_ymd_hm(s.started_at);
            let safe = safe_filename(&record_own_name(s));
            if safe.is_empty() {
                date
            } else {
                format!("{date} {safe}")
            }
        };
        let old = idx.files.get(&s.id).cloned();
        let taken: HashSet<String> = idx
            .files
            .iter()
            .filter(|(id, _)| *id != &s.id)
            .map(|(_, name)| name.clone())
            .collect();
        let mut n = 1usize;
        let name = loop {
            let candidate = if n == 1 {
                format!("{stem}.md")
            } else {
                format!("{stem} {n}.md")
            };
            if old.as_deref() == Some(candidate.as_str())
                || (!taken.contains(&candidate) && !folder.join(&candidate).exists())
            {
                break candidate;
            }
            n += 1;
        };

        let doc = frontmatter_document(s);
        let dst = folder.join(&name);
        let unchanged = old.as_deref() == Some(name.as_str())
            && fs::read_to_string(&dst).ok().as_deref() == Some(doc.as_str());
        if !unchanged {
            write_atomic(&dst, doc.as_bytes(), false)?;
            if let Some(old_name) = old
                && old_name != name {
                    let _ = fs::remove_file(folder.join(old_name));
                }
            idx.files.insert(s.id.clone(), name.clone());
            idx.last_file = Some(name);
            idx.last_at = Some(Utc::now());
        }
    }

    let bytes = serde_json::to_vec_pretty(&idx)?;
    write_atomic(&index_path, &bytes, false)?;
    Ok(idx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{NoteTopic, TranscriptLine};
    use tempfile::TempDir;

    #[test]
    fn markdown_srt_and_folder_sync_work() {
        let data = TempDir::new().unwrap();
        let vault = TempDir::new().unwrap();
        let mut store = SessionStore::open(data.path());
        let s = store.begin(false).unwrap();
        store
            .append_line(
                &s.id,
                TranscriptLine {
                    id: "1".into(),
                    t: 3.0,
                    speaker: "them".into(),
                    src: "Let's ship Verba today.".into(),
                    dst: Some("我们今天发布 Verba。".into()),
                    src_lang: "en".into(),
                    dst_lang: "zh-CN".into(),
                    voice: None,
                    via: Some("system".into()),
                    fixes: None,
                },
            )
            .unwrap();
        store
            .set_notes(
                &s.id,
                MeetingNotes {
                    title: Some("发布同步".into()),
                    summary: "决定今日发布 Verba。".into(),
                    topics: vec![NoteTopic {
                        start: 3.0,
                        title: "发布安排".into(),
                        summary: "确认发布时间".into(),
                        points: vec!["今日完成构建".into()],
                        ..Default::default()
                    }],
                    is_final: true,
                    covered: 1,
                    ..Default::default()
                },
            )
            .unwrap();
        let ended = store.end(false).unwrap().unwrap();

        let md = session_markdown(&ended);
        assert!(md.contains("## 纪要"));
        assert!(md.contains("我们今天发布 Verba。"));

        let srt = session_srt(&ended);
        assert!(srt.contains("00:00:03,000 --> 00:00:07,000"));

        let idx = sync_folder_export(data.path(), &store, vault.path().to_str().unwrap()).unwrap();
        let file_name = idx.files.get(&ended.id).unwrap();
        assert!(file_name.ends_with("发布同步.md"));
        let content = fs::read_to_string(vault.path().join(file_name)).unwrap();
        assert!(content.starts_with("---\nverba: 1\n"));
        assert!(content.contains("tags: [\"verba\"]"));
    }
}
