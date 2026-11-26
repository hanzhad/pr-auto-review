#!/usr/bin/env bash
# Consolidated daemon, scheduler/tick, worktrees, review-record, and machine-mark
# tests for auto-review (upstream issue).
# Consolidates:
#   - test-auto-review-daemon.sh
#   - test-auto-review-tick.sh
#   - test-auto-review-worktrees.sh
#   - test-auto-review-record.sh
#   - test-auto-review-mark.sh
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

# ==============================================================================
# Section 1: Daemon loop, round-robin queue, memory floor, and lock
# ==============================================================================
section_1() (
  # shellcheck disable=SC1091
  . "$here/lib/registry.sh"
  # shellcheck disable=SC1091
  . "$here/lib/daemon.sh"
  fail=0

  check_match() {
    if [[ "$3" =~ $2 ]]; then
      printf 'ok    %s\n' "$1"
    else
      printf 'FAIL  %s\n  pattern: %s\n  got:     %s\n' "$1" "$2" "$3"
      fail=1
    fi
  }

  logged=""
  log() { logged="${logged}$*"$'\n'; }

  fixtures=$(mktemp -d)
  trap 'rm -rf "$fixtures"' EXIT

  cat <<'EOF' >"$fixtures/meminfo_high"
MemTotal:       16384000 kB
MemFree:         4000000 kB
MemAvailable:    3072000 kB
Buffers:          500000 kB
EOF
  rc=0
  check_memory_floor 1500 "$fixtures/meminfo_high" || rc=$?
  check "memory_floor: 3000 MB passes floor of 1500 MB" 0 "$rc"

  cat <<'EOF' >"$fixtures/meminfo_low"
MemTotal:       16384000 kB
MemFree:          200000 kB
MemAvailable:     819200 kB
Buffers:          100000 kB
EOF
  rc=0
  logged=""
  check_memory_floor 1500 "$fixtures/meminfo_low" || rc=$?
  check "memory_floor: 800 MB fails floor of 1500 MB" 1 "$rc"
  check_match "memory_floor: logs postponement notice" "available memory \(800 MB\) below floor \(1500 MB\)" "$logged"

  rc=0
  check_memory_floor 1500 "$fixtures/nonexistent_meminfo" || rc=$?
  check "memory_floor: missing proc/meminfo defaults to pass" 0 "$rc"

  state_file="$fixtures/queue.state"
  check "queue step 1: repo1" "org/repo1" "$(daemon_next_repo "$state_file" "org/repo1" "org/repo2" "org/repo3")"
  check "queue step 2: repo2" "org/repo2" "$(daemon_next_repo "$state_file" "org/repo1" "org/repo2" "org/repo3")"
  check "queue step 3: repo3" "org/repo3" "$(daemon_next_repo "$state_file" "org/repo1" "org/repo2" "org/repo3")"
  check "queue step 4: wraps around to repo1" "org/repo1" "$(daemon_next_repo "$state_file" "org/repo1" "org/repo2" "org/repo3")"

  reg="$fixtures/projects.json"
  registry_init "$reg"
  registry_adopt "$reg" "org/alpha"
  registry_adopt "$reg" "org/beta"

  AUTO_REVIEW_LOCK_DIR="$fixtures/run_auto_review"
  DAEMON_LOCK_DIR="$AUTO_REVIEW_LOCK_DIR"
  LOCK_DIR="$AUTO_REVIEW_LOCK_DIR"
  MEMORY_FLOOR_MB=1000

  ticked=""
  run_repo_tick() { ticked="$1"; }

  daemon_tick_once "$reg" "$fixtures/d_state"
  check "daemon_tick_once: dispatches alpha" "org/alpha" "$ticked"
  daemon_tick_once "$reg" "$fixtures/d_state"
  check "daemon_tick_once: dispatches beta next" "org/beta" "$ticked"

  mkdir -p "$LOCK_DIR"
  echo "99999" >"$LOCK_DIR/daemon.lock"
  lock_rc=0
  daemon_tick_once "$reg" "$fixtures/d_state" || lock_rc=$?
  check "daemon_tick_once: lock held returns 3" 3 "$lock_rc"
  rm -f "$LOCK_DIR/daemon.lock"

  exit "$fail"
)

# ==============================================================================
# Section 2: Scheduler and parallel machine tick
# ==============================================================================
section_2() (
  script="$here/auto-review.sh"
  reglib="$here/lib/registry.sh"
  schedlib="$here/lib/scheduler.sh"
  fixtures=$(mktemp -d)
  fixtures=$(cd "$fixtures" && pwd -P)
  trap 'chmod -R u+rwx "$fixtures" 2>/dev/null; rm -r -f "$fixtures"' EXIT
  fail=0

  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  real_git=$(command -v git)
  g() { "$real_git" "$@"; }

  sp() {
    bash -c '. "$1"; . "$2"; shift 2; log() { :; }; "$@"' _ "$reglib" "$schedlib" "$@" 2>&1
  }
  P="$fixtures/pick"; mkdir -p "$P"
  pend="$P/pending"; runn="$P/running"; cur="$P/cursor"

  check "lib/scheduler.sh exists" "present" "$([ -f "$schedlib" ] && echo present || echo absent)"

  printf 'a 1\na 2\nb 3\nb 4\nc 5\nc 6\n' >"$pend"; : >"$runn"; rm -f "$cur"
  seq=""
  for i in 1 2 3 4 5 6; do seq="$seq$(sp sched_pick "$pend" "$runn" "$cur" a b c | tr ' ' ':') "; done
  check "pick: strict round-robin, oldest first inside a project" "a:1 b:3 c:5 a:2 b:4 c:6 " "$seq"
  sp sched_pick "$pend" "$runn" "$cur" a b c >/dev/null; rc=$?
  check "pick: nothing pending is rc 1" 1 "$rc"
  check "pick: nothing pending leaves the cursor on the last pick" "c" "$(cat "$cur" 2>/dev/null)"

  printf 'a 1\nb 2\nc 3\n' >"$pend"; printf 'b\n' >"$cur"
  check "pick: cursor b means c is next" "c 3" "$(sp sched_pick "$pend" "$runn" "$cur" a b c)"
  printf 'a 1\nb 2\nc 3\n' >"$pend"; printf 'c\n' >"$cur"
  check "pick: cursor c wraps to a" "a 1" "$(sp sched_pick "$pend" "$runn" "$cur" a b c)"
  printf 'a 1\nb 2\nc 3\n' >"$pend"; printf 'gone/repo\n' >"$cur"
  check "pick: a cursor that is no longer registered starts at the first" "a 1" "$(sp sched_pick "$pend" "$runn" "$cur" a b c)"
  printf 'a 1\nb 2\nc 3\n' >"$pend"; printf 'a\n' >"$cur"
  sp sched_pick "$pend" "$runn" "$cur" a b c >/dev/null
  check "pick: the pick is removed from pending" "a 1
c 3" "$(cat "$pend")"
  check "pick: the cursor is written" "b" "$(cat "$cur")"

  printf 'a 1\nb 2\n' >"$pend"; printf 'a\n' >"$runn"; rm -f "$cur"
  check "pick: skips a project that has a review running while another is free" "b 2" "$(sp sched_pick "$pend" "$runn" "$cur" a b)"
  printf 'a 1\nb 2\nc 3\n' >"$pend"; printf 'a\nb\n' >"$runn"; printf 'a\n' >"$cur"
  check "pick: the free project is c even though b is next in rotation" "c 3" "$(sp sched_pick "$pend" "$runn" "$cur" a b c)"
  printf 'a 1\nb 2\n' >"$pend"; printf 'a\nb\n' >"$runn"; printf 'a\n' >"$cur"
  check "pick: all busy, the next in rotation after the cursor doubles up" "b 2" "$(sp sched_pick "$pend" "$runn" "$cur" a b)"
  printf 'b 2\n' >"$pend"; printf 'a\n' >"$runn"; rm -f "$cur"
  check "pick: a running project with nothing pending is not picked, b is" "b 2" "$(sp sched_pick "$pend" "$runn" "$cur" a b)"
  : >"$runn"

  fivepend() { printf 'p1 1\np1 2\np2 1\np2 2\np3 1\np3 2\np4 1\np4 2\np5 1\np5 2\n' >"$pend"; }
  fivepend; rm -f "$cur"
  t1=""; for i in 1 2 3 4; do t1="$t1$(sp sched_pick "$pend" "$runn" "$cur" p1 p2 p3 p4 p5 | cut -d' ' -f1) "; done
  fivepend
  t2=""; for i in 1 2 3 4; do t2="$t2$(sp sched_pick "$pend" "$runn" "$cur" p1 p2 p3 p4 p5 | cut -d' ' -f1) "; done
  check "pick: tick 1 of 5 projects with 4 slots takes p1..p4" "p1 p2 p3 p4 " "$t1"
  check "pick: tick 2 starts at p5 (persistent cursor)" "p5 p1 p2 p3 " "$t2"

  mi="$P/meminfo"
  meminfo() { printf 'MemTotal:       16000000 kB\nMemAvailable:   %s kB\n' "$(($1 * 1024))" >"$mi"; }
  workers() {
    AUTO_REVIEW_MEMINFO="$mi" AUTO_REVIEW_MEMORY_FLOOR_MB=1000 AUTO_REVIEW_REVIEW_MB=1000 sp sched_workers "$1"
  }
  meminfo 3100
  check "workers: 3100 MB free, floor 1000, 1000 per review: cap 2, parallel 3 gives 2" "2" "$(workers 3)"
  check "workers: parallel below the cap stays" "1" "$(workers 1)"
  meminfo 10000
  check "workers: plenty of memory gives parallel" "3" "$(workers 3)"
  meminfo 900
  check "workers: below the floor gives 0" "0" "$(workers 3)"

  R="$P/projects.json"
  reg() { printf '%s\n' "$1" >"$R"; }
  sfn() {
    env -u AUTO_REVIEW_PARALLEL -u AUTO_REVIEW_SLOTS "${@:2}" bash -c '. "$1"; . "$2"; "$3" "$4"' _ "$reglib" "$schedlib" "$1" "$R" 2>&1
  }
  reg '{"version":1,"projects":{}}'
  check "parallel: default 1" "1" "$(sfn sched_parallel)"
  check "slots: default is parallel (1)" "1" "$(sfn sched_slots)"
  reg '{"version":1,"parallel":"3","projects":{}}'
  check "slots: parallel 3 and no slots gives 3" "3" "$(sfn sched_slots)"
  check "parallel: from the registry" "3" "$(sfn sched_parallel)"
  reg '{"version":1,"parallel":"3","slots":"4","projects":{}}'
  check "slots: an explicit slots wins" "4" "$(sfn sched_slots)"
  reg '{"version":1,"projects":{}}'
  check "slots: env AUTO_REVIEW_PARALLEL=2 gives slots 2" "2" "$(sfn sched_slots AUTO_REVIEW_PARALLEL=2)"

  n=0
  mk_world() {
    n=$((n + 1))
    root="$fixtures/w$n"
    bin="$root/bin"; obs="$root/obs"
    mkdir -p "$bin" "$obs" "$root/run" "$root/state" "$root/locks" "$root/tokens" \
      "$root/prs" "$root/heads" "$root/reviewed" "$root/sleep" "$root/clones/clones"
    : >"$obs/events"; : >"$root/gh-calls"
    reg="$root/projects.json"
    local par="$1" slt="$2"; shift 2
    jq -n --arg p "$par" --arg s "$slt" \
      '{version: 1, harness: "claude-code", model: "sonnet", projects: {}}
       + (if $p != "-" then {parallel: $p} else {} end) + (if $s != "-" then {slots: $s} else {} end)' >"$reg"
    local spec repo prs slug owner o c pr
    for spec in "$@"; do
      repo="${spec%%:*}"; prs="${spec#*:}"; slug=$(printf '%s' "$repo" | tr '/' '-'); owner="${repo%%/*}"
      printf 'ghp_fake%s\n' "$owner" >"$root/tokens/gh-$owner.token"
      o="$root/origins/$slug"; c="$root/clones/$slug"
      mkdir -p "$root/origins"
      g init -q -b main "$o"
      printf 'readme\n' >"$o/README.md"; g -C "$o" add -A; g -C "$o" commit -q -m init
      : >"$root/prs/$slug"
      for pr in $(printf '%s' "$prs" | tr ',' ' '); do
        g -C "$o" checkout -q -b "pr-$pr" main
        printf 'change %s\n' "$pr" >"$o/f$pr.txt"; g -C "$o" add -A; g -C "$o" commit -q -m "change $pr"
        g -C "$o" rev-parse HEAD >"$root/heads/$slug-$pr"
        echo "$pr" >>"$root/prs/$slug"
      done
      g -C "$o" checkout -q main
      g clone -q "$o" "$c"
      printf '%s\n' "$c" >"$root/clones/clones/$slug"
      jq --arg r "$repo" '.projects[$r] = {adopted_at: "2026-11-01T00:00:00Z", all: true, self_review: false}' "$reg" >"$reg.t" && mv "$reg.t" "$reg"
    done

    cat >"$bin/gh" <<'FAKE'
#!/bin/sh
echo "gh $*" >>"$FAKE_ROOT/gh-calls"
repo=""; prev=""
for a in "$@"; do [ "$prev" = "--repo" ] && repo="$a"; prev="$a"; done
case "$*" in
  "api user -q .login") echo tester; exit 0 ;;
  "pr list "*)
    slug=$(printf '%s' "$repo" | tr '/' '-')
    while read -r p; do
      n=0; [ -f "$FAKE_ROOT/reviewed/$slug-$p" ] && n=$(grep -c . "$FAKE_ROOT/reviewed/$slug-$p" || true)
      printf '%s\t%s\tmain\tfalse\tfalse\tauthor\tpr-%s\t\t%s\tChange %s\n' "$p" "$(cat "$FAKE_ROOT/heads/$slug-$p")" "$p" "$n" "$p"
    done <"$FAKE_ROOT/prs/$slug"
    exit 0 ;;
  "pr checkout "*)
    git checkout -q --detach "origin/pr-$3"; exit 0 ;;
  "pr view "*"baseRefName -q .baseRefName") echo main; exit 0 ;;
  "pr view "*) echo stub; exit 0 ;;
  "api repos/"*"/pulls/"*"/reviews --input -")
    r=$(printf '%s' "$2" | sed 's|^repos/||; s|/pulls/.*||'); pr=$(printf '%s' "$2" | sed 's|.*/pulls/||; s|/reviews||')
    sha=$(cat | jq -r '.commit_id // empty')
    echo "post $r $pr $sha" >>"$FAKE_ROOT/obs/events"
    echo "$sha" >>"$FAKE_ROOT/reviewed/$(printf '%s' "$r" | tr '/' '-')-$pr"
    exit 0 ;;
  "api --paginate repos/"*"/pulls/"*"/reviews "*)
    r=$(printf '%s' "$3" | sed 's|^repos/||; s|/pulls/.*||'); pr=$(printf '%s' "$3" | sed 's|.*/pulls/||; s|/reviews||')
    f="$FAKE_ROOT/reviewed/$(printf '%s' "$r" | tr '/' '-')-$pr"
    [ -f "$f" ] && cat "$f"
    exit 0 ;;
  "api repos/"*"/actions/runs"*) echo 0; exit 0 ;;
  "api repos/"*"/commits/"*"/status"*) echo none; exit 0 ;;
