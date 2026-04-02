#!/usr/bin/env bash
set -euo pipefail

# Deploy factory-owned config files to a target project.
# Never overwrites existing files.

# Deploy a single file if it doesn't already exist at the destination.
# Appends to _DEPLOYED_CONFIGS on deploy, silent otherwise.
_deploy_if_missing() {
  local src="$1"
  local dest="$2"
  local dest_dir
  dest_dir="$(dirname "$dest")"

  if [[ ! -f "$src" ]]; then
    log_warn "Source file not found: $src (skipping)"
    return 0
  fi

  [[ -f "$dest" ]] && return 0

  mkdir -p "$dest_dir"
  cp "$src" "$dest"
  _DEPLOYED_CONFIGS+=("$dest")
}

# Ensure packages are in devDependencies. Skips already-present packages.
# Usage: _ensure_devdeps <project_dir> <pkg1> [pkg2 ...]
_ensure_devdeps() {
  local project_dir="$1"; shift
  local missing=()

  for pkg in "$@"; do
    if ! jq -e --arg p "$pkg" '.devDependencies[$p] // empty' "$project_dir/package.json" &>/dev/null; then
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  log_info "Installing missing devDependencies: ${missing[*]}"
  (cd "$project_dir" && pnpm add -D "${missing[@]}") || {
    log_warn "Failed to install: ${missing[*]}"
    return 1
  }
}

# Deploy factory configs to a target project.
# - quality-gate.yml  → always (if missing)
# - .stryker.config.json  → only if package.json present and file missing
# - .dependency-cruiser.cjs → only if package.json present and file missing
# Only logs files that were actually deployed; single summary line if all present.
deploy_factory_configs() {
  local project_dir="$1"
  _DEPLOYED_CONFIGS=()

  # CI workflow — always deploy if missing
  _deploy_if_missing \
    "$FACTORY_DIR/templates/quality-gate.yml" \
    "$project_dir/.github/workflows/quality-gate.yml"

  # Node-specific configs — only when target has package.json
  if [[ -f "$project_dir/package.json" ]]; then
    _deploy_if_missing \
      "$FACTORY_DIR/templates/.stryker.config.json" \
      "$project_dir/.stryker.config.json"

    _deploy_if_missing \
      "$FACTORY_DIR/templates/.dependency-cruiser.cjs" \
      "$project_dir/.dependency-cruiser.cjs"

    # Ensure packages required by deployed configs are installed
    _ensure_devdeps "$project_dir" \
      "@stryker-mutator/core" \
      "@stryker-mutator/vitest-runner" \
      "@stryker-mutator/typescript-checker"

    _ensure_devdeps "$project_dir" \
      "dependency-cruiser"
  fi

  if [[ ${#_DEPLOYED_CONFIGS[@]} -eq 0 ]]; then
    log_info "All factory configs present"
  else
    for f in "${_DEPLOYED_CONFIGS[@]}"; do
      log_success "Deployed: $f"
    done
  fi

  _ensure_gitignore_entries "$project_dir"
}

# Append .claude/settings*.json entries to .gitignore if not already present.
# Prevents Claude Code runtime files from being committed on feature branches.
_ensure_gitignore_entries() {
  local project_dir="$1"
  local gitignore="$project_dir/.gitignore"
  local entries=(
    ".claude/settings.json"
    ".claude/settings.autonomous.json"
  )
  [[ -f "$gitignore" ]] || return 0
  for entry in "${entries[@]}"; do
    grep -qF "$entry" "$gitignore" || printf '\n%s\n' "$entry" >> "$gitignore"
  done
}
