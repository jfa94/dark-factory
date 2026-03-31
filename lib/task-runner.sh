#!/usr/bin/env bash
set -euo pipefail

# Single-task execution engine: branch creation, prompt building,
# Claude invocation, auto-fix, quality gate, and retry with
# failure-type-specific context.

# --- Defaults (overridable via environment) ---

MAX_TASK_RETRIES="${MAX_TASK_RETRIES:-4}"

# --- Placeholder: circuit breaker (implemented in spec 07) ---

check_time_circuit_breaker() {
  return 0
}

# --- Internal helpers ---

# Look up a task by ID from the tasks file.
# Outputs the full JSON object for the task.
_get_task_json() {
  local tasks_file="$1"
  local task_id="$2"

  local task_json
  task_json="$(jq -e --arg id "$task_id" '.[] | select(.task_id == $id)' "$tasks_file" 2>/dev/null)" || {
    log_error "Task $task_id not found in $tasks_file"
    return 1
  }

  printf '%s' "$task_json"
}

# Map complexity to model flag and max-turns budget.
# Sets _MODEL_FLAG and _MAX_TURNS.
_map_complexity() {
  local complexity="$1"

  case "$complexity" in
    simple)
      _MODEL_ARGS=("--model" "haiku")
      _MAX_TURNS=40
      ;;
    complex)
      _MODEL_ARGS=("--model" "opus")
      _MAX_TURNS=80
      ;;
    *)
      # standard (default)
      _MODEL_ARGS=()
      _MAX_TURNS=60
      ;;
  esac
}

# Create feature branch from staging.
# Checks out staging first, then creates feat/<task-id>.
_create_feature_branch() {
  local task_id="$1"
  local branch="feat/${task_id}"

  # If branch already exists, just check it out (resumed task)
  if git -C "$PROJECT_DIR" rev-parse --verify "$branch" &>/dev/null; then
    log_info "Branch $branch already exists — resuming"
    git -C "$PROJECT_DIR" checkout "$branch" --quiet
    return 0
  fi

  # Create from staging
  git -C "$PROJECT_DIR" checkout staging --quiet
  git -C "$PROJECT_DIR" checkout -b "$branch" --quiet
  log_info "Created branch $branch from staging"
}

