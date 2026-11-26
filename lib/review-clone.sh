#!/usr/bin/env bash
# The review clone of one project (upstream issue): created, checked
# against its record and fetched. Cut out of cmd_tick so the machine tick
# prepares a clone the same way.

# The project's review clone, checked and fetched; the working directory is
# the clone afterwards. $1 = owner/repo, $2 = its slug. Dies when the clone
# cannot be trusted, so a caller that must go on runs it in a subshell.
review_clone_prepare() {
  local repo="$1" slug="$2"
  # A dedicated checkout, never the one being worked in: `gh pr checkout`
  # there would hand the reviewer uncommitted work as part of the PR.
  #
  # What proves it is this tool's own clone sits outside the clone, beside the
  # locks. The marker used to live in the clone, which is precisely the
  # directory the reviewer may write to: deleting one file made every later
  # tick refuse to run, so the reviewed party could switch its own reviewer off.
  local clone="$CLONE_ROOT/$slug" marker="$MARKER_DIR/$slug"
  # First, before anything is cloned. A refusal that fires after `gh repo clone`
  # has run and the record has been written is not a refusal: the operator who
  # disowned a clone and deleted the directory would get it cloned again, the
  # record written for it, and only then the error — and once the `.disowned`
  # file goes, the tick proceeds against a checkout nobody re-authorised.
  if [ -f "$marker.disowned" ]; then
    die "$clone is marked disowned ($marker.disowned) — remove that file to let this tool use it again"
  fi
  if [ ! -d "$clone/.git" ]; then
    log "creating the review checkout at $clone"
    mkdir -p "$CLONE_ROOT"
    gh repo clone "$repo" "$clone" || die "cannot clone $repo into $clone"
    mkdir -p "$MARKER_DIR"
    printf '%s\n' "$clone" >"$marker"
  fi
  # A clone from before the record moved outside has nothing out here to speak
  # for it, and upgrading must not make every existing job refuse to run until
  # somebody deletes a checkout by hand. What it is adopted on is deliberately
  # not a file in the clone: the whole point of the move was that the reviewed
  # party can write in there. Reading a marker out of the tree — even a marker
  # this tool wrote — hands the decision back, because a branch can ship a file
  # of that name and the next checkout restores it however often it is deleted.
  #
  # The evidence is the two things a branch cannot touch: the clone sits at the
  # path this tool derives from the repository name, and its `origin` is that
  # repository. Neither is in the tree.
  # Equality, through the same parser the rest of the tool uses — not a
  # substring. `case "$origin" in *"$repo"*)` accepts
  # `github.com/acme/tool-v2` for `acme/tool`, and the mismatch that follows is
  # silent and expensive: the fetch and `gh pr checkout` resolve against the
  # clone's remote while the briefing and the posted review are fetched and
  # sent with `--repo`, so the reviewer gets a working tree from one repository
  # and a briefing from another.
  #
  # `.disowned` beside the record, because adoption on sight would otherwise
  # make the guard self-granting: deleting the record to refuse a clone would
  # be undone by the next tick, and there would be no way back short of
  # deleting the checkout.
  if [ ! -f "$marker" ] && [ -d "$clone/.git" ]; then
    local origin=""
    origin="$(repo_of "$clone" 2>/dev/null || echo "")"
    if [ "$origin" = "$repo" ]; then
      mkdir -p "$MARKER_DIR"
      printf '%s\n' "$clone" >"$marker"
      log "adopting the existing checkout at $clone; its record now lives at $marker"
    fi
  fi
  # Whatever the old marker was, it is not consulted any more, and a file the
  # reviewer can write should not be left looking like it means something.
  rm -f "$clone/$LEGACY_MARKER" 2>/dev/null || true
  [ -f "$marker" ] || die "$clone is not recorded as a review clone of this tool's (no $marker) — refusing to run in what may be a working checkout"

  # Before the fetch, not only before the reviewer. `.git` is the one guarded
  # name this tick reads itself, outside any sandbox: a link planted there —
  # by a previous tick's checkout, or by hand — is followed by `git fetch` and
  # `gh pr checkout` below, long before `run_reviewer` looks at it.
  if [ -L "$clone/.git" ]; then
    die ".git in $clone is a symlink — refusing to fetch or check out through it"
  fi

  cd "$clone"
  worktree_prune "$clone"
  clone_git fetch --quiet origin || die "git fetch failed in $clone"
}
