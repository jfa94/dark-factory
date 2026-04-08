#!/usr/bin/env bash
set -euo pipefail

# API usage monitoring: reads OAuth token from macOS Keychain,
# fetches usage from Anthropic API, and pauses execution when
# approaching rate limits. Failures are fatal — the pipeline
# cannot pace safely without usage data.

# --- Defaults (overridable via environment) ---

USAGE_HARD_CAP_PCT="${USAGE_HARD_CAP_PCT:-90}"
USAGE_POLL_INTERVAL="${USAGE_POLL_INTERVAL:-300}"

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

# Load OAuth token from macOS Keychain (Claude Code credential store).
# Sets _OAUTH_TOKEN on success; logs error and returns 1 on failure.
_load_oauth_token() {
  if [[ "$_OAUTH_TOKEN_LOADED" -eq 1 ]]; then
    [[ -n "$_OAUTH_TOKEN" ]] && return 0 || return 1
  fi

  _OAUTH_TOKEN_LOADED=1

  local raw_creds
  raw_creds="$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null)" || {
    log_error "Could not read Claude credentials from Keychain"
    _OAUTH_TOKEN=""
    return 1
  }

  _OAUTH_TOKEN="$(printf '%s' "$raw_creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)" || {
    log_error "Could not parse access token from Keychain credentials"
    _OAUTH_TOKEN=""
    return 1
  }

  if [[ -z "$_OAUTH_TOKEN" ]]; then
    log_error "OAuth token from Keychain is empty"
    return 1
  fi

  _USAGE_AVAILABLE=1
  return 0
}

# Fetch current API usage from Anthropic.
# Outputs JSON with usage data; returns 1 on failure.
_fetch_usage() {
  local response
  response="$(curl -sf --max-time 10 \
    -H "Authorization: Bearer ${_OAUTH_TOKEN}" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)" || {
    log_error "API usage fetch failed"
    return 1
  }

  if [[ -z "$response" ]]; then
    log_error "Empty response from usage API"
    return 1
  fi

  if ! printf '%s' "$response" | jq -e '.five_hour.utilization' &>/dev/null; then
    log_error "Unexpected usage API response: $(printf '%s' "$response" | head -c 300)"
    return 1
  fi

  printf '%s' "$response"
}

# --- CLI rate limit detection ---

RATE_LIMIT_MAX_WAIT="${RATE_LIMIT_MAX_WAIT:-14400}"  # 4 hours default
RATE_LIMIT_POLL_INTERVAL="${RATE_LIMIT_POLL_INTERVAL:-300}"  # 5 min between probes

# Check if Claude output file contains a CLI rate limit error.
# Returns 0 if rate limited, 1 if not.
# On rate limit, prints the reset info line to stdout.
is_rate_limit_error() {
  local output_file="$1"

  if grep -qiE 'hit your limit|rate.limit|too many requests' "$output_file" 2>/dev/null; then
    grep -oiE 'resets.*' "$output_file" 2>/dev/null | head -1
    return 0
  fi

  return 1
}

# Parse wait time in seconds from "resets 6pm (Europe/London)" style message.
# Prints seconds to stdout; returns 1 on parse failure.
_parse_rate_limit_wait() {
  local reset_msg="$1"

  local time_str
  time_str="$(printf '%s' "$reset_msg" | grep -oiE '[0-9]{1,2}(:[0-9]{2})?\s*(am|pm)' | head -1 | tr -d ' ' | tr '[:lower:]' '[:upper:]')" || true
  [[ -z "$time_str" ]] && return 1

  local tz
  tz="$(printf '%s' "$reset_msg" | grep -oE '\(([A-Za-z_/]+)\)' | tr -d '()' | head -1)" || true
  [[ -z "$tz" ]] && return 1

  local today
  today="$(TZ="$tz" date "+%Y-%m-%d")"

  local target_epoch=""
  if printf '%s' "$time_str" | grep -q ':'; then
    target_epoch="$(TZ="$tz" date -j -f "%Y-%m-%d %I:%M%p" "${today} ${time_str}" "+%s" 2>/dev/null)" \
      || target_epoch="$(TZ="$tz" date -d "${today} ${time_str}" "+%s" 2>/dev/null)" || true
  fi
  if [[ -z "$target_epoch" ]]; then
    target_epoch="$(TZ="$tz" date -j -f "%Y-%m-%d %I%p" "${today} ${time_str}" "+%s" 2>/dev/null)" \
      || target_epoch="$(TZ="$tz" date -d "${today} ${time_str}" "+%s" 2>/dev/null)" || return 1
  fi

  local now_epoch
  now_epoch="$(date "+%s")"
  local wait_secs=$(( target_epoch - now_epoch ))

  [[ "$wait_secs" -lt 0 ]] && wait_secs=$(( wait_secs + 86400 ))
  wait_secs=$(( wait_secs + 60 ))
  [[ "$wait_secs" -gt "$RATE_LIMIT_MAX_WAIT" ]] && wait_secs="$RATE_LIMIT_MAX_WAIT"

  printf '%s' "$wait_secs"
}

