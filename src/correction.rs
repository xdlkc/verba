use crate::pinyin_data::char_pinyin;
use crate::store::LineFix;
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq)]
pub struct Edit {
    pub from: String,
    pub to: String,
    pub confidence: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Apply,
    Ask,
    Drop,
}

pub const APPLY_AT: f64 = 0.6;
pub const SPELLING_AT: f64 = 0.8;
pub const ASK_AT: f64 = 0.8;

const INITIALS: &[&str] = &[
    "zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r",
    "z", "c", "s", "y", "w",
];

pub fn core(from: &str, to: &str) -> (String, String) {
    let a: Vec<char> = from.chars().collect();
    let b: Vec<char> = to.chars().collect();
    let min_len = a.len().min(b.len());
    let mut i = 0;
    while i < min_len && a[i] == b[i] {
        i += 1;
    }
    let mut j = 0;
    while j < min_len - i && a[a.len() - 1 - j] == b[b.len() - 1 - j] {
        j += 1;
    }
    let is_word = |c: char| c.is_ascii_alphanumeric();
    let from_edge =
        (i < a.len() && is_word(a[i])) || (i < b.len() && is_word(b[i]));
    if from_edge {
        while i > 0 && is_word(a[i - 1]) {
            i -= 1;
        }
    }
    let to_edge = (a.len() > j && is_word(a[a.len() - 1 - j]))
        || (b.len() > j && is_word(b[b.len() - 1 - j]));
    if to_edge {
        while j > 0 && is_word(a[a.len() - j]) {
            j -= 1;
        }
    }
    while a.len().saturating_sub(j + i) < 2 || b.len().saturating_sub(j + i) < 2 {
        if j > 0 && !is_word(a[a.len() - j]) {
            j -= 1;
        } else if i > 0 && !is_word(a[i - 1]) {
            i -= 1;
        } else {
            break;
        }
    }
    let f: String = a[i..a.len().saturating_sub(j)].iter().collect();
    let t: String = b[i..b.len().saturating_sub(j)].iter().collect();
    (f, t)
}

pub fn label(fix: &LineFix) -> (String, String) {
    let c = core(&fix.from, &fix.to);
    if c.0.is_empty() || c.1.is_empty() {
        (fix.from.clone(), fix.to.clone())
    } else {
        c
    }
}

pub fn is_han_only(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| char_pinyin(c).is_some())
}

pub fn name_shaped(s: &str) -> bool {
    s.chars()
        .any(|c| c.is_ascii() && (c.is_ascii_uppercase() || c.is_ascii_digit()))
}

pub fn is_plain_translation(heard: &str, word: &str) -> bool {
    is_han_only(heard)
        && word.chars().any(|c| c.is_ascii_alphabetic())
        && word.is_ascii()
        && !name_shaped(word)
}

pub fn pinyin_syllables(s: &str) -> Vec<&'static str> {
    s.chars().filter_map(char_pinyin).collect()
}

pub fn pinyin_flat(s: &str) -> String {
    let mut out = String::new();
    for ch in s.chars() {
        if let Some(py) = char_pinyin(ch) {
            out.push_str(py);
        } else if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        }
    }
    out
}

fn split_syllable(syl: &str) -> (&str, &str) {
    for &ini in INITIALS {
        if let Some(rest) = syl.strip_prefix(ini) {
            return (ini, rest);
        }
    }
    ("", syl)
}

pub fn sounds_alike(a: &str, b: &str) -> bool {
    let x = pinyin_syllables(a);
    let y = pinyin_syllables(b);
    if x.is_empty() || x.len() != y.len() {
        return false;
    }
    let mut score = 0.0f64;
    for (p, q) in x.iter().zip(y.iter()) {
        if p == q {
            score += 1.0;
            continue;
        }
        let (i1, f1) = split_syllable(p);
        let (i2, f2) = split_syllable(q);
        if i1 == i2 || f1 == f2 || f1.replace("ng", "n") == f2.replace("ng", "n") {
            score += 0.5;
        }
    }
    score / (x.len() as f64) >= 0.75
}

pub fn edit_distance(a: &str, b: &str) -> usize {
    let av: Vec<char> = a.chars().collect();
    let bv: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=bv.len()).collect();
    for (i, &ca) in av.iter().enumerate() {
        let mut prev = row[0];
        row[0] = i + 1;
        for (j, &cb) in bv.iter().enumerate() {
            let cur = row[j + 1];
            let sub = prev + usize::from(ca != cb);
            row[j + 1] = (row[j + 1] + 1).min(row[j] + 1).min(sub);
            prev = cur;
        }
    }
    row[bv.len()]
}

