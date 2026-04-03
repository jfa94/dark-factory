# Processing a PRD Issue

Run the full pipeline against a GitHub issue containing a Product Requirements Document.

## Prerequisites

1. Target project has required Claude configuration (see [Getting Started](../getting-started.md))
2. GitHub issue exists with `[PRD]` in the title
3. Issue body contains the PRD content

## Step 1: Invoke the Pipeline

```bash
./run-factory.sh ~/my-project --issue 42
```

The pipeline acquires a lock on the target project to prevent concurrent runs.

## Step 2: Branch Setup

The pipeline creates branches if they don't exist:

```
main
  └── develop
        └── staging
```

It then reconciles staging with develop (fast-forward or merge) and switches to staging.

## Step 3: Config Deployment

Factory configs are deployed if missing:

- `.github/workflows/quality-gate.yml`
- `.stryker.config.json`
- `.dependency-cruiser.cjs`
- `package.json` (scaffold scripts merged)

Committed to staging as "chore: deploy factory configs".

## Step 4: Spec Generation

The pipeline fetches the issue and invokes Claude to generate a spec:

```
[INFO]    Fetching PRD from issue #42
[INFO]    PRD: [PRD] User Authentication Flow
[INFO]    Running spec generation (max turns: 80)
```

Claude writes files to `specs/features/<slug>/`:
- Spec markdown files
- `tasks.json`

## Step 5: Spec Review

An automated review scores the spec (max 60 points):

```
[INFO]    Running spec review
[INFO]    Review score: 52/60 (threshold: 48/60)
[SUCCESS] Spec passed review
```

If below threshold, Claude fixes blocking issues and the review repeats (up to `MAX_SPEC_ITERATIONS` times).

## Step 6: Task Validation

The pipeline validates `tasks.json`:

- Required fields present
- No dangling dependency references
- No circular dependencies

Then topologically sorts tasks for execution order.

## Step 7: Task Execution

For each task in dependency order:

### 7a. Dependency Wait

If the task has dependencies, wait for their PRs to merge into staging.

### 7b. Branch Creation

```
[INFO]    Created branch feat/task-01-user-model from staging
```

### 7c. Claude Invocation

Claude receives a prompt with:
- Task title and description
- Acceptance criteria
- Files to modify
- Tests to write
- Orientation steps (read progress, run init.sh)

### 7d. Auto-Fix

After Claude completes:
```
[INFO]    Running auto-fix (format + lint)
```

### 7e. Quality Gate

```
[INFO]    Running quality gate
[SUCCESS] Quality gate passed
```

If failed, retries with the failing output injected into the prompt.

### 7f. Code Review

```
[INFO]    Starting code review for task-01-user-model
[INFO]    Review verdict: APPROVE
```

Verdicts:
- **APPROVE**: Create PR, enable auto-merge
- **REQUEST_CHANGES**: Retry task with findings
- **NEEDS_DISCUSSION**: Create PR without auto-merge, flag for human

### 7g. PR Creation

```
[SUCCESS] PR created: https://github.com/org/repo/pull/123
[SUCCESS] Auto-merge enabled
```

## Step 8: Completion

After all tasks:

```
=== Completion ===

[INFO]    ============================================
[INFO]    Pipeline Summary
[INFO]    ============================================
[SUCCESS] 3 succeeded
[INFO]    Logs: /path/to/project/logs/user-auth/20240101-120000
[INFO]    ============================================

[INFO]    Waiting for all PRs to merge
[SUCCESS] All PRs merged
[SUCCESS] Pipeline complete
```

The GitHub issue is closed with a comment listing all PR URLs.

## Troubleshooting

### Spec Generation Fails

```
[ERROR]   Spec generation failed after 2 attempts
```

Possible causes:
- PRD too vague or ambiguous
- Turn budget exhausted

Solutions:
- Increase `SPEC_GEN_TURNS`
- Clarify PRD content

### Spec Review Fails

```
[ERROR]   Spec review score below threshold after 3 iterations
```

The issue is labeled `needs-manual-spec` and requires human authoring.

### Task Retries Exhausted

```
[ERROR]   Task task-01 failed after 5 attempts (last failure: quality_gate)
```

Check logs at `logs/<spec>/<timestamp>/<task-id>-attempt-N.quality.log`.

### Circuit Breaker Tripped

```
[ERROR]   Runtime circuit breaker: 21600s elapsed (limit: 21600s)
```

Increase `MAX_RUNTIME_MINUTES` or split the PRD into smaller issues.

### Rate Limit

```
[WARN]    Claude is rate limited: resets 6pm (Europe/London)
[INFO]    Rate limit resets in ~45 minutes - sleeping
```

The pipeline automatically waits for the rate limit to clear.
