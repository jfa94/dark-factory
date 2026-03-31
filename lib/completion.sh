#!/usr/bin/env bash
set -euo pipefail

# Completion: resume detection, summary printing, issue management,
# PR merge waiting, and post-run cleanup (branch deletion, spec
# removal, log cleanup).

# --- Defaults (overridable via environment) ---

COMPLETION_PR_MERGE_TIMEOUT="${COMPLETION_PR_MERGE_TIMEOUT:-3600}"  # 60 minutes
COMPLETION_PR_POLL_INTERVAL="${COMPLETION_PR_POLL_INTERVAL:-30}"

# --- Resume detection ---

# Check for prior runs of a spec and prompt user to resume or start fresh.
# Sets RESUME_LOG_DIR (path to prior log dir) and RESUME_SKIP_SET (newline-
# separated task IDs to skip) if resuming; both empty if starting fresh.
# Usage: check_resume <project_dir> <spec_slug>
check_resume() {
  local project_dir="$1"
  local spec_slug="$2"
  local logs_base="${project_dir}/logs/${spec_slug}"

  RESUME_LOG_DIR=""
  RESUME_SKIP_SET=""

  if [[ ! -d "$logs_base" ]]; then
    return 0
  fi

  # Find most recent log directory with a status.log
  local latest_dir=""
  local dirs
  dirs="$(ls -1d "${logs_base}"/*/ 2>/dev/null | sort -r)" || return 0

  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    if [[ -f "${dir}status.log" ]]; then
      latest_dir="$dir"
      break
    fi
  done <<< "$dirs"

  if [[ -z "$latest_dir" ]]; then
    return 0
  fi

  # Prior run detected — prompt user
  log_warn "Prior run detected: $latest_dir"

  local completed
  completed="$(read_completed_tasks "$latest_dir")"
  local completed_count=0
  if [[ -n "$completed" ]]; then
    completed_count="$(printf '%s\n' "$completed" | wc -l | tr -d ' ')"
  fi

  log_info "  $completed_count task(s) completed in prior run"

  printf '\n' >&2
  log_info "Choose:"
  log_info "  [r] Resume — skip completed tasks, continue from where it left off"
  log_info "  [f] Fresh  — start over from scratch"
  printf '\n' >&2

  local choice
  while true; do
    read -rp "  Enter choice (r/f): " choice
    case "$choice" in
      r|R)
        RESUME_LOG_DIR="$latest_dir"
        RESUME_SKIP_SET="$completed"
        log_info "Resuming from prior run"
        return 0
        ;;
      f|F)
        log_info "Starting fresh"
        return 0
        ;;
      *)
        log_warn "Invalid choice — enter 'r' or 'f'"
        ;;
    esac
  done
}

# Detect commits ahead of staging on feat/<task-id> branches for resumed tasks.
# Outputs context string for passing to Claude prompts.
# Usage: get_resume_context <project_dir> <task_id>
get_resume_context() {
  local project_dir="$1"
  local task_id="$2"
  local branch="feat/${task_id}"

  # Check if branch exists
  if ! git -C "$project_dir" rev-parse --verify "$branch" &>/dev/null; then
    return 0
  fi

  # Get commits ahead of staging
  local ahead
  ahead="$(git -C "$project_dir" log --oneline "staging..$branch" 2>/dev/null)" || return 0

  if [[ -z "$ahead" ]]; then
    return 0
  fi

  printf 'Prior work on branch %s:\n%s' "$branch" "$ahead"
}

# --- Summary ---

# Print execution summary: counts and log directory.
print_summary() {
  local succeeded=0 failed=0 skipped=0

  for tid in "${!_TASK_STATUS[@]}"; do
    case "${_TASK_STATUS[$tid]}" in
      success) succeeded=$(( succeeded + 1 )) ;;
      failure) failed=$(( failed + 1 )) ;;
      skipped) skipped=$(( skipped + 1 )) ;;
    esac
  done

  printf '\n' >&2
  log_info "============================================"
  log_info "Pipeline Summary"
  log_info "============================================"
  log_success "$succeeded succeeded"
  if [[ "$failed" -gt 0 ]]; then
    log_error "$failed failed"
  fi
  if [[ "$skipped" -gt 0 ]]; then
    log_warn "$skipped skipped"
  fi
  if [[ -n "${FACTORY_LOG_DIR:-}" ]]; then
    log_info "Logs: $FACTORY_LOG_DIR"
  fi
  log_info "============================================"
  printf '\n' >&2
}

