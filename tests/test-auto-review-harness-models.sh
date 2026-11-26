#!/usr/bin/env bash
# Consolidated harness adapter, task adapter, models, and prompt tests for
# auto-review (upstream issue).
# Consolidates:
#   - test-auto-review-harness.sh
#   - test-auto-review-harness-adapter.sh
#   - test-auto-review-task-adapter.sh
#   - test-auto-review-models.sh
#   - test-auto-review-prompt.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$here/tests/lib-parallel.sh"

check() { # $1 = label, $2 = want, $3 = got
  if [ "$2" = "$3" ]; then
    printf 'ok    %s\n' "$1"
  else
    printf 'FAIL  %s\n--- want\n%s\n--- got\n%s\n' "$1" "$2" "$3"
    fail=1
  fi
}

has() { # $1 = label, $2 = text, $3 = fixed string it must contain
  case "$2" in
    *"$3"*) printf 'ok    %s\n' "$1" ;;
    *) printf 'FAIL  %s\n--- wanted to contain: %s\n--- got\n%s\n' "$1" "$3" "$2"; fail=1 ;;
  esac
}

lacks() { # $1 = label, $2 = text, $3 = fixed string it must not contain
  case "$2" in
    *"$3"*) printf 'FAIL  %s\n--- must not contain: %s\n' "$1" "$3"; fail=1 ;;
    *) printf 'ok    %s\n' "$1" ;;
  esac
}