esac
exit 0
FAKE
    cat >"$bin/bwrap" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
FAKE
    cat >"$bin/claude" <<'FAKE'
#!/bin/sh
root=$(cd -P "$(dirname "$0")/.." && pwd)
p=$(pwd -P); pr=${p##*/pr-}; s=$(basename "$(dirname "$p")")
echo "start $s $pr" >>"$root/obs/events"
if [ -f "$root/wait-event/$s-$pr" ]; then
  want=$(cat "$root/wait-event/$s-$pr")
  _w=0
  while [ "$_w" -lt 80 ] && ! grep -qF "$want" "$root/obs/events" 2>/dev/null; do
    sleep 0.05
    _w=$((_w + 1))
  done
fi
if [ -f "$root/wait-starts/$s-$pr" ]; then
  want_n=$(cat "$root/wait-starts/$s-$pr")
  _w=0
  while [ "$_w" -lt 80 ] && [ "$(grep -c '^start ' "$root/obs/events" 2>/dev/null || echo 0)" -lt "$want_n" ]; do
    sleep 0.05
    _w=$((_w + 1))
  done
fi
[ -f "$root/sleep/$s-$pr" ] && sleep "$(cat "$root/sleep/$s-$pr")"
[ -f "$root/run/status.json" ] && cp "$root/run/status.json" "$root/obs/status-$s-$pr"
echo "end $s $pr" >>"$root/obs/events"
printf '{"type":"result","subtype":"success","is_error":false,"usage":{"output_tokens":20},"result":"**No findings.** fine"}\n'
FAKE
    chmod 755 "$bin/gh" "$bin/bwrap" "$bin/claude"
  }

  run_tick() {
    [ -e "$root/userhome/.local/bin" ] || { mkdir -p "$root/userhome/.local" && ln -s "$bin" "$root/userhome/.local/bin"; }
    out=$(env -u GH_TOKEN HOME="$root/userhome" AUTO_REVIEW_INSIDE_CONTAINER=1 \
      AUTO_REVIEW_REGISTRY="$reg" AUTO_REVIEW_TOKEN_DIR="$root/tokens" \
      AUTO_REVIEW_CLONE_ROOT="$root/clones" AUTO_REVIEW_WORKTREE_ROOT="$root/worktrees" \
      AUTO_REVIEW_STATE_DIR="$root/state" AUTO_REVIEW_LOCK_DIR="$root/locks" \
      AUTO_REVIEW_STATUS_FILE="$root/run/status.json" AUTO_REVIEW_TIMEOUT=60 \
      AUTO_REVIEW_MEMINFO="$root/meminfo" AUTO_REVIEW_MEMORY_FLOOR_MB=100 AUTO_REVIEW_REVIEW_MB=100 \
      PATH="$bin:$PATH" FAKE_ROOT="$root" "$@" "$script" tick 2>&1)
    rc=$?
  }
  setmem() { printf 'MemAvailable: %s kB\n' "$(($1 * 1024))" >"$root/meminfo"; }
  posted() { grep '^post ' "$obs/events" | awk '{print $2 ":" $3}' | tr '\n' ' '; }
  started() { grep '^start ' "$obs/events" | awk '{print $2 ":" $3}' | tr '\n' ' '; }
  maxoverlap() { awk '/^start /{c++; if(c>m)m=c} /^end /{c--} END{print m+0}' "$obs/events"; }
  nth() { grep -nE "$1" "$obs/events" | sed -n "${2}p" | cut -d: -f1; }
  before() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ] && echo yes || echo no; }

  mk_world - - acme/a:3,1,2 acme/b:5
  setmem 10000
  t1=""; t2=""; t3=""; t4=""
  for i in 1 2 3 4; do
    run_tick; [ "$rc" = 0 ] || printf 'FAIL  tick %s exited %s\n%s\n' "$i" "$rc" "$(echo "$out" | tail -5)"
    eval "t$i=\"\$(posted)\""
    [ "$i" = 1 ] && cp "$obs/status-acme-a-1" "$root/snap1" 2>/dev/null
    : >"$obs/events"
  done
  check "parallel=1: tick 1 reviews the OLDEST PR of the first project (a#1, listing was 3,1,2)" "acme/a:1 " "$t1"
  check "parallel=1: tick 2 moves to the next project (b#5)" "acme/b:5 " "$t2"
  check "parallel=1: tick 3 is back at a (a#2)" "acme/a:2 " "$t3"
  check "parallel=1: tick 4 is a#3, b has nothing left" "acme/a:3 " "$t4"
  check "parallel=1: status during the one review lists one active" "1" "$(jq -r '.active | length' "$root/snap1" 2>&1)"
  run_tick
  check "parallel=1: tick 5 has nothing to review: exits 0 and posts nothing" "0:" "$rc:$(posted)"

  mk_world 1 4 acme/a:3,1,2 acme/b:5
  setmem 10000
  run_tick
  check "parallel=1 slots=4: exits 0" 0 "$rc"
  check "parallel=1 slots=4: a#1 b#5 a#2 a#3, one after another, rotating" "acme/a:1 acme/b:5 acme/a:2 acme/a:3 " "$(posted)"
  check "parallel=1 slots=4: never two at once" "1" "$(maxoverlap)"
  check "parallel=1 slots=4: the first project was reviewed at its own head" "post acme/a 1 $(cat "$root/heads/acme-a-1")" "$(grep '^post acme/a 1 ' "$obs/events")"

  mk_world 2 4 acme/a:1,2,3 acme/b:5
  setmem 10000
  mkdir -p "$root/wait-event"
  echo "start acme-a 2" >"$root/wait-event/acme-a-1"; echo 0.2 >"$root/sleep/acme-b-5"
  run_tick
  check "parallel=2: exits 0" 0 "$rc"
  check "parallel=2: the first two reviews started are a#1 and b#5" "acme-a:1 acme-b:5" "$(started | tr ' ' '\n' | sed -n '1,2p' | sort | tr '\n' ' ' | sed 's/ $//')"
  check "parallel=2: the third start is a#2" "acme-a:2" "$(started | tr ' ' '\n' | sed -n '3p')"
  check "parallel=2: a#2 starts only after b#5 ended (the free worker)" "yes" "$(before "$(nth '^end acme-b 5' 1)" "$(nth '^start acme-a 2' 1)")"
  check "parallel=2: a#2 starts while a#1 is still running (doubling up on a)" "yes" "$(before "$(nth '^start acme-a 2' 1)" "$(nth '^end acme-a 1' 1)")"
  check "parallel=2: all four reviews were started" "4" "$(started | wc -w | tr -d ' ')"
  check "parallel=2: never more than two at once" "2" "$(maxoverlap)"
  check "parallel=2: each PR is posted exactly once" "acme/a:1 acme/a:2 acme/a:3 acme/b:5 " "$(posted | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/^ //')"
  check "parallel=2: a#2 is posted against its own sha" "post acme/a 2 $(cat "$root/heads/acme-a-2")" "$(grep '^post acme/a 2 ' "$obs/events")"
  check "parallel=2: b#5 is posted against its own sha" "post acme/b 5 $(cat "$root/heads/acme-b-5")" "$(grep '^post acme/b 5 ' "$obs/events")"

  mk_world 2 - acme/a:1,2 acme/b:1 acme/c:1
  setmem 10000
  run_tick
  check "slots default: parallel=2 and no slots starts exactly 2 reviews in a tick" "2" "$(started | wc -w | tr -d ' ')"
  check "slots default: the two are a#1 and b#1 (different projects)" "acme/a:1 acme/b:1 " "$(posted | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/^ //')"
  mk_world 1 3 acme/a:1,2 acme/b:1 acme/c:1
  setmem 10000
  run_tick
  check "explicit slots: parallel=1 slots=3 starts 3 reviews" "3" "$(started | wc -w | tr -d ' ')"

  mk_world 1 4 acme/r1:1,2 acme/r2:1,2 acme/r3:1,2 acme/r4:1,2 acme/r5:1,2
  setmem 10000
  run_tick
  check "5 projects: tick 1 reviews r1..r4" "acme/r1:1 acme/r2:1 acme/r3:1 acme/r4:1 " "$(posted)"
  check "5 projects: r4 reviewed and r5 not yet after tick 1" "1/0" "$(grep -c '^post acme/r4 ' "$obs/events")/$(grep -c '^post acme/r5 ' "$obs/events")"
  run_tick
  check "5 projects: tick 2 starts at r5 (the cursor survived the process)" "acme-r5:1" "$(started | tr ' ' '\n' | sed -n '5p')"
  all=yes
  for r in r1 r2 r3 r4 r5; do grep -q "^post acme/$r " "$obs/events" || all=no; done
  check "5 projects: every project has a review posted within 2 ticks" "yes" "$all"
  check "5 projects: tick 2 is r5 r1 r2 r3 (strict rotation, not r1 again)" "acme/r1:1 acme/r2:1 acme/r3:1 acme/r4:1 acme/r5:1 acme/r1:2 acme/r2:2 acme/r3:2 " "$(posted)"

  mk_world 3 3 acme/a:1 acme/b:1 acme/c:1
  mkdir -p "$root/wait-starts"
  for p in a b c; do echo 3 >"$root/wait-starts/acme-$p-1"; done
  setmem 1000
  run_tick
  check "memory plenty, parallel=3: three at once" "3" "$(maxoverlap)"
  mk_world 3 3 acme/a:1 acme/b:1 acme/c:1
  for p in a b c; do echo 0.6 >"$root/sleep/acme-$p-1"; done
  setmem 300
  run_tick
  check "memory for two, parallel=3: never more than two at once" "2" "$(maxoverlap)"
  check "memory for two, parallel=3: all three PRs still get reviewed" "3" "$(posted | wc -w | tr -d ' ')"
  mk_world 3 3 acme/a:1
  setmem 50
  run_tick
  check "memory below the floor: the tick exits 0" 0 "$rc"
  check "memory below the floor: no review is started" "0" "$(started | wc -w | tr -d ' ')"
  has "memory below the floor: the log says memory" "$out" "memory"

  lookups() { grep -cE -- '--paginate|actions/runs|commits/|compare/' "$root/gh-calls"; }
  listings() { grep -c '^gh pr list' "$root/gh-calls"; }

  mk_world 1 4 acme/a:7,8
  setmem 10000
  cp "$root/heads/acme-a-7" "$root/reviewed/acme-a-7"
  run_tick
  check "cache: tick 1 exits 0" 0 "$rc"
  check "cache: tick 1 reviews #8 and not #7" "acme/a:8 " "$(posted)"
  l1=$(lookups)
  check "cache: tick 1 does look #7 and #8 up (the fake is counting)" "yes" "$([ "$l1" -ge 2 ] && echo yes || echo no)"
  : >"$root/gh-calls"
  run_tick
  check "cache: tick 2, nothing pushed: exits 0" 0 "$rc"
  check "cache: tick 2, nothing pushed: it listed, and made no per-PR GitHub call" "listed 0" "$([ "$(listings)" -ge 1 ] && echo listed || echo unlisted) $(lookups)"
  check "cache: tick 2 still lists the project (that is how a new head is seen)" "yes" "$([ "$(listings)" -ge 1 ] && echo yes || echo no)"
  check "cache: tick 2 posts nothing" "acme/a:8 " "$(posted)"
  : >"$root/reviewed/acme-a-8"
  : >"$root/gh-calls"
  run_tick
  check "cache: a dismissed review on #8 is reviewed again at the same head" "2" "$(grep -c '^post acme/a 8 ' "$obs/events")"
  check "cache: and #7, untouched, still costs no per-PR call" "0" "$(grep -c 'pulls/7/' "$root/gh-calls")"
  g -C "$root/origins/acme-a" checkout -q pr-7
  printf 'more\n' >"$root/origins/acme-a/more.txt"
  g -C "$root/origins/acme-a" add -A; g -C "$root/origins/acme-a" commit -q -m more
  g -C "$root/origins/acme-a" rev-parse HEAD >"$root/heads/acme-a-7"
  g -C "$root/origins/acme-a" checkout -q main
  : >"$root/gh-calls"
  run_tick
  check "cache: a new head on #7 is looked up again" "yes" "$([ "$(lookups)" -ge 1 ] && echo yes || echo no)"
  check "cache: a new head on #7 is reviewed, against the new sha" "post acme/a 7 $(cat "$root/heads/acme-a-7")" "$(grep '^post acme/a 7 ' "$obs/events")"

  mk_world 2 4 acme/a:1 acme/b:1
  setmem 10000
  mkdir -p "$root/wait-starts"
  echo 2 >"$root/wait-starts/acme-a-1"; echo 2 >"$root/wait-starts/acme-b-1"
  echo 0.2 >"$root/sleep/acme-a-1"; echo 0.2 >"$root/sleep/acme-b-1"
  run_tick
  snap="$obs/status-acme-a-1"
  sj() { jq -r "$1" "$snap" 2>&1; }
  check "status: a snapshot was taken during a review" "present" "$([ -f "$snap" ] && echo present || echo absent)"
  check "status: phase is reviewing while reviews run" "reviewing" "$(sj .phase)"
  check "status: active lists both running reviews" "2" "$(sj '.active | length')"
  check "status: active entries carry repo, pr, sha, model, lines, started_at" "0 0" \
    "$(sj '[.active[] | (["repo","pr","sha","model","lines","started_at"] - keys) | length] | join(" ")')"
  check "status: active has acme/a and acme/b" "acme/a acme/b" "$(sj '[.active[].repo] | sort | join(" ")')"
  check "status: the active sha is the PR head" "$(cat "$root/heads/acme-a-1")" "$(sj '.active[] | select(.repo == "acme/a") | .sha')"
  check "status: the model is filled in" "sonnet" "$(sj '.active[] | select(.repo == "acme/a") | .model')"
  check "status: the top level still names one active review (repo)" "yes" "$(jq -r '.repo as $r | if ([.active[].repo] | index($r)) != null then "yes" else "no" end' "$snap" 2>&1)"
  check "status: the top level still names one active review (pr)" "yes" "$(jq -r '(.pr | tostring) as $p | if ([.active[].pr | tostring] | index($p)) != null then "yes" else "no" end' "$snap" 2>&1)"
  check "status: after the last review the phase is idle" "idle" "$(jq -r .phase "$root/run/status.json" 2>&1)"
  check "status: after the last review active is empty" "0" "$(jq -r '.active | length' "$root/run/status.json" 2>&1)"

  mk_world 1 4 acme/a:1
  setmem 10000
  mv "$root/tokens/gh-acme.token" "$root/tokens/acme-a.token"
  run_tick
  check "per-repo token: a project with only <owner>-<repo>.token is reviewed" "acme/a:1 " "$(posted)"

  exit "$fail"
)

