#!/usr/bin/env bash
# Consolidated credential management, token status, reviewer uid/env isolation,
# docker exec-as-gate, and untrusted-repo stripping tests for auto-review
# (upstream issue).
# Consolidates:
#   - test-auto-review-credential.sh
#   - test-auto-review-reviewer-credential.sh
#   - test-auto-review-exec-as-gate.sh
#   - test-auto-review-tokens.sh
#   - test-auto-review-token-status.sh
#   - test-auto-review-set.sh
set -u
export AUTO_REVIEW_INSIDE_CONTAINER=1
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
    *"$3"*) printf 'FAIL  %s\n--- must not contain: %s\n--- got\n%s\n' "$1" "$3" "$2"; fail=1 ;;
    *) printf 'ok    %s\n' "$1" ;;
  esac
}

nonzero() { check "$1" 1 "$([ "$2" -ne 0 ] && echo 1 || echo 0)"; }

# ==============================================================================
# Section 1: credential set/list, login, custom adapter, and leak checks
# ==============================================================================
section_1() (
  script="$here/auto-review.sh"
  adir="$here/adapters/harness"
  fixtures=$(mktemp -d)
  chmod 755 "$fixtures"
  trap 'rm -rf "$fixtures"' EXIT
  fail=0

  same() {
    if cmp -s "$2" "$3"; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n--- files differ: %s %s\n' "$1" "$2" "$3"; fail=1; fi
  }
  adapter_prefix() {
    bash -c '. "$1" >/dev/null 2>&1; declare -F | awk "{print \$3}"' _ "$1" 2>/dev/null \
      | sed -n 's/^harness_\(.*\)_execute$/\1/p' | head -n 1
  }
  call_adapter() {
    local file="$1" p="$2" fn="$3"
    shift 3
    bash -c '. "$1"; fn="harness_$2_$3"; declare -F "$fn" >/dev/null || exit 99; shift 3; "$fn" "$@"' _ "$file" "$p" "$fn" "$@" \
      >"$fixtures/o" 2>"$fixtures/e" </dev/null
  }

  MARK1="zQ7mark-claude-9f3a"
  MARK2="zQ7mark-agy-5c1d"
  MARK3="zQ7mark-fakeh-77be"
  CLAUDE_OLD="sk-ant-old-$(printf '%060d' 1)"
  CLAUDE_NEW="sk-ant-$MARK1-$(printf '%060d' 2)"
  AGY_OLD="old-agy-$(printf '%060d' 3)"
  AGY_NEW="$(printf '{"token":"%s-first-line",\n  "refresh":"second line\twith a tab",\n  "x":"%s"}\n' "$MARK2" "$(printf '%050d' 4)")"
  FK_NEW="$(printf '%s-line-one\nline-two-of-the-credential\n' "$MARK3")"

  tokd="$fixtures/tokens"
  cap="$fixtures/cap"
  bindir="$fixtures/userhome/.local/bin"
  adapters="$fixtures/adapters"
  mkdir -p "$fixtures/userhome" "$tokd" "$cap" "$bindir" "$adapters/harness" "$fixtures/tmp" "$fixtures/faults"
  chmod 700 "$tokd"
  export HOME="$fixtures/userhome"
  export TMPDIR="$fixtures/tmp"
  export AUTO_REVIEW_TOKEN_DIR="$tokd"
  export AUTO_REVIEW_LOCK_DIR="$tokd"
  export AUTO_REVIEW_INSIDE_CONTAINER=1
  export AUTO_REVIEW_FAULT_DIR="$fixtures/faults"
  export AUTO_REVIEW_REGISTRY="$fixtures/projects.json"
  export AUTO_REVIEW_STATUS_FILE="$fixtures/status.json"
  export AUTO_REVIEW_CLONE_ROOT="$fixtures/clones"
  export AUTO_REVIEW_ADAPTER_DIR="$adapters"
  export FAKE_CAP="$cap" FAKE_MODE="$fixtures/mode" FAKE_LOGIN_OUT="$fixtures/login-out"
  export FAKE_MARKS="$MARK1 $MARK2 $MARK3"
  export PATH="$bindir:$PATH"
  echo ok >"$FAKE_MODE"
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN

  fake_body() { cat <<'FAKE_EOF'
#!/bin/sh
me=$(basename "$0")
case " $* " in
  *" -p "* | *" check "*) ;;
  *) [ -z "${FAKE_LOGIN_FAIL:-}" ] || { echo "login failed" >&2; exit 1; }
     cat "$FAKE_LOGIN_OUT"; exit 0 ;;
esac
echo x >>"$FAKE_CAP/$me.calls"
for m in $FAKE_MARKS; do env | grep -v '^FAKE_MARKS=' | grep -F -e "$m" | cut -d= -f1 >>"$FAKE_CAP/$me.envnames"; done
ps -eo args >>"$FAKE_CAP/$me.ps" 2>/dev/null
printf '%s\n' "$*" >>"$FAKE_CAP/$me.args"
mode=$(cat "$FAKE_MODE")
case "$me:$mode" in
  claude:ok) echo '{"type":"result","subtype":"success","is_error":false,"api_error_status":null,"result":"ok","usage":{"input_tokens":1,"output_tokens":5},"total_cost_usd":0.01}' ;;
  claude:*) echo '{"type":"result","subtype":"success","is_error":true,"api_error_status":'"$mode"',"result":"API Error: '"$mode"'","usage":{"input_tokens":0,"output_tokens":0},"total_cost_usd":0}'; exit 1 ;;
  agy:ok) echo '{"response":"ok","stats":{"models":{"m":{"tokens":{"candidates":5}}}}}' ;;
  agy:*) echo '{"error":{"code":'"$mode"',"message":"API Error '"$mode"'"}}'; exit 1 ;;
  fakeh:ok) echo '{"ok":true}' ;;
  fakeh:*) echo '{"status":'"$mode"'}'; exit 1 ;;
esac
FAKE_EOF
  }
  for n in claude agy fakeh; do fake_body >"$bindir/$n"; chmod 755 "$bindir/$n"; done

  cat >"$adapters/harness/fakeh.sh" <<'ADAPTER_EOF'
