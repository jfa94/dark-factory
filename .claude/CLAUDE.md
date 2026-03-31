# Global Context

## Role & Communication Style

- In all interactions and commit messages, be concise and sacrifice grammar for the sake of concision
- Push back on flawed logic or problematic approaches

## Commands

- Quality gate (all checks): `pnpm quality`
- Build: `pnpm build`
- Test: `pnpm test`
- Test with coverage: `pnpm test:coverage`
- Type-check: `pnpm typecheck`
- Lint: `pnpm lint`
- Format: `pnpm format`
- Dependency validation: `pnpm deps:validate`
- Mutation testing: `pnpm test:mutation`

## When Planning

- Present multiple options with trade-offs when they exist, without defaulting to agreement
- Call out edge cases and how we should handle them
- Ask clarifying questions rather than making assumptions
- Never plan to drop a database table
- At the end of each plan, give me a list of unresolved questions to answer, if any. Make the questions extremely concise

## When Implementing (after alignment)

- If you discover an unforeseen issue, stop and discuss
- Never drop a database table
- Run `pnpm quality` before declaring any task complete

## Testing Requirements

- Write tests for all new features unless explicitly told not to. Tests should cover both happy path and edge cases for new functionality
- NEVER delete or modify existing tests to make them pass
- When tests fail, fix the IMPLEMENTATION, not the test
- NEVER hardcode return values to satisfy specific test inputs
- NEVER write fallback code that silently degrades functionality
- Tests must be independent — no shared mutable state
- For functions with broad input domains, use property-based testing (fast-check) to catch edge cases that example-based tests miss

## Coding Standards

- Store API keys in environment files (e.g. `.env`) only, never in code

# Stack-Specific Guidelines

## Frontend

Frontend-specific guidelines (tech stack, React, Tailwind, Next.js conventions) are in `frontend.md` (same directory)

## Backend

Backend-specific guidelines (language, runtime) are in `backend.md` (same directory)