# ==============================================================================
# Section 1: Harness adapter contract, envelopes, core isolation, run_reviewer
# ==============================================================================
section_1() (
  script="$here/auto-review.sh"
  adir="$here/adapters/harness"
  fx="$here/tests/fixtures/auto-review/harness"
  fixtures=$(mktemp -d)
  chmod 755 "$fixtures"
  trap 'rm -r -f "$fixtures"' EXIT
  fail=0

  adapter_prefix() {
    bash -c '. "$1" >/dev/null 2>&1; declare -F | awk "{print \$3}"' _ "$1" 2>/dev/null \
      | sed -n 's/^harness_\(.*\)_execute$/\1/p' | head -n 1
  }
  call_adapter() {
    local file="$1" p="$2" fn="$3"
    shift 3
    bash -c '. "$1"; fn="harness_$2_$3"; shift 3; "$fn" "$@"' _ "$file" "$p" "$fn" "$@" \
      >"$fixtures/o" 2>"$fixtures/e" </dev/null
  }

  for want in claude-code agy; do
    check "adapters/harness/$want.sh exists" present "$([ -f "$adir/$want.sh" ] && echo present || echo absent)"
  done

  for file in "$adir"/*.sh; do
    [ -f "$file" ] || continue
    h="$(basename "$file" .sh)"
    p="$(adapter_prefix "$file")"
    check "$h: defines harness_<P>_execute" present "$([ -n "$p" ] && echo present || echo absent)"
    [ -n "$p" ] || continue
    for fn in probe execute parse parse_verdict; do
      got="$(bash -c '. "$1" >/dev/null 2>&1; declare -F "$2"' _ "$file" "harness_${p}_$fn" 2>/dev/null)"
      check "$h: defines harness_${p}_$fn" "harness_${p}_$fn" "$got"
    done
  done

  for h in claude-code agy; do
    file="$adir/$h.sh"
    [ -f "$file" ] || { printf 'FAIL  %s\n' "$h: no adapter to parse its fixtures with"; fail=1; continue; }
    p="$(adapter_prefix "$file")"
    [ -n "$p" ] || { printf 'FAIL  %s\n' "$h: no harness_<P>_execute to find the prefix by"; fail=1; continue; }

    call_adapter "$file" "$p" parse "$fx/$h/success.json"
    rc=$?
    check "$h: success envelope parses (rc 0)" 0 "$rc"
    has "$h: success envelope yields the review text" "$(cat "$fixtures/o")" "**1 finding.** - the retry loop never backs off"
    has "$h: success envelope yields the whole review, not its first line" "$(cat "$fixtures/o")" 'scripts/poll.sh:42'

    for bad in "$fx/$h"/error*.* "$fx/$h"/empty.*; do
      [ -f "$bad" ] || continue
      name="$h: $(basename "$bad")"
      call_adapter "$file" "$p" parse "$bad"
      rc=$?
      check "$name is refused (rc != 0)" 1 "$([ "$rc" != 0 ] && echo 1 || echo 0)"
      check "$name leaves nothing on stdout to be posted" "" "$(cat "$fixtures/o")"
      check "$name says why on stderr" 1 "$([ -s "$fixtures/e" ] && echo 1 || echo 0)"
    done
  done
  check "claude-code: fixtures cover success, error, empty" 3 \
    "$(for k in success error empty; do ls "$fx"/claude-code/$k.* >/dev/null 2>&1 && echo x; done | wc -l | tr -d ' ')"
  check "agy: fixtures cover success, error, empty" 3 \
    "$(for k in success error empty; do ls "$fx"/agy/$k.* >/dev/null 2>&1 && echo x; done | wc -l | tr -d ' ')"

  # agy denied_actions envelope checks
  agy_file="$adir/agy.sh"
  agy_p="$(adapter_prefix "$agy_file")"
  printf '{"status":"SUCCESS","response":"I'\''ll start by reading the diff and the PR description.","denied_actions":[{"action":"command","display_name":"RunCommand"}]}\n' >"$fixtures/agy-denied-single.json"
  call_adapter "$agy_file" "$agy_p" parse "$fixtures/agy-denied-single.json"
  rc=$?
  check "agy: denied_actions with SUCCESS+preamble exits 1" 1 "$rc"
  check "agy: denied_actions leaves nothing on stdout" "" "$(cat "$fixtures/o")"
  has "agy: denied_actions stderr mentions denied_actions" "$(cat "$fixtures/e")" "denied_actions"
  has "agy: denied_actions stderr names the denied action" "$(cat "$fixtures/e")" "command"

  printf '{"status":"SUCCESS","response":"I'\''ll start by reading...","denied_actions":[{"action":"read_file","display_name":"ReadFile"},{"action":"command"}]}\n' >"$fixtures/agy-denied-multi.json"
  call_adapter "$agy_file" "$agy_p" parse "$fixtures/agy-denied-multi.json"
  rc=$?
  check "agy: multiple denied_actions exits 1" 1 "$rc"
  check "agy: multiple denied_actions leaves nothing on stdout" "" "$(cat "$fixtures/o")"
  has "agy: multiple denied_actions stderr mentions denied_actions" "$(cat "$fixtures/e")" "denied_actions"

  printf '{"status":"SUCCESS","response":"**No findings.** ok","denied_actions":[]}\n' >"$fixtures/agy-denied-empty.json"
  call_adapter "$agy_file" "$agy_p" parse "$fixtures/agy-denied-empty.json"
  rc=$?
  check "agy: empty denied_actions array exits 0" 0 "$rc"
  has "agy: empty denied_actions array yields response" "$(cat "$fixtures/o")" "**No findings.** ok"

  printf '{"status":"SUCCESS","response":"**No findings.** ok"}\n' >"$fixtures/agy-denied-absent.json"
  call_adapter "$agy_file" "$agy_p" parse "$fixtures/agy-denied-absent.json"
  rc=$?
  check "agy: absent denied_actions exits 0" 0 "$rc"
  has "agy: absent denied_actions yields response" "$(cat "$fixtures/o")" "**No findings.** ok"

  core_code="$(grep -v '^[[:space:]]*#' "$script")"
  reviewer_fns="$(awk '/^run_reviewer(_in)?\(\) \{/ {on=1} on {print} on && /^}/ {on=0}' "$script" \
    | grep -v '^[[:space:]]*#')"
  check "run_reviewer is found in the core" present "$([ -n "$reviewer_fns" ] && echo present || echo absent)"

  core_hits() { printf '%s\n' "$2" | grep -n -P -- "$1"; }
  no_hit() {
    local hits
    hits="$(core_hits "$2" "$3" | head -n 5)"
    check "$1" "" "$hits"
  }
  no_hit "core has no --dangerously-* flag"      '--dangerously'     "$core_code"
  no_hit "core has no --output-format flag"      '--output-format'   "$core_code"
  no_hit "core has no --skip-trust flag"         '--skip-trust'      "$core_code"
  no_hit "core has no --approval-mode flag"      '--approval-mode'   "$core_code"
  no_hit "core has no --strict-mcp-config flag"  '--strict-mcp-config' "$core_code"
  no_hit "core has no GEMINI_API_KEY"            'GEMINI_API_KEY'    "$core_code"
  no_hit "core has no gemini command or function name" '(?<![./A-Za-z0-9])gemini' "$core_code"
  no_hit "core has no model id (claude-sonnet-5-5 ..., gemini-3.8 ...)" \
    '(claude-(sonnet|opus|haiku)-[0-9]|gemini-[0-9])' "$core_code"
  no_hit "run_reviewer names no CLI (claude, agy) as a command or a case label" \
    '(?<![-./\w$])(claude|agy)(?=[ *|)])' "$reviewer_fns"
  no_hit "run_reviewer has no case on harness names" 'gemini\*|agy\*' "$reviewer_fns"
  check "run_reviewer reaches the adapters (calls harness_* functions)" 1 \
    "$(printf '%s\n' "$reviewer_fns" | grep -c 'harness_' | awk '{print ($1 > 0)}')"

  check "adapters/harness/gemini-cli.sh is removed" absent "$([ -e "$adir/gemini-cli.sh" ] && echo present || echo absent)"
  check "test-auto-review-gemini-adapter.sh goes with its adapter" absent \
    "$([ -e "$here/scripts/test-auto-review-gemini-adapter.sh" ] && echo present || echo absent)"
  check "GEMINI_API_KEY appears nowhere under auto-review/ and tools/auto-review/" "" \
    "$(grep -rIl --exclude-dir=tests --exclude-dir=.git 'GEMINI_API_KEY' "$here" 2>/dev/null | sed "s|$here/||")"
  check "the gemini-cli harness name appears nowhere under auto-review/ and tools/auto-review/" "" \
    "$(grep -rIl --exclude-dir=tests --exclude-dir=.git 'gemini-cli' "$here" 2>/dev/null | sed "s|$here/||")"

  mkdir -p "$fixtures/home" "$fixtures/tokens" "$fixtures/lock"
  chmod 700 "$fixtures/tokens" "$fixtures/lock"
  export HOME="$fixtures/home"
  export AUTO_REVIEW_TOKEN_DIR="$fixtures/tokens"
  export AUTO_REVIEW_LOCK_DIR="$fixtures/lock"

  # shellcheck disable=SC1091
  . "$script"
  set +e

  rclone="$fixtures/reviewer-clone"
  rbin="$(mktemp -d "${AUTO_REVIEW_TEST_BIN_ROOT:-$fixtures}/rbin.XXXXXX")"
  chmod 755 "$rbin"
  trap 'rm -r -f "$fixtures" "$rbin"' EXIT
  mkdir -p "$rclone/.git" "$rclone/src"
  touch "$rclone/.auto-review-history.md" "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md"
  REVIEWER_CLONE="$rclone"
  REVIEWER_PERIMETER=()
  sleep() { command sleep 0.05; }
  AUTO_REVIEW_TIMEOUT=100000000

  cat >"$rbin/bwrap" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
FAKE
  cat >"$rbin/claude" <<'FAKE'
#!/bin/sh
a=$(printf '%s\n' "$@" | base64 | tr -d '\n')
printf '{"type":"result","subtype":"success","is_error":false,"usage":{"output_tokens":20},"result":"**No findings.** CALLED:claude ARGS:%s:END"}\n' "$a"
FAKE
  cat >"$rbin/agy" <<'FAKE'
#!/bin/sh
a=$(printf '%s\n' "$@" | base64 | tr -d '\n')
printf '{"response":"**No findings.** CALLED:agy ARGS:%s:END","stats":{"models":{"m":{"tokens":{"candidates":9}}}}}\n' "$a"
FAKE
  chmod 755 "$rbin/bwrap" "$rbin/claude" "$rbin/agy"
  PATH="$rbin:$PATH"
  export PATH

  run_with() {
    rm -f "$fixtures/out.md"
    HARNESS="$1" run_reviewer 1 "$fixtures/out.md" "$rclone/.auto-review-history.md" \
      "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md" >"$fixtures/run.log" 2>&1
    RUN_RC=$?
    OUT="$(cat "$fixtures/out.md" 2>/dev/null)"
    OUT_ARGS="$(printf '%s' "$OUT" | sed -n 's/.*ARGS:\([A-Za-z0-9+/=]*\):END.*/\1/p' | head -n 1 | base64 -d 2>/dev/null)"
  }

  run_with claude-code
  check "HARNESS=claude-code: run_reviewer succeeds" 0 "$RUN_RC"
  has   "HARNESS=claude-code: the claude adapter ran claude" "$OUT" "CALLED:claude"
  lacks "HARNESS=claude-code: agy was not run" "$OUT" "CALLED:agy"
  has   "HARNESS=claude-code: the review is the envelope's result" "$OUT" "**No findings.**"
  has   "HARNESS=claude-code: tools are limited to Read,Grep,Glob" "$(printf '%s\n' "$OUT_ARGS")" "Read,Grep,Glob"

  run_with agy
  check "HARNESS=agy: run_reviewer succeeds" 0 "$RUN_RC"
  has   "HARNESS=agy: the agy adapter ran agy" "$OUT" "CALLED:agy"
  lacks "HARNESS=agy: claude was not run" "$OUT" "CALLED:claude"
  check "HARNESS=agy: agy was launched" present "$([ -n "$OUT_ARGS" ] && echo present || echo absent)"
  lacks "HARNESS=agy: launched without --dangerously-skip-permissions" "x$OUT_ARGS" "--dangerously-skip-permissions"

  for h in claude-code agy; do
    cli=claude
    [ "$h" = agy ] && cli=agy
    for bad in "$fx/$h"/error*.* "$fx/$h"/empty.*; do
      [ -f "$bad" ] || continue
      cp "$rbin/$cli" "$fixtures/$cli.keep"
      cp "$bad" "$fixtures/readable.fixture" && chmod 644 "$fixtures/readable.fixture"
      printf '#!/bin/sh\ncat "%s"\n' "$fixtures/readable.fixture" >"$rbin/$cli"
      chmod 755 "$rbin/$cli"
      run_with "$h"
      check "$h: run_reviewer refuses $(basename "$bad") (rc != 0)" 1 "$([ "$RUN_RC" != 0 ] && echo 1 || echo 0)"
      check "$h: run_reviewer writes no review for $(basename "$bad")" "" "$OUT"
      cp "$fixtures/$cli.keep" "$rbin/$cli"
      chmod 755 "$rbin/$cli"
    done
  done

  core="$fixtures/core"
  mkdir -p "$core"
  cp -a "$here/." "$core/"
  mkdir -p "$core/adapters/harness"
  cat >"$core/adapters/harness/fakeh.sh" <<'FAKE'