#!/usr/bin/env bash
harness_fakeh_probe() { command -v fakeh >/dev/null 2>&1; }
harness_fakeh_models() { printf '%s\n' small; }
harness_fakeh_default_model() { printf '%s\n' small; }
harness_fakeh_execute() { REVIEWER_PID=0; }
harness_fakeh_token_file() { printf '%s\n' fakeh.token; }
harness_fakeh_token_min() { printf '%s\n' 12; }
harness_fakeh_aliases() { printf '%s\n' fk; }
harness_fakeh_login() { fakeh login; }
harness_fakeh_check_prompt() { printf '%s\n' 'say ok'; }
harness_fakeh_check_token() {
  FAKEH_TOKEN="$(cat "$1")" fakeh check "$(harness_fakeh_check_prompt)" >"$2" 2>"$3"
}
harness_fakeh_parse() {
  local s
  if [ "$(jq -r '.ok // false' <"$1" 2>/dev/null)" = true ]; then echo ok; return 0; fi
  s="$(jq -r '.status // 0' <"$1" 2>/dev/null)"
  printf 'the API answered %s\n' "$s" >&2
  case "$s" in 401 | 404) return 2 ;; *) return 1 ;; esac
}
ADAPTER_EOF

  ar() { bash "$script" "$@"; }
  put() { printf '%s' "$2" >"$tokd/$1"; chmod 600 "$tokd/$1"; }
  calls() { cat "$cap/$1.calls" 2>/dev/null | wc -l | tr -d ' '; }
  mode() { echo "$1" >"$FAKE_MODE"; }
  run_in() {
    local in="$1"
    shift
    ar "$@" <"$in" >"$fixtures/out" 2>&1
    rc=$?
    cat "$fixtures/out" >>"$fixtures/all-output"
  }
  printf '%s' "$CLAUDE_NEW" >"$fixtures/in-claude"
  printf '%s\n' "$AGY_NEW" >"$fixtures/in-agy"
  printf '%s\n' "$FK_NEW" >"$fixtures/in-fakeh"
  printf '%s' 'tiny' >"$fixtures/in-short"
  : >"$fixtures/all-output"
  check "fixture: the multi-line agy credential has three lines" 3 "$(wc -l <"$fixtures/in-agy" | tr -d ' ')"

  for h in claude-code agy; do
    f="$adir/$h.sh"
    p="$(adapter_prefix "$f")"
    for fn in login check_prompt check_token aliases; do
      bash -c '. "$1" >/dev/null 2>&1; declare -F "harness_$2_$3" >/dev/null' _ "$f" "$p" "$fn"
      check "$h: the adapter defines harness_P_$fn" 0 "$?"
    done
    call_adapter "$f" "$p" check_prompt
    check "$h: harness_P_check_prompt prints a prompt" 1 "$([ -n "$(tr -d '[:space:]' <"$fixtures/o")" ] && echo 1 || echo 0)"
  done
  call_adapter "$adir/claude-code.sh" "$(adapter_prefix "$adir/claude-code.sh")" aliases
  has "claude-code: answers to the name claude" "$(cat "$fixtures/o")" "claude"
  call_adapter "$adir/agy.sh" "$(adapter_prefix "$adir/agy.sh")" aliases
  has "agy: answers to the name antigravity" "$(cat "$fixtures/o")" "antigravity"

  put claude.token "$CLAUDE_OLD"
  run_in "$fixtures/in-claude" credential set claude
  check "set claude: exit 0" 0 "$rc"
  check "set claude: a stdout line is exactly ok" ok "$(grep -x ok "$fixtures/out" | head -n 1)"
  same "set claude: the token file holds stdin byte for byte" "$fixtures/in-claude" "$tokd/claude.token"
  check "set claude: the token file is 0600" 600 "$(stat -c %a "$tokd/claude.token" 2>/dev/null)"
  check "set claude: exactly one real check ran through the harness CLI" 1 "$(calls claude)"
  has "set claude: the check was a prompt (-p)" "$(cat "$cap/claude.args" 2>/dev/null)" "-p"

  put antigravity-oauth-token "$AGY_OLD"
  run_in "$fixtures/in-agy" credential set antigravity
  check "set antigravity: exit 0" 0 "$rc"
  check "set antigravity: a stdout line is exactly ok" ok "$(grep -x ok "$fixtures/out" | head -n 1)"
  same "set antigravity: a multi-line value is stored byte for byte" "$fixtures/in-agy" "$tokd/antigravity-oauth-token"
  check "set antigravity: exactly one real check ran through the harness CLI" 1 "$(calls agy)"

  run_in "$fixtures/in-claude" credential set claude-code
  check "set claude-code (the adapter name): exit 0" 0 "$rc"
  run_in "$fixtures/in-agy" credential set agy
  check "set agy (the adapter name): exit 0" 0 "$rc"

  rm -f "$tokd/claude.token"
  printf '%s' "sk-ant-$MARK1-$(printf '%060d' 5)" >"$FAKE_LOGIN_OUT"
  run_in /dev/null login claude
  check "login claude: exit 0" 0 "$rc"
  check "login claude: a stdout line is exactly ok" ok "$(grep -x ok "$fixtures/out" | head -n 1)"
  same "login claude: what the login command printed is the credential" "$FAKE_LOGIN_OUT" "$tokd/claude.token"

  rm -f "$tokd/antigravity-oauth-token"
  cp "$fixtures/in-agy" "$FAKE_LOGIN_OUT"
  run_in /dev/null login antigravity
  check "login antigravity: exit 0" 0 "$rc"
  same "login antigravity: the multi-line login output is the credential" "$FAKE_LOGIN_OUT" "$tokd/antigravity-oauth-token"

  put claude.token "$CLAUDE_OLD"
  cp "$tokd/claude.token" "$fixtures/claude.before"
  FAKE_LOGIN_FAIL=1 run_in /dev/null login claude
  nonzero "login claude, the login command fails: non-zero exit" "$rc"
  has "login claude, the login command fails: the output names step login" "$(cat "$fixtures/out")" "step login"
  same "login claude, the login command fails: the old credential is untouched" "$fixtures/claude.before" "$tokd/claude.token"

  run_in "$fixtures/in-fakeh" credential set fakeh
  check "third adapter: set <name> exits 0" 0 "$rc"
  check "third adapter: set prints ok" ok "$(grep -x ok "$fixtures/out" | head -n 1)"
  same "third adapter: stored byte for byte under the file its adapter names" "$fixtures/in-fakeh" "$tokd/fakeh.token"
  check "third adapter: the check ran through its own CLI" 1 "$(calls fakeh)"
  rm -f "$tokd/fakeh.token"
  cp "$fixtures/in-fakeh" "$FAKE_LOGIN_OUT"
  run_in /dev/null login fk
  check "third adapter: login <alias> exits 0" 0 "$rc"
  same "third adapter: login stored what its login command printed" "$FAKE_LOGIN_OUT" "$tokd/fakeh.token"
  run_in /dev/null credential list
  has "third adapter: credential list shows it" "$(cat "$fixtures/out")" "fakeh"

  check "git grep -i secret-vault outside tests/ is empty" "" \
    "$(cd "$here" && git grep -i -l secret-vault -- ':!tests/' 2>/dev/null)"

  reject() {
    mode "$5"
    cp "$tokd/$3" "$fixtures/before"
    run_in "$4" credential set "$2"
    nonzero "$1: non-zero exit" "$rc"
    same "$1: the old credential is byte-identical" "$fixtures/before" "$tokd/$3"
    has "$1: the output names the reason" "$(cat "$fixtures/out")" "$6"
    lacks "$1: the output does not claim ok" "$(grep -x ok "$fixtures/out")" "ok"
    mode ok
  }

  put claude.token "$CLAUDE_OLD"
  before=$(calls claude)
  reject "claude, too short" claude claude.token "$fixtures/in-short" ok "too short"
  has "claude, too short: the failed step is validate" "$(cat "$fixtures/out")" "step validate"
  check "claude, too short: no check was spent on it" "$before" "$(calls claude)"
  for code in 401 404 429; do
    reject "claude, the check gets $code" claude claude.token "$fixtures/in-claude" "$code" "$code"
    has "claude, the check gets $code: the failed step is check" "$(cat "$fixtures/out")" "step check"
  done
  put antigravity-oauth-token "$AGY_OLD"
  reject "antigravity, too short" antigravity antigravity-oauth-token "$fixtures/in-short" ok "too short"
  put fakeh.token "old-fakeh-credential"
  for code in 401 404 429; do
    reject "third adapter, the check gets $code" fakeh fakeh.token "$fixtures/in-fakeh" "$code" "$code"
    has "third adapter, the check gets $code: the failed step is check" "$(cat "$fixtures/out")" "step check"
  done
  reject "third adapter, too short (its own minimum of 12)" fakeh fakeh.token "$fixtures/in-short" ok "too short"
  rm -f "$tokd/claude.token"
  mode 401
  run_in "$fixtures/in-claude" credential set claude
  check "a rejected credential with no old one leaves no file" "absent" "$([ -e "$tokd/claude.token" ] && echo present || echo absent)"
  check "a rejected credential leaves no temporary file in the token dir" "" \
    "$(ls "$tokd" | grep -v -e '^claude.token$' -e '^antigravity-oauth-token$' -e '^fakeh.token$')"
  mode ok

  radopt() { bash -c '. "$1"; shift; registry_adopt "$@"' _ "$(dirname "$script")/lib/registry.sh" "$@"; }
  radopt "$AUTO_REVIEW_REGISTRY" acme/web
  ar set-global harness claude-code >/dev/null 2>&1
  put gh-acme.token "$(printf 'ghp_%040d' 1)"
  rm -f "$tokd/claude.token"
  st="$(bash "$script" status --json 2>/dev/null)"
  check "status --json: the missing claude credential is named" "claude.token" \
    "$(printf '%s' "$st" | jq -r '[.tokens[] | select(.problem == "missing")][0].name' 2>/dev/null)"
  cmdline="$(printf '%s' "$st" | jq -r '[.tokens[] | select(.name == "claude.token")][0].command // ""' 2>/dev/null)"
  check "status --json: it carries the command to run" 1 \
    "$(printf '%s' "$cmdline" | grep -Eq '^auto-review (login|credential set) (claude|claude-code)$' && echo 1 || echo 0)"
  lacks "status --json: never prints a credential" "$st" "$MARK1"

  put claude.token "$CLAUDE_OLD"
  rm -f "$tokd/antigravity-oauth-token"
  run_in "$fixtures/in-claude" credential set claude
  list="$(ar credential list 2>&1)"
  cl="$(printf '%s\n' "$list" | grep '^claude-code ')"
  check "list: claude-code is present" 1 "$(printf '%s' "$cl" | grep -Eq '^claude-code present age=[0-9]+s check=ok$' && echo 1 || echo 0)"
  al="$(printf '%s\n' "$list" | grep '^agy ')"
  check "list: agy, without a credential, is missing" 1 "$(printf '%s' "$al" | grep -Eq '^agy missing' && echo 1 || echo 0)"
  mode 401
  run_in "$fixtures/in-claude" credential set claude
  mode ok
  list="$(ar credential list 2>&1)"
  check "list: the last check result is the rejected attempt's status" 1 \
    "$(printf '%s\n' "$list" | grep '^claude-code ' | grep -Eq 'check=401$' && echo 1 || echo 0)"
  for m in "$MARK1" "$MARK2" "$MARK3" "$CLAUDE_OLD"; do lacks "list never prints a value ($m)" "$list" "$m"; done

  allout="$(cat "$fixtures/all-output")"
  for n in claude agy fakeh; do
    check "the capture saw real checks (so the scans below are not vacuous): $n" 1 \
      "$([ "$(calls $n)" -ge 1 ] && [ -s "$cap/$n.ps" ] && echo 1 || echo 0)"
  done
  for m in "$MARK1" "$MARK2" "$MARK3"; do
    lacks "the combined output of every command never holds $m" "$allout" "$m"
    lacks "the process list seen by the harness CLIs never holds $m" "$(cat "$cap"/*.ps 2>/dev/null)" "$m"
    lacks "no argument any harness CLI got holds $m" "$(cat "$cap"/*.args 2>/dev/null)" "$m"
    check "no file at rest outside the token files holds $m" "" \
      "$(grep -rlF -e "$m" "$fixtures" --exclude-dir=tokens --exclude-dir=cap \
          --exclude='in-*' --exclude=login-out --exclude='*.before' --exclude=all-output \
          --exclude=out 2>/dev/null)"
  done
  check "claude's environment holds the credential only in CLAUDE_CODE_OAUTH_TOKEN" \
    "CLAUDE_CODE_OAUTH_TOKEN" "$(sort -u "$cap/claude.envnames" 2>/dev/null)"
  check "agy's environment holds no credential" "" "$(sort -u "$cap/agy.envnames" 2>/dev/null)"

  exit "$fail"
)

