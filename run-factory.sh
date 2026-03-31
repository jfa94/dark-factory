#!/usr/bin/env bash
set -euo pipefail

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
  restore_settings || true
  release_lock || true
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
    generate_and_review_spec
    ;;
  discover)
    log_warn "Discover mode not yet implemented"
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

  # Commit spec directory to staging
  commit_spec_to_staging "$_SPEC_DIR"

  # TODO: Task execution (phase 5)
fi

# TODO: Summary and cleanup (phase 9)
