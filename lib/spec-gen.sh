#!/usr/bin/env bash
set -euo pipefail

# Spec generation and review pipeline.
# Fetches PRD from GitHub issue, invokes Claude to generate specs + tasks.json,
# validates output, and runs automated spec review loop.

# --- Defaults (overridable via environment) ---

SPEC_GEN_TURNS="${SPEC_GEN_TURNS:-60}"
SPEC_PASS_THRESHOLD="${SPEC_PASS_THRESHOLD:-48}"
MAX_SPEC_ITERATIONS="${MAX_SPEC_ITERATIONS:-3}"

# --- Internal helpers ---

# Fetch PRD body and title from a GitHub issue.
# Sets _PRD_TITLE and _PRD_BODY.
_fetch_prd() {
  local issue_number="$1"
  local repo_url
  repo_url="$(git -C "$PROJECT_DIR" remote get-url origin)"

  log_info "Fetching PRD from issue #${issue_number}"

  _PRD_TITLE="$(gh issue view "$issue_number" -R "$repo_url" --json title --jq '.title')" || {
    log_error "Failed to fetch issue #${issue_number} title"
    return 1
  }

  _PRD_BODY="$(gh issue view "$issue_number" -R "$repo_url" --json body --jq '.body')" || {
    log_error "Failed to fetch issue #${issue_number} body"
    return 1
  }

  if [[ -z "$_PRD_BODY" ]]; then
    log_error "Issue #${issue_number} has an empty body"
    return 1
  fi

  log_info "PRD: $_PRD_TITLE"
}

# Validate that tasks.json exists, is non-empty, and is valid JSON.
# Returns 0 on success, 1 on failure (with specific error messages).
_validate_tasks_json() {
  local tasks_file="$1"

  if [[ ! -f "$tasks_file" ]]; then
    log_error "Missing file: $tasks_file"
    return 1
  fi

  if [[ ! -s "$tasks_file" ]]; then
    log_error "Empty file: $tasks_file"
    return 1
  fi

  if ! jq empty "$tasks_file" 2>/dev/null; then
    log_error "Malformed JSON: $tasks_file"
    return 1
  fi

  return 0
}

# Build the spec generation prompt and write it to a temp file.
# Returns the temp file path via stdout.
_build_spec_prompt() {
  local prd_body="$1"
  local prompt_file
  prompt_file="$(mktemp)"

  cat <<'PROMPT_HEADER' > "$prompt_file"
You are generating vertical-slice specs from a PRD. Use the /prd-to-spec skill.

/prd-to-spec

Here is the PRD to convert:

---

PROMPT_HEADER

  # Append PRD body safely (no variable expansion — written via cat)
  printf '%s\n' "$prd_body" >> "$prompt_file"

  printf '%s' "$prompt_file"
}

# Run Claude spec generation.
# Returns 0 on success, 1 on failure.
_run_spec_generation() {
  local prompt_file="$1"
  local turns="$2"

  log_info "Running spec generation (max turns: $turns)"

  claude --print --model sonnet --max-turns "$turns" \
    -C "$PROJECT_DIR" \
    -p "$(cat "$prompt_file")" \
    > /dev/null 2>&1 &
  local pid=$!
  spin $pid
  wait $pid || {
    log_error "Claude spec generation failed"
    return 1
  }

  return 0
}

# Extract review score from spec-reviewer output.
# Expects a line like "Score: 52/60" or "Total: 48/60".
# Returns the numeric score via stdout, or empty on parse failure.
_extract_review_score() {
  local review_output="$1"

  printf '%s' "$review_output" \
    | grep -oiE '(score|total)[^0-9]*([0-9]+)\s*/\s*60' \
    | tail -1 \
    | grep -oE '[0-9]+' \
    | head -1
}

# Run spec-reviewer agent and return the review output.
_run_spec_review() {
  local spec_dir="$1"
  local review_output_file
  review_output_file="$(mktemp)"

  log_info "Running spec review"

  claude --print --model sonnet --max-turns 20 \
    -C "$PROJECT_DIR" \
    --agent spec-reviewer \
    -p "Review the spec in ${spec_dir}. Score each criterion and provide an overall score out of 60. List any blocking issues." \
    > "$review_output_file" 2>&1 &
  local pid=$!
  spin $pid
  wait $pid || {
    log_warn "Spec review process exited with error"
  }

  cat "$review_output_file"
  rm -f "$review_output_file"
}

