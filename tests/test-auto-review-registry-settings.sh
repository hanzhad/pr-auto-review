#!/usr/bin/env bash
# Consolidated registry, machine-settings, and skip-flags tests for auto-review
# (upstream issue).
# Consolidates:
#   - test-auto-review-registry.sh
#   - test-auto-review-machine-settings.sh
#   - test-auto-review-skip-flags.sh
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
# Section 1: Repository registry manager (lib/registry.sh + CLI + container)
# ==============================================================================
section_1() (
  # shellcheck disable=SC1091
  . "$here/lib/registry.sh"
  fixtures=$(mktemp -d)
  trap 'rm -rf "$fixtures"' EXIT
  fail=0

  reg_file="$fixtures/projects.json"

  # 1. registry_init
  registry_init "$reg_file"
  check "registry_init: creates file" "0" "$?"
  version="$(jq '.version' "$reg_file")"
  check "registry_init: envelope version 1" "1" "$version"

  # 2. registry_adopt
  registry_adopt "$reg_file" "hanzhad/demo-app" --all
  registry_adopt "$reg_file" "hanzhad/host-repo"
  check "registry_adopt: 2 projects registered" "2" "$(jq '.projects | length' "$reg_file")"
  check "registry_adopt: a new project carries no model, harness, interval or slots" "0" "$(jq '[.projects[] | select(has("model") or has("harness") or has("interval") or has("slots"))] | length' "$reg_file")"
  registry_adopt "$reg_file" "hanzhad/demo-app" --self-review
  check "registry_adopt: a rerun with a flag keeps the other flag" "true true" "$(jq -r '.projects["hanzhad/demo-app"] | "\(.all) \(.self_review)"' "$reg_file")"

  # 3. registry_get
  all="$(registry_get "$reg_file" "hanzhad/demo-app" "all")"
  check "registry_get: demo-app all is true" "true" "$all"
  check "registry_get: host-repo all is false" "false" "$(registry_get "$reg_file" "hanzhad/host-repo" "all")"
  fallback="$(registry_get "$reg_file" "hanzhad/demo-app" "nonexistent" "default_val")"
  check "registry_get: nonexistent key returns default" "default_val" "$fallback"

  # 4. registry_set
  registry_set "$reg_file" "hanzhad/demo-app" "all" 120
  check "registry_set: updates a field" "120" "$(registry_get "$reg_file" "hanzhad/demo-app" "all")"
  registry_set "$reg_file" "hanzhad/demo-app" "all" "true"
  registry_pause "$reg_file" "hanzhad/demo-app" "on hold"
  check "registry_pause: pauses demo-app" "true" "$(registry_get "$reg_file" "hanzhad/demo-app" "paused")"
  check "registry_pause: records the reason" "on hold" "$(registry_get "$reg_file" "hanzhad/demo-app" "paused_reason")"
  check "registry_pause: unregistered repo fails" "1" "$(registry_pause "$reg_file" "nobody/nothing" 2>/dev/null; echo $?)"
  check "registry_resume: unregistered repo fails" "1" "$(registry_resume "$reg_file" "nobody/nothing" 2>/dev/null; echo $?)"

  # 5. registry_list_enabled
  enabled="$(registry_list_enabled "$reg_file")"
  check "registry_list_enabled: the paused project is left out" "hanzhad/host-repo" "$enabled"
  registry_resume "$reg_file" "hanzhad/demo-app"
  check "registry_resume: both projects are listed again" "hanzhad/demo-app hanzhad/host-repo" "$(registry_list_enabled "$reg_file" | sort | tr '\n' ' ' | sed 's/ $//')"
  registry_pause "$reg_file" "hanzhad/demo-app"

  # 6. registry_forget
  registry_forget "$reg_file" "hanzhad/demo-app"
  check "registry_forget: demo-app removed" "1" "$(jq '.projects | length' "$reg_file")"
  check "registry_forget: host-repo remains" "true" "$(jq '.projects | has("hanzhad/host-repo")' "$reg_file")"

  # 7. registry_list --json
  json_out="$(registry_list "$reg_file" --json)"
  check "registry_list --json: output is valid JSON" "1" "$(printf '%s' "$json_out" | jq '.version' 2>/dev/null)"

  # 8. registry_migrate
  mig="$fixtures/mig.json"
  printf '%s' '{"version":1,"model":"opus","projects":{"a/b":{"enabled":true,"model":"x","harness":"y","interval":9,"slots":2,"all":true},"c/d":{"enabled":false}}}' >"$mig"
  mig_log="$(registry_migrate "$mig" 2>&1)"
  check "registry_migrate: per-project settings and enabled are gone" "0" "$(jq '[.projects[] | select(has("enabled") or has("model") or has("harness") or has("interval") or has("slots"))] | length' "$mig")"
  check "registry_migrate: all and the global model stay" "true opus" "$(jq -r '"\(.projects["a/b"].all) \(.model)"' "$mig")"
  check "registry_migrate: enabled false becomes paused" "true" "$(jq '.projects["c/d"].paused' "$mig")"
  check "registry_migrate: one line naming the repository and the keys" "1" "$(printf '%s\n' "$mig_log" | grep dropped | grep -c 'a/b (model, harness, interval, slots)')"
  check "registry_migrate: a second run says nothing" "" "$(registry_migrate "$mig" 2>&1)"

  # 9. Every write is tmp + mv
  wdir="$fixtures/writes"
  mkdir -p "$wdir"
  wreg="$wdir/projects.json"
  registry_init "$wreg"
  registry_adopt "$wreg" "hanzhad/atomic"
  mv_log="$fixtures/mv.log"
  mv() { printf '%s -> %s\n' "${*: -2:1}" "${*: -1}" >>"$mv_log"; command mv "$@"; }
  for step in set adopt forget set_global pause resume init; do
    ino_before="$(stat -c %i "$wreg")"
    : >"$mv_log"
    case "$step" in
      set) registry_set "$wreg" "hanzhad/atomic" "all" 61 ;;
      adopt) registry_adopt "$wreg" "hanzhad/other" ;;
      forget) registry_forget "$wreg" "hanzhad/other" ;;
      set_global) registry_set_global "$wreg" "model" "opus" ;;
      pause) registry_pause "$wreg" "hanzhad/atomic" "why" ;;
      resume) registry_resume "$wreg" "hanzhad/atomic" ;;
      init) rm -f "$wreg"; registry_init "$wreg" ;;
    esac
    src="$(sed -n 's/ -> .*//p' "$mv_log" | tail -1)"
    dst="$(sed -n 's/.* -> //p' "$mv_log" | tail -1)"
    check "tmp+mv ($step): mv onto the registry" "$wreg" "$dst"
    check "tmp+mv ($step): tmp file is a sibling" "$wdir" "$(dirname "${src:-/nowhere}")"
    [ "$step" = init ] || check "tmp+mv ($step): inode replaced, not rewritten in place" "1" "$([ "$ino_before" != "$(stat -c %i "$wreg")" ] && echo 1 || echo 0)"
    check "tmp+mv ($step): no tmp file left behind" "projects.json" "$(ls -A "$wdir")"
    check "tmp+mv ($step): result is valid JSON" "object" "$(jq -r type "$wreg" 2>/dev/null)"
  done
  unset -f mv
  registry_adopt "$wreg" "hanzhad/atomic"

  printf '{ not json' >"$wdir/broken.json"
  cp "$wdir/broken.json" "$wdir/broken.before"
  registry_set "$wdir/broken.json" "hanzhad/atomic" "all" 5 2>/dev/null
  check "registry_set: unreadable registry is left byte for byte" "" "$(cmp "$wdir/broken.json" "$wdir/broken.before" 2>&1)"
  check "registry_set: unknown repo fails" "1" "$(registry_set "$wreg" "nobody/nothing" "all" 5 2>/dev/null; echo $?)"

  # 10. registry_import
  check "registry_import: bad JSON refused" "1" "$(printf '{ nope' | registry_import "$wreg" 2>/dev/null; echo $?)"
  check "registry_import: no projects object refused" "1" "$(printf '{"version":1}' | registry_import "$wreg" 2>/dev/null; echo $?)"
  check "registry_import: refusals leave the old registry" "hanzhad/atomic" "$(registry_list_enabled "$wreg")"
  printf '%s' '{"version":1,"projects":{"acme/new":{"enabled":true}}}' | registry_import "$wreg"
  check "registry_import: good JSON replaces the registry" "acme/new" "$(registry_list_enabled "$wreg")"
  check "registry_import: no tmp file left behind" "broken.before