# ==============================================================================
# Section 3: Worktrees (lib/worktree.sh) and tick worktree isolation/pruning
# ==============================================================================
section_3() (
  script="$here/auto-review.sh"
  lib="$here/lib/worktree.sh"
  fixtures=$(mktemp -d)
  fixtures=$(cd "$fixtures" && pwd -P)
  trap 'chmod -R u+rwx "$fixtures" 2>/dev/null; rm -r -f "$fixtures"' EXIT
  fail=0

  exists() { [ -e "$1" ] && echo present || echo absent; }
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  real_git=$(command -v git)
  g() { "$real_git" "$@"; }
  wtlist() { g -C "$1" worktree list --porcelain | grep '^worktree ' | cut -c10- | sort; }

  build_repos() {
    local d="$1"
    mkdir -p "$d/github.com/acme" "$d/clones"
    origin="$d/github.com/acme/widgets.git"
    clone="$d/clones/acme-widgets"
    victim="$d/victim"
    printf 'keep\n' >"$victim"
    g init -q -b main "$origin"
    printf 'readme\n' >"$origin/README.md"
    printf 'main instructions\n' >"$origin/AGENTS.md"
    g -C "$origin" add -A
    g -C "$origin" commit -q -m init
    shamain=$(g -C "$origin" rev-parse HEAD)
    g -C "$origin" checkout -q -b pr-7
    printf 'seven\n' >"$origin/seven.txt"
    printf 'evil\n' >"$origin/CLAUDE.md"
    mkdir -p "$origin/sub" "$origin/.claude"
    printf 'evil\n' >"$origin/sub/AGENTS.md"
    printf '{}\n' >"$origin/.claude/settings.json"
    ln -s "$victim" "$origin/.auto-review-pr.md"
    g -C "$origin" add -A
    g -C "$origin" commit -q -m seven
    sha7=$(g -C "$origin" rev-parse HEAD)
    g -C "$origin" checkout -q main
    g -C "$origin" checkout -q -b pr-8
    printf 'eight\n' >"$origin/eight.txt"
    printf 'evil\n' >"$origin/GEMINI.md"
    g -C "$origin" add -A
    g -C "$origin" commit -q -m eight
    sha8=$(g -C "$origin" rev-parse HEAD)
    g -C "$origin" checkout -q main
    g clone -q "$origin" "$clone"
  }

  lib_run() { bash -c '. "$1"; shift; log() { :; }; "$@"' _ "$lib" "$@" 2>&1; }
  check "lib/worktree.sh exists" "present" "$(exists "$lib")"

  L="$fixtures/lib"
  build_repos "$L"
  export AUTO_REVIEW_WORKTREE_ROOT="$L/wt"
  want7="$L/wt/acme-widgets/pr-7"
  want8="$L/wt/acme-widgets/pr-8"

  check "worktree_dir: <root>/<slug>/pr-<n>" "$want7" "$(lib_run worktree_dir "$clone" 7)"
  check "worktree_root: the env var wins" "$L/wt" "$(lib_run worktree_root)"
  check "worktree_root: default is <clone root>/worktrees" "$L/default-cr/worktrees" \
    "$(env -u AUTO_REVIEW_WORKTREE_ROOT AUTO_REVIEW_CLONE_ROOT="$L/default-cr" bash -c '. "$1"; worktree_root' _ "$lib" 2>&1)"

  got7=$(lib_run worktree_add "$clone" 7); rc7=$?
  got8=$(lib_run worktree_add "$clone" 8); rc8=$?
  check "worktree_add 7: rc 0" 0 "$rc7"
  check "worktree_add 8: rc 0" 0 "$rc8"
  check "worktree_add 7: prints its path" "$want7" "$got7"
  check "worktree_add 8: prints its path" "$want8" "$got8"
  check "the two worktrees have distinct paths" "different" "$([ "$got7" != "$got8" ] && echo different || echo same)"
  check "worktree 7 is on disk" "present" "$(exists "$want7/README.md")"
  check "worktree 8 is on disk" "present" "$(exists "$want8/README.md")"
  check "a fresh worktree is at origin/HEAD" "$shamain" "$(g -C "$want7" rev-parse HEAD 2>&1)"
  check "a fresh worktree is detached (no branch)" "" "$(g -C "$want7" symbolic-ref -q HEAD 2>&1)"
  check "git worktree list: the clone and both worktrees" "$(printf '%s\n%s\n%s\n' "$clone" "$want7" "$want8" | sort)" "$(wtlist "$clone")"

  g -C "$want7" checkout -q --detach origin/pr-7
  g -C "$want8" checkout -q --detach origin/pr-8
  check "worktree 7 holds PR 7's head while 8 exists" "$sha7" "$(g -C "$want7" rev-parse HEAD)"
  check "worktree 8 holds PR 8's head while 7 exists" "$sha8" "$(g -C "$want8" rev-parse HEAD)"
  check "worktree 7 has seven.txt and not eight.txt" "present absent" "$(exists "$want7/seven.txt") $(exists "$want7/eight.txt")"
  check "worktree 8 has eight.txt and not seven.txt" "present absent" "$(exists "$want8/eight.txt") $(exists "$want8/seven.txt")"
  check "the main clone is still on main, untouched" "$shamain|" "$(g -C "$clone" rev-parse HEAD)|$(g -C "$clone" status --porcelain)"

  printf 'junk\n' >"$want7/leftover.txt"
  lib_run worktree_add "$clone" 7 >/dev/null; rc=$?
  check "worktree_add over a leftover of the same PR: rc 0" 0 "$rc"
  check "worktree_add over a leftover: the leftover is gone and the worktree is there" "absent present" "$(exists "$want7/leftover.txt") $(exists "$want7/README.md")"
  check "worktree_add over a leftover: back at origin/HEAD" "$shamain" "$(g -C "$want7" rev-parse HEAD 2>&1)"
  g -C "$want7" checkout -q --detach origin/pr-7

  for w in "$want7" "$want8"; do
    printf 'x\n' >"$w/CLAUDE.md"; printf 'x\n' >"$w/.auto-review-pr.md"
    mkdir -p "$w/sub/.claude" "$w/Docs"; printf 'x\n' >"$w/Docs/agents.md"; printf 'x\n' >"$w/sub/CLAUDE.local.md"
  done
  lib_run worktree_scrub "$want7" >/dev/null; rc=$?
  check "worktree_scrub: rc 0" 0 "$rc"
  check "scrub: root CLAUDE.md removed from its worktree" "present absent" "$(exists "$want7/README.md") $(exists "$want7/CLAUDE.md")"
  check "scrub: .auto-review-pr.md removed from its worktree" "present absent" "$(exists "$want7/README.md") $(exists "$want7/.auto-review-pr.md")"
  check "scrub: nested .claude and CLAUDE.local.md removed" "absent absent" "$(exists "$want7/sub/.claude") $(exists "$want7/sub/CLAUDE.local.md")"
  check "scrub: case-insensitive (Docs/agents.md)" "absent" "$(exists "$want7/Docs/agents.md")"
  check "scrub: the PR's ordinary files stay" "present" "$(exists "$want7/seven.txt")"
  check "scrub: the other worktree is untouched" "present present present" \
    "$(exists "$want8/CLAUDE.md") $(exists "$want8/.auto-review-pr.md") $(exists "$want8/Docs/agents.md")"
  check "scrub: the main clone's AGENTS.md is untouched" "present" "$(exists "$clone/AGENTS.md")"

  lib_run worktree_remove "$clone" "$want7" >/dev/null; rc=$?
  check "worktree_remove: rc 0" 0 "$rc"
  check "worktree_remove: the directory is gone" "absent" "$(exists "$want7")"
  check "worktree_remove: not listed any more" "$(printf '%s\n%s\n' "$clone" "$want8" | sort)" "$(wtlist "$clone")"
  check "worktree_remove: the other worktree stays" "present" "$(exists "$want8/eight.txt")"

  lib_run worktree_add "$clone" 7 >/dev/null
  lib_run worktree_add "$clone" 9 >/dev/null
  rm -r -f "$L/wt/acme-widgets/pr-9"
  mkdir -p "$L/wt/acme-widgets/pr-98" "$L/wt/other-project/pr-1"
  printf 'x\n' >"$L/wt/acme-widgets/pr-98/f"
  check "prune fixture: clone, 7, 8 and the deleted 9 are registered before pruning" "4" "$(wtlist "$clone" | wc -l | tr -d ' ')"
  lib_run worktree_prune "$clone" >/dev/null; rc=$?
  check "worktree_prune: rc 0" 0 "$rc"
  check "worktree_prune: registered worktrees (7, 8) removed" "absent absent" "$(exists "$want7") $(exists "$want8")"
  check "worktree_prune: unregistered leftover (pr-98) removed" "absent" "$(exists "$L/wt/acme-widgets/pr-98")"
  check "worktree_prune: only the main clone is listed" "$clone" "$(wtlist "$clone")"
  check "worktree_prune: no dangling registration is left" "0" "$(ls "$clone/.git/worktrees" 2>/dev/null | wc -l | tr -d ' ')"
  check "worktree_prune: another project's directory is untouched" "present" "$(exists "$L/wt/other-project/pr-1")"
  lib_run worktree_prune "$clone" >/dev/null; rc=$?
  check "worktree_prune with nothing to do: rc 0" 0 "$rc"
  unset AUTO_REVIEW_WORKTREE_ROOT

  n=0
  tick() {
    n=$((n + 1))
    root="$fixtures/t$n"
    build_repos "$root"
    home="$root/userhome"; xdg="$root/run"; bin="$root/bin"; obs="$root/obs"
    wtroot="$root/worktrees"; calls="$root/gh-calls"; gitlog="$root/git-log"
    mkdir -p "$home/.config/auto-review" "$xdg/auto-review" "$bin" "$obs"
    mkdir -p "$home/.local"; ln -s "$bin" "$home/.local/bin"
    printf 'ghp_fakefake123\n' >"$xdg/auto-review/acme-widgets.token"
    printf 'ghp_fakefake123\n' >"$home/.config/auto-review/acme-widgets.token"
    : >"$calls"; : >"$gitlog"
    usercheckout="$root/user-checkout"
    g clone -q "$origin" "$usercheckout"

    if [ "${1:-}" = stale ]; then
      g -C "$clone" worktree add -q --detach "$wtroot/acme-widgets/pr-91" origin/main
      g -C "$clone" worktree add -q --detach "$wtroot/acme-widgets/pr-92" origin/main
      rm -r -f "$wtroot/acme-widgets/pr-92"
      mkdir -p "$wtroot/acme-widgets/pr-93"; printf 'x\n' >"$wtroot/acme-widgets/pr-93/f"
    fi

    cat >"$bin/git" <<FAKE
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    fetch) echo "fetch \$PWD" >>"$gitlog"; break ;;
    worktree) echo "worktree \$*" >>"$gitlog"; break ;;
  esac
done
exec "$real_git" "\$@"
FAKE
    cat >"$bin/gh" <<'FAKE'
#!/bin/sh
echo "gh $*" >>"$FAKE_CALLS"
case "$*" in
  "api user -q .login") echo tester ;;
  "pr list "*)
    printf '7\t%s\tmain\tfalse\tfalse\tauthor\tpr-7\t\tChange seven\n' "$FAKE_SHA7"
    printf '8\t%s\tmain\tfalse\tfalse\tauthor\tpr-8\t\tChange eight\n' "$FAKE_SHA8"
    ;;
  "pr checkout "*)
    echo "checkout $3 in $PWD" >>"$FAKE_CALLS"
    case " $* " in
      *" --detach "*) git checkout -q --detach "origin/pr-$3" ;;
      *) git checkout -q -B main "origin/pr-$3" ;;
    esac
    ;;
  "pr view "*"baseRefName -q .baseRefName") echo main ;;
  "pr view "*) echo stub ;;
  "repo clone "*) git clone -q "$FAKE_ORIGIN" "$4" ;;
  "api repos/"*"/reviews --input -") cat >/dev/null; echo "posted $2" >>"$FAKE_CALLS" ;;
  *) exit 0 ;;
esac
FAKE
    cat >"$bin/bwrap" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
FAKE
    cat >"$bin/claude" <<'FAKE'
