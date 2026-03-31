#!/usr/bin/env bash
set -euo pipefail

# Validate that a target project has required prerequisites.
# Claude config (settings, skills) can live in the project dir OR ~/.claude/.

validate_project() {
  local dir="$1"
  local home_claude="$HOME/.claude"
  local errors=()

  # --- Hard requirements ---

  [[ -d "$dir" ]] \
    || errors+=("Directory does not exist: $dir")

  if ! git -C "$dir" remote 2>/dev/null | grep -q .; then
    errors+=("No git remote configured")
  fi

  # --- Claude config: project-level OR user-level ---

  local has_project_config=0
  local has_home_config=0

  # Check project-level
  if [[ -f "$dir/.claude/settings.json" ]]; then
    has_project_config=1
  fi

  # Check user-level (home dir)
  if [[ -f "$home_claude/settings.json" ]]; then
    has_home_config=1
  fi

  if [[ "$has_project_config" -eq 0 && "$has_home_config" -eq 0 ]]; then
    errors+=("No Claude settings.json found in $dir/.claude/ or $home_claude/")
  fi

  # Skills check: prd-to-spec must exist in at least one location
  if [[ ! -d "$dir/.claude/skills/prd-to-spec" && ! -d "$home_claude/skills/prd-to-spec" ]]; then
    errors+=("prd-to-spec skill not found in $dir/.claude/skills/ or $home_claude/skills/")
  fi

  # --- Report ---

  if [[ ${#errors[@]} -gt 0 ]]; then
    log_error "Project validation failed for: $dir"
    for err in "${errors[@]}"; do
      log_error "  - $err"
    done
    return 1
  fi

  # Info about which config is in use
  if [[ "$has_project_config" -eq 1 ]]; then
    log_info "Using project-level Claude config ($dir/.claude/)"
  else
    log_info "Using user-level Claude config ($home_claude/)"
  fi
}
