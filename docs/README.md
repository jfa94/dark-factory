<!-- last-documented: 80c750b9ce21478eb09ec9caf162895e9abc7fef -->

# Dark Factory Documentation

Dark Factory is an autonomous coding pipeline that transforms GitHub issues into merged pull requests. Point it at a Product Requirements Document (PRD) issue, and it generates specs, breaks work into tasks, executes each task via Claude AI, reviews the output, creates PRs, and auto-merges when all checks pass.

## What Problem It Solves

Software development involves repetitive cycles: read requirements, write code, run tests, fix failures, create PRs, wait for review, merge. Dark Factory automates this loop for well-defined features, freeing humans for design decisions and edge-case handling while AI handles implementation grunt work.

## Who It's For

- Teams with clear, spec-driven development workflows
- Projects that use Claude Code CLI and GitHub for version control
- Developers who want to offload routine implementation work

## Design Philosophy

- **Spec-first**: Nothing runs until the PRD becomes a validated spec with a dependency-sorted task graph
- **Dependency-aware**: Tasks wait for upstream work to merge before starting
- **Fresh-context review**: Code reviews run in isolated sessions with only the diff, not the implementation context
- **Circuit-breaker safety**: Hard limits on tasks, runtime, consecutive failures, and API usage prevent runaway execution
- **Non-destructive defaults**: Failed runs leave worktrees and logs intact for debugging

## Table of Contents

### Getting Started

- [Getting Started](./getting-started.md) - Install prerequisites and run your first pipeline

### Architecture

- [Overview](./architecture/overview.md) - System context and main execution flow
- [Components](./architecture/components.md) - Module breakdown and responsibilities

### How-To Guides

- [Processing a PRD Issue](./guides/processing-prd.md) - Run the pipeline against a GitHub issue
- [Discovering Multiple PRDs](./guides/discover-prds.md) - Process all open PRD issues
- [Resuming a Failed Run](./guides/resuming.md) - Continue from where a prior run stopped

### Reference

- [CLI Options](./reference/cli.md) - Command-line arguments and modes
- [Environment Variables](./reference/environment.md) - Tuning pipeline behavior
- [Deployed Configs](./reference/deployed-configs.md) - Quality gate, mutation testing, dependency rules
- [Task JSON Schema](./reference/task-schema.md) - Structure of tasks.json files

### Glossary

- [Glossary](./glossary.md) - Domain and technical terms
