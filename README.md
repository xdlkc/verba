# Verba (`言辞`)

English | [简体中文](./README.zh-CN.md)

**Verba** is a local-first macOS application for real-time bilingual subtitles, structured meeting notes, phonetic transcript search, and Obsidian synchronization.

- **On-device audio capture & speech recognition**: Captures system playback audio and an optional live room microphone via macOS CoreAudio Process Tap (`CATapDescription`, no Screen Recording permission required), then transcribes locally with Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+) or `SFSpeechRecognizer` fallback (macOS 14.4+). **Raw audio never leaves your Mac.**
- **Rust core engine (`verba-engine`)**: Handles live/batch translation scheduling, Mandarin pinyin homophone/phonetic correction, progressive structured meeting notes and fishbone diagrams, full-text + phonetic search, Markdown/SRT/Obsidian export, and a local Axum HTTP + SSE server (`127.0.0.1:4391`).
- **Local Loom AI gateway**: All translation, contextual glossary correction, and structured note generation route through your local [Loom](https://github.com/xdlkc/loom) gateway (`http://127.0.0.1:4319/v1` with `hub.key` authentication), using a priority queue where live subtitle translation preempts note generation, which preempts batch file imports.

## Core Features

1. **Real-Time Bilingual Subtitle Overlay**:
   - Displays streaming interim translations while listening and finalizes each utterance on completion.
   - Click-through by default, fades to 15% opacity on cursor hover, and enters drag-and-resize edit mode after hovering still for 0.6s.
   - Protected from screen sharing capture (`sharingType = .none`); toggle visibility globally with `⌃⌥S`.
2. **Structured Meeting Notes & Fishbone Diagrams**:
   - Generates meeting titles, executive summaries, timestamped topic timelines, cause-and-effect / trade-off fishbone diagrams, conclusions, owner-tagged clickable action items, and a bilingual terminology glossary.
   - Anti-capture floating notes window (`sharingType = .none` by default) adapts cleanly across narrow, card, and two-column layouts.
   - Live phonetic confirmation bar asks to learn misheard terms into your persistent custom vocabulary.
3. **Meeting Archive, Phonetic Search & Audio Sync**:
   - Searches past transcripts and notes with Mandarin pinyin homophone matching (flagged with `[音近]`).
   - Built-in audio playback (`system.m4a`) with speed cycling (`1.0x`, `1.25x`, `1.5x`, `2.0x`); click any timestamp or search hit to jump directly to that moment in the recording.
   - Supports per-line correction with optional whole-session batch replacement and speaker renaming.
4. **Local Media Import & Obsidian Vault Sync**:
   - Imports `.m4a`, `.mp3`, `.wav`, `.mp4`, `.mov`, and other AVFoundation audio/video files for on-device transcription, Loom translation, and note generation.
   - Automatically discovers local Obsidian Vaults and exports Markdown with YAML frontmatter or bilingual `.srt` subtitles to your selected folder.

## Architecture

```text
verba/
├── Cargo.toml                  # Rust engine & CLI crate (verba-engine, Apache-2.0)
├── VERSION                     # App bundle version (0.1.0)
├── src/
│   ├── main.rs                 # CLI: serve / status / search / export / notes
│   ├── server.rs               # Axum HTTP + SSE local service (127.0.0.1:4391)
│   ├── loom.rs                 # Loom OpenAI gateway client, hub.key auth & priority queue
│   ├── translator.rs           # Streaming/line/import translation + glossary-aware prompts
│   ├── notes.rs                # Incremental & long-meeting segmented notes + fishbone generation
│   ├── correction.rs           # Pinyin homophone matching, edit distance & manual fix learning
│   ├── heard.rs                # Streaming ASR cleanup, sentence segmentation & merging
│   ├── search.rs               # Notes + Chinese phonetic transcript search
│   ├── export.rs               # Markdown (YAML frontmatter) / SRT / Obsidian folder sync
│   ├── store.rs                # Local session store (~/Library/Application Support/Verba)
│   └── config.rs               # Settings, custom vocabulary & Obsidian Vault discovery
├── macos/
│   ├── Package.swift           # SwiftPM native macOS app (macOS 14.4+)
│   ├── Resources/Info.plist    # Bundle metadata & audio/speech usage descriptions
│   └── Sources/
│       ├── Verba/              # CoreAudio Tap, on-device ASR, importer, AppKit/SwiftUI UI
│       └── VerbaIcon/          # Programmatic AppIcon generator
└── scripts/
    ├── build.sh                # Builds Rust + Swift and bundles signed build/Verba.app
    └── test.sh                 # Runs Rust tests, Clippy (-D warnings), and Swift build check
```

## Requirements

- macOS 14.4 or later (`LSMinimumSystemVersion = 14.4`)
- Xcode Command Line Tools / Swift 6 toolchain and Rust (`1.89+`)
- A running local [Loom](https://github.com/xdlkc/loom) instance listening on `http://127.0.0.1:4319` (key at `~/Library/Application Support/ModelHub/.local/hub.key`, overridable via `MODEL_HUB_DATA_DIR`)

## Build & Run

```bash
# Run unit/integration tests, Clippy, and Swift build verification
./scripts/test.sh

# Build release verba-engine + Swift app into build/Verba.app (pass --dev for debug Swift build)
./scripts/build.sh

# Launch the app
open build/Verba.app
```

You can also inspect status, search archives, export transcripts, or regenerate notes directly from the `verba-engine` CLI (`--data-dir` overrides `VERBA_DATA_DIR` / `~/Library/Application Support/Verba`):

```bash
cargo run --bin verba-engine -- serve --port 4391
cargo run --bin verba-engine -- status --json
cargo run --bin verba-engine -- search "phonetic-keyword"
cargo run --bin verba-engine -- export <session-id> --format markdown
cargo run --bin verba-engine -- export <session-id> --format srt
cargo run --bin verba-engine -- notes <session-id> --fresh
```

## License

Licensed under the **Apache-2.0** license (declared in [`Cargo.toml`](./Cargo.toml)).
