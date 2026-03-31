#!/usr/bin/env bash
set -euo pipefail

# Validate that a target project has all required prerequisites.
# Collects all errors before reporting (not fail-fast).
validate_project() {
  local dir="$1"
  local errors=()

  [[ -d "$dir/.claude" ]] \
    || errors+=("Missing .claude/ directory")

  [[ -f "$dir/.claude/CLAUDE.md" ]] \
    || errors+=("Missing .claude/CLAUDE.md")

  [[ -f "$dir/.claude/settings.json" ]] \
    || errors+=("Missing .claude/settings.json")

  [[ -d "$dir/.claude/agents" ]] \
    || errors+=("Missing .claude/agents/ directory")

  [[ -d "$dir/.claude/skills/prd-to-spec" ]] \
    || errors+=("Missing .claude/skills/prd-to-spec/ directory")

  if ! git -C "$dir" remote 2>/dev/null | grep -q .; then
    errors+=("No git remote configured")
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    log_error "Project validation failed for: $dir"
    for err in "${errors[@]}"; do
      log_error "  - $err"
    done
    printf '\n' >&2
    log_info "Run configure.sh to set up missing Claude files"
    return 1
  fi
}
