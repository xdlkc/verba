use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BinaryHeap, HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tokio::sync::Notify;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Priority {
    Translate = 0,
    Notes = 1,
    File = 2,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LoomModelInfo {
    pub id: String,
    pub provider: String,
    pub owned_by: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LoomStatus {
    pub connected: bool,
    pub runtime: Option<String>,
    pub key_present: bool,
    pub loom_url: String,
    pub models: Vec<LoomModelInfo>,
    pub active_translate_model: Option<String>,
    pub active_notes_model: Option<String>,
    pub last_error: Option<String>,
    pub checked_at: Option<DateTime<Utc>>,
}

impl Default for LoomStatus {
    fn default() -> Self {
        Self {
            connected: false,
            runtime: None,
            key_present: false,
            loom_url: "http://127.0.0.1:4319/v1".to_string(),
            models: Vec::new(),
            active_translate_model: None,
            active_notes_model: None,
            last_error: None,
            checked_at: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoomCallRecord {
    pub at: DateTime<Utc>,
    pub model: String,
    pub role: String,
    pub latency_ms: u64,
    pub outcome: String,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoomError {
    NoKey(String),
    InvalidKey,
    RateLimited,
    Hijacked,
    Timeout,
    Unreachable(String),
    Http(u16, String),
    Parse(String),
}

impl std::fmt::Display for LoomError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoKey(msg) => write!(f, "no hub.key: {msg}"),
            Self::InvalidKey => write!(f, "Loom hub.key rejected (401/403)"),
            Self::RateLimited => write!(f, "rate limited (429)"),
            Self::Hijacked => write!(f, "search-style reply dropped"),
            Self::Timeout => write!(f, "request timed out"),
            Self::Unreachable(msg) => write!(f, "Loom unreachable: {msg}"),
            Self::Http(code, msg) => write!(f, "HTTP {code}: {msg}"),
            Self::Parse(msg) => write!(f, "parse error: {msg}"),
        }
    }
}

impl std::error::Error for LoomError {}

#[derive(Debug, Clone)]
pub struct ChatRequest {
    pub model: String,
    pub system: String,
    pub instruction: String,
    pub priority: Priority,
    pub json_mode: bool,
    pub max_tokens: u32,
    pub timeout: Duration,
    pub role: String,
}

#[derive(Debug, Clone)]
pub struct ChatResponse {
    pub content: String,
    pub latency_ms: u64,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

struct GateEntry {
    priority: u8,
    seq: u64,
}

impl PartialEq for GateEntry {
    fn eq(&self, other: &Self) -> bool {
        self.priority == other.priority && self.seq == other.seq
    }
}
impl Eq for GateEntry {}
impl PartialOrd for GateEntry {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for GateEntry {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        // Reverse for min-heap behavior
        (other.priority, other.seq).cmp(&(self.priority, self.seq))
    }
}

struct PriorityGate {
    max_concurrent: usize,
    state: Mutex<GateState>,
    notify: Notify,
}

struct GateState {
    active: usize,
    next_seq: u64,
    queue: BinaryHeap<GateEntry>,
}

impl PriorityGate {
    fn new(max_concurrent: usize) -> Self {
        Self {
            max_concurrent,
            state: Mutex::new(GateState {
                active: 0,
                next_seq: 0,
                queue: BinaryHeap::new(),
            }),
            notify: Notify::new(),
        }
    }

    async fn acquire(&self, priority: Priority) -> GateGuard<'_> {
        let seq = {
            let mut st = self.state.lock().unwrap();
            if st.active < self.max_concurrent && st.queue.is_empty() {
                st.active += 1;
                return GateGuard { gate: self };
            }
            st.next_seq += 1;
            let seq = st.next_seq;
            st.queue.push(GateEntry {
                priority: priority as u8,
                seq,
            });
            seq
        };

        loop {
            {
                let mut st = self.state.lock().unwrap();
                if st.active < self.max_concurrent
                    && let Some(top) = st.queue.peek()
                        && top.seq == seq {
                            st.queue.pop();
                            st.active += 1;
                            return GateGuard { gate: self };
                        }
            }
            self.notify.notified().await;
        }
    }
}

struct GateGuard<'a> {
    gate: &'a PriorityGate,
}

impl Drop for GateGuard<'_> {
    fn drop(&mut self) {
        {
            let mut st = self.gate.state.lock().unwrap();
            st.active = st.active.saturating_sub(1);
        }
        self.gate.notify.notify_waiters();
    }
}

#[derive(Default)]
struct ModelQuirks {
    no_thinking_field: HashSet<String>,
    no_json_mode: HashSet<String>,
    use_reasoning_effort: HashSet<String>,
}

pub struct LoomClient {
    http: reqwest::Client,
    gate: PriorityGate,
    quirks: Mutex<ModelQuirks>,
    calls: Mutex<Vec<LoomCallRecord>>,
}

impl LoomClient {
    pub fn new() -> Self {
        let http = reqwest::Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .build()
            .expect("reqwest client");
        Self {
            http,
            gate: PriorityGate::new(3),
            quirks: Mutex::new(ModelQuirks::default()),
            calls: Mutex::new(Vec::new()),
        }
    }

    pub fn discover_key(loom_dir: &Path) -> std::result::Result<String, LoomError> {
        let key_path = loom_dir.join("hub.key");
        let raw = fs::read_to_string(&key_path)
            .map_err(|e| LoomError::NoKey(format!("{}: {e}", key_path.display())))?;
        let trimmed = raw.trim().to_string();
        if trimmed.is_empty() {
            return Err(LoomError::NoKey(format!("{} is empty", key_path.display())));
        }
        Ok(trimmed)
    }

    pub fn health_url(loom_url: &str) -> String {
        let base = loom_url.trim().trim_end_matches('/');
        let root = base.strip_suffix("/v1").unwrap_or(base);
        format!("{root}/health")
    }

    pub fn endpoint(loom_url: &str, path: &str) -> String {
        let base = loom_url.trim().trim_end_matches('/');
        let path = path.trim_start_matches('/');
        format!("{base}/{path}")
    }

    pub async fn check_health(&self, loom_url: &str) -> std::result::Result<Option<String>, LoomError> {
        let url = Self::health_url(loom_url);
        let resp = self
            .http
            .get(&url)
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .map_err(|e| LoomError::Unreachable(e.to_string()))?;
        if !resp.status().is_success() {
            return Err(LoomError::Http(resp.status().as_u16(), "health check failed".into()));
        }
        let body: Value = resp
            .json()
            .await
            .map_err(|e| LoomError::Parse(e.to_string()))?;
        let ok = body.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
        if !ok {
            return Err(LoomError::Unreachable("health ok != true".into()));
        }
        Ok(body
            .get("runtime")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()))
    }

    pub async fn fetch_models(
        &self,
        loom_url: &str,
        loom_dir: &Path,
    ) -> std::result::Result<Vec<LoomModelInfo>, LoomError> {
        let key = Self::discover_key(loom_dir)?;
        let url = Self::endpoint(loom_url, "models");
        let resp = self
            .http
            .get(&url)
            .bearer_auth(&key)
            .timeout(Duration::from_secs(8))
            .send()
            .await
            .map_err(|e| LoomError::Unreachable(e.to_string()))?;
        let status = resp.status();
        if status.as_u16() == 401 || status.as_u16() == 403 {
            return Err(LoomError::InvalidKey);
        }
        if !status.is_success() {
            let msg = resp.text().await.unwrap_or_default();
            return Err(LoomError::Http(status.as_u16(), truncate_msg(&msg)));
        }
        let val: Value = resp
            .json()
            .await
            .map_err(|e| LoomError::Parse(e.to_string()))?;
        let data = val
            .get("data")
            .and_then(|d| d.as_array())
            .ok_or_else(|| LoomError::Parse("missing data array in /models".into()))?;
        let provider_names = read_provider_names(loom_dir);
        let mut out = Vec::new();
        for item in data {
            let Some(id) = item.get("id").and_then(|v| v.as_str()) else {
                continue;
            };
            let prefix = id.split('/').next().unwrap_or("loom");
            let provider = provider_names
                .get(prefix)
                .cloned()
                .unwrap_or_else(|| prefix.to_string());
            let owned_by = item
                .get("owned_by")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            out.push(LoomModelInfo {
                id: id.to_string(),
                provider,
                owned_by,
            });
        }
        Ok(out)
    }

    pub async fn probe_status(
        &self,
        loom_url: &str,
        loom_dir: &Path,
        configured_translate: &str,
        configured_notes: &str,
    ) -> LoomStatus {
        let mut st = LoomStatus {
            loom_url: loom_url.to_string(),
            checked_at: Some(Utc::now()),
            ..Default::default()
        };
        st.key_present = Self::discover_key(loom_dir).is_ok();
        match self.check_health(loom_url).await {
            Ok(rt) => {
                st.runtime = rt;
            }
            Err(e) => {
                st.last_error = Some(e.to_string());
                return st;
            }
        }
        match self.fetch_models(loom_url, loom_dir).await {
            Ok(models) => {
                st.connected = true;
                st.active_translate_model = pick_translate_model(&models, configured_translate);
                st.active_notes_model = pick_notes_model(&models, configured_notes);
                st.models = models;
            }
            Err(e) => {
                st.last_error = Some(e.to_string());
            }
        }
        st
    }

    pub async fn chat(
        &self,
        loom_url: &str,
        loom_dir: &Path,
        req: ChatRequest,
    ) -> std::result::Result<ChatResponse, LoomError> {
        let key = Self::discover_key(loom_dir)?;
        let _guard = self.gate.acquire(req.priority).await;
        let started = Instant::now();

        let (mut allow_thinking_obj, mut allow_json, mut use_effort) = {
            let q = self.quirks.lock().unwrap();
            (
                !q.no_thinking_field.contains(&req.model),
                req.json_mode && !q.no_json_mode.contains(&req.model),
                q.use_reasoning_effort.contains(&req.model),
            )
        };

        let mut attempts = 0;
        loop {
            attempts += 1;
            let body = build_chat_body(&req, allow_thinking_obj, allow_json, use_effort);
            let url = Self::endpoint(loom_url, "chat/completions");
            let resp = self
                .http
                .post(&url)
                .bearer_auth(&key)
                .timeout(req.timeout)
                .json(&body)
                .send()
                .await;
            let resp = match resp {
                Ok(r) => r,
                Err(e) if e.is_timeout() => {
                    self.record_call(&req, started, "timeout", 0, 0);
                    return Err(LoomError::Timeout);
                }
                Err(e) => {
                    let msg = e.to_string();
                    self.record_call(&req, started, "unreachable", 0, 0);
                    return Err(LoomError::Unreachable(msg));
                }
            };

            let code = resp.status().as_u16();
            if code == 401 || code == 403 {
                self.record_call(&req, started, "invalidKey", 0, 0);
                return Err(LoomError::InvalidKey);
            }
            if code == 429 {
                self.record_call(&req, started, "rateLimited", 0, 0);
                return Err(LoomError::RateLimited);
            }
            if (code == 400 || code == 422) && attempts <= 3 {
                let err_txt = resp.text().await.unwrap_or_default();
                let lower = err_txt.to_lowercase();
                if allow_json && (lower.contains("response_format") || lower.contains("json_object")) {
                    allow_json = false;
                    self.quirks.lock().unwrap().no_json_mode.insert(req.model.clone());
                    continue;
                }
                if allow_thinking_obj
                    && (lower.contains("thinking") || lower.contains("unknown") || lower.contains("extra"))
                {
                    allow_thinking_obj = false;
                    self.quirks
                        .lock()
                        .unwrap()
                        .no_thinking_field
                        .insert(req.model.clone());
                    continue;
                }
                if allow_json {
                    allow_json = false;
                    self.quirks.lock().unwrap().no_json_mode.insert(req.model.clone());
                    continue;
                }
                if !use_effort && lower.contains("reasoning") {
                    use_effort = true;
                    self.quirks
                        .lock()
                        .unwrap()
                        .use_reasoning_effort
                        .insert(req.model.clone());
                    continue;
                }
                self.record_call(&req, started, &format!("http{code}"), 0, 0);
                return Err(LoomError::Http(code, truncate_msg(&err_txt)));
            }
            if code != 200 {
                let err_txt = resp.text().await.unwrap_or_default();
                self.record_call(&req, started, &format!("http{code}"), 0, 0);
                return Err(LoomError::Http(code, truncate_msg(&err_txt)));
            }

            let root: Value = resp.json().await.map_err(|e| {
                self.record_call(&req, started, "parse", 0, 0);
                LoomError::Parse(e.to_string())
            })?;
            let choice = root
                .get("choices")
                .and_then(|c| c.as_array())
                .and_then(|a| a.first())
                .ok_or_else(|| LoomError::Parse("missing choices[0]".into()))?;
            let raw_content = extract_message_text(choice).ok_or_else(|| {
                self.record_call(&req, started, "parse", 0, 0);
                LoomError::Parse("missing choices[0].message.content".into())
            })?;
            let trimmed = strip_think_blocks(&raw_content);
            if is_hijacked_reply(&trimmed) {
                self.record_call(&req, started, "hijacked", 0, 0);
                return Err(LoomError::Hijacked);
            }
            let prompt_tokens = root
                .pointer("/usage/prompt_tokens")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            let completion_tokens = root
                .pointer("/usage/completion_tokens")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            let latency_ms = started.elapsed().as_millis() as u64;
            self.record_call(&req, started, "ok", prompt_tokens, completion_tokens);
            return Ok(ChatResponse {
                content: trimmed,
                latency_ms,
                prompt_tokens,
                completion_tokens,
            });
        }
    }

    pub fn recent_calls(&self) -> Vec<LoomCallRecord> {
        self.calls.lock().unwrap().clone()
    }

    fn record_call(
        &self,
        req: &ChatRequest,
        started: Instant,
        outcome: &str,
        prompt_tokens: u64,
        completion_tokens: u64,
    ) {
        let mut calls = self.calls.lock().unwrap();
        calls.push(LoomCallRecord {
            at: Utc::now(),
            model: req.model.clone(),
            role: req.role.clone(),
            latency_ms: started.elapsed().as_millis() as u64,
            outcome: outcome.to_string(),
            prompt_tokens,
            completion_tokens,
        });
        if calls.len() > 200 {
            let excess = calls.len() - 200;
            calls.drain(0..excess);
        }
    }
}

