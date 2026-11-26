#!/usr/bin/env bash
# `credential set|list` and `login` (upstream issue).
#
# On 2026-11-08 renewing the Claude credential took six steps across three tools
# and a 19-byte placeholder passed every check. This file is the one path every
# harness credential takes: read it from stdin byte for byte, validate its size
# against the adapter's minimum, check it with one real prompt through the
# harness CLI, and only then rename it into the token directory. A rejected one
# leaves the old file where it was. `login` is the same path with the adapter's
# own login command in front of it.
#
# Everything harness-specific is in the adapter: harness_P_token_file,
# _token_min, _aliases, _login, _check_prompt, _check_token and _parse. Adding a
# harness touches its adapter file only. The credential is never printed, never
# an argument, and in the environment only where the harness CLI needs it.
# Needs harness_load, harness_dirs, token_path and fault_dir (token-status.sh).

# The temporary file a command is holding, removed on any exit.
CREDENTIAL_TMP=""

# Prints the name of each harness adapter, once, in search order.
credential_harness_names() {
  local dir f name seen=" "
  while IFS= read -r dir; do
    for f in "$dir"/*.sh; do
      [ -f "$f" ] || continue
      name="$(basename "$f" .sh)"
      case "$seen" in *" $name "*) continue ;; esac
      seen="$seen$name "
      printf '%s\n' "$name"
    done
  done < <(harness_dirs)
}

# Prints the adapter name $1 stands for: the name itself, or the one whose
# harness_P_aliases lists it. Non-zero for none.
credential_resolve() {
  local want="$1" name aliases
  while IFS= read -r name; do
    if [ "$name" = "$want" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(credential_harness_names)
  while IFS= read -r name; do
    aliases="$(harness_load "$name" >/dev/null 2>&1 && "harness_${HARNESS_PREFIX}_aliases" 2>/dev/null)" || continue
    if printf '%s\n' "$aliases" | grep -qxF -- "$want"; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(credential_harness_names)
  return 1
}

# Keeps the last check result of harness $1 ($2: ok, a status, or fail) beside
# the fault files. A rejected attempt records its status here too.
credential_record_check() {
  local dir
  dir="$(fault_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$2" >"$dir/$1.check.tmp" 2>/dev/null \
    && mv -f "$dir/$1.check.tmp" "$dir/$1.check" 2>/dev/null
  return 0
}

# Copies token file $1 (stored at $2) into the machine container when run from
# the host, as cmd_claude_token does. Inside the container the directory is the
# gate's memory already.
credential_mirror() {
  [ -z "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] && [ ! -f /.dockerenv ] || return 0
  [ -z "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "auto-review" || return 0
  docker exec -i -u "$AUTO_REVIEW_GATE_UID" auto-review sh -c \
    "cat > /run/auto-review/.$1.new && chmod 0600 /run/auto-review/.$1.new && mv -f /run/auto-review/.$1.new /run/auto-review/$1" \
    <"$2" 2>/dev/null || true
}

# Ends the command at step $1 with reason $2. Nothing was stored.
credential_fail() {
  die "step $1: $2 — nothing stored"
}

# Validates, checks and stores the credential in file $2 (in the token
# directory, so the final rename is atomic) for harness $1. Prints ok.
credential_apply() {
  local h="$1" in="$2" p file min size out err perr rc=0 prc=0 msg status fn dest
  harness_load "$h" || die "no adapter for harness $h"
  p="harness_${HARNESS_PREFIX}"
  for fn in token_file token_min check_prompt check_token parse; do
    declare -F "${p}_$fn" >/dev/null || credential_fail validate "the $h adapter has no ${p}_$fn"
  done
  file="$("${p}_token_file")"
  min="$("${p}_token_min")"
  size="$(tr -d '[:space:]' <"$in" | wc -c | tr -d ' ')"
  [ "$size" -ge 1 ] || credential_fail validate "empty, nothing was read"
  [ "$size" -ge "$min" ] || credential_fail validate "too short ($size bytes, $h needs at least $min)"

  out="$(mktemp)"
  err="$(mktemp)"
  perr="$(mktemp)"
  "${p}_check_token" "$in" "$out" "$err" || rc=$?
  "${p}_parse" "$out" >/dev/null 2>"$perr" || prc=$?
  if [ "$rc" != 0 ] || [ "$prc" != 0 ]; then
    msg="$(head -n 1 "$perr" | cut -c1-300)"
    [ -n "$msg" ] || msg="the $h CLI exited $rc and its answer was not a successful run"
    status="$(printf '%s\n' "$msg" | sed -n 's/.*answered \([0-9][0-9][0-9]\).*/\1/p' | head -n 1)"
    credential_record_check "$h" "${status:-fail}"
    rm -f "$out" "$err" "$perr"
    credential_fail check "$msg"
  fi
  rm -f "$out" "$err" "$perr"

  dest="$TOKEN_DIR/$file"
  chmod 600 "$in"
  mv -f "$in" "$dest"
  CREDENTIAL_TMP=""
  # `docker exec` without -u is root; the gate has to be able to read it.
  if [ "$(id -u)" = 0 ]; then chown "$AUTO_REVIEW_GATE_UID" "$dest" 2>/dev/null || true; fi
  credential_record_check "$h" ok
  credential_mirror "$file" "$dest"
  echo ok
}

