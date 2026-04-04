#!/usr/bin/env bash
set -euo pipefail

# Branch management for the develop/staging branching model.
# All git operations target PROJECT_DIR (not the factory repo).
#
# Prerequisite: repo admin access required for branch protection via gh CLI.

# --- Branch setup ---

# Create develop and staging branches if they don't exist.
# develop is created from main; staging from develop (or main if no develop).
setup_staging() {
  log_info "Setting up branches in $PROJECT_DIR"

  # Fetch latest refs
  git -C "$PROJECT_DIR" fetch --quiet origin

  # Create develop from main if it doesn't exist
  if ! git -C "$PROJECT_DIR" rev-parse --verify develop &>/dev/null; then
    log_info "Creating develop branch from main"
    git -C "$PROJECT_DIR" branch develop main
  fi

  # Create staging from develop (falls back to main if develop still missing)
  if ! git -C "$PROJECT_DIR" rev-parse --verify staging &>/dev/null; then
    local base="develop"
    if ! git -C "$PROJECT_DIR" rev-parse --verify develop &>/dev/null; then
      base="main"
      log_warn "develop branch not found; creating staging from main"
    fi
    log_info "Creating staging branch from $base"
    git -C "$PROJECT_DIR" branch staging "$base"
    git -C "$PROJECT_DIR" push -u origin staging --quiet || log_warn "Failed to push staging to remote"
  fi

  log_success "Branches ready (develop + staging)"
}

# --- Branch reconciliation ---

# Fast-forward staging to match develop; falls back to merge.
# Aborts cleanly on merge conflicts — no dirty repo state left.
reconcile_staging_with_develop() {
  log_info "Reconciling staging with develop"

  # Remember current branch to restore later
  local original_branch
  original_branch="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)"

  # Abort if working tree is dirty (same guard as safe_checkout_staging)
  if ! git -C "$PROJECT_DIR" diff --quiet || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
    log_error "Working tree is dirty — commit or stash changes before running the pipeline"
    return 1
  fi

  git -C "$PROJECT_DIR" checkout staging --quiet

  # Sync with remote staging first (picks up merged PRs)
  git -C "$PROJECT_DIR" merge --ff-only origin/staging --quiet 2>/dev/null \
    || log_warn "Could not fast-forward local staging from origin/staging — may have diverged"

  # Check if staging already contains all of develop's commits
  if git -C "$PROJECT_DIR" merge-base --is-ancestor develop staging; then
    if [[ "$(git -C "$PROJECT_DIR" rev-parse develop)" == "$(git -C "$PROJECT_DIR" rev-parse staging)" ]]; then
      log_success "Staging already up to date with develop"
    else
      log_success "Staging already ahead of develop"
    fi
    git -C "$PROJECT_DIR" checkout "$original_branch" --quiet
    return 0
  fi

  # Try fast-forward first
  if git -C "$PROJECT_DIR" merge --ff-only develop &>/dev/null; then
    log_success "Staging fast-forwarded to develop"
    git -C "$PROJECT_DIR" checkout "$original_branch" --quiet
    return 0
  fi

  # Fall back to merge
  log_info "Fast-forward not possible; attempting merge"
  if ! git -C "$PROJECT_DIR" merge develop --no-edit 2>/dev/null; then
    log_error "Merge conflict: staging ← develop"
    git -C "$PROJECT_DIR" merge --abort 2>/dev/null || true
    git -C "$PROJECT_DIR" checkout "$original_branch" --quiet 2>/dev/null || true
    log_error "Conflict between staging and develop — resolve manually"
    return 1
  fi

  log_success "Staging merged with develop"
  git -C "$PROJECT_DIR" checkout "$original_branch" --quiet
  return 0
}

# --- Safe checkout ---

# Switch to staging branch, ensuring a clean working tree.
safe_checkout_staging() {
  local current
  current="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)"

  if [[ "$current" == "staging" ]]; then
    log_info "Already on staging"
    return 0
  fi

  # Abort if working tree is dirty
  if ! git -C "$PROJECT_DIR" diff --quiet || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
    log_error "Working tree is dirty — commit or stash changes before switching to staging"
    return 1
  fi

  git -C "$PROJECT_DIR" checkout staging --quiet
  log_info "Switched to staging"
}

# --- Branch protection ---

# Set branch protection on staging via gh CLI.
# Requires repo admin access.
setup_branch_protection() {
  local repo_url
  repo_url="$(git -C "$PROJECT_DIR" remote get-url origin)"

  # Extract owner/repo from URL (handles https and ssh)
  local nwo
  nwo="$(printf '%s' "$repo_url" | sed -E 's#(https://github\.com/|git@github\.com:)##' | sed 's/\.git$//')"

  log_info "Setting branch protection on staging ($nwo)"

  # Require Quality Gate workflow checks to pass.
  # Check names must match the `name:` field of each job in quality-gate.yml.
  gh api -X PUT "repos/${nwo}/branches/staging/protection" \
    --input - <<'PROTECTION' || {
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["Quality", "Mutation Testing", "Security Scan"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
PROTECTION
    log_warn "Branch protection setup failed — requires repo admin access"
    return 0
  }

  log_success "Branch protection set on staging"
}

# --- Config commit ---

# Commit factory-deployed configs to staging (idempotent — no-op if clean).
commit_deployed_configs() {
  git -C "$PROJECT_DIR" add -A

  if git -C "$PROJECT_DIR" diff --cached --quiet; then
    log_info "No new factory configs to commit"
    return 0
  fi

  git -C "$PROJECT_DIR" commit -m "chore: deploy factory configs" --quiet
  log_success "Factory configs committed to staging"
}

# --- Spec commit ---

# Commit the spec directory to staging before task execution.
commit_spec_to_staging() {
  local spec_dir="$1"

  safe_checkout_staging || return 1

  # Stage spec directory
  git -C "$PROJECT_DIR" add "$spec_dir"

  # Only commit if there are staged changes
  if git -C "$PROJECT_DIR" diff --cached --quiet; then
    log_info "Spec directory already committed to staging"
    return 0
  fi

  git -C "$PROJECT_DIR" commit -m "chore: add spec directory ${spec_dir}" --quiet
  log_success "Spec directory committed to staging"
}