impl Default for LoomClient {
    fn default() -> Self {
        Self::new()
    }
}

fn build_chat_body(
    req: &ChatRequest,
    allow_thinking_obj: bool,
    allow_json: bool,
    use_effort: bool,
) -> Value {
    let mut map = serde_json::Map::new();
    map.insert("model".into(), json!(req.model));
    map.insert(
        "messages".into(),
        json!([
            {"role": "system", "content": req.system},
            {"role": "user", "content": req.instruction},
        ]),
    );
    map.insert("stream".into(), json!(false));
    map.insert("max_tokens".into(), json!(req.max_tokens));

    if allow_thinking_obj {
        let lower = req.model.to_lowercase();
        if lower.contains("ling")
            || lower.contains("deepseek")
            || lower.contains("glm")
            || lower.contains("kimi")
            || lower.contains("minimax")
            || lower.contains("qwen")
        {
            map.insert("thinking".into(), json!({"type": "disabled"}));
        }
    }
    if use_effort {
        map.insert("reasoning_effort".into(), json!("none"));
    }
    if allow_json {
        map.insert("response_format".into(), json!({"type": "json_object"}));
    }
    Value::Object(map)
}

fn extract_message_text(choice: &Value) -> Option<String> {
    let content = choice.pointer("/message/content")?;
    if let Some(s) = content.as_str() {
        return Some(s.to_string());
    }
    if let Some(arr) = content.as_array() {
        let mut buf = String::new();
        for part in arr {
            if let Some(text) = part.get("text").and_then(|v| v.as_str()) {
                buf.push_str(text);
            }
        }
        if !buf.is_empty() {
            return Some(buf);
        }
    }
    None
}

