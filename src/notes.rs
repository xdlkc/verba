use crate::config::AppSettings;
use crate::heard::is_cjk_char;
use crate::loom::{ChatRequest, LoomClient, LoomError, Priority};
use crate::store::{
    Fishbone, FishboneBranch, MeetingNotes, NoteItem, NoteTerm, NoteTopic, Session,
    TranscriptLine, format_clock,
};
use chrono::Utc;
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::time::Duration;

pub const MAX_TOPICS: usize = 8;
pub const LIVE_MAX_TOPICS: usize = 12;
pub const TOPIC_SUMMARY_LIMIT: usize = 160;
pub const EDITABLE_TOPICS: usize = 2;
pub const SPLIT_MINUTES: f64 = 100.0;
pub const PART_MINUTES: f64 = 60.0;

#[derive(Serialize)]
struct CompactNotes<'a> {
    title: Option<&'a str>,
    summary: &'a str,
    topics: Vec<CompactTopic<'a>>,
    conclusions: Vec<&'a str>,
    todos: Vec<&'a str>,
    terms: &'a [NoteTerm],
}

#[derive(Serialize)]
struct CompactTopic<'a> {
    start: f64,
    title: &'a str,
    summary: &'a str,
    points: &'a [String],
    fishbone: Option<&'a Fishbone>,
}

