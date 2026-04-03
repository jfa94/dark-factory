# Getting Started

Set up Dark Factory and run your first autonomous pipeline.

## Prerequisites

### System Dependencies

Install these tools before running Dark Factory:

| Tool | Purpose | Installation |
|------|---------|--------------|
| Bash 4+ | Associative arrays, `declare -g` | `brew install bash` (macOS) |
| git | Version control | System package manager |
| [gh](https://cli.github.com/) | GitHub CLI for PRs and issues | `brew install gh` |
| [jq](https://jqlang.github.io/jq/) | JSON processing | `brew install jq` |
| [claude](https://docs.anthropic.com/en/docs/claude-code) | Claude Code CLI | Anthropic installer |

Authenticate the GitHub CLI:

```bash
gh auth login
```

### Target Project Requirements

The project you point Dark Factory at needs:

```
your-project/
  .claude/
    CLAUDE.md                     # Project instructions for Claude
    settings.json                 # Claude Code settings (project or ~/.claude/)
    skills/prd-to-spec/           # Skill for PRD-to-spec conversion
  .git/
    config (with remote)          # GitHub remote for PR/issue access
```

The `prd-to-spec` skill can live in the target project or in `~/.claude/skills/`.

## Clone Dark Factory

```bash
git clone https://github.com/your-org/dark-factory.git
cd dark-factory
```

No build step required. Dark Factory is pure Bash.

## Run Your First Pipeline

### Option 1: Process a Specific PRD Issue

If you have a GitHub issue with `[PRD]` in the title:

```bash
./run-factory.sh ~/my-project --issue 42
```

This:
1. Fetches issue #42 from the project's GitHub repository
2. Generates a spec with task breakdown via Claude
3. Reviews the spec for quality (must score >= 48/60)
4. Creates feature branches and executes each task
5. Runs code review on completed work
6. Creates PRs and enables auto-merge

### Option 2: Discover and Process All PRD Issues

```bash
./run-factory.sh ~/my-project --discover
```

Finds all open issues with `[PRD]` in the title and offers sequential or parallel processing.

### Option 3: Run an Existing Spec

If a spec already exists at `specs/features/<name>/tasks.json`:

```bash
./run-factory.sh ~/my-project user-authentication
```

Skips spec generation and proceeds directly to task execution.

## Understanding the Output

During execution, you'll see:

```
=== Branch Setup ===
[INFO]    Setting up branches in /Users/you/my-project
[SUCCESS] Branches ready (develop + staging)

=== Spec Generation ===
[INFO]    Fetching PRD from issue #42
[INFO]    PRD: [PRD] User Authentication Flow
[INFO]    Running spec generation (max turns: 80)
  /
[SUCCESS] Spec generated successfully

=== Task Execution ===
[INFO]    Task 1/3: task-01-user-model
[INFO]    Created branch feat/task-01-user-model from staging
[INFO]    Running quality gate
[SUCCESS] Quality gate passed
```

Logs persist in `your-project/logs/<spec-slug>/<timestamp>/`.

## Next Steps

- [Processing a PRD Issue](./guides/processing-prd.md) - Detailed walkthrough
- [Environment Variables](./reference/environment.md) - Tune turn budgets, thresholds, circuit breakers
- [Architecture Overview](./architecture/overview.md) - Understand the execution flow
