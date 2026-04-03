# Dark Factory

An autonomous coding pipeline that turns GitHub issues into merged pull requests. It reads PRD (Product Requirements Document) issues, generates specs with task breakdowns, executes tasks via Claude AI, reviews the output, and manages PRs — all without human intervention.

## How it works

```
GitHub Issue (PRD)
        |
        v
  Spec Generation ──> tasks.json (validated, topologically sorted)
        |
        v
  ┌─────────────── Task Loop (dependency order) ───────────────┐
  │                                                             │
  │   Create feature branch from staging                        │
  │          |                                                  │
  │          v                                                  │
  │   Invoke Claude (model chosen by task complexity)           │
  │          |                                                  │
  │          v                                                  │
  │   Auto-fix (format + lint) ──> Quality gate (pnpm quality)  │
  │          |                                                  │
  │          v                                                  │
  │   Code review (separate Claude agent)                       │
  │          |                                                  │
  │          v                                                  │
  │   Create PR ──> Auto-merge on APPROVE                       │
  │          |                                                  │
  │          v                                                  │
  │   Wait for dependency PRs to merge before next task         │
  │                                                             │
  └─────────────────────────────────────────────────────────────┘
        |
        v
  Completion: summary, issue close, branch cleanup
```

### Retry logic

Failed tasks are retried up to 4 times with context-specific guidance injected into the prompt:

| Failure type | Retry strategy |
|---|---|
| `max_turns` | Continue from saved partial work |
| `quality_gate` | Show failing checks, guide fixes |
| `code_review` | Feed reviewer findings back |
| `agent_error` | Include git log and progress state |
| `no_changes` | Prompt to verify file paths |

### Circuit breakers

The pipeline stops gracefully when any threshold is hit:

- **Task count** — max tasks executed (default: 20)
- **Runtime** — max elapsed time (default: 360 min)
- **Consecutive failures** — max failures in a row (default: 3)
- **API usage** — hard cap at 90% of rate window

### Complexity-based model routing

Tasks declare a complexity level that maps to a Claude model and turn budget:

| Complexity | Model | Max turns |
|---|---|---|
| `simple` | Haiku | 40 |
| `standard` | Sonnet | 60 |
| `complex` | Opus | 80 |

## Prerequisites

### System dependencies