#!/usr/bin/env bash
harness_fakeh_probe() { command -v fakeh-cli >/dev/null 2>&1; }
harness_fakeh_execute() {
  reviewer_launch "$1" -- fakeh-cli "$3" </dev/null >"$5" 2>"$6" &
  REVIEWER_PID=$!
}
harness_fakeh_parse() {
  local r
  r="$(jq -r '.review // empty' "$1" 2>/dev/null)"
  [ -n "$r" ] || { printf 'no review in the envelope\n' >&2; return 1; }
  printf '%s\n' "$r"
}
harness_fakeh_parse_verdict() { printf 'NO_FINDINGS\n'; }
FAKE
  cat >"$rbin/fakeh-cli" <<'FAKE'
#!/bin/sh
printf '{"review":"**No findings.** FAKEH-RAN"}\n'
FAKE
  chmod 755 "$rbin/fakeh-cli"
  cat >"$fixtures/child.sh" <<CHILD
. "$core/auto-review.sh"
set +e
REVIEWER_CLONE="$rclone"
REVIEWER_PERIMETER=()
sleep() { command sleep 0.05; }
AUTO_REVIEW_TIMEOUT=100000000
HARNESS=fakeh
run_reviewer 1 "$fixtures/fakeh-out.md" "$rclone/.auto-review-history.md" \
  "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md"
CHILD
  bash "$fixtures/child.sh" >"$fixtures/fakeh.log" 2>&1
  fakeh_rc=$?
  check "a dropped-in adapter file alone is enough: run_reviewer succeeds with HARNESS=fakeh" 0 "$fakeh_rc"
  [ "$fakeh_rc" = 0 ] || tail -n 5 "$fixtures/fakeh.log"
  has "a dropped-in adapter file alone is enough: its CLI produced the review" \
    "$(head -c 120 "$fixtures/fakeh-out.md" 2>/dev/null)" "FAKEH-RAN"

  exit "$fail"
)

# ==============================================================================
# Section 2: Claude Code harness adapter pure helpers
# ==============================================================================
section_2() (
  # shellcheck disable=SC1091
  . "$here/adapters/harness/claude-code.sh"
  fail=0

  check_status() {
    local name="$1" want_status="$2"
    shift 2
    local status=0
    "$@" >/dev/null 2>&1 || status=1
    if [ "$want_status" = "$status" ]; then
      printf 'ok    %s\n' "$name"
    else
      printf 'FAIL  %s\n  want status: %s\n  got status:  %s\n' "$name" "$want_status" "$status"
      fail=1
    fi
  }
  has_line() {
    if printf '%s\n' "$3" | grep -Fqx -e "$2"; then
      printf 'ok    %s\n' "$1"
    else
      printf 'FAIL  %s\n  missing expected line: %s\n' "$1" "$2"
      fail=1
    fi
  }
  lacks_line() {
    if printf '%s\n' "$3" | grep -Fqx -e "$2"; then
      printf 'FAIL  %s\n  found unwanted line: %s\n' "$1" "$2"
      fail=1
    else
      printf 'ok    %s\n' "$1"
    fi
  }

  fixtures=$(mktemp -d)
  trap 'rm -rf "$fixtures"' EXIT

  touch "$fixtures/prompt.md"
  touch "$fixtures/empty_history.md"
  printf 'Previous review notes\n' >"$fixtures/history.md"

  args_with_history="$(harness_claude_build_args "opus" "$fixtures/prompt.md" "$fixtures/history.md")"
  has_line "build_args: model flag" "--model" "$args_with_history"
  has_line "build_args: model value" "opus" "$args_with_history"
  has_line "build_args: restricted tools flag" "--tools" "$args_with_history"
  has_line "build_args: restricted tools value Read,Grep,Glob" "Read,Grep,Glob" "$args_with_history"
  lacks_line "build_args: no skip permissions flag (the reviewer is read-only, an earlier change)" "--dangerously-skip-permissions" "$args_with_history"
  has_line "build_args: system prompt flag" "--append-system-prompt" "$args_with_history"
  has_line "build_args: system prompt file" "$fixtures/history.md" "$args_with_history"
  has_line "build_args: prompt flag" "-p" "$args_with_history"

  args_empty_history="$(harness_claude_build_args "sonnet" "$fixtures/prompt.md" "$fixtures/empty_history.md")"
  lacks_line "build_args without history: no system prompt flag" "--append-system-prompt" "$args_empty_history"
  has_line "build_args without history: model sonnet" "sonnet" "$args_empty_history"

  printf '**No findings.**\n\nLGTM.\n' >"$fixtures/v_clean.txt"
  out="$(harness_claude_parse_verdict "$fixtures/v_clean.txt")"
  check "parse_verdict: clean" "NO_FINDINGS" "$out"
  check_status "parse_verdict status: clean" 0 harness_claude_parse_verdict "$fixtures/v_clean.txt"
  check "count_findings: clean" 0 "$(harness_claude_count_findings "$fixtures/v_clean.txt")"

  printf '\n\n**No findings.**\n' >"$fixtures/v_clean_blank.txt"
  out="$(harness_claude_parse_verdict "$fixtures/v_clean_blank.txt")"
  check "parse_verdict: clean with leading blank lines" "NO_FINDINGS" "$out"

  printf '**1 finding**\n\n1. Memory leak in cache loop.\n' >"$fixtures/v_1.txt"
  out="$(harness_claude_parse_verdict "$fixtures/v_1.txt")"
  check "parse_verdict: 1 finding" "FINDINGS:1" "$out"
  check_status "parse_verdict status: 1 finding" 0 harness_claude_parse_verdict "$fixtures/v_1.txt"
  check "count_findings: 1 finding" 1 "$(harness_claude_count_findings "$fixtures/v_1.txt")"

  printf '**5 findings**\n\n1. First issue.\n2. Second issue.\n' >"$fixtures/v_5.txt"
  out="$(harness_claude_parse_verdict "$fixtures/v_5.txt")"
  check "parse_verdict: 5 findings" "FINDINGS:5" "$out"
  check "count_findings: 5 findings" 5 "$(harness_claude_count_findings "$fixtures/v_5.txt")"

  printf 'Hello! I reviewed your code and it looks pretty good.\n' >"$fixtures/v_malformed.txt"
  out="$(harness_claude_parse_verdict "$fixtures/v_malformed.txt" 2>/dev/null || true)"
  check "parse_verdict: malformed" "MALFORMED" "$out"
  check_status "parse_verdict status: malformed" 1 harness_claude_parse_verdict "$fixtures/v_malformed.txt"
  check "count_findings: malformed" 0 "$(harness_claude_count_findings "$fixtures/v_malformed.txt")"

  touch "$fixtures/v_empty.txt"
  out="$(harness_claude_parse_verdict "$fixtures/v_empty.txt" 2>/dev/null || true)"
  check "parse_verdict: empty file" "MALFORMED" "$out"
  check_status "parse_verdict status: empty file" 1 harness_claude_parse_verdict "$fixtures/v_empty.txt"

  out="$(harness_claude_parse_verdict "$fixtures/nonexistent.txt" 2>/dev/null || true)"
  check "parse_verdict: nonexistent file" "MALFORMED" "$out"
  check_status "parse_verdict status: nonexistent file" 1 harness_claude_parse_verdict "$fixtures/nonexistent.txt"

  exit "$fail"
)

