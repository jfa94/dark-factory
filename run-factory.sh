#!/usr/bin/env bash
set -euo pipefail

# --- Resolve FACTORY_DIR (portable, handles symlinks) ---

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
FACTORY_DIR="$(cd "$(dirname "$SOURCE")" && pwd -P)"

# --- Source modules ---

for module in "$FACTORY_DIR"/lib/*.sh; do
  # shellcheck source=/dev/null
  source "$module"
done

# --- Main ---

parse_args "$@"

if [[ "$MODE" == "help" ]]; then
  show_help
  exit 0
fi

validate_project "$PROJECT_DIR"

# TODO: Acquire lock (phase 2 — lib/lock.sh)
# TODO: Swap settings to autonomous mode (phase 2 — lib/settings.sh)
# TODO: Deploy factory configs to target project (phase 2 — lib/config-deployer.sh)

# TODO: Mode routing
# case "$MODE" in
#   issue)      ... ;;
#   discover)   ... ;;
#   spec)       ... ;;
#   interactive) ... ;;
# esac

# TODO: Summary and cleanup (phase 9)