# ==============================================================================
# Section 2: Reviewer uid/env isolation, post_review guard, clone & agy
# ==============================================================================
section_2() (
  script="$here/auto-review.sh"
  fixtures=$(mktemp -d)
  chmod 755 "$fixtures"
  rbin="$(mktemp -d "${AUTO_REVIEW_TEST_BIN_ROOT:-$fixtures}/rbin.XXXXXX")"
  chmod 755 "$rbin"
  trap 'rm -r -f "$fixtures" "$rbin"' EXIT
  fail=0

  GHTOK="ghp_FIXTURE""gateTOKEN0123456789abcdefABCD"
  CLTOK="sk-ant-FIXTURE""claudeTOKEN9876543210zyxwVUTS"
  LKTOK="ghp_FIXTURE""lockdirTOKEN5555555555aaaaBBBB"

  mkdir -p "$fixtures/userhome" "$fixtures/tokens" "$fixtures/lock"
  chmod 700 "$fixtures/tokens" "$fixtures/lock"
  printf '%s\n' "$GHTOK" >"$fixtures/tokens/acme-widgets.token"
  printf '%s\n' "$CLTOK" >"$fixtures/tokens/claude.token"
  printf '%s\n' "$LKTOK" >"$fixtures/lock/acme-gadgets.token"
  chmod 600 "$fixtures"/tokens/*.token "$fixtures"/lock/*.token
  export HOME="$fixtures/userhome"
  export AUTO_REVIEW_TOKEN_DIR="$fixtures/tokens"
  export AUTO_REVIEW_LOCK_DIR="$fixtures/lock"

  # shellcheck disable=SC1091
  . "$script"
  set +e

  rclone="$fixtures/reviewer-clone"
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

  cat >"$rbin/claude" <<FAKE
#!/bin/sh
obs=\$({
  echo "uid=\$(id -u)"
  echo "home=\$HOME"
  for f in "$fixtures"/tokens/*.token "$fixtures"/lock/*.token; do
    if cat "\$f" >/dev/null 2>&1; then echo "readable:\$f"; else echo "unreadable:\$f"; fi
  done
  if cat /proc/$$/environ >/dev/null 2>&1; then echo "readable:gate-proc-environ"; else echo "unreadable:gate-proc-environ"; fi
  echo "ENV-BEGIN"
  env
} 2>&1)
jq -n --arg r "\$obs" '{type:"result",subtype:"success",is_error:false,usage:{output_tokens:20},result:("**No findings.** probe\n"+\$r)}'
FAKE
  chmod 755 "$rbin/bwrap" "$rbin/claude"
  PATH="$rbin:$PATH"
  export PATH

  export GH_TOKEN="$GHTOK" GITHUB_TOKEN="$GHTOK" GH_ENTERPRISE_TOKEN="$GHTOK"
  HARNESS=claude-code
  if setpriv --reuid=65534 --regid=65534 --clear-groups true 2>/dev/null; then
    setpriv --reuid=65534 --regid=65534 --clear-groups "$rbin/claude" >/dev/null 2>&1 </dev/null
    check "a non-gate uid can execute the claude stand-in (else the real claude would run)" 0 "$?"
  fi
  run_reviewer 1 "$fixtures/probe-out.md" "$rclone/.auto-review-history.md" \
    "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md" >"$fixtures/run.log" 2>&1
  probe_rc=$?
  check "reviewer probe ran and produced a report (rc=0)" 0 "$probe_rc"
  [ "$probe_rc" = 0 ] || cat "$fixtures/run.log"
  probe="$(cat "$fixtures/probe-out.md" 2>/dev/null)"
  probe_env="${probe#*ENV-BEGIN}"

  check "reviewer env has no GH_TOKEN" 0 "$(printf '%s\n' "$probe_env" | grep -c '^GH_TOKEN=')"
  check "reviewer env has no GITHUB_TOKEN" 0 "$(printf '%s\n' "$probe_env" | grep -c '^GITHUB_TOKEN=')"
  lacks "reviewer env holds the gate's GitHub token value under no name" "$probe_env" "$GHTOK"
  lacks "reviewer is not told where the token dir is (AUTO_REVIEW_TOKEN_DIR)" "$probe_env" "$fixtures/tokens"
  lacks "reviewer is not told where the lock dir is (AUTO_REVIEW_LOCK_DIR)" "$probe_env" "$fixtures/lock"
  home_line="$(printf '%s\n' "$probe" | sed -n 's/^home=//p' | head -n 1)"
  if [ -n "$home_line" ] && [ "$home_line" != "$fixtures/userhome" ]; then
    printf 'ok    %s\n' "reviewer has a HOME of its own"
  else
    printf 'FAIL  %s\n--- reviewer HOME was: %s (gate HOME: %s)\n' "reviewer has a HOME of its own" "$home_line" "$fixtures/userhome"
    fail=1
  fi

  if setpriv --reuid=65534 --regid=65534 --clear-groups true 2>/dev/null; then
    gate_uid="$(id -u)"
    reviewer_uid="$(printf '%s\n' "$probe" | sed -n 's/^uid=//p' | head -n 1)"
    if [ -n "$reviewer_uid" ] && [ "$reviewer_uid" != "$gate_uid" ]; then
      printf 'ok    %s\n' "reviewer runs as a different uid than the gate"
    else
      printf 'FAIL  %s\n--- reviewer uid %s, gate uid %s\n' "reviewer runs as a different uid than the gate" "$reviewer_uid" "$gate_uid"
      fail=1
    fi
    check "reviewer cannot read any *.token file" 0 "$(printf '%s\n' "$probe" | grep -c '^readable:.*\.token$')"
    check "reviewer cannot read the gate's /proc/<pid>/environ" 0 "$(printf '%s\n' "$probe" | grep -c '^readable:gate-proc-environ')"
  else
    printf 'SKIP  %s\n' "uid separation, token-file and /proc reads: needs a privileged run (setpriv cannot switch uid here)"
  fi

  cat >"$rbin/gh" <<FAKE
#!/bin/sh
cat >/dev/null
echo "\$*" >>"$fixtures/gh.calls"
FAKE
  chmod 755 "$rbin/gh"

  try_post() {
    local text="$1" rc out
    rm -f "$fixtures/gh.calls"
    printf '**1 finding.** - x\n\n1. `a.sh:1` leaks: %s\n' "$text" >"$fixtures/body.md"
    out="$(post_review acme/widgets 7 "$fixtures/body.md" "0123456789abcdef0123456789abcdef01234567" 2>&1)"
    rc=$?
    TRY_RC=$rc; TRY_OUT="$out"
    TRY_POSTED="$([ -s "$fixtures/gh.calls" ] && echo posted || echo not-posted)"
  }

  export GH_TOKEN="$GHTOK"
  try_post "$GHTOK"
  check "review containing GH_TOKEN value is not posted" not-posted "$TRY_POSTED"
  check "review containing GH_TOKEN value: post_review fails" 1 "$([ "$TRY_RC" != 0 ] && echo 1 || echo 0)"
  case "$(printf '%s' "$TRY_OUT" | tr 'A-Z' 'a-z')" in
    *refus*) printf 'ok    %s\n' "refusal is logged" ;;
    *) printf 'FAIL  %s\n' "refusal is logged (no line containing 'refus')"; fail=1 ;;
  esac
  lacks "refusal log does not print the value" "$TRY_OUT" "$GHTOK"

  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN
  try_post "see $CLTOK here"
  check "review containing a token-dir token value is not posted" not-posted "$TRY_POSTED"
  lacks "token-dir refusal log does not print the value" "$TRY_OUT" "$CLTOK"

  try_post "$LKTOK"
  check "review containing a lock-dir token value is not posted" not-posted "$TRY_POSTED"
  lacks "lock-dir refusal log does not print the value" "$TRY_OUT" "$LKTOK"

  try_post "nothing secret here"
  check "a clean review is still posted" posted "$TRY_POSTED"

  clone_lib="$here/lib/clone.sh"
  check "lib/clone.sh exists" present "$([ -f "$clone_lib" ] && echo present || echo absent)"
  # shellcheck disable=SC1090
  [ -f "$clone_lib" ] && . "$clone_lib"
  for fn in clone_repo clone_scrub_credentials; do
    check "lib/clone.sh defines $fn" "$fn" "$(declare -F "$fn" 2>/dev/null || echo missing)"
  done

  mkdir -p "$fixtures/gh/acme"
  git init -q --bare "$fixtures/gh/acme/widgets.git"
  git init -q "$fixtures/seed" && git -C "$fixtures/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
  git -C "$fixtures/seed" push -q "$fixtures/gh/acme/widgets.git" HEAD:refs/heads/main 2>/dev/null

  export AUTO_REVIEW_GITHUB_BASE="file://$fixtures/gh"
  export GH_TOKEN="$GHTOK"
  if declare -F clone_repo >/dev/null; then
    clone_repo acme/widgets "$fixtures/c1" >/dev/null 2>&1
  fi
  cfg="$(cat "$fixtures/c1/.git/config" 2>/dev/null)"
  check "clone_repo produced a clone" present "$([ -d "$fixtures/c1/.git" ] && echo present || echo absent)"
  if [ -n "$cfg" ]; then
    lacks "fresh clone .git/config has no x-access-token" "$cfg" "x-access-token"
    lacks "fresh clone .git/config has no token value" "$cfg" "$GHTOK"
  else
    printf 'FAIL  %s\n' "fresh clone .git/config is empty or missing"; fail=1
  fi
  unset GH_TOKEN

  git init -q "$fixtures/c2"
  git -C "$fixtures/c2" remote add origin "https://x-access-token:${GHTOK}@github.com/acme/widgets.git"
  git -C "$fixtures/c2" remote add upstream "https://x-access-token:${GHTOK}@github.com/acme/other.git"
  git -C "$fixtures/c2" config remote.origin.pushurl "https://x-access-token:${GHTOK}@github.com/acme/widgets.git"
  declare -F clone_scrub_credentials >/dev/null && clone_scrub_credentials "$fixtures/c2" >/dev/null 2>&1
  cfg2="$(cat "$fixtures/c2/.git/config" 2>/dev/null)"
  lacks "scrub removes x-access-token from an existing clone" "$cfg2" "x-access-token"
  lacks "scrub removes the token value from an existing clone" "$cfg2" "$GHTOK"
  check "scrub keeps the origin remote usable" "https://github.com/acme/widgets.git" \
    "$(git -C "$fixtures/c2" config --get remote.origin.url 2>/dev/null)"

  entry="$here/entrypoint.sh"
  check "entrypoint.sh embeds no x-access-token URL (occurrences)" 0 "$(grep -c "x-access-token" "$entry")"
  check "auto-review.sh embeds no x-access-token URL (occurrences)" 0 "$(grep -c "x-access-token" "$script")"
  has "entrypoint.sh scrubs existing clones on start" "$(grep -o "clone_scrub_credentials" "$entry" | head -n 1)" "clone_scrub_credentials"
  has "entrypoint.sh clones through clone_repo" "$(grep -o "clone_repo" "$entry" | head -n 1)" "clone_repo"

  cat >"$rbin/agy" <<FAKE
#!/bin/sh
a=\$(printf '%s\n' "\$@" | base64 | tr -d '\n')
printf '{"response":"AGYARGS:%s:END **No findings.** ok","usage":{"output_tokens":9}}\n' "\$a"
FAKE
  chmod 755 "$rbin/agy"
  HARNESS=agy
  rm -f "$fixtures/agy.args"
  run_reviewer 1 "$fixtures/agy-out.md" "$rclone/.auto-review-history.md" \
    "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md" >/dev/null 2>&1
  agy_args="$(sed -n 's/.*AGYARGS:\([A-Za-z0-9+/=]*\):END.*/\1/p' "$fixtures/agy-out.md" 2>/dev/null | head -n 1 | base64 -d 2>/dev/null)"
  check "agy was launched" present "$([ -n "$agy_args" ] && echo present || echo absent)"
  lacks "agy is launched without --dangerously-skip-permissions" "$agy_args" "--dangerously-skip-permissions"
  has "agy is launched with --disable-slash-commands" "$agy_args" "--disable-slash-commands"

  agy_lib="$here/lib/agy.sh"
  check "lib/agy.sh exists" present "$([ -f "$agy_lib" ] && echo present || echo absent)"
  # shellcheck disable=SC1090
  [ -f "$agy_lib" ] && . "$agy_lib"
  check "lib/agy.sh defines agy_write_settings" agy_write_settings "$(declare -F agy_write_settings 2>/dev/null || echo missing)"
  mkdir -p "$fixtures/agydir"
  declare -F agy_write_settings >/dev/null && agy_write_settings "$fixtures/agydir" >/dev/null 2>&1
  check "agy settings.json is valid JSON" valid "$(jq -e . "$fixtures/agydir/settings.json" >/dev/null 2>&1 && echo valid || echo invalid)"
  check "agy settings.json mode is 0600" "600" "$(stat -c %a "$fixtures/agydir/settings.json" 2>/dev/null)"
  check "agy settings.json allows no star" no-star "$(jq -e '[.permissions.allow[]?] | index("*") == null' "$fixtures/agydir/settings.json" >/dev/null 2>&1 && echo no-star || echo star-or-unreadable)"
  check "agy settings.json trustedWorkspaces" '["/var/lib/auto-review"]' "$(jq -c '.trustedWorkspaces // null' "$fixtures/agydir/settings.json" 2>/dev/null)"
  check "agy settings.json toolPermission" "request-review" "$(jq -r '.toolPermission // empty' "$fixtures/agydir/settings.json" 2>/dev/null)"
  check "agy settings.json permissions.allow" '["read_file(/var/lib/auto-review)","read_file(/tmp)"]' "$(jq -c '.permissions.allow // null' "$fixtures/agydir/settings.json" 2>/dev/null)"
  check "agy settings.json permissions.deny" '["command(*)","write_file(*)","read_url(*)","execute_url(*)","download_url(*)","mcp(*)"]' "$(jq -c '.permissions.deny // null' "$fixtures/agydir/settings.json" 2>/dev/null)"
  check "agy settings.json allow omits Claude tool names" no-claude-tools "$(jq -e '[.permissions.allow[]?] | (index("Read") == null and index("Grep") == null and index("Glob") == null)' "$fixtures/agydir/settings.json" >/dev/null 2>&1 && echo no-claude-tools || echo has-claude-tools)"
  check "agy settings.json allow omits /run/auto-review and /home/reviewer" no-forbidden-paths "$(jq -e '[.permissions.allow[]?] | any(contains("/run/auto-review") or contains("/home/reviewer")) | not' "$fixtures/agydir/settings.json" >/dev/null 2>&1 && echo no-forbidden-paths || echo has-forbidden-paths)"
  lacks "entrypoint.sh writes no allow-everything agy settings" "$(tr -d ' \n' <"$entry")" '"allow":["*"]'
  has "entrypoint.sh writes agy settings through agy_write_settings" "$(grep -o "agy_write_settings" "$entry" | head -n 1)" "agy_write_settings"

  # harness_agy_seed writes settings.json unconditionally even when oauth token is absent
  (
    # shellcheck disable=SC1091
    . "$here/adapters/harness/agy.sh"
    unset AUTO_REVIEW_REVIEWER_UID
    reviewer_uid_mode() { return 1; }
    export HOME="$fixtures/agy-home-empty"
    mkdir -p "$HOME/.gemini" "$fixtures/agy-seed-notok"
    harness_agy_seed "$fixtures/agy-seed-notok"
  ) >/dev/null 2>&1
  check "harness_agy_seed without oauth token writes settings.json" present "$([ -f "$fixtures/agy-seed-notok/.gemini/antigravity-cli/settings.json" ] && echo present || echo absent)"
  check "harness_agy_seed without oauth token sets mode 0600" "600" "$(stat -c %a "$fixtures/agy-seed-notok/.gemini/antigravity-cli/settings.json" 2>/dev/null)"
  check "harness_agy_seed without oauth token sets toolPermission request-review" "request-review" "$(jq -r '.toolPermission // empty' "$fixtures/agy-seed-notok/.gemini/antigravity-cli/settings.json" 2>/dev/null)"

  (
    # shellcheck disable=SC1091
    . "$here/adapters/harness/agy.sh"
    unset AUTO_REVIEW_REVIEWER_UID
    reviewer_uid_mode() { return 1; }
    export HOME="$fixtures/agy-home-tok"
    mkdir -p "$HOME/.gemini/antigravity-cli" "$fixtures/agy-seed-tok"
    printf 'tok-val\n' >"$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
    harness_agy_seed "$fixtures/agy-seed-tok"
  ) >/dev/null 2>&1
  check "harness_agy_seed with oauth token writes settings.json" present "$([ -f "$fixtures/agy-seed-tok/.gemini/antigravity-cli/settings.json" ] && echo present || echo absent)"
  check "harness_agy_seed with oauth token sets mode 0600" "600" "$(stat -c %a "$fixtures/agy-seed-tok/.gemini/antigravity-cli/settings.json" 2>/dev/null)"

  exit "$fail"
)