# ==============================================================================
# Section 3: Task adapter (github-issues.sh)
# ==============================================================================
section_3() (
  # shellcheck disable=SC1091
  . "$here/adapters/task/github-issues.sh"
  fail=0

  check_match() {
    if [[ "$3" =~ $2 ]]; then
      printf 'ok    %s\n' "$1"
    else
      printf 'FAIL  %s\n  pattern: %s\n  got:     %s\n' "$1" "$2" "$3"
      fail=1
    fi
  }
  log() { :; }

  fixtures=$(mktemp -d)
  trap 'rm -rf "$fixtures"' EXIT

  got="$(task_parse_references "Closes #23")"
  check "parse: single closes shorthand" "#23" "$got"

  got="$(task_parse_references "Part of #56")"
  check "parse: single part of shorthand" "#56" "$got"

  got="$(task_parse_references "fixes #89 and resolves #11")"
  want=$(printf '#89\n#11')
  check "parse: multiple keywords on one line" "$want" "$got"

  got="$(task_parse_references "Ref #42; refs #99")"
  want=$(printf '#42\n#99')
  check "parse: case-insensitive ref keywords" "$want" "$got"

  got="$(task_parse_references "Tracked at https://github.com/acme/webapp/issues/27 in repo")"
  check "parse: full issue URL" "acme/webapp#27" "$got"

  multiline="This PR implements the task.
Closes #10
Part of #20
Related to https://github.com/other/project/issues/30
Also fixes #10 again (duplicate).
"
  got="$(task_parse_references "$multiline")"
  want=$(printf '%s\n%s\n%s' '#10' '#20' 'other/project#30')
  check "parse: multiline with URL and deduplication" "$want" "$got"

  got="$(task_parse_references "Just a small cosmetic change with no ticket.")"
  check "parse: description without references" "" "$got"

  got="$(task_parse_references "")"
  check "parse: empty description" "" "$got"

  task_write_fallback "$fixtures/fallback.md"
  check "fallback: file exists" "0" "$?"
  content="$(cat "$fixtures/fallback.md")"
  check_match "fallback: contains header" "Task Briefing" "$content"
  check_match "fallback: contains explanation" "No linked task found" "$content"

  gh() {
    local num="" repo=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="$2"; shift 2 ;;
        issue) shift ;;
        view) num="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ "$num" = "27" ]; then
      printf '# Task Briefing: #27 — Platform-agnostic auto-review\n\n**Repository**: %s\n**State**: OPEN\n**Labels**: enhancement, core\n\n## Acceptance Criteria & Description\n\nMake auto-review independent machine container.\n' "$repo"
      return 0
    fi
    return 1
  }

  task_fetch_briefing "org/repo" "#27" "$fixtures/briefing_27.md"
  content="$(cat "$fixtures/briefing_27.md")"
  check_match "fetch: contains issue title" "Platform-agnostic auto-review" "$content"
  check_match "fetch: contains repository" "org/repo" "$content"
  check_match "fetch: contains state" "OPEN" "$content"
  check_match "fetch: contains acceptance criteria" "Make auto-review independent machine container" "$content"

  task_fetch_briefing "org/default" "external/other#27" "$fixtures/briefing_cross.md"
  content="$(cat "$fixtures/briefing_cross.md")"
  check_match "fetch cross-repo: targets external repo" "external/other" "$content"

  task_fetch_briefing "org/repo" "#98" "$fixtures/briefing_fail.md"
  check "fetch failure: exit status is 0" "0" "$?"
  content="$(cat "$fixtures/briefing_fail.md")"
  check_match "fetch failure: writes fallback notice" "No linked task found" "$content"

  body="Implement core decoupling.
Closes #27
Part of #30
"
  task_build_briefing "org/repo" "$body" "$fixtures/briefing_e2e.md"
  content="$(cat "$fixtures/briefing_e2e.md")"
  check_match "e2e: primary briefing rendered" "Platform-agnostic auto-review" "$content"
  check_match "e2e: additional linked tasks listed" "Additional linked tasks" "$content"
  check_match "e2e: contains secondary task ref" "#30" "$content"

  task_build_briefing "org/repo" "No ticket for this PR" "$fixtures/briefing_empty.md"
  content="$(cat "$fixtures/briefing_empty.md")"
  check_match "e2e without ticket: fallback rendered" "No linked task found" "$content"

  got="$(task_parse_references "Part of #67
Closes #42")"
  check "rank: closing first although part of comes first in the body" "$(printf '#42\n#67')" "$got"

  got="$(task_rank_references "Part of #67
Closes #42
see https://github.com/o/r/issues/5")"
  check "rank: kinds" "$(printf 'closing\t#42\nrelated\t#67\nrelated\t%s' 'o/r#5')" "$got"

  got="$(task_parse_references "Refs #7 and later Fixes #7")"
  check "rank: a reference seen as related and then as closing is closing" "#7" "$got"
  check "rank: ... and said once" "closing" "$(task_rank_references "Refs #7 and later Fixes #7" | cut -f1)"

  got="$(task_parse_references "Closes acme/webapp#42, part of Other/Repo#12")"
  check "parse: owner/repo#N after a keyword, case kept" "$(printf '%s\n%s' 'acme/webapp#42' 'Other/Repo#12')" "$got"

  got="$(task_parse_references "prefix #5 and the unfixes #6")"
  check "parse: prefix and unfixes are not keywords" "" "$got"

  gh() {
    case "$1 $2" in
      "pr view")
        case " $* " in
          *closingIssuesReferences*) printf 'org/repo#99\n'; return 0 ;;
        esac
        return 1 ;;
      "issue view")
        local num="$3" args="$*"
        case "$args" in
          *"-q"*"Parent task"*)
            case "$num" in
              67) printf '# Parent task: #67 — The epic\n\n**Repository**: org/repo\n**State**: OPEN'; return 0 ;;
              *) return 1 ;;
            esac ;;
          *"--json body"*)
            case "$num" in
              67) printf 'A long description of the epic that must not reach the reviewer.\n\n## Acceptance\n\n- [ ] one\n- [ ] two\n\n## Notes\n\nprivate notes\n'; return 0 ;;
              *) return 1 ;;
            esac ;;
          *)
            case "$num" in
              77) printf '# Task Briefing: #77 — About the fallback notice\n\n**Repository**: org/repo\n**State**: OPEN\n\n## Acceptance Criteria & Description\n\nThe briefing says "No linked task found" when nothing is linked.\n'; return 0 ;;
              42|99|12|13|14) printf '# Task Briefing: #%s — Task %s\n\n**Repository**: org/repo\n**State**: OPEN\n\n## Acceptance Criteria & Description\n\nDo %s\n' "$num" "$num" "$num"; return 0 ;;
              *) return 1 ;;
            esac ;;
        esac ;;
    esac
    return 1
  }

  task_build_briefing "org/repo" "Part of #67
Closes #42" "$fixtures/rank.md"
  content="$(cat "$fixtures/rank.md")"
  check_match "briefing: the closing issue comes first, in full" "^# Task Briefing: #42 — Task 42" "$content"
  check_match "briefing: the epic follows as a parent" "Parent task: #67 — The epic" "$content"
  check_match "briefing: the epic's acceptance list is in" "- \[ \] two" "$content"
  if [[ "$content" == *"must not reach the reviewer"* || "$content" == *"private notes"* ]]; then
    printf 'FAIL  briefing: the epic contributes only its title and acceptance list\n'; fail=1
  else
    printf 'ok    briefing: the epic contributes only its title and acceptance list\n'
  fi

  task_build_briefing "org/repo" "No keyword in this body" "$fixtures/sidebar.md" 55
  content="$(cat "$fixtures/sidebar.md")"
  check_match "sidebar: an issue linked from the pull request's sidebar is the task" "^# Task Briefing: #99 — Task 99" "$content"

  task_build_briefing "org/repo" "Closes #42
