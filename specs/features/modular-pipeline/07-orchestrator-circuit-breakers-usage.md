# Spec: Modular Pipeline - Orchestrator, Circuit Breakers & Usage Monitoring

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

66. Max task count circuit breaker (default 20)
67. Max runtime circuit breaker (default 360 min)
68. Consecutive failure circuit breaker (default 3)
69. All circuit breaker thresholds configurable via env vars
70. Check API usage before each task attempt and spec generation
71. Hourly threshold scaling within 5-hour window (20%/40%/60%/80%/90%)
72. Full pause at hard cap (default 90%), resume after window reset
73. Pause at hourly thresholds (max 30 min), resume at next window hour
74. OAuth token from macOS Keychain, graceful skip on failure
75. Dependency-failed/skipped tasks cause dependents to skip
76. Wait for dependency PRs to merge into staging (45-min timeout)
77. Detect cancelled auto-merge → early return
78. Pull latest staging after each dependency PR merge

---

## What to build

The main execution loop that ties everything together: iterates tasks in dependency order, invokes the task runner and code review for each, manages dependency-aware PR merge waiting, enforces circuit breakers, and throttles execution based on API usage. After this phase, the pipeline can execute a full spec end-to-end with all safety limits.

### Acceptance criteria

- [ ] `execute_tasks()` exported as orchestrator's public interface
- [ ] Tasks iterated in topological order (from phase 4's `topological_sort()`)
- [ ] Before each task: check if any dependency failed or was skipped → skip with message naming the blocking dependency
- [ ] Before each task: wait for dependency PRs to merge into staging (poll `gh pr view`)
- [ ] PR merge wait timeout: 45 minutes
- [ ] Cancelled auto-merge detected (checks failed on PR) → return early, don't wait full timeout
- [ ] After dependency PR merges: `git pull` latest staging
- [ ] Each task: invoke `run_task()` → if passes, invoke `review_task()` → create PR based on verdict
- [ ] Max task count circuit breaker: stops after N tasks execute (default 20, env var configurable)
- [ ] Max runtime circuit breaker: stops after N minutes (default 360, env var configurable)
- [ ] Consecutive failure circuit breaker: stops after N consecutive failures (default 3, env var configurable)
- [ ] Circuit breakers checked before each task attempt
- [ ] `check_usage_and_wait()` called before each task attempt and before spec generation
- [ ] OAuth token read from macOS Keychain via `security find-generic-password`
- [ ] Keychain read failure → gracefully skip usage checks (log warning, continue)
- [ ] API usage fetched from Anthropic OAuth API
- [ ] Hourly threshold scaling: 20% at hour 1, 40% at hour 2, 60% at hour 3, 80% at hour 4, 90% at hour 5
- [ ] Usage at hard cap (default 90%) → pause, poll until window resets, then resume
- [ ] Usage at hourly threshold → pause (max 30 min), resume when next window hour begins
- [ ] API call failure or parse failure → gracefully skip (log warning, continue)

### Technical constraints

- [ ] PR merge polling interval should be reasonable (e.g., 30 seconds) to avoid GitHub API rate limits
- [ ] Circuit breaker state tracked via simple counter variables (no external storage)
- [ ] Usage module must not crash the pipeline on any failure path (all errors → skip and continue)
- [ ] Runtime circuit breaker uses `$SECONDS` bash variable for elapsed time

### Out of scope

- [ ] Resume detection (phase 9) — orchestrator executes all tasks; resume logic wraps around it
- [ ] Summary and cleanup (phase 9)
- [ ] Multi-PRD dispatch (phase 8)

### Files to create/modify

- [ ] `lib/orchestrator.sh`
- [ ] `lib/usage.sh`
- [ ] `run-factory.sh` (modify — wire orchestrator into mode routing)
