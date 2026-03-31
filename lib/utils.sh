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

# Convert a string to a filesystem-safe slug (lowercase, hyphens, no special chars)
# Usage: slugify_title "My [PRD] Issue Title!" => "my-prd-issue-title"
slugify_title() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/-\{2,\}/-/g' \
    | sed 's/^-//;s/-$//'
}

# Display a spinner while a background PID is running
# Usage: some_command & spin $!
spin() {
  local pid=$1
  local frames='|/-\'
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