pub fn strip_think_blocks(raw: &str) -> String {
    let after_close = raw.rsplit("</think>").next().unwrap_or(raw);
    let cleaned = if let Some(open) = after_close.find("<think>") {
        &after_close[..open]
    } else {
        after_close
    };
    cleaned.trim().to_string()
}

fn is_hijacked_reply(text: &str) -> bool {
    const HIJACK_PREFIXES: &[&str] = &["根据现有检索证据", "暂未找到足够可靠的信息", "根据检索"];
    HIJACK_PREFIXES.iter().any(|p| text.starts_with(p))
}

fn truncate_msg(s: &str) -> String {
    let trimmed = s.trim();
    if trimmed.chars().count() <= 200 {
        trimmed.to_string()
    } else {
        let head: String = trimmed.chars().take(200).collect();
        format!("{head}…")
    }
}

fn read_provider_names(loom_dir: &Path) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let path = loom_dir.join("providers.json");
    let Ok(bytes) = fs::read(path) else {
        return map;
    };
    let Ok(root) = serde_json::from_slice::<Value>(&bytes) else {
        return map;
    };
    let Some(providers) = root.get("providers").and_then(|p| p.as_object()) else {
        return map;
    };
    for p in providers.values() {
        if let (Some(prefix), Some(name)) = (
            p.get("prefix").and_then(|v| v.as_str()),
            p.get("name").and_then(|v| v.as_str()),
        ) {
            map.insert(prefix.to_string(), name.to_string());
        }
    }
    map
}