# ==============================================================================
# Section 3: docker exec -u 10001 gate uid (unlock-token.sh & sync-tokens.sh)
# ==============================================================================
section_3() (
  unlock="$here/unlock-token.sh"
  sync="$here/sync-tokens.sh"
  fixtures=$(mktemp -d)
  trap 'rm -rf "$fixtures"' EXIT
  fail=0
  secret="s3cr3t-fixture-token-value"

  fakebin="$fixtures/bin"
  mkdir -p "$fakebin"
  cat >"$fakebin/docker" <<'FAKE'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
case "$1" in
  ps)
    case "$*" in
      *" -a "*|*" -a") [ "$FAKE_STATE" = absent ] || echo auto-review ;;
      *) case "$FAKE_STATE" in running|execfail) echo auto-review ;; esac ;;
    esac ;;
  exec)
    if [ "$FAKE_STATE" = execfail ]; then
      echo "OCI runtime exec failed: permission denied" >&2
      exit 126
    fi
    cat >/dev/null ;;
esac
exit 0
FAKE
  chmod +x "$fakebin/docker"

  n=0
  run_tool() {
    state="$1"; shift
    n=$((n + 1))
    tokdir="$fixtures/t$n"
    flog="$fixtures/docker$n.log"
    : >"$flog"
    out=$(printf '%s' "$secret" | FAKE_STATE="$state" FAKE_LOG="$flog" \
      AUTO_REVIEW_TOKEN_DIR="$tokdir" PATH="$fakebin:$PATH" "$@" 2>&1)
    rc=$?
  }
  written() { if [ -d "$tokdir" ]; then ls -A "$tokdir"; fi; }
  exec_lines() { grep '^exec ' "$flog" || true; }

  run_tool running "$unlock" --name gemini
  check "unlock running: exits 0" 0 "$rc"
  has "unlock running: exec runs as the gate" "$(exec_lines)" "-u 10001 "
  has "unlock running: exec targets auto-review" "$(exec_lines)" "auto-review"
  check "unlock running: nothing in the host dir" "" "$(written)"
  lacks "unlock running: token never printed" "$out" "$secret"

  run_tool stopped "$unlock" --name gemini
  check "unlock stopped: exits 1" 1 "$rc"
  has "unlock stopped: says it is not running" "$out" "not running"
  has "unlock stopped: says to start it" "$out" "start it"
  check "unlock stopped: no exec attempted" "" "$(exec_lines)"
  check "unlock stopped: nothing in the host dir" "" "$(written)"
  lacks "unlock stopped: token never printed" "$out" "$secret"

  run_tool execfail "$unlock" --name gemini
  check "unlock exec fails: exits non-zero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  has "unlock exec fails: shows the error" "$out" "permission denied"
  check "unlock exec fails: nothing in the host dir" "" "$(written)"
  lacks "unlock exec fails: token never printed" "$out" "$secret"

  run_tool absent "$unlock" --name gemini
  check "unlock absent: exits 0" 0 "$rc"
  check "unlock absent: token in the host dir" "gemini.token" "$(written)"
  check "unlock absent: token content kept" "$secret" "$(cat "$tokdir/gemini.token" 2>/dev/null)"
  has "unlock absent: says where it went" "$out" "$tokdir"
  lacks "unlock absent: token never printed" "$out" "$secret"
  check "unlock absent: no exec attempted" "" "$(exec_lines)"

  sync_case() {
    n=$((n + 1))
    tokdir="$fixtures/s$n"
    flog="$fixtures/docker$n.log"
    mkdir -p "$tokdir"
    printf '%s' "$secret" >"$tokdir/gemini.token"
    : >"$flog"
    out=$(FAKE_STATE="$1" FAKE_LOG="$flog" AUTO_REVIEW_TOKEN_DIR="$tokdir" \
      PATH="$fakebin:$PATH" bash "$sync" 2>&1 </dev/null)
    rc=$?
  }
  sync_case running
  check "sync running: exits 0" 0 "$rc"
  has "sync running: exec runs as the gate" "$(exec_lines)" "-u 10001 "
  has "sync running: says Delivered" "$out" "Delivered"
  lacks "sync running: token never printed" "$out" "$secret"
  sync_case execfail
  check "sync exec fails: exits non-zero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  lacks "sync exec fails: does not say Delivered" "$out" "Delivered"
  has "sync exec fails: shows the error" "$out" "permission denied"
  lacks "sync exec fails: token never printed" "$out" "$secret"

  for f in auto-review.sh unlock-token.sh sync-tokens.sh bin/auto-review; do
    bare=$(grep -nE 'docker exec' "$here/$f" | grep -v '^[0-9]*: *#' | grep -vE -- ' -u ' || true)
    check "$f: every docker exec passes -u" "" "$bare"
    has "$f: gate uid defaults to 10001" "$(cat "$here/$f")" 'AUTO_REVIEW_GATE_UID:-10001'
  done

  exit "$fail"
)

# ==============================================================================
# Section 4: Token directory defaults, permissions, and no-token tick
# ==============================================================================
section_4() (
  script="$here/auto-review.sh"
  fixtures=$(mktemp -d)
  trap 'rm -rf "$fixtures"' EXIT
  fail=0
  os=$(uname -s)
  mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

  n=0
  fresh() {
    n=$((n + 1))
    root="$fixtures/m$n"
    home="$root/userhome"
    xdg="$root/run"
    repo="$root/repo"
    glog="$root/gh.log"
    old="$home/.config/auto-review"
    new="$xdg/auto-review"
    mkdir -p "$home/.local/bin" "$xdg" "$root/clones"
    : >"$glog"
    git init -q -b main "$repo"
    git -C "$repo" remote add origin git@github.com:acme/widgets.git
    cat >"$home/.local/bin/gh" <<'FAKE'
#!/bin/sh
echo "gh $* [token=${GH_TOKEN:-}]" >>"$FAKE_LOG"
case "$1 $2" in
  "api user") echo tester ;;
  *) : ;;
