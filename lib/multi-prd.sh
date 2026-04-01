#!/usr/bin/env bash
set -euo pipefail

# Multi-PRD discovery and dispatch.
# Finds open PRD issues, offers sequential/parallel execution,
# and manages worktree-based parallel runs.

# --- Discovery ---

# Fetch open issues with [PRD] in the title.
# Populates _PRD_NUMBERS and _PRD_TITLES arrays.
_discover_prd_issues() {
  local repo_url
  repo_url="$(git -C "$PROJECT_DIR" remote get-url origin)"
  local nwo
  nwo="$(printf '%s' "$repo_url" | sed -E 's#(https://github\.com/|git@github\.com:)##' | sed 's/\.git$//')"

  log_info "Searching for open PRD issues in $nwo"

  local raw
  raw="$(gh issue list \
    --repo "$nwo" \
    --search "[PRD] in:title" \
    --state open \
    --json number,title \
    --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null)" || {
    log_error "Failed to fetch issues from GitHub"
    return 1
  }

  _PRD_NUMBERS=()
  _PRD_TITLES=()

  while IFS=$'\t' read -r num title; do
    [[ -z "$num" ]] && continue
    _PRD_NUMBERS+=("$num")
    _PRD_TITLES+=("$title")
  done <<< "$raw"
}

# --- Sequential execution ---

# Process PRDs one at a time through the standard pipeline.
sequential_execution() {
  local numbers=("$@")
  local total="${#numbers[@]}"
  local i=0
  local failed=0

  for issue_number in "${numbers[@]}"; do
    i=$((i + 1))
    log_info "Processing PRD $i/$total: issue #$issue_number"

    local rc=0
    "$FACTORY_DIR/run-factory.sh" "$PROJECT_DIR" --issue "$issue_number" --skip-lock || rc=$?

    if [[ "$rc" -eq 0 ]]; then
      log_success "PRD #$issue_number completed"
    else
      log_error "PRD #$issue_number failed (exit $rc)"
      failed=$(( failed + 1 ))
    fi
  done

  if [[ "$failed" -gt 0 ]]; then
    log_error "$failed/$total PRDs failed"
    return 1
  fi
}

# --- Parallel (worktree) execution ---

# Process PRDs in parallel, each in its own git worktree.
parallel_worktree_execution() {
  local numbers=("${!1}")
  local titles=("${!2}")
  local total="${#numbers[@]}"

  # --- Parent setup: staging branch + factory configs ---

  setup_staging
  reconcile_staging_with_develop

  deploy_factory_configs "$PROJECT_DIR"

  # --- Create worktrees and spawn workers ---

  local worktree_base="$PROJECT_DIR/.worktrees"
  mkdir -p "$worktree_base"

  local worker_pids=()
  local worker_issues=()
  local worker_paths=()

  # Trap to kill workers on interrupt, then re-raise for parent cleanup
  # shellcheck disable=SC2329 # invoked via trap on line 107
  _worker_cleanup() {
    local sig="$1"
    log_warn "Interrupt received — terminating workers"
    for pid in "${worker_pids[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    # Re-raise signal so parent EXIT trap fires
    trap - "$sig"
    kill -s "$sig" "$$"
  }
  trap '_worker_cleanup INT' INT
  trap '_worker_cleanup TERM' TERM

  for i in "${!numbers[@]}"; do
    local issue_number="${numbers[$i]}"
    local title="${titles[$i]}"
    local slug
    slug="$(slugify_title "$title")"
    local worktree_path="$worktree_base/$slug"

    log_info "Creating worktree for #$issue_number: $worktree_path"

    # Remove existing worktree if leftover from a previous run
    if [[ -d "$worktree_path" ]]; then
      log_warn "Removing stale worktree: $worktree_path"
      git -C "$PROJECT_DIR" worktree remove "$worktree_path" --force 2>/dev/null || rm -rf "$worktree_path"
    fi

    git -C "$PROJECT_DIR" worktree add "$worktree_path" staging --quiet

    "$FACTORY_DIR/run-factory.sh" "$worktree_path" --issue "$issue_number" &
    worker_pids+=($!)
    worker_issues+=("$issue_number")
    worker_paths+=("$worktree_path")
  done

  log_info "Spawned $total workers — waiting for completion"

  # --- Wait for all workers, track results ---

  local failed_paths=()

  for i in "${!worker_pids[@]}"; do
    local pid="${worker_pids[$i]}"
    local issue_number="${worker_issues[$i]}"
    local worktree_path="${worker_paths[$i]}"

    if wait "$pid"; then
      log_success "PRD #$issue_number completed — removing worktree"
      git -C "$PROJECT_DIR" worktree remove "$worktree_path" --force 2>/dev/null || true
    else
      log_error "PRD #$issue_number failed"
      log_error "  Worktree preserved: $worktree_path"
      log_error "  Cleanup: git -C \"$PROJECT_DIR\" worktree remove \"$worktree_path\" --force"
      failed_paths+=("$worktree_path")
    fi
  done

  # Prune stale worktree metadata
  git -C "$PROJECT_DIR" worktree prune 2>/dev/null || true

  # Restore parent's cleanup trap
  trap cleanup INT TERM

  if [[ ${#failed_paths[@]} -gt 0 ]]; then
    log_warn "${#failed_paths[@]}/$total PRDs failed — worktrees preserved on disk"
    return 1
  fi

  log_success "All $total PRDs completed successfully"
}

# --- Public interface ---

# Discover open PRD issues and dispatch for processing.
discover_and_process_prds() {
  _discover_prd_issues

  local count="${#_PRD_NUMBERS[@]}"

  if [[ "$count" -eq 0 ]]; then
    log_info "No open PRD issues found"
    return 0
  fi

  # Display discovered PRDs
  log_info "Found $count open PRD issue(s):"
  for i in "${!_PRD_NUMBERS[@]}"; do
    log_info "  #${_PRD_NUMBERS[$i]}  ${_PRD_TITLES[$i]}"
  done

  # Single PRD — process directly
  if [[ "$count" -eq 1 ]]; then
    log_info "Single PRD found — proceeding directly"
    sequential_execution "${_PRD_NUMBERS[@]}"
    return $?
  fi

  # Multiple PRDs — prompt user
  printf '\n' >&2
  log_info "Choose execution strategy:"
  log_info "  [s] Sequential — one at a time (safer, uses less resources)"
  log_info "  [p] Parallel   — each PRD in its own worktree (faster)"
  printf '\n' >&2

  local choice
  while true; do
    read -rp "  Enter choice (s/p): " choice
    case "$choice" in
      s|S)
        log_info "Starting sequential execution"
        sequential_execution "${_PRD_NUMBERS[@]}"
        return $?
        ;;
      p|P)
        log_info "Starting parallel worktree execution"
        parallel_worktree_execution _PRD_NUMBERS[@] _PRD_TITLES[@]
        return $?
        ;;
      *)
        log_warn "Invalid choice — enter 's' or 'p'"
        ;;
    esac
  done
}