# Build the initial task prompt and write to temp file.
# Returns temp file path via stdout.
_build_task_prompt() {
  local task_json="$1"
  local prompt_file
  prompt_file="$(mktemp)"

  local task_id title description complexity
  task_id="$(printf '%s' "$task_json" | jq -r '.task_id')"
  title="$(printf '%s' "$task_json" | jq -r '.title')"
  description="$(printf '%s' "$task_json" | jq -r '.description // ""')"
  complexity="$(printf '%s' "$task_json" | jq -r '.complexity // "standard"')"

  # Extract acceptance criteria as bullet list
  local criteria
  criteria="$(printf '%s' "$task_json" | jq -r '.acceptance_criteria // [] | .[] | "- " + .')"

  # Extract file list
  local files
  files="$(printf '%s' "$task_json" | jq -r '.files // [] | .[] | "- " + .')"

  # Extract test requirements if present
  local test_reqs
  test_reqs="$(printf '%s' "$task_json" | jq -r '.test_requirements // .testing // empty')"

  cat > "$prompt_file" <<PROMPT
# Task: ${title}

**Task ID:** ${task_id}
**Complexity:** ${complexity}

## Orientation (do this first)

1. Read \`claude-progress.json\` to understand project state and any prior work
2. Run \`git log --oneline -20\` to see recent commits and detect prior work on this task
3. Run \`./init.sh\` to ensure dependencies are installed and environment is ready

## Description

${description}

## Acceptance Criteria

${criteria}
PROMPT

  if [[ -n "$files" ]]; then
    cat >> "$prompt_file" <<PROMPT

## Files to Create/Modify

${files}
PROMPT
  fi

  if [[ -n "$test_reqs" ]]; then
    cat >> "$prompt_file" <<PROMPT

## Test Requirements

${test_reqs}
PROMPT
  fi

  cat >> "$prompt_file" <<'PROMPT'

## Rules

- Complete exactly ONE task in this session — this task only
- Use conventional commits: `feat(scope): description`, `fix(scope): description`, etc.
- Update `claude-progress.json` before stopping:
  - Set `current_task` to this task_id while working
  - Add session entry to `sessions` array
  - On completion: add task_id to `tasks_completed`, set `current_task` to null
  - On failure: add task_id to `tasks_failed`, set `current_task` to null
  - Update `last_updated` timestamp
- Update `feature-status.json` with acceptance criteria status
- Write tests for all new functionality (both happy path and edge cases)
- Do not modify existing tests to make them pass — fix the implementation instead
PROMPT

  printf '%s' "$prompt_file"
}

# Build retry prompt with failure context.
# Returns temp file path via stdout.
_build_retry_prompt() {
  local task_json="$1"
  local failure_type="$2"
  local failure_output="$3"
  local exit_code="$4"
  local attempt="$5"

  local prompt_file
  prompt_file="$(mktemp)"

  # Start with the base task prompt
  local base_prompt_file
  base_prompt_file="$(_build_task_prompt "$task_json")"
  cat "$base_prompt_file" > "$prompt_file"
  rm -f "$base_prompt_file"

  # Append retry-specific context
  cat >> "$prompt_file" <<RETRY_HEADER

## Retry Context (attempt ${attempt})

**Previous failure type:** ${failure_type}
**Previous exit code:** ${exit_code}

RETRY_HEADER

  # Type-specific guidance
  case "$failure_type" in
    max_turns)
      cat >> "$prompt_file" <<'GUIDANCE'
### Guidance: Max Turns Exceeded

The previous attempt ran out of turns before completing. Your partial work has been preserved on this branch.

- Continue from where the previous session left off
- Read `claude-progress.json` and `git log` to understand what was already done
- Focus on remaining work only — do not redo completed steps
- Be more concise in your approach to stay within the turn budget
GUIDANCE
      ;;
    quality_gate)
      cat >> "$prompt_file" <<'GUIDANCE'
### Guidance: Quality Gate Failed

The previous attempt completed but failed the quality gate (`pnpm quality`).

**Quality gate output:**

```
GUIDANCE
      printf '%s\n' "$failure_output" >> "$prompt_file"
      cat >> "$prompt_file" <<'GUIDANCE'
```

- Fix the specific issues shown above
- Run `pnpm quality` yourself before declaring done
- Common issues: lint errors, type errors, test failures, formatting
GUIDANCE
      ;;
    agent_error)
      cat >> "$prompt_file" <<GUIDANCE
### Guidance: Agent Error

The previous Claude session exited with an error (exit code ${exit_code}).

- Check \`git status\` and \`git log\` for any partial work
- Read \`claude-progress.json\` for session state
- Retry the task from current state
GUIDANCE
      ;;
    no_changes)
      cat >> "$prompt_file" <<'GUIDANCE'
### Guidance: No Changes Detected

The previous attempt completed but produced no git changes. This likely means the session failed to make progress.

- Ensure you are creating/modifying the correct files
- Check that file paths match the spec exactly
- Verify you are on the correct branch
- Make concrete changes — do not just analyze
GUIDANCE
      ;;
    code_review)
      cat >> "$prompt_file" <<'GUIDANCE'
### Guidance: Code Review Requested Changes

The implementation was completed and passed the quality gate, but the code review identified issues that must be fixed.

**Review findings:**

```
GUIDANCE
      printf '%s\n' "$failure_output" >> "$prompt_file"
      cat >> "$prompt_file" <<'GUIDANCE'
```

- Address each numbered finding from the review
- Do not break existing tests — fix the implementation, not the tests
- Focus on logic errors, edge cases, and correctness issues
- Run `pnpm quality` after making changes
GUIDANCE
      ;;
  esac

  printf '%s' "$prompt_file"
}

# Invoke Claude with the given prompt file and complexity settings.
# Uses module globals _MODEL_ARGS and _MAX_TURNS from _map_complexity().
# Returns: exit code from Claude process.
_invoke_claude() {
  local prompt_file="$1"
  local output_file="$2"

  local prompt_content
  prompt_content="$(cat "$prompt_file")"

  # Build args array
  local -a args=(claude --print --max-turns "$_MAX_TURNS" -C "$PROJECT_DIR")
  if [[ ${#_MODEL_ARGS[@]} -gt 0 ]]; then
    args+=("${_MODEL_ARGS[@]}")
  fi
  args+=(-p "$prompt_content")

  # Run Claude in background with spinner
  "${args[@]}" > "$output_file" 2>&1 &
  spin $!
  return $?
}

# Run auto-fix: formatting then linting (non-fatal).
_run_auto_fix() {
  log_info "Running auto-fix (format + lint)"

  # Formatting — non-fatal
  if ! (cd "$PROJECT_DIR" && pnpm format 2>/dev/null); then
    log_warn "Auto-fix: pnpm format failed (non-fatal)"
  fi

  # Lint fix — non-fatal
  if ! (cd "$PROJECT_DIR" && pnpm lint --fix 2>/dev/null); then
    log_warn "Auto-fix: pnpm lint --fix failed (non-fatal)"
  fi

  # Stage any auto-fix changes
  git -C "$PROJECT_DIR" add -A 2>/dev/null || true
  if ! git -C "$PROJECT_DIR" diff --cached --quiet 2>/dev/null; then
    git -C "$PROJECT_DIR" commit -m "style: auto-fix formatting and lint" --quiet 2>/dev/null || true
  fi
}

# Run quality gate. Returns 0 on pass, 1 on fail.
# Captures output to the provided file path.
_run_quality_gate() {
  local output_file="$1"

  log_info "Running quality gate"

  if (cd "$PROJECT_DIR" && pnpm quality > "$output_file" 2>&1); then
    log_success "Quality gate passed"
    return 0
  else
    log_error "Quality gate failed"
    return 1
  fi
}

# --- Public interface ---

# Execute a single task end-to-end with retry.
# Usage: run_task <task_id>
# Returns 0 on success, 1 on failure.
# Sets TASK_OUTCOME (success/failure) and TASK_FAILURE_TYPE.
run_task() {
  local task_id="$1"

  TASK_OUTCOME=""
  TASK_FAILURE_TYPE=""

  log_info "Starting task: $task_id"

  # Look up task
  local task_json
  task_json="$(_get_task_json "$_TASKS_FILE" "$task_id")" || return 1

  local complexity
  complexity="$(printf '%s' "$task_json" | jq -r '.complexity // "standard"')"

  # Map complexity to model/turns
  _map_complexity "$complexity"

  # Create feature branch
  _create_feature_branch "$task_id" || return 1

  local attempt=0
  local max_retries="$MAX_TASK_RETRIES"
  local prev_failure_type=""
  local prev_failure_output=""
  local prev_exit_code=0

  while [[ "$attempt" -le "$max_retries" ]]; do
    attempt=$(( attempt + 1 ))

    # Circuit breaker check before each attempt
    if ! check_time_circuit_breaker; then
      log_error "Circuit breaker tripped — aborting task $task_id"
      TASK_OUTCOME="failure"
      TASK_FAILURE_TYPE="circuit_breaker"
      return 1
    fi

    if [[ "$attempt" -eq 1 ]]; then
      log_info "Task $task_id — attempt $attempt"
    else
      log_warn "Task $task_id — retry attempt $attempt/$((max_retries + 1))"
    fi

    # Build prompt (initial or retry)
    local prompt_file
    if [[ "$attempt" -eq 1 ]]; then
      prompt_file="$(_build_task_prompt "$task_json")"
    else
      prompt_file="$(_build_retry_prompt "$task_json" "$prev_failure_type" "$prev_failure_output" "$prev_exit_code" "$attempt")"
    fi

    # Invoke Claude
    local claude_output_file
    claude_output_file="$(mktemp)"

    local claude_exit=0
    _invoke_claude "$prompt_file" "$claude_output_file" || claude_exit=$?
    rm -f "$prompt_file"

    # For max_turns failures, preserve partial work (no branch reset)
    if [[ "$claude_exit" -eq 2 ]]; then
      log_warn "Claude hit max turns for $task_id"
      prev_failure_type="max_turns"
      prev_failure_output=""
      prev_exit_code="$claude_exit"
      rm -f "$claude_output_file"
      continue
    fi

    # Agent error — non-zero exit that isn't max_turns
    if [[ "$claude_exit" -ne 0 ]]; then
      log_error "Claude exited with code $claude_exit for $task_id"
      prev_failure_type="agent_error"
      prev_failure_output="$(cat "$claude_output_file" 2>/dev/null || true)"
      prev_exit_code="$claude_exit"
      rm -f "$claude_output_file"
      continue
    fi

    rm -f "$claude_output_file"

    # Check if any changes were made (after confirming Claude exited 0)
    if git -C "$PROJECT_DIR" diff --quiet HEAD staging 2>/dev/null && \
       git -C "$PROJECT_DIR" diff --quiet 2>/dev/null && \
       git -C "$PROJECT_DIR" diff --cached --quiet 2>/dev/null; then
      log_warn "No changes detected for $task_id"
      prev_failure_type="no_changes"
      prev_failure_output=""
      prev_exit_code=0
      continue
    fi

    # Auto-fix (non-fatal)
    _run_auto_fix

    # Quality gate
    local quality_output_file
    quality_output_file="$(mktemp)"

    if _run_quality_gate "$quality_output_file"; then
      rm -f "$quality_output_file"
      log_success "Task $task_id completed successfully"
      TASK_OUTCOME="success"
      TASK_FAILURE_TYPE=""
      return 0
    fi

    # Quality gate failed
    prev_failure_type="quality_gate"
    prev_failure_output="$(cat "$quality_output_file" 2>/dev/null || true)"
    prev_exit_code=0
    rm -f "$quality_output_file"

    log_warn "Quality gate failed for $task_id (attempt $attempt)"
  done

  # All attempts exhausted
  log_error "Task $task_id failed after $attempt attempts (last failure: $prev_failure_type)"
  TASK_OUTCOME="failure"
  TASK_FAILURE_TYPE="$prev_failure_type"
  return 1
}
