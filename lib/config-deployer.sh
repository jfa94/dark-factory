#!/usr/bin/env bash
set -euo pipefail

# Deploy factory-owned config files to a target project.
# Never overwrites existing files.

# Deploy a single file if it doesn't already exist at the destination.
_deploy_if_missing() {
  local src="$1"
  local dest="$2"
  local dest_dir
  dest_dir="$(dirname "$dest")"

  if [[ ! -f "$src" ]]; then
    log_warn "Source file not found: $src (skipping)"
    return 0
  fi

  if [[ -f "$dest" ]]; then
    log_info "Skipping (exists): $dest"
    return 0
  fi

  mkdir -p "$dest_dir"
  cp "$src" "$dest"
  log_success "Deployed: $dest"
}

# Deploy factory configs to a target project.
# - quality-gate.yml  → always (if missing)
# - .stryker.config.json  → only if package.json present and file missing
# - .dependency-cruiser.cjs → only if package.json present and file missing
deploy_factory_configs() {
  local project_dir="$1"

  log_info "Deploying factory configs to $project_dir"

  # CI workflow — always deploy if missing
  _deploy_if_missing \
    "$FACTORY_DIR/quality-gate.yml" \
    "$project_dir/.github/workflows/quality-gate.yml"

  # Node-specific configs — only when target has package.json
  if [[ -f "$project_dir/package.json" ]]; then
    _deploy_if_missing \
      "$FACTORY_DIR/.stryker.config.json" \
      "$project_dir/.stryker.config.json"

    _deploy_if_missing \
      "$FACTORY_DIR/.dependency-cruiser.cjs" \
      "$project_dir/.dependency-cruiser.cjs"
  else
    log_info "No package.json; skipping Node-specific configs"
  fi
}