# Wait for Claude CLI rate limit to clear.
wait_for_claude_available() {
  local reset_msg="${1:-}"

  if [[ -n "$reset_msg" ]]; then
    local wait_secs
    wait_secs="$(_parse_rate_limit_wait "$reset_msg")" || true

    if [[ -n "$wait_secs" && "$wait_secs" -gt 0 ]]; then
      log_info "Rate limit resets in ~$(( wait_secs / 60 )) minutes — sleeping"

      local slept=0
      while [[ "$slept" -lt "$wait_secs" ]]; do
        local chunk="$RATE_LIMIT_POLL_INTERVAL"
        [[ $(( wait_secs - slept )) -lt "$chunk" ]] && chunk=$(( wait_secs - slept ))
        sleep "$chunk"
        slept=$(( slept + chunk ))

        if ! check_time_circuit_breaker; then
          log_error "Runtime circuit breaker tripped during rate limit wait"
          return 1
        fi

        log_info "Rate limit wait: $(( slept / 60 ))m / $(( wait_secs / 60 ))m"
      done

      return 0
    fi
  fi

  log_info "Polling for rate limit reset (${RATE_LIMIT_POLL_INTERVAL}s intervals)"
  local waited=0

  while [[ "$waited" -lt "$RATE_LIMIT_MAX_WAIT" ]]; do
    sleep "$RATE_LIMIT_POLL_INTERVAL"
    waited=$(( waited + RATE_LIMIT_POLL_INTERVAL ))

    if ! check_time_circuit_breaker; then
      log_error "Runtime circuit breaker tripped during rate limit wait"
      return 1
    fi

    local probe_out
    probe_out="$(factory_mktemp)"
    claude -p "ok" --max-turns 1 --model haiku > "$probe_out" 2>&1 || true

    if ! is_rate_limit_error "$probe_out" > /dev/null; then
      rm -f "$probe_out"
      log_success "Rate limit cleared after $(( waited / 60 )) minutes"
      return 0
    fi

    rm -f "$probe_out"
    log_info "Still rate limited — waiting ($(( waited / 60 ))m / $(( RATE_LIMIT_MAX_WAIT / 60 ))m)"
  done

  log_error "Rate limit wait timed out after $(( RATE_LIMIT_MAX_WAIT / 60 )) minutes"
  return 1
}

# Pre-check: probe Claude CLI to verify we're not rate limited.
check_claude_rate_limit() {
  log_info "Checking Claude availability"

  local probe_out
  probe_out="$(factory_mktemp)"

  claude -p "ok" --max-turns 1 --model haiku > "$probe_out" 2>&1 || true

  local reset_info
  if reset_info="$(is_rate_limit_error "$probe_out")"; then
    rm -f "$probe_out"
    log_warn "Claude is rate limited: $reset_info"
    wait_for_claude_available "$reset_info"
    return $?
  fi

  rm -f "$probe_out"
  log_success "Claude is available"
  return 0
}

# --- Public interface ---

