#!/usr/bin/env bash
set -euo pipefail

# --- Colors (respects NO_COLOR: https://no-color.org) ---

if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
  _RED='\033[0;31m'
  _YELLOW='\033[0;33m'
  _GREEN='\033[0;32m'
  _BLUE='\033[0;34m'
  _RESET='\033[0m'
else
  _RED='' _YELLOW='' _GREEN='' _BLUE='' _RESET=''
fi

# --- Logging (all output to stderr) ---

log_info()    { printf "${_BLUE}[INFO]${_RESET}    %s\n" "$*" >&2; }
log_warn()    { printf "${_YELLOW}[WARN]${_RESET}    %s\n" "$*" >&2; }
log_error()   { printf "${_RED}[ERROR]${_RESET}   %s\n" "$*" >&2; }
log_success() { printf "${_GREEN}[SUCCESS]${_RESET} %s\n" "$*" >&2; }

# --- Utilities ---

# Convert a string to a filesystem-safe slug (lowercase, hyphens, no special chars).
# Strips leading [PRD] prefix (case-insensitive) before slugifying.
# Usage: slugify_title "[PRD] My Issue Title!" => "my-issue-title"
slugify_title() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/^\[prd\] *//' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/-\{2,\}/-/g' \
    | sed 's/^-//;s/-$//'
}

# Display a spinner while a background PID is running
# Usage: some_command & spin $!
spin() {
  local pid=$1
  local frames=$'|/-\\'
  local i=0

  # Skip animation if not a terminal
  if ! [[ -t 2 ]]; then
    wait "$pid"
    return $?
  fi

  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s ' "${frames:i++%${#frames}:1}" >&2
    sleep 0.1
  done
  printf '\r    \r' >&2

  wait "$pid"
  return $?
}

# --- Temp directory (created at module load time) ---

FACTORY_TMP_DIR="$(mktemp -d)"

# Path to factory autonomous settings (passed via --settings to all claude invocations).
export FACTORY_SETTINGS="$FACTORY_DIR/templates/settings.autonomous.json"

# Create temp files inside FACTORY_TMP_DIR for cleanup on exit.
# Usage: factory_mktemp  (prints temp file path)
factory_mktemp() {
  mktemp "$FACTORY_TMP_DIR/factory-XXXXXX"
}

# --- Background PID tracking ---

declare -ga _BG_PIDS=()

# Register a background PID for cleanup on exit.
# Usage: some_cmd & register_bg_pid $!
register_bg_pid() {
  _BG_PIDS+=("$1")
}

# Kill all tracked background PIDs. Safe to call multiple times.
_kill_bg_pids() {
  if [[ ${#_BG_PIDS[@]} -eq 0 ]]; then
    return 0
  fi
  for pid in "${_BG_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  _BG_PIDS=()
}

# --- Log directory management ---

# Will be set once spec slug is known (in run-factory.sh).
FACTORY_LOG_DIR=""

# Initialize log directory for a run.
# Usage: init_log_dir <project_dir> <spec_slug>
init_log_dir() {
  local project_dir="$1"
  local spec_slug="$2"
  local timestamp
  timestamp="$(date '+%Y%m%d-%H%M%S')"

  FACTORY_LOG_DIR="${project_dir}/logs/${spec_slug}/${timestamp}"
  mkdir -p "$FACTORY_LOG_DIR"

  # Ensure logs/ is gitignored in target project
  local gitignore="${project_dir}/.gitignore"
  if [[ -f "$gitignore" ]]; then
    if ! grep -qxF 'logs/' "$gitignore" 2>/dev/null; then
      printf '\n# Dark factory logs\nlogs/\n' >> "$gitignore"
    fi
  else
    printf '# Dark factory logs\nlogs/\n' > "$gitignore"
  fi

  log_info "Log directory: $FACTORY_LOG_DIR"
}

# Write a line to the status log.
# Usage: write_status <task_id> <ok|failed|skipped>
write_status() {
  local task_id="$1"
  local status="$2"

  if [[ -z "$FACTORY_LOG_DIR" ]]; then
    return 0
  fi

  printf '%s=%s\n' "$task_id" "$status" >> "${FACTORY_LOG_DIR}/status.log"
}

# Write a line to the PR mapping log.
# Usage: write_pr_map <task_id> <pr_number>
write_pr_map() {
  local task_id="$1"
  local pr_number="$2"

  if [[ -z "$FACTORY_LOG_DIR" ]]; then
    return 0
  fi

  printf '%s=%s\n' "$task_id" "$pr_number" >> "${FACTORY_LOG_DIR}/pr-map.log"
}

# Read completed tasks from status log (for resume).
# Outputs task IDs that have status=ok, one per line.
read_completed_tasks() {
  local log_dir="$1"
  local status_file="${log_dir}/status.log"

  if [[ ! -f "$status_file" ]]; then
    return 0
  fi

  awk -F= '$2 == "ok" { print $1 }' "$status_file"
}
