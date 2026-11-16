use crate::config::{
    AppSettings, ObsidianVault, VocabEntry, discover_obsidian_vaults, load_settings, save_settings,
    write_atomic,
};
use crate::correction::{self, Verdict};
use crate::export::{ExportIndex, safe_filename, session_markdown, session_srt, sync_folder_export};
use crate::heard;
use crate::loom::{LoomCallRecord, LoomClient, LoomError, LoomStatus};
use crate::notes;
use crate::search::{SearchHit, search_sessions};
use crate::store::{
    LineFix, MeetingNotes, Session, SessionStore, SessionSummary, TranscriptLine,
};
use crate::translator::{FixContext, TranslateKind, translate_via_loom};
use axum::extract::{Path as AxumPath, Query, State};
use axum::http::{StatusCode, header};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use futures_util::stream::{self, Stream, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::convert::Infallible;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::{Mutex, RwLock, broadcast};

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

fn next_uid(prefix: &str) -> String {
    let n = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let ts = Utc::now().timestamp_millis();
    format!("{prefix}-{ts:x}-{n}")
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DraftSubtitle {
    pub speaker: String,
    pub src: String,
    pub dst: Option<String>,
    pub src_lang: String,
    pub dst_lang: String,
    pub t: f64,
    pub voice: Option<i32>,
    pub via: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ServerEvent {
    StateChanged,
    LoomStatus {
        status: LoomStatus,
    },
    SettingsUpdated {
        settings: AppSettings,
    },
    DraftUpdated {
        draft: Option<DraftSubtitle>,
    },
    #[serde(rename_all = "camelCase")]
    LineUpdated {
        session_id: String,
        line: TranscriptLine,
    },
    #[serde(rename_all = "camelCase")]
    NotesUpdated {
        session_id: String,
        notes: MeetingNotes,
    },
    #[serde(rename_all = "camelCase")]
    SessionUpdated {
        session_id: String,
        session: Session,
    },
    SessionsChanged,
}

#[derive(Debug, Default)]
pub struct LiveState {
    pub listening: bool,
    pub session_id: Option<String>,
    pub source_lang_override: Option<String>,
    pub target_lang_override: Option<String>,
    pub draft: Option<DraftSubtitle>,
    pub draft_seq: HashMap<String, u64>,
    pub draft_in_flight: HashSet<String>,
    pub last_draft_text: HashMap<String, String>,
    pub last_note_at: Option<DateTime<Utc>>,
    pub notes_running: bool,
    pub rejected_fixes: HashSet<String>,
}

pub struct AppState {
    pub data_dir: PathBuf,
    pub settings: RwLock<AppSettings>,
    pub store: Mutex<SessionStore>,
    pub loom: LoomClient,
    pub loom_status: RwLock<LoomStatus>,
    pub live: Mutex<LiveState>,
    pub events_tx: broadcast::Sender<ServerEvent>,
}

impl AppState {
    pub fn new(data_dir: PathBuf) -> Arc<Self> {
        let settings = load_settings(&data_dir);
        let store = SessionStore::open(&data_dir);
        let rejected = load_rejected_fixes(&data_dir);
        let (events_tx, _) = broadcast::channel(256);

        let initial_status = LoomStatus {
            loom_url: settings.loom_url.clone(),
            ..Default::default()
        };

        let live = LiveState {
            rejected_fixes: rejected,
            ..Default::default()
        };

        Arc::new(Self {
            data_dir,
            settings: RwLock::new(settings),
            store: Mutex::new(store),
            loom: LoomClient::new(),
            loom_status: RwLock::new(initial_status),
            live: Mutex::new(live),
            events_tx,
        })
    }

    pub fn emit(&self, ev: ServerEvent) {
        let _ = self.events_tx.send(ev);
    }

    pub async fn refresh_loom_status(&self) -> LoomStatus {
        let settings = self.settings.read().await.clone();
        let loom_dir = settings.resolved_loom_dir();
        let status = self
            .loom
            .probe_status(
                &settings.loom_url,
                &loom_dir,
                &settings.translate_model,
                &settings.notes_model,
            )
            .await;
        *self.loom_status.write().await = status.clone();
        self.emit(ServerEvent::LoomStatus {
            status: status.clone(),
        });
        status
    }

    pub async fn ensure_translate_model(&self) -> Option<String> {
        let current = {
            let st = self.loom_status.read().await;
            st.active_translate_model.clone()
        };
        if current.is_some() {
            return current;
        }
        let refreshed = self.refresh_loom_status().await;
        refreshed.active_translate_model
    }

    pub async fn ensure_notes_model(&self) -> Option<String> {
        let current = {
            let st = self.loom_status.read().await;
            st.active_notes_model.clone()
        };
        if current.is_some() {
            return current;
        }
        let refreshed = self.refresh_loom_status().await;
        refreshed.active_notes_model
    }

    async fn record_rejected(&self, from: &str, to: &str) {
        let key = fix_key(from, to);
        let all: Vec<String> = {
            let mut live = self.live.lock().await;
            live.rejected_fixes.insert(key);
            live.rejected_fixes.iter().cloned().collect()
        };
        save_rejected_fixes(&self.data_dir, &all);
    }

    async fn maybe_auto_export(&self) {
        let settings = self.settings.read().await.clone();
        if !settings.export_enabled || settings.export_folder.trim().is_empty() {
            return;
        }
        let store = self.store.lock().await;
        let _ = sync_folder_export(&self.data_dir, &store, settings.export_folder.trim());
    }

    async fn spawn_line_translation(
        self: &Arc<Self>,
        session_id: String,
        line_id: String,
        src_snapshot: String,
        kind: TranslateKind,
    ) {
        let state = Arc::clone(self);
        tokio::spawn(async move {
            let _ = state
                .translate_and_apply_line(&session_id, &line_id, &src_snapshot, kind, true)
                .await;
        });
    }

    async fn translate_and_apply_line(
        &self,
        session_id: &str,
        line_id: &str,
        src_snapshot: &str,
        kind: TranslateKind,
        allow_fixes: bool,
    ) -> Result<Option<TranscriptLine>, LoomError> {
        let settings = self.settings.read().await.clone();
        let Some(model) = self.ensure_translate_model().await else {
            return Err(LoomError::Unreachable("no Loom translation model available".into()));
        };

        let (line, ctx) = {
            let store = self.store.lock().await;
            let Some(session) = store.get(session_id) else {
                return Ok(None);
            };
            let Some(idx) = session.lines.iter().position(|l| l.id == line_id) else {
                return Ok(None);
            };
            let line = session.lines[idx].clone();
            if line.src != src_snapshot {
                return Ok(None);
            }
            let recent: Vec<String> = session.lines[..idx]
                .iter()
                .rev()
                .take(3)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .map(|l| l.shown())
                .collect();
            let following: Vec<String> = session.lines[idx + 1..]
                .iter()
                .take(2)
                .map(|l| l.shown())
                .collect();
            let topic = session
                .notes
                .as_ref()
                .and_then(|n| n.title.clone())
                .or_else(|| {
                    if session.renamed == Some(true) {
                        Some(session.title.clone())
                    } else {
                        None
                    }
                });
            let glossary = session
                .notes
                .as_ref()
                .map(notes::glossary_lines)
                .unwrap_or_default();
            let summary = session
                .notes
                .as_ref()
                .map(|n| n.summary.clone())
                .filter(|s| !s.is_empty());

            let ctx = FixContext {
                topic,
                words: settings.vocab_prompt_lines(),
                recent,
                following,
                summary,
                glossary,
            };
            (line, ctx)
        };

        let source_text = line.shown();
        let outcome = translate_via_loom(
            &self.loom,
            &settings,
            &model,
            &source_text,
            &line.src_lang,
            &line.dst_lang,
            kind,
            Some(&ctx),
        )
        .await?;

        let mut auto_fixes: Vec<LineFix> = Vec::new();
        let mut used_words: Vec<String> = Vec::new();
        if allow_fixes {
            let rejected = self.live.lock().await.rejected_fixes.clone();
            for edit in &outcome.edits {
                let verdict = correction::decide(
                    edit,
                    |h, w| settings.knows_vocab(h, w),
                    |h, w| rejected.contains(&fix_key(h, w)),
                );
                let (cf, ct) = correction::core(&edit.from, &edit.to);
                match verdict {
                    Verdict::Apply => {
                        if settings.knows_vocab(cf.as_str(), ct.as_str())
                            || settings.knows_vocab(&edit.from, &edit.to)
                        {
                            used_words.push(ct.clone());
                        }
                        auto_fixes.push(LineFix {
                            from: edit.from.clone(),
                            to: edit.to.clone(),
                            ask: None,
                            off: None,
                            user: None,
                        });
                    }
                    Verdict::Ask => {
                        auto_fixes.push(LineFix {
                            from: edit.from.clone(),
                            to: edit.to.clone(),
                            ask: Some(true),
                            off: None,
                            user: None,
                        });
                    }
                    Verdict::Drop => {}
                }
            }
        }

        if !used_words.is_empty() {
            let mut s = self.settings.write().await;
            for word in &used_words {
                s.mark_vocab_used(word);
            }
            let _ = save_settings(&self.data_dir, &s);
        }

        let updated_line = {
            let mut store = self.store.lock().await;
            let still_matches = store
                .get(session_id)
                .and_then(|s| s.lines.iter().find(|l| l.id == line_id))
                .is_some_and(|l| l.src == src_snapshot);
            if !still_matches {
                return Ok(None);
            }
            if allow_fixes {
                let existing = store
                    .get(session_id)
                    .and_then(|s| s.lines.iter().find(|l| l.id == line_id))
                    .and_then(|l| l.fixes.clone())
                    .unwrap_or_default();
                let merged = correction::merge_fixes(&existing, &auto_fixes);
                let _ = store.set_fixes(session_id, line_id, merged);
            }
            let _ = store.set_translation(session_id, line_id, outcome.translation);
            store
                .get(session_id)
                .and_then(|s| s.lines.iter().find(|l| l.id == line_id))
                .cloned()
        };

        if let Some(ref line) = updated_line {
            self.emit(ServerEvent::LineUpdated {
                session_id: session_id.to_string(),
                line: line.clone(),
            });
            if let Some(session) = self.store.lock().await.get(session_id).cloned() {
                self.emit(ServerEvent::SessionUpdated {
                    session_id: session_id.to_string(),
                    session,
                });
            }
        }

        Ok(updated_line)
    }

    async fn maybe_trigger_live_notes(self: &Arc<Self>, session_id: String) {
        let should_run = {
            let mut live = self.live.lock().await;
            if live.notes_running || !live.listening || live.session_id.as_deref() != Some(&session_id) {
                return;
            }
            let store = self.store.lock().await;
            let Some(session) = store.get(&session_id) else {
                return;
            };
            let covered = session.notes.as_ref().map(|n| n.covered).unwrap_or(0);
            let new_lines = session.lines.len().saturating_sub(covered);
            if session.lines.len() < 6 || new_lines < 6 {
                return;
            }
            let elapsed_ok = match live.last_note_at {
                None => true,
                Some(prev) => (Utc::now() - prev).num_seconds() >= 45,
            };
            if !elapsed_ok {
                return;
            }
            live.notes_running = true;
            true
        };

        if !should_run {
            return;
        }

        let state = Arc::clone(self);
        tokio::spawn(async move {
            let _ = state.generate_and_save_notes(&session_id, false, false).await;
            let mut live = state.live.lock().await;
            live.notes_running = false;
            live.last_note_at = Some(Utc::now());
        });
    }

    pub async fn generate_and_save_notes(
        &self,
        session_id: &str,
        is_final: bool,
        fresh: bool,
    ) -> Result<MeetingNotes, LoomError> {
        let settings = self.settings.read().await.clone();
        let Some(model) = self.ensure_notes_model().await else {
            return Err(LoomError::Unreachable("no Loom notes model available".into()));
        };
        let session_snapshot = {
            let store = self.store.lock().await;
            store
                .get(session_id)
                .cloned()
                .ok_or_else(|| LoomError::Parse(format!("session {session_id} not found")))?
        };
        if session_snapshot.lines.is_empty() {
            return Err(LoomError::Parse("session has no transcript lines".into()));
        }

        let notes = notes::generate_notes(
            &self.loom,
            &settings,
            &model,
            &session_snapshot,
            is_final,
            fresh,
        )
        .await?;

        {
            let mut store = self.store.lock().await;
            if let Err(e) = store.set_notes(session_id, notes.clone()) {
                return Err(LoomError::Parse(format!("failed to persist notes: {e}")));
            }
            if let Some(updated_session) = store.get(session_id).cloned() {
                self.emit(ServerEvent::NotesUpdated {
                    session_id: session_id.to_string(),
                    notes: notes.clone(),
                });
                self.emit(ServerEvent::SessionUpdated {
                    session_id: session_id.to_string(),
                    session: updated_session,
                });
                self.emit(ServerEvent::SessionsChanged);
            }
        }

        self.maybe_auto_export().await;
        Ok(notes)
    }

    async fn translate_lines_batch(
        &self,
        session_id: &str,
        pairs: Vec<(String, String)>,
        allow_fixes: bool,
    ) -> usize {
        stream::iter(pairs.into_iter().map(|(lid, src)| async move {
            self.translate_and_apply_line(session_id, &lid, &src, TranslateKind::File, allow_fixes)
                .await
                .is_ok()
        }))
        .buffer_unordered(4)
        .filter(|ok| futures_util::future::ready(*ok))
        .count()
        .await
    }
}

fn fix_key(from: &str, to: &str) -> String {
    let (cf, ct) = correction::core(from, to);
    format!("{}\0{}", cf.to_lowercase(), ct.to_lowercase())
}

fn load_rejected_fixes(data_dir: &Path) -> HashSet<String> {
    let path = data_dir.join("RejectedFixes.json");
    let Ok(bytes) = fs::read(path) else {
        return HashSet::new();
    };
    serde_json::from_slice::<Vec<String>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .collect()
}

fn save_rejected_fixes(data_dir: &Path, items: &[String]) {
    let path = data_dir.join("RejectedFixes.json");
    if let Ok(bytes) = serde_json::to_vec_pretty(items) {
        let _ = write_atomic(&path, &bytes, false);
    }
}

pub fn build_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/api/health", get(handle_health))
        .route("/api/state", get(handle_state))
        .route("/api/events", get(handle_events))
        .route("/api/loom/check", post(handle_loom_check))
        .route("/api/loom/test", post(handle_loom_test))
        .route("/api/settings", get(handle_get_settings).post(handle_post_settings))
        .route("/api/vocabulary/confirm", post(handle_vocab_confirm))
        .route("/api/vocabulary/import", post(handle_vocab_import))
        .route("/api/obsidian-vaults", get(handle_obsidian_vaults))
        .route("/api/listen/start", post(handle_listen_start))
        .route("/api/listen/stop", post(handle_listen_stop))
        .route("/api/listen/piece", post(handle_listen_piece))
        .route("/api/sessions", get(handle_list_sessions))
        .route(
            "/api/sessions/{id}",
            get(handle_get_session)
                .patch(handle_patch_session)
                .delete(handle_delete_session),
        )
        .route("/api/sessions/{id}/notes", post(handle_generate_notes))
        .route("/api/sessions/{id}/retranslate", post(handle_retranslate_session))
        .route(
            "/api/sessions/{id}/lines/{line_id}/fix",
            post(handle_fix_line),
        )
        .route("/api/sessions/{id}/export", get(handle_export_session))
        .route("/api/import/begin", post(handle_import_begin))
        .route("/api/import/{id}/piece", post(handle_import_piece))
        .route("/api/import/{id}/finish", post(handle_import_finish))
        .route("/api/search", get(handle_search))
        .route("/api/export/sync", post(handle_export_sync))
        .with_state(state)
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct StatePayload {
    version: String,
    data_dir: String,
    listening: bool,
    live_session_id: Option<String>,
    draft: Option<DraftSubtitle>,
    loom: LoomStatus,
    recent_calls: Vec<LoomCallRecord>,
    settings: AppSettings,
    sessions: Vec<SessionSummary>,
    live_session: Option<Session>,
}

async fn handle_health() -> impl IntoResponse {
    Json(json!({
        "ok": true,
        "service": "verba-engine",
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

async fn handle_state(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let settings = state.settings.read().await.clone();
    let loom = state.loom_status.read().await.clone();
    let recent_calls = state.loom.recent_calls();
    let (listening, live_session_id, draft) = {
        let live = state.live.lock().await;
        (live.listening, live.session_id.clone(), live.draft.clone())
    };
    let (sessions, live_session) = {
        let store = state.store.lock().await;
        let summaries = store
            .sessions
            .iter()
            .map(SessionSummary::from_session)
            .collect();
        let current = live_session_id
            .as_deref()
            .and_then(|id| store.get(id))
            .cloned();
        (summaries, current)
    };

    Json(StatePayload {
        version: env!("CARGO_PKG_VERSION").to_string(),
        data_dir: state.data_dir.to_string_lossy().to_string(),
        listening,
        live_session_id,
        draft,
        loom,
        recent_calls,
        settings,
        sessions,
        live_session,
    })
}

async fn handle_events(
    State(state): State<Arc<AppState>>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let mut rx = state.events_tx.subscribe();
    let stream = async_stream::stream! {
        let initial = serde_json::to_string(&ServerEvent::StateChanged).unwrap_or_default();
        yield Ok(Event::default().data(initial));
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    if let Ok(json) = serde_json::to_string(&ev) {
                        yield Ok(Event::default().data(json));
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    let sync = serde_json::to_string(&ServerEvent::StateChanged).unwrap_or_default();
                    yield Ok(Event::default().data(sync));
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    };
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct LoomCheckRequest {
    loom_url: Option<String>,
    loom_data_dir: Option<String>,
    translate_model: Option<String>,
    notes_model: Option<String>,
}

async fn handle_loom_check(
    State(state): State<Arc<AppState>>,
    body: Option<Json<LoomCheckRequest>>,
) -> impl IntoResponse {
    let cur = state.settings.read().await.clone();
    let default_dir = cur.resolved_loom_dir();
    let req = body.map(|b| b.0).unwrap_or_default();
    let url = req.loom_url.unwrap_or(cur.loom_url);
    let dir = match req.loom_data_dir {
        Some(d) if !d.trim().is_empty() => PathBuf::from(d.trim()),
        _ => default_dir,
    };
    let t_model = req.translate_model.unwrap_or(cur.translate_model);
    let n_model = req.notes_model.unwrap_or(cur.notes_model);

    let status = state.loom.probe_status(&url, &dir, &t_model, &n_model).await;
    *state.loom_status.write().await = status.clone();
    state.emit(ServerEvent::LoomStatus {
        status: status.clone(),
    });
    Json(json!({
        "status": status,
        "recentCalls": state.loom.recent_calls(),
    }))
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct LoomTestRequest {
    text: Option<String>,
    source_lang: Option<String>,
    target_lang: Option<String>,
    model: Option<String>,
}

async fn handle_loom_test(
    State(state): State<Arc<AppState>>,
    body: Option<Json<LoomTestRequest>>,
) -> Response {
    let settings = state.settings.read().await.clone();
    let req = body.map(|b| b.0).unwrap_or_default();
    let status = state.refresh_loom_status().await;
    if !status.connected {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "ok": false,
                "error": status.last_error.unwrap_or_else(|| "Loom not connected".into()),
            })),
        )
            .into_response();
    }
    let model = req
        .model
        .filter(|m| !m.trim().is_empty())
        .or(status.active_translate_model)
        .unwrap_or_default();
    if model.is_empty() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "ok": false,
                "error": "No model available in Loom",
            })),
        )
            .into_response();
    }
    let sample = req
        .text
        .filter(|t| !t.trim().is_empty())
        .unwrap_or_else(|| "Let's wrap up the Q3 metrics review and assign action items.".into());
    let src = req.source_lang.unwrap_or_else(|| "en".into());
    let dst = req
        .target_lang
        .unwrap_or_else(|| settings.resolved_target(Some(&src)));

    match translate_via_loom(
        &state.loom,
        &settings,
        &model,
        &sample,
        &src,
        &dst,
        TranslateKind::Sentence,
        None,
    )
    .await
    {
        Ok(out) => Json(json!({
            "ok": true,
            "translation": out.translation,
            "model": out.model,
            "latencyMs": out.latency_ms,
        }))
        .into_response(),
        Err(err) => (
            StatusCode::BAD_GATEWAY,
            Json(json!({
                "ok": false,
                "error": err.to_string(),
            })),
        )
            .into_response(),
    }
}

async fn handle_get_settings(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(state.settings.read().await.clone())
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct SettingsPatch {
    loom_url: Option<String>,
    loom_data_dir: Option<String>,
    translate_model: Option<String>,
    notes_model: Option<String>,
    source_lang: Option<String>,
    target_lang: Option<String>,
    notes_lang: Option<String>,
    loom_only: Option<bool>,
    draft_translate: Option<bool>,
    live_fix_enabled: Option<bool>,
    overlay_mode: Option<String>,
    overlay_hide_after: Option<f64>,
    notes_capturable: Option<bool>,
    export_enabled: Option<bool>,
    export_folder: Option<String>,
    vocabulary: Option<Vec<VocabEntry>>,
}

async fn handle_post_settings(
    State(state): State<Arc<AppState>>,
    Json(patch): Json<SettingsPatch>,
) -> Response {
    let mut reprobe = false;
    let mut trigger_export = false;
    let updated = {
        let mut s = state.settings.write().await;
        if let Some(v) = patch.loom_url {
            if v != s.loom_url {
                reprobe = true;
            }
            s.loom_url = v;
        }
        if let Some(v) = patch.loom_data_dir {
            if v != s.loom_data_dir {
                reprobe = true;
            }
            s.loom_data_dir = v;
        }
        if let Some(v) = patch.translate_model {
            if v != s.translate_model {
                reprobe = true;
            }
            s.translate_model = v;
        }
        if let Some(v) = patch.notes_model {
            if v != s.notes_model {
                reprobe = true;
            }
            s.notes_model = v;
        }
        if let Some(v) = patch.source_lang {
            s.source_lang = v;
        }
        if let Some(v) = patch.target_lang {
            s.target_lang = v;
        }
        if let Some(v) = patch.notes_lang {
            s.notes_lang = v;
        }
        if let Some(v) = patch.loom_only {
            s.loom_only = v;
        }
        if let Some(v) = patch.draft_translate {
            s.draft_translate = v;
        }
        if let Some(v) = patch.live_fix_enabled {
            s.live_fix_enabled = v;
        }
        if let Some(v) = patch.overlay_mode {
            s.overlay_mode = v;
        }
        if let Some(v) = patch.overlay_hide_after {
            s.overlay_hide_after = v.clamp(1.0, 30.0);
        }
        if let Some(v) = patch.notes_capturable {
            s.notes_capturable = v;
        }
        if let Some(v) = patch.export_enabled {
            if v && !s.export_enabled {
                trigger_export = true;
            }
            s.export_enabled = v;
        }
        if let Some(v) = patch.export_folder {
            if v != s.export_folder {
                trigger_export = true;
            }
            s.export_folder = v;
        }
        if let Some(v) = patch.vocabulary {
            s.vocabulary = v;
        }
        if let Err(e) = save_settings(&state.data_dir, &s) {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
        s.clone()
    };

    state.emit(ServerEvent::SettingsUpdated {
        settings: updated.clone(),
    });
    if reprobe {
        let _ = state.refresh_loom_status().await;
    }
    if trigger_export {
        state.maybe_auto_export().await;
    }
    Json(updated).into_response()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VocabConfirmRequest {
    heard: Option<String>,
    word: String,
    source: Option<String>,
}

async fn handle_vocab_confirm(
    State(state): State<Arc<AppState>>,
    Json(req): Json<VocabConfirmRequest>,
) -> impl IntoResponse {
    let updated = {
        let mut s = state.settings.write().await;
        s.confirm_vocab(
            req.heard.as_deref().unwrap_or(""),
            &req.word,
            req.source.as_deref().unwrap_or("user"),
        );
        let _ = save_settings(&state.data_dir, &s);
        s.clone()
    };
    state.emit(ServerEvent::SettingsUpdated {
        settings: updated.clone(),
    });
    Json(updated)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VocabImportRequest {
    text: String,
}

async fn handle_vocab_import(
    State(state): State<Arc<AppState>>,
    Json(req): Json<VocabImportRequest>,
) -> impl IntoResponse {
    let mut added = 0usize;
    let updated = {
        let mut s = state.settings.write().await;
        for raw in req.text.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((h, w)) = line
                .split_once("->")
                .or_else(|| line.split_once("→"))
                .or_else(|| line.split_once('\t'))
            {
                let h = h.trim();
                let w = w.trim();
                if !w.is_empty() {
                    s.confirm_vocab(h, w, "user");
                    added += 1;
                }
            } else {
                s.confirm_vocab("", line, "user");
                added += 1;
            }
        }
        let _ = save_settings(&state.data_dir, &s);
        s.clone()
    };
    state.emit(ServerEvent::SettingsUpdated {
        settings: updated.clone(),
    });
    Json(json!({ "imported": added, "settings": updated }))
}

async fn handle_obsidian_vaults() -> Json<Vec<ObsidianVault>> {
    Json(discover_obsidian_vaults())
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ListenStartRequest {
    room: Option<bool>,
    source_lang: Option<String>,
    target_lang: Option<String>,
}

async fn handle_listen_start(
    State(state): State<Arc<AppState>>,
    body: Option<Json<ListenStartRequest>>,
) -> Response {
    let req = body.map(|b| b.0).unwrap_or_default();

    // End any dangling live session first.
    {
        let mut store = state.store.lock().await;
        if store.live_id.is_some() {
            let _ = store.end(true);
        }
    }

    let (session, folder) = {
        let mut store = state.store.lock().await;
        match store.begin(req.room.unwrap_or(false)) {
            Ok(s) => {
                let folder = store.folder(&s.id).to_string_lossy().to_string();
                (s, folder)
            }
            Err(e) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": e.to_string() })),
                )
                    .into_response();
            }
        }
    };

    {
        let mut live = state.live.lock().await;
        live.listening = true;
        live.session_id = Some(session.id.clone());
        live.source_lang_override = req.source_lang;
        live.target_lang_override = req.target_lang;
        live.draft = None;
        live.draft_seq.clear();
        live.draft_in_flight.clear();
        live.last_draft_text.clear();
        live.last_note_at = None;
        live.notes_running = false;
    }

    state.emit(ServerEvent::SessionsChanged);
    state.emit(ServerEvent::StateChanged);
    Json(json!({
        "session": session,
        "audioFolder": folder,
    }))
    .into_response()
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ListenStopRequest {
    keep_empty_with_audio: Option<bool>,
    generate_final_notes: Option<bool>,
}

async fn handle_listen_stop(
    State(state): State<Arc<AppState>>,
    body: Option<Json<ListenStopRequest>>,
) -> Response {
    let req = body.map(|b| b.0).unwrap_or_default();

    {
        let mut live = state.live.lock().await;
        live.listening = false;
        live.session_id = None;
        live.draft = None;
        live.draft_seq.clear();
        live.draft_in_flight.clear();
        live.last_draft_text.clear();
    }
    state.emit(ServerEvent::DraftUpdated { draft: None });

    let ended = {
        let mut store = state.store.lock().await;
        match store.end(req.keep_empty_with_audio.unwrap_or(true)) {
            Ok(s) => s,
            Err(e) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": e.to_string() })),
                )
                    .into_response();
            }
        }
    };

    state.emit(ServerEvent::SessionsChanged);
    state.emit(ServerEvent::StateChanged);

    if let Some(ref s) = ended {
        if !s.lines.is_empty() && req.generate_final_notes.unwrap_or(true) {
            let bg_state = Arc::clone(&state);
            let sid = s.id.clone();
            tokio::spawn(async move {
                let _ = bg_state.generate_and_save_notes(&sid, true, false).await;
                bg_state.maybe_auto_export().await;
            });
        } else {
            state.maybe_auto_export().await;
        }
    }

    Json(json!({ "session": ended })).into_response()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PieceRequest {
    pub text: String,
    #[serde(default = "default_speaker")]
    pub speaker: String,
    pub is_final: bool,
    pub t: Option<f64>,
    pub lang: Option<String>,
    pub voice: Option<i32>,
    pub via: Option<String>,
    pub cut: Option<bool>,
}

fn default_speaker() -> String {
    "them".to_string()
}

fn resolve_pair(settings: &AppSettings, lang: Option<&str>) -> (String, String) {
    let src = match lang.map(str::trim).filter(|s| !s.is_empty() && *s != "auto") {
        Some(l) => l.to_string(),
        None => {
            if settings.source_lang != "auto" && !settings.source_lang.trim().is_empty() {
                settings.source_lang.clone()
            } else {
                "en".to_string()
            }
        }
    };
    let dst = settings.resolved_target(Some(&src));
    (src, dst)
}

async fn handle_listen_piece(
    State(state): State<Arc<AppState>>,
    Json(req): Json<PieceRequest>,
) -> Response {
    let (session_id, src_override, dst_override) = {
        let live = state.live.lock().await;
        if !live.listening {
            return (
                StatusCode::CONFLICT,
                Json(json!({ "error": "not currently listening" })),
            )
                .into_response();
        }
        let Some(sid) = live.session_id.clone() else {
            return (
                StatusCode::CONFLICT,
                Json(json!({ "error": "no active live session" })),
            )
                .into_response();
        };
        (
            sid,
            live.source_lang_override.clone(),
            live.target_lang_override.clone(),
        )
    };

    let cleaned = heard::clean(&req.text);
    if cleaned.is_empty() {
        return Json(json!({ "ignored": true, "lines": [] })).into_response();
    }

    let settings = state.settings.read().await.clone();
    let effective_lang = req.lang.as_deref().or(src_override.as_deref());
    let (mut src_lang, mut dst_lang) = resolve_pair(&settings, effective_lang);
    if effective_lang.is_none() && cleaned.chars().any(heard::is_cjk_char) && settings.source_lang == "auto" {
        src_lang = "zh-CN".to_string();
        dst_lang = settings.resolved_target(Some(&src_lang));
    }
    if let Some(d) = dst_override
        && !d.trim().is_empty() && d != src_lang {
            dst_lang = d;
        }

    let t = {
        let store = state.store.lock().await;
        let elapsed = store
            .get(&session_id)
            .map(|s| (Utc::now() - s.started_at).num_milliseconds().max(0) as f64 / 1000.0)
            .unwrap_or(0.0);
        req.t.unwrap_or(elapsed)
    };

    if !req.is_final {
        let draft = DraftSubtitle {
            speaker: req.speaker.clone(),
            src: cleaned.clone(),
            dst: None,
            src_lang: src_lang.clone(),
            dst_lang: dst_lang.clone(),
            t,
            voice: req.voice,
            via: req.via.clone(),
        };
        let should_translate_draft = {
            let mut live = state.live.lock().await;
            let seq = live.draft_seq.entry(req.speaker.clone()).or_insert(0);
            *seq += 1;
            let seq_val = *seq;
            let prev_dst = live
                .draft
                .as_ref()
                .filter(|d| d.speaker == req.speaker)
                .and_then(|d| d.dst.clone());
            let mut next_draft = draft.clone();
            next_draft.dst = prev_dst;
            live.draft = Some(next_draft.clone());
            live.last_draft_text
                .insert(req.speaker.clone(), cleaned.clone());
            state.emit(ServerEvent::DraftUpdated {
                draft: Some(next_draft),
            });

            if settings.draft_translate
                && heard::text_size(&cleaned) >= 2
                && !live.draft_in_flight.contains(&req.speaker)
            {
                live.draft_in_flight.insert(req.speaker.clone());
                Some(seq_val)
            } else {
                None
            }
        };

        if let Some(_seq_val) = should_translate_draft {
            let bg = Arc::clone(&state);
            let speaker = req.speaker.clone();
            let text_copy = cleaned.clone();
            let src_copy = src_lang.clone();
            let dst_copy = dst_lang.clone();
            tokio::spawn(async move {
                if let Some(model) = bg.ensure_translate_model().await {
                    let st = bg.settings.read().await.clone();
                    if let Ok(out) = translate_via_loom(
                        &bg.loom,
                        &st,
                        &model,
                        &text_copy,
                        &src_copy,
                        &dst_copy,
                        TranslateKind::Draft,
                        None,
                    )
                    .await
                    {
                        let mut live = bg.live.lock().await;
                        live.draft_in_flight.remove(&speaker);
                        if let Some(ref mut cur) = live.draft
                            && cur.speaker == speaker {
                                cur.dst = Some(out.translation);
                                let d = Some(cur.clone());
                                drop(live);
                                bg.emit(ServerEvent::DraftUpdated { draft: d });
                            }
                    } else {
                        bg.live.lock().await.draft_in_flight.remove(&speaker);
                    }
                } else {
                    bg.live.lock().await.draft_in_flight.remove(&speaker);
                }
            });
        }

        return Json(json!({ "draft": draft })).into_response();
    }

    // Finalized utterance
    let fuller_text = {
        let mut live = state.live.lock().await;
        let prev_draft = live.last_draft_text.remove(&req.speaker).unwrap_or_default();
        if live
            .draft
            .as_ref()
            .is_some_and(|d| d.speaker == req.speaker)
        {
            live.draft = None;
        }
        live.draft_in_flight.remove(&req.speaker);
        let sq = live.draft_seq.entry(req.speaker.clone()).or_insert(0);
        *sq += 1;
        heard::fuller(&cleaned, &prev_draft)
    };
    state.emit(ServerEvent::DraftUpdated { draft: None });

    let parts = split_sentences(&fuller_text);
    let mut touched_lines: Vec<TranscriptLine> = Vec::new();
    let prev_for_recheck: Option<(String, String)>;

    {
        let mut store = state.store.lock().await;
        for (idx, part) in parts.into_iter().enumerate() {
            let cut = if idx == 0 {
                req.cut.unwrap_or(false)
            } else {
                true
            };
            let should_merge = store
                .get(&session_id)
                .and_then(|s| s.lines.last())
                .is_some_and(|last| {
                    last.speaker == req.speaker
                        && last.voice == req.voice
                        && last.via == req.via
                        && last.src_lang == src_lang
                        && heard::continues(&last.src, &part, t - last.t, cut)
                });

            if should_merge
                && let Some(last) = store.get(&session_id).and_then(|s| s.lines.last()).cloned() {
                    let mut merged = last.clone();
                    merged.src = heard::join(&last.src, &part);
                    merged.dst = None;
                    let _ = store.replace_last_line(&session_id, merged.clone());
                    touched_lines.push(merged);
                    continue;
                }

            let line = TranscriptLine {
                id: next_uid("ln"),
                t,
                speaker: req.speaker.clone(),
                src: part,
                dst: None,
                src_lang: src_lang.clone(),
                dst_lang: dst_lang.clone(),
                voice: req.voice,
                via: req.via.clone(),
                fixes: None,
            };
            let _ = store.append_line(&session_id, line.clone());
            touched_lines.push(line);
        }

        prev_for_recheck = touched_lines.first().and_then(|first_touched| {
            let session = store.get(&session_id)?;
            let pos = session.lines.iter().position(|l| l.id == first_touched.id)?;
            if pos >= 1 {
                let prev = &session.lines[pos - 1];
                if (first_touched.t - prev.t).abs() <= 12.0 {
                    return Some((prev.id.clone(), prev.src.clone()));
                }
            }
            None
        });

        if let Some(session) = store.get(&session_id).cloned() {
            state.emit(ServerEvent::SessionUpdated {
                session_id: session_id.clone(),
                session,
            });
        }
    }

    for line in &touched_lines {
        state.emit(ServerEvent::LineUpdated {
            session_id: session_id.clone(),
            line: line.clone(),
        });
        state
            .spawn_line_translation(
                session_id.clone(),
                line.id.clone(),
                line.src.clone(),
                TranslateKind::Sentence,
            )
            .await;
    }

    if let Some((prev_id, prev_src)) = prev_for_recheck {
        let bg_state = Arc::clone(&state);
        let sid = session_id.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(400)).await;
            let _ = bg_state
                .translate_and_apply_line(&sid, &prev_id, &prev_src, TranslateKind::Sentence, true)
                .await;
        });
    }

    state.maybe_trigger_live_notes(session_id).await;
    Json(json!({ "lines": touched_lines })).into_response()
}

