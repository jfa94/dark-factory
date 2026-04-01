#!/usr/bin/env bash
set -euo pipefail

# Spec generation and review pipeline.
# Fetches PRD from GitHub issue, invokes Claude to generate specs + tasks.json,
# validates output, and runs automated spec review loop.

# --- Defaults (overridable via environment) ---

SPEC_GEN_TURNS="${SPEC_GEN_TURNS:-80}"
SPEC_PASS_THRESHOLD="${SPEC_PASS_THRESHOLD:-48}"
MAX_SPEC_ITERATIONS="${MAX_SPEC_ITERATIONS:-3}"

# --- Internal helpers ---

# Fetch PRD body and title from a GitHub issue.
# Sets _PRD_TITLE and _PRD_BODY.
_fetch_prd() {
  local _issue_num="$1"
  local repo_url
  repo_url="$(git -C "$PROJECT_DIR" remote get-url origin)"

  log_info "Fetching PRD from issue #${_issue_num}"

  _PRD_TITLE="$(gh issue view "$_issue_num" -R "$repo_url" --json title --jq '.title')" || {
    log_error "Failed to fetch issue #${_issue_num} title"
    return 1
  }

  _PRD_BODY="$(gh issue view "$_issue_num" -R "$repo_url" --json body --jq '.body')" || {
    log_error "Failed to fetch issue #${_issue_num} body"
    return 1
  }

  if [[ -z "$_PRD_BODY" ]]; then
    log_error "Issue #${_issue_num} has an empty body"
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
# Inlines the prd-to-spec skill content (Claude runs in the target project,
# not in dark-factory, so skills aren't available). Adapts interactive steps
# for headless --print mode.
# Returns the temp file path via stdout.
_build_spec_prompt() {
  local prd_body="$1"
  local spec_dir="$2"
  local prompt_file
  prompt_file="$(factory_mktemp)"

  local skill_file="${FACTORY_DIR}/.claude/skills/prd-to-spec/SKILL.md"

  cat <<PROMPT_HEADER > "$prompt_file"
You are generating vertical-slice specs from a PRD in fully automated (headless) mode.
There is no user to interact with — skip any steps that require user input.

Follow the spec generation process below. Key adaptations for headless mode:
- Skip step 1 (finding the PRD) — it is provided below
- Skip step 5 (quiz the user) — proceed directly with your best breakdown
- For step 8 (create tasks) — always create tasks, do not ask
- IMPORTANT: Write ALL spec files and tasks.json into this exact directory: ${spec_dir}

PROMPT_HEADER

  # Inline the skill content (strip YAML frontmatter)
  if [[ -f "$skill_file" ]]; then
    sed -n '/^---$/,/^---$/!p' "$skill_file" >> "$prompt_file"
  else
    log_warn "prd-to-spec skill not found at $skill_file — using fallback prompt"
    cat <<'FALLBACK' >> "$prompt_file"
Break the PRD into vertical-slice specs. For each slice, write a Markdown spec in specs/features/<slug>/.
Then create a tasks.json file in the same directory with all implementation tasks as a flat JSON array.
Each task needs: task_id, title, description, files, acceptance_criteria, tests_to_write, depends_on.
FALLBACK
  fi

  # Append the PRD body
  cat >> "$prompt_file" <<'PRD_HEADER'

---

## PRD (provided — skip step 1)

PRD_HEADER

  printf '%s\n' "$prd_body" >> "$prompt_file"

  printf '%s' "$prompt_file"
}

# Run Claude spec generation with retry for transient errors.
# Detects rate limits and API 500s, retries with backoff.
# Returns 0 on success, 1 on failure.
_run_spec_generation() {
  local prompt_file="$1"
  local turns="$2"
  local max_transient_retries=3
  local transient_attempt=0

  while [[ "$transient_attempt" -lt "$max_transient_retries" ]]; do
    transient_attempt=$(( transient_attempt + 1 ))

    if [[ "$transient_attempt" -gt 1 ]]; then
      local backoff=$(( transient_attempt * 15 ))
      log_info "Retrying after ${backoff}s backoff (transient retry $transient_attempt/$max_transient_retries)"
      sleep "$backoff"
    fi

    log_info "Running spec generation (max turns: $turns)"

    local gen_output_file
    gen_output_file="$(factory_mktemp)"

    (cd "$PROJECT_DIR" && claude --print --model opus --effort high --max-turns "$turns" \
      -p "$(cat "$prompt_file")") \
      > "$gen_output_file" 2>&1 &
    local pid=$!
    register_bg_pid $pid

    if spin $pid; then
      if [[ -n "${FACTORY_LOG_DIR:-}" ]]; then
        cp "$gen_output_file" "${FACTORY_LOG_DIR}/spec-gen.log" 2>/dev/null || true
      fi
      rm -f "$gen_output_file"
      return 0
    fi

    # Check if this is a rate limit error
    local reset_info
    if reset_info="$(is_rate_limit_error "$gen_output_file")"; then
      log_warn "Claude rate limited during spec generation: $reset_info"
      rm -f "$gen_output_file"
      wait_for_claude_available "$reset_info"
      continue
    fi

    # Check for transient API errors (500, 502, 503, 529)
    if grep -qE 'API Error: (500|502|503|529)|Internal server error|overloaded' "$gen_output_file" 2>/dev/null; then
      log_warn "Transient API error (attempt $transient_attempt/$max_transient_retries)"
      tail -5 "$gen_output_file" | while IFS= read -r line; do
        log_warn "  $line"
      done
      rm -f "$gen_output_file"
      continue
    fi

    # Non-transient failure
    log_error "Claude spec generation failed"
    if [[ -n "${FACTORY_LOG_DIR:-}" ]]; then
      cp "$gen_output_file" "${FACTORY_LOG_DIR}/spec-gen.log" 2>/dev/null || true
      log_error "  Full output saved to: ${FACTORY_LOG_DIR}/spec-gen.log"
    fi
    tail -20 "$gen_output_file" | while IFS= read -r line; do
      log_error "  $line"
    done
    rm -f "$gen_output_file"
    return 1
  done

  log_error "Spec generation failed after $max_transient_retries transient retries"
  return 1
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
# Usage: _run_spec_review <spec_dir> <iteration>
_run_spec_review() {
  local spec_dir="$1"
  local iteration="${2:-1}"
  local review_output_file
  review_output_file="$(factory_mktemp)"

  log_info "Running spec review"

  (cd "$PROJECT_DIR" && claude --print --model sonnet --max-turns 20 \
    --agent spec-reviewer \
    -p "Review the spec in ${spec_dir}. Score each criterion and provide an overall score out of 60. List any blocking issues.") \
    > "$review_output_file" 2>&1 &
  local pid=$!
  register_bg_pid $pid
  if ! spin $pid; then
    log_warn "Spec review process exited with error"
    if [[ -n "${FACTORY_LOG_DIR:-}" ]]; then
      cp "$review_output_file" "${FACTORY_LOG_DIR}/spec-review-${iteration}.log" 2>/dev/null || true
      log_warn "  Review output saved to: ${FACTORY_LOG_DIR}/spec-review-${iteration}.log"
    fi
    rm -f "$review_output_file"
    return 1
  fi

  if [[ -n "${FACTORY_LOG_DIR:-}" ]]; then
    cp "$review_output_file" "${FACTORY_LOG_DIR}/spec-review-${iteration}.log" 2>/dev/null || true
  fi

  cat "$review_output_file"
  rm -f "$review_output_file"
}

# Fix blocking issues identified by spec review.
# Usage: _fix_blocking_issues <spec_dir> <review_output> <iteration>
_fix_blocking_issues() {
  local spec_dir="$1"
  local review_output="$2"
  local iteration="${3:-1}"

  log_info "Fixing blocking issues from spec review"

  local fix_prompt_file
  fix_prompt_file="$(factory_mktemp)"

  local skill_file="${FACTORY_DIR}/.claude/skills/prd-to-spec/SKILL.md"

  cat <<'FIXHEADER' > "$fix_prompt_file"
The spec was reviewed and received a score below the passing threshold.
Fix ALL blocking issues identified in the review. Update spec files and tasks.json accordingly.

Fix priority order:
1. Test Coverage gaps (add missing tests_to_write entries)
2. Acceptance Criteria quality (add specificity, fix vague criteria)
3. Dependency graph issues (fix cycles, dangling references)
4. All other blocking issues

FIXHEADER

  # Re-inline test-coverage-rules so the fixer knows what good looks like
  if [[ -f "$skill_file" ]]; then
    {
      printf '## Test Coverage Rules (apply when fixing Test Coverage gaps)\n\n'
      awk '/^<test-coverage-rules>/,/^<\/test-coverage-rules>/' "$skill_file"
      printf '\n'
    } >> "$fix_prompt_file"
  fi

  # Add mechanical checklist for Test Coverage fixes
  if printf '%s' "$review_output" | grep -q "Test Coverage.*BLOCKING\|BLOCKING.*Test Coverage"; then
    cat <<'COVERAGE_FIX' >> "$fix_prompt_file"

## Mechanical Fix for Test Coverage

For EVERY task in tasks.json:
1. Count the entries in `acceptance_criteria`
2. Count the entries in `tests_to_write`
3. If tests_to_write count < acceptance_criteria count, add the missing test entries
4. Each new entry must follow: `filename.test.ts: description of what it asserts`
5. For any criterion involving validation/storage/permissions/error handling, ensure at least one error-path test exists

COVERAGE_FIX
  fi

  printf 'Spec directory: %s\n\nReview output:\n\n%s\n' "$spec_dir" "$review_output" >> "$fix_prompt_file"

  local fix_output_file
  fix_output_file="$(factory_mktemp)"

  (cd "$PROJECT_DIR" && claude --print --model sonnet --max-turns 40 \
    -p "$(cat "$fix_prompt_file")") \
    > "$fix_output_file" 2>&1 &
  local pid=$!
  register_bg_pid $pid
  if spin $pid; then
    if [[ -n "${FACTORY_LOG_DIR:-}" ]]; then
      cp "$fix_output_file" "${FACTORY_LOG_DIR}/spec-fix-${iteration}.log" 2>/dev/null || true
    fi
  else
    log_warn "Fix attempt exited with error"
    if [[ -n "${FACTORY_LOG_DIR:-}" ]]; then
      cp "$fix_output_file" "${FACTORY_LOG_DIR}/spec-fix-${iteration}.log" 2>/dev/null || true
      log_warn "  Fix output saved to: ${FACTORY_LOG_DIR}/spec-fix-${iteration}.log"
    fi
    tail -10 "$fix_output_file" | while IFS= read -r line; do
      log_warn "  $line"
    done
  fi

  rm -f "$fix_prompt_file" "$fix_output_file"
}

# Comment failure details on the GitHub issue and add label.
_report_failure() {
  local _issue_num="$1"
  local reason="$2"

  log_error "Spec generation failed for issue #${_issue_num}: $reason"

  gh issue comment "$_issue_num" \
    -R "$(git -C "$PROJECT_DIR" remote get-url origin)" \
    --body "$(cat <<EOF
## Automated Spec Generation Failed

**Reason:** ${reason}

This issue requires manual spec authoring. The automated pipeline was unable to produce a spec that meets the quality threshold after all retry attempts.
EOF
)" || log_warn "Failed to post failure comment on issue"

  gh issue edit "$_issue_num" \
    -R "$(git -C "$PROJECT_DIR" remote get-url origin)" \
    --add-label "needs-manual-spec" || log_warn "Failed to add needs-manual-spec label"
}

# --- Public interface ---

# Generate and review a spec from a GitHub issue PRD.
# Expects MODE=issue, ISSUE_NUMBER, and PROJECT_DIR to be set.
generate_and_review_spec() {
  # Fetch PRD
  _fetch_prd "$ISSUE_NUMBER" || return 1

  local slug
  slug="$(slugify_title "$_PRD_TITLE")"
  local spec_dir="specs/features/${slug}"
  local tasks_file="${PROJECT_DIR}/${spec_dir}/tasks.json"

  log_info "Spec directory: $spec_dir"

  # Initialize log directory now so spec-gen outputs can be persisted.
  # run-factory.sh will skip re-initialization if FACTORY_LOG_DIR is already set.
  if [[ -z "${FACTORY_LOG_DIR:-}" ]]; then
    init_log_dir "$PROJECT_DIR" "$slug"
  fi

  # Skip if valid tasks.json already exists
  if _validate_tasks_json "$tasks_file" 2>/dev/null; then
    log_info "Valid tasks.json already exists — skipping generation"
    return 0
  fi

  # Build prompt
  local prompt_file
  prompt_file="$(_build_spec_prompt "$_PRD_BODY" "$spec_dir")"

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
    _report_failure "$ISSUE_NUMBER" "Spec generation failed after 2 attempts — tasks.json missing or invalid"
    return 1
  fi

  log_success "Spec generated successfully"

  # --- Review loop ---

  local iteration=0
  local passed=0

  while [[ "$iteration" -lt "$MAX_SPEC_ITERATIONS" ]]; do
    iteration=$(( iteration + 1 ))
    log_info "Spec review iteration $iteration/$MAX_SPEC_ITERATIONS"

    check_usage_and_wait || return 1

    local review_output
    review_output="$(_run_spec_review "$spec_dir" "$iteration")"

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
      check_usage_and_wait || return 1
      _fix_blocking_issues "$spec_dir" "$review_output" "$iteration"

      # Re-validate tasks.json after fixes
      if ! _validate_tasks_json "$tasks_file"; then
        log_error "tasks.json became invalid after fix attempt"
        _report_failure "$ISSUE_NUMBER" "tasks.json corrupted during spec review fix (iteration $iteration)"
        return 1
      fi
    fi
  done

  if [[ "$passed" -eq 0 ]]; then
    _report_failure "$ISSUE_NUMBER" "Spec review score below threshold after $MAX_SPEC_ITERATIONS iterations"
    return 1
  fi

  log_success "Spec passed review (score: ${score}/60)"
  return 0
}
