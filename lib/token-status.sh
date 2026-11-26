#!/usr/bin/env bash
# Token status and the harness fault gate (upstream issue).
#
# A token that is there but cannot be real (the 19-byte placeholder of
# 2026-11-08) passed "readable and non-empty" and every review then failed with
# `401 Not logged in`, retried every tick, shown nowhere. This file holds what
# answers it: a minimum size per kind of token, a fault file per harness for the
# answers that retrying cannot change (401, 404), and `status --json`, which
# reports both. Needs harness_load and the registry from auto-review.sh.
#
# No token value is ever printed or stored here. The fault's fingerprint is the
# harness, the model and the token file's stat (mtime, size, inode): a hash of a
# secret is an offline-guessable copy of it, and a short token has too little
# entropy to survive that.

# The least number of bytes a GitHub token can have: a classic one is 40, a
# fine-grained one is longer, and the 19-byte placeholder is under it.
GITHUB_TOKEN_MIN=40

# Where the fault files are kept, one per harness.
fault_dir() { printf '%s\n' "${AUTO_REVIEW_FAULT_DIR:-/var/lib/auto-review/faults}"; }

# Prints the path of the token file $1: in the token directory, or where the
# container keeps it (the lock directory) when only that one has it.
token_path() {
  if [ ! -e "$TOKEN_DIR/$1" ] && [ -n "${AUTO_REVIEW_LOCK_DIR:-}" ] && [ -e "$AUTO_REVIEW_LOCK_DIR/$1" ]; then
    printf '%s\n' "$AUTO_REVIEW_LOCK_DIR/$1"
  else
    printf '%s\n' "$TOKEN_DIR/$1"
  fi
}

# Prints "missing" or "short" for token file $1 (a name) with least size $2,
# and nothing for a token that is long enough. Whitespace is not counted.
token_problem() {
  local path size
  path="$(token_path "$1")"
  if [ ! -s "$path" ]; then
    echo missing
    return 0
  fi
  size="$(tr -d '[:space:]' <"$path" 2>/dev/null | wc -c | tr -d ' ')"
  if [ "${size:-0}" -lt "$2" ]; then echo short; fi
  return 0
}

# Prints "<token file name> <least size>" of harness $1. Non-zero for no adapter.
harness_token_spec() {
  (
    harness_load "$1" || exit 1
    declare -F "harness_${HARNESS_PREFIX}_token_file" >/dev/null || exit 1
    printf '%s %s\n' "$("harness_${HARNESS_PREFIX}_token_file")" "$("harness_${HARNESS_PREFIX}_token_min")"
  )
}

# Prints the fingerprint of the configuration a fault is raised under.
# $1 = harness, $2 = model, $3 = token file name ("" for none).
fault_fingerprint() {
  local path="" st=none
  [ -n "$3" ] && path="$(token_path "$3")"
  if [ -n "$path" ] && [ -e "$path" ]; then
    st="$(stat -c '%y:%s:%i' "$path" 2>/dev/null || stat -f '%m:%z:%i' "$path" 2>/dev/null || echo none)"
  fi
  printf '%s|%s|%s\n' "$1" "$2" "$st"
}

# Pure: scrubs held token values and known credential shapes from $1, collapses
# line breaks to spaces, and caps the output to 300 bytes.
scrub_reason() {
  local text="${1:-}" tokens="" v
  if declare -F held_token_values >/dev/null 2>&1; then
    tokens="$(held_token_values)"
  else
    for v in "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${GH_ENTERPRISE_TOKEN:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}"; do
      [ "${#v}" -ge 8 ] && tokens="${tokens}${v}"$'\n'
    done
  fi
  if [ -n "$tokens" ]; then
    text="$(printf '%s' "$text" | SCRUB_TOKENS="$tokens" awk '
      BEGIN { n = split(ENVIRON["SCRUB_TOKENS"], arr, "\n") }
      {
        line = $0
        for (i = 1; i <= n; i++) {
          t = arr[i]
          if (length(t) < 8) continue
          while ((idx = index(line, t)) > 0) {
            line = substr(line, 1, idx - 1) "[REDACTED]" substr(line, idx + length(t))
          }
        }
        printf "%s%s", (NR > 1 ? "\n" : ""), line
      }
    ')"
  fi
  printf '%s' "$text" \
    | sed -E \
        -e 's/gh[pousr]_[A-Za-z0-9_]+/[REDACTED]/g' \
        -e 's/github_pat_[A-Za-z0-9_]+/[REDACTED]/g' \
        -e 's/sk-ant-[A-Za-z0-9_-]+/[REDACTED]/g' \
        -e 's/ya29\.[A-Za-z0-9._-]+/[REDACTED]/g' \
        -e 's/[Bb]earer[[:space:]]+[^[:space:]"'\'']+/Bearer [REDACTED]/g' \
    | tr '\r\n' '  ' \
    | head -c 300
}

