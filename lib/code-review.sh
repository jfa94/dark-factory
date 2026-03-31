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
_build_review_prompt() {
  local task_json="$1"
  local diff_content="$2"
  local is_followup="${3:-0}"

  local prompt_file
  prompt_file="$(mktemp)"

  local task_id title description criteria
  task_id="$(printf '%s' "$task_json" | jq -r '.task_id')"
  title="$(printf '%s' "$task_json" | jq -r '.title')"
  description="$(printf '%s' "$task_json" | jq -r '.description // ""')"
  criteria="$(printf '%s' "$task_json" | jq -r '.acceptance_criteria // [] | .[] | "- " + .')"

  if [[ "$is_followup" -eq 1 ]]; then
    # Stricter follow-up review — critical issues only
    cat > "$prompt_file" <<'HEADER'
# Follow-up Code Review (stricter pass)

This is a follow-up review after the author addressed previous findings.
Only flag **critical issues** — things that would cause bugs, data loss,
security vulnerabilities, or fundamentally broken behavior.

Do NOT flag:
- Formatting, naming conventions, or lint violations
- Minor style preferences
- Suggestions that are "nice to have" but not critical
- Issues already present before this change

HEADER
  else
    cat > "$prompt_file" <<'HEADER'
# Code Review

Review the diff below. Focus on:
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

## Diff

\`\`\`diff
CONTEXT

  # Append diff content from file to avoid shell expansion issues
  cat "$diff_content" >> "$prompt_file"

  cat >> "$prompt_file" <<'VERDICT'
```

## Your Verdict

After reviewing, output exactly one of these verdicts on its own line:

VERDICT: APPROVE
VERDICT: REQUEST_CHANGES
VERDICT: NEEDS_DISCUSSION

If APPROVE: briefly state why the code is acceptable.
If REQUEST_CHANGES: list specific issues that must be fixed (numbered).
If NEEDS_DISCUSSION: explain what needs human judgment and why.
VERDICT

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

  local -a args=(claude --print --model sonnet --max-turns "$REVIEW_TURNS" -C "$PROJECT_DIR")
  args+=(-p "$prompt_content")

  "${args[@]}" > "$output_file" 2>&1 &
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
  body_file="$(mktemp)"

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
      printf -- '- `%s`\n' "$f" >> "$body_file"
    done
  else
    printf 'No test files detected in diff.\n' >> "$body_file"
  fi

  cat >> "$body_file" <<'DELIM'

### Review Findings

DELIM

  if [[ -f "$review_output_file" ]]; then
    cat >> "$body_file" <<'DELIM'
<details>
<summary>Code review output</summary>

DELIM
    cat "$review_output_file" >> "$body_file"
    cat >> "$body_file" <<'DELIM'

</details>
DELIM
  else
    printf 'No review output available.\n' >> "$body_file"
  fi

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
  comment_body="$(mktemp)"
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
# Sets REVIEW_VERDICT (APPROVE/REQUEST_CHANGES/NEEDS_DISCUSSION).
# Returns 0 on success, 1 on failure.
# On REQUEST_CHANGES, sets REVIEW_FINDINGS with the review output
# and returns 1 with TASK_FAILURE_TYPE=code_review so the runner retries.
review_task() {
  local task_id="$1"
  local task_json="$2"
  local is_followup="${3:-0}"

  REVIEW_VERDICT=""
  REVIEW_FINDINGS=""

  # Skip if review is disabled
  if [[ "${ENABLE_CODE_REVIEW}" -eq 0 ]]; then
    log_info "Code review disabled — skipping"
    REVIEW_VERDICT="APPROVE"
    return 0
  fi

  local branch="feat/${task_id}"
  local title
  title="$(printf '%s' "$task_json" | jq -r '.title')"

  log_info "Starting code review for $task_id ($([ "$is_followup" -eq 1 ] && echo "follow-up" || echo "initial"))"

  # Get the diff for review
  local diff_file
  diff_file="$(mktemp)"
  git -C "$PROJECT_DIR" diff "staging...$branch" > "$diff_file" 2>/dev/null || {
    log_error "Failed to generate diff for $task_id"
    rm -f "$diff_file"
    return 1
  }

  # Check diff is non-empty
  if [[ ! -s "$diff_file" ]]; then
    log_warn "Empty diff for $task_id — nothing to review"
    rm -f "$diff_file"
    REVIEW_VERDICT="APPROVE"
    return 0
  fi

  # Build review prompt
  local prompt_file
  prompt_file="$(_build_review_prompt "$task_json" "$diff_file" "$is_followup")"
  rm -f "$diff_file"

  # Run review in background with spinner
  local review_output_file
  review_output_file="$(mktemp)"

  log_info "Running review with Sonnet (max $REVIEW_TURNS turns)"
  if ! _invoke_review "$prompt_file" "$review_output_file"; then
    log_error "Review session failed for $task_id"
    rm -f "$prompt_file" "$review_output_file"
    REVIEW_VERDICT="NEEDS_DISCUSSION"
    return 1
  fi
  rm -f "$prompt_file"

  # Parse verdict
  local verdict
  verdict="$(_parse_verdict "$review_output_file")"
  REVIEW_VERDICT="$verdict"

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

      # Stash findings for retry context
      REVIEW_FINDINGS="$(cat "$review_output_file" 2>/dev/null || true)"
      TASK_FAILURE_TYPE="code_review"
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
  esac
}
