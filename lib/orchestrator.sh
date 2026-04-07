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
MAX_CI_FIX_ATTEMPTS="${MAX_CI_FIX_ATTEMPTS:-2}"
CI_FIX_POLL_TIMEOUT="${CI_FIX_POLL_TIMEOUT:-900}"  # 15 minutes per fix attempt

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

# --- CI self-healing ---

# Extract structured CI failure context from a PR for use in fix prompts.
# Outputs: formatted string with failing check names and truncated log output.
# Usage: _extract_ci_failure_context <pr_url> <dep_branch>
_extract_ci_failure_context() {
  local pr_url="$1"
  local dep_branch="$2"

  local context="Failing checks:\n"

  local failing_checks
  failing_checks="$(gh pr checks "$pr_url" --json name,bucket,link \
    --jq '[.[] | select(.bucket == "fail")] | .[] | "- \(.name): \(.link)"' 2>/dev/null)" || true

  if [[ -n "$failing_checks" ]]; then
    context+="${failing_checks}\n"
  else
    context+="(could not retrieve check details)\n"
  fi

  context+="\n"

  # Get latest run ID for the branch
  local run_id
  run_id="$(gh run list --branch "$dep_branch" --limit 1 \
    --json databaseId --jq '.[0].databaseId' 2>/dev/null)" || true

  if [[ -n "$run_id" ]]; then
    local failed_logs
    failed_logs="$(gh run view "$run_id" --log-failed 2>/dev/null | tail -n 200)" || true

    if [[ -n "$failed_logs" ]]; then
      context+="Failed CI logs (last 200 lines):\n\`\`\`\n${failed_logs}\n\`\`\`\n"
    fi
  fi

  printf '%s' "$context"
}

