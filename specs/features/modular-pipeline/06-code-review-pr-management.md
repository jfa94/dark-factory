# Spec: Modular Pipeline - Code Review & PR Management

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

55. Each task reviewed by separate Claude session (Sonnet) with fresh context
56. Review focuses on logic errors, edge cases, business logic, test assertions, AI anti-patterns — not formatting/naming/lint
57. Structured verdict: APPROVE, REQUEST_CHANGES, or NEEDS_DISCUSSION
58. REQUEST_CHANGES triggers retry with review findings
59. Follow-up reviews use stricter prompt (critical issues only)
60. Code review togglable via ENABLE_CODE_REVIEW, turn budget via REVIEW_TURNS
61. Each task produces PR against staging with structured body
62. Approved PRs get auto-merge enabled
63. NEEDS_DISCUSSION PRs skip auto-merge, get comment with findings
64. PR creation retries once on failure (5-second delay)
65. PR body written to temp file (no inline shell expansion)

---

## What to build

A fresh-context code review that produces structured verdicts driving PR behavior: auto-merge for approved work, retry for requested changes, and human-flagged PRs for discussion items. After this phase, completed tasks produce reviewed PRs with appropriate merge behavior.

### Acceptance criteria

- [ ] `review_task()` exported as code review module's public interface
- [ ] Review runs in separate Claude session using Sonnet model
- [ ] Review prompt specifies focus: logic errors, unhandled edge cases, incorrect business logic, weak test assertions, AI-specific anti-patterns
- [ ] Review prompt explicitly excludes: formatting, naming, lint violations
- [ ] Review prompt requests structured verdict output: `APPROVE`, `REQUEST_CHANGES`, or `NEEDS_DISCUSSION`
- [ ] Verdict parsed from Claude output (grep/pattern match)
- [ ] `REQUEST_CHANGES` triggers implementation retry with review findings passed as context
- [ ] Follow-up reviews (after REQUEST_CHANGES retry) use stricter prompt — only critical issues
- [ ] `ENABLE_CODE_REVIEW` env var toggles review on/off (default on)
- [ ] `REVIEW_TURNS` env var configures review turn budget
- [ ] Review runs in background with spinner
- [ ] PR created against staging using `gh pr create`
- [ ] PR body includes: task description, acceptance criteria, tests written, review findings
- [ ] PR body written to temp file, passed via `--body-file` (no shell expansion)
- [ ] `APPROVE` verdict → `gh pr merge --auto` enabled
- [ ] `NEEDS_DISCUSSION` verdict → no auto-merge, `gh pr comment` with review findings
- [ ] PR creation retries once on failure after 5-second delay
- [ ] `code_review` added as a failure type in task runner retry logic

### Technical constraints

- [ ] Review must use a completely fresh Claude context (no conversation continuity from implementation)
- [ ] Review prompt includes the full diff (`git diff staging...feat/<task-id>`)
- [ ] Verdict parsing must handle cases where Claude doesn't produce a clean verdict (default to NEEDS_DISCUSSION)
- [ ] PR body temp file cleaned up after creation

### Out of scope

- [ ] Orchestrator loop integration (phase 7) — this phase provides `review_task()` as a callable function
- [ ] Dependency-aware PR merge waiting (phase 7)
- [ ] Auto-merge monitoring / cancelled merge detection (phase 7)

### Files to create/modify

- [ ] `lib/code-review.sh`
- [ ] `lib/task-runner.sh` (modify — integrate `code_review` failure type into retry logic)
