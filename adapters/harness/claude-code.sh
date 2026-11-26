#!/usr/bin/env bash
# Agent Harness Adapter: Claude Code for auto-review.
#
# Provides isolated CLI execution for Claude Code under strict read-only tool
# permissions, system prompt injection, and output verdict validation.

# Checks whether claude CLI is installed and available on PATH.
harness_claude_probe() {
  command -v claude >/dev/null 2>&1
}

# Prints the model names a user may set, one per line. claude takes the name
# as it is (--model sonnet), so there is no id table behind it.
harness_claude_models() {
  printf '%s\n' sonnet opus haiku
}

# Prints the one model used when none was chosen. It is in harness_claude_models.
harness_claude_default_model() {
  printf '%s\n' sonnet
}

# The file under the token directory claude authenticates with, and the least
# number of bytes it can have: above the 19-byte placeholder of 2026-11-08, under
# a token from `claude setup-token` (upstream issue).
harness_claude_token_file() {
  printf '%s\n' claude.token
}
harness_claude_token_min() {
  printf '%s\n' 40
}

# The other names `auto-review credential set` and `login` answer to.
harness_claude_aliases() {
  printf '%s\n' claude
}

# The one small prompt a credential check sends.
harness_claude_check_prompt() {
  printf '%s\n' 'reply with exactly: ok'
}

# Runs `claude setup-token` and prints the token on stdout. The command writes
# its instructions to stdout as well, so the token is picked out of the output
# and the other lines go to stderr, where the operator can read them. The token
# line itself is never echoed.
harness_claude_login() {
  local out rc=0 token
  out="$(mktemp)"
  claude setup-token >"$out" || rc=$?
  if [ "$rc" = 0 ]; then
    grep -v 'sk-ant-' "$out" >&2 || true
    token="$(grep -oE 'sk-ant-[A-Za-z0-9_-]+' "$out" | tail -n 1 || true)"
    if [ -n "$token" ]; then
      printf '%s' "$token"
    else
      printf 'no token (sk-ant-...) in what claude setup-token printed\n' >&2
      rc=1
    fi
  fi
  rm -f "$out"
  return "$rc"
}

# Pure builder: prints the invocation arguments for claude, one per line.
harness_claude_build_args() {
  local model="$1" prompt_file="$2" history_file="${3:-}"
  printf '%s\n' "--model" "$model"
  printf '%s\n' "--tools" "Read,Grep,Glob"
  if [ -n "$history_file" ] && [ -s "$history_file" ]; then
    printf '%s\n' "--append-system-prompt" "$history_file"
  fi
  printf '%s\n' "-p"
}

# Pure parser: extracts and validates the review verdict from output.
# Output format:
#   NO_FINDINGS  (exit 0)
#   FINDINGS:<N> (exit 0)
#   MALFORMED    (exit 1)
harness_claude_parse_verdict() {
  local output_file="$1"
  [ -f "$output_file" ] || { printf 'MALFORMED\n'; return 1; }

  local verdict
  verdict="$(awk 'NF { print; exit }' "$output_file" | tr -d '\r')"
  [ -n "$verdict" ] || { printf 'MALFORMED\n'; return 1; }

  case "$verdict" in
    '**No findings.'*)
      printf 'NO_FINDINGS\n'
      return 0
      ;;
    '**'[0-9]*' finding'*)
      local count
      count="$(printf '%s\n' "$verdict" | sed -E 's/^\*\*([0-9]+) finding.*/\1/')"
      printf 'FINDINGS:%s\n' "$count"
      return 0
      ;;
    *)
      printf 'MALFORMED\n'
      return 1
      ;;
  esac
}

# Pure helper: extracts integer findings count from output (0 on clean or malformed).
harness_claude_count_findings() {
  local output_file="$1"
  local parsed
  parsed="$(harness_claude_parse_verdict "$output_file" 2>/dev/null || echo "MALFORMED")"
  case "$parsed" in
    NO_FINDINGS) echo 0 ;;
    FINDINGS:*) echo "${parsed#FINDINGS:}" ;;
    *) echo 0 ;;
  esac
}


# Starts the reviewer in the background and leaves its pid in REVIEWER_PID.
# $1 = reviewer HOME, $2 = model, $3 = task, $4 = guidance (the system prompt
# addition), $5 = file for stdout, $6 = file for stderr. Reads nothing: stdin
# is /dev/null. Every argument is built here; the caller knows none of them.
#
# `--tools`, not `--allowedTools`. The two read alike and do opposite jobs:
# --allowedTools is a list of things that run *without a prompt*, so it never
# took a tool away and the deny list was carrying the whole weight, which is
# why three rounds of enumerating denies each left a hole. --tools sets the
# built-in set itself. Verified: with these three, Bash, Write, Edit, Task and
# Monitor are not in the session at all. No --dangerously-skip-permissions:
# the reviewer is read-only (upstream issue).
#
# --strict-mcp-config with an empty config, because --tools bounds the
# built-in set and nothing else: without it the reviewer still holds every
# MCP tool this machine has configured, which is the one class the file
# sandbox cannot see either. No deny list here on purpose: an enumeration
# reads as coverage and never has it.
#
# `--output-format json`, because plain stdout cannot be told apart from a
# review. On 2026-08-11 the subscription's session limit ran out mid-tick:
# the CLI printed "You've hit your session limit", exited **zero**, and the
# shell posted that as the review. The envelope has to say the run succeeded.
# stderr goes to its own file, not into the envelope: one deprecation warning
# in front of the JSON would make every envelope unparseable.
harness_claude_execute() {
  local rhome="$1" model="$2" task="$3" guidance="$4" raw="$5" err="$6"
  reviewer_launch "$rhome" -- \
    claude -p "$task" \
    --model "$model" \
    --append-system-prompt "$guidance" \
    --tools "Read,Grep,Glob" \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --output-format json \
    </dev/null >"$raw" 2>"$err" &
  REVIEWER_PID=$!
}