fn split_sentences(text: &str) -> Vec<String> {
    let mut rest = text.trim().to_string();
    let mut out = Vec::new();
    while !rest.is_empty() {
        if let Some((head, tail)) = heard::split_at_sentence_end(&rest) {
            if !head.is_empty() {
                out.push(head);
            }
            rest = tail;
        } else {
            out.push(rest);
            break;
        }
    }
    if out.is_empty() {
        let t = text.trim();
        if !t.is_empty() {
            out.push(t.to_string());
        }
    }
    out
}

async fn handle_list_sessions(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let store = state.store.lock().await;
    let list: Vec<SessionSummary> = store
        .sessions
        .iter()
        .map(SessionSummary::from_session)
        .collect();
    Json(list)
}

async fn handle_get_session(
    State(state): State<Arc<AppState>>,
    AxumPath(id): AxumPath<String>,
) -> Response {
    let store = state.store.lock().await;
    let Some(s) = store.get(&id).cloned() else {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "session not found" })),
        )
            .into_response();
    };
    Json(s).into_response()
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct PatchSessionRequest {
    title: Option<String>,
    voice: Option<i32>,
    voice_name: Option<String>,
    has_audio: Option<bool>,
}

async fn handle_patch_session(
    State(state): State<Arc<AppState>>,
    AxumPath(id): AxumPath<String>,
    Json(req): Json<PatchSessionRequest>,
) -> Response {
    let updated = {
        let mut store = state.store.lock().await;
        if store.get(&id).is_none() {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "session not found" })),
            )
                .into_response();
        }
        if let Some(ref title) = req.title {
            let _ = store.rename(&id, title);
        }
        if let (Some(v), Some(name)) = (req.voice, &req.voice_name) {
            let _ = store.set_voice_name(&id, v, name);
        }
        if let Some(has_audio) = req.has_audio
            && let Some(s) = store.get_mut(&id) {
                s.has_audio = has_audio;
                let _ = store.save(&id);
            }
        store.get(&id).cloned()
    };

    if let Some(s) = updated {
        state.emit(ServerEvent::SessionUpdated {
            session_id: id,
            session: s.clone(),
        });
        state.emit(ServerEvent::SessionsChanged);
        state.maybe_auto_export().await;
        Json(s).into_response()
    } else {
        StatusCode::NOT_FOUND.into_response()
    }
}