#!/bin/sh
head=$(git rev-parse HEAD 2>/dev/null || echo none)
{
  echo "cwd=$(pwd -P)"
  ls -A | while read -r f; do echo "has:$f"; done
  [ -e sub/AGENTS.md ] && echo "has:sub/AGENTS.md"
  [ -e .claude/settings.json ] && echo "has:.claude/settings.json"
  if [ -f .auto-review-diff.patch ]; then
    grep -q 'seven.txt' .auto-review-diff.patch && echo "diff-has:seven"
    grep -q 'eight.txt' .auto-review-diff.patch && echo "diff-has:eight"
  fi
  [ -L .auto-review-pr.md ] && echo "pr-md-is-symlink"
} >"$(cd -P "$(dirname "$0")/.." && pwd)/obs/$head"
printf '{"type":"result","subtype":"success","is_error":false,"usage":{"output_tokens":20},"result":"**No findings.** fine"}\n'
FAKE
    chmod 755 "$bin/git" "$bin/gh" "$bin/bwrap" "$bin/claude"

    out=$(env -u AUTO_REVIEW_TOKEN_DIR -u GH_TOKEN -u AUTO_REVIEW_WORKTREE_ROOT \
      HOME="$home" XDG_RUNTIME_DIR="$xdg" AUTO_REVIEW_CLONE_ROOT="$root/clones" \
      AUTO_REVIEW_WORKTREE_ROOT="$wtroot" AUTO_REVIEW_TIMEOUT=60 AUTO_REVIEW_INSIDE_CONTAINER=1 \
      PATH="$bin:$PATH" FAKE_CALLS="$calls" FAKE_OBS="$obs" FAKE_ORIGIN="$origin" \
      FAKE_SHA7="$sha7" FAKE_SHA8="$sha8" \
      "$script" tick "$usercheckout" --all 2>&1)
    rc=$?
  }

  obscwd() { if [ -f "$obs/$1" ]; then grep '^cwd=' "$obs/$1" | head -n 1; else echo "(no observation)"; fi; }
  obshas() { if [ ! -f "$obs/$1" ]; then echo none; elif grep -qxF "$2" "$obs/$1"; then echo yes; else echo no; fi; }

  tick plain
  check "tick: exits 0" 0 "$rc"
  [ "$rc" = 0 ] || printf '%s\n' "$out" | tail -25 | sed 's/^/  tick out: /'
  has "tick: both PRs were selected" "$out" "#8 needs a review"
  check "tick: the reviewer ran for PR 7 and PR 8" "2" "$(ls "$obs" | wc -l | tr -d ' ')"

  check "reviewer for PR 7 ran in PR 7's worktree" "cwd=$wtroot/acme-widgets/pr-7" "$(obscwd "$sha7")"
  check "reviewer for PR 8 ran in PR 8's worktree" "cwd=$wtroot/acme-widgets/pr-8" "$(obscwd "$sha8")"
  check "the .auto-review-* files are in PR 7's worktree" "yes yes yes" \
    "$(obshas "$sha7" 'has:.auto-review-history.md') $(obshas "$sha7" 'has:.auto-review-diff.patch') $(obshas "$sha7" 'has:.auto-review-pr.md')"
  check "the .auto-review-* files are in PR 8's worktree" "yes yes yes" \
    "$(obshas "$sha8" 'has:.auto-review-history.md') $(obshas "$sha8" 'has:.auto-review-diff.patch') $(obshas "$sha8" 'has:.auto-review-pr.md')"
  check "PR 7's patch is built in its own worktree (seven, not eight)" "yes no" "$(obshas "$sha7" 'diff-has:seven') $(obshas "$sha7" 'diff-has:eight')"
  check "PR 8's patch is built in its own worktree (eight, not seven)" "yes no" "$(obshas "$sha8" 'diff-has:eight') $(obshas "$sha8" 'diff-has:seven')"
  check "PR 7's planted .auto-review-pr.md link was replaced by a real file" "no" "$(obshas "$sha7" 'pr-md-is-symlink')"
  check "the link's target was not written through" "keep" "$(cat "$victim")"

  check "scrub in PR 7's worktree: CLAUDE.md, sub/AGENTS.md, .claude, AGENTS.md gone" "no no no no" \
    "$(obshas "$sha7" 'has:CLAUDE.md') $(obshas "$sha7" 'has:sub/AGENTS.md') $(obshas "$sha7" 'has:.claude/settings.json') $(obshas "$sha7" 'has:AGENTS.md')"
  check "scrub in PR 8's worktree: GEMINI.md and AGENTS.md gone" "no no" \
    "$(obshas "$sha8" 'has:GEMINI.md') $(obshas "$sha8" 'has:AGENTS.md')"
  check "scrub in PR 7's worktree leaves the PR's own file" "yes" "$(obshas "$sha7" 'has:seven.txt')"

  check "main clone: still at the commit it had" "$shamain" "$(g -C "$clone" rev-parse HEAD 2>&1)"
  check "main clone: working tree clean" "" "$(g -C "$clone" status --porcelain --ignored 2>&1)"
  check "main clone: no PR file in it" "absent absent" "$(exists "$clone/seven.txt") $(exists "$clone/eight.txt")"
  check "main clone: its own AGENTS.md was not scrubbed" "present" "$(exists "$clone/AGENTS.md")"
  check "main clone: no .auto-review-* files" "0" "$(ls -A "$clone" | grep -c '^\.auto-review-')"

  check "worktrees are removed after the reviews" "absent absent" "$(exists "$wtroot/acme-widgets/pr-7") $(exists "$wtroot/acme-widgets/pr-8")"
  check "git worktree list shows only the main clone after the tick" "$clone" "$(wtlist "$clone")"
  check "both reviews were posted" "2" "$(grep -c '^posted' "$calls")"

  check "git fetch ran once for the project's two PRs" "1" "$(grep -c '^fetch ' "$gitlog")"
  check "a worktree was added for each of the two PRs" "2" "$(grep -c '^worktree .*add' "$gitlog")"
  first_fetch=$(grep -n '^fetch ' "$gitlog" | head -n 1 | cut -d: -f1)
  first_add=$(grep -n '^worktree .*add' "$gitlog" | head -n 1 | cut -d: -f1)
  check "the fetch comes before the first worktree is added" "yes" \
    "$([ -n "$first_fetch" ] && [ -n "$first_add" ] && [ "$first_fetch" -lt "$first_add" ] && echo yes || echo no)"
  check "the fetch ran in the main clone, not in a worktree" "fetch $clone" "$(grep '^fetch ' "$gitlog" | head -n 1)"

  tick stale
  check "stale: tick exits 0" 0 "$rc"
  check "stale: the registered leftover (pr-91) is gone" "absent" "$(exists "$wtroot/acme-widgets/pr-91")"
  check "stale: the deleted-directory registration (pr-92) is gone" "absent" "$(exists "$clone/.git/worktrees/pr-92")"
  check "stale: the unregistered leftover (pr-93) is gone" "absent" "$(exists "$wtroot/acme-widgets/pr-93")"
  check "stale: only the main clone is listed afterwards" "$clone" "$(wtlist "$clone")"
  has "stale: the log says a stale worktree was pruned" "$out" "pruned stale worktree $wtroot/acme-widgets/pr-91"
  first_wt=$(grep -n '^worktree ' "$gitlog" | head -n 1 | cut -d: -f1)
  first_fetch=$(grep -n '^fetch ' "$gitlog" | head -n 1 | cut -d: -f1)
  check "stale: the prune happens before the fetch" "yes" \
    "$([ -n "$first_wt" ] && [ -n "$first_fetch" ] && [ "$first_wt" -lt "$first_fetch" ] && echo yes || echo no)"
  check "stale: the reviews still ran" "2" "$(ls "$obs" | wc -l | tr -d ' ')"

  exit "$fail"
)

# ==============================================================================
# Section 4: Review record detection (guard reviews, dismissals, humans)
# ==============================================================================
section_4() (
  script="$here/auto-review.sh"
  fixtures=$(mktemp -d)
  trap 'rm -r -f "$fixtures"' EXIT
  fail=0
  HEAD=abc1234abc1234abc1234abc1234abc1234abc12
  OLD=0000000000000000000000000001
  ME=tester

  SIG='_Automated review. Not an approval._'
  MARK="<!-- auto-review:$HEAD -->"

  n=0
  tick_with_reviews() {
    reviews=$1
    n=$((n + 1))
    root="$fixtures/t$n"
    home="$root/userhome"; xdg="$root/run"; repo="$root/repo"
    origin_repo="$root/github.com/acme/widgets.git"
    mkdir -p "$home/.local/bin" "$xdg/auto-review" "$root/clones" "$home/.config/auto-review"
    git init -q -b main "$origin_repo"
    git -C "$origin_repo" config commit.gpgsign false
    git -C "$origin_repo" config user.name t
    git -C "$origin_repo" config user.email t@t
    printf 'keep\n' >"$origin_repo/README.md"
    git -C "$origin_repo" add README.md
    git -C "$origin_repo" commit -q -m init
    git clone -q "$origin_repo" "$repo"
    printf 'ghp_fakefake123\n' >"$xdg/auto-review/acme-widgets.token"
    printf 'ghp_fakefake123\n' >"$home/.config/auto-review/acme-widgets.token"
    printf '%s\n' "$reviews" >"$root/reviews.json"

    cat >"$home/.local/bin/gh" <<'FAKE'
#!/bin/sh
case "$*" in
  "api user -q .login") echo "$FAKE_ME" ;;
  "pr list "*)
    printf '7\t%s\tmain\tfalse\tfalse\tauthor\tfeature\t\tSome change\n' "$FAKE_HEAD"
    ;;
  "api --paginate repos/acme/widgets/pulls/7/reviews -q "*)
    filter=$5
    jq -r "$filter" "$FAKE_REVIEWS"
    ;;
  "api repos/acme/widgets/actions/runs?"*) echo 0 ;;
  "api repos/acme/widgets/commits/"*"/status "*) echo none ;;
  *) exit 0 ;;
esac
FAKE
    cat >"$home/.local/bin/bwrap" <<'FAKE'
#!/bin/sh
exit 0
FAKE
    cat >"$home/.local/bin/claude" <<'FAKE'
#!/bin/sh
echo ran >>"$FAKE_RAN"
exit 0
FAKE
    chmod 755 "$home/.local/bin/gh" "$home/.local/bin/bwrap" "$home/.local/bin/claude"

    out=$(env -u AUTO_REVIEW_TOKEN_DIR -u GH_TOKEN \
      HOME="$home" XDG_RUNTIME_DIR="$xdg" AUTO_REVIEW_CLONE_ROOT="$root/clones" \
      PATH="$home/.local/bin:$PATH" FAKE_ME="$ME" FAKE_HEAD="$HEAD" \
      FAKE_REVIEWS="$root/reviews.json" FAKE_RAN="$root/ran" \
      "$script" tick "$repo" --all --dry-run 2>&1)
    rc=$?
  }

  review() {
    jq -n --arg l "$1" --arg s "$2" --arg b "$3" --arg c "$4" \
      '{user:{login:$l}, state:$s, body:$b, commit_id:$c}'
  }
  arr() { jq -s '.'; }

  needs() {
    has "$1: tick exits 0" "rc=$rc" "rc=0"
    has "$1: needs a review at the head" "$out" "#7 needs a review at ${HEAD:0:7}"
    lacks "$1: not read as reviewed" "$out" "#7 is reviewed at"
  }
  done_() {
    has "$1: tick exits 0" "rc=$rc" "rc=0"
    has "$1: reads as reviewed at the head" "$out" "#7 is reviewed at ${HEAD:0:7}"
    lacks "$1: no review requested" "$out" "#7 needs a review"
  }

  tick_with_reviews '[]'
  needs "fixture: no reviews"

  tick_with_reviews "$(review 'github-actions[bot]' CHANGES_REQUESTED "guard $MARK $SIG" $HEAD | arr)"
  needs "a. guard CHANGES_REQUESTED review"
  tick_with_reviews "$({ review 'github-actions[bot]' DISMISSED "guard $MARK $SIG" $HEAD
    review owner DISMISSED "dismissed the guard review" $HEAD; } | arr)"
  needs "a. guard review then its dismissal by the owner"
  tick_with_reviews "$({ review 'github-actions[bot]' DISMISSED "guard $MARK $SIG" $HEAD
    review "$ME" DISMISSED "dismissed the guard review" $HEAD; } | arr)"
  needs "a. guard review then a dismissal under this tool's own login"

  tick_with_reviews "$(review "$ME" DISMISSED "findings $MARK $SIG" $HEAD | arr)"
  needs "b. own review at the head, DISMISSED (marker and signature)"
  tick_with_reviews "$(review "$ME" DISMISSED "findings $SIG" $HEAD | arr)"
  needs "b. own review at the head, DISMISSED (signature only)"
  tick_with_reviews "$(review "$ME" DISMISSED "findings $MARK" $HEAD | arr)"
  needs "b. own review at the head, DISMISSED (marker only)"

  tick_with_reviews "$(review "$ME" COMMENTED "findings $MARK $SIG" $HEAD | arr)"
  done_ "c. own review at the head, COMMENTED"
  tick_with_reviews "$({ review "$ME" COMMENTED "findings $MARK $SIG" $OLD
    review "$ME" COMMENTED "findings $MARK $SIG" $HEAD; } | arr)"
  done_ "c. own reviews at an older and at the head sha, COMMENTED"
  tick_with_reviews "$({ review "$ME" DISMISSED "findings $MARK $SIG" $OLD
    review "$ME" COMMENTED "findings $MARK $SIG" $HEAD; } | arr)"
  done_ "c. older own review dismissed, live own review at the head"

  for state in APPROVED COMMENTED DISMISSED CHANGES_REQUESTED; do
    tick_with_reviews "$(review owner "$state" "by hand $MARK $SIG" $HEAD | arr)"
    needs "d. person's $state review with the marker text"
    tick_with_reviews "$(review owner "$state" "looks fine" $HEAD | arr)"
    needs "d. person's $state review, plain body"
  done
  tick_with_reviews "$({ review owner APPROVED "by hand $MARK $SIG" $HEAD
    review owner DISMISSED "by hand $MARK $SIG" $HEAD; } | arr)"
  needs "d. person's approval then dismissal"

  exit "$fail"
)

