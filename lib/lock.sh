#!/usr/bin/env bash
set -euo pipefail

# Directory-based locking with stale detection.
# Lock path is deterministic from the target project directory so
# concurrent terminals targeting the same project detect the same lock.

# Module state
_LOCK_DIR=""

# Derive a deterministic lock path from a project directory.
# Uses /tmp with a hash of the absolute path.
_lock_path_for() {
  local project_dir="$1"
  local hash
  hash="$(printf '%s' "$project_dir" | shasum -a 256 | cut -d' ' -f1)"
  printf '/tmp/dark-factory-lock-%s' "$hash"
}

# Check whether a PID is still alive.
_pid_alive() {
  kill -0 "$1" 2>/dev/null
}

# Acquire an exclusive lock for a project directory.
# Creates a directory atomically (POSIX mkdir guarantee).
# Reclaims stale locks whose owning PID is no longer alive.
acquire_lock() {
  local project_dir="$1"
  _LOCK_DIR="$(_lock_path_for "$project_dir")"
  local pid_file="$_LOCK_DIR/pid"

  # Attempt atomic directory creation
  if mkdir "$_LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$pid_file"
    log_info "Lock acquired: $_LOCK_DIR (PID $$)"
    return 0
  fi

  # Lock dir exists — check for stale lock
  if [[ -f "$pid_file" ]]; then
    local owner_pid
    owner_pid="$(cat "$pid_file")"

    if ! _pid_alive "$owner_pid"; then
      log_warn "Reclaiming stale lock (PID $owner_pid no longer alive)"
      rm -rf "$_LOCK_DIR"

      if mkdir "$_LOCK_DIR" 2>/dev/null; then
        printf '%s' "$$" > "$pid_file"
        log_info "Lock acquired: $_LOCK_DIR (PID $$)"
        return 0
      fi
    fi

    log_error "Project is locked by PID $owner_pid"
    log_error "Lock: $_LOCK_DIR"
    _LOCK_DIR=""
    return 1
  fi

  # pid file missing but dir exists — treat as stale
  log_warn "Lock directory exists without PID file; reclaiming"
  rm -rf "$_LOCK_DIR"

  if mkdir "$_LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$_LOCK_DIR/pid"
    log_info "Lock acquired: $_LOCK_DIR (PID $$)"
    return 0
  fi

  log_error "Failed to acquire lock: $_LOCK_DIR"
  _LOCK_DIR=""
  return 1
}

# Release the lock (remove the lock directory).
# Safe to call multiple times.
release_lock() {
  if [[ -n "$_LOCK_DIR" && -d "$_LOCK_DIR" ]]; then
    rm -rf "$_LOCK_DIR"
    log_info "Lock released: $_LOCK_DIR"
  fi
  _LOCK_DIR=""
}