# $1 = the file the CLI printed. rc 0 and the review text on stdout when the
# run produced a review; rc 2 for a 401 or 404 answer (a configuration fault);
# otherwise rc 1, nothing on stdout, one line on stderr.
#
# Everything is checked before anything is extracted: not JSON, not a result
# envelope, an error flag, or a subtype other than success all mean there is no
# review. An expired OAuth token produced `{"type":"result","subtype":"success",
# "is_error":false,"result":"Failed to authenticate. API Error: 401 ..."}`, a
# successful run whose result is somebody else's error, and that went into a
# pull request as a review on 2026-08-12. So this does not test for failure;
# it tests for **proof that the reviewer ran**: output tokens. An
# authentication failure or an exhausted session never reaches the model, so
# the count is zero there, and a review of any length is hundreds. `subtype`
# says success on a run that failed, so `is_error` and this count carry the
# signal, not the word. Both places are read, because a plain prompt reports
# `usage.output_tokens` while a slash command leaves it at zero and reports
# under `modelUsage`.
harness_claude_parse() {
  local raw="$1" envelope produced result status
  # A 401 or a 404 is the configuration talking (the token, the model), and
  # retrying cannot change it: exit 2, apart from every other failure.
  status="$(jq -r 'if type == "object" and .type == "result" and .is_error == true
      and (.api_error_status == 401 or .api_error_status == 404)
    then .api_error_status else empty end' <"$raw" 2>/dev/null || true)"
  if [ -n "$status" ]; then
    printf 'the API answered %s: %s\n' "$status" \
      "$(jq -r '.result // ""' <"$raw" 2>/dev/null | head -n 1 | cut -c1-200)" >&2
    return 2
  fi
  # Any other status the API answered (a 429, a 500) is named too; it is not a
  # configuration fault, so the exit status stays 1.
  status="$(jq -r 'if type == "object" and .type == "result" and .is_error == true
      and (.api_error_status | type) == "number"
    then .api_error_status else empty end' <"$raw" 2>/dev/null || true)"
  if [ -n "$status" ]; then
    printf 'the API answered %s: %s\n' "$status" \
      "$(jq -r '.result // ""' <"$raw" 2>/dev/null | head -n 1 | cut -c1-200)" >&2
    return 1
  fi
  envelope="$(jq -r 'if type == "object"
      and .type == "result"
      and .is_error == false
      and .subtype == "success"
      and (.result | type) == "string"
    then "ok" else "bad" end' <"$raw" 2>/dev/null || echo bad)"
  if [ "$envelope" != ok ]; then
    printf 'no successful result envelope in the output\n' >&2
    return 1
  fi
  produced="$(jq -r '[(.usage.output_tokens // 0),
    ((.modelUsage // {}) | to_entries | map(.value.outputTokens // 0) | add // 0)]
    | max' <"$raw" 2>/dev/null || echo 0)"
  case "$produced" in
    '' | *[!0-9]*) produced=0 ;;
  esac
  if [ "$produced" -lt 1 ]; then
    printf 'the model generated nothing, so this is the runtime talking, not a review\n' >&2
    return 1
  fi
  result="$(jq -r '.result' <"$raw" 2>/dev/null)" || {
    printf 'could not read the review out of the output\n' >&2
    return 1
  }
  if [ -z "$(printf '%s' "$result" | tr -d '[:space:]')" ]; then
    printf 'the review is empty\n' >&2
    return 1
  fi
  printf '%s\n' "$result"
}

# Sets REVIEWER_AUTH to what the reviewer will authenticate with, loading the
# stored token into the environment when there is one (load_claude_token).
harness_claude_auth() {
  if load_claude_token; then
    REVIEWER_AUTH="the stored token"
  else
    REVIEWER_AUTH="the interactive login (expires; see claude-token)"
  fi
}

# Checks a candidate token with one prompt, from a directory of its own: a
# CLAUDE.md in whatever the current directory happens to be is read as
# instructions, and this check has no business carrying somebody's project
# prompt into it. $1 = file holding the token, $2 = file for stdout, $3 = file
# for stderr (kept apart, so a CLI that exits without printing an envelope
# does not get a token blamed that it never managed to test). Returns the CLI's
# exit status.
harness_claude_check_token() {
  local tokfile="$1" out="$2" err="$3" dir rc=0
  dir="$(mktemp -d)"
  (
    cd "$dir" || exit 1
    CLAUDE_CODE_OAUTH_TOKEN="$(cat "$tokfile")" \
      env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
      claude -p "$(harness_claude_check_prompt)" \
      --tools "Read" \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --output-format json </dev/null
  ) >"$out" 2>"$err" || rc=$?
  rmdir "$dir" 2>/dev/null || true
  return "$rc"
}