# Records harness $1 in fault. $2 = model, $3 = token file name, $4 = message.
fault_record() {
  local dir msg tmp
  dir="$(fault_dir)"
  msg="$(scrub_reason "$4")"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$dir/$1.json.tmp.XXXXXX" 2>/dev/null)" || return 0
  jq -n --arg m "$msg" --arg f "$(fault_fingerprint "$1" "$2" "$3")" \
    '{message: $m, fingerprint: $f}' >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$dir/$1.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# Prints the message of the fault of harness $1 and succeeds when there is one
# raised under the current configuration; a stale fingerprint is no fault.
fault_current() {
  local file msg fp
  file="$(fault_dir)/$1.json"
  [ -s "$file" ] || return 1
  msg="$(jq -r '.message // empty' "$file" 2>/dev/null)"
  fp="$(jq -r '.fingerprint // empty' "$file" 2>/dev/null)"
  [ -n "$fp" ] && [ "$fp" = "$(fault_fingerprint "$1" "$2" "$3")" ] || return 1
  printf '%s\n' "${msg:-fault}"
}

# Prints "<harness>\t<model>" for the harness in use. The machine has one: the
# global harness and model (upstream issue).
harness_pairs_in_use() {
  local reg="$REGISTRY_DEFAULT_FILE" gh gm
  gh="$(registry_get_global "$reg" harness "${AUTO_REVIEW_HARNESS:-claude-code}")"
  gm="$(registry_get_global "$reg" model "$MODEL")"
  printf '%s\t%s\n' "$gh" "$gm"
}

# `auto-review status --json`: the tokens with a problem and the state of each
# harness in use, as one JSON object.
cmd_status() {
  [ "${1:-}" = --json ] || die "status needs --json"
  local tokens='[]' harnesses='{}' reg="$REGISTRY_DEFAULT_FILE" owner name problem
  local pairs h m spec file min state message msg
  if [ -f "$reg" ]; then
    # One GitHub token per resource owner, gh-<owner>.token. Until it
    # is delivered, a repository's old <owner>-<repo>.token serves, as it does
    # for tick, run and setup; then that file is the one judged.
    local repo seen=" "
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      owner="${repo%%/*}"
      name="gh-$owner.token"
      if [ ! -e "$(token_path "$name")" ] && [ -e "$(token_path "$(printf '%s' "$repo" | tr / -).token")" ]; then
        name="$(printf '%s' "$repo" | tr / -).token"
      fi
      case "$seen" in *" $name "*) continue ;; esac
      seen="$seen$name "
      problem="$(token_problem "$name" "$GITHUB_TOKEN_MIN")"
      [ -z "$problem" ] || tokens="$(jq -c --arg n "$name" --arg p "$problem" \
        '. + [{name: $n, kind: "github", problem: $p}]' <<<"$tokens")"
    done < <(jq -r '.projects | keys[]' "$reg" 2>/dev/null)
  fi
  pairs="$(harness_pairs_in_use | sort -u)"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    file=""
    min=0
    if spec="$(harness_token_spec "$h")"; then
      file="${spec% *}"
      min="${spec##* }"
      problem="$(token_problem "$file" "$min")"
      [ -z "$problem" ] || tokens="$(jq -c --arg n "$file" --arg k "$h" --arg p "$problem" \
        '. + [{name: $n, kind: $k, problem: $p, command: ("auto-review login " + $k)}]' <<<"$tokens")"
    fi
    state=ok
    message=""
    while IFS=$'\t' read -r _ m; do
      if msg="$(fault_current "$h" "$m" "$file")"; then
        state=fault
        message="$msg"
        break
      fi
    done < <(printf '%s\n' "$pairs" | awk -F'\t' -v h="$h" '$1 == h')
    harnesses="$(jq -c --arg h "$h" --arg s "$state" --arg m "$message" \
      '.[$h] = {state: $s, message: $m}' <<<"$harnesses")"
  done < <(printf '%s\n' "$pairs" | cut -f1 | sort -u)
  jq -cn --argjson t "$tokens" --argjson h "$harnesses" '{tokens: $t, harnesses: $h}'
}

# The gate in front of a review. $1 = pull request, $2 = harness, $3 = model.
# Needs HARNESS_PREFIX of the loaded adapter. Succeeds when the review may run.
# A missing token does not block (the interactive login is a fallback); a short
# one does, and so does a harness in fault under this configuration.
harness_gate() {
  local pr="$1" h="$2" model="$3" p="harness_${HARNESS_PREFIX}" file min problem msg
  declare -F "${p}_token_file" >/dev/null || return 0
  file="$("${p}_token_file")"
  min="$("${p}_token_min")"
  problem="$(token_problem "$file" "$min")"
  if [ "$problem" = short ]; then
    log "#$pr: $file is short (under $min bytes), so it cannot be a real token — not reviewing; store a new one"
    return 1
  fi
  if msg="$(fault_current "$h" "$model" "$file")"; then
    log "#$pr: harness $h is in fault: $msg — not reviewing until its token or the model changes"
    return 1
  fi
  return 0
}

# Raises the fault of harness $2 after a review run answered with a
# configuration fault. $1 = pull request, $3 = model, $4 = the reason, one line.
# Needs HARNESS_PREFIX of the loaded adapter.
harness_fault_raise() {
  local pr="$1" h="$2" model="$3" reason="$4" file=""
  declare -F "harness_${HARNESS_PREFIX}_token_file" >/dev/null && file="$("harness_${HARNESS_PREFIX}_token_file")"
  # Without a token file the login lives somewhere the fingerprint cannot see
  # (the interactive login), so a fault could never clear: log it, retry next tick.
  if [ -n "$file" ] && [ "$(token_problem "$file" 0)" = missing ]; then
    log "#$pr: harness $h answered with a configuration fault and has no $file, so it is not latched; the next tick tries again: $reason"
    return 0
  fi
  fault_record "$h" "$model" "$file" "$reason"
  log "#$pr: harness $h is in fault: $reason — not reviewing until its token or the model changes"
}
