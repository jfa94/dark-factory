# CLI Reference

## Synopsis

```bash
./run-factory.sh <project-dir> [options]
```

## Arguments

| Argument | Description |
|----------|-------------|
| `<project-dir>` | Path to the target project (resolved to absolute path) |

## Modes

Exactly one mode must be specified (except interactive, which is the default when no mode is given).

### --issue N

Process a specific GitHub PRD issue.

```bash
./run-factory.sh ~/my-project --issue 42
```

Workflow:
1. Fetch issue #N title and body from GitHub
2. Generate spec via Claude (prd-to-spec skill)
3. Review spec for quality (threshold: 48/60)
4. Execute tasks in dependency order
5. Code review and PR creation

### --discover

Find and process all open PRD issues.

```bash
./run-factory.sh ~/my-project --discover
```

Searches for issues with `[PRD]` in the title. For multiple issues, prompts for sequential or parallel execution.

Parallel mode creates a git worktree per PRD for isolated execution.

### spec-name (positional)

Process an existing spec by name.

```bash
./run-factory.sh ~/my-project user-authentication
```

Requires `specs/features/<spec-name>/tasks.json` to exist. Skips spec generation.

### --help, -h

Display help message.

```bash
./run-factory.sh --help
```

## Options

| Option | Description |
|--------|-------------|
| `--skip-lock` | Skip lock acquisition (used by internal recursive calls in parallel mode) |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success: all tasks completed and PRs merged |
| 1 | Failure: validation error, circuit breaker tripped, or tasks failed |

## Examples

### Basic Usage

```bash
# Process a PRD issue
./run-factory.sh ~/my-project --issue 42

# Discover all PRD issues
./run-factory.sh ~/my-project --discover

# Run existing spec
./run-factory.sh ~/my-project user-authentication
```

### With Environment Variables

```bash
# More turns for spec generation
SPEC_GEN_TURNS=100 ./run-factory.sh ~/my-project --issue 42

# Disable code review for faster iteration
ENABLE_CODE_REVIEW=0 ./run-factory.sh ~/my-project --issue 15

# Lower circuit breakers for a quick test
MAX_TASKS=5 MAX_RUNTIME_MINUTES=60 ./run-factory.sh ~/my-project --issue 7

# Higher spec quality threshold
SPEC_PASS_THRESHOLD=52 ./run-factory.sh ~/my-project --issue 42
```

### Error Handling

If a prior run exists for the same spec, the pipeline prompts:

```
Prior run detected: /path/to/project/logs/user-auth/20240101-120000
  3 task(s) completed in prior run

Choose:
  [r] Resume - skip completed tasks, continue from where it left off
  [f] Fresh  - start over from scratch

  Enter choice (r/f): 
```

Choosing `r` skips completed tasks and restores the PR URL mapping for dependency chains.
