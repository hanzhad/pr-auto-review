#!/usr/bin/env bash
# Daemon loop, fair multi-repo queue, and memory floor for auto-review (Issue 4.3).
#
# Provides global concurrency capping (MAX_CONCURRENCY=1), fair round-robin
# dispatch across adopted repositories, and memory floor protection.

MEMORY_FLOOR_MB="${AUTO_REVIEW_MEMORY_FLOOR_MB:-1500}"
DAEMON_LOCK_DIR="${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}"

# Ensure log function exists
type log >/dev/null 2>&1 || log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Checks whether available memory meets or exceeds the required floor.
# Returns 0 if memory is sufficient or cannot be inspected; returns 1 if below floor.
check_memory_floor() {
  local floor="${1:-$MEMORY_FLOOR_MB}"
  local meminfo="${2:-/proc/meminfo}"

  if [ ! -r "$meminfo" ]; then
    return 0
  fi

  local avail_kb avail_mb
  avail_kb="$(awk '/^MemAvailable:/ { print $2 }' "$meminfo" 2>/dev/null)"
  if [ -z "$avail_kb" ] || ! [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  avail_mb=$((avail_kb / 1024))
  if [ "$avail_mb" -lt "$floor" ]; then
    log "available memory (${avail_mb} MB) below floor (${floor} MB) — postponing review"
    return 1
  fi
  return 0
}

# Selects the next repository to review using a persistent state index.
# Usage: daemon_next_repo <state_file> <repo1> <repo2> ...
daemon_next_repo() {
  local state_file="$1"; shift
  local count=$#
  [ "$count" -gt 0 ] || return 1

  local idx=0
  if [ -f "$state_file" ]; then
    idx="$(cat "$state_file" 2>/dev/null || echo 0)"
    [[ "$idx" =~ ^[0-9]+$ ]] || idx=0
  fi

  local selected_idx=$((idx % count))
  local current=0 chosen=""
  for r in "$@"; do
    if [ "$current" -eq "$selected_idx" ]; then
      chosen="$r"
      break
    fi
    current=$((current + 1))
  done

  # Advance state index
  echo "$(( (selected_idx + 1) % count ))" >"$state_file" 2>/dev/null || true
  printf '%s\n' "$chosen"
}

# Executes a single tick in round-robin fashion across adopted repositories.
daemon_tick_once() {
  local reg_file="$1" state_file="$2"
  local -a repos=()

  # 1. Memory floor check
  if ! check_memory_floor "$MEMORY_FLOOR_MB"; then
    return 2
  fi

  # 2. Concurrency lock
  mkdir -p "$DAEMON_LOCK_DIR" 2>/dev/null || true
  local lock_file="$DAEMON_LOCK_DIR/daemon.lock"
  if ! ( set -o noclobber; echo "$$" > "$lock_file" ) 2>/dev/null; then
    # Lock held by an active tick
    return 3
  fi
  trap 'rm -f "$lock_file"' EXIT INT TERM

  # 3. Read enabled repositories
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    repos+=("$r")
  done < <(registry_list_enabled "$reg_file")

  if [ "${#repos[@]}" -eq 0 ]; then
    rm -f "$lock_file"
    return 0
  fi

  # 4. Pick next repo
  local repo
  repo="$(daemon_next_repo "$state_file" "${repos[@]}")"

  # 5. Run tick for selected repository
  log "daemon: dispatching tick for $repo"
  # Call tick (caller or main script provides cmd_tick / tick execution)
  if type run_repo_tick >/dev/null 2>&1; then
    run_repo_tick "$repo"
  fi

  rm -f "$lock_file"
  trap - EXIT INT TERM
  return 0
}
