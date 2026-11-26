#!/usr/bin/env bash
# The machine tick (upstream issue): `auto-review.sh tick` with no path.
# One pass over every registered project that is not paused; up to `parallel`
# reviews at once, `slots` started in all, picked by lib/scheduler.sh.
#
# Needs the rest of auto-review.sh in scope (parse_flags, review_pr_in_worktree,
# collect_pending, ...) and runs under its `set -euo pipefail`.

machine_state_dir() {
  printf '%s\n' "${AUTO_REVIEW_STATE_DIR:-$(dirname "$REGISTRY_DEFAULT_FILE")/tick-state}"
}

# The daemon.lock the legacy daemon takes too: a file holding a pid, so a tick
# and the old loop exclude each other. A dead pid's lock is cleared.
MACHINE_LOCK=""
machine_lock_take() {
  local lock="${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}/daemon.lock" pid
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  if ! (set -o noclobber; echo $$ >"$lock") 2>/dev/null; then
    pid="$(cat "$lock" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "another tick is running (pid $pid), skipping"
      return 1
    fi
    log "clearing a stale lock (pid ${pid:-unknown} is gone)"
    rm -f "$lock"
    (set -o noclobber; echo $$ >"$lock") 2>/dev/null || return 1
  fi
  MACHINE_LOCK="$lock"
}

# Prints the readable token file path for $repo (gh-<owner>.token, then <slug>.token).
machine_token_file() {
  local repo="$1" slug file
  slug="$(printf '%s' "$repo" | tr '/' '-')"
  file="$TOKEN_DIR/gh-${repo%%/*}.token"
  [ -r "$file" ] || file="$TOKEN_DIR/$slug.token"
  [ -r "$file" ] || return 1
  printf '%s\n' "$file"
}

# A project's own settings and token, in the calling (sub)shell: flags the way
# the registry sets them, GH_TOKEN of the owner. rc 1 when there is no token.
machine_project_setup() {
  local repo="$1" reg="$REGISTRY_DEFAULT_FILE" slug file all sr line cache
  local flags=()
  slug="$(printf '%s' "$repo" | tr '/' '-')"
  if ! file="$(machine_token_file "$repo")"; then
    log "no token for $repo — skipping it"
    return 1
  fi
  GH_TOKEN="$(tr -d '[:space:]' <"$file")"
  MACHINE_TOKEN_FILE="$file"
  export GH_TOKEN MACHINE_TOKEN_FILE
  # Worked out once, by the listing, and read back by the workers: a worker that
  # starts when another ends is on the critical path, and this is eight jq runs.
  cache="${MACHINE_WORK:+$MACHINE_WORK/flags.$slug}"
  if [ -n "$cache" ] && [ -f "$cache" ]; then
    while IFS= read -r line; do [ -z "$line" ] || flags+=("$line"); done <"$cache"
  else
    all="$(registry_get "$reg" "$repo" all "$(registry_get_global "$reg" all false)")"
    sr="$(registry_get "$reg" "$repo" self_review "$(registry_get_global "$reg" self_review false)")"
    case "$all" in true | 1) flags+=(--all) ;; esac
    case "$sr" in true | 1) flags+=(--self-review) ;; esac
    while IFS= read -r line; do
      [ -n "$line" ] && flags+=("$line")
    done < <(registry_tick_flags "$reg" "$repo")
    if [ -n "$cache" ]; then printf '%s\n' ${flags[@]+"${flags[@]}"} >"$cache"; fi
  fi
  parse_flags ${flags[@]+"${flags[@]}"}
}

# Fingerprint of a token file as mtime:size:inode (empty if stat fails).
machine_token_fingerprint() {
  local file="$1"
  stat -c '%Y:%s:%i' "$file" 2>/dev/null \
    || stat -f '%m:%z:%i' "$file" 2>/dev/null \
    || true
}