broken.json
projects.json" "$(ls -A "$wdir")"

  # 11. registry_migrate_legacy
  legacy="$fixtures/legacy.json"
  printf '%s' '{"version":1,"projects":{"old/one":{"enabled":true}}}' >"$legacy"
  newdir="$fixtures/state"
  mkdir -p "$newdir"
  registry_migrate_legacy "$legacy" "$newdir/projects.json" >/dev/null
  check "migrate: legacy copied to the new path" "old/one" "$(registry_list_enabled "$newdir/projects.json")"
  printf '%s' '{"version":1,"projects":{"old/two":{"enabled":true}}}' >"$legacy"
  registry_migrate_legacy "$legacy" "$newdir/projects.json"
  check "migrate: second start does not copy again" "old/one" "$(registry_list_enabled "$newdir/projects.json")"
  registry_pause "$newdir/projects.json" "old/one"
  registry_migrate_legacy "$legacy" "$newdir/projects.json"
  check "migrate: a changed registry is not overwritten" "true" "$(registry_get "$newdir/projects.json" "old/one" "paused")"
  registry_migrate_legacy "$fixtures/absent.json" "$newdir/none.json"
  check "migrate: no legacy file, no registry made" "absent" "$([ -e "$newdir/none.json" ] && echo present || echo absent)"
  printf '{ nope' >"$fixtures/badlegacy.json"
  registry_migrate_legacy "$fixtures/badlegacy.json" "$newdir/bad.json" 2>/dev/null
  check "migrate: invalid legacy file is not copied" "absent" "$([ -e "$newdir/bad.json" ] && echo present || echo absent)"

  # 12. The CLI: set, registry show, registry import
  cli="$here/auto-review.sh"
  cli_reg="$fixtures/cli/projects.json"
  mkdir -p "$fixtures/cli"
  registry_init "$cli_reg"
  registry_adopt "$cli_reg" "hanzhad/cli"
  cli_run() { AUTO_REVIEW_REGISTRY="$cli_reg" bash "$cli" "$@"; }
  cli_run set hanzhad/cli all true >/dev/null 2>&1
  check "auto-review set <repo> <key> <val>: updates the registry" "true" "$(registry_get "$cli_reg" "hanzhad/cli" "all")"
  cli_run set hanzhad/cli skip_bots true >/dev/null 2>&1
  check "auto-review set: boolean value" "true" "$(registry_get "$cli_reg" "hanzhad/cli" "skip_bots")"
  cli_run set hanzhad/cli note hello >/dev/null 2>&1
  check "auto-review set: string value" "hello" "$(registry_get "$cli_reg" "hanzhad/cli" "note")"
  check "auto-review set: unknown repo exits non-zero" "1" "$(cli_run set nobody/nothing all true >/dev/null 2>&1; echo $?)"
  check "auto-review registry show: prints the registry" "hello" "$(cli_run registry show 2>/dev/null | jq -r '.projects["hanzhad/cli"].note')"
  check "auto-review registry import: bad JSON exits non-zero" "1" "$(printf '{ nope' | cli_run registry import >/dev/null 2>&1; echo $?)"
  check "auto-review registry import: bad JSON keeps the registry" "hello" "$(registry_get "$cli_reg" "hanzhad/cli" "note")"
  printf '%s' '{"version":1,"projects":{"acme/in":{"enabled":true}}}' | cli_run registry import >/dev/null 2>&1
  check "auto-review registry import: replaces the registry" "acme/in" "$(registry_list_enabled "$cli_reg")"

  # 13. Container wiring: the registry is a volume, not a checkout
  compose_text="$(cat "$here/docker-compose.yml" 2>/dev/null)"
  check "docker-compose.yml: top-level compose project name is 0-review" "name: 0-review" "$(grep -E '^name: ' "$here/docker-compose.yml" 2>/dev/null | head -1)"
  has "docker-compose.yml: container_name remains auto-review" "$compose_text" "container_name: auto-review"
  has "docker-compose.yml: preserves explicit auto-review-state volume name" "$compose_text" "    name: auto-review-state"
  has "docker-compose.yml: preserves explicit auto-review-clones volume name" "$compose_text" "    name: auto-review-clones"
  has "docker-compose.yml: state volume at /var/lib/auto-review" "$compose_text" "- auto-review-state:/var/lib/auto-review
