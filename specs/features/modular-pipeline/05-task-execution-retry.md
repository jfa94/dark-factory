# Spec: Modular Pipeline - Task Execution & Retry

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

43. Each task runs on isolated `feat/<task-id>` branch from staging
44. Claude orients before coding — reads progress files, git log, runs init.sh
45. Claude implements exactly one task per session
46. Commits with conventional format, updates progress files, leaves env clean
47. Task complexity determines model and turn budget
48. Auto-fix formatting/linting runs after Claude, before quality gate
49. Quality gate (`pnpm quality`) runs as first pass/fail gate
50. Failed tasks retry up to configurable max (default 4) with failure context
51. Retry context distinguishes failure types with type-specific guidance
52. Resumed tasks continue from prior state via progress files and git log
53. Max-turns tasks preserve partial work for retry
54. Time-based circuit breaker checked inside retry loop

---

## What to build

The single-task execution engine: creates an isolated branch, builds a context-rich prompt, invokes Claude with complexity-appropriate model/turns, runs auto-fix and quality gate, and retries failures with failure-type-specific context. After this phase, `run_task()` can execute any individual task through its full lifecycle including retries.

### Acceptance criteria

- [ ] `run_task()` exported as module's public interface
- [ ] Feature branch `feat/<task-id>` created from staging
- [ ] Claude prompt includes: task description, acceptance criteria, file list, test requirements
- [ ] Prompt instructs Claude to orient first: read `claude-progress.json`, check `git log`, run `init.sh`
- [ ] Prompt instructs exactly one task per session, conventional commits (`feat(scope): description`)
- [ ] Prompt instructs updating progress tracking files before stopping
- [ ] Task complexity field maps to model and turn budget: simple→Haiku/40, standard→default/60, complex→Opus/80
- [ ] Prompt written to temp file with quoted heredoc
- [ ] Claude runs in background with spinner in foreground
- [ ] Auto-fix runs after Claude finishes: formatting (`pnpm format`) then linting fix (`pnpm lint --fix`)
- [ ] Quality gate (`pnpm quality`) runs after auto-fix
- [ ] `run_task()` returns outcome (success/failure) and failure type
- [ ] Failure types: `max_turns`, `quality_gate`, `agent_error`, `no_changes`
- [ ] Failed tasks retry up to configurable max (default 4, via env var)
- [ ] Retry prompt includes previous failure context: quality output, exit code, failure type
- [ ] Type-specific retry guidance (e.g., max_turns gets "continue from where you left off", quality_gate gets exact failure output)
- [ ] Partial work preserved on branch for max_turns failures (no branch reset)
- [ ] Resumed tasks (from interrupted run) read `claude-progress.json` and `git log` to detect prior work
- [ ] Time-based circuit breaker checked before each retry attempt
- [ ] Retry context passed via temp file (not command args)

### Technical constraints

- [ ] Claude invoked via `claude` CLI with `--model`, `--max-turns`, and `--print` flags
- [ ] Background process pattern: `claude ... &`, `spin $!`, `wait $!`; capture exit code
- [ ] Auto-fix must not fail the task (errors from auto-fix are non-fatal)
- [ ] Quality gate exit code determines pass/fail

### Out of scope

- [ ] Code review (phase 6) — `run_task()` handles implementation only
- [ ] PR creation (phase 6)
- [ ] Orchestrator loop / dependency handling (phase 7)
- [ ] API usage checking (phase 7)

### Files to create/modify

- [ ] `lib/task-runner.sh`