# ==============================================================================
# Section 5: Structured machine mark functions (lib/machine-mark.sh)
# ==============================================================================
section_5() (
  # shellcheck disable=SC1091
  . "$here/lib/machine-mark.sh"
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

  mark1="$(emit_machine_mark "abc1234" "clean" 0 1730889600)"
  check "emit_machine_mark: envelope format" \
    '<!-- auto-review: {"v":1,"tool":"auto-review","sha":"abc1234","verdict":"clean","findings":0,"ts":1730889600} -->' \
    "$mark1"

  parsed_json1="$(parse_machine_mark "$mark1")"
  check_status "emit_machine_mark: produces parseable machine mark" 0 test -n "$parsed_json1"

  tool_field="$(printf '%s' "$parsed_json1" | jq -r '.tool')"
  check "emit_machine_mark: JSON contains tool auto-review" "auto-review" "$tool_field"

  v_field="$(printf '%s' "$parsed_json1" | jq -r '.v')"
  check "emit_machine_mark: JSON contains version 1" "1" "$v_field"

  mark_default_ts="$(emit_machine_mark "def5678" "findings" 3)"
  check_status "emit_machine_mark: default timestamp is valid JSON" 0 parse_machine_mark "$mark_default_ts"

  review_with_mark="$(printf '%s\n\n%s\n' "**No findings.**" "$mark1")"
  check_status "is_automated_review: returns 0 for review with machine mark" 0 is_automated_review "$review_with_mark"
  check_status "is_automated_review: returns 0 for standalone machine mark" 0 is_automated_review "$mark1"

  review_with_mark_findings="$(format_review_with_mark "**2 findings.**" "sha999" "findings" 2 1730889600)"
  check_status "is_automated_review: returns 0 for findings review with mark" 0 is_automated_review "$review_with_mark_findings"

  legacy_review="$(printf '%s\n\n---\n_Automated review. Not an approval._\n' "**No findings.**")"
  check_status "is_automated_review: returns 0 for legacy review with footer" 0 is_automated_review "$legacy_review"
  check_status "is_automated_review: returns 0 for exact legacy string" 0 is_automated_review "Automated review. Not an approval."

  check_status "is_automated_review: returns 1 for human review LGTM! Approved." 1 is_automated_review "LGTM! Approved."
  check_status "is_automated_review: returns 1 for human comment with details" 1 is_automated_review "Looks good to me, approved for merge."
  check_status "is_automated_review: returns 1 for CI bot comment" 1 is_automated_review "ci/circleci: build passed on commit abc"
  check_status "is_automated_review: returns 1 for random user comment" 1 is_automated_review "Can you explain why we use awk here?"
  check_status "is_automated_review: returns 1 for empty text" 1 is_automated_review ""
  check_status "is_automated_review: returns 1 for broken machine mark JSON" 1 is_automated_review "<!-- auto-review: {broken json} -->"

  sample_json='{"v":1,"tool":"auto-review","sha":"fedcba987654","verdict":"clean","findings":0,"ts":1730889600}'
  check "extract_mark_field: extracts sha" "fedcba987654" "$(extract_mark_field "$sample_json" "sha")"
  check "extract_mark_field: extracts verdict" "clean" "$(extract_mark_field "$sample_json" "verdict")"
  check "extract_mark_field: extracts findings (numeric 0)" "0" "$(extract_mark_field "$sample_json" "findings")"

  sample_findings_json='{"v":1,"tool":"auto-review","sha":"111222333","verdict":"findings","findings":5,"ts":1730889600}'
  check "extract_mark_field: extracts findings (numeric 5)" "5" "$(extract_mark_field "$sample_findings_json" "findings")"
  check "extract_mark_field: extracts sha from full review text" "abc1234" "$(extract_mark_field "$review_with_mark" "sha")"
  check_status "extract_mark_field: returns 1 for nonexistent field" 1 extract_mark_field "$sample_json" "nonexistent"

  orig_body="$(printf '%s\n\n---\n_Automated review. Not an approval._' "**No findings.**")"
  formatted="$(format_review_with_mark "$orig_body" "sha456" "clean" 0 1730889600)"
  case "$formatted" in
    "$orig_body"*) check "format_review_with_mark: body preserved at start" "yes" "yes" ;;
    *) check "format_review_with_mark: body preserved at start" "yes" "no" ;;
  esac
  case "$formatted" in
    *'<!-- auto-review: {"v":1,"tool":"auto-review","sha":"sha456","verdict":"clean","findings":0,"ts":1730889600} -->')
      check "format_review_with_mark: embeds mark at end" "yes" "yes" ;;
    *) check "format_review_with_mark: embeds mark at end" "yes" "no" ;;
  esac
  check_status "format_review_with_mark: result is automated review" 0 is_automated_review "$formatted"
  check "format_review_with_mark: extracted sha matches" "sha456" "$(extract_mark_field "$formatted" "sha")"
  check "format_review_with_mark: extracted verdict matches" "clean" "$(extract_mark_field "$formatted" "verdict")"
  check "format_review_with_mark: extracted findings matches" "0" "$(extract_mark_field "$formatted" "findings")"

  empty_body_formatted="$(format_review_with_mark "" "sha000" "clean" 0 1730889600)"
  check "format_review_with_mark: works with empty body" \
    '<!-- auto-review: {"v":1,"tool":"auto-review","sha":"sha000","verdict":"clean","findings":0,"ts":1730889600} -->' \
    "$empty_body_formatted"

  footer_with_sha="$(format_review_footer "abcdef123456")"
  check "format_review_footer: includes short sha" \
    "$(printf '\n\n---\n_Automated review. Not an approval._ • Commit: abcdef1\n')" \
    "$footer_with_sha"
  footer_without_sha="$(format_review_footer "")"
  check "format_review_footer: without sha has legacy form" \
    "$(printf '\n\n---\n_Automated review. Not an approval._\n')" \
    "$footer_without_sha"
  review_with_sha_footer="$(printf '**No findings.**%s' "$footer_with_sha")"
  check_status "is_automated_review: recognizes review with commit in footer" 0 is_automated_review "$review_with_sha_footer"
  check "extract_mark_field: fallback to footer sha when mark absent" "abcdef1" "$(extract_mark_field "$review_with_sha_footer" "sha")"

  # post_review stamps verdict="malformed" when review body lacks a recognized verdict header
  (
    fx_post=$(mktemp -d)
    trap 'rm -rf "$fx_post"' EXIT
    mkdir -p "$fx_post/bin" "$fx_post/tokens" "$fx_post/lock"
    chmod 700 "$fx_post/tokens" "$fx_post/lock"
    export AUTO_REVIEW_TOKEN_DIR="$fx_post/tokens"
    export AUTO_REVIEW_LOCK_DIR="$fx_post/lock"
    cat >"$fx_post/bin/gh" <<FAKE
#!/bin/sh
cat >"$fx_post/payload.json"
FAKE
    chmod 755 "$fx_post/bin/gh"
    # shellcheck disable=SC1091
    . "$here/auto-review.sh"
    export PATH="$fx_post/bin:$PATH"
    set +e

    check_post_verdict() {
      local label="$1" body_text="$2" want_verdict="$3"
      rm -f "$fx_post/payload.json"
      printf '%s\n' "$body_text" >"$fx_post/body.md"
      post_review acme/widgets 7 "$fx_post/body.md" "0123456789abcdef0123456789abcdef01234567" >/dev/null 2>&1
      local posted_body got_verdict
      posted_body="$(jq -r '.body // empty' "$fx_post/payload.json" 2>/dev/null)"
      got_verdict="$(extract_mark_field "$posted_body" "verdict" 2>/dev/null)"
      check "$label" "$want_verdict" "$got_verdict"
    }

    check_post_verdict "post_review: preamble-only body stamps verdict=malformed" \
      "I'll start by reading the diff and the PR description." "malformed"
    check_post_verdict "post_review: unrecognized header stamps verdict=malformed" \
      "Hello! Here is my review of your changes." "malformed"
    check_post_verdict "post_review: **No findings.** stamps verdict=clean" \
      "**No findings.**" "clean"
    check_post_verdict "post_review: **Skipped — generated files only.** stamps verdict=clean" \
      "**Skipped — generated files only.**" "clean"
    check_post_verdict "post_review: **Skipped — low-risk paths only.** stamps verdict=skipped_low_risk" \
      "**Skipped — low-risk paths only.**" "skipped_low_risk"
    check_post_verdict "post_review: **Not reviewed.** stamps verdict=refused_size" \
      "**Not reviewed.**" "refused_size"
    check_post_verdict "post_review: **2 findings.** stamps verdict=findings" \
      "**2 findings.**" "findings"
    exit "$fail"
  ) || fail=1

  exit "$fail"
)

# ==============================================================================
# Section 6: Unified locked status.json RMW, tick_errors, recent_results,
#            dynamic scheduling metadata, and selective post_review retry
# =============================================================================
section_6() (
  script="$here/auto-review.sh"
  active_lib="$here/lib/active-status.sh"
  entry="$here/entrypoint.sh"
  fixtures=$(mktemp -d)
  fixtures=$(cd "$fixtures" && pwd -P)
  trap 'chmod -R u+rwx "$fixtures" 2>/dev/null; rm -rf "$fixtures"' EXIT
  fail=0

  # --- Part 1: Unified locked atomic status.json RMW updater ---
  check "entrypoint.sh uses no fixed STATUS_FILE.tmp path" 0 \
    "$(grep -c 'STATUS_FILE\.tmp' "$entry" 2>/dev/null || true)"
  check "entrypoint.sh has no bare idle printf overwrite" 0 \
    "$(grep -cE 'printf .*\"phase\":\"idle\"' "$entry" 2>/dev/null || true)"
  check "auto-review.sh uses no fixed status_file.tmp path" 0 \
    "$(grep -c '\$status_file\.tmp' "$script" 2>/dev/null || true)"

  (
    export AUTO_REVIEW_STATUS_FILE="$fixtures/rmw-status.json"
    export AUTO_REVIEW_TOKEN_DIR="$fixtures/empty-tokens"
    mkdir -p "$AUTO_REVIEW_TOKEN_DIR"
    # shellcheck disable=SC1091
    . "$script"
    # shellcheck disable=SC1091
    . "$active_lib"
    set +e

    # Seed status.json with additive sibling keys
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat >"$AUTO_REVIEW_STATUS_FILE" <<JSON
{"phase":"idle","active":[],"last_repo":"acme/prev","last_pr":9,"result":"posted","finished_at":"$now_iso","last_tick_at":"$now_iso","interval_s":180,"queued":[{"repo":"acme/q","pr":2}],"recent_results":{"acme/prev#9":{"sha":"aaa1111","result":"posted","error_kind":"","http_status":null,"reason":"","retryable":false,"attempts":1,"at":"$now_iso"}},"tick_errors":{"_global":{"error_kind":"memory_floor","reason":"low mem","at":"$now_iso"}}}
JSON

    MACHINE_ACTIVE=1
    status_review_begin "acme/a" 1 "deadbeef1111" 42 "sonnet"
    check "RMW add: phase is reviewing" "reviewing" "$(jq -r '.phase' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW add: preserves recent_results" "posted" "$(jq -r '.recent_results["acme/prev#9"].result // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW add: preserves tick_errors" "memory_floor" "$(jq -r '.tick_errors._global.error_kind // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW add: preserves interval_s" "180" "$(jq -r '.interval_s // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW add: preserves queued" "1" "$(jq -r '.queued | length' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_review_end "acme/a" 1 "posted"
    check "RMW remove (last): phase is idle" "idle" "$(jq -r '.phase' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW remove (last): preserves recent_results" "posted" "$(jq -r '.recent_results["acme/prev#9"].result // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW remove (last): preserves tick_errors" "memory_floor" "$(jq -r '.tick_errors._global.error_kind // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW remove (last): preserves interval_s" "180" "$(jq -r '.interval_s // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_daemon_started
    check "RMW daemon_started: preserves recent_results" "posted" "$(jq -r '.recent_results["acme/prev#9"].result // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW daemon_started: preserves tick_errors._global" "memory_floor" "$(jq -r '.tick_errors._global.error_kind // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_daemon_idle_refresh
    check "RMW daemon_idle_refresh: preserves tick_errors._global" "memory_floor" "$(jq -r '.tick_errors._global.error_kind // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW daemon_idle_refresh: preserves recent_results" "posted" "$(jq -r '.recent_results["acme/prev#9"].result // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_active_reset
    check "RMW reset: preserves recent_results" "posted" "$(jq -r '.recent_results["acme/prev#9"].result // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW reset: preserves tick_errors" "memory_floor" "$(jq -r '.tick_errors._global.error_kind // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "RMW reset: preserves last_repo" "acme/a" "$(jq -r '.last_repo // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    # Parallel active[] add under lock preserves all 4 entries and sibling keys
    for i in 1 2 3 4; do
      status_review_begin "acme/p$i" "$i" "sha$i" 10 "sonnet" &
    done
    wait
    check "parallel RMW add: valid JSON" "0" "$(jq -e . "$AUTO_REVIEW_STATUS_FILE" >/dev/null 2>&1; echo $?)"
    check "parallel RMW add: all 4 entries present" "4" "$(jq -r '.active | length' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"
    check "parallel RMW add: preserves recent_results" "posted" "$(jq -r '.recent_results["acme/prev#9"].result // empty' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    exit "$fail"
  ) || fail=1

  # --- Helper world for tick, recent_results, tick_errors, and post_review ---
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  real_git=$(command -v git)

  n=0
  mk_tick_world() {
    n=$((n + 1))
    root="$fixtures/tw$n"
    bin="$root/bin"; obs="$root/obs"
    mkdir -p "$bin" "$obs" "$root/run" "$root/state" "$root/locks" "$root/tokens" \
      "$root/prs" "$root/heads" "$root/reviewed" "$root/clones/clones" "$root/userhome/.local"
    ln -s "$bin" "$root/userhome/.local/bin"
    : >"$obs/events"; : >"$root/gh-calls"
    reg="$root/projects.json"
    jq -n '{version: 1, harness: "claude-code", model: "sonnet", parallel: "1", slots: "4", projects: {}}' >"$reg"
    local spec repo prs slug owner o c pr
    for spec in "$@"; do
      repo="${spec%%:*}"; prs="${spec#*:}"; slug=$(printf '%s' "$repo" | tr '/' '-'); owner="${repo%%/*}"
      printf 'ghp_fake%s00000000000000000000\n' "$owner" >"$root/tokens/gh-$owner.token"
      o="$root/origins/$slug"; c="$root/clones/$slug"
      mkdir -p "$root/origins"
      "$real_git" init -q -b main "$o"
      printf 'readme\n' >"$o/README.md"; "$real_git" -C "$o" add -A; "$real_git" -C "$o" commit -q -m init
      : >"$root/prs/$slug"
      for pr in $(printf '%s' "$prs" | tr ',' ' '); do
        [ -n "$pr" ] || continue
        "$real_git" -C "$o" checkout -q -b "pr-$pr" main
        if [ "${FAKE_EMPTY_DIFF:-0}" != "1" ]; then
          printf 'change %s\n' "$pr" >"$o/f$pr.txt"; "$real_git" -C "$o" add -A; "$real_git" -C "$o" commit -q -m "change $pr"
        else
          "$real_git" -C "$o" commit -q --allow-empty -m "empty $pr"
        fi
        "$real_git" -C "$o" rev-parse HEAD >"$root/heads/$slug-$pr"
        echo "$pr" >>"$root/prs/$slug"
      done
      "$real_git" -C "$o" checkout -q main
      "$real_git" clone -q "$o" "$c"
      printf '%s\n' "$c" >"$root/clones/clones/$slug"
      jq --arg r "$repo" '.projects[$r] = {adopted_at: "2026-11-01T00:00:00Z", all: true, self_review: false}' "$reg" >"$reg.t" && mv "$reg.t" "$reg"
    done

    cat >"$bin/gh" <<'FAKE'
#!/bin/sh
echo "gh $*" >>"$FAKE_ROOT/gh-calls"
repo=""; prev=""
for a in "$@"; do [ "$prev" = "--repo" ] && repo="$a"; prev="$a"; done
case "$*" in
  "api user -q .login")
    [ -f "$FAKE_ROOT/fail-auth" ] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    echo tester; exit 0 ;;
  "pr list "*)
    [ -f "$FAKE_ROOT/run/status.json" ] && cp "$FAKE_ROOT/run/status.json" "$FAKE_ROOT/obs/status-scanning"
    [ -f "$FAKE_ROOT/fail-list" ] && { echo "Could not resolve host: api.github.com" >&2; exit 1; }
    slug=$(printf '%s' "$repo" | tr '/' '-')
    while read -r p; do
      [ -n "$p" ] || continue
      printf '%s\t%s\tmain\tfalse\tfalse\tauthor\tpr-%s\t\t0\tChange %s\n' "$p" "$(cat "$FAKE_ROOT/heads/$slug-$p")" "$p" "$p"
    done <"$FAKE_ROOT/prs/$slug"
    exit 0 ;;
  "pr checkout "*)
    [ -f "$FAKE_ROOT/fail-checkout" ] && { echo "checkout failed" >&2; exit 1; }
    git checkout -q --detach "origin/pr-$3"; exit 0 ;;
  "pr view "*"baseRefName -q .baseRefName")
    [ -f "$FAKE_ROOT/fail-material" ] && { echo "pr view failed" >&2; exit 1; }
    echo main; exit 0 ;;
  "pr view "*".headRefOid"*)
    echo "${FAKE_CURRENT_HEAD:-0000000000000000000000000000}"; exit 0 ;;
  "pr view "*)
    [ -f "$FAKE_ROOT/fail-material" ] && { echo "pr view failed" >&2; exit 1; }
    echo stub; exit 0 ;;
  "repo clone "*)
    [ -f "$FAKE_ROOT/fail-clone" ] && { echo "clone failed" >&2; exit 1; }
    slug=$(printf '%s' "$3" | tr '/' '-')
    git clone -q "$FAKE_ROOT/origins/$slug" "$4"; exit 0 ;;
  "api repos/"*"/pulls/"*"/reviews --input -"*)
    cat >/dev/null
    echo "post_attempt" >>"$FAKE_ROOT/obs/post-attempts"
    mode="${FAKE_POST_MODE:-200}"
    if [ "$mode" = "502_then_200" ]; then
      cnt=$(wc -l <"$FAKE_ROOT/obs/post-attempts" | tr -d ' ')
      if [ "$cnt" -eq 1 ]; then
        echo "gh: Bad Gateway (HTTP 502)" >&2
        exit 1
      fi
      mode="200"
    fi
    case "$mode" in
      200) exit 0 ;;
      502) echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1 ;;
      429) echo "gh: You have exceeded a secondary rate limit (HTTP 429)" >&2; exit 1 ;;
      transport) echo "Post \"https://api.github.com/...\": dial tcp: lookup api.github.com: Try again" >&2; exit 1 ;;
      401) echo "gh: Bad credentials (HTTP 401)" >&2; exit 1 ;;
      403) echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
      422) echo "gh: Unprocessable Entity (HTTP 422)" >&2; exit 1 ;;
    esac
    exit 1 ;;
  "api --paginate repos/"*"/pulls/"*"/reviews "*)
    [ -f "$FAKE_ROOT/fail-history" ] && { echo "history failed" >&2; exit 1; }
    exit 0 ;;
  "api repos/"*"/pulls/"*)
    [ -n "${FAKE_CURRENT_HEAD:-}" ] && printf '{"head":{"sha":"%s"}}\n' "$FAKE_CURRENT_HEAD"
    exit 0 ;;
  "api repos/"*"/actions/runs"*) echo 0; exit 0 ;;
  "api repos/"*"/commits/"*"/status"*) echo none; exit 0 ;;
