# Spec: Modular Pipeline - Resume, Completion, Logging & Safety

> Source PRD: GitHub issue #1 — [PRD] Modular Autonomous Coding Pipeline

## Architectural decisions

Durable decisions that apply across all phases:

- **Entry point**: `run-factory.sh` is a thin orchestrator (~50 lines) that sources `lib/*.sh` and delegates
- **Module structure**: 15 modules in `lib/`, each a sourced file exporting functions. Modules communicate via shared variables and function calls
- **Strict mode**: All files use `set -euo pipefail`
- **Target project**: First positional arg is always the target project directory. The factory operates on it remotely
- **Factory-owned configs**: `settings.autonomous.json`, `quality-gate.yml`, `.stryker.config.json`, `.dependency-cruiser.cjs` live at repo root
- **Shell safety**: All dynamic content (PRD bodies, task descriptions) written to temp files with quoted heredocs. Never interpolated into command arguments
- **Background operations**: Long-running Claude sessions run in background; spinner in foreground; parent `wait`s
- **Topological sort**: Implemented in a single `jq` expression
- **Model routing**: Task complexity maps to model/turns — simple: Haiku/40, standard: default/60, complex: Opus/80

---

## User stories

86. Detect prior runs for same spec and offer to resume
87. Resumed runs skip completed tasks from status file
88. Resumed runs detect prior branch work and pass context to Claude
89. Summary at end: succeeded/failed/skipped counts + log directory
90. Close PRD issue with comment listing all PRs when all tasks succeed
91. Leave PRD issue open with per-task status comment when any tasks fail
92. Wait for all PRs to merge before cleanup
93. Delete local + remote feature branches after merge
94. Remove spec directory and commit removal to staging
95. Clean up log directory after successful completion
96. Kill all background Claude processes on exit (trap)
97. Clean up temp directory on exit (trap)
98. Prompt content via temp files with quoted heredocs (not inline)
99. Structured JSON log per task attempt + stderr log
100. Quality gate output logged per attempt
101. Code review output logged per attempt as JSON
102. Token usage logged per attempt (input + output, running total)
103. Status file: `task_id=ok|failed|skipped`
104. PR mapping file: `task_id=pr_number`
105. Spinner during long-running background operations

---

## What to build

The resume, completion, logging, and safety layers that wrap around the core pipeline. Resume detection allows interrupted runs to continue. Completion handles summary output, GitHub issue updates, and cleanup. Logging provides structured audit trails. Safety ensures clean process and temp file cleanup on any exit path. After this phase, the pipeline is fully operational end-to-end with proper observability and resilience.

### Acceptance criteria

**Resume:**
- [ ] Prior runs detected by checking for existing log directories matching the spec name
- [ ] User prompted to resume or start fresh when prior run detected
- [ ] Resumed runs read status file to identify completed tasks → skip them
- [ ] Resumed runs detect commits ahead of staging on `feat/<task-id>` branches → pass as context to Claude
- [ ] Resume integrates with orchestrator loop (pass "skip set" to `execute_tasks()`)

**Completion:**
- [ ] `print_summary()` shows counts: N succeeded, N failed, N skipped + log directory path
- [ ] All tasks succeeded → `gh issue close` with comment listing all PR URLs
- [ ] Any tasks failed/skipped → `gh issue comment` with per-task breakdown (status, PR number, failure reason), issue left open
- [ ] Pipeline waits for all PRs to merge before cleanup (poll `gh pr view`, reasonable timeout)
- [ ] After merge: local feature branches deleted (`git branch -d`)
- [ ] After merge: remote feature branches deleted (`git push --delete`)
- [ ] Spec directory (`specs/features/<slug>/`) removed and removal committed to staging
- [ ] Log directory cleaned up after successful completion

**Logging:**
- [ ] Log directory created per run: `logs/<spec-slug>/<timestamp>/`
- [ ] Each task attempt: `<task-id>-attempt-<n>.json` (Claude structured output)
- [ ] Each task attempt: `<task-id>-attempt-<n>.stderr.log` (stderr capture)
- [ ] Quality gate output: `<task-id>-attempt-<n>.quality.log`
- [ ] Code review output: `<task-id>-attempt-<n>.review.json`
- [ ] Token usage: `<task-id>-attempt-<n>.tokens.log` (input tokens, output tokens, running total)
- [ ] Status file: `status.log` with `task_id=ok|failed|skipped` per line
- [ ] PR mapping: `pr-map.log` with `task_id=pr_number` per line

**Safety:**
- [ ] Trap handler kills all background Claude processes on EXIT, SIGINT, SIGTERM
- [ ] Process cleanup uses process group or tracked PID list
- [ ] Temp directory (`mktemp -d`) created at startup, cleaned up in trap handler
- [ ] All prompt content written to temp files within this directory
- [ ] `spin()` function used for all long-running background operations (spec gen, task execution, code review)

### Technical constraints

- [ ] Log directory must be inside the target project (not the factory repo)
- [ ] Logs should be gitignored in the target project
- [ ] Status file format must be simple enough to parse with `grep`/`awk` (no JSON for status)
- [ ] Trap handler must be registered once in `run-factory.sh` and handle all cleanup (settings, lock, processes, temp)
- [ ] Background process tracking: maintain a PID array that the trap handler iterates

### Out of scope

- [ ] Web UI for log viewing
- [ ] Log aggregation or shipping to external services
- [ ] Automatic retry of failed PRs during cleanup wait

### Files to create/modify

- [ ] `lib/completion.sh`
- [ ] `lib/utils.sh` (modify — add logging infrastructure and temp dir management)
- [ ] `run-factory.sh` (modify — register unified trap handler, wire completion into flow)
