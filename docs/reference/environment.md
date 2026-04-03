# Environment Variables

All environment variables have sensible defaults. Override them to tune pipeline behavior.

## Spec Generation

| Variable | Default | Description |
|----------|---------|-------------|
| `SPEC_GEN_TURNS` | `80` | Maximum Claude turns for spec generation |
| `SPEC_PASS_THRESHOLD` | `48` | Minimum spec review score (out of 60) to proceed |
| `MAX_SPEC_ITERATIONS` | `3` | Maximum spec review/fix cycles before failing |

Higher `SPEC_GEN_TURNS` allows more complex PRDs to complete but increases cost. The default (80) handles most features. Bump to 100+ for very large PRDs.

`SPEC_PASS_THRESHOLD` of 48/60 (80%) is the default quality bar. Lower for faster iteration; raise for stricter specs.

## Code Review

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_CODE_REVIEW` | `1` | Enable code review phase (set to 0 to skip) |
| `REVIEW_TURNS` | `30` | Maximum Claude turns for code review |

Disabling code review (`ENABLE_CODE_REVIEW=0`) skips the review step and creates PRs directly after quality gate. Useful for trusted specs or rapid prototyping.

## Task Execution

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_TASK_RETRIES` | `4` | Per-task retry limit (covers all failure types) |

Retries include max_turns, quality_gate, code_review, agent_error, and no_changes failures. Each retry injects context-specific guidance into the prompt.

## Circuit Breakers

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_TASKS` | `20` | Maximum tasks to execute before stopping |
| `MAX_RUNTIME_MINUTES` | `360` | Pipeline timeout in minutes (6 hours) |
| `MAX_CONSECUTIVE_FAILURES` | `3` | Stop after this many consecutive failures |

Circuit breakers prevent runaway execution. When tripped, the pipeline stops gracefully with a summary of completed work.

## API Usage Monitoring

| Variable | Default | Description |
|----------|---------|-------------|
| `USAGE_HARD_CAP_PCT` | `90` | Pause when API usage reaches this percentage |
| `USAGE_POLL_INTERVAL` | `300` | Seconds between usage checks during pause |

The pipeline monitors both 5-hour and 7-day usage windows. When utilization approaches the cap, execution pauses until the window resets.

Hourly pacing within the 5-hour window:
- Hour 1: 20% threshold
- Hour 2: 40% threshold
- Hour 3: 60% threshold
- Hour 4: 80% threshold
- Hour 5: 90% threshold

## Rate Limit Handling

| Variable | Default | Description |
|----------|---------|-------------|
| `RATE_LIMIT_MAX_WAIT` | `14400` | Maximum seconds to wait for rate limit reset (4 hours) |
| `RATE_LIMIT_POLL_INTERVAL` | `300` | Seconds between rate limit probes |

When Claude returns a rate limit error, the pipeline parses the reset time and waits. If parsing fails, it polls with a brief probe until the limit clears.

## PR Merge Waiting

| Variable | Default | Description |
|----------|---------|-------------|
| `PR_MERGE_TIMEOUT` | `2700` | Timeout for dependency PR merges (45 minutes) |
| `PR_MERGE_POLL_INTERVAL` | `30` | Seconds between PR state checks |
| `COMPLETION_PR_MERGE_TIMEOUT` | `3600` | Timeout for all PRs to merge at completion (60 minutes) |
| `COMPLETION_PR_POLL_INTERVAL` | `30` | Seconds between PR checks at completion |

Tasks with dependencies wait for upstream PRs to merge before starting. These timeouts prevent indefinite blocking when checks fail or reviews stall.

## Example Configurations

### Fast Iteration (Prototyping)

```bash
ENABLE_CODE_REVIEW=0 \
MAX_TASK_RETRIES=2 \
SPEC_PASS_THRESHOLD=40 \
./run-factory.sh ~/my-project --issue 42
```

### High Quality (Production)

```bash
SPEC_PASS_THRESHOLD=52 \
ENABLE_CODE_REVIEW=1 \
REVIEW_TURNS=40 \
./run-factory.sh ~/my-project --issue 42
```

### Large PRD

```bash
SPEC_GEN_TURNS=120 \
MAX_SPEC_ITERATIONS=5 \
MAX_TASKS=30 \
MAX_RUNTIME_MINUTES=480 \
./run-factory.sh ~/my-project --issue 42
```

### Quick Test Run

```bash
MAX_TASKS=3 \
MAX_RUNTIME_MINUTES=30 \
MAX_CONSECUTIVE_FAILURES=1 \
./run-factory.sh ~/my-project --issue 42
```
