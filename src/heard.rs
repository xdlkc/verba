use regex::Regex;
use std::collections::HashSet;
use std::sync::LazyLock;

static RE_DOTS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*[.。]{2,}|\s*…+").unwrap());
static RE_ELLIPSIS_CHAIN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"…(?:[\s,，]*…)+").unwrap());
static RE_COMMAS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"([,，])(?:\s*[,，])+").unwrap());
static RE_COMMA_ELLIPSIS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[,，]\s*…|…\s*[,，]").unwrap());
static RE_SPACE_PUNCT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s+([,，.。…?？!！;；:：])").unwrap());
static RE_MULTI_SPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s{2,}").unwrap());

const LEAD_CHARS: &[char] = &[
    '.', ',', ';', ':', '!', '?', '…', '、', '，', '。', '；', '：', '！', '？', '-', '–',
    '—',
];

pub const JOIN_GAP: f64 = 1.5;
pub const JOIN_WORDS: usize = 40;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Boundary {
    Word = 0,
    Clause = 1,
    Sentence = 2,
}

static CONNECTIVES: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    [
        "所以", "但是", "因为", "然后", "可是", "而且", "不过", "其实", "反正", "如果", "虽然",
        "或者", "另外", "接下来", "总之", "因此", "于是", "就是说",
    ]
    .into_iter()
    .collect()
});

static PARTICLES: LazyLock<HashSet<char>> =
    LazyLock::new(|| ['吧', '呢', '吗', '啊', '嘛', '呀', '啦'].into_iter().collect());

pub fn is_cjk_char(c: char) -> bool {
    let u = c as u32;
    (0x3040..=0x30FF).contains(&u) || (0x3400..=0x9FFF).contains(&u) || (0xAC00..=0xD7AF).contains(&u)
}

pub fn is_cjk(text: &str) -> bool {
    text.chars().any(is_cjk_char)
}

pub fn text_size(text: &str) -> usize {
    if is_cjk(text) {
        text.chars().filter(|c| c.is_alphabetic()).count()
    } else {
        text.split_whitespace()
            .filter(|w| w.chars().any(|c| c.is_alphanumeric()))
            .count()
    }
}

pub fn clean(text: &str) -> String {
    let s = RE_DOTS.replace_all(text, "…");
    let s = RE_ELLIPSIS_CHAIN.replace_all(&s, "…");
    let s = RE_COMMAS.replace_all(&s, "$1");
    let s = RE_COMMA_ELLIPSIS.replace_all(&s, "…");
    let s = RE_SPACE_PUNCT.replace_all(&s, "$1");
    let s = RE_MULTI_SPACE.replace_all(&s, " ");
    let trimmed = s.trim_start_matches(|c: char| LEAD_CHARS.contains(&c) || c.is_whitespace());
    trimmed.trim().to_string()
}

pub fn fuller(final_text: &str, draft: &str) -> String {
    let combined_cjk = is_cjk(final_text) || is_cjk(draft);
    let count = |s: &str| -> usize {
        if combined_cjk {
            s.chars().filter(|c| c.is_alphanumeric()).count()
        } else {
            s.split_whitespace()
                .filter(|w| w.chars().any(|c| c.is_alphanumeric()))
                .count()
        }
    };
    let f = count(final_text);
    let d = count(draft);
    let min_gain = if combined_cjk { 6 } else { 3 };
    if d >= f + min_gain && (d as f64) >= (f as f64) * 1.15 {
        clean(draft)
    } else {
        final_text.to_string()
    }
}

pub fn ends_in_latin(text: &str) -> bool {
    let mut latin = 0usize;
    for ch in text.chars().rev() {
        if is_cjk_char(ch) {
            break;
        }
        if ch.is_ascii_alphabetic() {
            latin += 1;
        }
    }
    latin >= 15
}

pub fn ends_sentence(draft: &str) -> bool {
    let t = draft.trim();
    let Some(last) = t.chars().last() else {
        return false;
    };
    if !matches!(last, '。' | '！' | '？' | '.' | '!' | '?') || t.ends_with("..") {
        return false;
    }
    if last == '.' {
        let mut iter = t.chars().rev();
        iter.next();
        if iter.next().is_some_and(|c| c.is_ascii_digit()) {
            return false;
        }
    }
    if is_cjk(t) {
        t.chars().filter(|c| c.is_alphabetic()).count() >= 12
    } else {
        t.split(' ').filter(|w| !w.is_empty()).count() >= 5
    }
}

pub fn split_at_sentence_end(text: &str) -> Option<(String, String)> {
    let mut indices: Vec<(usize, char)> = text.char_indices().collect();
    while let Some((byte_idx, ch)) = indices.pop() {
        if !matches!(ch, '。' | '！' | '？' | '.' | '!' | '?') {
            continue;
        }
        let end_byte = byte_idx + ch.len_utf8();
        let head = &text[..end_byte];
        if !ends_sentence(head) {
            continue;
        }
        let tail = text[end_byte..].trim();
        if tail.chars().any(|c| c.is_alphabetic()) {
            return Some((head.trim().to_string(), tail.to_string()));
        }
    }
    None
}

pub fn clause_from(code: &str) -> usize {
    if code.starts_with("zh") {
        24
    } else if code == "ja" {
        40
    } else {
        20
    }
}

pub fn capped(code: &str) -> usize {
    if code.starts_with("zh") || code.starts_with("ja") {
        60
    } else {
        25
    }
}

