# Factory Bugs — Follow-up Plan (2026-04-10)

This document captures bugs discovered while running the factory on
`outsidey` and the fixes — some already applied, others to implement
after the in-progress run finishes.

## Summary of Issues Found

The run on 2026-04-09 produced 3 failed tasks and 4 skipped tasks. On
investigation, two classes of failure emerged:

1. **Legitimate review failures** — the code review flagged real issues
   and the task had only one follow-up retry, not enough to fix
   multi-part findings (e.g. `onboard-photo-004` needed a new server
   action for form-data persistence; `migrate-001` needed dead-code
   removal plus test strengthening).
2. **Empty-PR bug** — `settings-001` and `retake-002` produced PRs with
   zero content. Branch reflogs showed only `style: auto-fix formatting
   and lint` commits and no `feat(...)` commit from the task agent. The
   reviewer approved based on reading files in the working tree, but
   the push sent only the committed auto-fix commits.

Additionally, from the run on 2026-04-08, the factory created duplicate
PRs (#42 auth-001, #43 auth-002, #44 onboard-photo-001) for tasks that
had already been merged via earlier PRs (#21, #26, #27). The user
manually closed them with "Superseded — branch already merged".

## Fixes Already Applied (commits on `dark-factory@main`)

### `4e9834b` and earlier — in-run fixes
- `run-factory.sh:183` — `local` used outside a function (fatal syntax
  error at top-level). Removed the keyword.

### `89f7276` — review retry scaling
- `orchestrator.sh` — review retry budget now scales with task
  complexity: complex → 3, standard → 2, simple → 1. Previously there
  was a single follow-up retry regardless of complexity, which was not
  enough for multi-part review findings on complex tasks.
- `task-runner.sh` — `run_task` now calls `check_usage_and_wait` before
  each retry attempt (not just at the start of the task), so long
  retry loops are still usage-budget-aware.

### `537d697` — empty-PR bug
- `task-runner.sh` — after Claude exits 0 and before `_run_auto_fix`,
  run `git add -A` (respects `.gitignore`) and commit everything as
  `feat(<task-id>): task implementation`. This captures untracked
  feature files that `git add -u` in auto-fix was silently dropping.
- Simplified the "no changes" check to a single `git diff --quiet
  HEAD staging` — after the safety-net commit, any real work is now
  committed, so a clean HEAD..staging diff means nothing happened.

## Remaining Bugs (implement after current run finishes)

### B1. Review reads working tree, not committed state — MEDIUM

**Symptom.** The review prompt tells Claude to run `git diff
staging...${branch}`, but the reviewer also has Read/Grep tools and
nothing in the prompt forbids reading uncommitted files. Before the
`537d697` fix, the reviewer would happily approve based on files the
task agent had created but not committed — the push then sent an
empty branch.

**Fix.** In `_build_review_prompt` (lib/code-review.sh), add an
explicit rule: *Only evaluate the committed diff. Do not Read files
directly from the working tree — if it is not in `git diff
staging...${branch}`, it does not exist.* Optionally, make
`review_task` `git stash push -u` before invoking Claude so the work
tree cannot mislead the reviewer, and `git stash pop` (or drop) after.

The `537d697` fix makes this less critical because work is now
committed before review, but it is still a latent integrity gap — a
reviewer that reads working tree state is not reviewing what will
land.

### B2. Dependency-PR rebase can silently drop all commits — HIGH

**Symptom.** In `orchestrator.sh`'s dependency-PR rebase loop
(`_wait_for_dependency_prs` → rebase branch), the auto-resolver takes
`--ours` for pipeline tracking files and does a 3-way merge for
`package.json`. It uses `git rebase --empty=drop`, so commits that
become empty after conflict resolution are silently dropped. If all
commits on the branch touch only auto-resolvable files (e.g. several
`style: auto-fix formatting and lint` commits), every commit drops and
the branch resets to staging's HEAD — then gets force-pushed, turning
a content-ful branch into an empty PR.

This is how `settings-001`'s remote branch ended up at the staging
HEAD SHA: the rebase dropped its 3 `style: auto-fix` commits (no
`feat` commit existed because of B/the empty-PR bug), and the resulting
empty branch was force-pushed.

**Fix.** Before `git push --force-with-lease` in the dep-PR rebase
path, verify `git diff --quiet origin/staging feat/<task-id>`. If the
branch is now empty (no diff from staging), **do not push** — the
branch's content has been lost. Log an error with the pre-rebase SHA
(already logged to reflog as "prior tip") and fail the dependency,
letting the orchestrator surface it as a blocker. A silent force-push
to an empty branch is strictly worse than failing loudly.

### B3. Quality gate runs on working tree, not HEAD — MEDIUM

**Symptom.** `pnpm quality` runs in `$PROJECT_DIR`, operating on the
working tree. If the task agent leaves uncommitted files, the tests in
them run and pass even though they will not be pushed. This was the
other half of the empty-PR bug: quality gate wrongly reported success.

**Fix.** After the `537d697` safety-net commit, the working tree and
HEAD should match — so this is mostly moot. But as a defensive
check, in `_run_quality_gate`, after the safety-net commit, assert
that `git status --porcelain` is empty (no untracked/unstaged) before
running the gate. Fail the task attempt if it isn't — that means
something got skipped by `git add -A` (e.g. a gitignored temp that
shouldn't be there), and we shouldn't pretend quality passed on state
that will not be pushed.

### B4. Duplicate PRs for already-merged tasks — HIGH

**Symptom.** On the 2026-04-08 run, the factory re-executed `auth-001`,
`auth-002`, and `onboard-photo-001` even though earlier runs had
already merged PRs for them (#21, #26, #27). New duplicate PRs (#42,
#43, #44) were created with identical content and the user had to
close them manually. The root cause is that `check_resume` only looks
at `status.log` from the *single most recent* log directory — if
that directory is missing, or the user ran with `FACTORY_RESUME=f`, or
the status file doesn't mention a task, the factory re-runs it without
checking whether its work is already in `staging`.

**Fix.** Before starting each task in `execute_tasks`, check whether
the task's `feat(<task-id>):` commit message already exists in
`staging`'s history via `git log --grep "^feat(${task_id}):" staging
--max-count=1`. If it does, mark the task as already-done and skip.
Alternatively (more robust), check whether the files listed in
`tasks.json.[].files` already contain code matching the acceptance
criteria, but that's harder to automate — the commit-message check is
a good heuristic.

Also consider aggregating `status.log` across **all** prior log
directories, not just the most recent, to catch `ok` markers from
older runs.

### B5. `_create_feature_branch` destructive reset on rebase failure — MEDIUM

**Symptom.** In `task-runner.sh:_create_feature_branch`, when a rebase
onto staging fails, the branch is deleted and recreated from staging.
Any prior work (committed or not) is lost. This is partly a
convenience (clean slate for retry) and partly a bug (real review-retry
work can vanish). The `537d697` fix makes this less destructive because
work is committed before review, but a rebase that fails for
non-conflict reasons (e.g. lockfile issues) still nukes the branch.

**Fix.** Before resetting the branch, stash the `git diff HEAD` to a
named patch (e.g. `logs/<task-id>-rebase-rescue.patch`) so the work is
recoverable. Or: abort the rebase and keep the prior state, letting
the task retry build on top of the existing (non-rebased) branch —
staging drift will be handled via the review-retry loop.

## Immediate-State Cleanup Done (2026-04-10)

Before restarting the factory:

- Killed the usage-paused factory process (no active Claude work lost).
- Edited `20260409-072855/status.log` to mark `settings-001=failed`
  (was `ok`) so the resume re-attempts it.
- Deleted empty `origin/feat/settings-001` branch (was at staging SHA,
  caused by bug B2).
- Deleted `origin/feat/onboard-photo-004` and closed PR #52 so the
  fresh 3-retry attempt builds from a clean branch.
- Removed the killed run's empty log directory so resume picks up
  `20260409-072855` correctly.
- Verified the staging tasks.json still has `complexity=complex` for
  the 3 failed tasks (from commit `outsidey@0260be5`).

## Run Plan

1. Restart factory with `FACTORY_RESUME=r`.
2. It should re-attempt: `onboard-photo-004`, `migrate-001`,
   `retake-002`, `settings-001`, then the now-unblocked
   `dash-003`, `migrate-002`, `settings-002`, `settings-003`.
3. The remaining stale PRs (#35 auth-005, #38 onboard-002, #41
   quiz-003, #55 landing-003, #56 pref-002) are not on any task's
   dependency path, so the factory will not touch them in this run.
   They need a separate cleanup pass (manual `gh pr update-branch` +
   force-CI or close/re-run).