# Fix blocking issues identified by spec review.
_fix_blocking_issues() {
  local spec_dir="$1"
  local review_output="$2"

  log_info "Fixing blocking issues from spec review"

  local fix_prompt_file
  fix_prompt_file="$(mktemp)"

  # Write prompt safely — no shell expansion in heredoc body
  cat <<'FIXHEADER' > "$fix_prompt_file"
The spec was reviewed and received a score below the passing threshold.
Please fix all blocking issues identified in the review. Update the spec files and tasks.json accordingly.

Spec directory:
FIXHEADER
  printf '%s\n\nReview output:\n\n%s\n' "$spec_dir" "$review_output" >> "$fix_prompt_file"

  claude --print --model sonnet --max-turns 20 \
    -C "$PROJECT_DIR" \
    -p "$(cat "$fix_prompt_file")" \
    > /dev/null 2>&1 &
  local pid=$!
  spin $pid
  wait $pid || {
    log_warn "Fix attempt exited with error"
  }

  rm -f "$fix_prompt_file"
}

# Comment failure details on the GitHub issue and add label.
_report_failure() {
  local issue_number="$1"
  local reason="$2"

  log_error "Spec generation failed for issue #${issue_number}: $reason"

  gh issue comment "$issue_number" \
    -R "$(git -C "$PROJECT_DIR" remote get-url origin)" \
    --body "$(cat <<EOF
## Automated Spec Generation Failed

**Reason:** ${reason}

This issue requires manual spec authoring. The automated pipeline was unable to produce a spec that meets the quality threshold after all retry attempts.
EOF
)" || log_warn "Failed to post failure comment on issue"

  gh issue edit "$issue_number" \
    -R "$(git -C "$PROJECT_DIR" remote get-url origin)" \
    --add-label "needs-manual-spec" || log_warn "Failed to add needs-manual-spec label"
}

# --- Public interface ---

# Generate and review a spec from a GitHub issue PRD.
# Expects MODE=issue, ISSUE_NUMBER, and PROJECT_DIR to be set.
generate_and_review_spec() {
  local issue_number="$ISSUE_NUMBER"

  # Fetch PRD
  _fetch_prd "$issue_number" || return 1

  local slug
  slug="$(slugify_title "$_PRD_TITLE")"
  local spec_dir="specs/features/${slug}"
  local tasks_file="${PROJECT_DIR}/${spec_dir}/tasks.json"

  log_info "Spec directory: $spec_dir"

  # Skip if valid tasks.json already exists
  if _validate_tasks_json "$tasks_file" 2>/dev/null; then
    log_info "Valid tasks.json already exists — skipping generation"
    return 0
  fi

  # Build prompt
  local prompt_file
  prompt_file="$(_build_spec_prompt "$_PRD_BODY")"

  # --- Generation attempt (with one retry at higher budget) ---

  local gen_success=0

  for attempt in 1 2; do
    local turns="$SPEC_GEN_TURNS"
    if [[ "$attempt" -eq 2 ]]; then
      turns=$(( SPEC_GEN_TURNS + 20 ))
      log_warn "Retrying spec generation with increased budget ($turns turns)"
    fi

    if _run_spec_generation "$prompt_file" "$turns"; then
      if _validate_tasks_json "$tasks_file"; then
        gen_success=1
        break
      else
        log_warn "Spec generation produced invalid output (attempt $attempt)"
      fi
    fi
  done

  rm -f "$prompt_file"

  if [[ "$gen_success" -eq 0 ]]; then
    _report_failure "$issue_number" "Spec generation failed after 2 attempts — tasks.json missing or invalid"
    return 1
  fi

  log_success "Spec generated successfully"

  # --- Review loop ---

  local iteration=0
  local passed=0

  while [[ "$iteration" -lt "$MAX_SPEC_ITERATIONS" ]]; do
    iteration=$(( iteration + 1 ))
    log_info "Spec review iteration $iteration/$MAX_SPEC_ITERATIONS"

    local review_output
    review_output="$(_run_spec_review "$spec_dir")"

    local score
    score="$(_extract_review_score "$review_output")"

    if [[ -z "$score" ]]; then
      log_warn "Could not parse review score — treating as below threshold"
      score=0
    fi

    log_info "Review score: ${score}/60 (threshold: ${SPEC_PASS_THRESHOLD}/60)"

    if [[ "$score" -ge "$SPEC_PASS_THRESHOLD" ]]; then
      passed=1
      break
    fi

    if [[ "$iteration" -lt "$MAX_SPEC_ITERATIONS" ]]; then
      _fix_blocking_issues "$spec_dir" "$review_output"

      # Re-validate tasks.json after fixes
      if ! _validate_tasks_json "$tasks_file"; then
        log_error "tasks.json became invalid after fix attempt"
        _report_failure "$issue_number" "tasks.json corrupted during spec review fix (iteration $iteration)"
        return 1
      fi
    fi
  done

  if [[ "$passed" -eq 0 ]]; then
    _report_failure "$issue_number" "Spec review score below threshold after $MAX_SPEC_ITERATIONS iterations"
    return 1
  fi

  log_success "Spec passed review (score: ${score}/60)"
  return 0
}