pub fn boundaries(text: &str, code: &str) -> Vec<(usize, Boundary)> {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() < 2 {
        return Vec::new();
    }
    let mut map: std::collections::BTreeMap<usize, Boundary> = std::collections::BTreeMap::new();
    let mut add = |at: usize, kind: Boundary| {
        if at > 0 && at < chars.len() {
            map.entry(at)
                .and_modify(|cur| {
                    if kind > *cur {
                        *cur = kind;
                    }
                })
                .or_insert(kind);
        }
    };
    let is_comma = |c: char| -> bool {
        if code.starts_with("zh") {
            c == '，' || c == ','
        } else if code == "ja" {
            c == '、' || c == '，'
        } else {
            c == ','
        }
    };
    for (i, &ch) in chars.iter().enumerate() {
        if matches!(ch, '。' | '！' | '？' | '!' | '?') || (ch == '.' && i + 1 < chars.len()) {
            add(i + 1, Boundary::Sentence);
        }
        if is_comma(ch) {
            add(i + 1, Boundary::Clause);
        }
        if ch.is_whitespace() && i + 1 < chars.len() && !chars[i + 1].is_whitespace() {
            add(i + 1, Boundary::Word);
        }
        if code.starts_with("zh") && is_cjk_char(ch) {
            add(i, Boundary::Word);
            if PARTICLES.contains(&ch) {
                add(i + 1, Boundary::Clause);
            }
        }
    }
    if code.starts_with("zh") {
        let mut matched: Vec<(usize, usize)> = Vec::new();
        for p in 0..chars.len() {
            for len in [3usize, 2usize] {
                if p + len <= chars.len() {
                    let sub: String = chars[p..p + len].iter().collect();
                    if CONNECTIVES.contains(sub.as_str()) {
                        matched.push((p, len));
                        break;
                    }
                }
            }
        }
        for &(p, _len) in &matched {
            if !matched.iter().any(|&(op, olen)| op + olen == p) {
                add(p, Boundary::Clause);
            }
        }
        for &(p, len) in &matched {
            for inner in (p + 1)..(p + len) {
                if map.get(&inner) == Some(&Boundary::Word) {
                    map.remove(&inner);
                }
            }
        }
    }
    map.into_iter()
        .map(|(at, kind)| {
            let mut a = at;
            while a < chars.len() && chars[a].is_whitespace() {
                a += 1;
            }
            (a, kind)
        })
        .collect()
}

pub fn split_near(
    text: &str,
    near: usize,
    kind: Boundary,
    code: &str,
) -> Option<(String, String)> {
    let chars: Vec<char> = text.chars().collect();
    let find = |min_kind: Boundary, within: usize| -> Option<(String, String)> {
        let bounds = boundaries(text, code);
        let best = bounds
            .into_iter()
            .filter(|&(at, k)| {
                if k < min_kind || at.abs_diff(near) > within {
                    return false;
                }
                let head: String = chars[..at].iter().collect();
                let tail: String = chars[at..].iter().collect();
                let min_head = if is_cjk(&head) { 12 } else { 5 };
                text_size(&head) >= min_head && tail.chars().any(|c| c.is_alphabetic())
            })
            .min_by_key(|&(at, k)| (at.abs_diff(near), -(k as isize)))?;
        let head: String = chars[..best.0].iter().collect();
        let tail: String = chars[best.0..].iter().collect();
        Some((head.trim().to_string(), tail.trim().to_string()))
    };
    find(kind, (near / 3).max(8)).or_else(|| {
        if kind > Boundary::Word {
            find(Boundary::Word, 3)
        } else {
            None
        }
    })
}

pub fn continues(previous: &str, next: &str, gap: f64, cut: bool) -> bool {
    if !(-0.5..=JOIN_GAP).contains(&gap) {
        return false;
    }
    let Some(last) = previous.chars().last() else {
        return false;
    };
    let Some(first) = next.chars().next() else {
        return false;
    };
    let cjk = previous.chars().any(is_cjk_char);
    let size = if cjk {
        previous.chars().count() / 2
    } else {
        previous.split(' ').filter(|s| !s.is_empty()).count()
    };
    if size >= JOIN_WORDS {
        return false;
    }
    let combined = format!("{previous}{next}");
    if is_cjk(&combined) && text_size(&combined) > capped("zh") {
        return false;
    }
    match last {
        '?' | '!' | '？' | '！' => false,
        '.' | '。' => cut && first.is_lowercase(),
        _ => true,
    }
}

pub fn join(previous: &str, next: &str) -> String {
    let cjk = previous.chars().any(is_cjk_char);
    let mut head = previous.to_string();
    if head.ends_with('.') && !head.ends_with("…") {
        head.pop();
    }
    if head.ends_with('。') {
        head.pop();
    }
    if cjk {
        format!("{head}{next}")
    } else {
        format!("{head} {next}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_removes_asr_artifacts() {
        assert_eq!(clean(", ,  hello   world ."), "hello world.");
        assert_eq!(clean("in.........."), "in…");
        assert_eq!(clean("— , that is"), "that is");
    }

    #[test]
    fn fuller_keeps_richer_draft() {
        assert_eq!(
            fuller("needs budget", "needs the budget for next year by the end of this month"),
            "needs the budget for next year by the end of this month"
        );
        assert_eq!(fuller("hello world today", "hello world"), "hello world today");
    }

    #[test]
    fn continues_and_join_behavior() {
        assert!(continues("We are going to be.", "in the office", 0.5, true));
        assert!(!continues("Are you ready?", "Yes", 0.3, true));
        assert_eq!(
            join("We are going to be.", "in the office"),
            "We are going to be in the office"
        );
        assert_eq!(join("我们今天。", "先讨论这个"), "我们今天先讨论这个");
    }

    #[test]
    fn split_sentence_end_works() {
        let split = split_at_sentence_end("前回の会議で決定した事項について共有します。今回は次のフェーズに進みます")
            .unwrap();
        assert_eq!(split.0, "前回の会議で決定した事項について共有します。");
        assert_eq!(split.1, "今回は次のフェーズに進みます");
    }
}