esac
exit 0
FAKE
    cat >"$bin/bwrap" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
FAKE
    cat >"$bin/claude" <<'FAKE'
#!/bin/sh
root=$(cd -P "$(dirname "$0")/.." && pwd)
p=$(pwd -P); pr=${p##*/pr-}; s=$(basename "$(dirname "$p")")
[ -f "$root/run/status.json" ] && cp "$root/run/status.json" "$root/obs/status-$s-$pr"
if [ -f "$root/fail-reviewer" ]; then
  echo '{"type":"result","subtype":"error","is_error":true,"result":"reviewer crashed"}'
  exit 1
fi
printf '{"type":"result","subtype":"success","is_error":false,"usage":{"output_tokens":20},"result":"**No findings.** fine"}\n'
FAKE
    chmod 755 "$bin/gh" "$bin/bwrap" "$bin/claude"
  }

  run_w_tick() {
    env -u GH_TOKEN HOME="$root/userhome" AUTO_REVIEW_INSIDE_CONTAINER=1 \
      AUTO_REVIEW_REGISTRY="$reg" AUTO_REVIEW_TOKEN_DIR="$root/tokens" \
      AUTO_REVIEW_CLONE_ROOT="$root/clones" AUTO_REVIEW_WORKTREE_ROOT="$root/worktrees" \
      AUTO_REVIEW_STATE_DIR="$root/state" AUTO_REVIEW_LOCK_DIR="$root/locks" \
      AUTO_REVIEW_STATUS_FILE="$root/run/status.json" AUTO_REVIEW_TIMEOUT=60 \
      AUTO_REVIEW_INTERVAL=180 AUTO_REVIEW_POST_RETRY_DELAYS="0 0 0" \
      AUTO_REVIEW_MEMINFO="$root/meminfo" AUTO_REVIEW_MEMORY_FLOOR_MB=100 AUTO_REVIEW_REVIEW_MB=100 \
      PATH="$bin:$PATH" FAKE_ROOT="$root" "$@" "$script" tick >/dev/null 2>&1
  }
  w_mem() { printf 'MemAvailable: %s kB\n' "$(($1 * 1024))" >"$root/meminfo"; }

  # --- Part 2: memory_floor tick_errors._global + auto-clear ---
  mk_tick_world acme/a:1
  w_mem 50
  run_w_tick
  check "memory_floor: tick_errors._global is recorded" "1" \
    "$(jq -r 'if .tick_errors._global != null then 1 else 0 end' "$root/run/status.json" 2>/dev/null)"
  has "memory_floor: tick_errors._global reason mentions memory" \
    "$(jq -r '.tick_errors._global.reason // empty' "$root/run/status.json" 2>/dev/null)" "memory"
  w_mem 10000
  : >"$root/prs/acme-a"
  run_w_tick
  check "memory_floor: tick_errors._global clears on next healthy tick" "null" \
    "$(jq -r '.tick_errors._global' "$root/run/status.json" 2>/dev/null)"

  # --- Part 2: machine_list_project tick_errors[<repo>] + auto-clear ---
  mk_tick_world acme/a:1
  w_mem 10000
  touch "$root/fail-auth"
  run_w_tick
  check "tick_errors: token_invalid recorded for acme/a" "token_invalid" \
    "$(jq -r '.tick_errors["acme/a"].error_kind // empty' "$root/run/status.json" 2>/dev/null)"
  rm -f "$root/fail-auth"
  touch "$root/fail-list"
  run_w_tick
  check "tick_errors: list_failed/network recorded for acme/a" "1" \
    "$(jq -r '(.tick_errors["acme/a"].error_kind // "") | IN("network", "list_failed") | if . then 1 else 0 end' "$root/run/status.json" 2>/dev/null)"
  rm -f "$root/fail-list"
  rm -rf "$root/clones/acme-a"
  touch "$root/fail-clone"
  run_w_tick
  check "tick_errors: clone_failed recorded for acme/a" "clone_failed" \
    "$(jq -r '.tick_errors["acme/a"].error_kind // empty' "$root/run/status.json" 2>/dev/null)"
  rm -f "$root/fail-clone"
  run_w_tick
  check "tick_errors: acme/a clears on next successful listing" "null" \
    "$(jq -r '.tick_errors["acme/a"]' "$root/run/status.json" 2>/dev/null)"

  # --- Part 2: dynamic scheduling metadata (scanning, timeout_s, interval_s, queued) ---
  mk_tick_world acme/a:1,2,3
  w_mem 10000
  run_w_tick
  check "scanning: phase was scanning during machine_list_project" "scanning" \
    "$(jq -r '.phase // empty' "$root/obs/status-scanning" 2>/dev/null)"
  snap1="$root/obs/status-acme-a-1"
  check "timeout_s: present and > 0 in .active[0]" "1" \
    "$(jq -r '(.active[0].timeout_s // 0) | if (type == "number" and . > 0) then 1 else 0 end' "$snap1" 2>/dev/null)"
  check "interval_s: present and == 180" "180" \
    "$(jq -r '.interval_s // empty' "$snap1" 2>/dev/null)"
  check "queued: lists remaining pending PRs during first review" "2" \
    "$(jq -r '.queued | length' "$snap1" 2>/dev/null)"
  check "queued: entries have repo and pr" "acme/a:2" \
    "$(jq -r '"\(.queued[0].repo):\(.queued[0].pr)"' "$snap1" 2>/dev/null)"
  check "queued: empty when idle" "0" \
    "$(jq -r '.queued | length' "$root/run/status.json" 2>/dev/null)"

  # --- Part 2: pre-review failures in recent_results ---
  for mode in fail-checkout fail-material fail-history; do
    mk_tick_world acme/a:1
    w_mem 10000
    touch "$root/$mode"
    run_w_tick
    check "pre-review ($mode): recent_results[\"acme/a#1\"] recorded" "1" \
      "$(jq -r 'if .recent_results["acme/a#1"] != null then 1 else 0 end' "$root/run/status.json" 2>/dev/null)"
    check "pre-review ($mode): reason is non-empty" "1" \
      "$(jq -r '(.recent_results["acme/a#1"].reason // "") | if length > 0 then 1 else 0 end' "$root/run/status.json" 2>/dev/null)"
  done

  # Empty diff early post_review failure recorded in recent_results
  FAKE_EMPTY_DIFF=1 mk_tick_world acme/a:1
  FAKE_EMPTY_DIFF=0
  w_mem 10000
  FAKE_POST_MODE=403 run_w_tick
  check "pre-review (empty diff post_review 403): recent_results recorded" "github_rejected" \
    "$(jq -r '.recent_results["acme/a#1"].error_kind // empty' "$root/run/status.json" 2>/dev/null)"

  # --- Part 2: recent_results attempts increment/reset & 50-entry/24h cap ---
  mk_tick_world acme/a:1
  w_mem 10000
  touch "$root/fail-reviewer"
  run_w_tick
  check "attempts: 1st failure on sha1 is 1" "1" \
    "$(jq -r '.recent_results["acme/a#1"].attempts // 0' "$root/run/status.json" 2>/dev/null)"
  run_w_tick
  check "attempts: 2nd consecutive failure on same sha1 increments to 2" "2" \
    "$(jq -r '.recent_results["acme/a#1"].attempts // 0' "$root/run/status.json" 2>/dev/null)"
  # Push new sha2 on pr-1 -> failure resets attempts to 1
  "$real_git" -C "$root/origins/acme-a" checkout -q pr-1
  printf 'v2\n' >"$root/origins/acme-a/v2.txt"
  "$real_git" -C "$root/origins/acme-a" add -A
  "$real_git" -C "$root/origins/acme-a" commit -q -m v2
  "$real_git" -C "$root/origins/acme-a" rev-parse HEAD >"$root/heads/acme-a-1"
  "$real_git" -C "$root/origins/acme-a" checkout -q main
  run_w_tick
  check "attempts: failure on new sha2 resets to 1" "1" \
    "$(jq -r '.recent_results["acme/a#1"].attempts // 0' "$root/run/status.json" 2>/dev/null)"
  # Succeed (posted), then fail on next sha -> attempts resets to 1
  rm -f "$root/fail-reviewer"
  run_w_tick
  check "attempts: posted result recorded" "posted" \
    "$(jq -r '.recent_results["acme/a#1"].result // empty' "$root/run/status.json" 2>/dev/null)"
  touch "$root/fail-reviewer"
  "$real_git" -C "$root/origins/acme-a" checkout -q pr-1
  printf 'v3\n' >"$root/origins/acme-a/v3.txt"
  "$real_git" -C "$root/origins/acme-a" add -A
  "$real_git" -C "$root/origins/acme-a" commit -q -m v3
  "$real_git" -C "$root/origins/acme-a" rev-parse HEAD >"$root/heads/acme-a-1"
  "$real_git" -C "$root/origins/acme-a" checkout -q main
  run_w_tick
  check "attempts: failure after posted resets to 1" "1" \
    "$(jq -r '.recent_results["acme/a#1"].attempts // 0' "$root/run/status.json" 2>/dev/null)"

  # 50-entry & 24h TTL cap on recent_results
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg now "$now_iso" '{
    phase: "idle", active: [],
    recent_results: (
      ({"old/repo#1": {sha:"a",result:"posted",error_kind:"",http_status:null,reason:"",retryable:false,attempts:1,at:"2020-01-01T00:00:00Z"},
        "old/repo#2": {sha:"b",result:"posted",error_kind:"",http_status:null,reason:"",retryable:false,attempts:1,at:"2020-01-02T00:00:00Z"}})
      + ([range(1; 52) | {key: ("acme/bulk#" + tostring), value: {sha:"c",result:"posted",error_kind:"",http_status:null,reason:"",retryable:false,attempts:1,at:$now}}] | from_entries)
    )
  }' >"$root/run/status.json"
  rm -f "$root/fail-reviewer"
  "$real_git" -C "$root/origins/acme-a" checkout -q pr-1
  printf 'v4\n' >"$root/origins/acme-a/v4.txt"
  "$real_git" -C "$root/origins/acme-a" add -A
  "$real_git" -C "$root/origins/acme-a" commit -q -m v4
  "$real_git" -C "$root/origins/acme-a" rev-parse HEAD >"$root/heads/acme-a-1"
  "$real_git" -C "$root/origins/acme-a" checkout -q main
  run_w_tick
  check "recent_results cap: expired (>24h) entries pruned" "null" \
    "$(jq -r '.recent_results["old/repo#1"]' "$root/run/status.json" 2>/dev/null)"
  check "recent_results cap: total entries <= 50" "1" \
    "$(jq -r '(.recent_results | length) | if . <= 50 then 1 else 0 end' "$root/run/status.json" 2>/dev/null)"

  # --- Part 3: Table-driven selective post_review retry & error classification ---
  check_post_retry() {
    local label="$1" mode="$2" want_calls="$3" want_rc="$4" want_kind="$5" want_retry="$6" want_http="$7" extra_head="${8:-}"
    mk_tick_world acme/a:1
    w_mem 10000
    local sha1
    sha1="$(cat "$root/heads/acme-a-1")"
    local cur_head="${extra_head:-$sha1}"
    FAKE_POST_MODE="$mode" FAKE_CURRENT_HEAD="$cur_head" run_w_tick
    local calls
    calls="$(wc -l <"$root/obs/post-attempts" 2>/dev/null | tr -d ' ')"
    check "$label: gh post attempts" "$want_calls" "${calls:-0}"
    if [ "$want_rc" = "0" ]; then
      check "$label: result is posted" "posted" \
        "$(jq -r '.recent_results["acme/a#1"].result // empty' "$root/run/status.json" 2>/dev/null)"
    else
      check "$label: error_kind" "$want_kind" \
        "$(jq -r '.recent_results["acme/a#1"].error_kind // empty' "$root/run/status.json" 2>/dev/null)"
      check "$label: retryable" "$want_retry" \
        "$(jq -r 'if .recent_results["acme/a#1"].retryable == true then "true" elif .recent_results["acme/a#1"].retryable == false then "false" else "unset" end' "$root/run/status.json" 2>/dev/null)"
      if [ "$want_http" != "-" ]; then
        check "$label: http_status" "$want_http" \
          "$(jq -r '.recent_results["acme/a#1"].http_status // empty' "$root/run/status.json" 2>/dev/null)"
      fi
    fi
  }

  check_post_retry "post_review 502_then_200" "502_then_200" 2 0 "" "" "-"
  check_post_retry "post_review 502 exhausted" "502" 4 1 "github_transient" "true" "502"
  check_post_retry "post_review 429 exhausted" "429" 4 1 "github_transient" "true" "429"
  check_post_retry "post_review transport exhausted" "transport" 4 1 "github_transient" "true" "-"
  check_post_retry "post_review 401 no-retry" "401" 1 1 "github_rejected" "false" "401"
  check_post_retry "post_review 403 no-retry" "403" 1 1 "github_rejected" "false" "403"
  check_post_retry "post_review 422 same-head no-retry" "422" 1 1 "github_rejected" "false" "422"
  check_post_retry "post_review 422 stale_head no-retry" "422" 1 1 "stale_head" "false" "422" "ffffffffffffffffffffffffffffffffffffffff"

  # text_holds_token refusal: 0 gh post calls, retryable=false, error_kind=text_holds_token
  mk_tick_world acme/a:1
  w_mem 10000
  cat >"$bin/claude" <<'FAKE'
