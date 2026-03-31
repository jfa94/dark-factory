# Spec: Modular Pipeline - Spec Generation & Review

> Source PRD: GitHub issue #1 — [PRD] Modular Autonomous Coding Pipeline

## Architectural decisions

Durable decisions that apply across all phases:

- **Entry point**: `run-factory.sh` is a thin orchestrator (~50 lines) that sources `lib/*.sh` and delegates
- **Module structure**: 15 modules in `lib/`, each a sourced file exporting functions. Modules communicate via shared variables and function calls
- **Strict mode**: All files use `set -euo pipefail`
- **Target project**: First positional arg is always the target project directory. The factory operates on it remotely
- **Factory-owned configs**: `settings.autonomous.json`, `quality-gate.yml`, `.stryker.config.json`, `.dependency-cruiser.cjs` live at repo root
- **Shell safety**: All dynamic content (PRD bodies, task descriptions) written to temp files with quoted heredocs. Never interpolated into command arguments
- **Background operations**: Long-running Claude sessions run in background; spinner in foreground; parent `wait`s
- **Topological sort**: Implemented in a single `jq` expression
- **Model routing**: Task complexity maps to model/turns — simple: Haiku/40, standard: default/60, complex: Opus/80

---

## User stories

21. Fetch PRD from GitHub issue and generate specs + `tasks.json` via Claude
22. Auto-review specs with configurable quality threshold (default 48/60)
23. Spec review iterates (fix → re-review) up to configurable max (default 3)
24. Skip spec generation if valid `tasks.json` already exists
25. Failed generation retries once with increased turn budget
26. Failed generation comments on issue and adds `needs-manual-spec` label
27. Guard against invalid output (empty/malformed/missing `tasks.json`)
28. Turn budget, threshold, max iterations configurable via env vars

---

## What to build

A spec generation pipeline that fetches a PRD from a GitHub issue, invokes Claude to produce vertical-slice specs and `tasks.json`, validates the output, runs an automated spec review loop, and handles all failure modes with clear feedback. After this phase, `run-factory.sh ~/project --issue 5` generates reviewed specs end-to-end.

### Acceptance criteria

- [ ] `generate_and_review_spec()` exported as module's public interface
- [ ] PRD body fetched from GitHub issue via `gh issue view`
- [ ] Issue title slugified for spec directory name (`specs/features/<slug>/`)
- [ ] Prompt written to temp file using quoted heredoc (no shell injection)
- [ ] Claude invoked with `prd-to-spec` skill to generate spec files + `tasks.json`
- [ ] Generation skipped if `specs/features/<slug>/tasks.json` already exists and is valid JSON
- [ ] Output validated: `tasks.json` file exists, is non-empty, is valid JSON
- [ ] Specific error messages for: missing file, empty file, malformed JSON
- [ ] Spec-reviewer agent invoked on generated output
- [ ] Review score compared against SPEC_PASS_THRESHOLD (default 48/60)
- [ ] Below threshold: blocking issues fixed and re-reviewed, up to MAX_SPEC_ITERATIONS (default 3)
- [ ] Failed generation retries once with increased SPEC_GEN_TURNS budget
- [ ] On final failure: `gh issue comment` with failure details and `gh issue edit --add-label needs-manual-spec`
- [ ] SPEC_GEN_TURNS, SPEC_PASS_THRESHOLD, MAX_SPEC_ITERATIONS read from environment with defaults
- [ ] Spinner displayed during Claude spec generation and review sessions
- [ ] Claude runs in background with spinner in foreground

### Technical constraints

- [ ] All Claude invocations use background process pattern (`cmd &` + `spin $!` + `wait`)
- [ ] Prompt must include the full PRD body and the `prd-to-spec` skill invocation
- [ ] `tasks.json` validation uses `jq` to parse (catches malformed JSON)
- [ ] Spec review invokes the target project's spec-reviewer agent (not a factory-local one)

### Out of scope

- [ ] Task execution — this phase only generates and reviews specs
- [ ] Repository branch setup (phase 4)
- [ ] Interactive spec selection (handled by CLI module's interactive mode)

### Files to create/modify

- [ ] `lib/spec-gen.sh`
- [ ] `run-factory.sh` (modify — wire spec generation into issue mode route)