Closes #12
Closes #13
Closes #14" "$fixtures/four.md"
  content="$(cat "$fixtures/four.md")"
  n="$(grep -c '^# Task Briefing' "$fixtures/four.md")"
  check "four closing issues: three are fetched" "3" "$n"
  check_match "four closing issues: the fourth is listed by number" "Additional linked tasks\*\*: #14" "$content"

  task_build_briefing "org/repo" "Closes #42
Closes #44" "$fixtures/unreadable.md"
  content="$(cat "$fixtures/unreadable.md")"
  check_match "unreadable secondary: listed" "Additional linked tasks\*\*: #44" "$content"

  task_build_briefing "org/repo" "Closes org/repo#42 and fixes #42" "$fixtures/same.md"
  check "same repository, written out or not, is fetched once" "1" "$(grep -c '^# Task Briefing' "$fixtures/same.md")"

  task_build_briefing "org/repo" "Cosmetic change, no ticket." "$fixtures/none.md"
  check_match "no task, with a description: checked against the description" "task: none linked, checked against the description" "$(cat "$fixtures/none.md")"
  task_build_briefing "org/repo" "" "$fixtures/nobody.md"
  check_match "no task, no description: acceptance not checked" "task: none, acceptance not checked" "$(cat "$fixtures/nobody.md")"
  task_build_briefing "org/repo" "   " "$fixtures/blank.md"
  check_match "no task, a blank description: acceptance not checked" "task: none, acceptance not checked" "$(cat "$fixtures/blank.md")"

  task_build_briefing "org/repo" "Closes #44" "$fixtures/lonely.md"
  content="$(cat "$fixtures/lonely.md")"
  check_match "unreadable only task: named as unreadable" "could not be read: #44" "$content"
  check_match "unreadable only task: acceptance not checked" "acceptance not checked" "$content"
  if [[ "$content" == *"No linked task found"* ]]; then
    printf 'FAIL  unreadable only task: must not claim that no task is linked\n'; fail=1
  else
    printf 'ok    unreadable only task: does not claim that no task is linked\n'
  fi

  task_build_briefing "org/repo" "Closes #77" "$fixtures/quoting.md"
  content="$(cat "$fixtures/quoting.md")"
  check_match "a readable issue that quotes the notice is the task" "^# Task Briefing: #77 — About the fallback notice" "$content"
  if [[ "$content" == *"could not be read"* ]]; then
    printf 'FAIL  a readable issue that quotes the notice is not reported unreadable\n'; fail=1
  else
    printf 'ok    a readable issue that quotes the notice is not reported unreadable\n'
  fi

  exit "$fail"
)

