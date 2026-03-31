#!/usr/bin/env bash
set -euo pipefail

# Shared variables set by parse_args
MODE=""
ISSUE_NUMBER=""
SPEC_NAME=""
SKIP_SETTINGS_SWAP=0
PROJECT_DIR=""

show_help() {
  cat <<'EOF'
Usage: run-factory.sh <project-dir> [options]

Modular Autonomous Coding Pipeline — runs spec generation, task execution,
code review, and PR management against a target project.

Modes:
  --issue N              Process a specific GitHub PRD issue
  --discover             Find and process all open PRD issues
  <spec-name>            Process an existing spec by name
  (no mode flag)         Interactive spec selection

Options:
  --skip-settings-swap   Skip injecting autonomous settings into target project
  --help, -h             Show this help message

Prerequisites (in target project):
  .claude/CLAUDE.md          Project instructions for Claude
  .claude/settings.json      Claude Code settings
  .claude/agents/            Custom agent definitions
  .claude/skills/prd-to-spec/  PRD-to-spec skill

  git remote configured      For PR creation and issue access

Environment variables:
  SPEC_GEN_TURNS             Claude turns for spec generation (default: 60)
  SPEC_PASS_THRESHOLD        Spec review quality threshold (default: 48/60)
  MAX_SPEC_ITERATIONS        Spec review retry limit (default: 3)
  ENABLE_CODE_REVIEW         Enable code review phase (default: 1)
  REVIEW_TURNS               Claude turns for code review (default: 30)
  MAX_TASKS                  Maximum parallel tasks (default: 4)
  MAX_RUNTIME_MINUTES        Pipeline timeout in minutes (default: 120)
  MAX_CONSECUTIVE_FAILURES   Circuit breaker threshold (default: 3)
EOF
}

parse_args() {
  # Handle --help anywhere in args
  for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
      MODE="help"
      return 0
    fi
  done

  if [[ $# -eq 0 ]]; then
    log_error "Missing project directory"
    printf '\nRun: run-factory.sh --help\n' >&2
    exit 1
  fi

  PROJECT_DIR="$1"
  shift

  if [[ ! -d "$PROJECT_DIR" ]]; then
    log_error "Project directory does not exist: $PROJECT_DIR"
    exit 1
  fi

  # Resolve to absolute path
  PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

  # Parse remaining arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue)
        if [[ -n "$MODE" ]]; then
          log_error "Conflicting mode: already set to '$MODE', got --issue"
          exit 1
        fi
        if [[ $# -lt 2 || "$2" =~ ^-- ]]; then
          log_error "--issue requires a number"
          exit 1
        fi
        MODE="issue"
        ISSUE_NUMBER="$2"
        shift 2
        ;;
      --discover)
        if [[ -n "$MODE" ]]; then
          log_error "Conflicting mode: already set to '$MODE', got --discover"
          exit 1
        fi
        MODE="discover"
        shift
        ;;
      --skip-settings-swap)
        SKIP_SETTINGS_SWAP=1
        shift
        ;;
      -*)
        log_error "Unknown option: $1"
        printf '\nRun: run-factory.sh --help\n' >&2
        exit 1
        ;;
      *)
        if [[ -n "$MODE" ]]; then
          log_error "Conflicting mode: already set to '$MODE', got spec name '$1'"
          exit 1
        fi
        MODE="spec"
        SPEC_NAME="$1"
        shift
        ;;
    esac
  done

  # Default to interactive mode if no mode was set
  if [[ -z "$MODE" ]]; then
    MODE="interactive"
  fi
}
