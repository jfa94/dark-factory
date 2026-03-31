#!/usr/bin/env bash
set -euo pipefail

# Ensure progress-tracking scaffolding files exist in the target project.
# Missing files are created via a background Claude session.

# --- Internal helpers ---

# Build a prompt for Claude to create missing scaffolding files.
_build_scaffolding_prompt() {
  local missing_files=("$@")
  local prompt_file
  prompt_file="$(mktemp)"

  cat <<'HEADER' > "$prompt_file"
Create the following missing scaffolding files in the project root.
Each file must be created exactly as described below.

HEADER

  for file in "${missing_files[@]}"; do
    case "$file" in
      claude-progress.json)
        cat <<'SCHEMA' >> "$prompt_file"
## claude-progress.json

Create a JSON file tracking agent sessions and project state. Schema:

```json
{
  "project_state": "initializing",
  "sessions": [],
  "last_updated": "",
  "tasks_completed": [],
  "tasks_failed": [],
  "current_task": null
}
```

- `project_state`: one of "initializing", "in_progress", "completed", "failed"
- `sessions`: array of { session_id, task_id, started_at, ended_at, outcome }
- `last_updated`: ISO 8601 timestamp
- `tasks_completed`: array of completed task_ids
- `tasks_failed`: array of failed task_ids
- `current_task`: task_id currently being worked on, or null

SCHEMA
        ;;
      feature-status.json)
        cat <<'SCHEMA' >> "$prompt_file"
## feature-status.json

Create a JSON file tracking acceptance criteria pass/fail status. Schema:

```json
{
  "feature": "",
  "spec_slug": "",
  "criteria": [],
  "last_updated": ""
}
```

- `feature`: human-readable feature name
- `spec_slug`: spec directory slug
- `criteria`: array of { criterion, status, task_id, verified_at }
  - `status`: one of "pending", "pass", "fail"
- `last_updated`: ISO 8601 timestamp

SCHEMA
        ;;
      init.sh)
        cat <<'SCHEMA' >> "$prompt_file"
## init.sh

Create an executable shell script (chmod +x) that:

1. Installs project dependencies (detect package manager: pnpm/npm/yarn via lockfile)
2. Starts the dev server in the background (if a dev script exists in package.json)
3. Runs a basic smoke test (check that the dev server responds, or run the test suite)

The script should:
- Use #!/usr/bin/env bash and set -euo pipefail
- Be idempotent (safe to run multiple times)
- Log what it's doing at each step
- Exit 0 on success, non-zero on failure

SCHEMA
        ;;
    esac
  done

  printf '%s' "$prompt_file"
}

# --- Public interface ---

# Check for required scaffolding files; create any missing ones via Claude.
ensure_scaffolding() {
  log_info "Checking scaffolding files"

  local scaffolding_files=("claude-progress.json" "feature-status.json" "init.sh")
  local missing=()

  for file in "${scaffolding_files[@]}"; do
    if [[ ! -f "$PROJECT_DIR/$file" ]]; then
      missing+=("$file")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log_success "All scaffolding files present"
    return 0
  fi

  log_info "Missing scaffolding: ${missing[*]}"

  local prompt_file
  prompt_file="$(_build_scaffolding_prompt "${missing[@]}")"

  log_info "Creating scaffolding files via Claude"

  claude --print --model sonnet --max-turns 10 \
    -C "$PROJECT_DIR" \
    -p "$(cat "$prompt_file")" \
    > /dev/null 2>&1 &
  spin $! || {
    log_error "Scaffolding creation failed"
    rm -f "$prompt_file"
    return 1
  }

  rm -f "$prompt_file"

  # Verify files were created
  local still_missing=()
  for file in "${missing[@]}"; do
    if [[ ! -f "$PROJECT_DIR/$file" ]]; then
      still_missing+=("$file")
    fi
  done

  if [[ ${#still_missing[@]} -gt 0 ]]; then
    log_error "Scaffolding files still missing after creation: ${still_missing[*]}"
    return 1
  fi

  # Ensure init.sh is executable
  if [[ -f "$PROJECT_DIR/init.sh" ]]; then
    chmod +x "$PROJECT_DIR/init.sh"
  fi

  log_success "Scaffolding files created"
}
