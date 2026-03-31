#!/usr/bin/env bash
set -euo pipefail

# Task graph validation and topological sorting.
# Only dependency: jq.

# --- Public interface ---

# Validate that every task in tasks.json has required fields,
# no dangling dependency references, and no circular dependencies.
# Reports ALL errors (not fail-fast).
validate_tasks() {
  local tasks_file="$1"
  local errors=()

  if [[ ! -f "$tasks_file" ]]; then
    log_error "Tasks file not found: $tasks_file"
    return 1
  fi

  if ! jq empty "$tasks_file" 2>/dev/null; then
    log_error "Invalid JSON: $tasks_file"
    return 1
  fi

  # Check required fields on every task
  local field_errors
  field_errors="$(jq -r '
    [.[] | {
      id: .task_id,
      missing: (
        [
          (if .task_id         == null or .task_id         == "" then "task_id"             else empty end),
          (if .title            == null or .title            == "" then "title"              else empty end),
          (if .depends_on       == null                           then "depends_on"          else empty end),
          (if .acceptance_criteria == null                        then "acceptance_criteria"  else empty end)
        ]
      )
    } | select(.missing | length > 0)]
    | .[]
    | "Task \(.id // "(no task_id)"): missing \(.missing | join(", "))"
  ' "$tasks_file")"

  if [[ -n "$field_errors" ]]; then
    while IFS= read -r line; do
      errors+=("$line")
    done <<< "$field_errors"
  fi

  # Collect all task_ids
  local all_ids
  all_ids="$(jq -r '.[].task_id // empty' "$tasks_file")"

  # Check for dangling dependency references
  local dangling
  dangling="$(jq -r '
    ([ .[].task_id ] | map(select(. != null))) as $ids |
    .[] |
    .task_id as $tid |
    (.depends_on // [])[] |
    select(. as $dep | $ids | index($dep) | not) |
    "Task \($tid): depends on non-existent task \(.)"
  ' "$tasks_file")"

  if [[ -n "$dangling" ]]; then
    while IFS= read -r line; do
      errors+=("$line")
    done <<< "$dangling"
  fi

  # Check for circular dependencies
  local cycles
  cycles="$(jq -r '
    # Build adjacency: task_id -> depends_on
    (reduce .[] as $t ({}; . + {($t.task_id): ($t.depends_on // [])})) as $adj |

    # All task IDs
    ([ .[].task_id ] | map(select(. != null))) as $ids |

    # DFS cycle detection
    # State: visited (set of fully processed), path (current DFS stack)
    # Returns array of cycle descriptions
    def detect_cycles:
      { visited: [], path: [], cycles: [] } as $init |
      reduce $ids[] as $node ($init;
        if (.visited | index($node)) then .
        else
          # DFS from $node
          . as $state |
          { stack: [[$node, 0]], visited: $state.visited, path: $state.path, cycles: $state.cycles } |
          until(.stack | length == 0;
            .stack[-1] as [$cur, $idx] |
            if $idx == 0 then
              # First visit to this node
              if (.visited | index($cur)) then
                .stack |= .[:-1]
              elif (.path | index($cur)) then
                # Found cycle: extract from $cur onwards in path
                (.path | index($cur)) as $ci |
                .cycles += [(.path[$ci:] + [$cur] | join(" -> "))] |
                .stack |= .[:-1]
              else
                .path += [$cur] |
                .stack[-1][1] = 1 |
                ($adj[$cur] // []) as $deps |
                reduce ($deps | reverse)[] as $dep (.; .stack += [[$dep, 0]])
              end
            else
              # Backtrack
              .path |= .[:-1] |
              .visited += [$cur] |
              .stack |= .[:-1]
            end
          ) |
          { visited: .visited, path: .path, cycles: .cycles }
        end
      ) |
      .cycles;

    detect_cycles | .[] | "Circular dependency: \(.)"
  ' "$tasks_file")"

  if [[ -n "$cycles" ]]; then
    while IFS= read -r line; do
      errors+=("$line")
    done <<< "$cycles"
  fi

  # Report all errors
  if [[ ${#errors[@]} -gt 0 ]]; then
    log_error "Task validation failed (${#errors[@]} errors):"
    for err in "${errors[@]}"; do
      log_error "  - $err"
    done
    return 1
  fi

  log_success "Task validation passed"
  return 0
}

# Return task_ids in valid topological execution order.
# Implemented as a single jq expression with recursive function.
topological_sort() {
  local tasks_file="$1"

  jq -r '
    # Build adjacency map: task_id -> depends_on
    (reduce .[] as $t ({}; . + {($t.task_id): ($t.depends_on // [])})) as $adj |

    # All task IDs
    [ .[].task_id ] | map(select(. != null)) |

    # Kahn-style topological sort via recursive function
    . as $all |
    (reduce .[] as $id ({}; . + {($id): ($adj[$id] | length)})) as $in_degree |

    def topo_sort($remaining; $in_deg):
      if ($remaining | length) == 0 then []
      else
        # Find all nodes with in-degree 0 among remaining
        ([ $remaining[] | select($in_deg[.] == 0) ] | sort) as $ready |
        if ($ready | length) == 0 then
          error("Cycle detected during topological sort")
        else
          # Remove ready nodes, decrement in-degree of dependents
          ($remaining | map(select(. as $r | $ready | index($r) | not))) as $next_remaining |
          (reduce $next_remaining[] as $node ($in_deg;
            reduce ($adj[$node] // [])[] as $dep (.;
              # Only decrement if dep was in $ready
              if ($ready | index($dep)) then
                .[$node] = (.[$node] - 1)
              else .
              end
            )
          )) as $next_deg |
          $ready + topo_sort($next_remaining; $next_deg)
        end
      end;

    topo_sort($all; $in_degree) | .[]
  ' "$tasks_file"
}