esac
FAKE
    cat >"$home/.local/bin/claude" <<'FAKE'
#!/bin/sh
echo '{"is_error":false,"usage":{"output_tokens":3},"total_cost_usd":0.01,"result":"ok"}'
FAKE
    printf '#!/bin/sh\nexit 0\n' >"$home/.local/bin/bwrap"
    chmod 755 "$home/.local/bin/gh" "$home/.local/bin/claude" "$home/.local/bin/bwrap"
  }

  rc=0; out=""
  ar() {
    local unset_xdg=0
    if [ "$1" = -x ]; then unset_xdg=1; shift; fi
    local -a e=(HOME="$home" AUTO_REVIEW_CLONE_ROOT="$root/clones" FAKE_LOG="$glog")
    [ "$unset_xdg" = 1 ] || e+=(XDG_RUNTIME_DIR="$xdg")
    out=$(env -u AUTO_REVIEW_TOKEN_DIR -u XDG_RUNTIME_DIR -u GH_TOKEN "${e[@]}" "$script" "$@" 2>&1)
    rc=$?
  }

  dir_of() {
    env -u AUTO_REVIEW_TOKEN_DIR -u XDG_RUNTIME_DIR "$@" bash -c '. "$1"; printf %s "$TOKEN_DIR"' _ "$script"
  }

  fresh
  if [ "$os" = Linux ]; then
    check "default: under XDG_RUNTIME_DIR" "$xdg/auto-review" "$(dir_of HOME="$home" XDG_RUNTIME_DIR="$xdg")"
    check "default without XDG_RUNTIME_DIR: /run/user/<uid>" "/run/user/$(id -u)/auto-review" "$(dir_of HOME="$home")"
  else
    check "default on macOS stays under the home" "$home/.config/auto-review" "$(dir_of HOME="$home")"
  fi
  check "AUTO_REVIEW_TOKEN_DIR overrides the default" "$root/elsewhere" \
    "$(dir_of HOME="$home" XDG_RUNTIME_DIR="$xdg" AUTO_REVIEW_TOKEN_DIR="$root/elsewhere")"

  [ "$os" = Linux ] || { echo "skip  the rest is Linux only"; exit $fail; }

  fresh
  umask 022
  ar token "$repo" <<<'ghp_fakefake123'
  check "token: exit status" 0 "$rc"
  has "token: says where it stored" "$out" "stored $new/acme-widgets.token"
  check "token: lands in the runtime directory" "ghp_fakefake123" "$(cat "$new/acme-widgets.token" 2>/dev/null)"
  check "token: file is 0600" 600 "$(mode "$new/acme-widgets.token" 2>/dev/null)"
  check "token: directory is 0700" 700 "$(mode "$new" 2>/dev/null)"
  check "token: nothing at the old path" "absent" "$([ -e "$old" ] && echo present || echo absent)"
  lacks "token: output never names the vault" "$out" "secret-vault"

  fresh
  mkdir -m 755 "$new"
  ar token "$repo" <<<'ghp_fakefake123'
  check "token: a looser existing directory is tightened" 700 "$(mode "$new")"

  fresh
  ar claude-token <<<'sk-ant-fakefake_123'
  check "claude-token: exit status" 0 "$rc"
  check "claude-token: lands in the runtime directory" "sk-ant-fakefake_123" "$(cat "$new/claude.token" 2>/dev/null)"
  check "claude-token: file is 0600" 600 "$(mode "$new/claude.token" 2>/dev/null)"
  check "claude-token: directory is 0700" 700 "$(mode "$new" 2>/dev/null)"
  check "claude-token: nothing at the old path" "absent" "$([ -e "$old" ] && echo present || echo absent)"
  lacks "claude-token: output never names the vault" "$out" "secret-vault"

  fresh
  ar agy-token <<<'fake-agy-oauth-token-1234567890'
  check "agy-token: exit status" 0 "$rc"
  check "agy-token: lands in the runtime directory" "fake-agy-oauth-token-1234567890" "$(cat "$new/antigravity-oauth-token" 2>/dev/null)"
  check "agy-token: file is 0600" 600 "$(mode "$new/antigravity-oauth-token" 2>/dev/null)"
  check "agy-token: directory is 0700" 700 "$(mode "$new" 2>/dev/null)"
  lacks "agy-token: output never names the vault" "$out" "secret-vault"

  fresh
  ar tick "$repo"
  check "no token: the tick exits 0" 0 "$rc"
  has "no token: says so" "$out" "no token for acme/widgets"
  has "no token: names auto-review's own command" "$out" "auto-review.sh token $repo"
  lacks "no token: never names the vault" "$out" "secret-vault"
  check "no token: posts and asks GitHub nothing" "" "$(cat "$glog")"

  fresh
  mkdir -p "$old"
  printf 'ghp_oldoldold\n' >"$old/acme-widgets.token"
  printf 'sk-ant-oldoldold\n' >"$old/claude.token"
  ar tick "$repo"
  check "old path only: the tick exits 0" 0 "$rc"
  has "old path only: reports no token" "$out" "no token for acme/widgets"
  check "old path only: the old token is never used" "" "$(cat "$glog")"
  check "old path only: the old file is left alone" "ghp_oldoldold" "$(cat "$old/acme-widgets.token")"

  fresh
  ar -x tick "$repo"
  check "no token, no XDG_RUNTIME_DIR: the tick exits 0" 0 "$rc"
  has "no token, no XDG_RUNTIME_DIR: reports no token" "$out" "no token for acme/widgets"

  fresh
  mkdir -p "$new"
  printf 'ghp_newnewnew\n' >"$new/acme-widgets.token"
  ar tick "$repo"
  has "token present: gh is called under it" "$(cat "$glog")" "gh api user -q .login [token=ghp_newnewnew]"
  lacks "token present: no complaint of a missing token" "$out" "no token for"

  fresh
  mkdir -p "$new" "$old"
  printf 'ghp_newnewnew\n' >"$new/acme-widgets.token"
  printf 'ghp_oldoldold\n' >"$old/acme-widgets.token"
  ar tick "$repo"
  has "both: the runtime copy wins" "$(cat "$glog")" "[token=ghp_newnewnew]"
  lacks "both: the old copy is never used" "$(cat "$glog")" "ghp_oldoldold"

  fresh
  mkdir -p "$new"
  printf 'ghp_newnewnew\n' >"$new/acme-widgets.token"
  printf 'sk-ant-newnew\n' >"$new/claude.token"
  ar tick "$repo"
  has "claude token in the runtime directory is used" "$out" "on the stored token"

  fresh
  mkdir -p "$new" "$old"
  printf 'ghp_newnewnew\n' >"$new/acme-widgets.token"
  printf 'sk-ant-oldold\n' >"$old/claude.token"
  ar tick "$repo"
  has "claude token only at the old path is not used" "$out" "on the interactive login"

  exit "$fail"
)

