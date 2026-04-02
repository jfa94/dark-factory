#!/usr/bin/env bash
set -euo pipefail

# Orchestrator: main execution loop. Iterates tasks in dependency
# order, invokes task runner and code review, manages PR merge
# waiting, and enforces circuit breakers.

# --- Defaults (overridable via environment) ---

MAX_TASKS="${MAX_TASKS:-20}"
MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-360}"
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"
PR_MERGE_TIMEOUT="${PR_MERGE_TIMEOUT:-2700}"       # 45 minutes in seconds
PR_MERGE_POLL_INTERVAL="${PR_MERGE_POLL_INTERVAL:-30}"

# --- Circuit breaker state ---

_TASKS_EXECUTED=0
_CONSECUTIVE_FAILURES=0

# --- Task outcome tracking ---

# Associative arrays for tracking task outcomes and PR URLs.
declare -gA _TASK_STATUS=()   # task_id -> success|failure|skipped
declare -gA _TASK_PR_URL=()   # task_id -> PR URL (if created)

# --- Circuit breakers ---

# NOTE: check_time_circuit_breaker() is defined in usage.sh (not here)
# because modules source alphabetically and orchestrator.sh loads before
# task-runner.sh. Placing it in usage.sh (which loads after task-runner.sh)
# ensures the real implementation overrides the placeholder.