# Attempt to fix failing CI on a dependency PR.
# Checks out the dep branch, invokes Claude with failure context, pushes, re-enables auto-merge.
# Returns 0 if PR subsequently merges, 1 if all attempts exhausted.
# Usage: _attempt_dep_ci_fix <dep_id> <pr_url> <task_id>
_attempt_dep_ci_fix() {
  local dep_id="$1"
  local pr_url="$2"
  local task_id="$3"

  local dep_branch="feat/${dep_id}"
  local attempt=0
  local pr_state=""

  while [[ "$attempt" -lt "$MAX_CI_FIX_ATTEMPTS" ]]; do
    attempt=$(( attempt + 1 ))
    log_info "CI fix attempt $attempt/$MAX_CI_FIX_ATTEMPTS for $dep_id (needed by $task_id)"

    local ci_context
    ci_context="$(_extract_ci_failure_context "$pr_url" "$dep_branch")"

    # Checkout dependency branch
    if ! git -C "$PROJECT_DIR" checkout "$dep_branch" --quiet 2>/dev/null; then
      log_error "Could not checkout $dep_branch for CI fix"
      git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || true
      write_ci_fix "$task_id" "$dep_id" "failed"
      return 1
    fi
    git -C "$PROJECT_DIR" pull --quiet origin "$dep_branch" 2>/dev/null || true

    # Build fix prompt and invoke Claude
    local prompt_file
    prompt_file="$(_build_ci_fix_prompt "$dep_id" "$ci_context")"

    local claude_output_file
    claude_output_file="$(factory_mktemp)"

    _MODEL_ARGS=()
    _MAX_TURNS=40

    local claude_exit=0
    _invoke_claude "$prompt_file" "$claude_output_file" || claude_exit=$?
    rm -f "$prompt_file" "$claude_output_file"

    if [[ "$claude_exit" -ne 0 ]]; then
      log_warn "Claude CI fix session failed for $dep_id (exit $claude_exit)"
      git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || true
      continue
    fi

    # Check if Claude made any changes
    if git -C "$PROJECT_DIR" diff --quiet HEAD "origin/${dep_branch}" 2>/dev/null; then
      log_warn "CI fix produced no changes for $dep_id"
      git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || true
      continue
    fi

    # Push fixes
    if ! git -C "$PROJECT_DIR" push origin "$dep_branch" --quiet 2>/dev/null; then
      log_error "Failed to push CI fix for $dep_id"
      git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || true
      write_ci_fix "$task_id" "$dep_id" "failed"
      return 1
    fi

    log_success "Pushed CI fix for $dep_id (attempt $attempt)"

    # Re-enable auto-merge (may have been cancelled by failed checks)
    gh pr merge --auto --squash "$pr_url" 2>/dev/null || true

    git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || true

    # Give GitHub a moment before polling for new CI
    sleep 15

    # Poll for new CI result
    local ci_wait=0
    local check_summary=""

    while [[ "$ci_wait" -lt "$CI_FIX_POLL_TIMEOUT" ]]; do
      sleep "$PR_MERGE_POLL_INTERVAL"
      ci_wait=$(( ci_wait + PR_MERGE_POLL_INTERVAL ))

      pr_state="$(gh pr view "$pr_url" --json state --jq '.state' 2>/dev/null)" || continue

      if [[ "$pr_state" == "MERGED" ]]; then
        log_success "Dependency PR merged after CI fix: $dep_id"
        write_ci_fix "$task_id" "$dep_id" "fixed"
        return 0
      fi

      check_summary="$(gh pr checks "$pr_url" --json bucket \
        --jq '[.[] | .bucket] | if any(. == "fail") then "fail" elif any(. == "pending") then "pending" else "pass" end' \
        2>/dev/null)" || continue

      if [[ "$check_summary" == "fail" ]]; then
        log_warn "CI still failing after fix attempt $attempt for $dep_id"
        break
      fi

      log_info "CI fix: waiting for $dep_id checks (${ci_wait}s / ${CI_FIX_POLL_TIMEOUT}s) [$check_summary]"
    done

    # If we exited the poll loop with MERGED, we already returned 0 above
    if [[ "$pr_state" == "MERGED" ]]; then
      write_ci_fix "$task_id" "$dep_id" "fixed"
      return 0
    fi
  done

  log_error "CI fix exhausted $MAX_CI_FIX_ATTEMPTS attempts for $dep_id"
  write_ci_fix "$task_id" "$dep_id" "failed"
  return 1
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

      if [[ "$merge_state_status" == "CONFLICTING" || "$merge_state_status" == "DIRTY" ]]; then
        log_warn "Dependency PR has merge conflicts: $dep_id — attempting rebase"
        local dep_branch="feat/${dep_id}"
        local rebase_ok=0

        git -C "$PROJECT_DIR" fetch origin "$dep_branch" staging --quiet 2>/dev/null || true

        if git -C "$PROJECT_DIR" checkout "$dep_branch" --quiet 2>/dev/null; then
          git -C "$PROJECT_DIR" pull --quiet origin "$dep_branch" 2>/dev/null || true

          local rebase_cmd_ok=0
          git -C "$PROJECT_DIR" rebase origin/staging --quiet 2>/dev/null && rebase_cmd_ok=1

          # If rebase hit conflicts, try auto-resolving pipeline tracking files
          # (claude-progress.json, feature-status.json) which should not be on feature branches
          if [[ "$rebase_cmd_ok" -eq 0 ]]; then
            local conflict_files
            conflict_files="$(git -C "$PROJECT_DIR" diff --name-only --diff-filter=U 2>/dev/null)" || true
            local non_tracking_conflicts
            non_tracking_conflicts="$(printf '%s\n' "$conflict_files" \
              | grep -v '^claude-progress\.json$' \
              | grep -v '^feature-status\.json$')" || true

            if [[ -z "$non_tracking_conflicts" && -n "$conflict_files" ]]; then
              log_warn "Auto-resolving pipeline tracking file conflicts for $dep_id"
              # Take staging's version for these files (--ours in rebase = the base, i.e. staging)
              printf '%s\n' "$conflict_files" | while IFS= read -r f; do
                git -C "$PROJECT_DIR" checkout --ours -- "$f" 2>/dev/null || true
                git -C "$PROJECT_DIR" add -- "$f" 2>/dev/null || true
              done
              GIT_EDITOR=true git -C "$PROJECT_DIR" rebase --continue --quiet 2>/dev/null \
                && rebase_cmd_ok=1 || true
            else
              # Real code conflicts — retry with -X theirs to prefer feature branch's changes
              git -C "$PROJECT_DIR" rebase --abort 2>/dev/null || true
              log_warn "Retrying rebase with -X theirs for $dep_id"
              git -C "$PROJECT_DIR" rebase origin/staging -X theirs --quiet 2>/dev/null \
                && rebase_cmd_ok=1 || true
            fi
          fi

          if [[ "$rebase_cmd_ok" -eq 1 ]]; then
            if git -C "$PROJECT_DIR" push --force-with-lease origin "$dep_branch" --quiet 2>/dev/null; then
              log_success "Rebased and pushed $dep_branch — re-enabling auto-merge"
              gh pr merge --auto --squash "$pr_url" 2>/dev/null || true
              rebase_ok=1
            else
              log_error "Failed to push rebased $dep_branch"
            fi
          else
            log_error "Rebase of $dep_branch onto staging failed (unresolvable conflicts)"
            git -C "$PROJECT_DIR" rebase --abort 2>/dev/null || true
          fi

          git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || true
        else
          log_error "Could not checkout $dep_branch for rebase"
        fi

        if [[ "$rebase_ok" -eq 0 ]]; then
          return 1
        fi
        # Rebase succeeded — fall through to continue polling for merge
      fi

      if [[ "$merge_state_status" == "BLOCKED" ]]; then
        # Use structured JSON to distinguish definitively failed vs still pending
        local check_summary
        check_summary="$(gh pr checks "$pr_url" --json bucket \
          --jq '[.[] | .bucket] | if any(. == "fail") then "fail" elif any(. == "pending") then "pending" else "pass" end' \
          2>/dev/null)" || true

        if [[ "$check_summary" == "fail" ]]; then
          log_warn "Dependency PR checks failing for $dep_id — attempting CI fix"

          if _attempt_dep_ci_fix "$dep_id" "$pr_url" "$task_id"; then
            # Fix succeeded and PR merged — update local state and move on
            pr_state="MERGED"
            break
          fi

          log_error "CI fix failed for $dep_id — cannot proceed"
          return 1
        fi
        # "pending" = checks still running, keep waiting
      fi

      if [[ "$merge_state_status" == "BEHIND" ]]; then
        gh pr update-branch "$pr_url" 2>/dev/null || true
        log_info "Updated branch for $dep_id (was BEHIND)"
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

# Restore project to staging after any task execution.
# Called from execute_tasks after _execute_single_task completes.
_restore_staging() {
  git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || true
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

  local _total_tasks
  _total_tasks="$(printf '%s\n' "$TASK_ORDER" | grep -c .)" || _total_tasks="?"

  log_header "Task Execution  (max: $MAX_TASKS tasks · ${MAX_RUNTIME_MINUTES}m runtime)"


  local _task_num=0
  while IFS= read -r task_id; do
    [[ -z "$task_id" ]] && continue
    _task_num=$(( _task_num + 1 ))

    log_header "Task ${_task_num}/${_total_tasks}: ${task_id}"

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

    _restore_staging

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
