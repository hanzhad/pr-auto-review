#!/usr/bin/env bash
# Which pull requests of a listing want a review, and the decision cache
# (upstream issue). Cut out of cmd_tick so the per-project tick and the
# machine tick filter the same way.
#
# The cache is a file of "<repo> <pr> <head> <n>" lines, DECISION_CACHE; empty
# disables it, which is what the per-project tick does. Only terminal decisions
# go in: the head is reviewed already, or only base merges came since. A head
# whose CI is still running, or that needs a review, is never cached.
#
# <n> is how many reviews of this account the listing showed as not dismissed.
# The decision holds only while that number does: the owner dismissing a review
# to ask for another one lowers it, and the next tick looks the pull request up
# again instead of skipping it until the head moves. It comes with the listing,
# so a pull request nobody touched still costs no call of its own.

decision_cached() {
  [ -n "${DECISION_CACHE:-}" ] && [ -f "$DECISION_CACHE" ] && grep -qxF -- "$1 $2 $3 ${4:-0}" "$DECISION_CACHE"
}

decision_remember() {
  [ -n "${DECISION_CACHE:-}" ] || return 0
  printf '%s %s %s %s\n' "$1" "$2" "$3" "${4:-0}" >>"$DECISION_CACHE" 2>/dev/null || true
  return 0
}

# Drops the repository's entries for pull requests or heads the listing no
# longer has, or whose count of live reviews moved. $1 = repo, $2 = the listing
# as collect_pending takes it.
decision_prune() {
  local repo="$1" keep tmp
  [ -n "${DECISION_CACHE:-}" ] && [ -f "$DECISION_CACHE" ] || return 0
  keep="$(mktemp)"; tmp="$(mktemp)"
  printf '%s\n' "$2" | awk -F'\035' -v r="$repo" '$1 != "" { print r " " $1 " " $2 " " ($9 == "" ? 0 : $9) }' >"$keep"
  awk -v r="$repo" 'NR == FNR { k[$0] = 1; next } index($0, r " ") != 1 || ($0 in k)' "$keep" "$DECISION_CACHE" >"$tmp" && cat "$tmp" >"$DECISION_CACHE"
  rm -f "$keep" "$tmp"
  return 0
}

