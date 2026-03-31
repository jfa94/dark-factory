# Spec: Modular Pipeline - CLI, Validation & Utilities

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

1. Run pipeline on specific PRD issue (`run-factory.sh ~/project --issue 5`)
2. Discover and process all open PRD issues (`run-factory.sh ~/project --discover`)
3. Run pipeline on existing spec by name (`run-factory.sh ~/project user-auth`)
4. Run pipeline without spec name for interactive selection
5. `--help` flag shows usage, modes, prerequisites, env vars
6. Tool available on PATH
7. Validate target project has required Claude config (`.claude/CLAUDE.md`, `.claude/settings.json`, `.claude/agents/`, `.claude/skills/prd-to-spec/`)
8. Verify target project has configured git remote
9. Validation errors list all missing prerequisites at once
10. Validation error suggests running `configure.sh`

---

## What to build

A runnable entry point that parses CLI arguments, validates the target project has all required prerequisites, and provides shared utility functions used by all downstream modules. After this phase, `run-factory.sh --help` works, and `run-factory.sh <project-path>` validates the project and reports all issues.

### Acceptance criteria

- [ ] `run-factory.sh --help` displays usage instructions, available modes, prerequisites, and configurable env vars
- [ ] `run-factory.sh ~/project --issue 5` sets MODE=issue, ISSUE_NUMBER=5, PROJECT_DIR
- [ ] `run-factory.sh ~/project --discover` sets MODE=discover
- [ ] `run-factory.sh ~/project user-auth` sets MODE=spec, SPEC_NAME=user-auth
- [ ] `run-factory.sh ~/project` with no spec name sets MODE=interactive
- [ ] Missing project dir argument prints error and usage hint
- [ ] Invalid/non-existent project dir prints clear error
- [ ] Validation checks all prerequisites: `.claude/` dir, `CLAUDE.md`, `settings.json`, `agents/`, `skills/prd-to-spec/`, git remote
- [ ] All validation errors collected and reported together (not fail-fast)
- [ ] Validation error message suggests running `configure.sh` to fix
- [ ] `slugify_title()` converts issue titles to filesystem-safe slugs (lowercase, hyphens, no special chars)
- [ ] `spin()` displays a spinner while a background PID runs
- [ ] Logging helpers provide consistent formatted output (info, warn, error, success)
- [ ] Entry point resolves FACTORY_DIR to its own directory
- [ ] Entry point sources all modules from `lib/`
- [ ] `set -euo pipefail` enforced in all files

### Technical constraints

- [ ] Bash only — no external dependencies beyond git, gh, jq, claude CLI
- [ ] Entry point must be executable and shebang'd with `#!/usr/bin/env bash`
- [ ] Modules sourced (not executed as subshells) to share state
- [ ] CLI module exports `parse_args()` setting shared variables: `MODE`, `ISSUE_NUMBER`, `SPEC_NAME`, `SKIP_SETTINGS_SWAP`, `PROJECT_DIR`

### Out of scope

- [ ] Lock acquisition (phase 2)
- [ ] Settings swap (phase 2)
- [ ] Config deployment (phase 2)
- [ ] Any pipeline execution logic — entry point stubs mode routing but delegates to not-yet-implemented modules

### Files to create/modify

- [ ] `run-factory.sh`
- [ ] `lib/cli.sh`
- [ ] `lib/validator.sh`
- [ ] `lib/utils.sh`
