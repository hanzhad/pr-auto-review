#!/usr/bin/env bash
# One command sets a project up, and pause / resume (upstream issue, part
# of an earlier change). Needs the registry, token-status and clone libraries and `die`,
# `log` and the paths from auto-review.sh.
#
# GitHub tokens are one per resource owner, gh-<owner>.token: a fine-grained
# token has one resource owner, and the registered repositories belong to more
# than one. Every gh call of setup runs with that file's token and no other.

# The name of the token file for the owner of repository $1 (owner/repo).
owner_token_name() { printf 'gh-%s.token\n' "${1%%/*}"; }

# Prints the permissions the owner's token lacks on repository $1, one name per
# line, using only reads. The comment-write permission cannot be probed without
# posting, so it is not.
setup_missing_permissions() {
  local repo="$1" token="$2" pair path name
  for pair in \
    "Contents|repos/$repo/contents" \
    "Pull requests|repos/$repo/pulls?per_page=1" \
    "Actions|repos/$repo/actions/runs?per_page=1" \
    "Commit statuses|repos/$repo/commits/HEAD/status"; do
    name="${pair%%|*}"
    path="${pair#*|}"
    GH_TOKEN="$token" gh api "$path" >/dev/null 2>&1 || printf '%s\n' "$name"
  done
}

# Prints how many open pull requests the next tick would take on repository $1:
# the ones assigned to the token's account, or every one with $2 = true, minus
# drafts and, without $3 = true, the account's own. Reads only.
setup_dry_pick() {
  local repo="$1" all="$2" self_review="$3" token="$4" me prs
  local list_args=(--repo "$repo" --state open --limit 100 --json number,isDraft,author)
  me="$(GH_TOKEN="$token" gh api user -q .login 2>/dev/null)" || me=""
  [ "$all" = true ] || list_args+=(--assignee "@me")
  prs="$(GH_TOKEN="$token" gh pr list "${list_args[@]}" 2>/dev/null)" || { echo 0; return 0; }
  printf '%s\n' "$prs" | jq -r --arg me "$me" --arg sr "$self_review" \
    '[.[] | select(.isDraft | not) | select($sr == "true" or .author.login != $me)] | length'
}

# setup <owner/repo> [--all] [--self-review]
cmd_setup() {
  local repo="" flags=() reg="$REGISTRY_DEFAULT_FILE" arg owner name file token missing clone slug
  for arg in "$@"; do
    case "$arg" in
      --all | --self-review) flags+=("$arg") ;;
      -*) die "setup: unknown flag $arg (setup takes --all and --self-review)" ;;
      *) [ -z "$repo" ] || die "setup takes one repository"; repo="$arg" ;;
    esac
  done
  case "$repo" in
    */*) ;;
    *) die "setup needs a repository as owner/repo" ;;
  esac
  owner="${repo%%/*}"
  name="$(owner_token_name "$repo")"

  # 1. The owner's token, and what it may do on this repository.
  file="$(token_path "$name")"
  # Until every owner token is delivered the old per-repo file still serves,
  # as it does for tick, run and the entrypoint.
  if [ ! -s "$file" ] && [ -s "$(token_path "$(printf '%s' "$repo" | tr / -).token")" ]; then
    name="$(printf '%s' "$repo" | tr / -).token"
    file="$(token_path "$name")"
    log "setup $repo: no $(owner_token_name "$repo") yet, using the old $name"
  fi
  [ -s "$file" ] || die "setup $repo: no $name in $TOKEN_DIR — put the token of $owner there first"
  token="$(tr -d '[:space:]' <"$file")"
  [ -n "$token" ] || die "setup $repo: $name is empty"
  missing="$(setup_missing_permissions "$repo" "$token" | paste -sd, - | sed 's/,/, /g')"
  [ -z "$missing" ] || die "setup $repo: the token in $name lacks $missing on $repo — grant it on GitHub, then run setup again"

  # 2. Registered. A rerun changes only the flags it is given.
  registry_migrate "$reg" || true
  registry_adopt "$reg" "$repo" ${flags[@]+"${flags[@]}"} || die "setup $repo: could not write the registry"

  # 3. The review clone and its marker, as a tick would make them.
  slug="$(printf '%s' "$repo" | tr / -)"
  clone="$CLONE_ROOT/$slug"
  if [ ! -d "$clone/.git" ]; then
    mkdir -p "$CLONE_ROOT"
    GH_TOKEN="$token" gh repo clone "$repo" "$clone" >/dev/null 2>&1 || die "setup $repo: could not clone it into $clone"
  fi
  mkdir -p "$MARKER_DIR"
  printf '%s\n' "$clone" >"$MARKER_DIR/$slug"

  # 4. What it looks like now, and what the next tick would do. Nothing posted.
  echo "setup $repo: registered, cloned to $clone"
  registry_list "$reg" | awk -v r="$repo" 'NR <= 2 || $1 == r'
  echo "would pick up $(setup_dry_pick "$repo" \
    "$(registry_get "$reg" "$repo" all false)" "$(registry_get "$reg" "$repo" self_review false)" "$token") open pull request(s) on the next tick"
}

# pause <owner/repo> [--reason "..."]
cmd_pause() {
  local repo="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) [ $# -ge 2 ] || die "pause: --reason needs a text"; reason="$2"; shift 2 ;;
      -*) die "pause: unknown flag $1" ;;
      *) [ -z "$repo" ] || die "pause takes one repository"; repo="$1"; shift ;;
    esac
  done
  [ -n "$repo" ] || die "pause needs a repository"
  registry_migrate "$REGISTRY_DEFAULT_FILE" || true
  registry_pause "$REGISTRY_DEFAULT_FILE" "$repo" "$reason" || die "pause $repo: nothing changed"
  echo "paused $repo"
}

# resume <owner/repo>
cmd_resume() {
  [ $# -eq 1 ] || die "resume needs one repository"
  registry_migrate "$REGISTRY_DEFAULT_FILE" || true
  registry_resume "$REGISTRY_DEFAULT_FILE" "$1" || die "resume $1: nothing changed"
  echo "resumed $1"
}