# ==============================================================================
# Section 5: Token status & 401/404 configuration fault latching
# ==============================================================================
section_5() (
  script="$here/auto-review.sh"
  adir="$here/adapters/harness"
  fx="$here/tests/fixtures/auto-review/harness"
  fixtures=$(mktemp -d)
  chmod 755 "$fixtures"
  rbin="$(mktemp -d "${AUTO_REVIEW_TEST_BIN_ROOT:-$fixtures}/rbin.XXXXXX")"
  chmod 755 "$rbin"
  trap 'rm -r -f "$fixtures" "$rbin"' EXIT
  fail=0

  jok() { jq -e "$1" >/dev/null 2>&1 && echo true || echo false; }
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

  PLACEHOLDER='placeholder-tok-123'
  GOOD1="$(printf 'good-fixture-token-%081d' 1)"
  GOOD2="$(printf 'good-fixture-token-%081d' 2)"
  check "fixture: the placeholder is 19 bytes" 19 "$(printf '%s' "$PLACEHOLDER" | wc -c | tr -d ' ')"
  check "fixture: the good token is 100 bytes" 100 "$(printf '%s' "$GOOD1" | wc -c | tr -d ' ')"

  for want in claude-code:claude.token agy:antigravity-oauth-token; do
    h="${want%%:*}"
    file_want="${want#*:}"
    f="$adir/$h.sh"
    p="$(adapter_prefix "$f")"
    call_adapter "$f" "$p" token_file
    check "$h: harness_P_token_file names the file it authenticates with" "$file_want" "$(cat "$fixtures/o")"
    call_adapter "$f" "$p" token_min
    min="$(cat "$fixtures/o")"
    case "$min" in '' | *[!0-9]*) min=0 ;; esac
    check "$h: harness_P_token_min is above the 19-byte placeholder and within a real token" 1 \
      "$([ "$min" -gt 19 ] && [ "$min" -le 100 ] && echo 1 || echo 0)"
  done

  cc="$adir/claude-code.sh"
  pc="$(adapter_prefix "$cc")"
  for f in error-401.json error-404.json; do
    call_adapter "$cc" "$pc" parse "$fx/claude-code/$f"
    rc=$?
    check "claude-code parse $f: exit 2 (configuration fault)" 2 "$rc"
    check "claude-code parse $f: nothing on stdout" "" "$(cat "$fixtures/o")"
    check "claude-code parse $f: the reason is one line on stderr" 1 "$(wc -l <"$fixtures/e" | tr -d ' ')"
  done
  call_adapter "$cc" "$pc" parse "$fx/claude-code/error-401.json"
  has "claude-code parse error-401.json: the reason names 401" "$(cat "$fixtures/e")" "401"
  call_adapter "$cc" "$pc" parse "$fx/claude-code/error-404.json"
  has "claude-code parse error-404.json: the reason names 404" "$(cat "$fixtures/e")" "404"
  for f in error.json empty.json empty.txt; do
    call_adapter "$cc" "$pc" parse "$fx/claude-code/$f"
    check "claude-code parse $f: exit 1 (an ordinary failure, not a fault)" 1 "$?"
  done
  call_adapter "$cc" "$pc" parse "$fx/claude-code/success.json"
  check "claude-code parse success.json: still exit 0" 0 "$?"

  tokd="$fixtures/tokens"
  faultd="$fixtures/faults"
  mkdir -p "$fixtures/userhome" "$tokd" "$fixtures/lock"
  chmod 700 "$tokd"
  export HOME="$fixtures/userhome"
  export AUTO_REVIEW_TOKEN_DIR="$tokd"
  export AUTO_REVIEW_LOCK_DIR="$tokd"
  export AUTO_REVIEW_FAULT_DIR="$faultd"
  export AUTO_REVIEW_REGISTRY="$fixtures/projects.json"
  export AUTO_REVIEW_STATUS_FILE="$fixtures/status.json"
  export AUTO_REVIEW_CLONE_ROOT="$fixtures/clones"
  ar() { bash "$script" "$@"; }
  st() { bash "$script" status --json 2>/dev/null; }
  put() { printf '%s' "$2" >"$tokd/$1"; chmod 600 "$tokd/$1"; }
  prob() { st | jq -r --arg n "$1" '[.tokens[]? | select(.name == $n)] | .[0] | "\(.kind) \(.problem)"' 2>/dev/null; }
  hstate() { st | jq -r --arg h "$1" '.harnesses[$h].state // "absent"' 2>/dev/null; }

  ar set-global harness claude-code >/dev/null 2>&1
  radopt() { bash -c '. "$1"; shift; registry_adopt "$@"' _ "$(dirname "$script")/lib/registry.sh" "$@"; }
  radopt "$AUTO_REVIEW_REGISTRY" acme/web
  radopt "$AUTO_REVIEW_REGISTRY" other/api
  put gh-other.token "$GOOD1"
  put claude.token "$PLACEHOLDER"
  put antigravity-oauth-token "$GOOD1"

  out="$(st)"
  check "status --json: one JSON object with a tokens array" true \
    "$(printf '%s' "$out" | jok 'type == "object" and (.tokens | type) == "array"')"
  check "status --json: the missing GitHub token is named, with its kind" "github missing" "$(prob gh-acme.token)"
  check "status --json: the 19-byte claude.token is named as short, with its kind" "claude-code short" "$(prob claude.token)"
  check "status --json: a good GitHub token is not listed" "null null" "$(prob gh-other.token)"
  check "status --json: a good agy token is not listed" "null null" "$(prob antigravity-oauth-token)"
  lacks "status --json: never prints the placeholder's bytes" "$out" "$PLACEHOLDER"
  lacks "status --json: never prints a good token's bytes" "$out" "$GOOD1"

  put acme-web.token "$GOOD2"
  check "status --json: the per-repo file stands in for a missing owner token" "null null" "$(prob gh-acme.token)"
  check "status --json: a good per-repo stand-in is not listed" "null null" "$(prob acme-web.token)"
  put acme-web.token "short"
  check "status --json: a short per-repo stand-in is named" "github short" "$(prob acme-web.token)"
  rm -f "$tokd/acme-web.token"

  put claude.token "$GOOD1"
  put gh-acme.token "$GOOD2"
  check "status --json, all tokens good: no token is listed" 0 "$(st | jq -r '.tokens | length' 2>/dev/null)"

  put antigravity-oauth-token "short"
  ar set-global harness agy >/dev/null 2>&1
  check "status --json: a short agy token is named under its kind" "agy short" "$(prob antigravity-oauth-token)"
  ar set-global harness claude-code >/dev/null 2>&1
  put antigravity-oauth-token "$GOOD1"
  rm -f "$tokd/claude.token"
  check "status --json: a missing claude.token is named" "claude-code missing" "$(prob claude.token)"
  put claude.token "$GOOD1"

  # shellcheck disable=SC1091
  . "$script"
  set +e
  rclone="$fixtures/reviewer-clone"
  mkdir -p "$rclone/.git" "$rclone/src"
  touch "$rclone/.auto-review-history.md" "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md"
  REVIEWER_CLONE="$rclone"
  REVIEWER_PERIMETER=()
  sleep() { command sleep 0.05; }
  AUTO_REVIEW_TIMEOUT=100000000

  launches="$fixtures/launches"
  launches_agy="$fixtures/launches-agy"
  : >"$launches" && : >"$launches_agy"
  chmod 666 "$launches" "$launches_agy"
  cat >"$rbin/bwrap" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
FAKE
  cat >"$rbin/claude" <<FAKE
#!/bin/sh
echo run >>"$launches"
cat "$fixtures/cli.out"
exit "\$(cat "$fixtures/cli.rc")"
FAKE
  cat >"$rbin/agy" <<FAKE
#!/bin/sh
echo run >>"$launches_agy"
printf '{"response":"**No findings.** agy ran","stats":{"models":{"m":{"tokens":{"candidates":9}}}}}\n'
FAKE
  chmod 755 "$rbin/bwrap" "$rbin/claude" "$rbin/agy"
  PATH="$rbin:$PATH"
  export PATH

  setcli() {
    cp "$1" "$fixtures/cli.out"
    printf '%s\n' "$2" >"$fixtures/cli.rc"
    chmod 644 "$fixtures/cli.out" "$fixtures/cli.rc"
  }
  printf 'boom: something unrelated broke\n' >"$fixtures/garbage.txt"
  nlaunch() { wc -l <"$launches" | tr -d ' '; }
  nlaunch_agy() { wc -l <"$launches_agy" | tr -d ' '; }
  cur() { jq -r ".$1" "$AUTO_REVIEW_REGISTRY"; }
  run_with() {
    unset CLAUDE_CODE_OAUTH_TOKEN
    rm -f "$fixtures/out.md"
    HARNESS="$1" REVIEW_MODEL="$2" run_reviewer 1 "$fixtures/out.md" "$rclone/.auto-review-history.md" \
      "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md" >"$fixtures/run.log" 2>&1
    RUN_RC=$?
    LOG="$(cat "$fixtures/run.log")"
  }
  run_cc() { run_with claude-code "$(cur model)"; }
  fresh() {
    rm -rf "$faultd"
    : >"$launches"
    : >"$launches_agy"
    put claude.token "$GOOD1"
    ar set-global harness claude-code >/dev/null 2>&1
    setcli "$fx/claude-code/success.json" 0
  }
  ff="$faultd/claude-code.json"

  fresh
  run_cc
  check "good claude.token: the reviewer runs (control)" 0 "$RUN_RC"
  check "good claude.token: it was launched once" 1 "$(nlaunch)"
  fresh
  put claude.token "$PLACEHOLDER"
  run_cc
  nonzero "19-byte claude.token: run_reviewer fails" "$RUN_RC"
  check "19-byte claude.token: the reviewer is not launched" 0 "$(nlaunch)"
  has "19-byte claude.token: the log names the file" "$LOG" "claude.token"
  has "19-byte claude.token: the log says it is short" "$LOG" "short"
  lacks "19-byte claude.token: the log never holds the value" "$LOG" "$PLACEHOLDER"
  check "19-byte claude.token: a token problem is not a fault of the harness" absent "$([ -e "$ff" ] && echo present || echo absent)"
  put claude.token "$GOOD1"
  run_cc
  check "the token is replaced by a good one: reviews run again" 0 "$RUN_RC"
  check "the token is replaced by a good one: launched" 1 "$(nlaunch)"

  sha="$(printf '%s' "$GOOD1" | sha256sum | cut -d' ' -f1)"
  md5="$(printf '%s' "$GOOD1" | md5sum | cut -d' ' -f1)"
  for c in error-401.json:0:401 error-401.json:1:401 error-404.json:0:404; do
    f="${c%%:*}"; rest="${c#*:}"; ex="${rest%%:*}"; code="${rest#*:}"
    tag="$code (CLI exit $ex)"
    fresh
    setcli "$fx/claude-code/$f" "$ex"
    run_cc
    nonzero "$tag: run_reviewer fails" "$RUN_RC"
    check "$tag: the reviewer was started once, to find out" 1 "$(nlaunch)"
    check "$tag: a fault file for the harness is written" present "$([ -s "$ff" ] && echo present || echo absent)"
    has "$tag: the fault holds the message" "$(jq -r '.message // empty' "$ff" 2>/dev/null)" "$code"
    check "$tag: the fault holds a fingerprint of the configuration" 1 \
      "$([ -n "$(jq -r '.fingerprint // empty' "$ff" 2>/dev/null)" ] && echo 1 || echo 0)"
    lacks "$tag: the fault file holds no token bytes" "$(cat "$ff" 2>/dev/null)" "$GOOD1"
    lacks "$tag: the fault file holds no sha256 of the token" "$(cat "$ff" 2>/dev/null)" "$sha"
    lacks "$tag: the fault file holds no md5 of the token" "$(cat "$ff" 2>/dev/null)" "$md5"
    has "$tag: the log calls it a fault" "$LOG" "fault"

    run_cc
    nonzero "$tag: the next tick fails without a review" "$RUN_RC"
    check "$tag: the next tick launches nothing" 1 "$(nlaunch)"
    has "$tag: the next tick logs the fault" "$LOG" "fault"
    has "$tag: the next tick logs which harness" "$LOG" "claude-code"

    s="$(st)"
    check "$tag: status --json shows the harness in fault" fault "$(printf '%s' "$s" | jq -r '.harnesses["claude-code"].state' 2>/dev/null)"
    has "$tag: status --json carries the message" "$(printf '%s' "$s" | jq -r '.harnesses["claude-code"].message // empty' 2>/dev/null)" "$code"
    lacks "$tag: status --json holds no token bytes" "$s" "$GOOD1"
    check "$tag: a fault is not a token problem" "null null" "$(prob claude.token)"
  done

  fresh
  rm -f "$tokd/claude.token"
  setcli "$fx/claude-code/error-401.json" 0
  run_cc
  nonzero "no claude.token, 401: run_reviewer fails" "$RUN_RC"
  check "no claude.token, 401: no fault file" absent "$([ -e "$ff" ] && echo present || echo absent)"
  setcli "$fx/claude-code/success.json" 0
  run_cc
  check "no claude.token, 401: the next tick reviews" 0 "$RUN_RC"
  check "no claude.token, 401: the next tick launched the reviewer again" 2 "$(nlaunch)"

  fresh
  setcli "$fx/claude-code/error-401.json" 0
  run_cc
  put gh-acme.token "$GOOD1"
  run_cc
  check "an unrelated token changing does not clear the fault" 1 "$(nlaunch)"
  check "an unrelated token changing: status still says fault" fault "$(hstate claude-code)"

  put claude.token "$GOOD2"
  touch -d '2031-01-01 00:00:00' "$tokd/claude.token"
  check "a changed claude.token: status no longer shows the fault" ok "$(hstate claude-code)"
  setcli "$fx/claude-code/success.json" 0
  run_cc
  check "a changed claude.token: the next tick reviews" 0 "$RUN_RC"
  check "a changed claude.token: the reviewer was launched again" 2 "$(nlaunch)"

  fresh
  setcli "$fx/claude-code/error-404.json" 0
  run_cc
  check "404 for the model: in fault" fault "$(hstate claude-code)"
  ar set-global model opus >/dev/null 2>&1
  check "set-global model: the registry took it" opus "$(cur model)"
  check "set-global model: status no longer shows the fault" ok "$(hstate claude-code)"
  setcli "$fx/claude-code/success.json" 0
  run_cc
  check "set-global model: the next tick reviews" 0 "$RUN_RC"
  check "set-global model: the reviewer was launched again" 2 "$(nlaunch)"

  fresh
  setcli "$fx/claude-code/error-401.json" 0
  run_cc
  check "claude-code in fault before agy runs" fault "$(hstate claude-code)"
  run_with agy auto
  check "agy is not blocked by claude-code's fault: run_reviewer succeeds" 0 "$RUN_RC"
  check "agy is not blocked by claude-code's fault: agy was launched" 1 "$(nlaunch_agy)"
  ar set-global harness agy >/dev/null 2>&1
  check "agy is not blocked by claude-code's fault: agy is ok" ok "$(hstate agy)"
  check "claude-code stays in fault while agy reviews" present "$([ -s "$ff" ] && echo present || echo absent)"

  for c in error.json:0:"a 429 session limit" empty.json:0:"an empty envelope" garbage.txt:3:"a generic error, CLI exit 3"; do
    f="${c%%:*}"; rest="${c#*:}"; ex="${rest%%:*}"; tag="${rest#*:}"
    src="$fx/claude-code/$f"
    [ -f "$src" ] || src="$fixtures/$f"
    fresh
    setcli "$src" "$ex"
    run_cc
    nonzero "$tag: run_reviewer fails" "$RUN_RC"
    run_cc
    nonzero "$tag: and fails the next tick too" "$RUN_RC"
    check "$tag: both ticks launched the reviewer (retry as before)" 2 "$(nlaunch)"
    check "$tag: no fault file" absent "$([ -e "$ff" ] && echo present || echo absent)"
    check "$tag: status --json says ok" ok "$(hstate claude-code)"
    lacks "$tag: it is not called a fault in the log" "$LOG" "fault"
  done

  exit "$fail"
)