# --- Issue management ---

# Close the issue with a comment listing all PR URLs.
# Called when all tasks succeeded.
_close_issue_success() {
  local issue_number="$1"
  local repo_url="$2"

  local comment="## Pipeline Complete\n\nAll tasks succeeded. PRs:\n\n"
  for tid in "${!_TASK_PR_URL[@]}"; do
    comment+="- **${tid}**: ${_TASK_PR_URL[$tid]}\n"
  done

  gh issue comment "$issue_number" \
    -R "$repo_url" \
    --body "$(printf "$comment")" 2>/dev/null || {
    log_warn "Failed to post success comment on issue #$issue_number"
  }

  gh issue close "$issue_number" \
    -R "$repo_url" 2>/dev/null || {
    log_warn "Failed to close issue #$issue_number"
  }

  log_success "Issue #$issue_number closed"
}

# Comment per-task breakdown on the issue; leave it open.
# Called when any tasks failed or were skipped.
_comment_issue_partial() {
  local issue_number="$1"
  local repo_url="$2"

  local comment="## Pipeline Partial Completion\n\nPer-task breakdown:\n\n"
  for tid in "${!_TASK_STATUS[@]}"; do
    local status="${_TASK_STATUS[$tid]}"
    local pr="${_TASK_PR_URL[$tid]:-none}"
    local icon="?"
    case "$status" in
      success) icon="+" ;;
      failure) icon="x" ;;
      skipped) icon="-" ;;
    esac
    comment+="- [${icon}] **${tid}**: ${status}"
    if [[ "$pr" != "none" ]]; then
      comment+=" — ${pr}"
    fi
    comment+="\n"
  done

  gh issue comment "$issue_number" \
    -R "$repo_url" \
    --body "$(printf "$comment")" 2>/dev/null || {
    log_warn "Failed to post partial-completion comment on issue #$issue_number"
  }

  log_info "Issue #$issue_number left open (partial completion)"
}

# Route to success or partial issue management.
manage_issue() {
  if [[ -z "${ISSUE_NUMBER:-}" ]]; then
    return 0
  fi

  local repo_url
  repo_url="$(git -C "$PROJECT_DIR" remote get-url origin)" || return 0

  # Check if all tasks succeeded
  local all_ok=1
  for tid in "${!_TASK_STATUS[@]}"; do
    if [[ "${_TASK_STATUS[$tid]}" != "success" ]]; then
      all_ok=0
      break
    fi
  done

  if [[ "$all_ok" -eq 1 ]]; then
    _close_issue_success "$ISSUE_NUMBER" "$repo_url"
  else
    _comment_issue_partial "$ISSUE_NUMBER" "$repo_url"
  fi
}

# --- PR merge waiting ---