async fn handle_delete_session(
    State(state): State<Arc<AppState>>,
    AxumPath(id): AxumPath<String>,
) -> Response {
    let deleted = {
        let mut store = state.store.lock().await;
        match store.delete(&id) {
            Ok(ok) => ok,
            Err(e) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": e.to_string() })),
                )
                    .into_response();
            }
        }
    };
    if deleted {
        state.emit(ServerEvent::SessionsChanged);
        Json(json!({ "deleted": true })).into_response()
    } else {
        (
            StatusCode::BAD_REQUEST,
            Json(json!({ "deleted": false, "error": "cannot delete live or missing session" })),
        )
            .into_response()
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct GenerateNotesRequest {
    #[serde(alias = "final")]
    is_final: Option<bool>,
    fresh: Option<bool>,
}

async fn handle_generate_notes(
    State(state): State<Arc<AppState>>,
    AxumPath(id): AxumPath<String>,
    body: Option<Json<GenerateNotesRequest>>,
) -> Response {
    let req = body.map(|b| b.0).unwrap_or_default();
    let is_final = match req.is_final {
        Some(v) => v,
        None => {
            let store = state.store.lock().await;
            store.live_id.as_deref() != Some(id.as_str())
        }
    };
    let fresh = req.fresh.unwrap_or(false);

    match state.generate_and_save_notes(&id, is_final, fresh).await {
        Ok(notes) => Json(notes).into_response(),
        Err(err) => {
            let code = match err {
                LoomError::Unreachable(_) | LoomError::NoKey(_) | LoomError::InvalidKey => {
                    StatusCode::SERVICE_UNAVAILABLE
                }
                _ => StatusCode::BAD_GATEWAY,
            };
            (code, Json(json!({ "error": err.to_string() }))).into_response()
        }
    }
}

async fn handle_retranslate_session(
    State(state): State<Arc<AppState>>,
    AxumPath(id): AxumPath<String>,
) -> Response {
    let pairs: Vec<(String, String)> = {
        let store = state.store.lock().await;
        let Some(s) = store.get(&id) else {
            return (
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "session not found" })),
            )
                .into_response();
        };
        s.lines
            .iter()
            .map(|l| (l.id.clone(), l.src.clone()))
            .collect()
    };

    let total = pairs.len();
    let succeeded = state.translate_lines_batch(&id, pairs, false).await;

    Json(json!({ "total": total, "translated": succeeded })).into_response()
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixLineRequest {
    action: Option<String>, // "accept" | "reject" | "edit"
    from: Option<String>,
    to: Option<String>,
    edited_text: Option<String>,
    apply_all: Option<bool>,
}