# ==============================================================================
# Section 6: Untrusted-repo stripping/denying of instruction dirs/files
# ==============================================================================
section_6() (
  script="$here/auto-review.sh"
  profile="$here/reviewer.sb"
  # shellcheck disable=SC1091
  . "$script"
  set +e
  fixtures=$(mktemp -d)
  trap 'rm -r -f "$fixtures"' EXIT
  fail=0

  n=0
  fresh() {
    n=$((n + 1))
    root="$fixtures/m$n"
    home="$root/userhome"
    xdg="$root/run"
    repo="$root/repo"
    origin_repo="$root/github.com/acme/widgets.git"
    mkdir -p "$home/.local/bin" "$xdg/auto-review" "$root/clones"
    chmod 755 "$fixtures" "$root" "$home" "$home/.local"
    : >"$home/.local/observed" && : >"$home/.local/observed.cwd"
    chmod 0666 "$home/.local/observed" "$home/.local/observed.cwd"
    git init -q -b main "$origin_repo"
    git -C "$origin_repo" config commit.gpgsign false
    git -C "$origin_repo" config user.name t
    git -C "$origin_repo" config user.email t@t
    printf 'keep\n' >"$origin_repo/README.md"
    git -C "$origin_repo" add README.md
    git -C "$origin_repo" commit -q -m init

    git clone -q "$origin_repo" "$repo"
    printf 'ghp_fakefake123\n' >"$xdg/auto-review/acme-widgets.token"
    mkdir -p "$home/.config/auto-review"
    printf 'ghp_fakefake123\n' >"$home/.config/auto-review/acme-widgets.token"
  }

  rc=0; out=""
  ar() {
    out=$(env -u AUTO_REVIEW_TOKEN_DIR -u GH_TOKEN HOME="$home" XDG_RUNTIME_DIR="$xdg" AUTO_REVIEW_CLONE_ROOT="$root/clones" "$script" "$@" 2>&1)
    rc=$?
  }

  bclone="$fixtures/bwrap-clone"
  mkdir -p "$bclone/.git" "$bclone/.claude" "$bclone/.gemini" "$bclone/.agents" \
    "$bclone/.agent" "$bclone/_agents" "$bclone/_agent" "$bclone/src"
  touch "$bclone/.mcp.json" "$bclone/CLAUDE.md" "$bclone/CLAUDE.local.md" \
    "$bclone/AGENTS.md" "$bclone/GEMINI.md" "$bclone/README.md"

  OS=Linux
  REVIEWER_CLONE="$bclone"
  REVIEWER_PERIMETER=(--ro-bind / /)
  AUTO_REVIEW_DOCKERENV="$fixtures/no-dockerenv" sandbox_command
  bwrap_args="${REVIEWER_SANDBOX[*]}"
  for guarded in AGENTS.md GEMINI.md .gemini .agents .agent _agents _agent; do
    lacks "bwrap skips root entry $guarded" "$bwrap_args" "--bind $bclone/$guarded"
  done

  sb_deny=$(tr -d '\r' <"$profile" | awk '/^\(deny file-write\*/ && ++n == 2, /\)\)\)$/' | grep -v '^[[:space:]]*;;')
  for sub in /.gemini /.agents /.agent /_agents /_agent; do
    has "reviewer.sb denies subpath $sub" "$sb_deny" "(subpath (string-append (param \"CLONE\") \"$sub\"))"
  done
  for lit in /AGENTS.md /GEMINI.md; do
    has "reviewer.sb denies literal $lit" "$sb_deny" "(literal (string-append (param \"CLONE\") \"$lit\"))"
  done

  rclone="$fixtures/reviewer-clone"
  rbin="$fixtures/rbin"
  mkdir -p "$rclone/.git" "$rclone/src" "$rbin"
  touch "$rclone/.auto-review-history.md" "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md"
  REVIEWER_CLONE="$rclone"
  REVIEWER_PERIMETER=()
  chmod 755 "$fixtures"
  captured_guidance_file="$fixtures/guidance.txt"
  : >"$captured_guidance_file" && chmod 0666 "$captured_guidance_file"

  cat >"$rbin/bwrap" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
FAKE
  cat >"$rbin/claude" <<FAKE
#!/bin/sh
while [ \$# -gt 0 ]; do
  case "\$1" in
    --append-system-prompt)
      printf '%s' "\$2" >"$captured_guidance_file"
      shift 2
      ;;
    *) shift ;;
  esac
done
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"usage":{"output_tokens":12},"result":"**No findings.** - ok"}'
FAKE
  chmod 755 "$rbin/bwrap" "$rbin/claude"
  PATH="$rbin:$PATH"
  export PATH
  sleep() { :; }

  for name in GEMINI.md .gemini .agents .agent _agents _agent; do
    mkdir -p "$rclone/nested"
    if [ "$name" = "GEMINI.md" ]; then
      printf 'inject\n' >"$rclone/nested/$name"
    else
      mkdir -p "$rclone/nested/$name"
      printf 'inject\n' >"$rclone/nested/$name/config"
    fi
    : >"$captured_guidance_file" && chmod 0666 "$captured_guidance_file"
    run_out=$(run_reviewer 1 "$fixtures/out.md" "$rclone/.auto-review-history.md" \
      "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md" 2>&1)
    run_rc=$?
    rm -r -f "$rclone/nested"
    check "pre-launch check refuses surviving $name (rc=1)" 1 "$run_rc"
    has "pre-launch check logs surviving $name" "$run_out" "survived the clearing"
  done

  : >"$captured_guidance_file" && chmod 0666 "$captured_guidance_file"
  run_reviewer 1 "$fixtures/out.md" "$rclone/.auto-review-history.md" \
    "$rclone/.auto-review-diff.patch" "$rclone/.auto-review-pr.md" >/dev/null 2>&1
  guidance_text=$(cat "$captured_guidance_file" 2>/dev/null)
  for token in GEMINI.md .gemini/ .agents/ .agent/ _agents/ _agent/; do
    has "guidance names stripped $token" "$guidance_text" "$token"
  done

  fresh
  git -C "$origin_repo" checkout -q -b pr-branch
  mkdir -p "$origin_repo/sub" "$origin_repo/.gemini" "$origin_repo/.agents" \
    "$origin_repo/.agent" "$origin_repo/_agents" "$origin_repo/_agent" "$origin_repo/src"
  printf 'bad\n' | tee "$origin_repo/GEMINI.md" "$origin_repo/sub/gemini.md" \
    "$origin_repo/AGENTS.md" "$origin_repo/CLAUDE.md" \
    "$origin_repo/.gemini/settings.json" "$origin_repo/.agents/a.md" \
    "$origin_repo/.agent/b.md" "$origin_repo/_agents/c.md" "$origin_repo/_agent/d.md" >/dev/null
  printf 'good\n' >"$origin_repo/src/keep.ts"
  git -C "$origin_repo" add -f .
  git -C "$origin_repo" commit -q -m "add instruction files"
  pr_sha=$(git -C "$origin_repo" rev-parse HEAD)
  git -C "$origin_repo" checkout -q main

  cat >"$home/.local/bin/gh" <<FAKE
#!/bin/sh
case "\$*" in
  "api user -q .login") echo tester ;;
  "pr view 1 --repo acme/widgets --json number,headRefOid,headRefName,baseRefName,author,title,state,labels"*)
    printf '1\t%s\tmain\tfalse\tfalse\tauthor\tpr-branch\t\tTest PR\n' "$pr_sha"
    ;;
  "repo clone acme/widgets "*)
    git clone -q "$origin_repo" "\$4"
    ;;
  "pr checkout 1 --detach --force")
    git checkout -q -f --detach origin/pr-branch
    ;;
  "pr view 1 --repo acme/widgets --json baseRefName"*)
    echo main
    ;;
  *) exit 0 ;;
