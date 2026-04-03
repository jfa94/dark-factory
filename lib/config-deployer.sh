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

# Deploy factory configs to a target project.
# - quality-gate.yml  → always (if missing)
# - .stryker.config.json  → only if package.json present and file missing
# - .dependency-cruiser.cjs → only if package.json present and file missing
# - package.scaffold.json → merged into package.json (scripts + devDeps) if package.json present
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

    # Merge scaffold scripts + devDependencies into package.json (skip if already up to date)
    local scaffold="$FACTORY_DIR/templates/package.scaffold.json"
    if [[ -f "$scaffold" ]]; then
      local _merge_result
      _merge_result="$(TARGET_PATH="$project_dir" SCAFFOLD_PATH="$FACTORY_DIR/templates" node -e "
        const fs = require('fs');
        const raw = fs.readFileSync(process.env.TARGET_PATH + '/package.json', 'utf8');
        const pkg = JSON.parse(raw);
        const scaffold = JSON.parse(fs.readFileSync(process.env.SCAFFOLD_PATH + '/package.scaffold.json', 'utf8'));
        const merged = JSON.parse(JSON.stringify(pkg));
        merged.scripts = Object.assign({}, merged.scripts || {}, scaffold.scripts);
        merged.devDependencies = Object.assign({}, merged.devDependencies || {}, scaffold.devDependencies);
        const updated = JSON.stringify(merged, null, 2) + '\n';
        if (updated === raw) { process.stdout.write('noop'); }
        else { fs.writeFileSync(process.env.TARGET_PATH + '/package.json', updated); process.stdout.write('changed'); }
      ")"
      if [[ "$_merge_result" == "changed" ]]; then
        _DEPLOYED_CONFIGS+=("$project_dir/package.json (scaffold merge)")
      fi
    fi
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

# Append required entries to .gitignore if not already present.
# Prevents Claude Code runtime files and tooling artifacts from being committed on feature branches.
_ensure_gitignore_entries() {
  local project_dir="$1"
  local gitignore="$project_dir/.gitignore"
  local entries=(
    ".claude/settings.json"
    ".claude/settings.autonomous.json"
    ".stryker-tmp/"
    "claude-progress.json"
    "feature-status.json"
  )
  [[ -f "$gitignore" ]] || return 0
  for entry in "${entries[@]}"; do
    grep -qF "$entry" "$gitignore" || printf '\n%s\n' "$entry" >> "$gitignore"
  done
}