async fn handle_fix_line(
    State(state): State<Arc<AppState>>,
    AxumPath((id, line_id)): AxumPath<(String, String)>,
    Json(req): Json<FixLineRequest>,
) -> Response {
    let action = req.action.as_deref().unwrap_or(if req.edited_text.is_some() {
        "edit"
    } else {
        "accept"
    });

    match action {
        "accept" | "reject" => {
            let from = req.from.unwrap_or_default();
            let to = req.to.unwrap_or_default();
            let src_snapshot = {
                let mut store = state.store.lock().await;
                let Some(session) = store.get(&id) else {
                    return StatusCode::NOT_FOUND.into_response();
                };
                let Some(line) = session.lines.iter().find(|l| l.id == line_id) else {
                    return StatusCode::NOT_FOUND.into_response();
                };
                let mut fixes = line.fixes.clone().unwrap_or_default();
                let mut matched = false;
                for f in &mut fixes {
                    if f.from == from && f.to == to {
                        matched = true;
                        if action == "accept" {
                            f.ask = None;
                            f.off = None;
                            f.user = Some(true);
                        } else {
                            f.ask = None;
                            f.off = Some(true);
                        }
                    }
                }
                if !matched && action == "accept" && !from.is_empty() && !to.is_empty() {
                    fixes.push(LineFix {
                        from: from.clone(),
                        to: to.clone(),
                        ask: None,
                        off: None,
                        user: Some(true),
                    });
                }
                let src = line.src.clone();
                let _ = store.set_fixes(&id, &line_id, fixes);
                src
            };

            if action == "accept" {
                let mut s = state.settings.write().await;
                s.confirm_vocab(&from, &to, "user");
                let _ = save_settings(&state.data_dir, &s);
                let copy = s.clone();
                drop(s);
                state.emit(ServerEvent::SettingsUpdated { settings: copy });
            } else {
                state.record_rejected(&from, &to).await;
            }

            let updated = state
                .translate_and_apply_line(&id, &line_id, &src_snapshot, TranslateKind::Sentence, false)
                .await
                .ok()
                .flatten();

            let session = state.store.lock().await.get(&id).cloned();
            if let Some(ref s) = session {
                state.emit(ServerEvent::SessionUpdated {
                    session_id: id.clone(),
                    session: s.clone(),
                });
            }
            state.maybe_auto_export().await;
            Json(json!({ "line": updated, "session": session })).into_response()
        }
        "edit" => {
            let Some(edited_text) = req.edited_text else {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "editedText required" })),
                )
                    .into_response();
            };
            let (target_fix, heard_term, apply_lines): (Option<LineFix>, String, Vec<(String, String)>) = {
                let mut store = state.store.lock().await;
                let Some(line) = store
                    .get(&id)
                    .and_then(|s| s.lines.iter().find(|l| l.id == line_id))
                    .cloned()
                else {
                    return StatusCode::NOT_FOUND.into_response();
                };
                let shown = line.shown();
                let existing = line.fixes.clone().unwrap_or_default();
                let inferred = correction::user_edit(&shown, &edited_text, &line.src, &existing);

                let (fix, heard_term, _swap) = if let Some(pair) = inferred {
                    pair
                } else if edited_text.trim() != shown {
                    (
                        LineFix {
                            from: line.src.clone(),
                            to: edited_text.trim().to_string(),
                            ask: None,
                            off: None,
                            user: Some(true),
                        },
                        String::new(),
                        false,
                    )
                } else {
                    return Json(json!({ "unchanged": true })).into_response();
                };

                let mut to_retranslate = vec![(line_id.clone(), line.src.clone())];
                let new_fixes = correction::merge_fixes(&existing, std::slice::from_ref(&fix));
                let _ = store.set_fixes(&id, &line_id, new_fixes);

                if req.apply_all.unwrap_or(false) && !fix.from.is_empty() {
                    let other_ids: Vec<(String, String, Vec<LineFix>)> = store
                        .get(&id)
                        .map(|s| {
                            s.lines
                                .iter()
                                .filter(|l| l.id != line_id && l.shown().contains(&fix.from))
                                .map(|l| (l.id.clone(), l.src.clone(), l.fixes.clone().unwrap_or_default()))
                                .collect()
                        })
                        .unwrap_or_default();
                    for (oid, osrc, o_existing) in other_ids {
                        let merged = correction::merge_fixes(&o_existing, std::slice::from_ref(&fix));
                        let _ = store.set_fixes(&id, &oid, merged);
                        to_retranslate.push((oid, osrc));
                    }
                }

                (Some(fix), heard_term, to_retranslate)
            };

            if let Some(fix) = target_fix
                && !heard_term.is_empty() {
                    let mut s = state.settings.write().await;
                    s.confirm_vocab(&heard_term, &fix.to, "user");
                    let _ = save_settings(&state.data_dir, &s);
                    let copy = s.clone();
                    drop(s);
                    state.emit(ServerEvent::SettingsUpdated { settings: copy });
                }

            // Retranslate edited lines cleanly in background, awaiting the primary line
            if let Some((first_id, first_src)) = apply_lines.first().cloned() {
                let _ = state
                    .translate_and_apply_line(&id, &first_id, &first_src, TranslateKind::Sentence, false)
                    .await;
                for (oid, osrc) in apply_lines.into_iter().skip(1) {
                    state
                        .spawn_line_translation(id.clone(), oid, osrc, TranslateKind::File)
                        .await;
                }
            }

            let session = state.store.lock().await.get(&id).cloned();
            if let Some(ref s) = session {
                state.emit(ServerEvent::SessionUpdated {
                    session_id: id.clone(),
                    session: s.clone(),
                });
            }
            state.maybe_auto_export().await;
            Json(json!({ "session": session })).into_response()
        }
        other => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": format!("unknown fix action: {other}") })),
        )
            .into_response(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImportBeginRequest {
    file_name: String,
    source_path: String,
    recorded_at: Option<DateTime<Utc>>,
    duration_seconds: f64,
}

async fn handle_import_begin(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ImportBeginRequest>,
) -> Response {
    let mut store = state.store.lock().await;
    match store.begin_import(&req.file_name, &req.source_path, req.recorded_at, req.duration_seconds) {
        Ok(s) => {
            let folder = store.folder(&s.id).to_string_lossy().to_string();
            state.emit(ServerEvent::SessionsChanged);
            Json(json!({ "session": s, "audioFolder": folder })).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImportPieceRequest {
    text: String,
    t: f64,
    lang: Option<String>,
}

async fn handle_import_piece(
    State(state): State<Arc<AppState>>,
    AxumPath(id): AxumPath<String>,
    Json(req): Json<ImportPieceRequest>,
) -> Response {
    let cleaned = heard::clean(&req.text);
    if cleaned.is_empty() {
        return Json(json!({ "lines": [] })).into_response();
    }
    let settings = state.settings.read().await.clone();
    let (mut src_lang, mut dst_lang) = resolve_pair(&settings, req.lang.as_deref());
    if req.lang.as_deref().unwrap_or("auto") == "auto" && cleaned.chars().any(heard::is_cjk_char) {
        src_lang = "zh-CN".to_string();
        dst_lang = settings.resolved_target(Some(&src_lang));
    }

    let parts = split_sentences(&cleaned);
    let mut created = Vec::new();
    {
        let mut store = state.store.lock().await;
        if store.get(&id).is_none() {
            return StatusCode::NOT_FOUND.into_response();
        }
        for part in parts {
            let should_merge = store
                .get(&id)
                .and_then(|s| s.lines.last())
                .is_some_and(|last| {
                    last.src_lang == src_lang && heard::continues(&last.src, &part, req.t - last.t, false)
                });
            if should_merge
                && let Some(last) = store.get(&id).and_then(|s| s.lines.last()).cloned() {
                    let mut merged = last.clone();
                    merged.src = heard::join(&last.src, &part);
                    merged.dst = None;
                    let _ = store.replace_last_line(&id, merged.clone());
                    created.push(merged);
                    continue;
                }
            let line = TranscriptLine {
                id: next_uid("imp"),
                t: req.t,
                speaker: "them".to_string(),
                src: part,
                dst: None,
                src_lang: src_lang.clone(),
                dst_lang: dst_lang.clone(),
                voice: None,
                via: Some("file".to_string()),
                fixes: None,
            };
            let _ = store.append_line(&id, line.clone());
            created.push(line);
        }
    }

    Json(json!({ "lines": created })).into_response()
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ImportFinishRequest {
    generate_notes: Option<bool>,
    translate_all: Option<bool>,
}

async fn handle_import_finish(
    State(state): State<Arc<AppState>>,
    AxumPath(id): AxumPath<String>,
    body: Option<Json<ImportFinishRequest>>,
) -> Response {
    let req = body.map(|b| b.0).unwrap_or_default();

    let pending: Vec<(String, String)> = {
        let store = state.store.lock().await;
        let Some(s) = store.get(&id) else {
            return StatusCode::NOT_FOUND.into_response();
        };
        if req.translate_all.unwrap_or(true) {
            s.lines
                .iter()
                .filter(|l| l.dst.is_none())
                .map(|l| (l.id.clone(), l.src.clone()))
                .collect()
        } else {
            Vec::new()
        }
    };

    if !pending.is_empty() {
        let _ = state.translate_lines_batch(&id, pending, true).await;
    }

    {
        let mut store = state.store.lock().await;
        if let Err(e) = store.finish_import(&id) {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            )
                .into_response();
        }
    }

    if req.generate_notes.unwrap_or(true) {
        let _ = state.generate_and_save_notes(&id, true, false).await;
    }

    let session = state.store.lock().await.get(&id).cloned();
    if let Some(ref s) = session {
        state.emit(ServerEvent::SessionUpdated {
            session_id: id,
            session: s.clone(),
        });
    }
    state.emit(ServerEvent::SessionsChanged);
    state.maybe_auto_export().await;
    Json(json!({ "session": session })).into_response()
}

#[derive(Debug, Deserialize)]
struct SearchQuery {
    q: Option<String>,
    session_id: Option<String>,
}

async fn handle_search(
    State(state): State<Arc<AppState>>,
    Query(query): Query<SearchQuery>,
) -> Json<Vec<SearchHit>> {
    let q = query.q.unwrap_or_default();
    let store = state.store.lock().await;
    Json(search_sessions(
        &store.sessions,
        &q,
        query.session_id.as_deref(),
    ))
}

#[derive(Debug, Deserialize)]
struct ExportQuery {
    format: Option<String>,
}

async fn handle_export_session(
    State(state): State<Arc<AppState>>,
    AxumPath(id): AxumPath<String>,
    Query(query): Query<ExportQuery>,
) -> Response {
    let store = state.store.lock().await;
    let Some(s) = store.get(&id) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let fmt = query.format.as_deref().unwrap_or("markdown");
    let stem = safe_filename(&s.display_title());
    let fallback = if stem.is_empty() { id.clone() } else { stem };
    match fmt {
        "srt" => {
            let body = session_srt(s);
            let mut resp = Response::new(axum::body::Body::from(body));
            resp.headers_mut().insert(
                header::CONTENT_TYPE,
                header::HeaderValue::from_static("application/x-subrip; charset=utf-8"),
            );
            if let Ok(hv) = header::HeaderValue::from_str(&format!(
                "attachment; filename=\"{fallback}.srt\""
            )) {
                resp.headers_mut().insert(header::CONTENT_DISPOSITION, hv);
            }
            resp
        }
        _ => {
            let body = session_markdown(s);
            let mut resp = Response::new(axum::body::Body::from(body));
            resp.headers_mut().insert(
                header::CONTENT_TYPE,
                header::HeaderValue::from_static("text/markdown; charset=utf-8"),
            );
            if let Ok(hv) = header::HeaderValue::from_str(&format!(
                "attachment; filename=\"{fallback}.md\""
            )) {
                resp.headers_mut().insert(header::CONTENT_DISPOSITION, hv);
            }
            resp
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ExportSyncRequest {
    folder: Option<String>,
}

async fn handle_export_sync(
    State(state): State<Arc<AppState>>,
    body: Option<Json<ExportSyncRequest>>,
) -> Response {
    let req_folder = body.and_then(|b| b.0.folder).unwrap_or_default();
    let folder = if !req_folder.trim().is_empty() {
        req_folder.trim().to_string()
    } else {
        state.settings.read().await.export_folder.clone()
    };
    if folder.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "export folder is empty" })),
        )
            .into_response();
    }
    let store = state.store.lock().await;
    match sync_folder_export(&state.data_dir, &store, &folder) {
        Ok(idx) => Json::<ExportIndex>(idx).into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use tempfile::TempDir;
    use tokio::net::TcpListener;
    use tower::ServiceExt;

    async fn mock_loom_server() -> (String, TempDir) {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("hub.key"), "hub-server-test-key\n").unwrap();

        let app = Router::new()
            .route(
                "/health",
                get(|| async { Json(json!({ "ok": true, "runtime": "rust" })) }),
            )
            .route(
                "/v1/models",
                get(|| async {
                    Json(json!({
                        "data": [
                            {"id": "zenmux/inclusionai/ling-3.1-flash", "owned_by": "zenmux"},
                            {"id": "deepseek/deepseek-v4-pro", "owned_by": "deepseek"}
                        ]
                    }))
                }),
            )
            .route(
                "/v1/chat/completions",
                post(|Json(body): Json<serde_json::Value>| async move {
                    let sys = body["messages"][0]["content"].as_str().unwrap_or("");
                    if sys.contains("JSON object") && sys.contains("\"fixes\"") {
                        Json(json!({
                            "choices": [{"message": {"content": "{\"translation\":\"我们用 Morpho 做质押吧。\",\"fixes\":[{\"from\":\"莫拉\",\"to\":\"Morpho\",\"confidence\":0.95}]}"}}],
                            "usage": {"prompt_tokens": 20, "completion_tokens": 12}
                        }))
                    } else if sys.contains("meeting notes") || sys.contains("fishbone") {
                        Json(json!({
                            "choices": [{"message": {"content": "{\"title\":\"Morpho 质押讨论\",\"summary\":\"团队讨论了 Morpho 协议上的质押方案。\",\"topics\":[{\"start\":0,\"title\":\"质押方案\",\"summary\":\"决定采用 Morpho\",\"points\":[\"使用 Morpho 进行质押\"],\"pointTimes\":[1.0]}],\"conclusions\":[{\"text\":\"采用 Morpho\"}],\"todos\":[{\"text\":\"部署测试网\",\"owner\":\"Alice\",\"t\":2.0}],\"terms\":[{\"name\":\"Morpho\",\"note\":\"借贷协议\"}]}"}}],
                            "usage": {"prompt_tokens": 50, "completion_tokens": 40}
                        }))
                    } else {
                        Json(json!({
                            "choices": [{"message": {"content": "欢迎参加产品评审会议。"}}],
                            "usage": {"prompt_tokens": 10, "completion_tokens": 8}
                        }))
                    }
                }),
            );

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (format!("http://{addr}/v1"), dir)
    }

    #[tokio::test]
    async fn full_http_flow_listen_fix_notes_search_and_export() {
        let data_dir = TempDir::new().unwrap();
        let (loom_url, loom_dir) = mock_loom_server().await;
        let state = AppState::new(data_dir.path().to_path_buf());
        let app = build_router(Arc::clone(&state));

        // 1. Update settings to point to mock Loom
        let patch = json!({
            "loomUrl": loom_url,
            "loomDataDir": loom_dir.path().to_string_lossy(),
            "liveFixEnabled": true
        });
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/settings")
                    .header("content-type", "application/json")
                    .body(Body::from(patch.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        // 2. Start listening
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/listen/start")
                    .header("content-type", "application/json")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let started: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        let sid = started["session"]["id"].as_str().unwrap().to_string();

        // 3. Send a finalized piece
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/listen/piece")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "text": "Let us stake with 莫拉 today.",
                            "speaker": "them",
                            "isFinal": true,
                            "lang": "en",
                            "t": 1.0
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let piece_res: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        let line_id = piece_res["lines"][0]["id"].as_str().unwrap().to_string();

        // Wait briefly for background translation + Ask/Apply fix
        tokio::time::sleep(Duration::from_millis(120)).await;

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/sessions/{sid}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let s: Session = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(s.lines[0].dst.as_deref(), Some("我们用 Morpho 做质押吧。"));

        // 4. Generate notes
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{sid}/notes"))
                    .header("content-type", "application/json")
                    .body(Body::from("{\"final\":true}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        // 5. Fix line manually & confirm vocab
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{sid}/lines/{line_id}/fix"))
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "action": "edit",
                            "editedText": "Let us stake with Morpho today.",
                            "applyAll": true
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        // 6. Stop listening
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/listen/stop")
                    .header("content-type", "application/json")
                    .body(Body::from("{\"generateFinalNotes\":false}"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        // 7. Search & export
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/api/search?q=Morpho")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let hits: Vec<SearchHit> = serde_json::from_slice(&bytes).unwrap();
        assert!(!hits.is_empty());

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/sessions/{sid}/export?format=markdown"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let md = String::from_utf8(
            axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .unwrap()
                .to_vec(),
        )
        .unwrap();
        assert!(md.contains("Morpho 质押讨论"));
    }
}