esac
FAKE
  cat >"$home/.local/bin/bwrap" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
FAKE
  cat >"$home/.local/bin/claude" <<'FAKE'
#!/bin/sh
rec="$(cd "$(dirname "$0")/.." && pwd)/observed"
find . -path ./.git -prune -o -print | sed 's#^./##' >"$rec"
pwd -P >"$rec.cwd"
exit 0
FAKE
  chmod 755 "$home/.local/bin/gh" "$home/.local/bin/bwrap" "$home/.local/bin/claude"

  if [ "$(uname -s)" = Linux ]; then
    AUTO_REVIEW_INSIDE_CONTAINER=1 ar tick "$repo" --review 1
    rc=$?
    check "tick exits 0" 0 "$rc"
    [ -s "$home/.local/observed" ] || { printf 'FAIL  observed file missing/empty\n'; fail=1; }
    tclone="$root/clones/acme-widgets"
    seen() { grep -qxF "$1" "$home/.local/observed" 2>/dev/null && echo present || echo absent; }
    for stripped in GEMINI.md sub/gemini.md .gemini .agents .agent _agents _agent; do
      check "post-checkout strips $stripped in the worktree (while keeping src/keep.ts)" "present:absent" \
        "$(seen src/keep.ts):$(seen "$stripped")"
    done
    check "the scrub ran in a worktree, not in the main clone" "no" \
      "$([ "$(cat "$home/.local/observed.cwd" 2>/dev/null)" = "$(cd "$tclone" && pwd -P)" ] && echo yes || echo no)"
    check "the main clone was not checked out to the PR" "absent" \
      "$([ -e "$tclone/src/keep.ts" ] && echo present || echo absent)"
  fi

  exit "$fail"
)

# ==============================================================================
# Section 7: Secret-scrubbing hardening
# ==============================================================================
section_7() (
  script="$here/auto-review.sh"
  fixtures=$(mktemp -d)
  chmod 755 "$fixtures"
  rbin="$(mktemp -d "${AUTO_REVIEW_TEST_BIN_ROOT:-$fixtures}/rbin.XXXXXX")"
  chmod 755 "$rbin"
  trap 'rm -rf "$fixtures" "$rbin"' EXIT
  fail=0

  AGYTOK="agy-oauth-FIXTURE-secret-1234567890"
  CCENVTOK="cc-oauth-env-FIXTURE-secret-9876543210"
  GHTOK="ghp_FIXTUREsecret0123456789abcdefABCD"

  mkdir -p "$fixtures/userhome" "$fixtures/tokens" "$fixtures/lock" "$fixtures/faults" "$fixtures/run"
  chmod 700 "$fixtures/tokens" "$fixtures/lock"
  printf '%s\n' "$AGYTOK" >"$fixtures/tokens/antigravity-oauth-token"
  printf '%s\n' "$GHTOK" >"$fixtures/tokens/acme-widgets.token"
  chmod 600 "$fixtures/tokens/antigravity-oauth-token" "$fixtures/tokens/acme-widgets.token"

  export HOME="$fixtures/userhome"
  export AUTO_REVIEW_TOKEN_DIR="$fixtures/tokens"
  export AUTO_REVIEW_LOCK_DIR="$fixtures/lock"
  export AUTO_REVIEW_FAULT_DIR="$fixtures/faults"
  export AUTO_REVIEW_STATUS_FILE="$fixtures/run/status.json"
  export CLAUDE_CODE_OAUTH_TOKEN="$CCENVTOK"
  export GH_TOKEN="$GHTOK"

  # shellcheck disable=SC1091
  . "$script"
  set +e

  # 1. held_token_values includes antigravity-oauth-token and CLAUDE_CODE_OAUTH_TOKEN
  held="$(held_token_values)"
  has "held_token_values includes antigravity-oauth-token" "$held" "$AGYTOK"
  has "held_token_values includes CLAUDE_CODE_OAUTH_TOKEN" "$held" "$CCENVTOK"
  has "held_token_values includes *.token" "$held" "$GHTOK"

  # 2. post_review refuses antigravity-oauth-token and CLAUDE_CODE_OAUTH_TOKEN
  cat >"$rbin/gh" <<FAKE
#!/bin/sh
cat >/dev/null
echo "\$*" >>"$fixtures/gh.calls"
FAKE
  chmod 755 "$rbin/gh"
  PATH="$rbin:$PATH"
  export PATH

  for label_tok in "antigravity-oauth-token:$AGYTOK" "CLAUDE_CODE_OAUTH_TOKEN:$CCENVTOK"; do
    lbl="${label_tok%%:*}"
    val="${label_tok#*:}"
    rm -f "$fixtures/gh.calls"
    printf '**No findings.** leaked %s\n' "$val" >"$fixtures/body.md"
    post_review acme/widgets 7 "$fixtures/body.md" "0123456789abcdef0123456789abcdef01234567" >/dev/null 2>&1
    rc=$?
    check "post_review refuses $lbl (non-zero rc)" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
    check "post_review refuses $lbl (no gh call)" "0" "$([ -s "$fixtures/gh.calls" ] && echo 1 || echo 0)"
  done

  # 3. Table-driven scrubbing across reviewer_error and fault_record
  check_scrub_surface() {
    local name="$1" secret="$2"
    printf '{"type":"result","is_error":true,"result":"failed with %s"}\n' "$secret" >"$fixtures/raw.json"
    : >"$fixtures/err.txt"
    local r_out
    r_out="$(reviewer_error "$fixtures/raw.json" "$fixtures/err.txt")"
    lacks "reviewer_error scrubs $name" "$r_out" "$secret"

    fault_record "claude-code" "sonnet" "claude.token" "API error leaking $secret in message"
    local f_msg
    f_msg="$(jq -r '.message // empty' "$fixtures/faults/claude-code.json" 2>/dev/null)"
    lacks "fault_record scrubs $name" "$f_msg" "$secret"
  }

  check_scrub_surface "antigravity-oauth-token" "$AGYTOK"
  check_scrub_surface "CLAUDE_CODE_OAUTH_TOKEN" "$CCENVTOK"
  check_scrub_surface "held GH_TOKEN" "$GHTOK"
  check_scrub_surface "ghp_ shape" "ghp_AbCdEf1234567890SecretValue"
  check_scrub_surface "gho_ shape" "gho_AbCdEf1234567890SecretValue"
  check_scrub_surface "ghu_ shape" "ghu_AbCdEf1234567890SecretValue"
  check_scrub_surface "ghs_ shape" "ghs_AbCdEf1234567890SecretValue"
  check_scrub_surface "ghr_ shape" "ghr_AbCdEf1234567890SecretValue"
  check_scrub_surface "github_pat_ shape" "github_pat_11ABCDEF""0123456789Secret"
  check_scrub_surface "sk-ant- shape" "sk-ant-api03-""secret9999abcdef"
  check_scrub_surface "ya29. shape" "ya29.a0AfH6SMBsecret123456"
  check_scrub_surface "Bearer shape" "Bearer my-secret-bearer-token-xyz"

  # 4. Scrubbing in tick_errors.*.reason and recent_results.*.reason + 300-char cap
  root="$fixtures/tick-scrub"
  bin="$root/bin"
  mkdir -p "$bin" "$root/run" "$root/state" "$root/locks" "$root/tokens" "$root/clones/clones" "$root/userhome/.local"
  ln -s "$bin" "$root/userhome/.local/bin"
  printf '%s\n' "$GHTOK" >"$root/tokens/gh-acme.token"
  reg="$root/projects.json"
  jq -n '{version: 1, harness: "claude-code", model: "sonnet", parallel: "1", slots: "4", projects: {"acme/a": {adopted_at: "2026-11-01T00:00:00Z", all: true, self_review: false}}}' >"$reg"

  long_pad="$(printf '%0400d' 0)"
  cat >"$bin/gh" <<FAKE
#!/bin/sh
case "\$*" in
  "api user -q .login")
    echo "HTTP 401 token=sk-ant-api03-leaked999 Bearer secret-bearer-999 $long_pad" >&2
    exit 1 ;;
esac
exit 0
FAKE
  printf '#!/bin/sh\nexit 0\n' >"$bin/claude"
  printf '#!/bin/sh\nexit 0\n' >"$bin/bwrap"
  chmod 755 "$bin/gh" "$bin/claude" "$bin/bwrap"

  env -u GH_TOKEN HOME="$root/userhome" AUTO_REVIEW_INSIDE_CONTAINER=1 \
    AUTO_REVIEW_REGISTRY="$reg" AUTO_REVIEW_TOKEN_DIR="$root/tokens" \
    AUTO_REVIEW_CLONE_ROOT="$root/clones" AUTO_REVIEW_WORKTREE_ROOT="$root/worktrees" \
    AUTO_REVIEW_STATE_DIR="$root/state" AUTO_REVIEW_LOCK_DIR="$root/locks" \
    AUTO_REVIEW_STATUS_FILE="$root/run/status.json" \
    AUTO_REVIEW_MEMINFO="$root/meminfo" AUTO_REVIEW_MEMORY_FLOOR_MB=100 AUTO_REVIEW_REVIEW_MB=100 \
    PATH="$bin:$PATH" "$script" tick >/dev/null 2>&1 || true

  te_reason="$(jq -r '.tick_errors["acme/a"].reason // empty' "$root/run/status.json" 2>/dev/null)"
  check "tick_errors reason is non-empty" 1 "$([ -n "$te_reason" ] && echo 1 || echo 0)"
  lacks "tick_errors reason scrubs sk-ant-" "$te_reason" "sk-ant-api03-leaked999"
  lacks "tick_errors reason scrubs Bearer" "$te_reason" "secret-bearer-999"
  check "tick_errors reason capped to <= 300 chars" 1 "$([ "${#te_reason}" -le 300 ] && echo 1 || echo 0)"

  # 300-char cap on reviewer_error
  printf '{"type":"result","is_error":true,"result":"err %s"}\n' "$long_pad" >"$fixtures/long.json"
  long_err="$(reviewer_error "$fixtures/long.json" "$fixtures/err.txt")"
  check "reviewer_error capped to <= 300 chars" 1 "$([ "${#long_err}" -le 300 ] && echo 1 || echo 0)"

  exit "$fail"
)

run_sections_parallel section_1 section_2 section_3 section_4 section_5 section_6 section_7
exit $?