#!/bin/sh
printf '{"type":"result","subtype":"success","is_error":false,"usage":{"output_tokens":20},"result":"**No findings.** leaked ghp_fakeacme00000000000000000000"}\n'
FAKE
  chmod 755 "$bin/claude"
  run_w_tick
  check "post_review text_holds_token: 0 gh post calls" "0" \
    "$([ -f "$root/obs/post-attempts" ] && wc -l <"$root/obs/post-attempts" | tr -d ' ' || echo 0)"
  check "post_review text_holds_token: error_kind" "text_holds_token" \
    "$(jq -r '.recent_results["acme/a#1"].error_kind // empty' "$root/run/status.json" 2>/dev/null)"
  check "post_review text_holds_token: retryable is false" "false" \
    "$(jq -r 'if .recent_results["acme/a#1"].retryable == false then "false" else "other" end' "$root/run/status.json" 2>/dev/null)"

  # --- Part 4: Single-source interval_s across tick, daemon refresh, and sleep ---
  mk_tick_world acme/a:1
  w_mem 10000
  jq '.interval = 600' "$reg" >"$reg.tmp" && mv -f "$reg.tmp" "$reg"
  env -u GH_TOKEN -u AUTO_REVIEW_INTERVAL HOME="$root/userhome" AUTO_REVIEW_INSIDE_CONTAINER=1 \
    AUTO_REVIEW_REGISTRY="$reg" AUTO_REVIEW_TOKEN_DIR="$root/tokens" \
    AUTO_REVIEW_CLONE_ROOT="$root/clones" AUTO_REVIEW_WORKTREE_ROOT="$root/worktrees" \
    AUTO_REVIEW_STATE_DIR="$root/state" AUTO_REVIEW_LOCK_DIR="$root/locks" \
    AUTO_REVIEW_STATUS_FILE="$root/run/status.json" AUTO_REVIEW_TIMEOUT=60 \
    AUTO_REVIEW_POST_RETRY_DELAYS="0 0 0" \
    AUTO_REVIEW_MEMINFO="$root/meminfo" AUTO_REVIEW_MEMORY_FLOOR_MB=100 AUTO_REVIEW_REVIEW_MB=100 \
    PATH="$bin:$PATH" FAKE_ROOT="$root" "$script" tick >/dev/null 2>&1
  check "interval_s after tick with registry interval=600 and env unset" "600" \
    "$(jq -r '.interval_s // empty' "$root/run/status.json" 2>/dev/null)"
  (
    unset AUTO_REVIEW_INTERVAL
    export AUTO_REVIEW_REGISTRY="$reg"
    export AUTO_REVIEW_STATUS_FILE="$root/run/status.json"
    # shellcheck disable=SC1091
    . "$here/lib/registry.sh"
    # shellcheck disable=SC1091
    . "$active_lib"
    set +e
    status_daemon_idle_refresh
    check "interval_s after status_daemon_idle_refresh matches tick" "600" \
      "$(jq -r '.interval_s // empty' "$root/run/status.json" 2>/dev/null)"
    check "status_interval_s (daemon sleep value) matches tick" "600" \
      "$(status_interval_s)"
    status_daemon_started
    check "interval_s after status_daemon_started matches tick" "600" \
      "$(jq -r '.interval_s // empty' "$root/run/status.json" 2>/dev/null)"
    status_active_reset
    check "interval_s after status_active_reset matches tick" "600" \
      "$(jq -r '.interval_s // empty' "$root/run/status.json" 2>/dev/null)"
    exit "$fail"
  ) || fail=1
  check "entrypoint.sh sleeps via status_interval_s" "1" \
    "$(grep -c 'daemon_sleep_s=\"\$(status_interval_s)\"' "$entry" 2>/dev/null || true)"

  exit "$fail"
)

# ==============================================================================
# Section 7: Login caching per token fingerprint, /rate_limit telemetry,
#            circuit breaker (<500 throttle / <150 pause), and entrypoint sleep
# ==============================================================================
section_7() (
  script="$here/auto-review.sh"
  active_lib="$here/lib/active-status.sh"
  entry="$here/entrypoint.sh"
  fixtures=$(mktemp -d)
  fixtures=$(cd "$fixtures" && pwd -P)
  trap 'chmod -R u+rwx "$fixtures" 2>/dev/null; rm -rf "$fixtures"' EXIT
  fail=0

  # --- Part 1: active-status.sh preserves rate_limit across RMW helpers ---
  (
    export AUTO_REVIEW_STATUS_FILE="$fixtures/rl-status.json"
    export AUTO_REVIEW_TOKEN_DIR="$fixtures/empty-tokens"
    mkdir -p "$AUTO_REVIEW_TOKEN_DIR"
    # shellcheck disable=SC1091
    . "$script"
    # shellcheck disable=SC1091
    . "$active_lib"
    set +e

    cat >"$AUTO_REVIEW_STATUS_FILE" <<'JSON'
{"phase":"idle","active":[],"queued":[],"interval_s":180,"rate_limit":{"core_remaining":420,"core_limit":5000,"core_reset_at":1732570000,"graphql_remaining":4900,"graphql_limit":5000,"throttled":true}}
JSON

    MACHINE_ACTIVE=1
    status_review_begin "acme/a" 1 "sha1" 10 "sonnet"
    check "rate_limit preserved across status_review_begin" "420:true" \
      "$(jq -r '"\(.rate_limit.core_remaining // empty):\(.rate_limit.throttled)"' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_review_end "acme/a" 1 "posted"
    check "rate_limit preserved across status_review_end" "420:true" \
      "$(jq -r '"\(.rate_limit.core_remaining // empty):\(.rate_limit.throttled)"' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_phase_set "scanning" 180
    check "rate_limit preserved across status_phase_set" "420:true" \
      "$(jq -r '"\(.rate_limit.core_remaining // empty):\(.rate_limit.throttled)"' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_tick_error_set "_global" "rate_limited" "rate limit low"
    check "rate_limit preserved across status_tick_error_set" "420:true" \
      "$(jq -r '"\(.rate_limit.core_remaining // empty):\(.rate_limit.throttled)"' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_tick_error_clear "_global"
    check "rate_limit preserved across status_tick_error_clear" "420:true" \
      "$(jq -r '"\(.rate_limit.core_remaining // empty):\(.rate_limit.throttled)"' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_daemon_idle_refresh
    check "rate_limit preserved across status_daemon_idle_refresh" "420:true" \
      "$(jq -r '"\(.rate_limit.core_remaining // empty):\(.rate_limit.throttled)"' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_daemon_started
    check "rate_limit preserved across status_daemon_started" "420:true" \
      "$(jq -r '"\(.rate_limit.core_remaining // empty):\(.rate_limit.throttled)"' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    status_active_reset
    check "rate_limit preserved across status_active_reset" "420:true" \
      "$(jq -r '"\(.rate_limit.core_remaining // empty):\(.rate_limit.throttled)"' "$AUTO_REVIEW_STATUS_FILE" 2>/dev/null)"

    exit "$fail"
  ) || fail=1

  # --- Helper world for login cache & rate_limit circuit breaker ---
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  real_git=$(command -v git)

  n=0
  mk_rl_world() {
    n=$((n + 1))
    root="$fixtures/rl$n"
    bin="$root/bin"; obs="$root/obs"
    mkdir -p "$bin" "$obs" "$root/run" "$root/state" "$root/locks" "$root/tokens" \
      "$root/prs" "$root/heads" "$root/clones/clones" "$root/userhome/.local"
    ln -s "$bin" "$root/userhome/.local/bin"
    : >"$root/gh-calls"
    reg="$root/projects.json"
    jq -n '{version: 1, harness: "claude-code", model: "sonnet", parallel: "1", slots: "4", projects: {}}' >"$reg"
    local spec repo prs slug owner o c pr
    for spec in "$@"; do
      repo="${spec%%:*}"; prs="${spec#*:}"; slug=$(printf '%s' "$repo" | tr '/' '-'); owner="${repo%%/*}"
      printf 'ghp_fake%s00000000000000000000\n' "$owner" >"$root/tokens/gh-$owner.token"
      o="$root/origins/$slug"; c="$root/clones/$slug"
      mkdir -p "$root/origins"
      "$real_git" init -q -b main "$o"
      printf 'readme\n' >"$o/README.md"; "$real_git" -C "$o" add -A; "$real_git" -C "$o" commit -q -m init
      : >"$root/prs/$slug"
      for pr in $(printf '%s' "$prs" | tr ',' ' '); do
        [ -n "$pr" ] || continue
        "$real_git" -C "$o" checkout -q -b "pr-$pr" main
        printf 'change %s\n' "$pr" >"$o/f$pr.txt"; "$real_git" -C "$o" add -A; "$real_git" -C "$o" commit -q -m "change $pr"
        "$real_git" -C "$o" rev-parse HEAD >"$root/heads/$slug-$pr"
        echo "$pr" >>"$root/prs/$slug"
      done
      "$real_git" -C "$o" checkout -q main
      "$real_git" clone -q "$o" "$c"
      printf '%s\n' "$c" >"$root/clones/clones/$slug"
      jq --arg r "$repo" '.projects[$r] = {adopted_at: "2026-11-01T00:00:00Z", all: true, self_review: false}' "$reg" >"$reg.t" && mv "$reg.t" "$reg"
    done

    cat >"$bin/gh" <<'FAKE'
#!/bin/sh
echo "gh $*" >>"$FAKE_ROOT/gh-calls"
repo=""; prev=""; jq_filter=""
for a in "$@"; do
  [ "$prev" = "--repo" ] && repo="$a"
  if [ "$prev" = "-q" ] || [ "$prev" = "--jq" ]; then jq_filter="$a"; fi
  prev="$a"
done
case "$*" in
  "api user -q .login"*)
    [ -f "$FAKE_ROOT/fail-auth" ] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    if [ -f "$FAKE_ROOT/me-override" ]; then
      cat "$FAKE_ROOT/me-override"
    else
      echo "tester"
    fi
    exit 0 ;;
  "api rate_limit"* | "api /rate_limit"*)
    core_rem="${FAKE_CORE_REM:-5000}"
    core_lim="${FAKE_CORE_LIM:-5000}"
    core_rst="${FAKE_CORE_RST:-1732570000}"
    gql_rem="${FAKE_GQL_REM:-5000}"
    gql_lim="${FAKE_GQL_LIM:-5000}"
    gql_rst="${FAKE_GQL_RST:-$core_rst}"
    case "${GH_TOKEN:-}" in
      ghp_fakeacme*) [ -n "${FAKE_ACME_CORE_REM:-}" ] && core_rem="$FAKE_ACME_CORE_REM" ;;
      ghp_fakebeta*) [ -n "${FAKE_BETA_CORE_REM:-}" ] && core_rem="$FAKE_BETA_CORE_REM" ;;
    esac
    json=$(printf '{"resources":{"core":{"limit":%s,"used":0,"remaining":%s,"reset":%s},"graphql":{"limit":%s,"used":0,"remaining":%s,"reset":%s}}}' \
      "$core_lim" "$core_rem" "$core_rst" "$gql_lim" "$gql_rem" "$gql_rst")
    if [ -n "$jq_filter" ]; then
      printf '%s\n' "$json" | jq -r "$jq_filter"
    else
      printf '%s\n' "$json"
    fi
    exit 0 ;;
  "pr list "*)
    slug=$(printf '%s' "$repo" | tr '/' '-')
    while read -r p; do
      [ -n "$p" ] || continue
      printf '%s\t%s\tmain\tfalse\tfalse\tauthor\tpr-%s\t\t0\tChange %s\n' "$p" "$(cat "$FAKE_ROOT/heads/$slug-$p")" "$p" "$p"
    done <"$FAKE_ROOT/prs/$slug"
    exit 0 ;;
  "pr checkout "*)
    git checkout -q --detach "origin/pr-$3"; exit 0 ;;
  "pr view "*"baseRefName -q .baseRefName")
    echo main; exit 0 ;;
  "pr view "*)
    echo stub; exit 0 ;;
  "api repos/"*"/pulls/"*"/reviews --input -"*)
    cat >/dev/null; exit 0 ;;
  "api --paginate repos/"*"/pulls/"*"/reviews "*)
    exit 0 ;;
  "api repos/"*"/actions/runs"*) echo 0; exit 0 ;;
  "api repos/"*"/commits/"*"/status"*) echo none; exit 0 ;;
esac
exit 0
FAKE
    cat >"$bin/bwrap" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
FAKE
    cat >"$bin/claude" <<'FAKE'
