#!/usr/bin/env bash
# Task Tracker Adapter: GitHub Issues for auto-review.
#
# Extracts issue links and acceptance criteria from pull request descriptions,
# grounding code review in the original requirements.
#
# Which issue is "the task" (upstream issue): references come
# from the pull request body and from GitHub's own closing links; the ones that
# close come before the ones that only relate, so a body that opens with
# "Part of an earlier change" briefs the issue it closes, not the epic. Up to three are
# fetched. A closing issue is read in full; an issue the pull request is only
# part of is a parent, and contributes its title and its acceptance list only.

# How many linked tasks are fetched; the rest are listed by number.
TASK_MAX_FETCH=3

# Pure parser: extracts issue references from a PR description, one per line as
# `<kind><TAB><ref>`: kind is `closing` (closes, fixes, resolves and their
# forms) or `related` (part of, ref, refs, and a bare issue URL), ref is `#<num>`
# or `<owner>/<repo>#<num>`. Closing references come first, each group in the
# order the body gives them, a reference once.
task_rank_references() {
  local body="${1:-}"
  [ -n "$body" ] || return 0

  # Normalize CRLF and process lines
  printf '%s\n' "$body" | tr -d '\r' | awk '
    function add(ref, k) {
      if (!(ref in kind)) { order[++count] = ref; kind[ref] = k }
      else if (k == "closing") kind[ref] = "closing"
    }
    {
      line = $0

      # Match full GitHub issue URLs: https://github.com/<owner>/<repo>/issues/<num>
      s = line
      while (match(s, /https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/issues\/[0-9]+/)) {
        url = substr(s, RSTART, RLENGTH)
        sub(/https:\/\/github\.com\//, "", url)
        sub(/\/issues\//, "#", url)
        add(url, "related")
        s = substr(s, RSTART + RLENGTH)
      }

      # Match shorthand keywords, with an optional owner/repo before the number.
      # tolower() keeps the length, so offsets found in the lowered copy cut the
      # original, and a repository name keeps its case.
      s_low = tolower(line)
      s_orig = line
      while (match(s_low, /(^|[^a-z0-9_])(closes|close|closed|fixes|fix|fixed|resolves|resolve|resolved|part of|refs|ref)[ \t]+([a-z0-9_.-]+\/[a-z0-9_.-]+)?#[0-9]+/)) {
        m_low = substr(s_low, RSTART, RLENGTH)
        m = substr(s_orig, RSTART, RLENGTH)
        k = (m_low ~ /(closes|close|closed|fixes|fix|fixed|resolves|resolve|resolved)[ \t]/) ? "closing" : "related"
        match(m, /([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#[0-9]+/)
        add(substr(m, RSTART, RLENGTH), k)
        s_low = substr(s_low, RSTART + RLENGTH)
        s_orig = substr(s_orig, RSTART + RLENGTH)
      }
    }
    END {
      for (i = 1; i <= count; i++) if (kind[order[i]] == "closing") printf "closing\t%s\n", order[i]
      for (i = 1; i <= count; i++) if (kind[order[i]] != "closing") printf "related\t%s\n", order[i]
    }
  '
}

# The references alone, in rank order: closing first.
task_parse_references() {
  task_rank_references "${1:-}" | cut -f2
}

# Writes fallback notice when no linked task exists or task is unreadable.
# With a second argument that is empty or blank, the pull request has no
# description to check against either, and the notice says so.
task_write_fallback() {
  local target_file="$1"
  if [ "$#" -ge 2 ] && ! printf '%s' "$2" | grep -q '[^[:space:]]'; then
    cat <<'EOF' >"$target_file"
# Task Briefing
_No linked task found, and the pull request has no description. task: none, acceptance not checked — review the diff for correctness only._
EOF
    return 0
  fi
  cat <<'EOF' >"$target_file"
# Task Briefing
_No linked task found in pull request description (e.g. Closes #N or Part of #N). The pull request's title and description are the task: task: none linked, checked against the description._
EOF
}

# Splits a reference into repository and number: sets _task_repo, _task_num.
_task_split_ref() {
  local default_repo="$1" ref="$2"
  _task_repo="$default_repo"; _task_num="$ref"
  if [[ "$ref" == *"#"* && "$ref" != "#"* ]]; then
    _task_repo="${ref%#*}"
    _task_num="${ref#*#}"
  elif [[ "$ref" == "#"* ]]; then
    _task_num="${ref###}"
  fi
}

# Fetches task metadata and acceptance criteria for a given reference into the
# target file. Fails, writing nothing, when the issue cannot be read: the status
# is the only way to tell that from an issue whose text happens to say so.
task_fetch_issue() {
  local default_repo="$1" ref="$2" target_file="$3"
  _task_split_ref "$default_repo" "$ref"
  local target_repo="$_task_repo" issue_num="$_task_num"

  local tmp
  tmp="$(mktemp)"
  if gh issue view "$issue_num" --repo "$target_repo" \
    --json number,title,body,state,labels \
    -q '"# Task Briefing: #\(.number) — \(.title)\n\n**Repository**: '"$target_repo"'\n**State**: \(.state)\n**Labels**: \([.labels[].name] | join(", ") // "_none_")\n\n## Acceptance Criteria & Description\n\n\(.body // "_none_")\n"' >"$tmp" 2>/dev/null; then
    mv "$tmp" "$target_file"
    return 0
  fi

  rm -f "$tmp"
  log "could not fetch issue $ref from $target_repo"
  return 1
}

# The same, with a graceful fallback on a missing issue or an API error: the
# "no linked task" notice is written and the status is 0.
task_fetch_briefing() {
  task_fetch_issue "$@" || task_write_fallback "$3"
  return 0
}

# A parent (an epic the pull request is only part of): its title, its state and
# its acceptance list, not its description. The acceptance list is what is under
# an "Acceptance" / "Done when" heading, a "Done when" paragraph, and any
# checklist item. Fails when the issue cannot be read, writing nothing.
task_fetch_parent() {
  local default_repo="$1" ref="$2" target_file="$3" head body
  _task_split_ref "$default_repo" "$ref"
  local target_repo="$_task_repo" issue_num="$_task_num"

  head="$(gh issue view "$issue_num" --repo "$target_repo" --json number,title,state \
    -q '"# Parent task: #\(.number) — \(.title)\n\n**Repository**: '"$target_repo"'\n**State**: \(.state)"' 2>/dev/null)" || return 1
  body="$(gh issue view "$issue_num" --repo "$target_repo" --json body -q '.body // ""' 2>/dev/null)" || return 1
  {
    printf '%s\n\n## Acceptance (title and acceptance list only; this pull request is part of it)\n\n' "$head"
    printf '%s\n' "$body" | tr -d '\r' | awk '
      /^#+[ \t]/ { inacc = (tolower($0) ~ /acceptance|done when|definition of done/); indone = 0; if (inacc) { print; printed = 1 } next }
      tolower($0) ~ /done when/ { print; printed = 1; indone = 1; next }
      indone { if ($0 ~ /^[ \t]*$/) indone = 0; else { print; printed = 1; next } }
      inacc { print; printed = 1; next }
      /^[ \t]*[-*] \[[ xX]\]/ { print; printed = 1 }
      END { if (!printed) print "_none_" }
    '
  } >"$target_file"
  return 0
}

# Issues GitHub itself says this pull request closes (the sidebar link, which a
# body without a keyword never shows): `<owner>/<repo>#<num>` per line. Empty
# when there is no pull request number or the call fails.
task_closing_links() {
  local repo="$1" pr="${2:-}"
  [ -n "$pr" ] || return 0
  gh pr view "$pr" --repo "$repo" --json closingIssuesReferences \
    -q '.closingIssuesReferences[] | "\(.repository.owner.login)/\(.repository.name)#\(.number)"' 2>/dev/null || true
}

# Writes the briefing file for a pull request (optionally its number, so GitHub's
# own closing links are read too).
task_build_briefing() {
  local repo="$1" pr_body="$2" target_file="$3" pr="${4:-}"
  local ranked ref kind link fetched=0 extra="" first=1 tmp

  # The same repository written out is the same task as `#N`.
  ranked="$(task_rank_references "$pr_body" | while IFS=$'\t' read -r kind ref; do
    printf '%s\t%s\n' "$kind" "${ref/#"$repo"#/#}"
  done)"
  # GitHub's links close; they go after the body's own closing keywords and
  # before everything that only relates.
  link="$(task_closing_links "$repo" "$pr" | while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    printf 'closing\t%s\n' "${ref/#"$repo"#/#}"
  done)"
  ranked="$( { printf '%s\n' "$ranked" | grep '^closing' || true; printf '%s\n' "$link" | grep '^closing' || true; printf '%s\n' "$ranked" | grep '^related' || true; } | awk -F'\t' 'NF >= 2 && !seen[$2]++')"

  if [ -z "$ranked" ]; then
    task_write_fallback "$target_file" "$pr_body"
    return 0
  fi

  : >"$target_file"
  while IFS=$'\t' read -r kind ref; do
    [ -n "$ref" ] || continue
    if [ "$fetched" -ge "$TASK_MAX_FETCH" ]; then
      extra="$extra$ref "
      continue
    fi
    tmp="$(mktemp)"
    if [ "$kind" = closing ]; then
      # A closing issue that cannot be read is listed, not faked: the fetch
      # writes the "no task linked" notice on failure, which would say the
      # opposite of what happened.
      task_fetch_issue "$repo" "$ref" "$tmp" || { rm -f "$tmp"; extra="$extra$ref "; continue; }
    else
      task_fetch_parent "$repo" "$ref" "$tmp" || { rm -f "$tmp"; extra="$extra$ref "; continue; }
    fi
    [ "$first" = 1 ] || printf '\n\n---\n\n' >>"$target_file"
    cat "$tmp" >>"$target_file"
    rm -f "$tmp"
    first=0
    fetched=$((fetched + 1))
  done <<<"$ranked"

  # Nothing could be read: say so, naming what was linked and unreadable if
  # something was; a pull request with no link at all never gets here.
  if [ "$fetched" = 0 ]; then
    printf '# Task Briefing
_The linked task could not be read: %s. task: none, acceptance not checked — review the diff for correctness only._
' "${extra% }" >"$target_file"
    return 0
  fi
  if [ -n "$extra" ]; then
    printf '\n\n**Additional linked tasks**: %s\n' "$extra" >>"$target_file"
  fi
  return 0
}
