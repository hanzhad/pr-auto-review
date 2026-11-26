#!/usr/bin/env bash
# Which review runs next, and how many at once (upstream issue).
#
# Functions only. The machine tick (lib/machine-tick.sh) asks these; nothing
# here fetches, calls gh, or dies. Needs lib/registry.sh for the two settings.

# The next review to start. $1 = pending file ("<repo> <pr>" per line, a repo's
# lines oldest first), $2 = running file (one "<repo>" per review in flight),
# $3 = cursor file (the repo picked last), the rest are the enabled projects in
# registry order. Walks the projects starting after the cursor and takes the
# first with a pending PR and nothing running; when every one that has a pending
# PR is busy, the first of them. Prints "<repo> <pr>", takes that line out of
# the pending file and writes the repo to the cursor; rc 1 and nothing else
# changes when nothing is pending.
sched_pick() {
  local pending="$1" running="$2" cursor="$3"
  shift 3
  local n=$# i start=0 k repo cur="" chosen="" any="" pr tmp
  [ "$n" -gt 0 ] && [ -s "$pending" ] || return 1
  local repos=("$@")
  cur="$(head -n 1 "$cursor" 2>/dev/null || true)"
  if [ -n "$cur" ]; then
    for ((i = 0; i < n; i++)); do
      if [ "${repos[$i]}" = "$cur" ]; then
        start=$(((i + 1) % n))
        break
      fi
    done
  fi
  for ((k = 0; k < n; k++)); do
    repo="${repos[$(((start + k) % n))]}"
    awk -v r="$repo" '$1 == r { f = 1 } END { exit !f }' "$pending" || continue
    [ -n "$any" ] || any="$repo"
    if [ ! -s "$running" ] || ! grep -qxF -- "$repo" "$running"; then
      chosen="$repo"
      break
    fi
  done
  chosen="${chosen:-$any}"
  [ -n "$chosen" ] || return 1
  pr="$(awk -v r="$chosen" '$1 == r { print $2; exit }' "$pending")"
  tmp="$pending.$$"
  awk -v r="$chosen" '$1 == r && !d { d = 1; next } { print }' "$pending" >"$tmp" && cat "$tmp" >"$pending"
  rm -f "$tmp"
  printf '%s\n' "$chosen" >"$cursor"
  printf '%s %s\n' "$chosen" "$pr"
}

# How many reviews may run at once: the smaller of $1 (parallel) and what the
# memory above the floor holds. Read at call time:
#   AUTO_REVIEW_MEMINFO          a /proc/meminfo-format file (MemAvailable)
#   AUTO_REVIEW_MEMORY_FLOOR_MB  left alone for everything else, default 1500
#   AUTO_REVIEW_REVIEW_MB        what one review needs, default 1024
# An unreadable meminfo is no cap. 0 means start nothing.
sched_workers() {
  local parallel="${1:-1}" meminfo floor per avail_kb free cap
  meminfo="${AUTO_REVIEW_MEMINFO:-/proc/meminfo}"
  floor="${AUTO_REVIEW_MEMORY_FLOOR_MB:-1500}"
  per="${AUTO_REVIEW_REVIEW_MB:-1024}"
  case "$floor" in '' | *[!0-9]*) floor=1500 ;; esac
  case "$per" in '' | *[!0-9]* | 0) per=1024 ;; esac
  avail_kb="$(awk '/^MemAvailable:/ { print $2 }' "$meminfo" 2>/dev/null || true)"
  case "$avail_kb" in
    '' | *[!0-9]*)
      printf '%s\n' "$parallel"
      return 0
      ;;
  esac
  free=$((avail_kb / 1024 - floor))
  if [ "$free" -lt 0 ]; then cap=0; else cap=$((free / per)); fi
  if [ "$cap" -lt "$parallel" ]; then printf '%s\n' "$cap"; else printf '%s\n' "$parallel"; fi
}

# A positive whole number, or the default.
sched_number() {
  case "$1" in '' | *[!0-9]* | 0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

# Reviews running at once, at most: registry `parallel`, else the environment,
# else 1. $1 = registry file.
sched_parallel() {
  sched_number "$(registry_get_global "$1" parallel "${AUTO_REVIEW_PARALLEL:-1}")" 1
}

# Reviews started in one tick, at most: registry `slots`, else the environment,
# else parallel, so that one tick is one round of workers.
sched_slots() {
  local fallback="${AUTO_REVIEW_SLOTS:-}"
  [ -n "$fallback" ] || fallback="$(sched_parallel "$1")"
  sched_number "$(registry_get_global "$1" slots "$fallback")" "$(sched_parallel "$1")"
}
