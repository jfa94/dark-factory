#!/usr/bin/env bash
set -euo pipefail

# API usage monitoring: reads OAuth token from macOS Keychain,
# fetches usage from Anthropic API, and pauses execution when
# approaching rate limits. All failures are non-fatal — the
# pipeline continues if usage checks fail.

# --- Defaults (overridable via environment) ---

USAGE_HARD_CAP_PCT="${USAGE_HARD_CAP_PCT:-90}"
USAGE_POLL_INTERVAL="${USAGE_POLL_INTERVAL:-60}"
USAGE_HOURLY_PAUSE_MAX="${USAGE_HOURLY_PAUSE_MAX:-1800}"  # 30 minutes

# --- Circuit breaker: runtime (overrides placeholder in task-runner.sh) ---

# Defined here (not orchestrator.sh) because modules source alphabetically:
# orchestrator.sh loads before task-runner.sh, so placing it there would
# let the placeholder win. usage.sh loads after task-runner.sh.
check_time_circuit_breaker() {
  local max_seconds=$(( ${MAX_RUNTIME_MINUTES:-360} * 60 ))

  if [[ "$SECONDS" -ge "$max_seconds" ]]; then
    log_error "Runtime circuit breaker: ${SECONDS}s elapsed (limit: ${max_seconds}s)"
    return 1
  fi

  return 0
}

# --- Internal state ---

_OAUTH_TOKEN=""
_OAUTH_TOKEN_LOADED=0
_USAGE_AVAILABLE=0

# --- Internal helpers ---

# Load OAuth token from macOS Keychain.
# Sets _OAUTH_TOKEN on success; logs warning and returns 1 on failure.
_load_oauth_token() {
  if [[ "$_OAUTH_TOKEN_LOADED" -eq 1 ]]; then
    [[ -n "$_OAUTH_TOKEN" ]] && return 0 || return 1
  fi

  _OAUTH_TOKEN_LOADED=1

  _OAUTH_TOKEN="$(security find-generic-password -s "anthropic-oauth" -w 2>/dev/null)" || {
    log_warn "Could not read OAuth token from Keychain — usage checks disabled"
    _OAUTH_TOKEN=""
    return 1
  }

  if [[ -z "$_OAUTH_TOKEN" ]]; then
    log_warn "OAuth token from Keychain is empty — usage checks disabled"
    return 1
  fi

  _USAGE_AVAILABLE=1
  return 0
}

# Fetch current API usage from Anthropic.
# Outputs JSON with usage data; returns 1 on failure.
_fetch_usage() {
  local response
  response="$(curl -sS --max-time 10 \
    -H "Authorization: Bearer ${_OAUTH_TOKEN}" \
    "https://api.anthropic.com/v1/organizations/usage" 2>/dev/null)" || {
    log_warn "API usage fetch failed"
    return 1
  }

  if [[ -z "$response" ]]; then
    log_warn "Empty response from usage API"
    return 1
  fi

  # Validate it's parseable JSON with expected fields
  if ! printf '%s' "$response" | jq -e '.usage and .limit' &>/dev/null; then
    log_warn "Unexpected usage API response format"
    return 1
  fi

  printf '%s' "$response"
}

# Get the hourly threshold percentage for the current hour within
# a 5-hour rate-limit window.
# Returns the threshold as an integer (20, 40, 60, 80, 90).
_get_hourly_threshold() {
  local usage_json="$1"

  # Extract window start and compute elapsed hours
  local window_start_str elapsed_seconds elapsed_hours
  window_start_str="$(printf '%s' "$usage_json" | jq -r '.window_start // empty' 2>/dev/null)" || {
    # No window info — use conservative default
    printf '20'
    return
  }

  if [[ -z "$window_start_str" ]]; then
    printf '20'
    return
  fi

  # Convert window start to epoch
  local window_epoch now_epoch
  window_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${window_start_str%%.*}" "+%s" 2>/dev/null)" || {
    # Fallback: try GNU date format
    window_epoch="$(date -d "$window_start_str" "+%s" 2>/dev/null)" || {
      printf '20'
      return
    }
  }

  now_epoch="$(date "+%s")"
  elapsed_seconds=$(( now_epoch - window_epoch ))
  elapsed_hours=$(( elapsed_seconds / 3600 ))

  # Clamp to 0-4 range
  if [[ "$elapsed_hours" -lt 0 ]]; then
    elapsed_hours=0
  elif [[ "$elapsed_hours" -gt 4 ]]; then
    elapsed_hours=4
  fi

  # Threshold scaling: hour 0→20%, 1→40%, 2→60%, 3→80%, 4→90%
  local thresholds=(20 40 60 80 90)
  printf '%s' "${thresholds[$elapsed_hours]}"
}