- **Bash 4+** — `brew install bash` on macOS
- **git** — version control
- **[gh](https://cli.github.com/)** — GitHub CLI (authenticated)
- **[jq](https://jqlang.github.io/jq/)** — JSON processing
- **[claude](https://docs.anthropic.com/en/docs/claude-code)** — Claude Code CLI (authenticated)

### Target project requirements

The project you point Dark Factory at must have:

```
your-project/
  .claude/
    CLAUDE.md                     # Project instructions for Claude
    settings.json                 # Claude Code settings
    agents/                       # Custom agent definitions
    skills/prd-to-spec/           # Skill for PRD-to-spec conversion
  .git/
    config (with remote)          # GitHub remote for PR/issue access
```

## Usage

```bash
./run-factory.sh <project-dir> [options]
```

### Modes

```bash
# Process a specific GitHub PRD issue
./run-factory.sh ~/my-project --issue 42

# Discover and process all open [PRD]-tagged issues
./run-factory.sh ~/my-project --discover

# Process an existing spec by name
./run-factory.sh ~/my-project user-authentication

# Interactive spec selection
./run-factory.sh ~/my-project

# Show help
./run-factory.sh --help
```

### Options

| Option | Description |
|---|---|
| `--issue N` | Process GitHub issue #N as a PRD |
| `--discover` | Find and process all open `[PRD]`-tagged issues |
| `--skip-settings-swap` | Don't inject autonomous settings into target project |
| `--help`, `-h` | Show help |

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `SPEC_GEN_TURNS` | `60` | Claude turns for spec generation |
| `SPEC_PASS_THRESHOLD` | `48` | Minimum spec review score (out of 60) |
| `MAX_SPEC_ITERATIONS` | `3` | Spec review retry limit |
| `ENABLE_CODE_REVIEW` | `1` | Enable/disable code review phase |
| `REVIEW_TURNS` | `30` | Claude turns for code review |
| `MAX_TASKS` | `20` | Max tasks before circuit breaker trips |
| `MAX_RUNTIME_MINUTES` | `360` | Pipeline timeout |
| `MAX_CONSECUTIVE_FAILURES` | `3` | Consecutive failure circuit breaker |
| `MAX_TASK_RETRIES` | `4` | Per-task retry limit |
| `USAGE_HARD_CAP_PCT` | `90` | API usage pause threshold (%) |
| `USAGE_POLL_INTERVAL` | `60` | Usage check interval (seconds) |

### Examples

```bash
# Process issue with more spec generation budget
SPEC_GEN_TURNS=80 ./run-factory.sh ~/my-project --issue 42

# Disable code review phase for faster iteration
ENABLE_CODE_REVIEW=0 ./run-factory.sh ~/my-project --issue 15

# Lower circuit breaker thresholds for a quick test run
MAX_TASKS=5 MAX_RUNTIME_MINUTES=60 ./run-factory.sh ~/my-project --issue 7
```

## Architecture

Dark Factory is ~3,700 lines of Bash across 16 modules, all sourced (not subshelled) to share state.

```
run-factory.sh          Entry point — sources modules, parses args, routes to mode
lib/
  cli.sh                Argument parsing and mode resolution
  validator.sh          Target project prerequisite checks
  utils.sh              Logging, slug generation, temp files, PID tracking
  lock.sh               Directory-based project locking with stale PID detection
  settings.sh           Backup/inject/restore autonomous Claude settings
  config-deployer.sh    Deploy quality gate, mutation testing, dependency cruiser configs
  spec-gen.sh           Fetch PRD from GitHub, invoke Claude for spec generation, review loop
  task-validator.sh     JSON validation, dependency graph checks, circular dependency detection, topological sort
  repository.sh         Branch management (staging/develop setup, reconciliation, protection)
  scaffolding.sh        Progress tracking files (claude-progress.json, feature-status.json)
  task-runner.sh        Task execution: branch creation, Claude invocation, quality gate, retry
  code-review.sh        Invoke code-reviewer agent, parse verdicts (APPROVE/REQUEST_CHANGES/NEEDS_DISCUSSION)
  orchestrator.sh       Main loop: task ordering, circuit breakers, dependency waiting, PR merge coordination
  completion.sh         Resume detection, summary, issue management, PR merge polling, cleanup
  usage.sh              API usage monitoring, rate-limit detection, hourly pause logic
  multi-prd.sh          Multi-PRD discovery, sequential/parallel execution via worktrees
```

### Key design decisions

- **Pure Bash** — no runtime dependencies beyond standard CLI tools
- **Module sourcing** — all modules share a single process for state continuity
- **Spec-first workflow** — PRDs become specs become `tasks.json` before any code runs
- **Dependency-aware execution** — task graph is topologically sorted; tasks wait for upstream PR merges
- **Fresh-context review** — code reviews run in isolated agent sessions with only the diff
- **Non-fatal defaults** — usage checks, config deployment, and settings swap fail gracefully
- **Guaranteed cleanup** — `EXIT` trap restores settings, releases locks, kills background processes

### Branch strategy

```
main
  └── develop
        └── staging (branch protection)
              ├── feat/task-01-setup-auth
              ├── feat/task-02-user-model
              └── feat/task-03-api-routes
```

Each task creates a feature branch from `staging`, opens a PR back to `staging`, and auto-merges on approval.

### Configs deployed to target projects

Dark Factory deploys these configs to the target project if they don't already exist:

- `templates/settings.autonomous.json` — Claude Code settings with autonomous permissions and safety hooks
- `templates/quality-gate.yml` — GitHub Actions workflow (tests, lint, format, typecheck, mutation testing)
- `templates/.stryker.config.json` — Mutation testing config
- `templates/.dependency-cruiser.cjs` — Dependency graph validation

### Safety guardrails

The autonomous settings (`settings.autonomous.json`) include hooks that:

- **Block access** to `.claude/` directory
- **Block edits** on `main`/`master` branches
- **Block edits** to `.env`, migration, and secrets files
- **Block dangerous commands** (`rm -rf`, `DROP TABLE`, `chmod 777`, piped curls)
- **Detect secrets** in staged changes before commit
- **Run type-check + lint** before every commit
- **Auto-format** files after every edit
- **Run related tests** after every file change
- **Run full test suite** when Claude stops (stop gate)

## Resume support

If a prior run exists for the same spec, Dark Factory prompts:

```
Prior run detected. Resume [r] or Fresh [f]?
```

Resuming skips completed tasks and restores the PR URL mapping so dependency chains continue correctly.

## Documentation

Full documentation is available in [`/docs`](./docs/README.md):

- [Getting Started](./docs/getting-started.md) - Installation and first run
- [Architecture](./docs/architecture/overview.md) - System design and execution flow
- [CLI Reference](./docs/reference/cli.md) - Command-line options
- [Environment Variables](./docs/reference/environment.md) - Configuration tuning
- [Glossary](./docs/glossary.md) - Domain and technical terms