pub fn glossary_lines(notes: &MeetingNotes) -> Vec<String> {
    notes
        .terms
        .iter()
        .take(30)
        .map(|t| {
            if t.heard.is_empty() {
                format!("{} ({})", t.name, t.note)
            } else {
                format!("{} ({}; misheard as {})", t.name, t.note, t.heard.join(", "))
            }
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
pub fn build_prompt(
    notes: &MeetingNotes,
    lines: &[TranscriptLine],
    from: usize,
    language: &str,
    is_final: bool,
    names: &HashMap<i32, String>,
    frozen: usize,
    part: Option<(usize, usize)>,
) -> String {
    let format_line = |i: usize| -> String {
        let l = &lines[i];
        let who = if l.speaker == "me" {
            "你".to_string()
        } else if let Some(v) = l.voice {
            names
                .get(&v)
                .cloned()
                .unwrap_or_else(|| format!("说话人{v}"))
        } else {
            "对方".to_string()
        };
        format!("[L{} {} {}] {}", i + 1, format_clock(l.t), who, l.shown())
    };

    let mut current = "{}".to_string();
    if !notes.is_empty() {
        let compact = CompactNotes {
            title: notes.title.as_deref(),
            summary: &notes.summary,
            topics: notes
                .topics
                .iter()
                .skip(frozen)
                .map(|t| CompactTopic {
                    start: t.start,
                    title: &t.title,
                    summary: &t.summary,
                    points: &t.points,
                    fishbone: t.fishbone.as_ref(),
                })
                .collect(),
            conclusions: notes.conclusions.iter().map(|c| c.text.as_str()).collect(),
            todos: notes.todos.iter().map(|t| t.text.as_str()).collect(),
            terms: &notes.terms,
        };
        if let Ok(s) = serde_json::to_string(&compact) {
            current = s;
        }
    }

    let context_start = from.saturating_sub(2);
    let task = match part {
        Some((idx, of)) => format!(
            "that has just ended. It was long, so it is noted in parts: write the notes for part {idx} of {of} only, from the lines below"
        ),
        None if is_final => "that has just ended. Rewrite them from the whole transcript".to_string(),
        None => "that is still going on. Update them with the new lines".to_string(),
    };

    let mut p = format!(
        "You keep notes for a meeting {task}.\nWrite the notes in {language}. Return JSON only.\n\n"
    );

    if !is_final {
        if frozen > 0 {
            p.push_str("Earlier topics (settled: kept as they are, do not return them):\n");
            for t in notes.topics.iter().take(frozen) {
                p.push_str(&format!("- {} {}: {}\n", format_clock(t.start), t.title, t.summary));
            }
            p.push('\n');
        }
        p.push_str(&format!(
            "Current notes (JSON{}):\n{current}\n\n",
            if frozen > 0 { ", latest topics only" } else { "" }
        ));
    }

    if context_start < from {
        p.push_str("Already covered (context only):\n");
        for i in context_start..from {
            p.push_str(&format_line(i));
            p.push('\n');
        }
        p.push('\n');
    }

    p.push_str(&format!(
        "{} (id, mm:ss, speaker 对方=the other side / 你=me / a name or 说话人N=one person on the other side, text). Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n",
        if is_final { "Transcript" } else { "New lines" }
    ));
    for i in from..lines.len() {
        p.push_str(&format_line(i));
        p.push('\n');
    }

    if is_final && from < lines.len() {
        let first = lines[from].t;
        let last = lines.last().map(|l| l.t).unwrap_or(first);
        let cap = part.map(|(_, of)| part_topics(of)).unwrap_or(MAX_TOPICS);
        let most = (((last - first) / 180.0) as usize + 1).clamp(1, cap);
        p.push_str(&format!(
            "\nThis {} ran {}: use at most {most} topic{}.\n",
            if part.is_none() { "meeting" } else { "part" },
            format_clock(last - first),
            if most == 1 { "" } else { "s" }
        ));
    } else if !is_final {
        if let (Some(current_topic), Some(newest)) = (notes.topics.last(), lines.last()) {
            if newest.t - current_topic.start < 120.0 {
                p.push_str(&format!(
                    "\nThe current topic \"{}\" started at {}, under 2 minutes ago: do not start a new topic in this update; add the new lines to it.\n",
                    current_topic.title,
                    format_clock(current_topic.start)
                ));
            }
        } else if notes.topics.is_empty() {
            p.push_str("\nThese are the first lines: make one topic.\n");
        }
    }

    p.push('\n');
    p.push_str(&format_spec(language, !names.is_empty(), is_final, frozen));
    p
}

fn format_spec(language: &str, voices: bool, is_final: bool, frozen: usize) -> String {
    let owner_hint = if !voices {
        "\"对方\" or \"你\" or null"
    } else {
        "the person's label from the transcript (a name like \"George\", or \"说话人2\"), \"你\", or null when unclear"
    };
    let topics_rule = if frozen > 0 {
        "returning only the topics in the current notes and at most one new one after them".to_string()
    } else {
        format!("at most {MAX_TOPICS} in total")
    };
    let per_update = if is_final { "" } else { "; add at most one new topic per update" };
    format!(
        "Return the full notes as one JSON object with exactly these keys:\n\
         {{\"title\": \"the meeting's name: what it is about, a few words\",\n\
          \"summary\": \"2-3 sentences on the whole meeting so far\",\n\
          \"topics\": [{{\"start\": seconds, \"title\": \"short title\", \"summary\": \"one sentence on the whole topic\", \"points\": [{{\"text\": \"key point\", \"evidence\": [\"L4\"]}}], \"evidence\": [\"L3\"],\n\
                      \"fishbone\": null or {{\"question\": \"the problem or question\", \"branches\": [{{\"label\": \"2-6 words\", \"detail\": \"one short line\", \"t\": seconds, \"evidence\": [\"L5\"]}}]}}}}],\n\
          \"conclusions\": [{{\"text\": \"...\", \"evidence\": [\"L7\", \"L8\"]}}],\n\
          \"todos\": [{{\"text\": \"...\", \"owner\": {owner_hint}, \"evidence\": [\"L9\"]}}],\n\
          \"terms\": [{{\"name\": \"correct spelling\", \"note\": \"who or what, a few words\", \"heard\": [\"how it was misrecognised\"]}}]}}\n\
         Rules (be brief: these notes are read at a glance during the meeting):\n\
         - title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not \"会议\" alone). Keep the current title unless the meeting's subject has clearly changed.\n\
         - summary: at most 3 short sentences.\n\
         - Topics in time order, {topics_rule}. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes and the current topic started at least 2 minutes before the newest line{per_update}. Otherwise add to the current one, and merge small neighbouring topics.\n\
         - A topic's summary is one sentence on the whole topic, at most 40 Chinese characters or 25 words: rewrite it concisely; never append \"最新/又/补充/then/later\".\n\
         - At most 4 points per topic, each one short phrase.\n\
         - At most 5 conclusions and only real to-dos (often none).\n\
         - Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.\n\
         - Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.\n\
         - terms: at most 10 in total, replacing less useful ones rather than adding: first names the transcript misspells (heard), then people, places and jargon a reader would not know. name is the correct spelling in the transcript's language; heard lists only wrong forms the transcript used.\n\
         - Write the meeting title and every summary, title, point, branch, conclusion and to-do in {language}, even when the transcript is in another language. Only term names keep the transcript's spelling.\n\
         - Use empty arrays when there is nothing. No markdown, no text outside the JSON."
    )
}

pub fn parse_notes(raw: &str, times: &[f64], started_at: f64) -> Option<MeetingNotes> {
    let open = raw.find('{')?;
    let close = raw.rfind('}')?;
    if open >= close {
        return None;
    }
    let root: Value = serde_json::from_str(&raw[open..=close]).ok()?;
    let line_count = times.len();

    let parse_line_numbers = |v: Option<&Value>| -> Vec<usize> {
        let mut out = Vec::new();
        if let Some(arr) = v.and_then(|x| x.as_array()) {
            for item in arr {
                if let Some(s) = item.as_str() {
                    let digits: String = s.chars().skip_while(|c| !c.is_ascii_digit()).take_while(|c| c.is_ascii_digit()).collect();
                    if let Ok(n) = digits.parse::<usize>()
                        && n >= 1 && n <= line_count && !out.contains(&n) {
                            out.push(n);
                        }
                }
            }
        }
        out
    };
    let support_count = |v: Option<&Value>| -> usize { parse_line_numbers(v).len() };
    let earliest_time = |v: Option<&Value>| -> Option<f64> {
        parse_line_numbers(v)
            .into_iter()
            .min()
            .and_then(|n| times.get(n - 1).copied())
    };

    let mut notes = MeetingNotes {
        summary: root
            .get("summary")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string(),
        ..Default::default()
    };

    if let Some(title) = root.get("title").and_then(|v| v.as_str()) {
        let cleaned = title
            .trim()
            .trim_matches(|c| matches!(c, '"' | '“' | '”' | '「' | '」' | '《' | '》'));
        if !cleaned.is_empty() {
            notes.title = Some(cleaned.to_string());
        }
    }

    if let Some(topics) = root.get("topics").and_then(|v| v.as_array()) {
        for t in topics {
            let title = t.get("title").and_then(|v| v.as_str()).unwrap_or("").trim();
            if title.is_empty() {
                continue;
            }
            let fishbone = t.get("fishbone").and_then(|f| {
                let branches: Vec<FishboneBranch> = f
                    .get("branches")
                    .and_then(|b| b.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|b| {
                                let label = b.get("label").and_then(|v| v.as_str()).unwrap_or("").trim();
                                if label.is_empty() {
                                    return None;
                                }
                                let detail = b.get("detail").and_then(|v| v.as_str()).unwrap_or("").trim();
                                let ev = b.get("evidence");
                                let fallback_t = b.get("t").and_then(val_as_f64);
                                Some(FishboneBranch {
                                    label: label.to_string(),
                                    detail: detail.to_string(),
                                    t: earliest_time(ev).or(fallback_t),
                                    support: support_count(ev),
                                })
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                if branches.len() >= 2 {
                    Some(Fishbone {
                        question: f
                            .get("question")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .trim()
                            .to_string(),
                        branches,
                    })
                } else {
                    None
                }
            });

            let mut points = Vec::new();
            let mut point_times = Vec::new();
            if let Some(arr) = t.get("points").and_then(|v| v.as_array()) {
                for p in arr {
                    let (text, pt) = if let Some(s) = p.as_str() {
                        (s.trim().to_string(), None)
                    } else {
                        let txt = p.get("text").and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
                        (txt, earliest_time(p.get("evidence")))
                    };
                    if text.is_empty() {
                        continue;
                    }
                    points.push(text);
                    point_times.push(pt);
                }
            }

            let topic_ev_time = earliest_time(t.get("evidence"));
            let min_pt_time = point_times.iter().copied().flatten().reduce(f64::min);
            let said = match (topic_ev_time, min_pt_time) {
                (Some(a), Some(b)) => Some(a.min(b)),
                (a, b) => a.or(b),
            };
            let start = said
                .or_else(|| t.get("start").and_then(val_as_f64))
                .unwrap_or(started_at);

            notes.topics.push(NoteTopic {
                start,
                title: title.to_string(),
                summary: t
                    .get("summary")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .trim()
                    .to_string(),
                points,
                fishbone,
                point_times: if point_times.iter().any(|x| x.is_some()) {
                    Some(point_times)
                } else {
                    None
                },
            });
        }
    }

    let parse_items = |key: &str| -> Vec<NoteItem> {
        root.get(key)
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|i| {
                        let text = i.get("text").and_then(|v| v.as_str()).unwrap_or("").trim();
                        if text.is_empty() {
                            return None;
                        }
                        let owner = i
                            .get("owner")
                            .and_then(|v| v.as_str())
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty());
                        let ev = i.get("evidence");
                        Some(NoteItem {
                            text: text.to_string(),
                            owner,
                            support: support_count(ev),
                            t: earliest_time(ev),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default()
    };

    notes.conclusions = parse_items("conclusions");
    notes.todos = parse_items("todos");

    if let Some(terms) = root.get("terms").and_then(|v| v.as_array()) {
        for t in terms {
            let name = t.get("name").and_then(|v| v.as_str()).unwrap_or("").trim();
            if name.is_empty() {
                continue;
            }
            let note = t
                .get("note")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .trim()
                .to_string();
            let heard: Vec<String> = t
                .get("heard")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|x| x.as_str())
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty() && s != name)
                        .collect()
                })
                .unwrap_or_default();
            notes.terms.push(NoteTerm {
                name: name.to_string(),
                note,
                heard,
            });
        }
    }
    if notes.terms.len() > 20 {
        notes.terms.sort_by_key(|t| usize::from(t.heard.is_empty()));
        notes.terms.truncate(20);
    }

    if notes.is_empty() {
        None
    } else {
        Some(notes)
    }
}

fn val_as_f64(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
}

pub fn written_in_language(notes: &MeetingNotes, language: &str) -> bool {
    let mut combined = notes.summary.clone();
    for t in &notes.topics {
        combined.push_str(&t.title);
    }
    let letters: Vec<char> = combined.chars().filter(|c| c.is_alphabetic()).collect();
    if letters.is_empty() {
        return true;
    }
    let cjk = letters.iter().filter(|&&c| is_cjk_char(c)).count();
    let wants_cjk = ["Chinese", "Japanese", "Korean"]
        .iter()
        .any(|k| language.contains(k));
    if wants_cjk {
        cjk * 5 >= letters.len()
    } else {
        cjk * 2 < letters.len()
    }
}

pub fn merge_topics(old: &[NoteTopic], frozen: usize, returned: &[NoteTopic]) -> Vec<NoteTopic> {
    let mut kept: Vec<NoteTopic> = old.iter().take(frozen).cloned().collect();
    let fixed: HashSet<&str> = kept.iter().map(|t| t.title.as_str()).collect();
    let own: Vec<NoteTopic> = returned
        .iter()
        .filter(|t| !fixed.contains(t.title.as_str()))
        .cloned()
        .collect();
    let mut tail = if kept.is_empty() {
        own
    } else {
        let keep_count = (old.len().saturating_sub(kept.len())) + 1;
        own.into_iter()
            .rev()
            .take(keep_count)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect()
    };
    if tail.is_empty() {
        return old.to_vec();
    }
    for t in &mut tail {
        t.summary = shortened(&t.summary);
    }
    tail = capped(tail, LIVE_MAX_TOPICS - kept.len().min(1));
    while kept.len() + tail.len() > LIVE_MAX_TOPICS && kept.len() >= 2 {
        let mut best_idx = 0usize;
        let mut best_span = f64::INFINITY;
        for i in 0..(kept.len() - 1) {
            let end = if i + 2 < kept.len() {
                kept[i + 2].start
            } else {
                tail[0].start
            };
            let span = end - kept[i].start;
            if span < best_span {
                best_span = span;
                best_idx = i;
            }
        }
        let joined_topic = joined(&kept[best_idx], &kept[best_idx + 1]);
        kept[best_idx] = joined_topic;
        kept.remove(best_idx + 1);
    }
    kept.extend(tail);
    capped(kept, LIVE_MAX_TOPICS)
}

pub fn joined(a: &NoteTopic, b: &NoteTopic) -> NoteTopic {
    let from_a = a.points.len().min(4usize.saturating_sub(b.points.len()).max(2));
    let from_b = b.points.len().min(4usize.saturating_sub(from_a));
    let mut points: Vec<String> = a.points.iter().take(from_a).cloned().collect();
    points.extend(b.points.iter().take(from_b).cloned());
    let mut times: Vec<Option<f64>> = (0..from_a).map(|i| a.point_time(i)).collect();
    times.extend((0..from_b).map(|i| b.point_time(i)));
    let gap = if a.summary.chars().last().is_some_and(|c| "。！？；".contains(c)) {
        ""
    } else {
        " "
    };
    NoteTopic {
        start: a.start,
        title: format!("{} / {}", a.title, b.title),
        summary: format!("{}{gap}{}", a.summary, b.summary),
        points,
        fishbone: a.fishbone.clone().or_else(|| b.fishbone.clone()),
        point_times: if times.iter().any(|x| x.is_some()) {
            Some(times)
        } else {
            None
        },
    }
}

pub fn shortened(summary: &str) -> String {
    if summary.chars().count() <= TOPIC_SUMMARY_LIMIT {
        return summary.to_string();
    }
    let head: String = summary.chars().take(TOPIC_SUMMARY_LIMIT).collect();
    for (idx, ch) in head.char_indices().skip(10) {
        if "。！？；.!?;".contains(ch) {
            return head[..idx + ch.len_utf8()].to_string();
        }
    }
    format!("{}…", head.trim())
}

pub fn capped(mut topics: Vec<NoteTopic>, count: usize) -> Vec<NoteTopic> {
    let limit = count.max(1);
    while topics.len() > limit {
        let extra = topics.pop().unwrap();
        let mut last = topics.pop().unwrap();
        let mut times: Vec<Option<f64>> = (0..last.points.len()).map(|i| last.point_time(i)).collect();
        times.extend((0..extra.points.len()).map(|i| extra.point_time(i)));
        last.points.extend(extra.points);
        last.point_times = if times.iter().any(|x| x.is_some()) {
            Some(times)
        } else {
            None
        };
        topics.push(last);
    }
    topics
}

pub fn heard_as_said(terms: Vec<NoteTerm>, lines: &[TranscriptLine]) -> Vec<NoteTerm> {
    terms
        .into_iter()
        .map(|mut t| {
            t.heard.retain(|h| {
                let hl = h.to_lowercase();
                lines.iter().any(|l| l.src.to_lowercase().contains(&hl))
            });
            t
        })
        .collect()
}

pub fn keep_term_order(old: &[NoteTerm], mut new: Vec<NoteTerm>) -> Vec<NoteTerm> {
    let mut rank: HashMap<String, usize> = HashMap::new();
    for (i, t) in old.iter().enumerate() {
        rank.entry(t.name.clone()).or_insert(i);
    }
    let mut indexed: Vec<(usize, NoteTerm)> = new.drain(..).enumerate().collect();
    indexed.sort_by_key(|(offset, t)| (rank.get(&t.name).copied().unwrap_or(old.len() + offset), *offset));
    indexed.into_iter().map(|(_, t)| t).collect()
}

pub fn carry_times(old: &MeetingNotes, new: &mut MeetingNotes) {
    let mut known_pts: HashMap<String, f64> = HashMap::new();
    for t in &old.topics {
        for (i, p) in t.points.iter().enumerate() {
            if let Some(x) = t.point_time(i) {
                known_pts.insert(p.clone(), x);
            }
        }
    }
    for t in &mut new.topics {
        let times: Vec<Option<f64>> = t
            .points
            .iter()
            .enumerate()
            .map(|(i, p)| {
                let cur = t.point_time(i);
                let prev = known_pts.get(p).copied();
                match (cur, prev) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                }
            })
            .collect();
        if let Some(first) = times.iter().copied().flatten().reduce(f64::min)
            && first < t.start {
                t.start = first;
            }
        t.point_times = if times.iter().any(|x| x.is_some()) {
            Some(times)
        } else {
            None
        };
    }
    let mut item_times: HashMap<String, f64> = HashMap::new();
    for item in old.conclusions.iter().chain(old.todos.iter()) {
        if let Some(t) = item.t {
            item_times.entry(item.text.clone()).or_insert(t);
        }
    }
    for c in &mut new.conclusions {
        if let Some(&prev) = item_times.get(&c.text) {
            c.t = Some(c.t.map_or(prev, |cur| cur.min(prev)));
        }
    }
    for td in &mut new.todos {
        if let Some(&prev) = item_times.get(&td.text) {
            td.t = Some(td.t.map_or(prev, |cur| cur.min(prev)));
        }
    }
}

pub fn parts(lines: &[TranscriptLine]) -> Vec<std::ops::Range<usize>> {
    let (Some(first), Some(last)) = (lines.first().map(|l| l.t), lines.last().map(|l| l.t)) else {
        return Vec::new();
    };
    let minutes = (last - first) / 60.0;
    if minutes <= SPLIT_MINUTES {
        return vec![std::ops::Range {
            start: 0,
            end: lines.len(),
        }];
    }
    let count = (minutes / PART_MINUTES).ceil() as usize;
    let length = (last - first) / (count as f64);
    let mut bounds = vec![0usize];
    for k in 1..count {
        let at = first + length * (k as f64);
        if let Some(i) = lines.iter().position(|l| l.t >= at)
            && i > *bounds.last().unwrap() {
                bounds.push(i);
            }
    }
    bounds.push(lines.len());
    bounds.windows(2).map(|w| w[0]..w[1]).collect()
}

pub fn part_topics(parts_count: usize) -> usize {
    (MAX_TOPICS / parts_count.max(1)).max(2)
}

pub fn thinned(mut topics: Vec<NoteTopic>, count: usize, end: f64) -> Vec<NoteTopic> {
    let limit = count.max(1);
    while topics.len() > limit {
        let n = topics.len() - 1;
        let same = (0..n).find(|&i| subject(&topics[i].title) == subject(&topics[i + 1].title));
        let idx = same.unwrap_or_else(|| {
            (0..n)
                .min_by(|&a, &b| {
                    let sa = if a + 2 < topics.len() { topics[a + 2].start } else { end } - topics[a].start;
                    let sb = if b + 2 < topics.len() { topics[b + 2].start } else { end } - topics[b].start;
                    sa.partial_cmp(&sb).unwrap_or(std::cmp::Ordering::Equal)
                })
                .unwrap_or(0)
        });
        let mut one = joined(&topics[idx], &topics[idx + 1]);
        if same.is_some() {
            one.title = topics[idx].title.clone();
            one.summary = topics[idx].summary.clone();
        }
        topics[idx] = one;
        topics.remove(idx + 1);
    }
    topics
}

pub fn subject(title: &str) -> String {
    let t = title.trim();
    if let Some(last) = t.chars().last()
        && (last == '）' || last == ')')
            && let Some(open) = t.rfind(['（', '('])
                && open > 0 {
                    return t[..open].trim().to_string();
                }
    t.to_string()
}

pub async fn generate_notes(
    loom: &LoomClient,
    settings: &AppSettings,
    model: &str,
    session: &Session,
    is_final: bool,
    fresh: bool,
) -> std::result::Result<MeetingNotes, LoomError> {
    let lines = &session.lines;
    if lines.is_empty() {
        return Err(LoomError::Parse("session has no transcript lines".into()));
    }
    let loom_dir = settings.resolved_loom_dir();
    let language = &settings.notes_lang;
    let times: Vec<f64> = lines.iter().map(|l| l.t).collect();
    let started_at = lines.first().map(|l| l.t).unwrap_or(0.0);

    let mut names: HashMap<i32, String> = HashMap::new();
    if let Some(vn) = &session.voice_names {
        for (k, v) in vn {
            if let Ok(id) = k.parse::<i32>()
                && !v.trim().is_empty() {
                    names.insert(id, v.trim().to_string());
                }
        }
    }

    if is_final {
        let chunks = parts(lines);
        if chunks.len() > 1
            && let Some(merged) =
                long_final(loom, settings, model, lines, &chunks, &names).await
            {
                let mut final_notes = merged;
                final_notes.terms = heard_as_said(final_notes.terms, lines);
                final_notes.covered = lines.len();
                final_notes.updated_at = Some(Utc::now());
                final_notes.is_final = true;
                return Ok(final_notes);
            }
    }

    let base = if is_final || fresh {
        MeetingNotes::default()
    } else {
        session.notes.clone().unwrap_or_default()
    };
    let from = if is_final {
        0
    } else {
        base.covered.min(lines.len())
    };
    let frozen = if is_final || fresh {
        0
    } else {
        base.topics.len().saturating_sub(EDITABLE_TOPICS)
    };
    let prompt = build_prompt(&base, lines, from, language, is_final, &names, frozen, None);

    let attempts = if is_final || fresh { 2 } else { 1 };
    let mut parsed_notes: Option<MeetingNotes> = None;
    for _ in 0..attempts {
        let resp = loom
            .chat(
                &settings.loom_url,
                &loom_dir,
                ChatRequest {
                    model: model.to_string(),
                    system: prompt.clone(),
                    instruction: format!("Update the notes. Write them in {language}."),
                    priority: Priority::Notes,
                    json_mode: true,
                    max_tokens: 6000,
                    timeout: Duration::from_secs(90),
                    role: if is_final { "notes-final" } else { "notes-live" }.to_string(),
                },
            )
            .await?;
        if let Some(p) = parse_notes(&resp.content, &times, started_at)
            && written_in_language(&p, language) {
                parsed_notes = Some(p);
                break;
            }
    }

    let mut next = parsed_notes.ok_or_else(|| LoomError::Parse("failed to parse notes JSON".into()))?;
    if !is_final && !fresh {
        next.topics = merge_topics(&base.topics, frozen, &next.topics);
    }
    if !fresh
        && let Some(old) = &session.notes {
            next.terms = keep_term_order(&old.terms, next.terms);
            if next.title.is_none() {
                next.title = old.title.clone();
            }
        }
    next.terms = heard_as_said(next.terms, lines);
    carry_times(&base, &mut next);
    next.covered = lines.len();
    next.updated_at = Some(Utc::now());
    next.is_final = is_final;
    Ok(next)
}

async fn long_final(
    loom: &LoomClient,
    settings: &AppSettings,
    model: &str,
    lines: &[TranscriptLine],
    chunks: &[std::ops::Range<usize>],
    names: &HashMap<i32, String>,
) -> Option<MeetingNotes> {
    let language = &settings.notes_lang;
    let started_at = lines.first().map(|l| l.t).unwrap_or(0.0);
    let loom_dir = settings.resolved_loom_dir();
    let times: Vec<f64> = lines.iter().map(|l| l.t).collect();
    let mut part_texts = Vec::new();
    let mut all_topics = Vec::new();

    let mut handles = Vec::new();
    for (idx, range) in chunks.iter().enumerate() {
        let prompt = build_prompt(
            &MeetingNotes::default(),
            &lines[..range.end],
            range.start,
            language,
            true,
            names,
            0,
            Some((idx + 1, chunks.len())),
        );
        let loom_url = settings.loom_url.clone();
        let dir = loom_dir.clone();
        let m = model.to_string();
        let lang = language.to_string();
        handles.push(async move {
            loom.chat(
                &loom_url,
                &dir,
                ChatRequest {
                    model: m,
                    system: prompt,
                    instruction: format!("Write the notes for this part. Write them in {lang}."),
                    priority: Priority::Notes,
                    json_mode: true,
                    max_tokens: 6000,
                    timeout: Duration::from_secs(90),
                    role: "notes-part".to_string(),
                },
            )
            .await
        });
    }
    let replies = futures_util::future::join_all(handles).await;
    for (idx, reply) in replies.into_iter().enumerate() {
        let raw = reply.ok()?.content;
        let parsed = parse_notes(&raw, &times, started_at)?;
        if parsed.topics.is_empty() {
            return None;
        }
        let open = raw.find('{')?;
        let close = raw.rfind('}')?;
        let mut obj: Value = serde_json::from_str(&raw[open..=close]).ok()?;
        if let Some(m) = obj.as_object_mut() {
            m.remove("topics");
        }
        part_texts.push(serde_json::to_string(&obj).ok()?);
        let end_t = lines[chunks[idx].end - 1].t;
        all_topics.extend(thinned(parsed.topics, part_topics(chunks.len()), end_t));
    }

    let mut merge_prompt = format!(
        "You keep notes for a meeting that has just ended. It was long, so each part was noted on its own; below are those notes, in time order (JSON; evidence ids are transcript lines, L1 the first). Merge them into the notes for the whole meeting.\n\
         Write the notes in {language}. Return JSON only.\n\n"
    );
    for (i, part) in part_texts.iter().enumerate() {
        merge_prompt.push_str(&format!("Part {} of {}:\n{part}\n\n", i + 1, part_texts.len()));
    }
    if let (Some(first), Some(last)) = (lines.first().map(|l| l.t), lines.last().map(|l| l.t)) {
        merge_prompt.push_str(&format!(
            "This meeting ran {}. Return \"topics\": []: the parts' topics are kept as they are. Name and summarise the whole meeting, every part of it; keep each conclusion, to-do and term once, with the evidence ids it had.\n\n",
            format_clock(last - first)
        ));
    }
    merge_prompt.push_str(&format_spec(language, !names.is_empty(), true, 0));

    for _ in 0..2 {
        let resp = loom
            .chat(
                &settings.loom_url,
                &loom_dir,
                ChatRequest {
                    model: model.to_string(),
                    system: merge_prompt.clone(),
                    instruction: format!("Merge the notes. Write them in {language}."),
                    priority: Priority::Notes,
                    json_mode: true,
                    max_tokens: 6000,
                    timeout: Duration::from_secs(90),
                    role: "notes-merge".to_string(),
                },
            )
            .await
            .ok()?;
        if let Some(mut merged) = parse_notes(&resp.content, &times, started_at) {
            merged.topics = all_topics.clone();
            if written_in_language(&merged, language) {
                return Some(merged);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_notes_maps_evidence_lines_and_fishbone() {
        let json = r#"```json
        {
          "title": "发布评审",
          "summary": "讨论了周五发版计划与接口延迟排查。",
          "topics": [
            {
              "start": 999,
              "title": "延迟原因分析",
              "summary": "定位了网关缓存与超时问题。",
              "points": [{"text": "缓存未命中导致 P95 升高", "evidence": ["L2"]}],
              "evidence": ["L2", "L3"],
              "fishbone": {
                "question": "为什么 P95 延迟上升？",
                "branches": [
                  {"label": "缓存失效", "detail": "热键 TTL 过短", "evidence": ["L2"]},
                  {"label": "重连耗时", "detail": "连接池上限不足", "evidence": ["L3"]}
                ]
              }
            }
          ],
          "conclusions": [{"text": "周五前上线修复", "evidence": ["L4"]}],
          "todos": [{"text": "压测网关", "owner": "对方", "evidence": ["L4"]}],
          "terms": [{"name": "Morpho", "note": "协议名称", "heard": ["莫拉"]}]
        }
        ```"#;
        let times = [5.0, 12.0, 25.0, 40.0];
        let notes = parse_notes(json, &times, 0.0).unwrap();
        assert_eq!(notes.title.as_deref(), Some("发布评审"));
        assert_eq!(notes.topics.len(), 1);
        assert_eq!(notes.topics[0].start, 12.0);
        assert_eq!(notes.topics[0].point_time(0), Some(12.0));
        assert_eq!(notes.topics[0].fishbone.as_ref().unwrap().branches.len(), 2);
        assert_eq!(notes.conclusions[0].t, Some(40.0));
        assert_eq!(notes.todos[0].owner.as_deref(), Some("对方"));
    }

    #[test]
    fn merge_topics_keeps_frozen_and_caps_total() {
        let old = vec![
            NoteTopic { start: 0.0, title: "开场".into(), summary: "s1".into(), points: vec!["p1".into()], ..Default::default() },
            NoteTopic { start: 100.0, title: "议题二".into(), summary: "s2".into(), points: vec!["p2".into()], ..Default::default() },
            NoteTopic { start: 200.0, title: "议题三".into(), summary: "s3".into(), points: vec!["p3".into()], ..Default::default() },
        ];
        let returned = vec![
            NoteTopic { start: 0.0, title: "开场".into(), summary: "echo".into(), points: vec![], ..Default::default() },
            NoteTopic { start: 100.0, title: "议题二".into(), summary: "s2b".into(), points: vec!["p2b".into()], ..Default::default() },
            NoteTopic { start: 200.0, title: "议题三".into(), summary: "s3b".into(), points: vec!["p3b".into()], ..Default::default() },
            NoteTopic { start: 350.0, title: "议题四".into(), summary: "s4".into(), points: vec!["p4".into()], ..Default::default() },
        ];
        let merged = merge_topics(&old, 1, &returned);
        assert_eq!(merged.len(), 4);
        assert_eq!(merged[0].summary, "s1");
        assert_eq!(merged[3].title, "议题四");
    }
}
