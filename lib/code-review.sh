#!/usr/bin/env bash
set -euo pipefail

# Code review & PR management: fresh-context review producing
# structured verdicts that drive PR behavior (auto-merge, retry,
# or human-flagged).

# --- Defaults (overridable via environment) ---

ENABLE_CODE_REVIEW="${ENABLE_CODE_REVIEW:-1}"
REVIEW_TURNS="${REVIEW_TURNS:-30}"

# --- Internal helpers ---

# Build the review prompt for a task.
# Writes prompt to a temp file; prints file path to stdout.
# Claude reads the diff itself via tools (Bash/Read/Grep/Glob).
_build_review_prompt() {
  local task_json="$1"
  local branch="$2"
  local is_followup="${3:-0}"
  local prior_findings="${4:-}"

  local prompt_file
  prompt_file="$(factory_mktemp)"

  local task_id title description criteria
  task_id="$(printf '%s' "$task_json" | jq -r '.task_id')"
  title="$(printf '%s' "$task_json" | jq -r '.title')"
  description="$(printf '%s' "$task_json" | jq -r '.description // ""')"
  criteria="$(printf '%s' "$task_json" | jq -r '.acceptance_criteria // [] | .[] | "- " + .')"

  if [[ "$is_followup" -eq 1 ]]; then
    # Verification pass — confirm prior findings were addressed
    cat > "$prompt_file" <<'HEADER'
# Follow-up Code Review (verification pass)

A previous review flagged specific issues. The author has attempted to fix them.
Your job is to:
1. Verify each previously-flagged issue is resolved
2. Flag any NEW critical issues introduced by the fix

Do NOT re-review the entire implementation — focus on the flagged issues and their fixes.
Do NOT flag formatting, naming conventions, or lint violations.

HEADER
    if [[ -n "$prior_findings" ]]; then
      cat >> "$prompt_file" <<FINDINGS
## Previous Review Findings

${prior_findings}

FINDINGS
    fi
  else
    cat > "$prompt_file" <<'HEADER'
# Code Review

Review the changes for this task. Focus on:
- Logic errors and incorrect control flow
- Unhandled edge cases that could cause runtime failures
- Incorrect business logic or misunderstood requirements
- Weak test assertions (tests that pass but don't actually verify behavior)
- AI-specific anti-patterns: hardcoded returns to satisfy tests, silent fallbacks that hide failures, dead code

Do NOT flag:
- Formatting or whitespace
- Naming conventions
- Lint violations (these are caught by automated tooling)

HEADER
  fi

  cat >> "$prompt_file" <<CONTEXT
## Task Context

**Task:** ${title}
**Task ID:** ${task_id}

### Description

${description}

### Acceptance Criteria

${criteria}

## Instructions

Run \`git diff staging...${branch}\` to see what changed. Use Read, Grep, and Glob to inspect
specific files in more detail as needed. Exclude lockfiles and generated files from your review
(pnpm-lock.yaml, package-lock.yaml, yarn.lock, claude-progress.json, feature-status.json,
.claude/tool-audit.jsonl).

## Your Verdict

After reviewing, output exactly one of these verdicts on its own line:

VERDICT: APPROVE
VERDICT: REQUEST_CHANGES
VERDICT: NEEDS_DISCUSSION

If APPROVE: briefly state why the code is acceptable.
If REQUEST_CHANGES: list specific issues that must be fixed (numbered).
If NEEDS_DISCUSSION: explain what needs human judgment and why.
CONTEXT

  printf '%s' "$prompt_file"
}

# Parse verdict from Claude review output.
# Returns: APPROVE, REQUEST_CHANGES, or NEEDS_DISCUSSION.
# Defaults to NEEDS_DISCUSSION if no clean verdict found.
_parse_verdict() {
  local review_output_file="$1"

  local verdict
  verdict="$(grep -oE 'VERDICT:[[:space:]]*(APPROVE|REQUEST_CHANGES|NEEDS_DISCUSSION)' "$review_output_file" | tail -1 | sed 's/VERDICT:[[:space:]]*//' || true)"

  if [[ -z "$verdict" ]]; then
    log_warn "No clean verdict found in review output — defaulting to NEEDS_DISCUSSION"
    verdict="NEEDS_DISCUSSION"
  fi

  printf '%s' "$verdict"
}

# Run the Claude review session in background with spinner.
# Returns: exit code from Claude process.
_invoke_review() {
  local prompt_file="$1"
  local output_file="$2"

  local prompt_content
  prompt_content="$(cat "$prompt_file")"

  local -a args=(claude --print --model sonnet --max-turns "$REVIEW_TURNS")
  args+=(--tools "Bash,Read,Grep,Glob")
  args+=(--settings "$FACTORY_SETTINGS")
  args+=(-p "$prompt_content")

  (cd "$PROJECT_DIR" && "${args[@]}") > "$output_file" 2>&1 &
  register_bg_pid $!
  spin $!
  return $?
}

# Build the PR body and write to a temp file.
# Prints file path to stdout.
_build_pr_body() {
  local task_json="$1"
  local review_output_file="$2"
  local verdict="$3"

  local body_file
  body_file="$(factory_mktemp)"

  local task_id title description criteria
  task_id="$(printf '%s' "$task_json" | jq -r '.task_id')"
  title="$(printf '%s' "$task_json" | jq -r '.title')"
  description="$(printf '%s' "$task_json" | jq -r '.description // ""')"
  criteria="$(printf '%s' "$task_json" | jq -r '.acceptance_criteria // [] | .[] | "- [ ] " + .')"

  cat > "$body_file" <<BODY
## Task: ${title}

**Task ID:** ${task_id}
**Review Verdict:** ${verdict}

### Description

${description}

### Acceptance Criteria

${criteria}

### Tests Written

BODY

  # Extract test files from the diff
  local test_files
  test_files="$(git -C "$PROJECT_DIR" diff --name-only "staging...feat/${task_id}" 2>/dev/null \
    | grep -E '\.(test|spec)\.' || true)"

  if [[ -n "$test_files" ]]; then
    printf '%s\n' "$test_files" | while IFS= read -r f; do
      printf -- "- \`%s\`\n" "$f" >> "$body_file"
    done
  else
    printf 'No test files detected in diff.\n' >> "$body_file"
  fi

  {
    cat <<'DELIM'

### Review Findings

DELIM
    if [[ -f "$review_output_file" ]]; then
      cat <<'DELIM'
<details>
<summary>Code review output</summary>

DELIM
      cat "$review_output_file"
      cat <<'DELIM'

</details>
DELIM
    else
      printf 'No review output available.\n'
    fi
  } >> "$body_file"

  printf '%s' "$body_file"
}

# Create PR against staging. Retries once on failure after 5s delay.
_create_pr() {
  local task_id="$1"
  local title="$2"
  local body_file="$3"
  local branch="feat/${task_id}"

  local repo_url
  repo_url="$(git -C "$PROJECT_DIR" remote get-url origin)"

  # Push branch to remote
  git -C "$PROJECT_DIR" push -u origin "$branch" --quiet 2>/dev/null || {
    log_warn "Push failed; retrying once"
    git -C "$PROJECT_DIR" push -u origin "$branch" --quiet
  }

  local pr_url=""
  local pr_title="feat(${task_id}): ${title}"

  # First attempt
  pr_url="$(gh pr create \
    --base staging \
    --head "$branch" \
    --title "$pr_title" \
    --body-file "$body_file" \
    -R "$repo_url" 2>/dev/null)" || {

    log_warn "PR creation failed — retrying in 5 seconds"
    sleep 5

    # Second attempt
    pr_url="$(gh pr create \
      --base staging \
      --head "$branch" \
      --title "$pr_title" \
      --body-file "$body_file" \
      -R "$repo_url")" || {
      log_error "PR creation failed after retry"
      return 1
    }
  }

  printf '%s' "$pr_url"
}

# Enable auto-merge on a PR.
_enable_auto_merge() {
  local pr_url="$1"

  gh pr merge --auto --squash "$pr_url" 2>/dev/null || {
    log_warn "Failed to enable auto-merge on $pr_url"
    return 0
  }

  log_success "Auto-merge enabled on $pr_url"
}

# Post review findings as a PR comment.
_post_review_comment() {
  local pr_url="$1"
  local review_output_file="$2"

  local comment_body
  comment_body="$(factory_mktemp)"
  cat > "$comment_body" <<'HEADER'
## Code Review — Needs Discussion

This PR was flagged for human review. Findings below:

HEADER
  cat "$review_output_file" >> "$comment_body"

  gh pr comment "$pr_url" --body-file "$comment_body" 2>/dev/null || {
    log_warn "Failed to post review comment on $pr_url"
  }

  rm -f "$comment_body"
}

# --- Public interface ---

# Review a completed task and create a PR.
# Usage: review_task <task_id> <task_json>
# Returns 0 on APPROVE or NEEDS_DISCUSSION (PR created), 1 on REQUEST_CHANGES,
# 2 on hard failure. On REQUEST_CHANGES, also sets TASK_FAILURE_TYPE=code_review.
review_task() {
  local task_id="$1"
  local task_json="$2"
  local is_followup="${3:-0}"
  local prior_findings="${4:-}"

  # Skip if review is disabled
  if [[ "${ENABLE_CODE_REVIEW}" -eq 0 ]]; then
    log_info "Code review disabled — skipping"
    return 0
  fi

  local branch="feat/${task_id}"
  local title
  title="$(printf '%s' "$task_json" | jq -r '.title')"

  log_info "Starting code review for $task_id ($([ "$is_followup" -eq 1 ] && echo "follow-up" || echo "initial"))"

  # Build review prompt (Claude reads the diff via tools)
  local prompt_file
  prompt_file="$(_build_review_prompt "$task_json" "$branch" "$is_followup" "$prior_findings")"

  # Run review in background with spinner
  local review_output_file
  review_output_file="$(factory_mktemp)"

  log_info "Running review with Sonnet (max $REVIEW_TURNS turns)"
  if ! _invoke_review "$prompt_file" "$review_output_file"; then
    log_error "Review session failed for $task_id"
    rm -f "$prompt_file" "$review_output_file"
    return 2
  fi
  rm -f "$prompt_file"

  # Log review output
  if [[ -n "${FACTORY_LOG_DIR:-}" ]]; then
    local log_prefix="${FACTORY_LOG_DIR}/${task_id}-attempt-${_CURRENT_ATTEMPT:-1}"
    cp "$review_output_file" "${log_prefix}.review.json" 2>/dev/null || true
  fi

  # Parse verdict
  local verdict
  verdict="$(_parse_verdict "$review_output_file")"

  log_info "Review verdict for $task_id: $verdict"

  case "$verdict" in
    APPROVE)
      log_success "Code review approved $task_id"

      # Create PR and enable auto-merge
      local body_file
      body_file="$(_build_pr_body "$task_json" "$review_output_file" "$verdict")"

      local pr_url
      pr_url="$(_create_pr "$task_id" "$title" "$body_file")" || {
        log_error "Failed to create PR for $task_id"
        rm -f "$body_file" "$review_output_file"
        return 1
      }
      rm -f "$body_file"
      log_success "PR created: $pr_url"

      _enable_auto_merge "$pr_url"
      rm -f "$review_output_file"
      return 0
      ;;

    REQUEST_CHANGES)
      log_warn "Review requested changes for $task_id"

      export TASK_FAILURE_TYPE="code_review"
      export TASK_FAILURE_OUTPUT
      TASK_FAILURE_OUTPUT="$(head -c 4000 "$review_output_file" 2>/dev/null || true)"
      rm -f "$review_output_file"
      return 1
      ;;

    NEEDS_DISCUSSION)
      log_warn "Review flagged $task_id for discussion"

      # Create PR without auto-merge, post comment with findings
      local body_file
      body_file="$(_build_pr_body "$task_json" "$review_output_file" "$verdict")"

      local pr_url
      pr_url="$(_create_pr "$task_id" "$title" "$body_file")" || {
        log_error "Failed to create PR for $task_id"
        rm -f "$body_file" "$review_output_file"
        return 1
      }
      rm -f "$body_file"
      log_success "PR created (no auto-merge): $pr_url"

      _post_review_comment "$pr_url" "$review_output_file"
      rm -f "$review_output_file"
      return 0
      ;;

    *)
      log_error "Unexpected review verdict: $verdict"
      rm -f "$review_output_file"
      return 2
      ;;
  esac
}