fn damerau_distance(a: &str, b: &str) -> usize {
    let av: Vec<char> = a.chars().collect();
    let bv: Vec<char> = b.chars().collect();
    let n = av.len();
    let m = bv.len();
    let mut d = vec![vec![0usize; m + 1]; n + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cell) in d[0].iter_mut().enumerate() {
        *cell = j;
    }
    for i in 1..=n {
        for j in 1..=m {
            let cost = usize::from(av[i - 1] != bv[j - 1]);
            let mut best = (d[i - 1][j] + 1)
                .min(d[i][j - 1] + 1)
                .min(d[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && av[i - 1] == bv[j - 2] && av[i - 2] == bv[j - 1] {
                best = best.min(d[i - 2][j - 2] + cost);
            }
            d[i][j] = best;
        }
    }
    d[n][m]
}

fn latin_skeleton(s: &str) -> String {
    let lower = s.to_ascii_lowercase().replace("ph", "f").replace('x', "ks");
    let mut out = String::new();
    let mut first_alpha = true;
    for ch in lower.chars() {
        if !ch.is_ascii_alphabetic() {
            continue;
        }
        let mapped = match ch {
            'c' | 'q' | 'g' => 'k',
            'z' => 's',
            'v' | 'f' | 'b' => 'p',
            'd' => 't',
            other => other,
        };
        let is_vowel = matches!(ch, 'a' | 'e' | 'i' | 'o' | 'u' | 'y' | 'w' | 'h');
        if is_vowel {
            if first_alpha {
                out.push(mapped);
            }
            first_alpha = false;
            continue;
        }
        first_alpha = false;
        if !out.ends_with(mapped) {
            out.push(mapped);
        }
    }
    out
}

pub fn english_sounds_alike(a: &str, b: &str) -> bool {
    let a_trim = a.trim();
    let b_trim = b.trim();
    if a_trim.is_empty()
        || b_trim.is_empty()
        || !a_trim.is_ascii()
        || !b_trim.is_ascii()
        || a_trim.split_whitespace().count() > 4
        || b_trim.split_whitespace().count() > 4
        || !a_trim.chars().any(|c| c.is_ascii_alphabetic())
        || !b_trim.chars().any(|c| c.is_ascii_alphabetic())
    {
        return false;
    }
    let al = a_trim.to_ascii_lowercase();
    let bl = b_trim.to_ascii_lowercase();
    if edit_distance(&al, &bl) <= 2 {
        return true;
    }
    if al.len().abs_diff(bl.len()) > 6 {
        return false;
    }
    let sa = latin_skeleton(&al);
    let sb = latin_skeleton(&bl);
    if sa.is_empty() || sb.is_empty() {
        return false;
    }
    if sa.len().min(sb.len()) <= 3 {
        return sa == sb;
    }
    damerau_distance(&sa, &sb) <= 2
}

pub fn decide<K, R>(edit: &Edit, known: K, rejected: R) -> Verdict
where
    K: Fn(&str, &str) -> bool,
    R: Fn(&str, &str) -> bool,
{
    let (cf, ct) = core(&edit.from, &edit.to);
    if cf.is_empty()
        || ct.is_empty()
        || cf.to_lowercase() == ct.to_lowercase()
        || rejected(&edit.from, &edit.to)
        || rejected(&cf, &ct)
    {
        return Verdict::Drop;
    }
    if known(&edit.from, &edit.to) || known(&cf, &ct) {
        return Verdict::Apply;
    }
    if edit.confidence < APPLY_AT {
        return Verdict::Drop;
    }
    let latin_from = cf.chars().any(|c| c.is_ascii_alphabetic());
    let latin_to = ct.chars().any(|c| c.is_ascii_alphabetic());
    if !latin_from && !latin_to && is_han_only(&cf) && is_han_only(&ct) && sounds_alike(&cf, &ct) {
        return Verdict::Apply;
    }
    if latin_from
        && latin_to
        && cf.is_ascii()
        && ct.is_ascii()
        && edit.confidence >= SPELLING_AT
        && cf.to_lowercase() != ct.to_lowercase()
        && (english_sounds_alike(&cf, &ct)
            || (edit.confidence >= 0.92
                && name_shaped(&ct)
                && cf.split_whitespace().count() <= 4
                && ct.split_whitespace().count() <= 4))
    {
        return Verdict::Apply;
    }
    if latin_to && edit.confidence >= ASK_AT && name_shaped(&ct) {
        return Verdict::Ask;
    }
    Verdict::Drop
}

fn find_word(needle: &str, haystack: &str) -> Option<(usize, usize)> {
    if needle.is_empty() {
        return None;
    }
    let is_latin = |c: Option<char>| c.is_some_and(|ch| ch.is_ascii_alphanumeric());
    let needle_first = needle.chars().next();
    let needle_last = needle.chars().last();
    let mut from = 0;
    while from < haystack.len() {
        let rel = haystack[from..].find(needle)?;
        let start = from + rel;
        let end = start + needle.len();
        let before = haystack[..start].chars().last();
        let after = haystack[end..].chars().next();
        if !(is_latin(needle_first) && is_latin(before))
            && !(is_latin(needle_last) && is_latin(after))
        {
            return Some((start, end));
        }
        let next_char_len = haystack[start..].chars().next().map(|c| c.len_utf8()).unwrap_or(1);
        from = start + next_char_len;
    }
    None
}

pub fn apply_fixes(fixes: &[LineFix], src: &str) -> (String, Vec<(usize, usize)>) {
    let mut text = src.to_string();
    let mut spans: Vec<(String, usize)> = Vec::new();
    let ordered = fixes
        .iter()
        .filter(|f| f.user != Some(true))
        .chain(fixes.iter().filter(|f| f.user == Some(true)));
    for f in ordered {
        if !f.is_applied() || f.from.is_empty() {
            continue;
        }
        let found = find_word(&f.from, &text).or_else(|| {
            text.find(&f.from).map(|s| (s, s + f.from.len()))
        });
        let Some((byte_start, byte_end)) = found else {
            continue;
        };
        let char_start = text[..byte_start].chars().count();
        let from_chars = f.from.chars().count();
        let to_chars = f.to.chars().count();
        let delta = to_chars as isize - from_chars as isize;
        for span in &mut spans {
            if span.1 > char_start {
                span.1 = (span.1 as isize + delta).max(0) as usize;
            }
        }
        text.replace_range(byte_start..byte_end, &f.to);
        spans.push((f.to.clone(), char_start));
    }
    let total_chars = text.chars().count();
    let mut marks: Vec<(usize, usize)> = spans
        .into_iter()
        .filter_map(|(word, offset)| {
            let len = word.chars().count();
            if offset + len <= total_chars {
                Some((offset, offset + len))
            } else {
                None
            }
        })
        .collect();
    marks.sort_by_key(|m| m.0);
    (text, marks)
}

#[derive(Deserialize)]
struct RawFixReply {
    translation: String,
    #[serde(default)]
    fixes: Vec<RawFixItem>,
}

#[derive(Deserialize)]
struct RawFixItem {
    from: Option<String>,
    to: Option<String>,
    confidence: Option<f64>,
}

pub fn parse_fixes_reply(reply: &str, subtitle: &str) -> Option<(String, Vec<Edit>)> {
    let open = reply.find('{')?;
    let close = reply.rfind('}')?;
    if open >= close {
        return None;
    }
    let parsed: RawFixReply = serde_json::from_str(&reply[open..=close]).ok()?;
    let mut edits = Vec::new();
    for item in parsed.fixes {
        let Some(from) = item.from else { continue };
        let Some(to) = item.to else { continue };
        if from.is_empty() || from == to || !subtitle.contains(&from) {
            continue;
        }
        edits.push(Edit {
            from,
            to,
            confidence: item.confidence.unwrap_or(0.0),
        });
    }
    Some((parsed.translation.trim().to_string(), edits))
}

pub fn merge_fixes(old: &[LineFix], new: &[LineFix]) -> Vec<LineFix> {
    let kept: Vec<LineFix> = old
        .iter()
        .filter(|f| f.off == Some(true) || f.user == Some(true))
        .cloned()
        .collect();
    let mut out = kept.clone();
    for n in new {
        let nc = core(&n.from, &n.to);
        let conflict = kept
            .iter()
            .any(|k| k.from == n.from || core(&k.from, &k.to).0 == nc.0);
        if !conflict {
            out.push(n.clone());
        }
    }
    out
}

pub fn user_edit(
    shown: &str,
    edited: &str,
    src: &str,
    fixes: &[LineFix],
) -> Option<(LineFix, String, bool)> {
    let new = edited.trim();
    if new.is_empty() || new == shown {
        return None;
    }
    let a: Vec<char> = shown.chars().collect();
    let b: Vec<char> = new.chars().collect();
    let min_len = a.len().min(b.len());
    let mut p = 0;
    while p < min_len && a[p] == b[p] {
        p += 1;
    }
    let mut q = 0;
    while q < min_len - p && a[a.len() - 1 - q] == b[b.len() - 1 - q] {
        q += 1;
    }
    let swap = a.len() - p - q > 0 && b.len() - p - q > 0;
    let is_latin = |c: char| c.is_ascii_alphanumeric();
    let mut tokens: Vec<(usize, usize)> = Vec::new();
    let mut k = 0;
    while k < a.len() {
        let mut e = k + 1;
        if is_latin(a[k]) {
            while e < a.len() && is_latin(a[e]) {
                e += 1;
            }
        }
        tokens.push((k, e));
        k = e;
    }
    let mut start = p;
    let mut end = a.len() - q;
    if let Some(&(lo, _)) = tokens.iter().find(|&&(lo, hi)| start >= lo && start < hi) {
        start = lo;
    }
    if end > start
        && let Some(&(_, hi)) = tokens.iter().find(|&&(lo, hi)| end > lo && end - 1 < hi) {
            end = hi;
        }
    let span = |s: usize, e: usize| -> String { a[s..e].iter().collect() };
    let replacement = |s: usize, e: usize| -> String {
        let b_end = b.len().saturating_sub(a.len() - e);
        if s <= b_end && b_end <= b.len() {
            b[s..b_end].iter().collect()
        } else {
            String::new()
        }
    };
    while !span(start, end).chars().any(|c| c.is_alphanumeric())
        || shown.matches(&span(start, end)).count() != 1
        || replacement(start, end).is_empty()
    {
        if let Some(&(lo, _)) = tokens.iter().rev().find(|&&(_, hi)| hi <= start) {
            start = lo;
        } else if let Some(&(_, hi)) = tokens.iter().find(|&&(lo, _)| lo >= end) {
            end = hi;
        } else {
            break;
        }
    }
    let from = span(start, end);
    let to = replacement(start, end);
    if from.is_empty() || from == to {
        return None;
    }
    let mut heard = from.clone();
    if !src.contains(&from)
        && let Some(earlier) = fixes.iter().find(|f| f.is_applied() && from.contains(&f.to)) {
            heard = core(&earlier.from, &earlier.to).0;
        }
    Some((
        LineFix {
            from,
            to,
            ask: None,
            off: None,
            user: Some(true),
        },
        heard,
        swap,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn homophone_detection_accepts_sound_alike_and_rejects_unrelated() {
        assert!(sounds_alike("质压", "质押"));
        assert!(sounds_alike("制压", "质押"));
        assert!(!sounds_alike("苍蝇", "方向"));
        assert_eq!(
            decide(
                &Edit {
                    from: "解除质压".into(),
                    to: "解除质押".into(),
                    confidence: 0.85,
                },
                |_, _| false,
                |_, _| false
            ),
            Verdict::Apply
        );
        assert_eq!(
            decide(
                &Edit {
                    from: "苍蝇".into(),
                    to: "方向".into(),
                    confidence: 0.9,
                },
                |_, _| false,
                |_, _| false
            ),
            Verdict::Drop
        );
    }

    #[test]
    fn latin_spelling_and_proper_noun_ask() {
        assert_eq!(
            decide(
                &Edit {
                    from: "Kubernetes".into(),
                    to: "Kubernets".into(),
                    confidence: 0.85,
                },
                |_, _| false,
                |_, _| false
            ),
            Verdict::Apply
        );
        assert_eq!(
            decide(
                &Edit {
                    from: "莫拉".into(),
                    to: "Morpho".into(),
                    confidence: 0.88,
                },
                |_, _| false,
                |_, _| false
            ),
            Verdict::Ask
        );
        assert_eq!(
            decide(
                &Edit {
                    from: "平台".into(),
                    to: "platform".into(),
                    confidence: 0.95,
                },
                |_, _| false,
                |_, _| false
            ),
            Verdict::Drop
        );
    }

    #[test]
    fn apply_fixes_updates_text_and_spans() {
        let fixes = vec![
            LineFix {
                from: "制压".into(),
                to: "质押".into(),
                ask: None,
                off: None,
                user: None,
            },
            LineFix {
                from: "莫拉".into(),
                to: "Morpho".into(),
                ask: Some(true),
                off: None,
                user: None,
            },
        ];
        let (shown, marks) = apply_fixes(&fixes, "莫拉支持解除制压");
        assert_eq!(shown, "莫拉支持解除质押");
        assert_eq!(marks, vec![(6, 8)]);
    }

    #[test]
    fn user_edit_extracts_token_swap() {
        let res = user_edit("我们用莫拉做测试", "我们用Morpho做测试", "我们用莫拉做测试", &[]).unwrap();
        assert_eq!(res.0.from, "莫拉");
        assert_eq!(res.0.to, "Morpho");
        assert!(res.2);
    }

    #[test]
    fn english_phonetic_and_context_fixes_apply() {
        let cases = [
            ("two", "too", 0.95),
            ("ploy crusts", "pull requests", 0.95),
            ("Floydcrusts", "pull requests", 0.95),
            ("polar crests", "pull requests", 0.95),
            ("polar quests", "pull requests", 0.95),
            ("all flop", "all slop", 0.95),
            ("Dropbot at SpaceXSI", "Grokbot at xAI", 0.95),
        ];
        for (from, to, confidence) in cases {
            assert_eq!(
                decide(
                    &Edit {
                        from: from.into(),
                        to: to.into(),
                        confidence,
                    },
                    |_, _| false,
                    |_, _| false,
                ),
                Verdict::Apply,
                "expected Apply for {from} -> {to}"
            );
        }
    }
}
