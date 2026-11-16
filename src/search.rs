use crate::correction;
use crate::store::Session;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub session_id: String,
    pub session_title: String,
    pub line_id: Option<String>,
    pub t: Option<f64>,
    pub kind: String, // "line" | "notes"
    pub text: String,
    pub translation: Option<String>,
    pub homophone_match: bool,
}

pub fn search_sessions(
    sessions: &[Session],
    query: &str,
    session_id: Option<&str>,
) -> Vec<SearchHit> {
    let q = query.trim();
    if q.is_empty() {
        return Vec::new();
    }
    let q_lower = q.to_lowercase();
    let q_py = correction::pinyin_flat(q);
    let has_cjk = q.chars().any(crate::heard::is_cjk_char);

    let mut hits = Vec::new();
    for s in sessions {
        if let Some(target_id) = session_id
            && s.id != target_id {
                continue;
            }
        let s_title = s.display_title();
        if let Some(notes) = &s.notes {
            let mut notes_hit = false;
            if notes.summary.to_lowercase().contains(&q_lower) {
                notes_hit = true;
                hits.push(SearchHit {
                    session_id: s.id.clone(),
                    session_title: s_title.clone(),
                    line_id: None,
                    t: None,
                    kind: "notes".into(),
                    text: notes.summary.clone(),
                    translation: None,
                    homophone_match: false,
                });
            }
            if !notes_hit {
                for topic in &notes.topics {
                    if topic.title.to_lowercase().contains(&q_lower)
                        || topic.summary.to_lowercase().contains(&q_lower)
                        || topic.points.iter().any(|p| p.to_lowercase().contains(&q_lower))
                    {
                        hits.push(SearchHit {
                            session_id: s.id.clone(),
                            session_title: s_title.clone(),
                            line_id: None,
                            t: Some(topic.start),
                            kind: "notes".into(),
                            text: format!("{} — {}", topic.title, topic.summary),
                            translation: None,
                            homophone_match: false,
                        });
                        break;
                    }
                }
            }
        }

        for line in &s.lines {
            let shown = line.shown();
            let dst = line.dst.as_deref().unwrap_or("");
            let direct = shown.to_lowercase().contains(&q_lower)
                || line.src.to_lowercase().contains(&q_lower)
                || dst.to_lowercase().contains(&q_lower);
            let homophone = !direct
                && has_cjk
                && q_py.len() >= 2
                && (correction::pinyin_flat(&shown).contains(&q_py)
                    || correction::pinyin_flat(&line.src).contains(&q_py));
            if direct || homophone {
                hits.push(SearchHit {
                    session_id: s.id.clone(),
                    session_title: s_title.clone(),
                    line_id: Some(line.id.clone()),
                    t: Some(line.t),
                    kind: "line".into(),
                    text: shown,
                    translation: line.dst.clone(),
                    homophone_match: homophone,
                });
            }
        }
    }
    hits
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::TranscriptLine;
    use chrono::Utc;

    #[test]
    fn homophone_search_finds_misrecognized_chinese_words() {
        let s = Session {
            id: "20261116-000100".into(),
            title: "技术讨论".into(),
            started_at: Utc::now(),
            ended_at: Some(Utc::now()),
            lines: vec![
                TranscriptLine {
                    id: "1".into(),
                    t: 10.0,
                    speaker: "them".into(),
                    src: "我们需要解除制压才能继续".into(),
                    dst: Some("We need to unstake to continue".into()),
                    src_lang: "zh-CN".into(),
                    dst_lang: "en".into(),
                    voice: None,
                    via: Some("system".into()),
                    fixes: None,
                },
                TranscriptLine {
                    id: "2".into(),
                    t: 20.0,
                    speaker: "them".into(),
                    src: "今天天气不错".into(),
                    dst: None,
                    src_lang: "zh-CN".into(),
                    dst_lang: "en".into(),
                    voice: None,
                    via: Some("system".into()),
                    fixes: None,
                },
            ],
            has_audio: false,
            notes: None,
            renamed: Some(true),
            voice_names: None,
            source_file: None,
            source_path: None,
            importing: None,
            room: None,
        };
        let hits = search_sessions(&[s], "质押", None);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].line_id.as_deref(), Some("1"));
        assert!(hits[0].homophone_match);
    }
}
