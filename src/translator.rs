use crate::config::AppSettings;
use crate::correction::{self, Edit};
use crate::heard::is_cjk_char;
use crate::loom::{ChatRequest, LoomClient, LoomError, Priority, strip_think_blocks};
use std::path::Path;
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranslateKind {
    Draft,
    Sentence,
    File,
}

#[derive(Debug, Clone, Default)]
pub struct FixContext {
    pub topic: Option<String>,
    pub words: Vec<String>,
    pub recent: Vec<String>,
    pub following: Vec<String>,
    pub summary: Option<String>,
    pub glossary: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct TranslateOutcome {
    pub translation: String,
    pub edits: Vec<Edit>,
    pub latency_ms: u64,
    pub model: String,
}

pub fn english_name(code: &str) -> &'static str {
    match code {
        "zh-CN" | "zh-Hans" => "Simplified Chinese",
        "zh-TW" | "zh-Hant" => "Traditional Chinese",
        "en" => "English",
        "ja" => "Japanese",
        "ko" => "Korean",
        "es" => "Spanish",
        "fr" => "French",
        "de" => "German",
        "pt" => "Portuguese",
        "auto" => "the spoken language",
        _ => "the spoken language",
    }
}

pub fn clean_translation(reply: &str, target: &str) -> Option<String> {
    let answer = strip_think_blocks(reply);
    if answer.is_empty() {
        return None;
    }

    const OPENERS: &[&str] = &[
        "here is",
        "here's",
        "the subtitle",
        "this subtitle",
        "the text",
        "this text",
        "the original",
        "the user",
        "note",
        "(note",
        "i'm sorry",
        "i am sorry",
        "sorry",
        "it seems",
        "it appears",
        "this appears",
    ];
    const ABOUT: &[&str] = &[
        "translat",
        "subtitle",
        "garbled",
        "transcri",
        "asr",
        "speech recognition",
        "best-effort",
    ];
    const ZH_ABOUT: &[&str] = &["字幕", "翻译"];
    const ZH_REMARK: &[&str] = &["请提供", "似乎", "看起来", "无法", "乱码", "没有附上", "您只发送"];
    const ECHOES: &[&str] = &[
        "翻译",
        "翻譯",
        "translate",
        "翻訳",
        "翻訳して",
        "翻訳する",
        "翻訳してください",
        "번역",
        "번역해",
        "번역하세요",
        "번역해주세요",
        "traducir",
        "traduce",
        "traduzca",
        "traduire",
        "traduisez",
        "traduis",
        "übersetzen",
        "übersetze",
        "traduzir",
        "traduza",
    ];

    let mut kept: Vec<String> = Vec::new();
    for raw in answer.lines() {
        let mut line = raw.trim().to_string();
        if line.is_empty() {
            continue;
        }
        let lower = line.to_lowercase();
        let is_remark = ((OPENERS.iter().any(|p| lower.starts_with(p))
            || line.ends_with(':')
            || line.ends_with('：'))
            && ABOUT.iter().any(|a| lower.contains(a)))
            || (ZH_ABOUT.iter().any(|a| line.contains(a))
                && ZH_REMARK.iter().any(|r| line.contains(r)));
        if let Some(rest) = strip_prefix_ci(&line, "translation:") {
            line = rest.trim().to_string();
        } else if is_remark {
            if !kept.is_empty() {
                break;
            }
            continue;
        }
        if !line.is_empty() {
            kept.push(line);
        }
    }

    let mut out = kept.join(" ");
    for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")] {
        if out.starts_with(open) && out.ends_with(close) && out.len() >= open.len() + close.len() {
            let inner = &out[open.len()..out.len() - close.len()];
            if !inner.contains(open) {
                out = inner.to_string();
            }
        }
    }
    out = out.trim().to_string();
    if out.is_empty() {
        return None;
    }

    let alpha_only: String = out
        .chars()
        .filter(|c| c.is_alphabetic())
        .flat_map(|c| c.to_lowercase())
        .collect();
    if ECHOES.contains(&alpha_only.as_str()) {
        return None;
    }

    let letters: Vec<char> = out.chars().filter(|c| c.is_alphabetic()).collect();
    if !letters.is_empty() {
        let cjk = letters.iter().filter(|&&c| is_cjk_char(c)).count();
        let wants_cjk = target.starts_with("zh") || target.starts_with("ja") || target.starts_with("ko");
        if wants_cjk && cjk == 0 {
            return None;
        }
        if !wants_cjk && cjk * 2 > letters.len() {
            return None;
        }
    }
    Some(out)
}