# Resolves the GitHub login for $owner using $state_dir/login.<owner>,
# keyed by token_file fingerprint. Only caches non-empty successful lookups.
machine_resolve_login() {
  local owner="$1" token_file="$2" state_dir="$3" err_tmp="$4"
  local fp cache_file cached_fp="" cached_me="" me tmp
  fp="$(machine_token_fingerprint "$token_file")"
  cache_file="$state_dir/login.$owner"
  if [ -n "$fp" ] && [ -r "$cache_file" ]; then
    IFS=' ' read -r cached_fp cached_me <"$cache_file" || true
    if [ "$cached_fp" = "$fp" ] && [ -n "$cached_me" ]; then
      printf '%s\n' "$cached_me"
      return 0
    fi
  fi
  me="$(gh api user -q .login 2>"$err_tmp")" || return 1
  [ -n "$me" ] || return 1
  if [ -n "$fp" ]; then
    mkdir -p "$state_dir" 2>/dev/null || true
    if tmp="$(mktemp "$cache_file.tmp.XXXXXX" 2>/dev/null)"; then
      printf '%s %s\n' "$fp" "$me" >"$tmp" && mv -f "$tmp" "$cache_file" || rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  printf '%s\n' "$me"
}

# Pure parser: /rate_limit JSON -> "<cr>\t<cl>\t<ct>\t<gr>\t<gl>\t<gt>\t<throttled>\t<paused>".
machine_rate_limit_parse() {
  local raw="$1" cr cl ct gr gl gt throttled="false" paused="false"
  local parsed
  parsed="$(printf '%s' "$raw" | jq -r '[
    (.resources.core.remaining // empty),
    (.resources.core.limit // empty),
    (.resources.core.reset // empty),
    (.resources.graphql.remaining // empty),
    (.resources.graphql.limit // empty),
    (.resources.graphql.reset // empty)
  ] | @tsv' 2>/dev/null || true)"
  [ -n "$parsed" ] || return 1
  IFS=$'\t' read -r cr cl ct gr gl gt <<<"$parsed"
  case "$cr:$cl:$ct:$gr:$gl:$gt" in
    *[!0-9:]*) return 1 ;;
  esac
  [ -n "$cr" ] && [ -n "$cl" ] && [ -n "$ct" ] && [ -n "$gr" ] && [ -n "$gl" ] && [ -n "$gt" ] || return 1
  if [ "$cr" -lt 500 ] || [ "$gr" -lt 500 ]; then
    throttled="true"
  fi
  if [ "$cr" -lt 150 ] || [ "$gr" -lt 150 ]; then
    paused="true"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cr" "$cl" "$ct" "$gr" "$gl" "$gt" "$throttled" "$paused"
}

MACHINE_RATE_LIMIT_PAUSED_FILES=""

machine_repo_rate_limited() {
  local repo="$1" file
  [ -n "${MACHINE_RATE_LIMIT_PAUSED_FILES:-}" ] || return 1
  file="$(machine_token_file "$repo" || true)"
  [ -n "$file" ] || return 1
  case "$MACHINE_RATE_LIMIT_PAUSED_FILES" in
    *"|$file|"*) return 0 ;;
  esac
  return 1
}

# Queries GET /rate_limit once per distinct token file, updates status.json,
# pauses individual repos whose token is <150, and returns 1 when all
# token-bearing repos are paused.
machine_check_rate_limit() {
  local repo file token raw parsed cr cl ct gr gl gt throttled paused
  local seen_files="" any_throttled="false" have_metrics=0
  local best_min="" best_cr=0 best_cl=0 best_ct=0 best_gr=0 best_gl=0 best_gt=0
  local cur_min paused_repos=0 active_repos=0
  MACHINE_RATE_LIMIT_PAUSED_FILES=""
  for repo in "$@"; do
    file="$(machine_token_file "$repo" || true)"
    [ -n "$file" ] || continue
    case "$seen_files" in
      *"|$file|"*) continue ;;
    esac
    seen_files="${seen_files}|${file}|"
    token="$(tr -d '[:space:]' <"$file")"
    raw="$(GH_TOKEN="$token" gh api /rate_limit 2>/dev/null || true)"
    [ -n "$raw" ] || continue
    parsed="$(machine_rate_limit_parse "$raw")" || continue
    IFS=$'\t' read -r cr cl ct gr gl gt throttled paused <<<"$parsed"
    [ "$throttled" = "true" ] && any_throttled="true"
    cur_min="$cr"
    [ "$gr" -lt "$cur_min" ] && cur_min="$gr"
    if [ "$have_metrics" -eq 0 ] || [ "$cur_min" -lt "$best_min" ]; then
      have_metrics=1
      best_min="$cur_min"
      best_cr="$cr"; best_cl="$cl"; best_ct="$ct"
      best_gr="$gr"; best_gl="$gl"; best_gt="$gt"
    fi
    if [ "$paused" = "true" ]; then
      MACHINE_RATE_LIMIT_PAUSED_FILES="${MACHINE_RATE_LIMIT_PAUSED_FILES}|${file}|"
      log "GitHub API rate limit too low for $file (core=${cr}/${cl}, graphql=${gr}/${gl}) — pausing repos using it"
    fi
  done
  if [ "$have_metrics" -eq 1 ]; then
    status_rate_limit_set "$best_cr" "$best_cl" "$best_ct" "$best_gr" "$best_gl" "$best_gt" "$any_throttled"
  fi
  for repo in "$@"; do
    file="$(machine_token_file "$repo" || true)"
    [ -n "$file" ] || continue
    if machine_repo_rate_limited "$repo"; then
      paused_repos=$((paused_repos + 1))
      status_tick_error_set "$repo" "rate_limited" "GitHub API rate limit too low"
    else
      active_repos=$((active_repos + 1))
    fi
  done
  if [ "$paused_repos" -gt 0 ] && [ "$active_repos" -eq 0 ]; then
    log "GitHub API rate limit too low (core=${best_cr}/${best_cl}, graphql=${best_gr}/${best_gl}) — pausing repo scan"
    status_tick_error_set "_global" "rate_limited" "GitHub API rate limit too low (core=${best_cr}/${best_cl}, graphql=${best_gr}/${best_gl})"
    return 1
  fi
  return 0
}

# Appends "<repo> <pr>" lines, oldest first, to $2, and leaves the project's
# clone fetched. Runs in a subshell: a die only costs this project.
machine_list_project() {
  local repo="$1" out="$2" me open_prs slug err_tmp err_msg err_kind
  slug="$(printf '%s' "$repo" | tr '/' '-')"
  if ! machine_project_setup "$repo"; then
    status_tick_error_set "$repo" "token_invalid" "no token for $repo"
    return 0
  fi
  err_tmp="$(mktemp)"
  if ! me="$(machine_resolve_login "${repo%%/*}" "$MACHINE_TOKEN_FILE" "$(machine_state_dir)" "$err_tmp")"; then
    err_msg="$(cat "$err_tmp" 2>/dev/null || true)"
    rm -f "$err_tmp"
    log "$repo: the token is not valid — skipping it"
    status_tick_error_set "$repo" "token_invalid" "${err_msg:-the token is not valid}"
    return 0
  fi
  local list_args=(--repo "$repo" --state open --limit "$LIST_LIMIT" --json number,headRefOid,headRefName,baseRefName,isDraft,title,author,labels,reviews)
  [ "$REVIEW_ALL" = 1 ] || list_args+=(--assignee "@me")
  # The count of this account's reviews that are not dismissed rides in the same
  # listing, so noticing a dismissal costs no call of its own.
  if ! open_prs="$(gh pr list "${list_args[@]}" \
    -q '.[] | [.number, .headRefOid, .baseRefName, (.isDraft | tostring), (.author.is_bot | tostring), .author.login, .headRefName, ([.labels[].name] | join("\u001f")), ([.reviews[] | select(.author.login == "'"$me"'" and .state != "DISMISSED")] | length), .title] | @tsv' 2>"$err_tmp" |
    tr '\t' '\035')"; then
    err_msg="$(cat "$err_tmp" 2>/dev/null || true)"
    rm -f "$err_tmp"
    case "$err_msg" in
      *'Could not resolve'* | *'dial tcp'* | *'timed out'* | *'timeout'* | *'connection refused'* | *'network'* | *'EOF'* | *'TLS'* | *'HTTP 50'[234]*)
        err_kind="network" ;;
      *) err_kind="list_failed" ;;
    esac
    log "$repo: could not list pull requests — skipping it"
    status_tick_error_set "$repo" "$err_kind" "${err_msg:-could not list pull requests}"
    return 0
  fi
  if [ -z "$open_prs" ]; then
    rm -f "$err_tmp"
    status_tick_error_clear "$repo"
    return 0
  fi
  collect_pending "$repo" "$me" "$open_prs"
  decision_prune "$repo" "$open_prs"
  if [ -z "$PENDING_PRS" ]; then
    rm -f "$err_tmp"
    status_tick_error_clear "$repo"
    return 0
  fi
  log "$repo: $(printf '%s\n' "$PENDING_PRS" | wc -l | tr -d ' ') need a review"
  if ! (review_clone_prepare "$repo" "$slug") 2>"$err_tmp"; then
    err_msg="$(cat "$err_tmp" 2>/dev/null || true)"
    rm -f "$err_tmp"
    log "$repo: the review clone is not usable — skipping it"
    status_tick_error_set "$repo" "clone_failed" "${err_msg:-the review clone is not usable}"
    return 0
  fi
  rm -f "$err_tmp"
  status_tick_error_clear "$repo"
  printf '%s\n' "$PENDING_PRS" | sort -n | sed "s|^|$repo |" >>"$out"
}

# One review, as a background job of the tick. $1 = repo, $2 = pr.
machine_review_worker() {
  local repo="$1" pr="$2" slug clone wt=""
  slug="$(printf '%s' "$repo" | tr '/' '-')"
  clone="$CLONE_ROOT/$slug"
  log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $repo $*"; }
  # However the worker ends: its entry leaves the list and its worktree goes.
  trap 'machine_worker_done "$repo" "$pr" "$clone" "$wt"' EXIT
  machine_project_setup "$repo" || exit 0
  PR_LISTED_SHA="$(cat "$MACHINE_WORK/head.$slug-$pr" 2>/dev/null || echo "")"
  REVIEW_POSTED_SHA=""
  if ! wt="$(worktree_add "$clone" "$pr")"; then
    log "#$pr: cannot add a worktree, skipping"
    status_record_result "$repo" "$pr" "${PR_LISTED_SHA:-}" "failed" "worktree_add_failed" "" "cannot add a worktree" "true"
    exit 0
  fi
  log "#$pr: checking out"
  review_pr_in_worktree "$pr" "$wt" || true
  if [ -n "$REVIEW_POSTED_SHA" ]; then
    # One more live review than the listing showed, which is the one just posted.
    local before
    before="$(cat "$MACHINE_WORK/count.$slug-$pr" 2>/dev/null || echo 0)"
    decision_remember "$repo" "$pr" "$REVIEW_POSTED_SHA" "$((before + 1))"
  fi
  exit 0
}

machine_worker_done() {
  local repo="$1" pr="$2" clone="$3" wt="$4"
  trap - EXIT
  cd "$clone" 2>/dev/null || cd /
  [ -z "$wt" ] || worktree_remove "$clone" "$wt"
  if status_active_has "$repo" "$pr"; then
    status_locked status_active_remove_locked "$repo" "$pr" aborted "" "aborted" "" "review worker aborted" "true" || true
  fi
  return 0
}

# Rebuilds $1/jobs ("<pid> <repo>") and $1/running from the workers alive.
machine_reap() {
  local work="$1" pid repo
  : >"$work/jobs.new"
  while read -r pid repo; do
    if kill -0 "$pid" 2>/dev/null; then echo "$pid $repo" >>"$work/jobs.new"; fi
  done <"$work/jobs"
  mv -f "$work/jobs.new" "$work/jobs"
  awk '{ print $2 }' "$work/jobs" >"$work/running"
}

MACHINE_WORK=""
machine_cleanup() {
  local pid repo
  trap - EXIT INT TERM
  if [ -n "$MACHINE_WORK" ] && [ -f "$MACHINE_WORK/jobs" ]; then
    while read -r pid repo; do kill "$pid" 2>/dev/null || true; done <"$MACHINE_WORK/jobs"
    wait 2>/dev/null || true
    rm -rf "$MACHINE_WORK"
  fi
  [ -z "$MACHINE_LOCK" ] || rm -f "$MACHINE_LOCK"
  [ -z "${MACHINE_ACTIVE:-}" ] || status_active_reset
  return 0
}

cmd_machine_tick() {
  local reg="$REGISTRY_DEFAULT_FILE" state parallel slots workers repo pick pr
  local repos=() started=0 work
  [ -f "$reg" ] || {
    log "no registry at $reg — nothing to do"
    return 0
  }
  command -v gh >/dev/null || die "gh is not on PATH"
  command -v claude >/dev/null || die "claude is not on PATH"
  command -v jq >/dev/null || die "jq is not on PATH — the reviewer's output is read as JSON"
  if [ -z "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] && [ ! -f /.dockerenv ] && [ "$OS" = Linux ]; then
    command -v bwrap >/dev/null || die "bwrap is not on PATH — the reviewer does not run without it"
  fi
  while IFS= read -r repo; do
    [ -n "$repo" ] && repos+=("$repo")
  done < <(registry_list_enabled "$reg")
  if [ "${#repos[@]}" -eq 0 ]; then
    log "no project to review"
    return 0
  fi
  parallel="$(sched_parallel "$reg")"
  slots="$(sched_slots "$reg")"
  workers="$(sched_workers "$parallel")"
  local interval_s
  interval_s="$(status_interval_s "$reg")"
  if [ "$workers" -lt 1 ]; then
    log "available memory is below the floor — starting no review this tick"
    status_tick_error_set "_global" "memory_floor" "available memory is below the floor — starting no review this tick"
    return 0
  fi
  machine_lock_take || return 0
  trap machine_cleanup EXIT INT TERM
  status_tick_error_clear "_global"
  if ! machine_check_rate_limit "${repos[@]}"; then
    return 0
  fi
  state="$(machine_state_dir)"
  mkdir -p "$state"
  MODEL="$(registry_get_global "$reg" model "$MODEL")"
  HARNESS="$(registry_get_global "$reg" harness "$HARNESS")"
  PLAN_OVER="$(registry_get_global "$reg" plan_over "$PLAN_OVER")"
  PLAN_OVER_FILES="$(registry_get_global "$reg" plan_over_files "$PLAN_OVER_FILES")"
  READ_BUDGET="$(registry_get_global "$reg" read_budget "$READ_BUDGET")"
  harness_load "$HARNESS" || die "no adapter for harness $HARNESS (adapters/harness/<name>.sh)"
  work="$(mktemp -d)"
  MACHINE_WORK="$work"
  MACHINE_ACTIVE=1
  DECISION_CACHE="$state/decisions"
  : >>"$DECISION_CACHE"
  : >"$work/pending"; : >"$work/running"; : >"$work/jobs"
  status_phase_set "scanning" "$interval_s"
  log "tick: ${#repos[@]} projects, $workers at once, $slots this tick, reviewing with $MODEL"
  for repo in "${repos[@]}"; do
    if machine_repo_rate_limited "$repo"; then
      continue
    fi
    (machine_list_project "$repo" "$work/pending") || log "$repo: could not be read — skipping it"
  done
  status_queued_set "$work/pending"
  while [ "$started" -lt "$slots" ]; do
    machine_reap "$work"
    if [ "$(wc -l <"$work/jobs" | tr -d ' ')" -ge "$workers" ]; then
      sleep 0.05
      continue
    fi
    pick="$(sched_pick "$work/pending" "$work/running" "$state/cursor" "${repos[@]}")" || break
    status_queued_set "$work/pending"
    repo="${pick% *}"
    pr="${pick#* }"
    (machine_review_worker "$repo" "$pr") &
    echo "$! $repo" >>"$work/jobs"
    started=$((started + 1))
  done
  while [ -s "$work/jobs" ]; do
    machine_reap "$work"
    sleep 0.1
  done
  log "tick done: $started started"
}
