#!/usr/bin/env bash
# The reviewer's uid isolation, in a container with exactly the compose security
# options (upstream issue). Needs docker; SKIPs (exit 0) without it.
#
#   bash scripts/test-auto-review-reviewer-isolation-docker.sh
#
# Builds the image from this checkout, then runs, as the entrypoint would leave
# the process (uid 10001 holding SETUID/SETGID only):
#   - the container probe,
#   - the credential test, whose privileged block is a permanent SKIP outside a
#     container like this one,
#   - direct checks that the reviewer uid cannot read the gate's files or
#     environ, cannot write the material it reads, and cannot switch back.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
image="${AUTO_REVIEW_TEST_IMAGE:-auto-review:isolation-test}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP  reviewer isolation in the container: docker is not available"
  exit 0
fi

if [ -z "${AUTO_REVIEW_TEST_IMAGE:-}" ]; then
  docker build --quiet -f "$here/Dockerfile" -t "$image" "$here" >/dev/null ||
    { echo "FAIL  docker build of the auto-review image"; exit 1; }
fi

# Same as tools/auto-review/docker-compose.yml.
run() { # args after `--` are the entrypoint's
  docker run --rm -i \
    --user 0 --read-only \
    --cap-drop ALL --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges:true \
    --tmpfs /run/auto-review:size=32M,mode=0700,uid=10001,gid=10001 \
    --tmpfs /tmp:size=128M,mode=1777,exec \
    --tmpfs /opt/ar-bin:size=16M,mode=1777,exec \
    -e AUTO_REVIEW_TEST_BIN_ROOT=/opt/ar-bin \
    --tmpfs /home/reviewer:size=512M,mode=0700,uid=10001,gid=10001 \
    --tmpfs /home/rv:size=512M,mode=0700,uid=10002,gid=10002 \
    -v "$here:/src:ro" \
    --entrypoint /usr/local/bin/entrypoint.sh "$image" "$@"
}

fail=0
section() { printf '=== %s\n' "$1"; }

section "container probe"
run probe </dev/null || fail=1

section "credential test, privileged block included"
out="$(run bash /src/tests/test-auto-review-credentials-isolation.sh 2>&1 </dev/null)"
rc=$?
printf '%s\n' "$out" | grep -v '^ok' | head -n 30
printf '%s\n' "$out" | grep -c '^ok' | sed 's/^/ok lines: /'
[ "$rc" = 0 ] || fail=1
case "$out" in
  *"SKIP  uid separation"*) echo "FAIL  the privileged block still skipped inside the container"; fail=1 ;;
  *"ok    reviewer runs as a different uid than the gate"*) ;;
  *) echo "FAIL  the privileged block did not run"; fail=1 ;;
esac

section "direct isolation checks"
run bash -s <<'INNER' || fail=1
set -u
. /src/lib/reviewer-uid.sh
export AUTO_REVIEW_REVIEWER_UID=10002
bad=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 (want '$2', got '$3')"; bad=1; fi; }
gate_uid=$(id -u)
t=$(mktemp -d); chmod 755 "$t"
printf 'ghp_FIXTURE\n' >/run/auto-review/r.token
mkdir -p "$t/src/.git" "$t/src/sub"; echo code >"$t/src/sub/a.txt"; echo secret >"$t/src/.git/config"
check "gate runs as 10001" 10001 "$gate_uid"
check "reviewer_uid_mode is on" yes "$(reviewer_uid_mode && echo yes || echo no)"
m=$(reviewer_material_prepare "$t/src")
check "material has the tree" code "$(cat "$m/sub/a.txt")"
check "material has no .git" absent "$([ -e "$m/.git" ] && echo present || echo absent)"
home=$(reviewer_home_name)
r() { reviewer_exec "$home" sh -c "mkdir -p \"\$HOME\"; $1"; }
check "reviewer uid is 10002" 10002 "$(r 'id -u')"
check "reviewer gid is 10002" 10002 "$(r 'id -g')"
check "reviewer holds no capabilities" 0000000000000000 "$(r 'sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status')"
check "reviewer holds no ambient capabilities" 0000000000000000 "$(r 'sed -n "s/^CapAmb:[[:space:]]*//p" /proc/self/status')"
check "reviewer cannot read a token file" unreadable "$(r 'cat /run/auto-review/r.token >/dev/null 2>&1 && echo readable || echo unreadable')"
check "reviewer cannot list the token dir" unreadable "$(r 'ls /run/auto-review >/dev/null 2>&1 && echo readable || echo unreadable')"
check "reviewer cannot read the gate's /proc/<pid>/environ" unreadable "$(r "cat /proc/$$/environ >/dev/null 2>&1 && echo readable || echo unreadable")"
check "reviewer cannot read any process environ" 0 "$(r 'n=0; for f in /proc/[0-9]*/environ; do cat "$f" >/dev/null 2>&1 && [ "$f" != "/proc/$$/environ" ] && n=$((n+1)); done; echo $n' | tr -d ' ')"
check "reviewer reads the material" code "$(r "cat $m/sub/a.txt")"
check "reviewer cannot write in the material" denied "$(r "touch $m/x 2>/dev/null && echo wrote || echo denied")"
check "reviewer cannot change a material file" denied "$(r "echo x >>$m/sub/a.txt 2>/dev/null && echo wrote || echo denied")"
check "reviewer cannot switch back to the gate uid" denied "$(r 'setpriv --reuid 10001 --regid 10001 --clear-groups true 2>/dev/null && echo switched || echo denied')"
# The paths and modes production uses; a volume made before the fix is 0755.
chmod 755 /var/lib/auto-review /var/lib/auto-review/clones
gate_protect_state_dirs
mkdir -p /var/lib/auto-review/clones/acme-widgets; echo code >/var/lib/auto-review/clones/acme-widgets/f
check "the clone root is 0700 owned by the gate" "700 10001" "$(stat -c '%a %u' /var/lib/auto-review/clones)"
check "the state dir is 0700 owned by the gate" "700 10001" "$(stat -c '%a %u' /var/lib/auto-review)"
check "reviewer cannot read the clone area" unreadable "$(r 'ls /var/lib/auto-review/clones >/dev/null 2>&1 && echo readable || echo unreadable')"
check "reviewer cannot read a file in a clone" unreadable "$(r 'cat /var/lib/auto-review/clones/acme-widgets/f >/dev/null 2>&1 && echo readable || echo unreadable')"
rm -r -f /var/lib/auto-review/clones/acme-widgets
check "reviewer has a writable HOME of its own" ok "$(r 'touch "$HOME/f" && echo ok')"
reviewer_home_remove "$home"
check "the reviewer HOME is gone after reviewer_home_remove" gone "$(reviewer_exec "$home" sh -c '[ -e "$HOME" ] && echo present || echo gone')"
rm -rf "$m" "$t"
exit "$bad"
INNER

if [ "$fail" = 0 ]; then echo "all isolation checks passed"; else echo "ISOLATION CHECKS FAILED"; fi
exit "$fail"