"
  has "docker-compose.yml: legacy checkout mounted read-only" "$compose_text" ":/etc/auto-review/legacy:ro"
  lacks "docker-compose.yml: checkout is not mounted as config" "$compose_text" "/var/lib/auto-review/config"
  has "docker-compose.yml: registry in the state dir" "$compose_text" "AUTO_REVIEW_REGISTRY=/var/lib/auto-review/projects.json"
  check "tracked example registry exists" "present" "$([ -f "$here/projects.example.json" ] && echo present || echo absent)"
  check "live registry is not tracked" "" "$(git -C "$here" ls-files projects.json 2>/dev/null)"
  check "live registry path is git-ignored" "projects.json" "$(git -C "$here" check-ignore projects.json 2>/dev/null)"

  entrypoint_text="$(cat "$here/entrypoint.sh" 2>/dev/null)"
  has "entrypoint.sh: migrates the legacy registry" "$entrypoint_text" "registry_migrate_legacy"
  has "entrypoint.sh: legacy file under /etc/auto-review/legacy" "$entrypoint_text" "/etc/auto-review/legacy/projects.json"
  lacks "entrypoint.sh: no config-directory path" "$entrypoint_text" "/var/lib/auto-review/config"
  migrates_early=$(awk '/registry_migrate_legacy/{m=1} /case "\$\{1:-daemon\}"/{if(m) print "yes"; exit}' "$here/entrypoint.sh")
  check "entrypoint.sh: migrates before the daemon/CLI case" "yes" "${migrates_early:-no}"
  has "entrypoint.sh: registry subcommand reaches the CLI" "$entrypoint_text" "|registry|"

  exit "$fail"
)

# ==============================================================================
# Section 2: Machine settings, setup, pause/resume, migration, atomic writes
# ==============================================================================
section_2() (
  script="$here/auto-review.sh"
  fx=$(mktemp -d)
  trap 'rm -r -f "$fx"' EXIT
  fail=0

  refused() { # $1 = label, $2 = exit code
    check "$1" 1 "$([ "$2" -ne 0 ] && echo 1 || echo 0)"
  }

  mkdir -p "$fx/bin" "$fx/tokens" "$fx/userhome/.local"
  ln -s "$fx/bin" "$fx/userhome/.local/bin"
  chmod 700 "$fx/tokens"
  reg="$fx/regdir/projects.json"
  export HOME="$fx/userhome"
  export AUTO_REVIEW_REGISTRY="$reg"
  export AUTO_REVIEW_TOKEN_DIR="$fx/tokens"
  export AUTO_REVIEW_LOCK_DIR="$fx/tokens"
  export AUTO_REVIEW_CLONE_ROOT="$fx/clones"
  export AUTO_REVIEW_INSIDE_CONTAINER=1
  export FAKE_GH_LOG="$fx/gh.log"
  export PATH="$fx/bin:$PATH"
  realmv=$(command -v mv)
  export REALMV="$realmv"

  T_HANZHAD="$(printf 'fixture-hanzhad-token-%078d' 1)"
  T_ACME_ORG="$(printf 'fixture-acme-org-token-%077d' 2)"
  T_ACME="$(printf 'fixture-acme-token-%082d' 4)"
  T_OLDREPO="$(printf 'fixture-per-repo-token-%077d' 3)"

  cat >"$fx/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >>"$FAKE_GH_LOG"
hay="$*"
[ "${1:-}" = pr ] && hay="$* pulls"
for w in ${FAKE_GH_DENY:-}; do
  case "$hay" in
    *"$w"*) echo "HTTP 403: Resource not accessible by personal access token" >&2; exit 1 ;;
  esac