#!/bin/sh
root=$(cd -P "$(dirname "$0")/.." && pwd)
p=$(pwd -P); pr=${p##*/pr-}; s=$(basename "$(dirname "$p")")
[ -f "$root/run/status.json" ] && cp "$root/run/status.json" "$root/obs/status-$s-$pr"
printf '{"type":"result","subtype":"success","is_error":false,"usage":{"output_tokens":20},"result":"**No findings.** fine"}\n'
FAKE
    chmod 755 "$bin/gh" "$bin/bwrap" "$bin/claude"
  }

  run_rl_tick() {
    env -u GH_TOKEN HOME="$root/userhome" AUTO_REVIEW_INSIDE_CONTAINER=1 \
      AUTO_REVIEW_REGISTRY="$reg" AUTO_REVIEW_TOKEN_DIR="$root/tokens" \
      AUTO_REVIEW_CLONE_ROOT="$root/clones" AUTO_REVIEW_WORKTREE_ROOT="$root/worktrees" \
      AUTO_REVIEW_STATE_DIR="$root/state" AUTO_REVIEW_LOCK_DIR="$root/locks" \
      AUTO_REVIEW_STATUS_FILE="$root/run/status.json" AUTO_REVIEW_TIMEOUT=60 \
      AUTO_REVIEW_INTERVAL=180 AUTO_REVIEW_POST_RETRY_DELAYS="0 0 0" \
      AUTO_REVIEW_MEMINFO="$root/meminfo" AUTO_REVIEW_MEMORY_FLOOR_MB=100 AUTO_REVIEW_REVIEW_MB=100 \
      PATH="$bin:$PATH" FAKE_ROOT="$root" "$@" "$script" tick >/dev/null 2>&1
  }
  rl_mem() { printf 'MemAvailable: %s kB\n' "$(($1 * 1024))" >"$root/meminfo"; }
  api_user_calls() { local c; c="$(grep -c '^gh api user' "$root/gh-calls" 2>/dev/null || true)"; echo "${c:-0}"; }
  rate_limit_calls() { local c; c="$(grep -cE '^gh api /?rate_limit' "$root/gh-calls" 2>/dev/null || true)"; echo "${c:-0}"; }
  pr_list_calls() { local c; c="$(grep -c '^gh pr list' "$root/gh-calls" 2>/dev/null || true)"; echo "${c:-0}"; }

  # --- Part 2: Login caching per (owner, token_file stat mtime:size:inode) ---
  mk_rl_world acme/a:1 acme/b:1 beta/c:1
  rl_mem 10000
  run_rl_tick
  check "login cache: tick 1 calls gh api user once per owner (2 owners, 3 repos)" "2" "$(api_user_calls)"
  check "login cache: state/login.acme exists" "present" "$([ -s "$root/state/login.acme" ] && echo present || echo absent)"
  check "login cache: state/login.beta exists" "present" "$([ -s "$root/state/login.beta" ] && echo present || echo absent)"

  : >"$root/gh-calls"
  run_rl_tick
  check "login cache: tick 2 with unchanged tokens makes 0 gh api user calls" "0" "$(api_user_calls)"

  # Boundary: mtime change only (same size and inode) invalidates acme cache, leaves beta cached
  touch -d "2030-01-01T00:00:00Z" "$root/tokens/gh-acme.token"
  : >"$root/gh-calls"
  run_rl_tick
  check "login cache: mtime change invalidates only acme (1 gh api user call)" "1" "$(api_user_calls)"

  # Content/inode/size replacement invalidates cache
  printf 'tester2\n' >"$root/me-override"
  printf 'ghp_rotated_token_longer_value_1234567890\n' >"$root/tokens/gh-acme.token.new"
  mv -f "$root/tokens/gh-acme.token.new" "$root/tokens/gh-acme.token"
  : >"$root/gh-calls"
  run_rl_tick
  check "login cache: replaced token file invalidates cache (1 gh api user call)" "1" "$(api_user_calls)"

  : >"$root/gh-calls"
  run_rl_tick
  check "login cache: subsequent tick with rotated token hits cache (0 calls)" "0" "$(api_user_calls)"

  # Negative: gh api user failure does not poison cache
  mk_rl_world acme/a:1
  rl_mem 10000
  touch "$root/fail-auth"
  run_rl_tick
  check "login cache (auth failure): records token_invalid" "token_invalid" \
    "$(jq -r '.tick_errors["acme/a"].error_kind // empty' "$root/run/status.json" 2>/dev/null)"
  rm -f "$root/fail-auth"
  : >"$root/gh-calls"
  run_rl_tick
  check "login cache (auth recovery): resolves login on next tick (1 call)" "1" "$(api_user_calls)"
  check "login cache (auth recovery): clears token_invalid" "null" \
    "$(jq -r '.tick_errors["acme/a"]' "$root/run/status.json" 2>/dev/null)"

  # --- Part 3: /rate_limit telemetry & circuit breaker (<500 throttle / <150 pause) ---
  mk_rl_world acme/a:1 acme/b:1
  rl_mem 10000
  FAKE_CORE_REM=4900 FAKE_CORE_LIM=5000 FAKE_CORE_RST=1732571234 FAKE_GQL_REM=4800 FAKE_GQL_LIM=5000 FAKE_GQL_RST=1732572345 run_rl_tick
  check "rate_limit: queried once per tick across 2 repos" "1" "$(rate_limit_calls)"
  check "rate_limit: status.json telemetry fields" "4900:5000:1732571234:4800:5000:1732572345:false" \
    "$(jq -r '.rate_limit | "\(.core_remaining):\(.core_limit):\(.core_reset_at):\(.graphql_remaining):\(.graphql_limit):\(.graphql_reset_at):\(.throttled)"' "$root/run/status.json" 2>/dev/null)"
  check "rate_limit: preserved in status.json during active review" "4900" \
    "$(jq -r '.rate_limit.core_remaining // empty' "$root/obs/status-acme-a-1" 2>/dev/null)"

  # Table-driven boundary matrix for <500 throttle and <150 pause
  check_rl_threshold() {
    local label="$1" core_rem="$2" gql_rem="$3" want_throttled="$4" want_scan="$5" want_global_err="$6"
    : >"$root/gh-calls"
    FAKE_CORE_REM="$core_rem" FAKE_GQL_REM="$gql_rem" run_rl_tick
    local got_throttled got_scans got_err
    got_throttled="$(jq -r 'if .rate_limit.throttled == true then "true" elif .rate_limit.throttled == false then "false" else "unset" end' "$root/run/status.json" 2>/dev/null)"
    got_scans="$(pr_list_calls)"
    got_err="$(jq -r '.tick_errors._global.error_kind // "none"' "$root/run/status.json" 2>/dev/null)"
    check "$label: throttled" "$want_throttled" "$got_throttled"
    if [ "$want_scan" = "yes" ]; then
      check "$label: repo scan ran" "yes" "$([ "$got_scans" -ge 1 ] && echo yes || echo no)"
    else
      check "$label: repo scan skipped" "0" "$got_scans"
    fi
    check "$label: tick_errors._global.error_kind" "$want_global_err" "$got_err"
  }

  mk_rl_world acme/a:1
  rl_mem 10000
  check_rl_threshold "threshold (core=500, gql=500)"   500  500  "false" "yes" "none"
  check_rl_threshold "threshold (core=499, gql=5000)"  499  5000 "true"  "yes" "none"
  check_rl_threshold "threshold (core=5000, gql=499)"  5000 499  "true"  "yes" "none"
  check_rl_threshold "threshold (core=150, gql=5000)"  150  5000 "true"  "yes" "none"
  check_rl_threshold "threshold (core=149, gql=5000)"  149  5000 "true"  "no"  "rate_limited"
  check_rl_threshold "threshold (core=5000, gql=149)"  5000 149  "true"  "no"  "rate_limited"
  check_rl_threshold "threshold (recovery 5000/5000)"  5000 5000 "false" "yes" "none"

  # Multi-owner isolation: exhausted acme token (100) skips acme/a while healthy beta token (5000) still lists beta/c
  mk_rl_world acme/a:1 beta/c:1
  rl_mem 10000
  : >"$root/gh-calls"
  FAKE_ACME_CORE_REM=100 FAKE_BETA_CORE_REM=5000 run_rl_tick
  check "rate_limit (multi-owner): queried once per distinct token" "2" "$(rate_limit_calls)"
  check "rate_limit (multi-owner): acme/a skipped" "0" "$(grep -c '^gh pr list --repo acme/a' "$root/gh-calls" 2>/dev/null || true)"
  check "rate_limit (multi-owner): beta/c still listed" "1" "$(grep -c '^gh pr list --repo beta/c' "$root/gh-calls" 2>/dev/null || true)"
  check "rate_limit (multi-owner): acme/a recorded rate_limited" "rate_limited" \
    "$(jq -r '.tick_errors["acme/a"].error_kind // empty' "$root/run/status.json" 2>/dev/null)"

  # --- Part 4: entrypoint.sh daemon_sleep_s for throttled and rate_limited ---
  ep_root="$fixtures/ep"
  mkdir -p "$ep_root/bin" "$ep_root/run" "$ep_root/var" "$ep_root/clones" "$ep_root/home"
  sed -e "s|/var/run/docker.sock|$ep_root/no-docker.sock|g" \
      -e "s|/usr/local/lib/auto-review|$here|g" \
      -e "s|/usr/local/bin/auto-review|$ep_root/bin/auto-review|g" \
      "$entry" >"$ep_root/entrypoint.sh"
  chmod 755 "$ep_root/entrypoint.sh"
  jq -n '{version: 1, interval: 180, projects: {}}' >"$ep_root/var/projects.json"

  cat >"$ep_root/bin/auto-review" <<'FAKE'
#!/bin/sh
if [ "$1" = "tick" ] && [ -n "${FAKE_TICK_STATUS_JSON:-}" ]; then
  printf '%s\n' "$FAKE_TICK_STATUS_JSON" >"$AUTO_REVIEW_STATUS_FILE"
fi
exit 0
FAKE
  cat >"$ep_root/bin/sleep" <<'FAKE'
#!/bin/sh
printf '%s\n' "$1" >"$FAKE_SLEEP_OUT"
kill -TERM "$PPID" 2>/dev/null || true
exit 0
FAKE
  chmod 755 "$ep_root/bin/auto-review" "$ep_root/bin/sleep"

  run_ep_sleep() {
    local status_json="$1"
    rm -f "$ep_root/sleep-arg" "$ep_root/run/status.json"
    env -u AUTO_REVIEW_INTERVAL HOME="$ep_root/home" \
      AUTO_REVIEW_REGISTRY="$ep_root/var/projects.json" \
      AUTO_REVIEW_LOCK_DIR="$ep_root/run" \
      AUTO_REVIEW_CLONE_ROOT="$ep_root/clones" \
      AUTO_REVIEW_STATUS_FILE="$ep_root/run/status.json" \
      FAKE_TICK_STATUS_JSON="$status_json" \
      FAKE_SLEEP_OUT="$ep_root/sleep-arg" \
      PATH="$ep_root/bin:$PATH" \
      "$ep_root/entrypoint.sh" daemon >/dev/null 2>&1 || true
    cat "$ep_root/sleep-arg" 2>/dev/null || echo "missing"
  }

  now_s=$(date +%s)
  got_norm=$(run_ep_sleep "{\"phase\":\"idle\",\"active\":[],\"interval_s\":180,\"rate_limit\":{\"core_remaining\":4000,\"core_limit\":5000,\"core_reset_at\":$((now_s + 1200)),\"graphql_remaining\":5000,\"graphql_limit\":5000,\"throttled\":false}}")
  check "entrypoint sleep (normal, throttled=false): 180s" "180" "$got_norm"

  got_throt=$(run_ep_sleep "{\"phase\":\"idle\",\"active\":[],\"interval_s\":180,\"rate_limit\":{\"core_remaining\":400,\"core_limit\":5000,\"core_reset_at\":$((now_s + 1200)),\"graphql_remaining\":5000,\"graphql_limit\":5000,\"throttled\":true}}")
  check "entrypoint sleep (throttled=true): doubled to 360s" "360" "$got_throt"

  now_s=$(date +%s)
  got_rl_short=$(run_ep_sleep "{\"phase\":\"idle\",\"active\":[],\"interval_s\":180,\"rate_limit\":{\"core_remaining\":100,\"core_limit\":5000,\"core_reset_at\":$((now_s + 120)),\"graphql_remaining\":5000,\"graphql_limit\":5000,\"throttled\":true},\"tick_errors\":{\"_global\":{\"error_kind\":\"rate_limited\",\"reason\":\"low\",\"at\":\"2026-11-25T00:00:00Z\"}}}")
  check "entrypoint sleep (rate_limited, reset in 120s): ~125s (120..128)" "yes" \
    "$(case "$got_rl_short" in ''|*[!0-9]*) echo no ;; *) [ "$got_rl_short" -ge 120 ] && [ "$got_rl_short" -le 128 ] && echo yes || echo "no:$got_rl_short" ;; esac)"

  now_s=$(date +%s)
  got_rl_cap=$(run_ep_sleep "{\"phase\":\"idle\",\"active\":[],\"interval_s\":180,\"rate_limit\":{\"core_remaining\":100,\"core_limit\":5000,\"core_reset_at\":$((now_s + 1200)),\"graphql_remaining\":5000,\"graphql_limit\":5000,\"graphql_reset_at\":$((now_s + 1200)),\"throttled\":true},\"tick_errors\":{\"_global\":{\"error_kind\":\"rate_limited\",\"reason\":\"low\",\"at\":\"2026-11-25T00:00:00Z\"}}}")
  check "entrypoint sleep (rate_limited, reset in 1200s): capped at ~600s (595..600)" "yes" \
    "$(case "$got_rl_cap" in ''|*[!0-9]*) echo no ;; *) [ "$got_rl_cap" -ge 595 ] && [ "$got_rl_cap" -le 600 ] && echo yes || echo "no:$got_rl_cap" ;; esac)"

  now_s=$(date +%s)
  got_rl_gql=$(run_ep_sleep "{\"phase\":\"idle\",\"active\":[],\"interval_s\":180,\"rate_limit\":{\"core_remaining\":5000,\"core_limit\":5000,\"core_reset_at\":$((now_s + 1200)),\"graphql_remaining\":100,\"graphql_limit\":5000,\"graphql_reset_at\":$((now_s + 60)),\"throttled\":true},\"tick_errors\":{\"_global\":{\"error_kind\":\"rate_limited\",\"reason\":\"low\",\"at\":\"2026-11-25T00:00:00Z\"}}}")
  check "entrypoint sleep (rate_limited on graphql, reset in 60s): ~65s (60..68)" "yes" \
    "$(case "$got_rl_gql" in ''|*[!0-9]*) echo no ;; *) [ "$got_rl_gql" -ge 60 ] && [ "$got_rl_gql" -le 68 ] && echo yes || echo "no:$got_rl_gql" ;; esac)"

  exit "$fail"
)

run_sections_parallel section_1 section_2 section_3 section_4 section_5 section_6 section_7
exit $?
