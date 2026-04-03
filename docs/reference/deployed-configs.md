# Deployed Configs

Dark Factory deploys configuration files to target projects to establish quality gates and safety hooks. Existing files are never overwritten.

## Quality Gate (GitHub Actions)

**Deployed to:** `.github/workflows/quality-gate.yml`

A CI workflow that runs on PRs to the staging branch:

### Jobs

| Job | Checks | Runs After |
|-----|--------|------------|
| Quality | typecheck, lint, test, deps:validate, audit | - |
| Security Scan | Semgrep SAST, TruffleHog secrets | Quality |
| Mutation Testing | Stryker mutation tests | Quality |
| Auto Merge | Squash merge when all checks pass | All |

### Required Scripts

The workflow expects these npm scripts in the target project's package.json:

```json
{
  "scripts": {
    "typecheck": "tsc --noEmit",
    "lint": "eslint . --max-warnings 0",
    "test": "vitest run",
    "deps:validate": "depcruise src --output-type err",
    "test:mutation": "stryker run"
  }
}
```

If your project is missing these scripts, Dark Factory merges them from `package.scaffold.json`.

## Mutation Testing (Stryker)

**Deployed to:** `.stryker.config.json`

Configuration for mutation testing with Vitest:

```json
{
  "testRunner": "vitest",
  "plugins": [
    "@stryker-mutator/vitest-runner",
    "@stryker-mutator/typescript-checker"
  ],
  "checkers": ["typescript"],
  "coverageAnalysis": "perTest",
  "thresholds": {"high": 80, "low": 60, "break": 60},
  "mutate": [
    "src/**/*.ts",
    "!src/**/*.test.ts",
    "!src/**/*.spec.ts",
    "!src/**/*.d.ts",
    "!src/**/types/**",
    "!src/**/index.ts",
    "!src/data/**"
  ],
  "incremental": true
}
```

The `break: 60` threshold fails the build if mutation score drops below 60%.

### Required Dependencies

```json
{
  "devDependencies": {
    "@stryker-mutator/core": "^9.0.0",
    "@stryker-mutator/vitest-runner": "^9.0.0",
    "@stryker-mutator/typescript-checker": "^9.0.0"
  }
}
```

## Dependency Cruiser

**Deployed to:** `.dependency-cruiser.cjs`

Enforces architectural constraints on the dependency graph:

### Rules

| Rule | Severity | Description |
|------|----------|-------------|
| no-circular | error | No circular dependencies |
| domain-no-infrastructure | error | Domain layer cannot depend on services/lib/app/components |
| components-no-services | error | Components cannot directly import services |
| not-to-test | error | Production code cannot import test files |
| not-to-dev-dep | error | Source files cannot import devDependencies |
| no-unresolvable | error | All imports must resolve |

### Required Dependencies

```json
{
  "devDependencies": {
    "dependency-cruiser": "^17.0.0"
  }
}
```

## Package Scaffold

**Merged into:** `package.json`

If the target project has a package.json, Dark Factory merges scripts and devDependencies from `templates/package.scaffold.json`:

### Scripts Added

```json
{
  "scripts": {
    "typecheck": "tsc --noEmit",
    "lint": "eslint . --max-warnings 0",
    "lint:fix": "eslint . --fix",
    "format": "prettier --write .",
    "format:check": "prettier --check .",
    "test": "vitest run",
    "test:watch": "vitest",
    "test:coverage": "vitest run --coverage",
    "test:mutation": "stryker run",
    "test:mutation:full": "stryker run --force",
    "deps:validate": "depcruise src --output-type err",
    "deps:graph": "depcruise src --include-only '^src' --output-type dot | dot -T svg > docs/dependency-graph.svg",
    "audit": "npm audit --audit-level=high --omit=dev",
    "quality": "pnpm typecheck && pnpm lint && pnpm format:check && pnpm test:coverage && pnpm deps:validate && pnpm audit && pnpm test:mutation"
  }
}
```

The `quality` script is what `pnpm quality` runs in the pipeline.

### DevDependencies Added

```json
{
  "devDependencies": {
    "vitest": "^4.1.2",
    "@vitest/coverage-v8": "^4.1.2",
    "@stryker-mutator/core": "^9.0.0",
    "@stryker-mutator/vitest-runner": "^9.0.0",
    "@stryker-mutator/typescript-checker": "^9.0.0",
    "dependency-cruiser": "^17.0.0"
  }
}
```

Existing scripts and devDependencies in the target package.json are preserved. Only missing entries are added.

## Autonomous Settings

**Applied via:** `--settings` flag on all Claude invocations

The `templates/settings.autonomous.json` file configures Claude Code behavior during autonomous execution:

### Permissions

**Allowed:**
- All standard tools (Read, Edit, Write, Glob, Grep, Bash)
- WebSearch
- Supabase MCP tools
- PostHog MCP tools

**Denied:**
- `rm -rf *`, `rm -r *`
- Access to `.claude/` directory (except `.claude/worktrees/`)
- `git push --force`, `git rebase`, `git reset --hard`, `git clean -f`
- `npx create-*` (scaffold generators)
- Destructive AWS operations

### Hooks

#### PreToolUse

| Trigger | Check |
|---------|-------|
| Glob, Grep, Read, Edit, Write | Block access to `.claude/` directory |
| Edit, Write | Block edits on main/master branches |
| Edit, Write | Block edits to `.env*`, `/secrets/`, applied migrations |
| execute_sql | Block DROP DATABASE, DROP SCHEMA, TRUNCATE, GRANT, REVOKE |
| Bash | Block dangerous patterns (rm -rf, DROP TABLE, chmod 777, piped curls) |
| Bash | Nudge toward native tools (cat -> Read, grep -> Grep, etc.) |
| Bash (git commit) | Run pre-commit checks (typecheck + lint + secrets detection) |
| Bash (git push) | Run quality checks before push |

#### PostToolUse

| Trigger | Action |
|---------|--------|
| Edit, Write | Auto-format with Prettier |
| Edit, Write (non-test .ts/.tsx) | Run related tests via Vitest |
| All tools | Append to `.claude/tool-audit.jsonl` |

#### Stop Gate

When Claude session ends, run the full test suite. If tests fail, exit with error to trigger retry.

## Gitignore Entries

Dark Factory appends these entries to `.gitignore` if not present:

```
logs/
.stryker-tmp/
.claude/settings.json
.claude/settings.autonomous.json
claude-progress.json
feature-status.json
```

The `claude-progress.json` and `feature-status.json` entries ensure these Claude-facing context files remain untracked working-tree artifacts. They persist on disk across branch switches (git ignores them) and must never be committed to avoid merge conflicts.