# Check all circuit breakers. Returns 1 if any tripped.
_check_circuit_breakers() {
  # Task count
  if [[ "$_TASKS_EXECUTED" -ge "$MAX_TASKS" ]]; then
    log_error "Task count circuit breaker: $_TASKS_EXECUTED tasks executed (limit: $MAX_TASKS)"
    return 1
  fi

  # Runtime
  if ! check_time_circuit_breaker; then
    return 1
  fi

  # Consecutive failures
  if [[ "$_CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]]; then
    log_error "Consecutive failure circuit breaker: $_CONSECUTIVE_FAILURES failures (limit: $MAX_CONSECUTIVE_FAILURES)"
    return 1
  fi

  return 0
}

# --- Dependency helpers ---

# Check whether a task's dependencies all succeeded.
# Returns 0 if all deps are satisfied, 1 if any failed/skipped.
# On failure, prints the name of the blocking dependency to stdout.
_check_dependencies() {
  local task_id="$1"

  local deps
  deps="$(jq -r --arg id "$task_id" \
    '.[] | select(.task_id == $id) | .depends_on // [] | .[]' \
    "$_TASKS_FILE" 2>/dev/null)" || return 0

  if [[ -z "$deps" ]]; then
    return 0
  fi

  while IFS= read -r dep_id; do
    local dep_status="${_TASK_STATUS[$dep_id]:-pending}"

    if [[ "$dep_status" == "failure" || "$dep_status" == "skipped" ]]; then
      printf '%s' "$dep_id"
      return 1
    fi
  done <<< "$deps"

  return 0
}

# Wait for all dependency PRs to merge into staging.
# Returns 0 when all merged, 1 on timeout or cancelled auto-merge.
_wait_for_dependency_prs() {
  local task_id="$1"

  local deps
  deps="$(jq -r --arg id "$task_id" \
    '.[] | select(.task_id == $id) | .depends_on // [] | .[]' \
    "$_TASKS_FILE" 2>/dev/null)" || return 0

  if [[ -z "$deps" ]]; then
    return 0
  fi

  while IFS= read -r dep_id; do
    local pr_url="${_TASK_PR_URL[$dep_id]:-}"

    # No PR URL — dep might have been approved with NEEDS_DISCUSSION or
    # might not have a PR. Skip waiting.
    if [[ -z "$pr_url" ]]; then
      continue
    fi

    # Check if already merged
    local pr_state
    pr_state="$(gh pr view "$pr_url" --json state --jq '.state' 2>/dev/null)" || {
      log_warn "Could not check PR state for $dep_id — skipping wait"
      continue
    }

    if [[ "$pr_state" == "MERGED" ]]; then
      continue
    fi

    # Poll until merged, timeout, or cancelled
    log_info "Waiting for $dep_id PR to merge: $pr_url"
    local waited=0

    while [[ "$waited" -lt "$PR_MERGE_TIMEOUT" ]]; do
      sleep "$PR_MERGE_POLL_INTERVAL"
      waited=$(( waited + PR_MERGE_POLL_INTERVAL ))

      pr_state="$(gh pr view "$pr_url" --json state --jq '.state' 2>/dev/null)" || {
        log_warn "PR state check failed for $dep_id — retrying"
        continue
      }

      if [[ "$pr_state" == "MERGED" ]]; then
        log_success "Dependency PR merged: $dep_id"
        break
      fi

      # Detect cancelled auto-merge (checks failed → PR closed or review changes requested)
      if [[ "$pr_state" == "CLOSED" ]]; then
        log_error "Dependency PR was closed (checks likely failed): $dep_id"
        return 1
      fi

      # Check if auto-merge was cancelled due to failing checks
      local merge_state_status
      merge_state_status="$(gh pr view "$pr_url" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null)" || true

      if [[ "$merge_state_status" == "BLOCKED" ]]; then
        # Check if status checks are failing
        local check_status
        check_status="$(gh pr checks "$pr_url" 2>/dev/null)" || true

        if printf '%s' "$check_status" | grep -qE '(fail|error)'; then
          log_error "Dependency PR checks failing — auto-merge cancelled: $dep_id"
          return 1
        fi
      fi

      log_info "Still waiting for $dep_id PR to merge (${waited}s / ${PR_MERGE_TIMEOUT}s)"
    done

    if [[ "$pr_state" != "MERGED" ]]; then
      log_error "Timeout waiting for $dep_id PR to merge (${PR_MERGE_TIMEOUT}s)"
      return 1
    fi
  done <<< "$deps"

  # Pull latest staging after all dependency PRs merged
  log_info "Pulling latest staging after dependency merges"
  git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || true
  git -C "$PROJECT_DIR" pull --quiet origin staging 2>/dev/null || {
    log_warn "Failed to pull latest staging — continuing"
  }

  return 0
}

# --- Task execution ---

# Execute a single task through the run → review → PR pipeline.
# Returns 0 on success (PR created), 1 on failure.
_execute_single_task() {
  local task_id="$1"

  # Run the task
  if ! run_task "$task_id"; then
    _TASK_STATUS["$task_id"]="failure"
    return 1
  fi

  # Task passed — get task JSON for review
  local task_json
  task_json="$(jq -e --arg id "$task_id" '.[] | select(.task_id == $id)' "$_TASKS_FILE" 2>/dev/null)" || {
    log_error "Could not read task JSON for $task_id"
    _TASK_STATUS["$task_id"]="failure"
    return 1
  }

  # Review the task
  local review_rc=0
  review_task "$task_id" "$task_json" || review_rc=$?

  case "$review_rc" in
    0)
      _TASK_STATUS["$task_id"]="success"

      # Capture PR URL from the branch (review_task creates the PR)
      local pr_url
      pr_url="$(gh pr view "feat/${task_id}" -R "$(git -C "$PROJECT_DIR" remote get-url origin)" \
        --json url --jq '.url' 2>/dev/null)" || true

      if [[ -n "$pr_url" ]]; then
        _TASK_PR_URL["$task_id"]="$pr_url"
      fi

      return 0
      ;;

    1)
      # REQUEST_CHANGES — code-review.sh set TASK_FAILURE_TYPE=code_review; retry
      log_info "Review requested changes for $task_id — retrying with review findings"
      local review_findings="${TASK_FAILURE_OUTPUT:-}"

      if run_task "$task_id"; then
        local followup_rc=0
        review_task "$task_id" "$task_json" 1 "$review_findings" || followup_rc=$?

        if [[ "$followup_rc" -eq 0 ]]; then
          _TASK_STATUS["$task_id"]="success"

          local pr_url
          pr_url="$(gh pr view "feat/${task_id}" -R "$(git -C "$PROJECT_DIR" remote get-url origin)" \
            --json url --jq '.url' 2>/dev/null)" || true

          if [[ -n "$pr_url" ]]; then
            _TASK_PR_URL["$task_id"]="$pr_url"
          fi

          return 0
        fi
      fi

      _TASK_STATUS["$task_id"]="failure"
      return 1
      ;;

    *)
      # Hard failure (review session crashed, unexpected verdict)
      _TASK_STATUS["$task_id"]="failure"
      return 1
      ;;
  esac
}