# The pull requests of a listing that want a review now: sets PENDING_PRS to
# their numbers, one per line. $1 = owner/repo, $2 = the reviewing account,
# $3 = the listing (number, head, base, draft, bot, author, branch, labels,
# count of this account's live reviews and title, separated by the group
# separator). Every filter of a tick is here,
# the free ones first.
collect_pending() {
  local repo="$1" me="$2" open_prs="$3"
  local number head base is_draft is_bot author branch labels rcount title
  local pending=""
  while IFS=$'\035' read -r number head base is_draft is_bot author branch labels rcount title; do
    [ -n "$number" ] || continue

    # Silently, as it always was: a draft is somebody saying they are not asking
    # for a review yet, and a line about it every tick is noise.
    if [ "$is_draft" = true ] && [ -z "$REVIEW_ONLY" ]; then
      continue
    fi

    if [ -n "$REVIEW_ONLY" ]; then
      log "#$number: reviewing at ${head:0:7} — $title"
      pending="${number}"$'\n'
      continue
    fi

    # These three first, because they are the only filters that cost nothing:
    # branch, labels and authorship all came back with the listing, where the
    # already-reviewed check and the CI gate are two API calls each, spent every
    # tick, on a pull request this will refuse anyway.
    local matched
    if matched="$(matched_glob "$SKIP_BRANCHES" "$branch")"; then
      log "#$number is on $branch, which matches --skip-branch $matched — skipping"
      continue
    fi

    if matched="$(label_skipped "$labels")"; then
      log "#$number is labelled $matched — skipping"
      continue
    fi

    if [ "$SKIP_BOTS" = 1 ] && [ "$is_bot" = true ]; then
      log "#$number was opened by $author, which GitHub calls an app — skipping (--skip-bots)"
      continue
    fi

    if [ "$author" = "$me" ] && [ "$SELF_REVIEW" != 1 ]; then
      log "#$number is this account's own — skipping (pass --self-review to include it)"
      continue
    fi

    # A head already decided costs no call. Only machine ticks keep the cache.
    if decision_cached "$repo" "$number" "$head" "$rcount"; then
      continue
    fi

    # `--paginate`, because this is the entire record that a commit has been
    # reviewed and the endpoint answers 30 at a time. Every push adds a review,
    # so a long-lived pull request walks its own head's review off the first
    # page — and from that tick on it reads as never reviewed, is reviewed
    # again, gains another review, and does it for ever at full price. The
    # generated release pull request that prompted --skip-branch was at 10.
    #
    # Filtered to `$me`'s own reviews: a CI guard posts CHANGES_REQUESTED (and
    # later DISMISSED) as `github-actions[bot]` on the head commit, and without
    # this filter that reads as "reviewed" for ever — a bot's guard review is
    # not this reviewer's record that the commit is done. demo-app#2170 sat
    # skipped every tick this way, reviewed only at 9157ac8 and 59dccb0 by
    # `github-actions[bot]`, never by `$me`.
    #
    # And then to the ones carrying this tool's own signature line, because
    # `$me` is also the person: the job runs on the owner's token, so an
    # approval the owner typed by hand lands on the same login as what this
    # posts. demo-app#4284 (2026-11-04) was approved at its head before any
    # tick reached it, read as "reviewed at 8c750c0" for an hour, and
    # dismissing the approval changed nothing while a DISMISSED review still
    # counted. Now it does not: the owner dismissing a review of this job's own
    # is a request to review again, so a DISMISSED one drops out of the list
    # entirely, and only_base_merges_since below never sees it either. The way
    # out for a review nobody dismissed is `--review N`; nobody should need an
    # empty commit.
    local reviewed
    reviewed="$(gh api --paginate "repos/$repo/pulls/$number/reviews" -q ".[] | select(.user.login == \"$me\" and .state != \"DISMISSED\" and ((.body | contains(\"<!-- auto-review:\")) or (.body | contains(\"Automated review. Not an approval.\")))) | .commit_id" || echo "")"
    if printf '%s\n' "$reviewed" | grep -qx "$head"; then
      log "#$number is reviewed at ${head:0:7} — skipping"
      decision_remember "$repo" "$number" "$head" "$rcount"
      continue
    fi

    # A ruleset requiring the branch up to date means `gh pr update-branch`
    # merges master in every time the check fires, which moves the head and
    # would otherwise re-review a diff nobody changed. The API's own order for
    # this endpoint is submission order, so the last line is the most recent
    # review's commit — the one to compare the new head against.
    if [ -n "$reviewed" ]; then
      local last_reviewed
      last_reviewed="$(printf '%s\n' "$reviewed" | tail -n1)"
      if [ -n "$last_reviewed" ] && only_base_merges_since "$repo" "$base" "$last_reviewed" "$head"; then
        log "#$number: only base merges since ${last_reviewed:0:7} — keeping that review"
        decision_remember "$repo" "$number" "$head" "$rcount"
        continue
      fi
    fi

    # Exit 8 is `gh pr checks` for "still running". Reviewing now would judge a
    # commit CI has not finished with, and a push during the review would make
    # the result stale before it is posted. A red or check-less PR is reviewed
    # as normal — a failure is worth commenting on.
    if ci_pending "$repo" "$head"; then
      log "#$number has CI still running — postponing"
      continue
    fi

    # The worker that posts it needs the count, to cache the head with the
    # review it is about to add, and the head SHA for pre-review telemetry.
    if [ -n "${MACHINE_WORK:-}" ]; then
      local wslug
      wslug="$(printf '%s' "$repo" | tr '/' '-')"
      printf '%s' "${rcount:-0}" >"$MACHINE_WORK/count.$wslug-$number"
      printf '%s' "$head" >"$MACHINE_WORK/head.$wslug-$number"
    fi
    log "#$number needs a review at ${head:0:7} — $title"
    pending="${pending}${number}"$'\n'
  done <<<"$open_prs"
  PENDING_PRS="$(printf '%s' "$pending" | sed '/^$/d')"
}
