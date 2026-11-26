#!/usr/bin/env bash
# What status.json says while reviews run (upstream issue, an earlier change).
#
# All updates to status.json go through status_locked + atomic mktemp + mv -f
# and preserve existing sibling keys (recent_results, tick_errors, interval_s,
# queued, last_repo, last_pr, result, finished_at, last_tick_at, rate_limit).

status_path() {
  printf '%s\n' "${AUTO_REVIEW_STATUS_FILE:-/run/auto-review/status.json}"
}

status_interval_s() {
  local reg="${1:-${AUTO_REVIEW_REGISTRY:-${REGISTRY_DEFAULT_FILE:-/var/lib/auto-review/projects.json}}}"
  local raw=""
  if [ -r "$reg" ]; then
    if declare -F registry_get_global >/dev/null 2>&1; then
      raw="$(registry_get_global "$reg" interval "${AUTO_REVIEW_INTERVAL:-180}")"
    else
      raw="$(jq -r 'if .interval != null then .interval else empty end' "$reg" 2>/dev/null || true)"
      [ -n "$raw" ] || raw="${AUTO_REVIEW_INTERVAL:-180}"
    fi
  else
    raw="${AUTO_REVIEW_INTERVAL:-180}"
  fi
  case "$raw" in
    '' | *[!0-9]* | 0) raw=180 ;;
    *) [ "$raw" -gt 0 ] 2>/dev/null || raw=180 ;;
  esac
  printf '%s\n' "$raw"
}

status_cutoff_iso() {
  date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo ""
}

status_scrub_text() {
  if declare -F scrub_reason >/dev/null 2>&1; then
    scrub_reason "$1"
  else
    printf '%s' "$1" | tr '\r\n' '  ' | head -c 300
  fi
}

