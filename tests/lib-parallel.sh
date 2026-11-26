#!/usr/bin/env bash
# Parallel test section runner.

# Pure Core: normalize_section_jobs <raw_value>
# Validates RUN_TESTS_SECTION_JOBS (default 4) and prints a positive integer.
normalize_section_jobs() {
  local raw="${1:-}"
  if [ -z "$raw" ]; then
    printf '4\n'
    return 0
  fi
  case "$raw" in
    *[!0-9]* | 0)
      printf 'run-tests.sh: invalid RUN_TESTS_SECTION_JOBS=%s\n' "$raw" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$raw"
}

# Thin I/O: run_sections_parallel <fn1> [fn2 ...]
# Runs isolated test section functions concurrently (bounded by
# RUN_TESTS_SECTION_JOBS, default 4), buffers each section's stdout/stderr to a
# temp file, prints all outputs deterministically in argument order, and returns
# 1 if any section exited non-zero.
run_sections_parallel() {
  local total="$#"
  [ "$total" -gt 0 ] || return 0

  local jobs
  jobs=$(normalize_section_jobs "${RUN_TESTS_SECTION_JOBS:-}") || return $?

  local -a fns=("$@")
  local sec_tmp
  sec_tmp=$(mktemp -d)

  local -a pids=()
  local -a active=()
  local -a rcs=()
  local next_idx=0
  local idx rc out_file rc_file overall_rc=0

  _reap_sections() {
    local -a still_active=()
    local reaped=0
    local i
    for i in ${active[@]+"${active[@]}"}; do
      if [ -f "$sec_tmp/$i.rc" ] || ! kill -0 "${pids[$i]}" 2>/dev/null; then
        wait "${pids[$i]}" 2>/dev/null || true
        if [ -f "$sec_tmp/$i.rc" ]; then
          rcs[$i]=$(cat "$sec_tmp/$i.rc")
        else
          rcs[$i]=1
        fi
        reaped=1
      else
        still_active+=("$i")
      fi
    done
    active=(${still_active[@]+"${still_active[@]}"})
    [ "$reaped" -eq 1 ]
  }

  while [ "$next_idx" -lt "$total" ] || [ "${#active[@]}" -gt 0 ]; do
    while [ "$next_idx" -lt "$total" ] && [ "${#active[@]}" -lt "$jobs" ]; do
      out_file="$sec_tmp/$next_idx.out"
      rc_file="$sec_tmp/$next_idx.rc"
      (
        _sec_rc=0
        ( "${fns[$next_idx]}" ) >"$out_file" 2>&1 || _sec_rc=$?
        printf '%d\n' "$_sec_rc" >"$rc_file.tmp"
        mv "$rc_file.tmp" "$rc_file"
      ) &
      pids[$next_idx]=$!
      active+=("$next_idx")
      next_idx=$((next_idx + 1))
    done

    if [ "${#active[@]}" -gt 0 ]; then
      if ! _reap_sections; then
        sleep 0.02
      fi
    fi
  done

  idx=0
  while [ "$idx" -lt "$total" ]; do
    [ -f "$sec_tmp/$idx.out" ] && cat "$sec_tmp/$idx.out"
    rc="${rcs[$idx]:-1}"
    if [ "$rc" -ne 0 ]; then
      overall_rc=1
    fi
    idx=$((idx + 1))
  done

  rm -rf "$sec_tmp"
  return "$overall_rc"
}