# Wait for all task PRs to merge. Returns 0 when all merged, 1 on timeout.
wait_for_all_pr_merges() {
  if [[ ${#_TASK_PR_URL[@]} -eq 0 ]]; then
    log_info "No PRs to wait for"
    return 0
  fi

  log_info "Waiting for all PRs to merge (timeout: ${COMPLETION_PR_MERGE_TIMEOUT}s)"

  local all_merged=1

  for tid in "${!_TASK_PR_URL[@]}"; do
    local pr_url="${_TASK_PR_URL[$tid]}"
    [[ -z "$pr_url" ]] && continue

    local pr_state
    pr_state="$(gh pr view "$pr_url" --json state --jq '.state' 2>/dev/null)" || {
      log_warn "Could not check PR state for $tid"
      all_merged=0
      continue
    }

    if [[ "$pr_state" == "MERGED" ]]; then
      continue
    fi

    # Poll until merged or timeout
    local waited=0
    while [[ "$waited" -lt "$COMPLETION_PR_MERGE_TIMEOUT" ]]; do
      sleep "$COMPLETION_PR_POLL_INTERVAL"
      waited=$(( waited + COMPLETION_PR_POLL_INTERVAL ))

      pr_state="$(gh pr view "$pr_url" --json state --jq '.state' 2>/dev/null)" || {
        log_warn "PR state check failed for $tid — retrying"
        continue
      }

      if [[ "$pr_state" == "MERGED" ]]; then
        log_success "PR merged: $tid"
        break
      fi

      if [[ "$pr_state" == "CLOSED" ]]; then
        log_error "PR closed without merge: $tid"
        all_merged=0
        break
      fi

      log_info "Waiting for $tid PR to merge (${waited}s / ${COMPLETION_PR_MERGE_TIMEOUT}s)"
    done

    if [[ "$pr_state" != "MERGED" && "$pr_state" != "CLOSED" ]]; then
      log_error "Timeout waiting for $tid PR to merge"
      all_merged=0
    fi
  done

  if [[ "$all_merged" -eq 0 ]]; then
    return 1
  fi

  log_success "All PRs merged"
  return 0
}

# --- Post-merge cleanup ---

# Delete local and remote feature branches for completed tasks.
cleanup_branches() {
  for tid in "${!_TASK_STATUS[@]}"; do
    local branch="feat/${tid}"

    # Only clean up branches for successfully merged tasks
    if [[ "${_TASK_STATUS[$tid]}" != "success" ]]; then
      continue
    fi

    # Delete local branch
    git -C "$PROJECT_DIR" branch -d "$branch" 2>/dev/null || {
      log_warn "Could not delete local branch $branch"
    }

    # Delete remote branch
    git -C "$PROJECT_DIR" push --delete origin "$branch" 2>/dev/null || {
      log_warn "Could not delete remote branch $branch"
    }
  done
}

# Remove spec directory and commit the removal to staging.
cleanup_spec() {
  local spec_dir="$1"

  if [[ ! -d "${PROJECT_DIR}/${spec_dir}" ]]; then
    return 0
  fi

  git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || return 0

  git -C "$PROJECT_DIR" rm -r "$spec_dir" --quiet 2>/dev/null || {
    log_warn "Could not git rm spec dir: $spec_dir"
    return 0
  }

  git -C "$PROJECT_DIR" commit -m "chore: remove spec directory ${spec_dir}" --quiet 2>/dev/null || {
    log_warn "Spec removal commit failed"
  }

  log_success "Spec directory removed and committed"
}

# Clean up log directory after fully successful completion.
cleanup_logs() {
  if [[ -n "${FACTORY_LOG_DIR:-}" && -d "$FACTORY_LOG_DIR" ]]; then
    rm -rf "$FACTORY_LOG_DIR"
    log_info "Log directory cleaned up"
  fi
}

# --- Orchestrator integration: write status/PR after each task ---

# Flush task statuses and PR mappings to log files.
# Called after execute_tasks() returns.
flush_task_logs() {
  if [[ -z "${FACTORY_LOG_DIR:-}" ]]; then
    return 0
  fi

  for tid in "${!_TASK_STATUS[@]}"; do
    local status="${_TASK_STATUS[$tid]}"
    case "$status" in
      success) write_status "$tid" "ok" ;;
      failure) write_status "$tid" "failed" ;;
      skipped) write_status "$tid" "skipped" ;;
    esac
  done

  for tid in "${!_TASK_PR_URL[@]}"; do
    local pr_url="${_TASK_PR_URL[$tid]}"
    # Extract PR number from URL (last path segment)
    local pr_number
    pr_number="$(printf '%s' "$pr_url" | grep -oE '[0-9]+$')" || continue
    write_pr_map "$tid" "$pr_number"
  done
}

# --- Full completion flow ---

# Run the full completion sequence:
# 1. Print summary
# 2. Flush logs
# 3. Manage issue
# 4. Wait for merges (if all succeeded)
# 5. Cleanup branches, spec, logs (if all merged)
run_completion() {
  local spec_dir="${1:-}"

  print_summary
  flush_task_logs

  manage_issue

  # Check if all tasks succeeded
  local all_ok=1
  for tid in "${!_TASK_STATUS[@]}"; do
    if [[ "${_TASK_STATUS[$tid]}" != "success" ]]; then
      all_ok=0
      break
    fi
  done

  if [[ "$all_ok" -eq 0 ]]; then
    log_warn "Not all tasks succeeded — skipping merge wait and cleanup"
    return 1
  fi

  # Wait for all PRs to merge
  if ! wait_for_all_pr_merges; then
    log_warn "Not all PRs merged — skipping cleanup"
    return 1
  fi

  # Post-merge cleanup
  cleanup_branches

  if [[ -n "$spec_dir" ]]; then
    cleanup_spec "$spec_dir"
  fi

  cleanup_logs

  log_success "Pipeline complete"
  return 0
}