# Calculate usage percentage from API response.
# Returns integer percentage (0-100) or empty on parse failure.
_get_usage_pct() {
  local usage_json="$1"

  local usage limit pct
  usage="$(printf '%s' "$usage_json" | jq -r '.usage // empty' 2>/dev/null)" || return 1
  limit="$(printf '%s' "$usage_json" | jq -r '.limit // empty' 2>/dev/null)" || return 1

  if [[ -z "$usage" || -z "$limit" || "$limit" -eq 0 ]]; then
    return 1
  fi

  pct=$(( (usage * 100) / limit ))
  printf '%s' "$pct"
}

# Wait until the next window hour begins.
# Sleeps in increments, respecting the max pause duration.
_wait_for_next_hour() {
  local usage_json="$1"

  local window_start_str
  window_start_str="$(printf '%s' "$usage_json" | jq -r '.window_start // empty' 2>/dev/null)" || return 0

  if [[ -z "$window_start_str" ]]; then
    log_warn "No window_start in usage data — sleeping 5 minutes"
    sleep 300
    return 0
  fi

  local window_epoch now_epoch elapsed_seconds current_hour next_hour_start wait_seconds
  window_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${window_start_str%%.*}" "+%s" 2>/dev/null)" || {
    window_epoch="$(date -d "$window_start_str" "+%s" 2>/dev/null)" || {
      sleep 300
      return 0
    }
  }

  now_epoch="$(date "+%s")"
  elapsed_seconds=$(( now_epoch - window_epoch ))
  current_hour=$(( elapsed_seconds / 3600 ))
  next_hour_start=$(( window_epoch + (current_hour + 1) * 3600 ))
  wait_seconds=$(( next_hour_start - now_epoch ))

  # Clamp to max pause duration
  if [[ "$wait_seconds" -gt "$USAGE_HOURLY_PAUSE_MAX" ]]; then
    wait_seconds="$USAGE_HOURLY_PAUSE_MAX"
  fi

  if [[ "$wait_seconds" -le 0 ]]; then
    return 0
  fi

  log_info "Pausing for $(( wait_seconds / 60 )) minutes until next usage window hour"
  sleep "$wait_seconds"
}

# Wait until window resets (poll-based).
_wait_for_window_reset() {
  log_warn "Usage at hard cap — pausing until window resets"

  local max_wait="${USAGE_HARD_CAP_WAIT:-7200}"  # 2 hours default
  local waited=0

  while [[ "$waited" -lt "$max_wait" ]]; do
    sleep "$USAGE_POLL_INTERVAL"
    waited=$(( waited + USAGE_POLL_INTERVAL ))

    # Respect runtime circuit breaker
    if ! check_time_circuit_breaker; then
      log_error "Runtime circuit breaker tripped during usage wait"
      return 1
    fi

    local usage_json
    usage_json="$(_fetch_usage)" || continue

    local pct
    pct="$(_get_usage_pct "$usage_json")" || continue

    if [[ "$pct" -lt "$USAGE_HARD_CAP_PCT" ]]; then
      log_success "Usage dropped to ${pct}% — resuming"
      return 0
    fi

    log_info "Usage still at ${pct}% (cap: ${USAGE_HARD_CAP_PCT}%) — waiting (${waited}s / ${max_wait}s)"
  done

  log_error "Usage wait timed out after ${max_wait}s"
  return 1
}

# --- Public interface ---

# Check API usage and wait if approaching limits.
# Safe to call anywhere — all failures are non-fatal.
check_usage_and_wait() {
  # Skip if token not available
  if [[ "$_USAGE_AVAILABLE" -eq 0 ]]; then
    _load_oauth_token || return 0
  fi

  local usage_json
  usage_json="$(_fetch_usage)" || return 0

  local pct
  pct="$(_get_usage_pct "$usage_json")" || {
    log_warn "Could not parse usage percentage — skipping check"
    return 0
  }

  # Hard cap: pause and poll until reset
  if [[ "$pct" -ge "$USAGE_HARD_CAP_PCT" ]]; then
    _wait_for_window_reset
    return 0
  fi

  # Hourly threshold check
  local threshold
  threshold="$(_get_hourly_threshold "$usage_json")"

  if [[ "$pct" -ge "$threshold" ]]; then
    log_warn "Usage at ${pct}% exceeds hourly threshold ${threshold}%"
    _wait_for_next_hour "$usage_json"
    return 0
  fi

  return 0
}
