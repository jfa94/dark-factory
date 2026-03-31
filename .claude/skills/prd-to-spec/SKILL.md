---
name: prd-to-spec
description: Turn a PRD into a list of feature specs by creating a multi-phase implementation plan using tracer-bullet vertical slices.
The output is a list of Markdown and JSON files in `specs/features/`.
Use when user wants to break down a PRD, create an implementation plan, plan phases from a PRD, or mentions "tracer bullets".
---

# PRD to Spec

Turn a PRD into a list of feature specs by first creating a multi-phase implementation plan using tracer-bullet vertical slices.
The output is a list of Markdown files in `specs/features/`.

## Process

### 1. Find the PRD

First, check for open GitHub issues tagged with `[PRD]` in the title:

```bash
gh issue list --search "[PRD] in:title" --state open
```

- **Multiple issues found:** present the list and ask the user which one to implement
- **One issue found:** use it directly — fetch the full body with `gh issue view <number>`
- **No issues found:** ask the user to paste the PRD or point you to the file/issue

### 2. Explore the codebase

If you have not already explored the codebase, do so to understand the current architecture, existing patterns, and integration layers.

### 3. Identify durable architectural decisions

Before slicing, identify high-level decisions that are unlikely to change throughout implementation:

- Route structures / URL patterns
- Database schema shape
- Key data models
- Authentication / authorization approach
- Third-party service boundaries

These go in the plan header so every phase can reference them.

### 4. Draft vertical slices

Break the PRD into **tracer bullet** phases. Each phase is a thin vertical slice that cuts through ALL integration
layers end-to-end, NOT a horizontal slice of one layer.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
- Do NOT include specific file names, function names, or implementation details that are likely to change as later phases are built
- DO include durable decisions: route paths, schema shapes, data model names
</vertical-slice-rules>

### 5. Quiz the user

Present the proposed breakdown as a numbered list. For each phase show:

- **Title:** short descriptive name
- **User stories covered:** which user stories from the PRD this addresses

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Should any phases be merged or split further?

Iterate until the user approves the breakdown.

### 6. Write the spec files

Create `specs/features/` and the relevant subdirectory (e.g., `specs/features/user-onboarding`) if it doesn't exist.
Write a spec for each phase as a Markdown file in the directory (e.g., `specs/features/user-onboarding/user-authentication.md`). Use the template below.

<spec-template>
# Spec: <Feature Name> - <Spec Name>

> Source PRD: <brief identifier or link>

## Architectural decisions

Durable decisions that apply across all phases:

- **Routes**: ...
- **Schema**: ...
- **Key models**: ...
- (add/remove sections as appropriate)

---

## User stories

**User stories**: <list from PRD>

---

## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation.

### Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3
- [ ] ...

### Technical Constraints

- [ ] Constraint 1
- [ ] Constraint 2
- [ ] Constraint 3
- [ ] ...

### Out of Scope

- [ ] Item 1 (reason for being out of scope)
- [ ] Item 2 (reason for being out of scope)
- [ ] Item 3 (reason for being out of scope)
- [ ] ...

### Files to Create/Modify

- [ ] path/to/file1.extension
- [ ] path/to/file2.extension
- [ ] path/to/file3.extension
- [ ] ...

</spec-template>

Key principles for good specs:

- **Be explicit about what's out of scope.** Expanding out of scope can be tempting. If you don't say "no OAuth," you might get OAuth.
- **State technical constraints as hard rules.** "No third-party auth libraries" is clearer than "prefer building from primitives."
- **Keep acceptance criteria testable.** Each criterion should map directly to one or more test cases. Vague criteria like "good user experience" give nothing to verify against.

### 7. Write metadata

If the PRD came from a GitHub issue (step 1), write a `metadata.json` in the same spec directory:

```json
{ "prd_issue": <issue-number> }
```

For example: `specs/features/user-onboarding/metadata.json`. Skip this file if the user pasted the PRD manually.

### 8. Create tasks

Ask the user if they would like to decompose the specs into agent-friendly tasks. If yes, decompose ALL specs into a single flat list of implementation tasks where each task:

1. is completable in under (approximately) 45 min
2. has clear acceptance criteria that map to specific test assertions
3. lists exact files to create or modify (max 3 files per task)
4. specifies which tests to write.

Tasks from later phases MUST list tasks from earlier phases in their `depends_on` array so the factory can execute them in the correct order.

Output the entire list as a single JSON array in ONE file called `tasks.json` in the feature directory (e.g., `specs/features/user-onboarding/tasks.json`). Do NOT create separate task files per spec — all tasks go in this one file. Fields: task_id, title, description, files, acceptance_criteria, tests_to_write, depends_on (array of task_ids).

```json
[
    {
        "task_id": "auth-001",
        "title": "Auth domain types and password hashing",
        "description": "Create auth type definitions and bcrypt-based password hashing utilities",
        "files": ["src/domain/auth/types.ts", "src/domain/auth/password.ts"],
        "acceptance_criteria": [
            "Password hash uses bcrypt with min 12 rounds",
            "Hash and verify functions are pure — no side effects",
            "Types cover User, Session, AuthError"
        ],
        "tests_to_write": [
            "password.test.ts: hash produces valid bcrypt string",
            "password.test.ts: verify returns true for correct password",
            "password.test.ts: verify returns false for wrong password",
            "password.test.ts: hash with <12 rounds throws"
        ],
        "depends_on": []
    },
    {
        "task_id": "auth-002",
        "title": "Email validation and registration logic",
        "description": "Create email validation in domain layer and registration service",
        "files": ["src/domain/auth/validation.ts", "src/services/auth.service.ts"],
        "acceptance_criteria": [
            "Email validation rejects malformed addresses",
            "Registration creates user with hashed password",
            "Duplicate email returns typed AuthError"
        ],
        "tests_to_write": [
            "validation.test.ts: valid emails pass",
            "validation.test.ts: malformed emails fail",
            "auth.service.test.ts: register creates user",
            "auth.service.test.ts: duplicate email returns error tuple"
        ],
        "depends_on": ["auth-001"]
    }
]
```