done
case "${1:-} ${2:-}" in
  "repo clone")
    git init -q "$4" && git -C "$4" remote add origin "https://github.com/$3.git"
    exit $?
    ;;
  "pr list")
    json="$(jq -n --argjson n "${FAKE_GH_PRS:-0}" '[range(1; $n + 1) | {number: ., headRefOid: "abc\(.)", isDraft: false, author: {login: "someone"}}]')"
    jqx=""
    prev=""
    for a in "$@"; do
      case "$prev" in --jq | -q) jqx="$a" ;; esac
      prev="$a"
    done
    if [ -n "$jqx" ]; then printf '%s' "$json" | jq -r "$jqx"; else printf '%s\n' "$json"; fi
    exit 0
    ;;
esac
echo '{}'
exit 0
GH
  cat >"$fx/bin/mv" <<'MV'
#!/usr/bin/env bash
if [ "${FAKE_MV_FAIL:-0}" = 1 ]; then
  for last; do :; done
  [ "$last" = "$AUTO_REVIEW_REGISTRY" ] && { echo "mv: simulated failure" >&2; exit 1; }
fi
printf '%s\n' "$*" >>"${FAKE_MV_LOG:-/dev/null}"
exec "$REALMV" "$@"
MV
  chmod +x "$fx/bin/gh" "$fx/bin/mv"

  ar() { bash "$script" "$@"; }
  jget() { jq -r "$1" "$reg"; }
  fresh() {
    rm -rf "$fx/regdir" "$fx/clones" "$FAKE_GH_LOG"
    mkdir -p "$fx/regdir"
    rm -f "$fx/tokens"/*
    printf '%s\n' "$T_HANZHAD" >"$fx/tokens/gh-hanzhad.token"
    printf '%s\n' "$T_ACME_ORG" >"$fx/tokens/gh-acme-org.token"
    printf '%s\n' "$T_ACME" >"$fx/tokens/gh-acme.token"
    : >"$FAKE_GH_LOG"
    unset FAKE_GH_DENY FAKE_GH_PRS FAKE_MV_FAIL
  }

  # 1. setup on a fresh machine
  fresh
  export FAKE_GH_PRS=2
  out=$(ar setup acme/web 2>&1); rc=$?
  check "setup acme/web on a fresh machine: exit 0" 0 "$rc"
  check "setup: the project is registered" true "$(jget '.projects["acme/web"] != null')"
  check "setup: not paused" false "$(jget '.projects["acme/web"].paused // false')"
  check "setup: all defaults to false" false "$(jget '.projects["acme/web"].all // false')"
  check "setup: self_review defaults to false" false "$(jget '.projects["acme/web"].self_review // false')"
  check "setup: the review clone exists" yes "$([ -d "$fx/clones/acme-web/.git" ] && echo yes || echo no)"
  check "setup: the clone's marker exists" yes "$([ -f "$fx/clones/clones/acme-web" ] && echo yes || echo no)"
  has "setup: prints the project's list line" "$out" "acme/web"
  has "setup: prints how many PRs the next tick would pick up" "$out" "would pick up 2"
  lacks "setup: a dry pick posts no comment" "$(cat "$FAKE_GH_LOG")" "pr comment"
  lacks "setup: a dry pick posts no review" "$(cat "$FAKE_GH_LOG")" "pr review"
  lacks "setup: a dry pick makes no POST" "$(cat "$FAKE_GH_LOG")" "POST"
  check "setup: after it the project is in the picker's list" "acme/web" \
    "$(bash -c '. "$1"; registry_list_enabled "$2"' _ "$here/lib/registry.sh" "$reg")"

  # 2. flags, and re-running setup to change them
  fresh
  ar setup acme/web --all >/dev/null 2>&1
  check "setup --all: all is true" true "$(jget '.projects["acme/web"].all')"
  check "setup --all: self_review stays false" false "$(jget '.projects["acme/web"].self_review // false')"
  before_entry="$(jget '.projects["acme/web"] | del(.self_review)')"
  ar setup acme/web --self-review >/dev/null 2>&1; rc=$?
  check "setup --self-review on a registered project: exit 0" 0 "$rc"
  check "re-run with --self-review: self_review is true" true "$(jget '.projects["acme/web"].self_review')"
  check "re-run with --self-review: nothing else changed" "$before_entry" "$(jget '.projects["acme/web"] | del(.self_review)')"
  check "re-run: still one project" 1 "$(jget '.projects | length')"

  # 3. the owner's token: one file per resource owner
  fresh
  out=$(ar setup acme-org/web 2>&1); rc=$?
  check "setup acme-org/web: exit 0" 0 "$rc"
  check "setup acme-org/web: gh was called" 1 "$([ -s "$FAKE_GH_LOG" ] && echo 1 || echo 0)"
  check "setup acme-org/web: every gh call used the acme-org token" 0 \
    "$(grep -vc "^$T_ACME_ORG|" "$FAKE_GH_LOG")"
  check "setup acme-org/web: the hanzhad token was never used" 0 "$(grep -c "$T_HANZHAD" "$FAKE_GH_LOG")"
  fresh
  ar setup hanzhad/api >/dev/null 2>&1
  check "setup hanzhad/api: gh was called" 1 "$([ -s "$FAKE_GH_LOG" ] && echo 1 || echo 0)"
  check "setup hanzhad/api: every gh call used the hanzhad token" 0 "$(grep -vc "^$T_HANZHAD|" "$FAKE_GH_LOG")"

  fresh
  rm -f "$fx/tokens/gh-acme.token"
  out=$(ar setup acme/web 2>&1); rc=$?
  refused "setup acme/web without gh-acme.token: refused" $rc
  has "setup without the owner's token: names gh-acme.token" "$out" "gh-acme.token"
  check "setup without the owner's token: no project registered" 0 "$([ -f "$reg" ] && jget '.projects | length' || echo 0)"
  check "setup without the owner's token: no clone" no "$([ -e "$fx/clones/acme-web" ] && echo yes || echo no)"

  printf '%s\n' "$T_OLDREPO" >"$fx/tokens/acme-web.token"
  : >"$FAKE_GH_LOG"
  out=$(ar setup acme/web 2>&1); rc=$?
  check "setup with only the old acme-web.token: exit 0" 0 "$rc"
  has "setup with only the old per-repo token: says so" "$out" "acme-web.token"
  check "setup with only the old per-repo token: every gh call used it" 0 "$(grep -vc "^$T_OLDREPO|" "$FAKE_GH_LOG")"
  check "setup with only the old per-repo token: registered" true "$(jget '.projects["acme/web"] != null')"

  fresh
  printf '%s\n' "$T_OLDREPO" >"$fx/tokens/acme-web.token"
  ar setup acme/web >/dev/null 2>&1
  check "setup with both files: the per-repo token was never used" 0 "$(grep -c "$T_OLDREPO" "$FAKE_GH_LOG")"

  for pair in "/contents:Contents" "/pulls:Pull requests" "/actions/:Actions" "/status:Commit statuses"; do
    frag="${pair%%:*}"
    name="${pair#*:}"
    fresh
    export FAKE_GH_DENY="$frag"
    out=$(ar setup acme/web 2>&1); rc=$?
    unset FAKE_GH_DENY
    refused "setup, token lacks $name: refused" $rc
    has "setup, token lacks $name: the message names it" "$out" "$name"
    has "setup, token lacks $name: the message names the owner's token file" "$out" "gh-acme.token"
    check "setup, token lacks $name: nothing registered" 0 "$([ -f "$reg" ] && jget '.projects | length' || echo 0)"
    check "setup, token lacks $name: no clone" no "$([ -e "$fx/clones/acme-web" ] && echo yes || echo no)"
  done
  fresh
  export FAKE_GH_DENY="/actions/"
  ar setup acme/web >/dev/null 2>&1
  unset FAKE_GH_DENY
  check "setup, token lacks Actions: no marker" no "$([ -e "$fx/clones/clones/acme-web" ] && echo yes || echo no)"

  # 4. adopt alias
  fresh
  out=$(ar adopt acme/web 2>&1); rc=$?
  check "adopt acme/web: exit 0" 0 "$rc"
  has "adopt: prints the new name" "$out" "setup"
  check "adopt: registers the project like setup" true "$(jget '.projects["acme/web"] != null')"

  # 5. per-project machine settings are refused
  fresh
  ar setup acme/web >/dev/null 2>&1
  for kv in model:opus harness:agy interval:60 slots:3; do
    key="${kv%%:*}"
    val="${kv#*:}"
    before=$(cat "$reg")
    out=$(ar set acme/web "$key" "$val" 2>&1); rc=$?
    refused "set <repo> $key $val: refused" $rc
    has "set <repo> $key: points to set-global" "$out" "set-global"
    check "set <repo> $key: registry byte-identical" "$before" "$(cat "$reg")"
  done

  for kv in enabled:false paused:true; do
    key="${kv%%:*}"
    val="${kv#*:}"
    before=$(cat "$reg")
    out=$(ar set acme/web "$key" "$val" 2>&1); rc=$?
    refused "set <repo> $key $val: refused" $rc
    has "set <repo> $key: points to pause" "$out" "pause acme/web"
    check "set <repo> $key: registry byte-identical" "$before" "$(cat "$reg")"
  done

  # 6. CLI migration
  old_registry() {
    cat >"$reg" <<'JSON'
{
  "version": 1,
  "harness": "claude-code",
  "model": "sonnet",
  "projects": {
    "acme/web": {"enabled": true, "interval": 120, "model": "opus", "harness": "claude-code",
                 "slots": 3, "adopted_at": "2026-10-01T00:00:00Z", "all": true,
                 "self_review": true, "skip_labels": ["wip"]},
    "acme/off": {"enabled": false, "interval": 300, "adopted_at": "2026-10-02T00:00:00Z"}
  }
}
JSON
  }
  fresh
  old_registry
  out=$(ar list 2>&1); rc=$?
  check "migration: list on an old registry exits 0" 0 "$rc"
  for k in model harness interval slots; do
    check "migration: no project keeps $k" 0 "$(jget "[.projects[] | select(has(\"$k\"))] | length")"
  done
  check "migration: the global model stays" sonnet "$(jget .model)"
  check "migration: the global harness stays" claude-code "$(jget .harness)"
  check "migration: all stays" true "$(jget '.projects["acme/web"].all')"
  check "migration: self_review stays" true "$(jget '.projects["acme/web"].self_review')"
  check "migration: skip_labels stays" wip "$(jget '.projects["acme/web"].skip_labels[0]')"
  check "migration: adopted_at stays" 2026-10-01T00:00:00Z "$(jget '.projects["acme/web"].adopted_at')"
  check "migration: enabled true is not paused" false "$(jget '.projects["acme/web"].paused // false')"
  check "migration: enabled false is paused" true "$(jget '.projects["acme/off"].paused')"
  check "migration: the paused project has a paused_at" string "$(jget '.projects["acme/off"].paused_at | type')"
  check "migration: the enabled key is gone" 0 "$(jget '[.projects[] | select(has("enabled"))] | length')"
  dropped="$(printf '%s\n' "$out" | grep -i 'dropped')"
  check "migration: exactly one line says what was dropped" 1 "$(printf '%s\n' "$dropped" | grep -c .)"
  for w in model harness interval slots acme/web; do
    has "migration: the dropped line names $w" "$dropped" "$w"
  done
  after=$(cat "$reg")
  out=$(ar list 2>&1)
  check "migration: a second run logs no dropped line" 0 "$(printf '%s\n' "$out" | grep -ci 'dropped')"
  check "migration: a second run changes nothing" "$after" "$(cat "$reg")"
  fresh
  ar setup acme/web >/dev/null 2>&1
  check "a registry made by setup logs no dropped line" 0 "$(ar list 2>&1 | grep -ci 'dropped')"

  # 7. pause and resume
  picker() { bash -c '. "$1"; registry_list_enabled "$2"' _ "$here/lib/registry.sh" "$reg" | sort | tr '\n' ' ' | sed 's/ $//'; }
  fresh
  ar setup acme/web --all --self-review >/dev/null 2>&1
  ar setup acme/api >/dev/null 2>&1
  out=$(ar pause acme/web --reason "maintenance window" 2>&1); rc=$?
  check "pause --reason: exit 0" 0 "$rc"
  check "pause: paused is true" true "$(jget '.projects["acme/web"].paused')"
  check "pause: paused_at is a timestamp" string "$(jget '.projects["acme/web"].paused_at | type')"
  check "pause: the reason is recorded" "maintenance window" "$(jget '.projects["acme/web"].paused_reason')"
  check "pause: all is kept" true "$(jget '.projects["acme/web"].all')"
  check "pause: self_review is kept" true "$(jget '.projects["acme/web"].self_review')"
  check "pause: the project is still registered" true "$(jget '.projects["acme/web"] != null')"
  check "pause: the clone is kept" yes "$([ -d "$fx/clones/acme-web/.git" ] && echo yes || echo no)"
  check "pause: the marker is kept" yes "$([ -f "$fx/clones/clones/acme-web" ] && echo yes || echo no)"
  check "pause: other projects are unaffected" false "$(jget '.projects["acme/api"].paused // false')"
  check "pause: the picker's list drops the paused project" "acme/api" "$(picker)"
  lst="$(ar list 2>&1)"
  has "list shows that a project is paused" "$lst" "paused"
  has "list shows the reason" "$lst" "maintenance window"
  check "list --json carries paused" true "$(ar list --json 2>/dev/null | jq '.projects["acme/web"].paused')"
  out=$(ar pause acme/nothere 2>&1); rc=$?
  refused "pause of an unregistered repo: refused" $rc
  has "pause of an unregistered repo: names it" "$out" "acme/nothere"
  ar resume acme/web >/dev/null 2>&1; rc=$?
  check "resume: exit 0" 0 "$rc"
  check "resume: not paused" false "$(jget '.projects["acme/web"].paused // false')"
  check "resume: paused_at is gone" null "$(jget '.projects["acme/web"].paused_at')"
  check "resume: the reason is gone" null "$(jget '.projects["acme/web"].paused_reason')"
  check "resume: all is kept" true "$(jget '.projects["acme/web"].all')"
  check "resume: both projects are in the picker's list again" "acme/api acme/web" "$(picker)"
  out=$(ar resume acme/nothere 2>&1); rc=$?
  refused "resume of an unregistered repo: refused" $rc
  ar pause acme/api >/dev/null 2>&1
  check "pause without --reason: paused" true "$(jget '.projects["acme/api"].paused')"
  check "pause without --reason: no reason recorded" "" "$(jget '.projects["acme/api"].paused_reason // ""')"

  # 8. CLI registry writes are atomic
  fresh
  ar setup acme/web >/dev/null 2>&1
  export FAKE_MV_LOG="$fx/mv.log"
  : >"$FAKE_MV_LOG"
  ar pause acme/web >/dev/null 2>&1
  mvline="$(grep -F " $reg" "$FAKE_MV_LOG" | tail -n 1)"
  check "pause: the registry is replaced by an mv" 1 "$([ -n "$mvline" ] && echo 1 || echo 0)"
  src="$(printf '%s' "$mvline" | sed 's/^-[a-zA-Z]* //; s/ .*$//')"
  check "pause: the temp file is in the registry's own directory" "$(dirname "$reg")" "$(dirname "$src")"
  check "pause: the temp file is not the registry" 1 "$([ "$src" != "$reg" ] && echo 1 || echo 0)"
  unset FAKE_MV_LOG
  lsdir() { ls -A "$(dirname "$reg")" | tr '\n' ' '; }
  files_before="$(lsdir)"
  before=$(cat "$reg")
  export FAKE_MV_FAIL=1
  ar pause acme/web --reason x >/dev/null 2>&1; rc=$?
  refused "pause with a failing mv: non-zero" $rc
  check "pause with a failing mv: registry byte-identical" "$before" "$(cat "$reg")"
  check "pause with a failing mv: no temp file left" "$files_before" "$(lsdir)"
  unset FAKE_MV_FAIL
  ar pause acme/web --reason x >/dev/null 2>&1; rc=$?
  check "pause without the failing mv (control): exit 0" 0 "$rc"
  check "pause without the failing mv (control): paused" true "$(jget '.projects["acme/web"].paused')"
  before=$(cat "$reg")
  export FAKE_MV_FAIL=1
  ar resume acme/web >/dev/null 2>&1; rc=$?
  refused "resume with a failing mv: non-zero" $rc
  check "resume with a failing mv: registry byte-identical" "$before" "$(cat "$reg")"
  check "resume with a failing mv: no temp file left" "$files_before" "$(lsdir)"
  unset FAKE_MV_FAIL
  ar resume acme/web >/dev/null 2>&1; rc=$?
  check "resume without the failing mv (control): exit 0" 0 "$rc"
  check "resume without the failing mv (control): resumed" false "$(jget '.projects["acme/web"].paused // false')"
  fresh
  export FAKE_MV_FAIL=1
  ar setup acme/web >/dev/null 2>&1; rc=$?
  unset FAKE_MV_FAIL
  refused "setup with a failing mv: non-zero" $rc
  check "setup with a failing mv: no registry appeared" no "$([ -e "$reg" ] && echo yes || echo no)"
  check "setup with a failing mv: no temp file left" 0 "$(ls -A "$(dirname "$reg")" | wc -l | tr -d ' ')"
  ar setup acme/web >/dev/null 2>&1; rc=$?
  check "setup without the failing mv (control): exit 0" 0 "$rc"
  check "setup without the failing mv (control): registered" true "$(jget '.projects["acme/web"] != null')"
  fresh
  old_registry
  before=$(cat "$reg")
  files_before="$(lsdir)"
  export FAKE_MV_FAIL=1
  ar list >/dev/null 2>&1
  unset FAKE_MV_FAIL
  check "migration with a failing mv: the old registry is byte-identical" "$before" "$(cat "$reg")"
  check "migration with a failing mv: no temp file left" "$files_before" "$(lsdir)"
  ar list >/dev/null 2>&1
  check "migration without the failing mv (control): migrated" 0 "$(jget '[.projects[] | select(has("model"))] | length')"
  check "migration without the failing mv (control): acme/off paused" true "$(jget '.projects["acme/off"].paused')"

  exit "$fail"
)

# ==============================================================================
# Section 3: no-review label and registry skip_branches/bots/labels/skip_if_only
# ==============================================================================
section_3() (
  script="$here/auto-review.sh"
  registry_lib="$here/lib/registry.sh"
  fixtures=$(mktemp -d)
  trap 'rm -r -f "$fixtures"' EXIT
  fail=0

  flags_lacks() {
    case "$2" in
      *--skip-label*) lacks "$1" "$2" "$3" ;;
      *) printf 'FAIL  %s\n--- no flags printed\n--- got\n%s\n' "$1" "$2"; fail=1 ;;
    esac
  }

  n=0
  tick_with_labels() {
    labels=$1; shift
    n=$((n + 1))
    root="$fixtures/t$n"
    home="$root/home"; xdg="$root/run"; repo="$root/repo"
    origin_repo="$root/github.com/acme/widgets.git"
    calls="$root/gh-calls"; ran="$root/reviewer-ran"
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
    : >"$calls"

    cat >"$home/.local/bin/gh" <<'FAKE'
#!/bin/sh
echo "gh $*" >>"$FAKE_CALLS"
case "$*" in
  "api user -q .login") echo tester ;;
  "pr list "*)
    printf '7\tabc1234abc1234abc1234abc1234abc1234abc12\tmain\tfalse\tfalse\tauthor\tfeature\t%s\tSome change\n' "$FAKE_LABELS"
    ;;
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
      PATH="$home/.local/bin:$PATH" FAKE_CALLS="$calls" FAKE_RAN="$ran" FAKE_LABELS="$labels" \
      "$script" tick "$repo" --all "$@" 2>&1)
    rc=$?
  }

  posted() {
    grep -E 'pr review|pr comment|pr edit|issue comment|-X (POST|PATCH|PUT)|--method (POST|PATCH|PUT)| -[fF] |--input' "$calls" 2>/dev/null
  }
  touched_pr7() {
    grep -v -E '^gh (pr list|api user)' "$calls" 2>/dev/null | grep -E '(^| |/)7( |/|$)'
  }

  tick_with_labels "no-review" --skip-label no-review
  check "fixture: explicit --skip-label no-review: tick exits 0" 0 "$rc"
  has "fixture: explicit --skip-label no-review: log names the label" "$out" "#7 is labelled no-review"

  tick_with_labels "no-review"
  check "no flag: tick exits 0" 0 "$rc"
  has "no flag: log says #7 is labelled no-review" "$out" "#7 is labelled no-review"
  has "no flag: log says skipping" "$out" "skipping"

  check "no flag: no reviewer launched" "absent" "$([ -e "$ran" ] && echo present || echo absent)"
  check "no flag: nothing posted to the PR" "" "$(posted)"
  check "no flag: no call touches #7 beyond the listing" "" "$(touched_pr7)"

  tick_with_labels "bug"$'\037'"no-review"
  has "no-review among other labels still skips" "$out" "#7 is labelled no-review"
  tick_with_labels "bug"
  lacks "unrelated label does not skip" "$out" "#7 is labelled"

  check "lib/registry.sh defines registry_tick_flags" "registry_tick_flags" \
    "$(bash -c '. "$1"; declare -F registry_tick_flags' _ "$registry_lib" 2>/dev/null || echo missing)"

  flags() { bash -c '. "$1"; registry_tick_flags "$2" "$3"' _ "$registry_lib" "$1" "$2" 2>&1; }
  reg() { printf '%s\n' "$2" >"$fixtures/$1.json"; printf '%s' "$fixtures/$1.json"; }
  W=acme/widgets
  DEFAULT=$(printf -- '--skip-label\nno-review')

  r=$(reg defaults '{"version":1,"harness":"claude-code","projects":{"acme/widgets":{"enabled":true}}}')
  check "defaults: only --skip-label no-review" "$DEFAULT" "$(flags "$r" $W)"

  r=$(reg project-branches '{"version":1,"projects":{"acme/widgets":{"enabled":true,"skip_branches":["release/*","dependabot/**"]}}}')
  got=$(flags "$r" $W)
  has "project skip_branches: first glob" "$got" "$(printf -- '--skip-branch\nrelease/*')"
  has "project skip_branches: second glob" "$got" "$(printf -- '--skip-branch\ndependabot/**')"
  has "project skip_branches: label default kept" "$got" "$DEFAULT"

  r=$(reg project-bots '{"version":1,"projects":{"acme/widgets":{"enabled":true,"skip_bots":true}}}')
  has "project skip_bots true: --skip-bots" "$(flags "$r" $W)" "--skip-bots"

  r=$(reg project-bots-false '{"version":1,"skip_bots":true,"projects":{"acme/widgets":{"enabled":true,"skip_bots":false}}}')
  check "project skip_bots false overrides global true: flags are the default" "$DEFAULT" "$(flags "$r" $W)"

  r=$(reg global '{"version":1,"skip_branches":["release/*"],"skip_bots":true,"skip_if_only":["**/*.md","tests/**"],"projects":{"acme/widgets":{"enabled":true}}}')
  got=$(flags "$r" $W)
  has "global skip_branches applies when the project has none" "$got" "$(printf -- '--skip-branch\nrelease/*')"
  has "global skip_bots applies when the project has none" "$got" "--skip-bots"
  has "global skip_if_only: first glob" "$got" "$(printf -- '--skip-if-only\n**/*.md')"
  has "global skip_if_only: second glob" "$got" "$(printf -- '--skip-if-only\ntests/**')"

  r=$(reg override '{"version":1,"skip_branches":["release/*"],"skip_if_only":["**/*.md"],"projects":{"acme/widgets":{"enabled":true,"skip_branches":["hotfix/*"],"skip_if_only":["docs/**"]}}}')
  got=$(flags "$r" $W)
  has "project skip_branches wins over global" "$got" "$(printf -- '--skip-branch\nhotfix/*')"
  has "project skip_if_only wins over global" "$got" "$(printf -- '--skip-if-only\ndocs/**')"
  flags_lacks "global skip_branches is replaced, not merged" "$got" "release/*"
  flags_lacks "global skip_if_only is replaced, not merged" "$got" "**/*.md"

  r=$(reg labels '{"version":1,"projects":{"acme/widgets":{"enabled":true,"skip_labels":["wip","hold"]}}}')
  got=$(flags "$r" $W)
  has "project skip_labels: wip" "$got" "$(printf -- '--skip-label\nwip')"
  has "project skip_labels: hold" "$got" "$(printf -- '--skip-label\nhold')"

  r=$(reg other-repo '{"version":1,"projects":{"acme/widgets":{"enabled":true,"skip_branches":["release/*"]},"acme/other":{"enabled":true}}}')
  check "a different project does not get this one skip_branches" "$DEFAULT" "$(flags "$r" acme/other)"

  check "the machine tick (what the entrypoint runs) calls registry_tick_flags" "called" \
    "$(grep -q 'registry_tick_flags' "$here/lib/machine-tick.sh" && echo called || echo not-called)"

  exit "$fail"
)

run_sections_parallel section_1 section_2 section_3
exit $?