# A temporary file in the token directory, 0600 from the moment it exists.
credential_tempfile() {
  mkdir -p "$TOKEN_DIR"
  chmod 700 "$TOKEN_DIR" 2>/dev/null || true
  CREDENTIAL_TMP="$(mktemp "$TOKEN_DIR/.credential.XXXXXX")" || die "cannot write in $TOKEN_DIR"
  # shellcheck disable=SC2064 # the path is fixed at this point
  trap 'rm -f "$CREDENTIAL_TMP"' EXIT
}

# `credential set <harness>`: the credential is all of stdin.
cmd_credential_set() {
  local h
  h="$(credential_resolve "$1")" || die "no adapter for harness $1 (known: $(credential_harness_names | tr '\n' ' '))"
  [ ! -t 0 ] || die "stdin is a terminal — pipe the credential in:  <something that prints it> | auto-review credential set $1"
  credential_tempfile
  cat >"$CREDENTIAL_TMP"
  credential_apply "$h" "$CREDENTIAL_TMP"
}

# `login <harness>`: the adapter's login command prints the credential on stdout.
cmd_login() {
  local h
  h="$(credential_resolve "$1")" || die "no adapter for harness $1 (known: $(credential_harness_names | tr '\n' ' '))"
  harness_load "$h" || die "no adapter for harness $h"
  declare -F "harness_${HARNESS_PREFIX}_login" >/dev/null || credential_fail login "the $h adapter has no login flow"
  credential_tempfile
  "harness_${HARNESS_PREFIX}_login" >"$CREDENTIAL_TMP" || credential_fail login "the $h login command failed"
  credential_apply "$h" "$CREDENTIAL_TMP"
}

# One line for harness $1: <harness> <present|missing> age=<N>s check=<last>.
credential_list_line() {
  local name="$1" file path chk=none mtime
  file="$(harness_token_spec "$name")" || return 0
  file="${file% *}"
  path="$(token_path "$file")"
  [ ! -s "$(fault_dir)/$name.check" ] || chk="$(head -n 1 "$(fault_dir)/$name.check")"
  if [ -s "$path" ]; then
    mtime="$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || date +%s)"
    printf '%s present age=%ss check=%s\n' "$name" "$(( $(date +%s) - mtime ))" "$chk"
  else
    printf '%s missing check=%s\n' "$name" "$chk"
  fi
}

cmd_credential_list() {
  local name
  while IFS= read -r name; do
    credential_list_line "$name"
  done < <(credential_harness_names)
}

cmd_credential() {
  case "${1:-}" in
    set)
      [ $# -eq 2 ] || die "credential set needs one harness"
      cmd_credential_set "$2"
      ;;
    list)
      [ $# -eq 1 ] || die "credential list takes no arguments"
      cmd_credential_list
      ;;
    *) die "credential needs set <harness> or list" ;;
  esac
}
