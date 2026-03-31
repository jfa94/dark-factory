# Spec: Modular Pipeline - Lock, Settings & Config Deployment

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

11. Deploy quality-gate CI workflow to target `.github/workflows/` if missing
12. Deploy `.stryker.config.json` to target if missing and has `package.json`
13. Deploy `.dependency-cruiser.cjs` to target if missing and has `package.json`
14. Existing target config files never overwritten
15. Inject autonomous settings into target `settings.json` at startup
16. Restore original settings on exit (success, failure, or interrupt)
17. Settings backup stored in target project (not factory repo)
18. Prevent concurrent runs on same project via lock
19. Stale locks auto-detected and reclaimed
20. Clear error message for active lock (includes PID)

---

## What to build

Safety infrastructure that protects against concurrent runs (directory-based locks with stale detection), manages Claude settings (swap factory settings in, restore originals on any exit), and deploys factory-owned configuration files to target projects without overwriting customizations.

### Acceptance criteria

- [ ] `acquire_lock()` creates a directory-based lock derived from target project path
- [ ] `mkdir` used for atomic lock creation (POSIX guarantee)
- [ ] Lock contains PID of owning process
- [ ] Second concurrent run on same project gets error with blocking PID
- [ ] Stale locks (PID no longer alive) automatically reclaimed
- [ ] `release_lock()` removes lock directory
- [ ] `swap_settings()` copies `settings.autonomous.json` from factory into target `.claude/settings.json`
- [ ] Original `settings.json` backed up in target project (e.g., `settings.json.bak`)
- [ ] `restore_settings()` reverses the swap (backup → original)
- [ ] Settings restored on normal exit, `set -e` failure, SIGINT, and SIGTERM (trap handler)
- [ ] Lock released in same trap handler as settings restore
- [ ] `deploy_factory_configs()` copies `quality-gate.yml` to target `.github/workflows/` if missing
- [ ] `.stryker.config.json` deployed only when target has `package.json` and file is missing
- [ ] `.dependency-cruiser.cjs` deployed only when target has `package.json` and file is missing
- [ ] Existing config files in target never overwritten
- [ ] `run-factory.sh` wired: validate → deploy configs → acquire lock → swap settings (with trap)

### Technical constraints

- [ ] Lock path must be deterministic from project directory (so different terminals detect same lock)
- [ ] Trap handler must clean up both settings and lock (order: restore settings first, then release lock)
- [ ] `--skip-settings-swap` flag must bypass settings swap (for child processes in parallel mode)
- [ ] Config deployment must create `.github/workflows/` directory if it doesn't exist

### Out of scope

- [ ] The content of factory-owned config files (these are static files, not generated — content will be authored during implementation based on current pipeline behavior)
- [ ] Settings for specific Claude permissions (content of `settings.autonomous.json` authored during implementation)

### Files to create/modify

- [ ] `lib/lock.sh`
- [ ] `lib/settings.sh`
- [ ] `lib/config-deployer.sh`
- [ ] `settings.autonomous.json`
- [ ] `quality-gate.yml`
- [ ] `.stryker.config.json`
- [ ] `.dependency-cruiser.cjs`
- [ ] `run-factory.sh` (modify — wire lock, settings, config deployment into orchestration flow)
