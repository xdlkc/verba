use clap::{Parser, Subcommand, ValueEnum};
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::net::TcpListener;
use verba::config::{default_data_dir, load_settings};
use verba::export::{session_markdown, session_srt};
use verba::loom::{LoomClient, pick_notes_model, pick_translate_model};
use verba::notes::generate_notes;
use verba::search::search_sessions;
use verba::server::{AppState, build_router};
use verba::store::SessionStore;

#[derive(Parser)]
#[command(
    name = "verba-engine",
    version,
    about = "Verba（言辞）local Rust engine backed by Loom"
)]
struct Cli {
    /// Override Verba data directory (defaults to ~/Library/Application Support/Verba)
    #[arg(long, global = true)]
    data_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the local HTTP + SSE service for Verba.app
    Serve {
        /// Loopback port to listen on
        #[arg(long, default_value_t = 4391)]
        port: u16,
    },
    /// Show Verba & local Loom status
    Status {
        /// Print machine-readable JSON
        #[arg(long)]
        json: bool,
    },
    /// Search stored meetings (with Chinese homophone/pinyin matching)
    Search {
        query: String,
        #[arg(long)]
        session: Option<String>,
    },
    /// Export a stored meeting as Markdown or SRT
    Export {
        session_id: String,
        #[arg(long, value_enum, default_value_t = ExportFormat::Markdown)]
        format: ExportFormat,
    },
    /// Generate or refresh structured meeting notes via local Loom
    Notes {
        session_id: String,
        #[arg(long)]
        fresh: bool,
    },
}

#[derive(Clone, ValueEnum)]
enum ExportFormat {
    Markdown,
    Srt,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let data_dir = cli.data_dir.unwrap_or_else(default_data_dir);

    let exit_code = match cli.command.unwrap_or(Commands::Serve { port: 4391 }) {
        Commands::Serve { port } => run_serve(data_dir, port).await,
        Commands::Status { json } => run_status(data_dir, json).await,
        Commands::Search { query, session } => run_search(data_dir, &query, session.as_deref()),
        Commands::Export { session_id, format } => run_export(data_dir, &session_id, format),
        Commands::Notes { session_id, fresh } => run_notes(data_dir, &session_id, fresh).await,
    };

    if exit_code != 0 {
        std::process::exit(exit_code);
    }
}

async fn run_serve(data_dir: PathBuf, port: u16) -> i32 {
    let state = AppState::new(data_dir);
    let startup_state = Arc::clone(&state);
    tokio::spawn(async move {
        let _ = startup_state.refresh_loom_status().await;
    });

    let router = build_router(state);
    let addr = format!("127.0.0.1:{port}");
    let listener = match TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("verba-engine: failed to bind {addr}: {e}");
            return 1;
        }
    };
    let actual = listener.local_addr().map(|a| a.to_string()).unwrap_or(addr);
    println!("verba-engine listening on http://{actual}");

    if let Err(e) = axum::serve(listener, router).await {
        eprintln!("verba-engine server error: {e}");
        return 1;
    }
    0
}

async fn run_status(data_dir: PathBuf, as_json: bool) -> i32 {
    let settings = load_settings(&data_dir);
    let store = SessionStore::open(&data_dir);
    let loom_dir = settings.resolved_loom_dir();
    let loom = LoomClient::new();
    let status = loom
        .probe_status(
            &settings.loom_url,
            &loom_dir,
            &settings.translate_model,
            &settings.notes_model,
        )
        .await;

    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "version": env!("CARGO_PKG_VERSION"),
                "dataDir": data_dir,
                "sessions": store.sessions.len(),
                "loom": status,
            }))
            .unwrap_or_default()
        );
        return if status.connected { 0 } else { 1 };
    }

    println!("Verba Engine v{}", env!("CARGO_PKG_VERSION"));
    println!("Data dir:   {}", data_dir.display());
    println!("Sessions:   {}", store.sessions.len());
    println!("Loom URL:   {}", status.loom_url);
    println!(
        "Loom state: {}",
        if status.connected {
            format!(
                "connected ({} models)",
                status.models.len()
            )
        } else {
            format!(
                "disconnected ({})",
                status.last_error.as_deref().unwrap_or("unknown error")
            )
        }
    );
    println!(
        "Loom key:   {}",
        if status.key_present { "present" } else { "missing" }
    );
    println!(
        "Translate:  {}",
        status
            .active_translate_model
            .as_deref()
            .unwrap_or("(none)")
    );
    println!(
        "Notes:      {}",
        status.active_notes_model.as_deref().unwrap_or("(none)")
    );
    if status.connected { 0 } else { 1 }
}

fn run_search(data_dir: PathBuf, query: &str, session_id: Option<&str>) -> i32 {
    let store = SessionStore::open(&data_dir);
    let hits = search_sessions(&store.sessions, query, session_id);
    if hits.is_empty() {
        println!("No matches for \"{query}\".");
        return 0;
    }
    for hit in hits {
        let marker = if hit.homophone_match { " [音近]" } else { "" };
        println!(
            "[{} | {}]{} {}",
            hit.session_id, hit.session_title, marker, hit.text
        );
        if let Some(tr) = hit.translation {
            println!("  -> {tr}");
        }
    }
    0
}

fn run_export(data_dir: PathBuf, session_id: &str, format: ExportFormat) -> i32 {
    let store = SessionStore::open(&data_dir);
    let Some(s) = store.get(session_id) else {
        eprintln!("Session not found: {session_id}");
        return 1;
    };
    match format {
        ExportFormat::Markdown => print!("{}", session_markdown(s)),
        ExportFormat::Srt => print!("{}", session_srt(s)),
    }
    0
}

async fn run_notes(data_dir: PathBuf, session_id: &str, fresh: bool) -> i32 {
    let settings = load_settings(&data_dir);
    let mut store = SessionStore::open(&data_dir);
    let Some(session) = store.get(session_id).cloned() else {
        eprintln!("Session not found: {session_id}");
        return 1;
    };
    let loom = LoomClient::new();
    let status = loom
        .probe_status(
            &settings.loom_url,
            &settings.resolved_loom_dir(),
            &settings.translate_model,
            &settings.notes_model,
        )
        .await;
    let Some(model) = pick_notes_model(&status.models, &settings.notes_model)
        .or_else(|| pick_translate_model(&status.models, &settings.translate_model))
    else {
        eprintln!(
            "No Loom model available: {}",
            status.last_error.as_deref().unwrap_or("Loom disconnected")
        );
        return 1;
    };

    match generate_notes(&loom, &settings, &model, &session, true, fresh).await {
        Ok(notes) => {
            if let Err(e) = store.set_notes(session_id, notes.clone()) {
                eprintln!("Failed to save notes: {e}");
                return 1;
            }
            println!(
                "{}",
                serde_json::to_string_pretty(&notes).unwrap_or_default()
            );
            0
        }
        Err(e) => {
            eprintln!("Failed to generate notes: {e}");
            1
        }
    }
}
