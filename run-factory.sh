#!/usr/bin/env bash
set -euo pipefail

# --- Bash 4+ required (associative arrays, declare -g) ---

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  printf 'Error: Bash 4+ required (found %s). Install via Homebrew: brew install bash\n' "$BASH_VERSION" >&2
  exit 1
fi

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
  _kill_bg_pids || true
  restore_settings || true
  release_lock || true
  if [[ -n "${FACTORY_TMP_DIR:-}" && -d "$FACTORY_TMP_DIR" ]]; then
    rm -rf "$FACTORY_TMP_DIR"
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

if [[ "$SKIP_SETTINGS_SWAP" -eq 0 ]]; then
  swap_settings "$PROJECT_DIR"
else
  log_info "Skipping settings swap (--skip-settings-swap)"
fi

# --- Mode routing ---

case "$MODE" in
  issue)
    check_usage_and_wait || true
    generate_and_review_spec
    ;;
  discover)
    discover_and_process_prds
    ;;
  spec)
    log_warn "Spec mode not yet implemented"
    ;;
  interactive)
    log_warn "Interactive mode not yet implemented"
    ;;
esac

# --- Repository setup, scaffolding & task validation (after spec is ready) ---

if [[ "$MODE" == "issue" || "$MODE" == "spec" ]]; then
  # Resolve spec directory and tasks file
  if [[ "$MODE" == "issue" ]]; then
    _SLUG="$(slugify_title "$_PRD_TITLE")"
  else
    _SLUG="$SPEC_NAME"
  fi
  _SPEC_DIR="specs/features/${_SLUG}"
  _TASKS_FILE="${PROJECT_DIR}/${_SPEC_DIR}/tasks.json"

  # Initialize log directory
  init_log_dir "$PROJECT_DIR" "$_SLUG"

  # Resume detection
  check_resume "$PROJECT_DIR" "$_SLUG"

  # Branch setup
  setup_staging
  reconcile_staging_with_develop
  setup_branch_protection

  # Scaffolding
  ensure_scaffolding

  # Task validation
  validate_tasks "$_TASKS_FILE"

  # Topological sort — store result for orchestrator
  TASK_ORDER="$(topological_sort "$_TASKS_FILE")"
  export TASK_ORDER

  log_info "Task execution order:"
  printf '%s\n' "$TASK_ORDER" | while IFS= read -r tid; do
    log_info "  - $tid"
  done

  # If resuming, pre-populate skip set and prior PR URLs
  if [[ -n "${RESUME_SKIP_SET:-}" ]]; then
    while IFS= read -r skip_tid; do
      [[ -z "$skip_tid" ]] && continue
      _TASK_STATUS["$skip_tid"]="success"
      log_info "Resume: marking $skip_tid as completed (skipping)"
    done <<< "$RESUME_SKIP_SET"

    # Restore PR mapping from prior run
    if [[ -n "${RESUME_LOG_DIR:-}" && -f "${RESUME_LOG_DIR}/pr-map.log" ]]; then
      _resume_repo_url="$(git -C "$PROJECT_DIR" remote get-url origin)" || true
      _resume_nwo="$(printf '%s' "$_resume_repo_url" | sed -E 's#(https://github\.com/|git@github\.com:)##' | sed 's/\.git$//')"
      while IFS='=' read -r tid pr_num; do
        [[ -z "$tid" ]] && continue
        _TASK_PR_URL["$tid"]="https://github.com/${_resume_nwo}/pull/${pr_num}"
      done < "${RESUME_LOG_DIR}/pr-map.log"
      unset _resume_repo_url _resume_nwo
    fi
  fi

  # Commit spec directory to staging
  commit_spec_to_staging "$_SPEC_DIR"

  # Execute tasks in dependency order
  check_usage_and_wait || true
  execute_tasks || true

  # Completion: summary, issue management, merge wait, cleanup
  run_completion "$_SPEC_DIR"
fi