# --- Public interface ---

# Execute all tasks in topological order with circuit breakers
# and dependency management.
# Expects: TASK_ORDER (newline-separated task IDs), _TASKS_FILE, PROJECT_DIR
execute_tasks() {
  if [[ -z "${TASK_ORDER:-}" ]]; then
    log_error "No task order defined — nothing to execute"
    return 1
  fi

  log_info "Starting task execution (max tasks: $MAX_TASKS, max runtime: ${MAX_RUNTIME_MINUTES}m)"

  while IFS= read -r task_id; do
    [[ -z "$task_id" ]] && continue

    log_info "--- Task: $task_id ---"

    # Circuit breakers
    if ! _check_circuit_breakers; then
      log_error "Circuit breaker tripped — stopping execution"
      return 1
    fi

    # Usage check — fatal if usage cannot be determined
    if ! check_usage_and_wait; then
      log_error "Usage check failed — aborting task execution"
      return 1
    fi

    # Dependency check — skip if any dep failed or was skipped
    local blocking_dep
    if blocking_dep="$(_check_dependencies "$task_id")"; then
      : # all deps satisfied
    else
      log_warn "Skipping $task_id — dependency $blocking_dep failed or was skipped"
      _TASK_STATUS["$task_id"]="skipped"
      write_status "$task_id" "skipped"
      continue
    fi

    # Wait for dependency PRs to merge
    if ! _wait_for_dependency_prs "$task_id"; then
      log_error "Dependency PR merge failed for $task_id — skipping"
      _TASK_STATUS["$task_id"]="skipped"
      write_status "$task_id" "skipped"
      continue
    fi

    # Skip already-completed tasks (resume)
    if [[ "${_TASK_STATUS[$task_id]:-}" == "success" ]]; then
      log_info "Skipping $task_id — already completed (resumed)"
      continue
    fi

    # Execute
    _TASKS_EXECUTED=$(( _TASKS_EXECUTED + 1 ))

    if _execute_single_task "$task_id"; then
      _CONSECUTIVE_FAILURES=0
      log_success "Task $task_id completed"
    else
      _CONSECUTIVE_FAILURES=$(( _CONSECUTIVE_FAILURES + 1 ))
      log_error "Task $task_id failed (consecutive failures: $_CONSECUTIVE_FAILURES)"
    fi

    # Persist status to disk immediately for resume support
    case "${_TASK_STATUS[$task_id]:-failure}" in
      success) write_status "$task_id" "ok" ;;
      failure) write_status "$task_id" "failed" ;;
      skipped) write_status "$task_id" "skipped" ;;
    esac
    if [[ -n "${_TASK_PR_URL[$task_id]:-}" ]]; then
      local _pr_num
      _pr_num="$(printf '%s' "${_TASK_PR_URL[$task_id]}" | grep -oE '[0-9]+$')" || true
      [[ -n "$_pr_num" ]] && write_pr_map "$task_id" "$_pr_num"
    fi

  done <<< "$TASK_ORDER"

  # Summary
  local total=0 succeeded=0 failed=0 skipped=0
  for tid in "${!_TASK_STATUS[@]}"; do
    total=$(( total + 1 ))
    case "${_TASK_STATUS[$tid]}" in
      success) succeeded=$(( succeeded + 1 )) ;;
      failure) failed=$(( failed + 1 )) ;;
      skipped) skipped=$(( skipped + 1 )) ;;
    esac
  done

  log_info "Execution summary: $succeeded succeeded, $failed failed, $skipped skipped (of $total)"

  if [[ "$failed" -gt 0 || "$skipped" -gt 0 ]]; then
    return 1
  fi

  return 0
}
