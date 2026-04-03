# Discovering Multiple PRDs

Process all open PRD issues in a repository.

## Finding PRD Issues

```bash
./run-factory.sh ~/my-project --discover
```

The pipeline searches for open issues with `[PRD]` in the title:

```
[INFO]    Searching for open PRD issues in org/repo
[INFO]    Found 3 open PRD issue(s):
[INFO]      #42  [PRD] User Authentication Flow
[INFO]      #45  [PRD] Payment Integration
[INFO]      #48  [PRD] Email Notifications
```

## Single PRD

If only one PRD issue exists, it processes immediately:

```
[INFO]    Single PRD found - proceeding directly
```

## Multiple PRDs

For multiple issues, choose an execution strategy:

```
Choose execution strategy:
  [s] Sequential - one at a time (safer, uses less resources)
  [p] Parallel   - each PRD in its own worktree (faster)

  Enter choice (s/p):
```

### Sequential Execution

Processes each PRD one after another using the same working directory:

```
[INFO]    Processing PRD 1/3: issue #42
... full pipeline for #42 ...
[SUCCESS] PRD #42 completed

[INFO]    Processing PRD 2/3: issue #45
... full pipeline for #45 ...
[SUCCESS] PRD #45 completed

[INFO]    Processing PRD 3/3: issue #48
... full pipeline for #48 ...
[SUCCESS] PRD #48 completed
```

Pros:
- Lower resource usage
- Simpler to debug
- PRDs don't compete for API quota

Cons:
- Slower total execution time
- A blocking PRD delays all subsequent PRDs

### Parallel Execution

Creates a git worktree per PRD for isolated execution:

```
[INFO]    Creating worktree for #42: /path/to/project/.worktrees/user-authentication
[INFO]    Creating worktree for #45: /path/to/project/.worktrees/payment-integration
[INFO]    Creating worktree for #48: /path/to/project/.worktrees/email-notifications

[INFO]    Spawned 3 workers - waiting for completion

[SUCCESS] PRD #42 completed - removing worktree
[SUCCESS] PRD #45 completed - removing worktree
[SUCCESS] PRD #48 completed - removing worktree

[SUCCESS] All 3 PRDs completed successfully
```

Pros:
- Faster total execution time
- PRDs execute independently
- Failures don't block other PRDs

Cons:
- Higher resource usage (CPU, disk)
- May hit API rate limits faster
- Worktrees consume disk space

## Worktree Management

### Location

Worktrees are created at:

```
your-project/.worktrees/<slug>/
```

### Successful Completion

Worktrees are automatically removed when a PRD completes successfully.

### Failed PRDs

Worktrees for failed PRDs are preserved for debugging:

```
[ERROR]   PRD #45 failed
[ERROR]     Worktree preserved: /path/to/project/.worktrees/payment-integration
[ERROR]     Cleanup: git -C "/path/to/project" worktree remove "/path/to/project/.worktrees/payment-integration" --force
```

### Manual Cleanup

Remove all worktrees:

```bash
git -C ~/my-project worktree prune
rm -rf ~/my-project/.worktrees
```

## Error Handling

### Partial Success

If some PRDs fail:

```
[ERROR]   1/3 PRDs failed - worktrees preserved on disk
```

The pipeline exits with status 1. Completed PRDs are fully processed; failed PRDs have worktrees preserved.

### Interrupt Handling

Ctrl+C during parallel execution terminates all workers:

```
[WARN]    Interrupt received - terminating workers
```

Workers are killed, but worktrees remain for inspection.

## Best Practices

### When to Use Sequential

- First time running Dark Factory
- Debugging pipeline issues
- Tight API quota

### When to Use Parallel

- Large backlog of independent PRDs
- PRDs that don't modify overlapping files
- Sufficient API quota for concurrent execution

### PRD Independence

Parallel execution works best when PRDs don't modify the same files. If PRDs have overlapping scope, staging branch conflicts may occur when PRs attempt to merge.

### Rate Limit Awareness

With parallel execution, each worker monitors usage independently. The 5-hour and 7-day usage windows are shared across all workers. If utilization approaches the cap, all workers pause.