# ==============================================================================
# Section 4: Harness models, set-global, and agy Gemini 4 model/effort catalog
# ==============================================================================
section_4() (
  script="$here/auto-review.sh"
  adir="$here/adapters/harness"
  fx=$(mktemp -d)
  trap 'rm -r -f "$fx"' EXIT
  fail=0

  refused() { check "$1" 1 "$([ "$2" -ne 0 ] && echo 1 || echo 0)"; }
  reg="$fx/projects.json"
  export AUTO_REVIEW_REGISTRY="$reg"
  ar() { bash "$script" "$@"; }
  jget() { jq -r "$1" "$reg"; }
  jok() { jq -e "$1" >/dev/null 2>&1 && echo true || echo false; }

  for f in "$adir"/*.sh; do
    h=$(basename "$f" .sh)
    out=$(bash -c '
      . "$1" >/dev/null 2>&1
      p=$(declare -F | awk "{print \$3}" | sed -n "s/^harness_\(.*\)_execute\$/\1/p" | head -n 1)
      if declare -F "harness_${p}_models" >/dev/null; then echo HAS_MODELS; fi
      if declare -F "harness_${p}_default_model" >/dev/null; then echo HAS_DEFAULT; fi
      "harness_${p}_models" 2>/dev/null | sed "s/^/M:/"
      echo "D:$("harness_${p}_default_model" 2>/dev/null)"
    ' _ "$f" 2>&1)
    case "$out" in *HAS_MODELS*) m=yes ;; *) m=no ;; esac
    case "$out" in *HAS_DEFAULT*) d=yes ;; *) d=no ;; esac
    check "adapter $h defines harness_P_models" yes "$m"
    check "adapter $h defines harness_P_default_model" yes "$d"
    def=$(printf '%s\n' "$out" | sed -n 's/^D://p')
    n=$(printf '%s\n' "$out" | grep -c '^M:.\+')
    [ "$n" -ge 1 ] && nz=yes || nz=no
    check "adapter $h lists at least one model" yes "$nz"
    [ -n "$def" ] && dz=yes || dz=no
    check "adapter $h default is one non-empty name" yes "$dz"
    printf '%s\n' "$out" | grep -qx "M:$def" && inl=yes || inl=no
    check "adapter $h default ($def) is in its list" yes "$inl"
  done

  ja=$(ar models agy 2>/dev/null)
  check "models agy: valid JSON object" true "$(printf '%s' "$ja" | jok 'type=="object"')"
  check "models agy: names the harness" agy "$(printf '%s' "$ja" | jq -r '.harness' 2>/dev/null)"
  check "models agy: models is a non-empty array of strings" true \
    "$(printf '%s' "$ja" | jok '(.models|type)=="array" and (.models|length)>0 and all(.models[]; type=="string")')"
  check "models agy: default is in models" true \
    "$(printf '%s' "$ja" | jok '.default as $d | .models | index($d) != null')"
  check "models agy: offers auto" true "$(printf '%s' "$ja" | jok '.models | index("auto") != null')"
  jc=$(ar models claude-code 2>/dev/null)
  check "models claude-code: offers sonnet opus haiku" true \
    "$(printf '%s' "$jc" | jok '.models as $m | all(("sonnet","opus","haiku"); . as $x | $m | index($x) != null)')"
  check "models claude-code: does not offer flash" true \
    "$(printf '%s' "$jc" | jok '.models | index("flash") == null')"
  jall=$(ar models 2>/dev/null)
  check "models: one JSON document that covers every adapter" true \
    "$(printf '%s' "$jall" | jok 'tostring | contains("agy") and contains("claude-code")')"
  ar models nosuchharness >/dev/null 2>&1; rc=$?
  ok_known=$(printf %s "$jc" | jok '(.models|length)>0')
  refused "models: unknown harness is refused (and a known one is served)" "$([ "$ok_known" = true ] && echo $rc || echo 0)"

  agydef_want=$(printf '%s' "$ja" | jq -r .default 2>/dev/null)
  clddef_want=$(printf '%s' "$jc" | jq -r .default 2>/dev/null)

  rm -f "$reg"
  ar set-global harness claude-code >/dev/null 2>&1
  ar set-global model opus >/dev/null 2>&1
  ar set-global harness agy >/dev/null 2>&1
  check "set-global harness agy: harness written" agy "$(jget .harness)"
  check "set-global harness agy: model is agy's default" "$agydef_want" "$(jget .model)"
  check "set-global harness agy: model is not left as opus" true "$([ "$(jget .model)" != opus ] && echo true || echo false)"

  rm -f "$reg"
  ar set-global harness claude-code >/dev/null 2>&1
  ar set-global model sonnet >/dev/null 2>&1
  seen="$fx/seen"; : >"$seen"
  ( while [ ! -e "$fx/stop" ]; do jq -r '"\(.harness) \(.model)"' "$reg" 2>/dev/null >>"$seen"; done ) &
  poller=$!
  ar set-global harness agy >/dev/null 2>&1
  sleep 0.2; : >"$fx/stop"; wait "$poller" 2>/dev/null; rm -f "$fx/stop"
  newdef=$(jget .model)
  mixed=$(sort -u "$seen" | grep -v -e '^claude-code sonnet$' -e "^agy $newdef\$" | grep -c .)
  check "set-global harness agy: no intermediate (harness,model) pair is ever visible" 0 "$mixed"
  check "set-global harness agy: the pair did change (poll saw the new one)" "agy $agydef_want" "$(printf 'agy %s' "$newdef")"

  rm -f "$reg"
  ar set-global harness agy >/dev/null 2>&1
  ar set-global model auto >/dev/null 2>&1
  ar set-global harness claude-code >/dev/null 2>&1
  check "set-global harness claude-code: harness written" claude-code "$(jget .harness)"
  check "set-global harness claude-code: model is claude's default" "$clddef_want" "$(jget .model)"
  check "set-global harness claude-code: model is not left as auto" true "$([ "$(jget .model)" != auto ] && echo true || echo false)"

  rm -f "$reg"
  ar set-global harness claude-code >/dev/null 2>&1
  before=$(cat "$reg")
  msg=$(ar set-global model flash 2>&1); rc=$?
  refused "set-global model flash on claude-code: refused" $rc
  check "set-global model flash on claude-code: says something" 1 "$([ -n "$msg" ] && echo 1 || echo 0)"
  check "set-global model flash on claude-code: registry byte-identical" "$before" "$(cat "$reg")"

  ar set-global harness agy >/dev/null 2>&1
  before=$(cat "$reg")
  ar set-global model haiku >/dev/null 2>&1; rc=$?
  refused "set-global model haiku on agy: refused" $rc
  check "set-global model haiku on agy: registry byte-identical" "$before" "$(cat "$reg")"

  ar set-global harness claude-code >/dev/null 2>&1
  ar set-global model opus >/dev/null 2>&1; rc=$?
  check "set-global model opus on claude-code: accepted" 0 "$rc"
  check "set-global model opus on claude-code: written" opus "$(jget .model)"
  ar set-global harness agy >/dev/null 2>&1
  ar set-global model pro >/dev/null 2>&1; rc=$?
  check "set-global model pro on agy: accepted" 0 "$rc"
  check "set-global model pro on agy: written" pro "$(jget .model)"

  before=$(cat "$reg")
  msg=$(ar set-global harness nosuchharness 2>&1); rc=$?
  refused "set-global harness nosuchharness: refused" $rc
  check "set-global harness nosuchharness: says something" 1 "$([ -n "$msg" ] && echo 1 || echo 0)"
  check "set-global harness nosuchharness: registry byte-identical" "$before" "$(cat "$reg")"

  radopt() { bash -c '. "$1"; shift; registry_adopt "$@"' _ "$here/lib/registry.sh" "$@"; }
  rm -f "$reg"
  ar set-global harness claude-code >/dev/null 2>&1
  radopt "$reg" acme/web
  radopt "$reg" acme/keep --all
  projects_before=$(jget '.projects')
  ar set-global harness agy >/dev/null 2>&1
  check "set-global harness agy: projects are left as they were" "$projects_before" "$(jget '.projects')"
  check "set-global harness agy: no project gained a model or harness" 0 \
    "$(jget '[.projects[] | select(has("model") or has("harness"))] | length')"
  ar set-global harness claude-code >/dev/null 2>&1
  check "set-global harness claude-code: model is claude's default again" "$clddef_want" "$(jget .model)"

  rm -f "$reg"
  ar set-global harness claude-code >/dev/null 2>&1
  radopt "$reg" acme/web
  ar set-global model haiku >/dev/null 2>&1; rc=$?
  check "set-global model haiku with a registered project: accepted" 0 "$rc"
  check "set-global model haiku with a registered project: written" haiku "$(jget .model)"

  . "$adir/agy.sh"
  agy_models_list=$(harness_agy_models)
  for m in neon-low neon-medium neon neon-xhigh orchestrator-neon; do
    check "harness_agy_models offers $m" present \
      "$(printf '%s\n' "$agy_models_list" | grep -qx -- "$m" && echo present || echo absent)"
  done

  model_cases=(
    "auto gemini-4-hydrogen-high"
    "flash gemini-4-hydrogen-medium"
    "flash-low gemini-4-hydrogen-low"
    "flash-high gemini-4-hydrogen-high"
    "hydrogen gemini-4-hydrogen-high"
    "hydrogen-low gemini-4-hydrogen-low"
    "hydrogen-medium gemini-4-hydrogen-medium"
    "hydrogen-xhigh gemini-4-hydrogen-xhigh"
    "pro gemini-4-carbon-high"
    "carbon gemini-4-carbon-high"
    "carbon-low gemini-4-carbon-low"
    "carbon-medium gemini-4-carbon-medium"
    "argon gemini-4-argon-medium"
    "argon-low gemini-4-argon-low"
    "argon-high gemini-4-argon-high"
    "neon-low gemini-4-neon-low"
    "neon-medium gemini-4-neon-medium"
    "neon gemini-4-neon-high"
    "neon-xhigh gemini-4-neon-xhigh"
    "neon:low gemini-4-neon-low"
    "neon:medium gemini-4-neon-medium"
    "neon:high gemini-4-neon-high"
    "neon:xhigh gemini-4-neon-xhigh"
    "gemini-4-neon:low gemini-4-neon-low"
    "gemini-4-neon:xhigh gemini-4-neon-xhigh"
    "orchestrator gemini-pro-orchestrator"
    "orchestrator-argon gemini-pro-orchestrator-argon"
    "orchestrator-neon gemini-pro-orchestrator-neon"
    "orchestrator-neon:high gemini-pro-orchestrator-neon"
    "flash-3.8 gemini-3.8-flash-medium"
    "flash-3.8:low gemini-3.8-flash-low"
    "gemini-3.8-flash gemini-3.8-flash-medium"
    "gemini-4-hydrogen:low gemini-4-hydrogen-low"
    "gemini-4-carbon:medium gemini-4-carbon-medium"
    "hydrogen:low gemini-4-hydrogen-low"
    "carbon:medium gemini-4-carbon-medium"
    "orchestrator:high gemini-pro-orchestrator"
  )
  for entry in "${model_cases[@]}"; do
    input="${entry%% *}"
    want="${entry#* }"
    check "harness_agy_model $input -> $want" "$want" "$(harness_agy_model "$input")"
  done

  agy_effort() {
    if declare -F harness_agy_effort >/dev/null 2>&1; then
      harness_agy_effort "$1"
    else
      printf '__undefined__\n'
    fi
  }
  check "harness_agy_effort orchestrator:high -> high" "high" "$(agy_effort "orchestrator:high")"
  check "harness_agy_effort hydrogen:low -> empty" "" "$(agy_effort "hydrogen:low")"
  check "harness_agy_effort neon:high -> empty" "" "$(agy_effort "neon:high")"
  check "harness_agy_effort orchestrator-neon:high -> high" "high" "$(agy_effort "orchestrator-neon:high")"

  agy_execute_args() {
    local m="$1"
    (
      harness_agy_seed() { :; }
      reviewer_launch() {
        shift 2
        printf '%s\n' "$@"
      }
      raw="$fx/raw"
      err="$fx/err"
      local rc=0
      harness_agy_execute "$fx" "$m" "test task" "" "$raw" "$err" || rc=$?
      wait "${REVIEWER_PID:-}" 2>/dev/null || true
      cat "$raw" 2>/dev/null
      return "$rc"
    )
  }

  args_orch=$(agy_execute_args "orchestrator:high")
  check "harness_agy_execute orchestrator:high passes --effort flag" present \
    "$(printf '%s\n' "$args_orch" | grep -qx -- '--effort' && echo present || echo absent)"
  check "harness_agy_execute orchestrator:high passes effort high" high \
    "$(printf '%s\n' "$args_orch" | grep -A1 -x -- '--effort' | tail -n 1)"
  check "harness_agy_execute orchestrator:high passes model gemini-pro-orchestrator" gemini-pro-orchestrator \
    "$(printf '%s\n' "$args_orch" | grep -A1 -x -- '--model' | tail -n 1)"

  args_hyd=$(agy_execute_args "hydrogen:low")
  check "harness_agy_execute hydrogen:low omits --effort" absent \
    "$(printf '%s\n' "$args_hyd" | grep -qx -- '--effort' && echo present || echo absent)"
  check "harness_agy_execute hydrogen:low passes model gemini-4-hydrogen-low" gemini-4-hydrogen-low \
    "$(printf '%s\n' "$args_hyd" | grep -A1 -x -- '--model' | tail -n 1)"

  args_auto=$(agy_execute_args "auto")
  check "harness_agy_execute auto omits --effort" absent \
    "$(printf '%s\n' "$args_auto" | grep -qx -- '--effort' && echo present || echo absent)"
  check "harness_agy_execute auto passes model gemini-4-hydrogen-high" gemini-4-hydrogen-high \
    "$(printf '%s\n' "$args_auto" | grep -A1 -x -- '--model' | tail -n 1)"

  check "harness_agy_model orchestrator-argon:low -> gemini-pro-orchestrator-argon" \
    "gemini-pro-orchestrator-argon" "$(harness_agy_model "orchestrator-argon:low")"
  check "harness_agy_effort orchestrator-argon:low -> low" \
    "low" "$(agy_effort "orchestrator-argon:low")"
  args_orch_arg=$(agy_execute_args "orchestrator-argon:low")
  check "harness_agy_execute orchestrator-argon:low passes --effort flag" present \
    "$(printf '%s\n' "$args_orch_arg" | grep -qx -- '--effort' && echo present || echo absent)"
  check "harness_agy_execute orchestrator-argon:low passes effort low" low \
    "$(printf '%s\n' "$args_orch_arg" | grep -A1 -x -- '--effort' | tail -n 1)"
  check "harness_agy_execute orchestrator-argon:low passes model gemini-pro-orchestrator-argon" gemini-pro-orchestrator-argon \
    "$(printf '%s\n' "$args_orch_arg" | grep -A1 -x -- '--model' | tail -n 1)"

  args_neon=$(agy_execute_args "neon:high")
  check "harness_agy_execute neon:high omits --effort" absent \
    "$(printf '%s\n' "$args_neon" | grep -qx -- '--effort' && echo present || echo absent)"
  check "harness_agy_execute neon:high passes model gemini-4-neon-high" gemini-4-neon-high \
    "$(printf '%s\n' "$args_neon" | grep -A1 -x -- '--model' | tail -n 1)"

  args_orch_neon=$(agy_execute_args "orchestrator-neon:high")
  check "harness_agy_execute orchestrator-neon:high passes --effort flag" present \
    "$(printf '%s\n' "$args_orch_neon" | grep -qx -- '--effort' && echo present || echo absent)"
  check "harness_agy_execute orchestrator-neon:high passes effort high" high \
    "$(printf '%s\n' "$args_orch_neon" | grep -A1 -x -- '--effort' | tail -n 1)"
  check "harness_agy_execute orchestrator-neon:high passes model gemini-pro-orchestrator-neon" gemini-pro-orchestrator-neon \
    "$(printf '%s\n' "$args_orch_neon" | grep -A1 -x -- '--model' | tail -n 1)"

  unsupported_effort_cases=(
    "sonnet:high" "opus:high" "carbon:xhigh" "argon:xhigh"
    "hydrogen:bogus" "orchestrator:bogus" "neon:max" "neon:bogus" "orchestrator-neon:bogus"
  )
  for m in "${unsupported_effort_cases[@]}"; do
    harness_agy_model "$m" >/dev/null 2>&1; rc=$?
    refused "harness_agy_model $m: unsupported effort refused" "$rc"
    harness_agy_effort "$m" >/dev/null 2>&1; rc=$?
    refused "harness_agy_effort $m: unsupported effort refused" "$rc"
    agy_execute_args "$m" >/dev/null 2>&1; rc=$?
    refused "harness_agy_execute $m: unsupported effort refused" "$rc"
  done

  exit "$fail"
)

# ==============================================================================
# Section 5: Prompt rendering, golden files, placeholders, and defect checks
# ==============================================================================
section_5() (
  root="$here"
  fix="$here/tests/fixtures/auto-review-prompt"
  fail=0; ok=0
  pass() { ok=$((ok + 1)); }
  bad() { fail=$((fail + 1)); echo "FAIL: $*"; }

  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  printf 'earlier review\n' > "$tmp/history.md"
  : > "$tmp/empty.md"

  # shellcheck disable=SC1091
  . "$root/lib/prompt.sh"
  SELF="$root.sh"
  REVIEW_SENTINEL=AUTO-REVIEW-BEGIN

  render_case() {
    local h="$tmp/$1.md"
    {
      reviewer_guidance "$h" /tmp/gold/pr.diff /tmp/gold/pr.md
      printf '\n=====TASK=====\n'
      reviewer_task 42 /tmp/gold/pr.diff /tmp/gold/pr.md
    } | sed "s|$tmp/history.md|@HISTORY@|g"
  }

  for name in empty history; do
    render_case "$name" > "$tmp/$name.out"
    if [ -n "${UPDATE_GOLDEN:-}" ]; then cp "$tmp/$name.out" "$fix/$name.golden"; fi
    if [ ! -f "$fix/$name.golden" ]; then
      bad "$name: no golden file"
    elif cmp -s "$tmp/$name.out" "$fix/$name.golden"; then
      pass
    else
      bad "$name differs from its golden file"
      diff "$fix/$name.golden" "$tmp/$name.out" | head -8
    fi
  done

  for f in "$root"/prompt/*.md; do
    left=$(grep -o '{{[a-z_]*}}' "$f" | sort -u | grep -v -x -e '{{sentinel}}' -e '{{pr}}' -e '{{diff}}' -e '{{meta}}' -e '{{history}}' || true)
    if [ -n "$left" ]; then bad "$(basename "$f"): unknown placeholder $left"; else pass; fi
  done

  if render_case history | grep -q '{{'; then bad "a placeholder survived rendering"; else pass; fi

  out=$(reviewer_task 'a&b' '/tmp/x\y' '/tmp/m&n')
  case "$out" in *'#a&b'*'/tmp/x\y'*'/tmp/m&n'*) pass ;; *) bad "special characters in a value were changed" ;; esac

  if (prompt_dir() { return 1; }; reviewer_task 1 a b) >/dev/null 2>&1; then bad "a missing prompt directory rendered a task"; else pass; fi
  if (prompt_dir() { return 1; }; reviewer_guidance "$tmp/empty.md" a b) >/dev/null 2>&1; then bad "a missing prompt directory rendered guidance"; else pass; fi
  for gone in guidance history reading task; do
    cp -r "$root/prompt" "$tmp/p-$gone"; rm "$tmp/p-$gone/$gone.md"
    (
      prompt_dir() { printf '%s\n' "$tmp/p-$gone"; }
      if [ "$gone" = task ]; then reviewer_task 1 a b; else reviewer_guidance "$tmp/history.md" a b; fi
    ) >/dev/null 2>&1 && bad "missing $gone.md was not an error" || pass
  done

  for gone in guidance task; do
    cp -r "$root/prompt" "$tmp/q-$gone"; rm "$tmp/q-$gone/$gone.md"
    rm -f "$tmp/loaded" "$tmp/rc"
    (
      # shellcheck disable=SC1091
      . "$root.sh"
      set +e
      prompt_dir() { printf '%s\n' "$tmp/q-$gone"; }
      harness_load() { : >"$tmp/loaded"; return 1; }
      log() { :; }
      REVIEWER_WORKDIR=$(mktemp -d "$tmp/clone.XXXXXX")
      run_reviewer_in 7 "$tmp/out" "$tmp/empty.md" /dev/null /dev/null
      echo $? >"$tmp/rc"
    ) >/dev/null 2>&1
    if [ -f "$tmp/rc" ] && [ "$(cat "$tmp/rc")" != 0 ] && [ ! -e "$tmp/loaded" ]; then pass; else bad "run_reviewer_in went on without $gone.md"; fi
  done

  if READING_PLAN=1 reviewer_guidance "$tmp/empty.md" a b | grep -q '^READING-PLAN-BEGIN$'; then pass; else bad "no plan section above the threshold"; fi
  if READING_PLAN=0 reviewer_guidance "$tmp/empty.md" a b | grep -q 'READING-PLAN'; then bad "a plan was asked for below the threshold"; else pass; fi
  if (READING_PLAN=1; cp -r "$root/prompt" "$tmp/p-plan"; rm "$tmp/p-plan/plan.md"; prompt_dir() { printf '%s\n' "$tmp/p-plan"; }; reviewer_guidance "$tmp/empty.md" a b) >/dev/null 2>&1; then bad "a missing plan.md was not an error"; else pass; fi

  if READING_PLAN=1 READING_OVER=1 reviewer_guidance "$tmp/empty.md" a b | grep -q 'over the read budget'; then pass; else bad "no budget paragraph over the read budget"; fi
  if READING_PLAN=1 READING_OVER=0 reviewer_guidance "$tmp/empty.md" a b | grep -q 'over the read budget'; then bad "budget paragraph under the budget"; else pass; fi

  task_out="$(reviewer_task 86 /tmp/gold/pr.diff /tmp/gold/pr.md)"
  task_norm=$(printf '%s' "$task_out" | tr '\n' ' ' | tr -s ' ')

  if printf '%s' "$task_norm" | grep -q 'adjacent valid or invalid input'; then pass; else bad "task missing adjacent valid or invalid input defect criterion"; fi
  if printf '%s' "$task_norm" | grep -q 'canonical module or helper'; then pass; else bad "task missing canonical module or helper defect criterion"; fi
  if printf '%s' "$task_norm" | grep -q 'heuristic parsing or guessing in a `Reader`' && printf '%s' "$task_norm" | grep -q 'upstream `Writer`'; then pass; else bad "task missing Reader/Writer heuristic parsing defect criterion"; fi
  if printf '%s' "$task_norm" | grep -q 'caller-specific branch'; then pass; else bad "task missing caller-specific branch defect criterion"; fi
  if printf '%s' "$task_norm" | grep -q 'unindexed payload expression'; then pass; else bad "task missing unindexed payload expression defect criterion"; fi

  if printf '%s' "$task_norm" | grep -q 'Invariant:' && printf '%s' "$task_norm" | grep -q 'Test:' && printf '%s' "$task_norm" | grep -qE 'concrete.*(input|state)'; then pass; else bad "task missing Invariant:/Test:/concrete input or state grounding"; fi
  if printf '%s' "$task_norm" | grep -q 'canonical owner, sibling site, or `Writer` path'; then pass; else bad "task missing canonical owner, sibling site, or Writer path grounding"; fi
  if printf '%s' "$task_norm" | grep -q 'Formatting, naming, taste, and speculative'; then pass; else bad "task missing exclusion of Formatting, naming, taste, and speculative notes"; fi

  if printf '%s' "$task_norm" | grep -q 'canonical owners, sibling copies, or upstream `Writer`' && printf '%s' "$task_norm" | grep -qiE 'grep.*(canonical|sibling|Writer|reader and writer)' && printf '%s' "$task_norm" | grep -qi 'did not touch'; then pass; else bad "task missing widened cross-tree grep and untouched-file exception"; fi

  if python3 "$root/scripts/scan.py" --tree "$root/prompt" >/dev/null 2>&1; then pass; else bad "prompt/*.md failed scan.py"; fi

  readme_findings=$(sed -n '/^## What the reviewer is given$/,/^## Why the task/p' "$root/README.md" | tr '\n' ' ' | tr -s ' ')
  if printf '%s' "$readme_findings" | grep -qiE 'adjacent (valid|invalid|valid or invalid|valid/invalid) input|overfit'; then pass; else bad "README findings section missing overfit / adjacent input category"; fi
  if printf '%s' "$readme_findings" | grep -qiE 'canonical (module|helper|owner)|sibling (copy|copies|site)'; then pass; else bad "README findings section missing canonical helper / sibling copy category"; fi
  if printf '%s' "$readme_findings" | grep -qE 'Reader.*Writer|Writer.*Reader'; then pass; else bad "README findings section missing Reader/Writer category"; fi
  if printf '%s' "$readme_findings" | grep -qiE 'caller-specific branch|unindexed payload'; then pass; else bad "README findings section missing caller-specific branch / unindexed payload category"; fi
  if printf '%s' "$readme_findings" | grep -q 'Invariant:' && printf '%s' "$readme_findings" | grep -q 'Test:' && printf '%s' "$readme_findings" | grep -qi 'taste' && printf '%s' "$readme_findings" | grep -qi 'speculative'; then pass; else bad "README findings section missing Invariant:/Test: grounding or taste/speculative exclusion"; fi

  if printf '%s' "$task_norm" | grep -q 'Also flag five structural defects when'; then pass; else bad "task missing 'Also flag five structural defects when' count update"; fi
  if printf '%s' "$task_norm" | grep -qiE 'wall-clock|wall clock' && printf '%s' "$task_norm" | grep -q 'Date\.now()' && printf '%s' "$task_norm" | grep -q 'performance\.now()' && printf '%s' "$task_norm" | grep -qiE 'elapsed|duration'; then pass; else bad "task missing wall-clock timing defect criterion (Date.now(), performance.now(), elapsed duration bounds)"; fi
  if printf '%s' "$task_norm" | grep -qiE 'algorithmic|complexity|logic' && printf '%s' "$task_norm" | grep -qi 'deterministic' && printf '%s' "$task_norm" | grep -qiE '(operation|comparison).*counter'; then pass; else bad "task missing deterministic operation or comparison counters alternative for wall-clock timing defect"; fi

  if printf '%s' "$readme_findings" | grep -q 'five structural defect classes'; then pass; else bad "README findings section missing 'five structural defect classes'"; fi
  if printf '%s' "$readme_findings" | grep -qiE 'wall-clock|wall clock|Date\.now\(\)|performance\.now\(\)' && printf '%s' "$readme_findings" | grep -qiE '(operation|comparison).*counter'; then pass; else bad "README findings section missing wall-clock timing vs deterministic operation/comparison counters class"; fi

  echo "prompt: $ok ok, $fail FAIL"
  [ "$fail" -eq 0 ]
)

run_sections_parallel section_1 section_2 section_3 section_4 section_5
exit $?
