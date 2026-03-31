# Spec: Modular Pipeline - Multi-PRD Processing

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

79. `--discover` finds all open `[PRD]` issues in project's GitHub repo
80. Choose sequential or parallel processing for multiple PRDs
81. Parallel: parent sets up staging + deploys workflow before spawning workers
82. Workers run in isolated worktrees with `--skip-settings-swap`
83. Failed worktrees preserved with cleanup instructions
84. Successful worktrees cleaned up automatically
85. Single PRD with `--discover` proceeds directly (no mode prompt)

---

## What to build

A discovery and dispatch system that finds open PRD issues, presents execution options (sequential/parallel), and manages worktree-based parallel execution with proper lifecycle handling. After this phase, `run-factory.sh ~/project --discover` can batch-process multiple PRDs.

### Acceptance criteria

- [ ] `discover_and_process_prds()` exported as module's public interface
- [ ] Discovers open issues with `[PRD]` in title via `gh issue list --search "[PRD] in:title" --state open`
- [ ] No PRDs found → clear message and exit
- [ ] Single PRD found → proceed directly to processing (no sequential/parallel prompt)
- [ ] Multiple PRDs found → prompt user to choose sequential or parallel
- [ ] `sequential_execution()`: processes PRDs one at a time through the standard pipeline flow
- [ ] `parallel_worktree_execution()`: each PRD gets its own git worktree
- [ ] Parent process sets up staging branch and deploys quality-gate workflow before spawning workers
- [ ] Workers invoked with `--skip-settings-swap` flag (parent manages settings)
- [ ] Workers invoked with the worktree path as project directory
- [ ] Failed worktrees preserved on disk with message: path + cleanup command
- [ ] Successful worktrees removed automatically (`git worktree remove`)
- [ ] Workers run as background processes; parent waits for all to complete

### Technical constraints

- [ ] Worktrees created via `git worktree add` in the target project
- [ ] Each worker is a separate invocation of `run-factory.sh` (not a function call) to get process isolation
- [ ] Parent must `trap` to clean up workers on interrupt
- [ ] Worktree paths must be deterministic (e.g., `.worktrees/<issue-slug>`)

### Out of scope

- [ ] Cross-PRD dependency management (each PRD is independent)
- [ ] Shared staging reconciliation between parallel workers (each worker manages its own branching)
- [ ] Load balancing or prioritization across PRDs

### Files to create/modify

- [ ] `lib/multi-prd.sh`
- [ ] `run-factory.sh` (modify — wire discover mode routing)
