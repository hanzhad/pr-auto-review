#!/usr/bin/env bash
# One git worktree per review (upstream issue).
#
# A review used to check the pull request out in the project's single review
# clone, so two reviews could never be in flight at once and the clone itself
# carried whatever the last branch shipped. Each review now gets a worktree of
# that clone, at <root>/<slug>/pr-<n>: the checkout, the scrub and the
# .auto-review-* files all live there, and the clone is only ever fetched into.
#
# Functions only; nothing here fetches, calls gh, or dies.

# The root of every worktree. Both variables are read at call time.
worktree_root() {
  if [ -n "${AUTO_REVIEW_WORKTREE_ROOT:-}" ]; then
    printf '%s\n' "$AUTO_REVIEW_WORKTREE_ROOT"
  else
    printf '%s\n' "${AUTO_REVIEW_CLONE_ROOT:-$HOME/.cache/auto-review}/worktrees"
  fi
}

# $1 = review clone (CLONE_ROOT/<slug>), $2 = pull request number.
worktree_dir() {
  printf '%s/%s/pr-%s\n' "$(worktree_root)" "$(basename "$1")" "$2"
}

# Detached worktree at origin/HEAD; prints its path. A directory or registration
# left by a killed tick for the same pull request is replaced.
worktree_add() {
  local clone="$1" dir
  dir="$(worktree_dir "$clone" "$2")"
  git -C "$clone" worktree remove --force "$dir" >/dev/null 2>&1 || true
  rm -rf "${dir:?}"
  git -C "$clone" worktree prune >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$dir")" || return 1
  git -C "$clone" worktree add -q --detach "$dir" origin/HEAD >/dev/null || return 1
  printf '%s\n' "$dir"
}

# $1 = review clone, $2 = the worktree's path.
worktree_remove() {
  local clone="$1" dir="$2"
  git -C "$clone" worktree remove --force "$dir" >/dev/null 2>&1 || true
  rm -rf "${dir:?}"
  git -C "$clone" worktree prune >/dev/null 2>&1 || true
  return 0
}

# Every directory under this project's slug, registered or not, then the
# registrations whose directory is gone. Run at the start of a tick: nothing
# else is in flight for the project while its lock is held.
worktree_prune() {
  local clone="$1" base d
  base="$(worktree_root)/$(basename "$clone")"
  if [ -d "$base" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      log "pruned stale worktree $d"
      rm -rf "${d:?}"
    done < <(find "$base" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
  fi
  git -C "$clone" worktree prune >/dev/null 2>&1 || true
  return 0
}

# Removes, from $1 only, what `gh pr checkout` may have written that is read as
# an instruction or written through: the staged .auto-review-* names, and every
# instruction file in the tree. `rm -rf` and no -type test, because the name is
# what the runtime and the redirection care about, whatever kind of entry it is.
# rc 1 when something could not be removed.
worktree_scrub() {
  local dir="$1" unsafe rc=0
  for unsafe in .auto-review-history.md .auto-review-diff.patch .auto-review-pr.md; do
    rm -rf "${dir:?}/$unsafe" || rc=1
  done
  find "${dir:?}" -path "$dir/.git" -prune -o \
    \( -iname CLAUDE.md -o -iname CLAUDE.local.md -o -iname AGENTS.md \
    -o -iname .mcp.json -o -iname .claude \
    -o -iname GEMINI.md -o -iname .gemini \
    -o -iname .agents -o -iname .agent \
    -o -iname _agents -o -iname _agent \) -prune -exec rm -r -f {} + || rc=1
  return "$rc"
}
