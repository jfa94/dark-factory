# Spec: Modular Pipeline - Repository Setup, Scaffolding & Task Validation

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

29. Auto-create staging branch from develop (or main if no develop)
30. Reconcile staging with develop before task execution
31. Branch protection on staging (quality, mutation, security checks)
32. Staging reconciliation aborts cleanly on merge conflicts
33. Create develop from main if it doesn't exist
34. Detect and create missing scaffolding files via Claude
35. `claude-progress.json` tracks session history and project state
36. `feature-status.json` tracks acceptance criteria pass/fail
37. `init.sh` installs deps, starts dev server, runs smoke test
38. Validate required fields in `tasks.json`
39. Detect and reject circular dependencies
40. Detect dangling dependency references
41. Execute tasks in topological order
42. Commit spec directory to staging before task execution

---

## What to build

Branch management that sets up the develop/staging branching model with reconciliation, project scaffolding that ensures progress-tracking files exist, and task graph validation that catches structural problems before execution. After this phase, the pipeline can prepare a project for task execution: branches ready, scaffolding in place, tasks validated and ordered.

### Acceptance criteria

- [ ] `setup_staging()` creates `develop` from `main` if develop doesn't exist
- [ ] `setup_staging()` creates `staging` from `develop` (or `main` if no `develop`)
- [ ] `reconcile_staging_with_develop()` fast-forwards staging when possible
- [ ] Falls back to merge when fast-forward not possible
- [ ] Merge conflicts detected and abort cleanly — no dirty repo state left
- [ ] Conflict abort message names the conflicting branches
- [ ] `safe_checkout_staging()` handles clean branch switching
- [ ] Branch protection set on staging via `gh` CLI (require quality, mutation, security checks)
- [ ] `ensure_scaffolding()` checks for `claude-progress.json`, `feature-status.json`, `init.sh`
- [ ] Missing scaffolding files created via Claude session
- [ ] `claude-progress.json` schema: tracks agent sessions and project state
- [ ] `feature-status.json` schema: tracks acceptance criteria with pass/fail status
- [ ] `init.sh` installs dependencies, starts dev server, runs smoke test
- [ ] `validate_tasks()` checks every task has: `task_id`, `title`, `depends_on`, `acceptance_criteria`
- [ ] Reports all validation errors (not just first)
- [ ] Circular dependencies detected with list of tasks in cycle
- [ ] Dangling dependency references detected (depends_on referencing non-existent task_id)
- [ ] `topological_sort()` returns tasks in valid execution order
- [ ] Topological sort implemented as single `jq` expression with recursive function
- [ ] Spec directory committed to staging before task execution begins
- [ ] All operations run against the target project directory (not the factory repo)

### Technical constraints

- [ ] Branch operations use `git -C "$PROJECT_DIR"` to operate on target
- [ ] Branch protection requires repo admin access (document this prerequisite)
- [ ] Scaffolding Claude session runs in background with spinner
- [ ] `jq` is the only dependency for task validation/sorting

### Out of scope

- [ ] Task execution itself (phase 5)
- [ ] Code review (phase 6)
- [ ] Circuit breakers (phase 7)

### Files to create/modify

- [ ] `lib/repository.sh`
- [ ] `lib/scaffolding.sh`
- [ ] `lib/task-validator.sh`
- [ ] `run-factory.sh` (modify — wire repo setup, scaffolding, task validation into flow)