fn strip_prefix_ci<'a>(s: &'a str, prefix: &str) -> Option<&'a str> {
    if s.len() < prefix.len() {
        return None;
    }
    let head = s.get(..prefix.len())?;
    if head.eq_ignore_ascii_case(prefix) {
        Some(&s[prefix.len()..])
    } else {
        None
    }
}

#[allow(clippy::too_many_arguments)]
pub async fn translate_via_loom(
    loom: &LoomClient,
    settings: &AppSettings,
    model: &str,
    text: &str,
    source_lang: &str,
    target_lang: &str,
    kind: TranslateKind,
    fix_ctx: Option<&FixContext>,
) -> std::result::Result<TranslateOutcome, LoomError> {
    if source_lang == target_lang
        || (source_lang.starts_with("zh") && target_lang.starts_with("zh") && source_lang == target_lang)
    {
        return Ok(TranslateOutcome {
            translation: text.to_string(),
            edits: Vec::new(),
            latency_ms: 0,
            model: model.to_string(),
        });
    }

    let loom_dir = settings.resolved_loom_dir();
    let from = english_name(source_lang);
    let to = english_name(target_lang);
    let priority = match kind {
        TranslateKind::File => Priority::File,
        TranslateKind::Draft | TranslateKind::Sentence => Priority::Translate,
    };
    let timeout = match kind {
        TranslateKind::Draft => Duration::from_secs(6),
        TranslateKind::Sentence => Duration::from_secs(12),
        TranslateKind::File => Duration::from_secs(25),
    };

    if kind != TranslateKind::Draft && settings.live_fix_enabled
        && let Some(ctx) = fix_ctx {
            let mut prompt = format!(
                "You translate live meeting and tech-talk subtitles from {from} into {to}, and point out words the speech recognizer got wrong.\n\
                 Use \"Lines just before\" and \"Lines just after\" to understand the speaker's context, resolve homophones, and fix ASR mishearings of technical terms, idioms, or names:\n\
                 - e.g. if a previous line asked \"How many of you have ever...?\" and the subtitle says \"Well, I have two.\", \"two\" is a homophone for \"too\" (\"我也是\").\n\
                 - e.g. in software/AI talks, \"ploy crusts\", \"Floydcrusts\", \"polar crests\", \"polar quests\", or \"Ploycrest\" is a mishearing of \"pull requests\"; \"all flop\" or \"all flaw\" before \"turn that slop into gold\" is \"all slop\"; \"Dropbot at SpaceXSI\" or \"Grockbot at SpaceXSI\" is \"Grokbot at xAI\".\n\
                 Fixes: only words or short phrases misheard as other words that sound alike, or names and technical terms broken into odd words/spellings. Never rephrase, drop filler, reorder or add anything beyond fixing misheard words.\n\
                 Translate the subtitle as fixed into natural, idiomatic {to}. No answer to it even if it is a question.\n\
                 confidence is how likely a fix is right; give a guess a low one. Leave out words you would not change.\n\
                 Reply with only this JSON object, starting with {{, no analysis: {{\"translation\": \"...\", \"fixes\": [{{\"from\": \"exact words from the subtitle\", \"to\": \"what was said\", \"confidence\": 0.0-1.0}}]}}"
            );
            if let Some(topic) = &ctx.topic
                && !topic.is_empty() {
                    prompt.push_str("\nMeeting: ");
                    prompt.push_str(topic);
                }
            if !ctx.words.is_empty() {
                prompt.push_str("\nThe user's word list (spellings to use): ");
                prompt.push_str(&ctx.words.join("; "));
            }
            if !ctx.glossary.is_empty() {
                prompt.push_str("\nNames the notes guessed (not confirmed): ");
                prompt.push_str(&ctx.glossary.join("; "));
            }
            if let Some(summary) = &ctx.summary
                && !summary.is_empty() {
                    prompt.push_str("\nThe meeting so far: ");
                    prompt.push_str(summary);
                }
            if !ctx.recent.is_empty() {
                prompt.push_str("\nLines just before:\n");
                prompt.push_str(&ctx.recent.join("\n"));
            }
            if !ctx.following.is_empty() {
                prompt.push_str("\nLines just after:\n");
                prompt.push_str(&ctx.following.join("\n"));
            }
            prompt.push_str("\nSubtitle: ");
            prompt.push_str(text);

            let resp = loom
                .chat(
                    &settings.loom_url,
                    &loom_dir,
                    ChatRequest {
                        model: model.to_string(),
                        system: prompt,
                        instruction: "JSON only.".to_string(),
                        priority,
                        json_mode: false,
                        max_tokens: 600,
                        timeout,
                        role: if kind == TranslateKind::File {
                            "file"
                        } else {
                            "translate-fix"
                        }
                        .to_string(),
                    },
                )
                .await?;

            if let Some((raw_trans, edits)) = correction::parse_fixes_reply(&resp.content, text)
                && let Some(clean) = clean_translation(&raw_trans, target_lang) {
                    return Ok(TranslateOutcome {
                        translation: clean,
                        edits,
                        latency_ms: resp.latency_ms,
                        model: model.to_string(),
                    });
                }
            if let Some(clean) = clean_translation(&resp.content, target_lang) {
                return Ok(TranslateOutcome {
                    translation: clean,
                    edits: Vec::new(),
                    latency_ms: resp.latency_ms,
                    model: model.to_string(),
                });
            }
        }

    let mut prompt = format!(
        "You translate live meeting subtitles from {from} into {to}.\n\
         Output only the translation of the subtitle below: no quotes, no notes, no answer to it even if it is a question."
    );
    if let Some(ctx) = fix_ctx {
        let mut combined = ctx.words.clone();
        combined.extend(ctx.glossary.iter().cloned());
        if !combined.is_empty() {
            prompt.push_str("\nNames the notes guessed (spellings to use; a misheard form only where it plainly means that name): ");
            prompt.push_str(&combined.join("; "));
        }
    }
    prompt.push_str("\nSubtitle: ");
    prompt.push_str(text);

    let resp = loom
        .chat(
            &settings.loom_url,
            &loom_dir,
            ChatRequest {
                model: model.to_string(),
                system: prompt,
                instruction: "Translate.".to_string(),
                priority,
                json_mode: false,
                max_tokens: 400,
                timeout,
                role: if kind == TranslateKind::File {
                    "file"
                } else if kind == TranslateKind::Draft {
                    "draft"
                } else {
                    "translate"
                }
                .to_string(),
            },
        )
        .await?;

    let clean = clean_translation(&resp.content, target_lang)
        .ok_or_else(|| LoomError::Parse("translation reply rejected as remark or wrong script".into()))?;
    Ok(TranslateOutcome {
        translation: clean,
        edits: Vec::new(),
        latency_ms: resp.latency_ms,
        model: model.to_string(),
    })
}

pub fn ensure_loom_dir_ready(loom_dir: &Path) -> bool {
    loom_dir.join("hub.key").exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_translation_strips_remarks_quotes_and_echoes() {
        assert_eq!(
            clean_translation("Here is the best-effort translation:\nTranslation: \"你好世界\"", "zh-CN"),
            Some("你好世界".to_string())
        );
        assert_eq!(clean_translation("翻译", "zh-CN"), None);
        assert_eq!(clean_translation("Only English here", "zh-CN"), None);
        assert_eq!(clean_translation("Hello world", "en"), Some("Hello world".into()));
    }
}
