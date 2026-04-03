# Resuming a Failed Run

Continue from where a prior run stopped.

## Resume Mechanism

The authoritative source for resume state is `status.log`, written deterministically by `write_status` in `lib/utils.sh`. Each line records `task_id=ok|failed|skipped`. The `check_resume` function in `completion.sh` reads this file to populate `_TASK_STATUS` before task execution begins.

Note: `claude-progress.json` is a Claude-facing context file that helps Claude understand prior work — it is **not** used for pipeline resume decisions.

## Detection

When a prior run exists for the same spec, the pipeline prompts:

```
[WARN]    Prior run detected: /path/to/project/logs/user-auth/20240101-120000
[INFO]      3 task(s) completed in prior run

Choose:
  [r] Resume - skip completed tasks, continue from where it left off
  [f] Fresh  - start over from scratch

  Enter choice (r/f):
```

## Resume Option

Choosing `r` (resume):

1. Marks completed tasks as "success" in the task status map
2. Restores PR URL mapping from `pr-map.log`
3. Skips completed tasks during execution
4. Continues with the first uncompleted task

```
[INFO]    Resuming from prior run
[INFO]    Resume: marking task-01-user-model as completed (skipping)
[INFO]    Resume: marking task-02-repository as completed (skipping)
[INFO]    Resume: marking task-03-api as completed (skipping)

=== Task Execution ===

=== Task 4/6: task-04-tests ===
[INFO]    Starting task: task-04-tests
```

## Fresh Option

Choosing `f` (fresh):

1. Creates a new log directory
2. Starts from the first task
3. Does not use any state from the prior run

Existing feature branches are reused and rebased onto current staging.

## What Gets Preserved

### Log Directory

Prior run logs are at:

```
logs/<spec-slug>/<timestamp>/
  status.log          # task_id=ok|failed|skipped per line
  pr-map.log          # task_id=pr_number per line
  spec-gen.log        # Spec generation output
  spec-review-N.log   # Spec review iterations
  task-id-attempt-N.json      # Claude output per attempt
  task-id-attempt-N.quality.log   # Quality gate output
  task-id-attempt-N.review.json   # Code review output
  task-id-attempt-N.tokens.log    # Token usage
```

### Feature Branches

Feature branches (`feat/<task-id>`) persist across runs. When a task is retried:

1. The branch is checked out
2. If behind staging, it's rebased
3. Claude continues from the existing commits

```
[INFO]    Branch feat/task-04-tests already exists - resuming
[INFO]    Rebasing feat/task-04-tests onto staging
```

### PR URL Mapping

`pr-map.log` maps task IDs to PR numbers:

```
task-01-user-model=123
task-02-repository=124
task-03-api=125
```

On resume, the pipeline uses these URLs for dependency waiting.

## When to Resume vs Fresh

### Resume When

- A transient error occurred (rate limit, API 500, network issue)
- Circuit breaker tripped but earlier tasks succeeded
- You want to continue from the last failed task

### Fresh When

- The spec changed since the prior run
- You modified tasks.json manually
- Earlier tasks produced incorrect results
- You want a clean slate

## Manual Intervention

### Checking Prior State

```bash
# See what completed
cat logs/user-auth/20240101-120000/status.log

# Output:
# task-01-user-model=ok
# task-02-repository=ok
# task-03-api=ok
# task-04-tests=failed
```

### Inspecting Failure Logs

```bash
# Quality gate failure
cat logs/user-auth/20240101-120000/task-04-tests-attempt-3.quality.log

# Code review findings
cat logs/user-auth/20240101-120000/task-04-tests-attempt-3.review.json
```

### Checking Feature Branch

```bash
cd ~/my-project
git checkout feat/task-04-tests
git log --oneline staging..HEAD
```

### Manually Fixing a Task

If you want to fix a task manually before resuming:

1. Check out the feature branch
2. Make your fixes
3. Commit
4. Run the pipeline - it will detect prior work and continue

```bash
cd ~/my-project
git checkout feat/task-04-tests
# ... make fixes ...
git commit -m "fix: address test failures"

# Run pipeline - will detect prior commits
./run-factory.sh ~/my-project user-auth
# Choose 'r' to resume
```

## Clearing Prior Runs

To force a completely fresh start:

```bash
# Remove all logs for a spec
rm -rf ~/my-project/logs/user-auth/

# Remove feature branches
git branch -D feat/task-01-user-model feat/task-02-repository ...

# Or delete all feat/* branches
git branch | grep 'feat/' | xargs git branch -D
```