publish_status() {
  local status_file dir tmp
  status_file="$(status_path)"
  dir="$(dirname "$status_file")"
  [ -d "$dir" ] && [ -w "$dir" ] || return 0
  tmp="$(mktemp "${status_file}.tmp.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s\n' "$1" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$status_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Runs "$@" holding the status lock: a directory, as every other lock here. A
# lock older than ten seconds belonged to a worker that died holding it.
status_locked() {
  local lock dir waited=0 rc=0
  lock="$(status_path).lock"
  dir="$(dirname "$lock")"
  [ -d "$dir" ] && [ -w "$dir" ] || return 0
  until mkdir "$lock" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      rm -rf "$lock"
      waited=0
    fi
    sleep 0.05
  done
  "$@" || rc=$?
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

status_read_json() {
  local cur
  cur="$(cat "$(status_path)" 2>/dev/null || true)"
  if [ -n "$cur" ] && [ "$(printf '%s' "$cur" | jq -r 'type' 2>/dev/null || true)" = "object" ]; then
    printf '%s' "$cur"
  else
    printf '{}'
  fi
}

# Applies a jq read-modify-write transform (caller holds status_locked).
status_rmw_locked() {
  local cur next
  cur="$(status_read_json)"
  next="$(printf '%s' "$cur" | jq -c "$@" 2>/dev/null || true)"
  if [ -n "$next" ]; then
    publish_status "$next"
  fi
  return 0
}

# Shared jq filter snippet for updating recent_results with 24h TTL + 50-entry cap.
_STATUS_RR_FILTER='
  ($r + "#" + ($p | tostring)) as $key
  | (if $sha_arg != "" then $sha_arg else (((.active // []) | map(select(.repo == $r and .pr == $p)) | .[0].sha) // "") end) as $eff_sha
  | ((.recent_results // {})[$key] // null) as $prev
  | (if $res == "posted" then 1
     elif ($prev != null and $prev.result != "posted" and $prev.sha == $eff_sha) then (($prev.attempts // 0) + 1)
     else 1 end) as $attempts
  | {
      sha: $eff_sha,
      result: $res,
      error_kind: $kind,
      http_status: $http,
      reason: $reason,
      retryable: $retry,
      attempts: $attempts,
      at: $now
    } as $rec
  | (((.recent_results // {}) + {($key): $rec})
     | to_entries
     | map(select($cutoff == "" or ((.value.at // "") >= $cutoff)))
     | sort_by(.value.at // "")
     | .[-50:]
     | from_entries) as $rr
'

# $1 = the entry as JSON.
status_active_add_locked() {
  status_rmw_locked --argjson e "$1" '
    ((.active // []) | map(select(.repo != $e.repo or .pr != $e.pr)) + [$e]) as $a
    | ((.queued // []) | map(select(.repo != $e.repo or .pr != $e.pr))) as $q
    | . + $a[0] + {phase: "reviewing", active: $a, queued: $q}'
}

# $1 = repo, $2 = pr, $3 = result, [$4 = sha, $5 = error_kind, $6 = http_status, $7 = reason, $8 = retryable].
status_active_remove_locked() {
  local repo="$1" pr="$2" res="$3" sha="${4:-}" kind="${5:-}" http="${6:-}" reason="${7:-}" retry="${8:-false}"
  local now cutoff http_json retry_json
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cutoff="$(status_cutoff_iso)"
  reason="$(status_scrub_text "$reason")"
  case "$http" in
    '' | *[!0-9]*) http_json="null" ;;
    *) http_json="$http" ;;
  esac
  [ "$retry" = "true" ] && retry_json="true" || retry_json="false"
  status_rmw_locked \
    --arg r "$repo" --argjson p "$pr" --arg res "$res" \
    --arg sha_arg "$sha" --arg kind "$kind" --argjson http "$http_json" \
    --arg reason "$reason" --argjson retry "$retry_json" \
    --arg now "$now" --arg cutoff "$cutoff" \
    "$_STATUS_RR_FILTER"'
    | ((.active // []) | map(select(.repo != $r or .pr != $p))) as $a
    | if ($a | length) > 0 then
        . + $a[0] + {phase: "reviewing", active: $a, recent_results: $rr}
      else
        (. + {phase: "idle", active: [], last_repo: $r, last_pr: $p, result: $res, finished_at: $now, recent_results: $rr})
        | del(.repo, .pr, .sha, .lines, .model, .started_at, .timeout_s)
      end'
}

# Records a PR outcome without modifying .active[] (e.g. pre-review failures).
# $1 = repo, $2 = pr, $3 = sha, $4 = result, $5 = error_kind, $6 = http_status, $7 = reason, $8 = retryable.
status_record_result_locked() {
  local repo="$1" pr="$2" sha="${3:-}" res="$4" kind="${5:-}" http="${6:-}" reason="${7:-}" retry="${8:-false}"
  local now cutoff http_json retry_json
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cutoff="$(status_cutoff_iso)"
  reason="$(status_scrub_text "$reason")"
  case "$http" in
    '' | *[!0-9]*) http_json="null" ;;
    *) http_json="$http" ;;
  esac
  [ "$retry" = "true" ] && retry_json="true" || retry_json="false"
  status_rmw_locked \
    --arg r "$repo" --argjson p "$pr" --arg res "$res" \
    --arg sha_arg "$sha" --arg kind "$kind" --argjson http "$http_json" \
    --arg reason "$reason" --argjson retry "$retry_json" \
    --arg now "$now" --arg cutoff "$cutoff" \
    "$_STATUS_RR_FILTER"'
    | . + {last_repo: $r, last_pr: $p, result: $res, finished_at: $now, recent_results: $rr}'
}

status_record_result() {
  status_locked status_record_result_locked "$@"
}

# $1 = repo, $2 = pr. True while the entry is in the list.
status_active_has() {
  jq -e --arg r "$1" --argjson p "$2" '(.active // []) | any(.repo == $r and .pr == $p)' \
    "$(status_path)" >/dev/null 2>&1
}

# Nothing is running: resets active/queued and stamps idle, preserving
# recent_results, tick_errors, interval_s, last_repo, etc.
status_active_reset() {
  local now iv
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  iv="$(status_interval_s)"
  status_locked status_rmw_locked \
    --arg now "$now" --argjson iv "$iv" \
    '(. + {
        phase: "idle",
        active: [],
        queued: [],
        last_tick_at: $now,
        interval_s: $iv
      })
     | del(.repo, .pr, .sha, .lines, .model, .started_at, .timeout_s)'
}

# Sets phase (e.g. "scanning") and interval_s while preserving sibling keys.
status_phase_set() {
  local phase="$1" iv="${2:-$(status_interval_s)}" now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  status_locked status_rmw_locked \
    --arg ph "$phase" --argjson iv "$iv" --arg now "$now" \
    '(. + {phase: $ph, active: [], queued: [], interval_s: $iv, last_tick_at: $now})
     | del(.repo, .pr, .sha, .lines, .model, .started_at, .timeout_s)'
}

# Updates .queued from a pending file ("<repo> <pr>" lines).
status_queued_set() {
  local pending_file="$1" arr='[]'
  if [ -s "$pending_file" ]; then
    arr="$(jq -Rsc '[split("\n")[] | select(length > 0) | split(" ") | {repo: .[0], pr: (.[1] | tonumber)}]' "$pending_file" 2>/dev/null || echo '[]')"
  fi
  status_locked status_rmw_locked --argjson q "$arr" '. + {queued: $q}'
}

# $1 = scope ("_global" or "<owner/repo>"), $2 = error_kind, $3 = reason.
status_tick_error_set() {
  local scope="$1" kind="$2" reason now iv
  reason="$(status_scrub_text "$3")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  iv="$(status_interval_s)"
  status_locked status_rmw_locked \
    --arg s "$scope" --arg k "$kind" --arg r "$reason" --arg t "$now" --argjson iv "$iv" \
    '. + {
        phase: (.phase // "idle"),
        active: (.active // []),
        queued: (.queued // []),
        interval_s: $iv,
        tick_errors: ((.tick_errors // {}) + {($s): {error_kind: $k, reason: $r, at: $t}})
      }
     | if $s == "_global" then . + {last_tick_at: $t} else . end'
}

# $1 = scope ("_global" or "<owner/repo>").
status_tick_error_clear() {
  local scope="$1"
  status_locked status_rmw_locked \
    --arg s "$scope" \
    'if (.tick_errors | type) == "object" then .tick_errors |= with_entries(select(.key != $s)) else . end'
}

# $1 = core_remaining, $2 = core_limit, $3 = core_reset_at,
# $4 = graphql_remaining, $5 = graphql_limit, $6 = graphql_reset_at,
# $7 = throttled (true|false).
status_rate_limit_set() {
  local core_rem="$1" core_lim="$2" core_rst="$3" gql_rem="$4" gql_lim="$5" gql_rst="$6" throttled="$7"
  local throt_json="false"
  [ "$throttled" = "true" ] && throt_json="true"
  status_locked status_rmw_locked \
    --argjson cr "$core_rem" --argjson cl "$core_lim" --argjson ct "$core_rst" \
    --argjson gr "$gql_rem" --argjson gl "$gql_lim" --argjson gt "$gql_rst" --argjson th "$throt_json" \
    '. + {
      rate_limit: {
        core_remaining: $cr,
        core_limit: $cl,
        core_reset_at: $ct,
        graphql_remaining: $gr,
        graphql_limit: $gl,
        graphql_reset_at: $gt,
        throttled: $th
      }
    }'
}

# Container daemon startup RMW update (preserves any existing keys).
status_daemon_started() {
  local now iv
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  iv="$(status_interval_s)"
  status_locked status_rmw_locked \
    --arg now "$now" --argjson iv "$iv" \
    '. + {phase: "idle", active: (.active // []), queued: (.queued // []), interval_s: $iv, started_at: $now}'
}

# Post-tick daemon idle refresh (preserves tick_errors._global and sibling keys).
status_daemon_idle_refresh() {
  local now iv
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  iv="$(status_interval_s)"
  status_locked status_rmw_locked \
    --arg now "$now" --argjson iv "$iv" \
    'if .phase == "reviewing" then
       .
     elif ((.tick_errors // {})._global // null) != null then
       . + {last_tick_at: $now, interval_s: $iv}
     else
       (. + {phase: "idle", active: [], queued: [], interval_s: $iv, last_tick_at: $now})
       | del(.repo, .pr, .sha, .lines, .model, .started_at, .timeout_s)
     end'
}

# $1 = repo, $2 = pr, $3 = sha, $4 = lines of patch, $5 = model, [$6 = timeout_s].
status_review_begin() {
  local repo="$1" pr="$2" sha="$3" lines="$4" model="$5" timeout_s="${6:-}" now entry
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -z "$timeout_s" ]; then
    if declare -F reviewer_timeout >/dev/null 2>&1; then
      timeout_s="$(reviewer_timeout "$lines" "${READING_PLAN:-0}")"
    else
      timeout_s="${AUTO_REVIEW_TIMEOUT:-900}"
    fi
  fi
  if [ -n "${MACHINE_ACTIVE:-}" ]; then
    entry="$(jq -nc --arg r "$repo" --argjson p "$pr" --arg s "$sha" --argjson l "$lines" --arg m "$model" --arg t "$now" --argjson to "$timeout_s" \
      '{repo: $r, pr: $p, sha: $s, model: $m, lines: $l, started_at: $t, timeout_s: $to}')"
    status_locked status_active_add_locked "$entry"
  else
    status_locked status_rmw_locked \
      --arg r "$repo" --argjson p "$pr" --arg s "$sha" --arg l "$lines" --arg m "$model" --arg t "$now" --argjson to "$timeout_s" \
      '. + {phase: "reviewing", repo: $r, pr: $p, sha: $s, lines: $l, model: $m, started_at: $t, timeout_s: $to}'
  fi
}

# $1 = repo, $2 = pr, $3 = failed | empty | posted | post_failed,
# [$4 = sha, $5 = error_kind, $6 = http_status, $7 = reason, $8 = retryable].
status_review_end() {
  status_locked status_active_remove_locked "$@"
}
