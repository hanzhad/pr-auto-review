#!/usr/bin/env bash
# GitHub platform adapter for auto-review.
#
# Provides isolated GitHub CLI calls for PR listing, CI checking, compare
# inspection, history queries, and review posting.

# Evaluates whether GitHub Actions runs or commit statuses are pending for a SHA.
# Returns 0 if pending (tick should postpone), 1 if settled or settled-without-CI.
platform_ci_pending() {
  local repo="$1" sha="$2" running state
  local runs_read=0 status_read=0 unreadable="" pending=0

  running="$(gh api "repos/$repo/actions/runs?head_sha=$sha" \
    -q '[.workflow_runs[] | select(.status != "completed")] | length' 2>/dev/null || echo "")"
  case "$running" in
    '' | *[!0-9]*) unreadable="workflow runs" ;;
    *)
      runs_read=1
      if [ "$running" != 0 ]; then
        pending=1
      fi
      ;;
  esac

  state="$(gh api "repos/$repo/commits/$sha/status" \
    -q 'if (.statuses | length) == 0 then "none" else .state end' 2>/dev/null || echo "")"
  case "$state" in
    pending | success | failure | error | none)
      status_read=1
      if [ "$state" = pending ]; then
        pending=1
      fi
      ;;
    *)
      if [ -n "$unreadable" ]; then
        unreadable="$unreadable or commit statuses"
      else
        unreadable="commit statuses"
      fi
      ;;
  esac

  if [ "$runs_read" != 1 ] || [ "$status_read" != 1 ]; then
    if [ "$pending" = 1 ]; then
      log "cannot read $unreadable for ${sha:0:7} (the token may not be allowed to) — postponing on the half that answered"
    else
      log "cannot read $unreadable for ${sha:0:7} (the token may not be allowed to) — reviewing without waiting for CI"
    fi
  fi
  if [ "$pending" = 1 ]; then
    return 0
  fi
  return 1
}

# Whether every commit between $old and $new is nothing but the base branch
# being merged in (e.g. `gh pr update-branch`).
platform_only_base_merges_since() {
  local repo="$1" base="$2" old="$3" new="$4"
  [ -n "$base" ] || return 1
  local commits
  commits="$(gh api "repos/$repo/compare/$old...$new" \
    -q '.commits[] | [.sha, (.parents | length), (.parents[1].sha // "")] | @tsv' 2>/dev/null)" || return 1
  [ -n "$commits" ] || return 1
  local sha nparents parent2 status
  while IFS=$'\t' read -r sha nparents parent2; do
    [ -n "$sha" ] || continue
    if [ "$nparents" != 2 ] || [ -z "$parent2" ]; then
      return 1
    fi
    status="$(gh api "repos/$repo/compare/$base...$parent2" -q '.status' 2>/dev/null)" || return 1
    case "$status" in
      identical | behind) ;;
      *) return 1 ;;
    esac
  done <<<"$commits"
  return 0
}

# Appends paginated API query output into $into.
platform_fetch_history_source() {
  local into="$1" path="$2" query="$3" tmp
  tmp="$(mktemp)"
  if gh api --paginate "$path" -q "$query" >"$tmp" 2>/dev/null; then
    cat "$tmp" >>"$into"
    rm -f "$tmp"
    return 0
  fi
  log "could not read $path"
  rm -f "$tmp"
  return 1
}

# Reads current head SHA of PR $2 in repo $1. Empty when unreadable.
platform_pr_head_sha() {
  local repo="$1" pr="$2" out sha=""
  out="$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  if printf '%s' "$out" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    printf '%s\n' "$out"
    return 0
  fi
  out="$(gh api "repos/$repo/pulls/$pr" 2>/dev/null || true)"
  sha="$(printf '%s' "$out" | jq -r '.head.sha // empty' 2>/dev/null || true)"
  printf '%s\n' "$sha"
}

# Pure: classifies a failed post_review attempt.
# $1 = http_code (or ""), $2 = stderr text, $3 = reviewed_sha, $4 = current_head_sha.
# Prints "<error_kind> <retryable>".
classify_post_review_failure() {
  local http="${1:-}" err="${2:-}" expected_sha="${3:-}" current_sha="${4:-}"
  if [ "$http" = "422" ]; then
    if [ -n "$current_sha" ] && [ -n "$expected_sha" ] && [ "$current_sha" != "$expected_sha" ]; then
      printf 'stale_head false\n'
    else
      printf 'github_rejected false\n'
    fi
    return 0
  fi
  if [ "$http" = "429" ]; then
    printf 'github_transient true\n'
    return 0
  fi
  case "$err" in
    *[Ss]'econdary rate limit'* | *'secondary rate limit'*)
      printf 'github_transient true\n'
      return 0
      ;;
  esac
  case "$http" in
    5[0-9][0-9])
      printf 'github_transient true\n'
      return 0
      ;;
    '')
      printf 'github_transient true\n'
      return 0
      ;;
    *)
      printf 'github_rejected false\n'
      return 0
      ;;
  esac
}

# Submits review JSON payload for a pull request pinned to a specific commit SHA.
# Populates POST_REVIEW_HTTP_STATUS and POST_REVIEW_STDERR on failure.
platform_post_review() {
  local repo="$1" pr="$2" body="$3" sha="$4"
  local err_file rc=0 err_text="" http_code=""
  err_file="$(mktemp)"
  POST_REVIEW_HTTP_STATUS=""
  POST_REVIEW_STDERR=""
  if ! jq -n --rawfile body "$body" --arg commit_id "$sha" \
    '{body: $body, commit_id: $commit_id, event: "COMMENT"}' |
    gh api "repos/$repo/pulls/$pr/reviews" --input - >/dev/null 2>"$err_file"; then
    rc=1
  fi
  err_text="$(cat "$err_file" 2>/dev/null || true)"
  rm -f "$err_file"
  if [ "$rc" != 0 ]; then
    POST_REVIEW_STDERR="$err_text"
    http_code="$(printf '%s' "$err_text" | sed -nE 's/.*HTTP ([0-9]{3}).*/\1/p' | head -n 1)"
    POST_REVIEW_HTTP_STATUS="$http_code"
    return 1
  fi
  return 0
}