pub fn pick_translate_model(models: &[LoomModelInfo], configured: &str) -> Option<String> {
    let cfg = configured.trim();
    if !cfg.is_empty() && models.iter().any(|m| m.id == cfg) {
        return Some(cfg.to_string());
    }
    const PREFERRED: &[&str] = &[
        "zenmux/inclusionai/ling-3.1-flash",
        "zenmux/inclusionai/ling-3.0-flash",
        "glm/glm-5.3-flash",
        "glm/glm-5.3-flashx",
        "deepseek/deepseek-flash",
        "minimax/MiniMax-M3.1-Flash",
        "zenmux/xiaomi/mimo-v2.6-flash",
        "longcat/LongCat-2.5",
        "zenmux/anthropic/claude-haiku-5.5",
    ];
    for id in PREFERRED {
        if models.iter().any(|m| m.id == *id) {
            return Some((*id).to_string());
        }
    }
    models
        .iter()
        .find(|m| m.id.to_lowercase().contains("flash"))
        .or_else(|| models.first())
        .map(|m| m.id.clone())
}

pub fn pick_notes_model(models: &[LoomModelInfo], configured: &str) -> Option<String> {
    let cfg = configured.trim();
    if !cfg.is_empty() && models.iter().any(|m| m.id == cfg) {
        return Some(cfg.to_string());
    }
    const PREFERRED: &[&str] = &[
        "zenmux/inclusionai/ling-3.1-flash",
        "deepseek/deepseek-v4-pro",
        "glm/glm-5.3",
        "kimi/k3.1-pro-highspeed",
        "minimax/MiniMax-M3.1-Flash",
        "zenmux/xiaomi/mimo-v2.6-pro",
        "zenmux/anthropic/claude-sonnet-5.5",
        "deepseek/deepseek-flash",
    ];
    for id in PREFERRED {
        if models.iter().any(|m| m.id == *id) {
            return Some((*id).to_string());
        }
    }
    models.first().map(|m| m.id.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Router, routing::get, routing::post};
    use tempfile::TempDir;
    use tokio::net::TcpListener;

    #[test]
    fn model_picker_prefers_flash_for_translation() {
        let catalog = vec![
            LoomModelInfo {
                id: "deepseek/deepseek-v4-pro".into(),
                provider: "DeepSeek".into(),
                owned_by: None,
            },
            LoomModelInfo {
                id: "zenmux/inclusionai/ling-3.1-flash".into(),
                provider: "ZenMux".into(),
                owned_by: None,
            },
        ];
        assert_eq!(
            pick_translate_model(&catalog, "").as_deref(),
            Some("zenmux/inclusionai/ling-3.1-flash")
        );
        assert_eq!(
            pick_notes_model(&catalog, "deepseek/deepseek-v4-pro").as_deref(),
            Some("deepseek/deepseek-v4-pro")
        );
    }

    #[test]
    fn strip_think_blocks_handles_complete_and_truncated() {
        assert_eq!(strip_think_blocks("<think>hmm</think>\n你好"), "你好");
        assert_eq!(strip_think_blocks("<think>cut off mid thought"), "");
    }

    #[tokio::test]
    async fn mock_loom_gateway_round_trip() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("hub.key"), "hub-test-secret\n").unwrap();

        let app = Router::new()
            .route(
                "/health",
                get(|| async { axum::Json(json!({"ok": true, "runtime": "rust"})) }),
            )
            .route(
                "/v1/models",
                get(|| async {
                    axum::Json(json!({
                        "data": [
                            {"id": "zenmux/inclusionai/ling-3.1-flash", "owned_by": "zenmux"},
                            {"id": "deepseek/deepseek-flash", "owned_by": "deepseek"}
                        ]
                    }))
                }),
            )
            .route(
                "/v1/chat/completions",
                post(|axum::Json(body): axum::Json<Value>| async move {
                    if body.get("response_format").is_some() {
                        return (
                            axum::http::StatusCode::BAD_REQUEST,
                            "response_format unsupported",
                        )
                            .into_response();
                    }
                    axum::Json(json!({
                        "choices": [{"message": {"content": "你好，世界"}}],
                        "usage": {"prompt_tokens": 12, "completion_tokens": 4}
                    }))
                    .into_response()
                }),
            );
        use axum::response::IntoResponse;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });

        let base = format!("http://{addr}/v1");
        let client = LoomClient::new();
        let status = client.probe_status(&base, dir.path(), "", "").await;
        assert!(status.connected);
        assert_eq!(
            status.active_translate_model.as_deref(),
            Some("zenmux/inclusionai/ling-3.1-flash")
        );

        let reply = client
            .chat(
                &base,
                dir.path(),
                ChatRequest {
                    model: "zenmux/inclusionai/ling-3.1-flash".into(),
                    system: "Translate hello world".into(),
                    instruction: "Translate.".into(),
                    priority: Priority::Translate,
                    json_mode: true,
                    max_tokens: 100,
                    timeout: Duration::from_secs(5),
                    role: "translate".into(),
                },
            )
            .await
            .unwrap();
        assert_eq!(reply.content, "你好，世界");
    }
}
