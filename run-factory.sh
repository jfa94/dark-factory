#!/usr/bin/env bash
set -euo pipefail

# --- Resolve FACTORY_DIR (portable, handles symlinks) ---

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
FACTORY_DIR="$(cd "$(dirname "$SOURCE")" && pwd -P)"

# --- Source modules ---

for module in "$FACTORY_DIR"/lib/*.sh; do
  # shellcheck source=/dev/null
  source "$module"
done

# --- Main ---

parse_args "$@"

if [[ "$MODE" == "help" ]]; then
  show_help
  exit 0
fi

validate_project "$PROJECT_DIR"

# --- Deploy factory configs (before lock — no cleanup needed on failure) ---

deploy_factory_configs "$PROJECT_DIR"

# --- Acquire lock ---

acquire_lock "$PROJECT_DIR"

# --- Swap settings (with trap for guaranteed cleanup) ---

cleanup() {
  local exit_code=$?
  restore_settings || true
  release_lock || true
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

if [[ "$SKIP_SETTINGS_SWAP" -eq 0 ]]; then
  swap_settings "$PROJECT_DIR"
else
  log_info "Skipping settings swap (--skip-settings-swap)"
fi

# TODO: Mode routing
# case "$MODE" in
#   issue)      ... ;;
#   discover)   ... ;;
#   spec)       ... ;;
#   interactive) ... ;;
# esac

# TODO: Summary and cleanup (phase 9)
