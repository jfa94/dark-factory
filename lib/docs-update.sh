#!/usr/bin/env bash
set -euo pipefail

# Documentation update: invokes Claude to update /docs and write ADR(s)
# after a successful pipeline run.

# --- Defaults ---

DOCS_MAX_TURNS="${DOCS_MAX_TURNS:-120}"
DOCS_MAX_DIFF_LINES="${DOCS_MAX_DIFF_LINES:-8000}"

# --- Internal helpers ---

# Read the last-documented commit hash from docs/README.md.
# Expects: <!-- last-documented: <sha> --> on line 1.
# Outputs the hash, or empty string if not found.
_get_last_documented_commit() {
  local docs_readme="${PROJECT_DIR}/docs/README.md"

  if [[ ! -f "$docs_readme" ]]; then
    return 0
  fi

  local marker
  marker="$(head -1 "$docs_readme" | grep -oE 'last-documented: [a-f0-9]+' | cut -d' ' -f2)" || true
  printf '%s' "$marker"
}

# Build the docs-update prompt and write to a temp file.
# Returns the temp file path via stdout.
_build_docs_prompt() {
  local spec_dir="$1"
  local prompt_file
  prompt_file="$(factory_mktemp)"

  # --- Gather context ---

  # Last-documented commit
  local last_commit
  last_commit="$(_get_last_documented_commit)"

  # Git diff since last-documented (or staging if marker missing)
  local diff_base="${last_commit:-staging}"
  local git_diff
  git_diff="$(git -C "$PROJECT_DIR" diff "${diff_base}..HEAD" -- \
    ':!*.lock' ':!*.snap' ':!dist/' ':!build/' ':!coverage/' \
    2>/dev/null | head -n "$DOCS_MAX_DIFF_LINES")" || git_diff=""

  local diff_truncated=""
  local actual_lines
  actual_lines="$(git -C "$PROJECT_DIR" diff "${diff_base}..HEAD" -- \
    ':!*.lock' ':!*.snap' ':!dist/' ':!build/' ':!coverage/' \
    2>/dev/null | wc -l | tr -d ' ')" || actual_lines="0"
  if [[ "$actual_lines" -gt "$DOCS_MAX_DIFF_LINES" ]]; then
    diff_truncated="(truncated — showing first ${DOCS_MAX_DIFF_LINES} of ${actual_lines} lines)"
  fi

  # Current HEAD sha (for updating the marker)
  local head_sha
  head_sha="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)" || head_sha=""

  # Spec directory contents
  local spec_abs="${PROJECT_DIR}/${spec_dir}"
  local spec_contents=""
  if [[ -d "$spec_abs" ]]; then
    # Read tasks.json and any .md files in the spec dir
    for f in "${spec_abs}"/*.md "${spec_abs}/tasks.json"; do
      [[ -f "$f" ]] || continue
      local fname
      fname="$(basename "$f")"
      spec_contents+="### ${spec_dir}/${fname}\n\n\`\`\`\n$(cat "$f")\n\`\`\`\n\n"
    done
  fi

  # PRD from GitHub issue (optional — only in --issue mode)
  local prd_section=""
  if [[ -n "${ISSUE_NUMBER:-}" ]]; then
    local repo_url
    repo_url="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null)" || repo_url=""
    if [[ -n "$repo_url" ]]; then
      local prd_title prd_body
      prd_title="$(gh issue view "$ISSUE_NUMBER" -R "$repo_url" --json title --jq '.title' 2>/dev/null)" || prd_title=""
      prd_body="$(gh issue view "$ISSUE_NUMBER" -R "$repo_url" --json body --jq '.body' 2>/dev/null)" || prd_body=""
      if [[ -n "$prd_title" || -n "$prd_body" ]]; then
        prd_section="## PRD (GitHub Issue #${ISSUE_NUMBER})

**Title:** ${prd_title}

${prd_body}

"
      fi
    fi
  fi

  # Existing docs/decisions directory — find highest ADR number for sequencing
  local next_adr_num=1
  local decisions_dir="${PROJECT_DIR}/docs/decisions"
  if [[ -d "$decisions_dir" ]]; then
    local max_num
    max_num="$(find "$decisions_dir" -maxdepth 1 -name '[0-9]*.md' -printf '%f\n' 2>/dev/null \
      | grep -oE '^[0-9]+' | sort -n | tail -1)" || max_num=""
    if [[ -n "$max_num" ]]; then
      next_adr_num=$(( max_num + 1 ))
    fi
  fi

  cat > "$prompt_file" <<PROMPT
You are updating the documentation for this project after a successful feature implementation.
Run in fully automated (headless) mode — there is no user to interact with.

## Your Tasks

1. **Update existing docs** in \`/docs\` to accurately reflect the newly implemented feature.
   - Update any pages that describe functionality, architecture, or configuration that changed
   - Do not remove existing content unless it is now incorrect
   - Add new sections/pages only if the feature introduces something not documented anywhere

2. **Write ADR(s)** in \`docs/decisions/\`
   - Create one ADR per significant architectural decision made during this feature
   - Name files with a zero-padded sequence number starting at ${next_adr_num} (e.g., \`$(printf '%03d' "$next_adr_num")-short-title.md\`)
   - Use this format for each ADR:
     \`\`\`markdown
     # ADR-NNN: Title

     **Status:** Accepted
     **Date:** $(date +%Y-%m-%d)

     ## Context
     (what problem or situation required a decision)

     ## Decision
     (what was decided and why)

     ## Consequences
     (trade-offs, follow-up work, risks)
     \`\`\`
   - Only write ADRs for decisions that are genuinely architectural (e.g., chosen approach for data modeling, API design, choice of library, important trade-off). Skip trivial implementation details.

3. **Update the last-documented marker** in \`docs/README.md\` line 1:
   - Change \`<!-- last-documented: ${last_commit:-<old-sha>} -->\` to \`<!-- last-documented: ${head_sha} -->\`
   - If the file doesn't have this marker yet, add it as line 1

## Context

${prd_section}## Spec and Tasks

$(printf '%b' "$spec_contents")
## Code Changes (diff from ${diff_base} to HEAD)
${diff_truncated}

\`\`\`diff
${git_diff}
\`\`\`
PROMPT

  printf '%s' "$prompt_file"
}

# --- Public interface ---

# Update the target project's /docs directory and write ADR(s).
# Called after all PRs merge, before cleanup.
# Usage: update_project_docs <spec_dir>
# Non-fatal: logs a warning on failure, does not abort the pipeline.
update_project_docs() {
  local spec_dir="${1:-}"

  log_header "Documentation Update"

  local prompt_file
  prompt_file="$(_build_docs_prompt "$spec_dir")"

  local output_file
  output_file="$(factory_mktemp)"

  local -a args=(claude --print --max-turns "$DOCS_MAX_TURNS")
  args+=(--settings "$FACTORY_SETTINGS")
  local prompt_content
  prompt_content="$(cat "$prompt_file")"
  rm -f "$prompt_file"
  args+=(-p "$prompt_content")

  log_info "Invoking Claude to update docs..."

  local rc=0
  (cd "$PROJECT_DIR" && "${args[@]}") < /dev/null > "$output_file" 2>&1 &
  register_bg_pid $!
  spin $!
  rc=$?

  rm -f "$output_file"

  if [[ "$rc" -ne 0 ]]; then
    log_warn "Docs update failed (exit $rc) — skipping (non-fatal)"
    return 0
  fi

  # Check if any docs changes were made
  if git -C "$PROJECT_DIR" diff --quiet HEAD 2>/dev/null && \
     git -C "$PROJECT_DIR" diff --cached --quiet 2>/dev/null; then
    log_warn "Docs update: no changes detected"
    return 0
  fi

  # Commit docs changes to staging
  git -C "$PROJECT_DIR" checkout staging --quiet 2>/dev/null || {
    log_warn "Docs update: could not checkout staging — skipping commit"
    return 0
  }

  git -C "$PROJECT_DIR" add -A -- 'docs/' 2>/dev/null || true

  if git -C "$PROJECT_DIR" diff --cached --quiet 2>/dev/null; then
    log_info "Docs update: nothing to commit"
    return 0
  fi

  git -C "$PROJECT_DIR" commit \
    -m "docs: update documentation and write ADR(s)" \
    --quiet 2>/dev/null || {
    log_warn "Docs update: commit failed — changes left unstaged"
    return 0
  }

  log_success "Documentation updated and committed to staging"
}
