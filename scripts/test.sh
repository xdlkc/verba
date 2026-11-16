#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${SDKROOT:-}" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]] && \
   [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi

echo "==> Running Rust unit & HTTP integration tests..."
cargo test --manifest-path "$ROOT/Cargo.toml"

echo "==> Running Rust Clippy (-D warnings)..."
cargo clippy --manifest-path "$ROOT/Cargo.toml" --all-targets -- -D warnings

echo "==> Verifying macOS Swift package compilation..."
swift build --package-path "$ROOT/macos"

echo "All Verba checks passed."