# Check API usage and wait if approaching limits.
# Fatal on any failure — the pipeline requires usage data to pace safely.
check_usage_and_wait() {
  if [[ "$_USAGE_AVAILABLE" -eq 0 ]]; then
    if ! _load_oauth_token; then
      log_error "Usage monitoring unavailable — check Claude OAuth token (run \`claude /login\` to refresh)"
      return 1
    fi
  fi

  local usage_json="" fetch_attempt=0
  while [[ "$fetch_attempt" -lt 3 ]]; do
    fetch_attempt=$(( fetch_attempt + 1 ))
    # On retries, reload token from Keychain — Claude Code may have refreshed it
    if [[ "$fetch_attempt" -gt 1 ]]; then
      _OAUTH_TOKEN_LOADED=0
      _load_oauth_token 2>/dev/null || true
    fi
    usage_json="$(_fetch_usage)" && break
    if [[ "$fetch_attempt" -lt 3 ]]; then
      log_warn "Usage API fetch failed (attempt $fetch_attempt/3) — retrying in 5s"
      sleep 5
    fi
    usage_json=""
  done
  if [[ -z "$usage_json" ]]; then
    log_error "Usage API unavailable after 3 attempts — check network connectivity and OAuth token validity"
    return 1
  fi

  # Parse fields
  local utilization resets_at
  utilization="$(printf '%s' "$usage_json" | jq -r '.five_hour.utilization // empty')" || {
    log_error "Could not parse utilization from usage response — unexpected API response format"
    return 1
  }
  resets_at="$(printf '%s' "$usage_json" | jq -r '.five_hour.resets_at // empty')" || {
    log_error "Could not parse resets_at from usage response — unexpected API response format"
    return 1
  }

  # Right after a window reset the API may transiently return null fields.
  # Default to 0% / synthetic +5h reset — safe to proceed.
  if [[ -z "$utilization" ]]; then
    log_warn "Usage API returned null utilization — assuming 0% (post-reset transient)"
    utilization="0"
  fi
  if [[ -z "$resets_at" ]]; then
    log_warn "Usage API returned null resets_at — assuming +5h"
    resets_at="$(TZ=UTC date -v+5H "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)" \
      || resets_at="$(TZ=UTC date -d "+5 hours" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)" \
      || resets_at="$(TZ=UTC date "+%Y-%m-%dT%H:%M:%S")"
  fi

  # Parse seven-day utilization separately
  local seven_day_utilization seven_day_resets_at
  seven_day_utilization="$(printf '%s' "$usage_json" | jq -r '.seven_day.utilization // empty' 2>/dev/null)" || seven_day_utilization=""
  seven_day_resets_at="$(printf '%s' "$usage_json" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)" || seven_day_resets_at=""

  # Compute 5-hour window position for session pacing
  local now_epoch reset_epoch
  now_epoch="$(date "+%s")"
  reset_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${resets_at%%.*}" "+%s" 2>/dev/null)" \
    || reset_epoch="$(TZ=UTC date -d "${resets_at%%.*}" "+%s" 2>/dev/null)" \
    || { log_error "Could not parse reset time: $resets_at — cannot determine pacing window"; return 1; }

  local window_start window_elapsed window_hour hourly_threshold
  window_start=$(( reset_epoch - 5 * 3600 ))
  window_elapsed=$(( now_epoch - window_start ))
  window_hour=$(( window_elapsed / 3600 + 1 ))
  (( window_hour < 1 )) && window_hour=1
  (( window_hour > 5 )) && window_hour=5

  hourly_threshold=$(( window_hour * 20 ))
  (( hourly_threshold > 90 )) && hourly_threshold=90

  local hard_cap="$USAGE_HARD_CAP_PCT"

  # Compute weekly proportional threshold: (days_elapsed / 7) * 100
  # If we're 3 days into the 7-day window, threshold = 42.9%
  local weekly_threshold="" weekly_day=""
  if [[ -n "$seven_day_utilization" && -n "$seven_day_resets_at" ]]; then
    local weekly_reset_epoch
    weekly_reset_epoch="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${seven_day_resets_at%%.*}" "+%s" 2>/dev/null)" \
      || weekly_reset_epoch="$(TZ=UTC date -d "${seven_day_resets_at%%.*}" "+%s" 2>/dev/null)" \
      || weekly_reset_epoch=""

    if [[ -n "$weekly_reset_epoch" ]]; then
      local weekly_window_start=$(( weekly_reset_epoch - 7 * 86400 ))
      local weekly_elapsed=$(( now_epoch - weekly_window_start ))
      weekly_day=$(( weekly_elapsed / 86400 + 1 ))
      (( weekly_day < 1 )) && weekly_day=1
      (( weekly_day > 7 )) && weekly_day=7
      # Integer approximation: day * 100 / 7 (e.g. day 1→14, day 2→28, day 3→42)
      weekly_threshold=$(( weekly_day * 100 / 7 ))
    fi
  fi

  # Format session resets_at as local HH:MM for readability
  local session_resets_local
  session_resets_local="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${resets_at%%.*}" "+%H:%M" 2>/dev/null)" \
    || session_resets_local="$(date -d "${resets_at%%.*}" "+%H:%M" 2>/dev/null)" \
    || session_resets_local="${resets_at%%T*} ${resets_at##*T}"

  local seven_day_label="" weekly_threshold_label=""
  if [[ -n "$seven_day_utilization" ]]; then
    seven_day_label=" · 7d: ${seven_day_utilization}%"
    [[ -n "$weekly_threshold" ]] && weekly_threshold_label=" (day ${weekly_day}/7, cap ${weekly_threshold}%)"
  fi
  log_usage "5h: ${utilization}% · hour ${window_hour}/5 · threshold ${hourly_threshold}% · hard cap ${hard_cap}% · resets at ${session_resets_local}${seven_day_label}${weekly_threshold_label}"

  # --- Weekly budget check (exit gracefully if over proportional threshold) ---
  # Return 2 to signal callers to stop the pipeline gracefully.
  if [[ -n "$weekly_threshold" ]] && awk -v u="$seven_day_utilization" -v t="$weekly_threshold" 'BEGIN{exit !(u >= t)}'; then
    log_warn "=== WEEKLY BUDGET EXCEEDED: 7d usage ${seven_day_utilization}% >= ${weekly_threshold}% (day ${weekly_day}/7) — stopping pipeline ==="
    log_info "The weekly usage budget has been reached for today. Re-run tomorrow when the proportional threshold increases."
    return 2
  fi

  # --- Session hard cap: at or above 90% of 5h window — wait until session resets ---
  if awk -v u="$utilization" -v c="$hard_cap" 'BEGIN{exit !(u >= c)}'; then
    local wait_secs=$(( reset_epoch - now_epoch + 60 ))

    if [[ "$wait_secs" -le 0 ]]; then
      log_info "Session reset already passed, continuing"
      return 0
    fi

    local wake_time
    wake_time="$(date -r $(( now_epoch + wait_secs )) '+%H:%M:%S' 2>/dev/null)" \
      || wake_time="$(date -d "@$(( now_epoch + wait_secs ))" '+%H:%M:%S' 2>/dev/null)" \
      || wake_time="unknown"

    log_warn "=== USAGE PAUSE (SESSION): ${utilization}% >= ${hard_cap}% hard cap — sleeping $(( wait_secs / 60 ))m until $wake_time ==="

    local remaining="$wait_secs"
    while [[ "$remaining" -gt 0 ]]; do
      local chunk=$(( remaining > USAGE_POLL_INTERVAL ? USAGE_POLL_INTERVAL : remaining ))
      sleep "$chunk"
      remaining=$(( remaining - chunk ))
      SECONDS=$(( SECONDS > chunk ? SECONDS - chunk : 0 ))  # don't count pause time against runtime limit

      if ! check_time_circuit_breaker; then
        log_error "Runtime circuit breaker tripped during usage pause"
        return 1
      fi

      if [[ "$remaining" -gt 0 ]]; then
        log_info "  ... $(( remaining / 60 ))m remaining"
      fi
    done

    log_success "=== USAGE PAUSE (SESSION): resumed ==="
    return 0
  fi

  # --- Session hourly pacing: above hourly threshold — wait until next window hour ---
  if awk -v u="$utilization" -v t="$hourly_threshold" 'BEGIN{exit !(u >= t)}'; then
    local next_window_hour_epoch=$(( window_start + window_hour * 3600 ))
    local wait_secs=$(( next_window_hour_epoch - now_epoch + 10 ))

    if [[ "$wait_secs" -le 0 ]]; then
      log_info "Next window hour already passed, continuing"
      return 0
    fi

    # Cap at 30 minutes for hours 1-4; let hour 5 run to reset
    (( window_hour < 5 && wait_secs > 1800 )) && wait_secs=1800

    local wake_time
    wake_time="$(date -r $(( now_epoch + wait_secs )) '+%H:%M:%S' 2>/dev/null)" \
      || wake_time="$(date -d "@$(( now_epoch + wait_secs ))" '+%H:%M:%S' 2>/dev/null)" \
      || wake_time="unknown"

    local next_hour=$(( window_hour + 1 ))
    (( next_hour > 5 )) && next_hour=5

    log_warn "=== USAGE PAUSE (HOURLY): ${utilization}% >= ${hourly_threshold}% (window hour ${window_hour}) — sleeping $(( wait_secs / 60 ))m until hour ${next_hour} at $wake_time ==="

    local remaining="$wait_secs"
    while [[ "$remaining" -gt 0 ]]; do
      local chunk=$(( remaining > USAGE_POLL_INTERVAL ? USAGE_POLL_INTERVAL : remaining ))
      sleep "$chunk"
      remaining=$(( remaining - chunk ))
      SECONDS=$(( SECONDS > chunk ? SECONDS - chunk : 0 ))  # don't count pause time against runtime limit

      if ! check_time_circuit_breaker; then
        log_error "Runtime circuit breaker tripped during usage pause"
        return 1
      fi

      if [[ "$remaining" -gt 0 ]]; then
        log_info "  ... $(( remaining / 60 ))m remaining"
      fi
    done

    log_success "=== USAGE PAUSE (HOURLY): resumed — now in window hour ${next_hour} ==="
  fi

  return 0
}
