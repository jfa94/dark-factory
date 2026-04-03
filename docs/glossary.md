# Glossary

## Domain Terms

### PRD (Product Requirements Document)

A GitHub issue with `[PRD]` in the title containing feature requirements. The pipeline transforms PRDs into specs, tasks, and ultimately merged code.

### Spec

A structured breakdown of a PRD into implementation details. Lives in `specs/features/<slug>/` and includes markdown documentation and a `tasks.json` file.

### Task

A unit of work extracted from a spec. Each task has acceptance criteria, test requirements, dependencies, and maps to a single feature branch and PR.

### Spec Slug

A filesystem-safe identifier derived from the PRD title. Example: `[PRD] User Authentication!` becomes `user-authentication`.

### Acceptance Criteria

Conditions that must be met for a task to be complete. Used in prompts to guide Claude and in reviews to verify correctness.

## Pipeline Terms

### Circuit Breaker

A safety mechanism that stops pipeline execution when a threshold is exceeded:
- Task count (`MAX_TASKS`)
- Runtime (`MAX_RUNTIME_MINUTES`)
- Consecutive failures (`MAX_CONSECUTIVE_FAILURES`)
- API usage (`USAGE_HARD_CAP_PCT`)

### Quality Gate

A CI check that must pass before code can merge. Includes typecheck, lint, test, mutation testing, dependency validation, and security scan.

### Auto-Fix

Post-Claude formatting and linting pass. Runs `pnpm format` and `pnpm lint:fix`, then commits any changes.

### Auto-Merge

GitHub's auto-merge feature enabled on PRs. Squash merges automatically when all required checks pass.

### Fresh-Context Review

A code review performed in an isolated Claude session that only sees the diff, not the implementation context. Prevents review bias from debugging history.

## Branch Terms

### Staging

Protected branch where feature PRs merge. Has branch protection requiring Quality Gate checks to pass.

### Feature Branch

A branch created for each task: `feat/<task-id>`. PRs from feature branches target staging.

### Develop

Intermediate branch between staging and main. Used for manual promotion after features stabilize.

## Technical Terms

### Turn

A single Claude interaction (prompt + response). Each task has a turn budget based on complexity (40-80 turns).

### Topological Sort

Ordering tasks so dependencies come before dependents. A task only starts after all its dependencies have merged.

### Worktree

A git worktree - a separate working directory sharing the same repository. Used for parallel PRD execution.

### Lock

A directory-based mutual exclusion mechanism preventing concurrent Dark Factory runs on the same project. Uses atomic `mkdir` with PID tracking.

## Model Terms

### Haiku

Anthropic's fastest, most economical Claude model. Used for simple tasks (40 turns).

### Sonnet

Anthropic's balanced Claude model. Default for standard tasks (60 turns) and code review (30 turns).

### Opus

Anthropic's most capable Claude model. Used for spec generation (80 turns) and complex tasks (80 turns).

## Verdict Terms

### APPROVE

Code review verdict indicating the implementation is acceptable. Triggers PR creation with auto-merge enabled.

### REQUEST_CHANGES

Code review verdict indicating issues must be fixed. The task is retried with review findings injected into the prompt.

### NEEDS_DISCUSSION

Code review verdict indicating human judgment is required. PR is created without auto-merge, and findings are posted as a comment.

## File Terms

### tasks.json

JSON file listing all tasks for a spec. Each task has task_id, title, description, complexity, files, acceptance_criteria, tests_to_write, and depends_on.

### claude-progress.json

Project-level file tracking agent sessions and task completion state. Claude updates this during execution.

### feature-status.json

Project-level file tracking acceptance criteria status per task.

### init.sh

Project-level script for environment setup: installs dependencies, starts dev server, runs smoke test.

### status.log

Per-run file recording task outcomes: `task_id=ok|failed|skipped` per line.

### pr-map.log

Per-run file mapping task IDs to PR numbers for resume support.
