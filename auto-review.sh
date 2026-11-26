#!/bin/bash
# BEGIN-USAGE
# Review open pull requests, unattended, for every project registered on the
# machine. The tick runs in the auto-review container (the design docs).
#
# Usage:
#   auto-review token <path>            store this repository's token
#   auto-review claude-token            store the reviewer's own login token
#   auto-review credential set <harness>  validate, check and store a harness
#                                       credential read from stdin
#   auto-review credential list         each harness: present or missing, age, last check
#   auto-review login <harness>         run the harness's login flow, then credential set
#   auto-review setup <owner/repo> [--all] [--self-review]
#                                       register, clone and check a project in one step
#   auto-review pause <repo> [--reason T]   stop reviewing a project (its clone stays)
#   auto-review resume <repo>           review it again
#   auto-review forget <repo>           drop a project from the registry
#   auto-review set   <repo> <key> <val>  change a repo in the machine registry
#                                       (model, harness, interval and slots are the
#                                       machine's: use set-global)
#   auto-review set-global <key> <val>  change a machine-wide setting
#   auto-review registry show|import    print the registry / replace it from stdin
#   auto-review models [harness]        the models each harness offers, as JSON
#   auto-review status --json           the missing or short tokens, the harnesses in fault
#   auto-review tick                    one machine tick: every registered project
#   auto-review tick  <path> [flags]    one pass over one checkout
#   auto-review list                    the registered projects
#
# <path> is a git checkout. The repository is read from its origin, so that is
# the only argument any command needs.
#
# Flags (`tick <path>`):
#   --all             every open PR, not only the assigned ones
#   --self-review     include PRs the reviewing account wrote
#   --skip-branch P   never review a head branch matching glob P
#                     (repeatable; --review N ignores it)
#   --skip-label P    the same, against every label on the PR
#   --skip-bots       skip PRs GitHub says an app opened
#   --skip-if-only G  when EVERY changed file matches one of these globs, post
#                     a one-line skip instead of a review (repeatable)
#   --model N         which model reviews (default sonnet)
#   --small-model N   the model for a diff under --small-under
#   --small-under N   lines of patch below which --small-model reviews
#                     (both or neither)
#   --max N           reviews per tick (default 2)
#   --dry-run         print the selection, spend nothing
#   --review N        review PR N now, whatever is already on it
#
# A project with generated or low-risk trees might carry:
#   --skip-if-only '**/__snapshots__/**' --skip-if-only '.changeset/**'
#   --skip-if-only '**/*.md' --skip-if-only '**/*.test.*'
#   --skip-if-only '**/*.spec.*' --skip-if-only 'tests/**'
#   --small-model haiku --small-under 100
# Scripts, infrastructure and `.github/workflows/**` are deliberately absent
# from that list: they stay reviewed.
#
# `token` reads the clipboard (pbpaste; under WSL, Windows' clipboard through
# powershell.exe; on other Linux there is none), or stdin when you pipe into
# it. It writes the file 0600 and prints which account the token belongs to; a
# rejected token is not stored.
#
# `claude-token` is the same for the credential the reviewer itself runs on —
# one per machine, not one per repository. Make it with `claude setup-token`.
# Without it the reviewer uses your interactive login, which expires; see the
# comment on load_claude_token for why that stops the job.
# END-USAGE
#
# The state is GitHub's. A pull request needs reviewing when no formal review
# on it carries a commit_id equal to its headRefOid; posting the review is what
# records the work. Nothing is written down locally — see the design docs.
#
# That state says a commit is unreviewed and nothing about what was already
# said, so every review is handed the pull request's own discussion and told
# not to raise a point that has been answered — see collect_history.
#
set -euo pipefail

PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

# Darwin or Linux, read once. Everything that differs between the two is
# behind a test of this — the reviewer's sandbox, the clipboard
# and `stat` — and nothing else is.
OS="$(uname -s)"
# Where the tokens are kept. On Linux that is memory: the user's runtime
# directory is a tmpfs, so a reboot leaves nothing readable behind and the
# tokens come back by whoever put them there (upstream issue). The
# fallback is computed from the uid because a logon task under `wsl --exec` has
# no XDG_RUNTIME_DIR, and /run/user/<uid> is where it would have pointed. On
# macOS launchd has no such folder, so the home directory stays. A file left in
# ~/.config/auto-review by an earlier version is not read: no fallback to it.
if [ "$OS" = Linux ]; then
  TOKEN_DIR="${AUTO_REVIEW_TOKEN_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/auto-review}"
else
  TOKEN_DIR="${AUTO_REVIEW_TOKEN_DIR:-$HOME/.config/auto-review}"
fi
CLONE_ROOT="${AUTO_REVIEW_CLONE_ROOT:-$HOME/.cache/auto-review}"
# The uid the gate runs as in the machine container; it owns /run/auto-review
# and /var/lib/auto-review (0700), so every docker exec goes in as it.
AUTO_REVIEW_GATE_UID="${AUTO_REVIEW_GATE_UID:-10001}"
# Not inside the clone: the clone is the one directory the reviewer's sandbox
# may write to, so anything the tick depends on that lives in there is the
# untrusted party's to delete or forge. A deleted marker made every later tick
# refuse to run, and looks exactly like a repository where nothing is happening.
MARKER_DIR="$CLONE_ROOT/clones"
# The old marker, written inside the clone. Neither read nor written any more —
# a clone from before the move is adopted on its path and its origin, and this
# is deleted on sight so a file the reviewer can write stops looking like it
# decides anything.
LEGACY_MARKER=".auto-review-clone"
# The reviewer is told to open with this and the shell refuses anything that
# does not. It is a receipt: only a run that read the system prompt can produce
# it, so an error message arriving on the same channel cannot be mistaken for a
# review. Changing it is fine; changing it in only one of the two places is not,
# which is why it is a variable.
REVIEW_SENTINEL="AUTO-REVIEW-BEGIN"
REVIEWER_PROFILE=""
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# Through any symlinked install: reviewer.sb sits beside the real script, and
# `dirname` of a link in ~/.local/bin points at the link's directory instead.
while [ -L "$SELF" ]; do
  _link="$(readlink "$SELF")"
  case "$_link" in
    /*) SELF="$_link" ;;
    *) SELF="$(cd "$(dirname "$SELF")" && cd "$(dirname "$_link")" && pwd)/$(basename "$_link")" ;;
  esac
done

# Sourced for pure core evaluation functions.
# shellcheck source=lib/core.sh
source "/usr/local/lib/auto-review/lib/core.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/core.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/core.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/core.sh"

# Sourced for code platform adapter (upstream issue).
# shellcheck source=adapters/code/github.sh
source "/usr/local/lib/auto-review/adapters/code/github.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/adapters/code/github.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/adapters/code/github.sh" 2>/dev/null || \
  source "$(dirname "$0")/adapters/code/github.sh"

# Sourced for task tracker adapter (upstream issue).
# shellcheck source=adapters/task/github-issues.sh
source "/usr/local/lib/auto-review/adapters/task/github-issues.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/adapters/task/github-issues.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/adapters/task/github-issues.sh" 2>/dev/null || \
  source "$(dirname "$0")/adapters/task/github-issues.sh"

# Harness adapters (upstream issue) are loaded by name when a review
# runs: the harness H is the file adapters/harness/H.sh and nothing else.
# Sets HARNESS_PREFIX to the P of its harness_P_* functions, found by the
# *_execute function it defines.
harness_dirs() {
  local dir
  # AUTO_REVIEW_ADAPTER_DIR holds harness/<name>.sh and is searched first
  # (upstream issue), so a harness can be added without touching the tool.
  if [ -n "${AUTO_REVIEW_ADAPTER_DIR:-}" ]; then
    printf '%s
' "$AUTO_REVIEW_ADAPTER_DIR/harness"
  fi
  for dir in /usr/local/lib/auto-review "$(dirname "$SELF")" "$(dirname "${BASH_SOURCE[0]:-$0}")"; do
    printf '%s
' "$dir/adapters/harness"
  done
}

harness_load() {
  local name="$1" dir file="" prefix
  case "$name" in '' | *[!a-z0-9-]*) return 1 ;; esac
  while IFS= read -r dir; do
    if [ -f "$dir/$name.sh" ]; then
      file="$dir/$name.sh"
      break
    fi
  done < <(harness_dirs)
  [ -n "$file" ] || return 1
  prefix="$(bash -c '. "$1" >/dev/null 2>&1; declare -F' _ "$file" 2>/dev/null \
    | awk '!done && $3 ~ /^harness_.*_execute$/ { sub(/^harness_/, "", $3); sub(/_execute$/, "", $3); print $3; done=1 }')"
  [ -n "$prefix" ] || return 1
  # shellcheck disable=SC1090 # the adapter is chosen at run time
  . "$file" || return 1
  HARNESS_PREFIX="$prefix"
}

# shellcheck source=lib/scheduler.sh
source "/usr/local/lib/auto-review/lib/scheduler.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/scheduler.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/scheduler.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/scheduler.sh"

# shellcheck source=lib/active-status.sh
source "/usr/local/lib/auto-review/lib/active-status.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/active-status.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/active-status.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/active-status.sh"

# shellcheck source=lib/pending.sh
source "/usr/local/lib/auto-review/lib/pending.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/pending.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/pending.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/pending.sh"

# shellcheck source=lib/review-clone.sh
source "/usr/local/lib/auto-review/lib/review-clone.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/review-clone.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/review-clone.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/review-clone.sh"

# shellcheck source=lib/machine-tick.sh
source "/usr/local/lib/auto-review/lib/machine-tick.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/machine-tick.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/machine-tick.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/machine-tick.sh"

# Sourced for structured machine marks (upstream issue).
# shellcheck source=lib/machine-mark.sh
source "/usr/local/lib/auto-review/lib/machine-mark.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/machine-mark.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/machine-mark.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/machine-mark.sh"

# Sourced for registry and daemon management (upstream issue).
# shellcheck source=lib/registry.sh
source "/usr/local/lib/auto-review/lib/registry.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/registry.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/registry.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/registry.sh" 2>/dev/null || true

# Which models a harness offers, and the checks built on it (upstream issue).
# shellcheck source=lib/harness-models.sh
source "/usr/local/lib/auto-review/lib/harness-models.sh" 2>/dev/null ||   source "$(dirname "$SELF")/lib/harness-models.sh" 2>/dev/null ||   source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/harness-models.sh" 2>/dev/null ||   source "$(dirname "$0")/lib/harness-models.sh"

# Token minimums, the harness fault files and `status` (upstream issue).
# shellcheck source=lib/token-status.sh
source "/usr/local/lib/auto-review/lib/token-status.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/token-status.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/token-status.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/token-status.sh"

# The reviewer's prompt text, read from prompt/*.md (upstream issue).
# shellcheck source=lib/prompt.sh
source "/usr/local/lib/auto-review/lib/prompt.sh" 2>/dev/null ||   source "$(dirname "$SELF")/lib/prompt.sh" 2>/dev/null ||   source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/prompt.sh" 2>/dev/null ||   source "$(dirname "$0")/lib/prompt.sh"

# credential set|list and login (upstream issue).
# shellcheck source=lib/credential.sh
source "/usr/local/lib/auto-review/lib/credential.sh" 2>/dev/null ||   source "$(dirname "$SELF")/lib/credential.sh" 2>/dev/null ||   source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/credential.sh" 2>/dev/null ||   source "$(dirname "$0")/lib/credential.sh"

# setup, pause and resume (upstream issue).
# shellcheck source=lib/setup.sh
source "/usr/local/lib/auto-review/lib/setup.sh" 2>/dev/null ||   source "$(dirname "$SELF")/lib/setup.sh" 2>/dev/null ||   source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/setup.sh" 2>/dev/null ||   source "$(dirname "$0")/lib/setup.sh"

# shellcheck source=lib/daemon.sh
source "/usr/local/lib/auto-review/lib/daemon.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/daemon.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/daemon.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/daemon.sh" 2>/dev/null || true

# shellcheck source=lib/clone.sh
source "/usr/local/lib/auto-review/lib/clone.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/clone.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/clone.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/clone.sh"

# shellcheck source=lib/worktree.sh
source "/usr/local/lib/auto-review/lib/worktree.sh" 2>/dev/null ||   source "$(dirname "$SELF")/lib/worktree.sh" 2>/dev/null ||   source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/worktree.sh" 2>/dev/null ||   source "$(dirname "$0")/lib/worktree.sh"

# shellcheck source=lib/reviewer-uid.sh
source "/usr/local/lib/auto-review/lib/reviewer-uid.sh" 2>/dev/null || \
  source "$(dirname "$SELF")/lib/reviewer-uid.sh" 2>/dev/null || \
  source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/reviewer-uid.sh" 2>/dev/null || \
  source "$(dirname "$0")/lib/reviewer-uid.sh"

REVIEW_ALL=0
SELF_REVIEW=0
DRY_RUN=0
MAX_PRS="${AUTO_REVIEW_SLOTS:-${AUTO_REVIEW_MAX_PRS:-2}}"
# Head-branch globs that are never reviewed, one per line. A string rather than
# an array: this file runs under macOS's /bin/bash 3.2, where an empty array
# expanded under `set -u` is an error, and the guard for that is already
# cluttering `cmd_run`.
SKIP_BRANCHES=""
# The same, matched against every label the pull request carries. no-review is
# there unless a flag adds to it: the label is the one mute a person can apply
# from the pull request's own page.
SKIP_LABELS="no-review"$'\n'
SKIP_BOTS=0
# The close reads, in tokens, past which the reviewer is told to name in its plan
# which code it skims (upstream issue). A budget, not a ceiling:
# the review always runs. About 19 tokens of context per line of patch, measured
# over 983 reviews on 2026-11-04. Machine-wide: set-global read_budget.
READ_BUDGET="${AUTO_REVIEW_READ_BUDGET:-150000}"
READING_OVER=0
# What counts as a test, for the table of files. Built in, unlike --skip-if-only: the
# question is what somebody had to write and judge, and the answer does not
# change from one project to the next, while a job's flags would. `*` crosses
# `/`, see path_glob_matched.
TEST_PATHS='**/*.test.*
**/*.spec.*
**/__tests__/**
**/tests/**
**/test/**
**/*_test.*
**/test_*.py'
# Path globs, one per line. When every file the pull request changes matches
# one of them the tick posts a skip instead of running the model. Empty is
# off; there are no built-in defaults, because what counts as low-risk is the
# project's call and belongs in its job's flags.
SKIP_IF_ONLY=""
# A cheaper model for a small diff. Both empty/0 is off; parse_flags refuses
# one without the other.
SMALL_MODEL=""
SMALL_UNDER=0
# What `gh pr list` is asked for in one call. Not a knob: it is here so the
# tick can tell "50 open pull requests" from "50 and an unknown number this
# never saw", which are the same answer from the API's side.
LIST_LIMIT=50
# Named here rather than left to the machine.
#
# `claude -p` with no --model takes the model out of ~/.claude/settings.json,
# which is the interactive setting — so an unattended job silently changed
# model whenever the owner changed theirs, and nothing in the log said which
# one wrote a review. Two jobs on one machine could not differ either.
#
# Sonnet by default because the work is bounded: read a staged patch, name what
# breaks and on what input. The reasons to reach for a larger model — a long
# unfamiliar codebase, an open-ended design question — are not what a review of
# one diff is, and this runs on every push of every pull request.
MODEL="${AUTO_REVIEW_MODEL:-sonnet}"
# A patch over this many lines, or this many files, is planned before it is read
# and the plan is posted with the review (upstream issue). Machine-wide:
# set-global plan_over, set-global plan_over_files.
PLAN_OVER="${AUTO_REVIEW_PLAN_OVER:-1500}"
PLAN_OVER_FILES="${AUTO_REVIEW_PLAN_OVER_FILES:-40}"
READING_PLAN=0
# One pull request, reviewed whatever its head already carries. Empty unless
# `--review N` was typed; never stored in a job's flags.
REVIEW_ONLY=""
# Set by collect_material: the base branch the patch was built against.
MATERIAL_BASE=""
# Which model reviews this one pull request — MODEL, or SMALL_MODEL for a
# diff under SMALL_UNDER. Set per pull request in the tick.
REVIEW_MODEL=""
# Agent harness to execute the review (claude-code, agy).
HARNESS="${AUTO_REVIEW_HARNESS:-claude-code}"
# The head the last successful post_review was against; a machine tick worker
# reads it to cache the decision.
REVIEW_POSTED_SHA=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
# stderr, not stdout: several of these fire inside a $(…) substitution, where
# anything on stdout is captured into a variable instead of reaching the
# terminal. `run -h` failed silently for exactly that reason.
die() {
  log "ERROR: $*" >&2
  exit 1
}
# Brings an old registry up to date before a verb reads it. A failed write
# leaves the registry as it was, and the verb goes on with that.
migrate_registry() {
  registry_migrate "$REGISTRY_DEFAULT_FILE" || log "the registry could not be migrated; going on with it as it is" >&2
}
# Between the markers rather than by line number: the range went stale twice
# while the help text was being edited, and a wrong range is silent.
usage() {
  sed -n '/^# BEGIN-USAGE$/,/^# END-USAGE$/p' "$SELF" |
    sed '1d;$d' | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Every subcommand takes a path first. Catch a flag or a typo here rather than
# letting `cd` report it in its own vocabulary.
resolve_path() {
  case "$1" in
    -*) die "expected a path, got the flag $1 — flags come after it" ;;
  esac
  [ -d "$1" ] || die "$1 is not a directory"
  (cd "$1" && pwd)
}

# --- shared -------------------------------------------------------------

parse_flags() {
  FLAGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)
        REVIEW_ALL=1
        FLAGS+=("$1")
        ;;
      --self-review)
        SELF_REVIEW=1
        FLAGS+=("$1")
        ;;
      # A pull request nobody wrote by hand. The generated release PR is the
      # case this exists for: its diff is a version bump and a changelog the
      # tool assembled, so every review of it says "no findings" at full price,
      # every time the branch moves. Unassigning does not mute it under --all,
      # and draft is not something the generator sets.
      --skip-branch)
        shift
        [ -n "${1:-}" ] || die "--skip-branch takes a branch name or a glob"
        SKIP_BRANCHES="${SKIP_BRANCHES}${1}"$'\n'
        FLAGS+=(--skip-branch "$1")
        ;;
      # The per-pull-request half of the same idea, and the one to reach for
      # first: a label is put on from the pull request's own page, by whoever is
      # looking at it, and it takes effect on the next tick. A branch glob is a
      # standing rule about a class of pull request and only changes when the
      # job is reinstalled.
      --skip-label)
        shift
        [ -n "${1:-}" ] || die "--skip-label takes a label name or a glob"
        SKIP_LABELS="${SKIP_LABELS}${1}"$'\n'
        FLAGS+=(--skip-label "$1")
        ;;
      # Everything GitHub calls an app: the release generator, dependabot,
      # renovate. Covers the ones whose branch names are not worth learning —
      # `--skip-branch` still exists for a generator that commits under a
      # person's account, which is how the release PR that prompted all this
      # was authored.
      --skip-bots)
        SKIP_BOTS=1
        FLAGS+=("$1")
        ;;
      # Removed with an earlier change: a size is not a reason to refuse a review any more.
      --max-diff)
        die "--max-diff is gone: nothing is refused for its size. The budget is machine-wide: set-global read_budget N (tokens)"
        ;;
      # A pull request whose every file is one a review adds nothing to —
      # regenerated snapshots, a changeset, prose. Posted rather than skipped,
      # for the same reason every shell-written line posts: the review's commit_id is what
      # records the head as done, so the sentence is said once per push.
      --skip-if-only)
        shift
        [ -n "${1:-}" ] || die "--skip-if-only takes a path glob"
        SKIP_IF_ONLY="${SKIP_IF_ONLY}${1}"$'\n'
        FLAGS+=(--skip-if-only "$1")
        ;;
      --small-model)
        shift
        [ -n "${1:-}" ] || die "--small-model takes a model alias or name"
        SMALL_MODEL="$1"
        FLAGS+=(--small-model "$1")
        ;;
      --small-under)
        shift
        case "${1:-}" in
          '' | *[!0-9]* | 0) die "--small-under takes a number of lines, at least 1" ;;
        esac
        SMALL_UNDER="$1"
        FLAGS+=(--small-under "$1")
        ;;
      --dry-run) DRY_RUN=1 ;;
      # Deliberately not added to FLAGS: a job that carried this would review
      # the same pull request every minute for ever. It is a thing you type.
      --review)
        shift
        case "${1:-}" in
          '' | *[!0-9]*) die "--review takes a pull request number" ;;
        esac
        REVIEW_ONLY="$1"
        ;;
      --max)
        shift
        MAX_PRS="$1"
        FLAGS+=(--max "$1")
        ;;
      # An alias (`sonnet`, `opus`) or a full name — whatever `claude --model`
      # takes. Not validated here: the list of models is the runtime's to know,
      # and a name it rejects fails the run with its own message, in the log,
      # rather than this shell guessing at what exists.
      --model)
        shift
        [ -n "${1:-}" ] || die "--model takes a model alias or name"
        MODEL="$1"
        FLAGS+=(--model "$1")
        ;;
      --harness)
        shift
        [ -n "${1:-}" ] || die "--harness takes a harness name (claude-code, agy)"
        HARNESS="$1"
        FLAGS+=(--harness "$1")
        ;;
      *) die "unknown flag: $1" ;;
    esac
    shift
  done
  # One without the other is a job that looks configured and never uses it.
  if [ -n "$SMALL_MODEL" ] && [ "$SMALL_UNDER" = 0 ]; then
    die "--small-model needs --small-under N"
  fi
  if [ -z "$SMALL_MODEL" ] && [ "$SMALL_UNDER" != 0 ]; then
    die "--small-under needs --small-model N"
  fi
}

# Is CI still working on this commit?
#
# Not `gh pr checks`. That reads GraphQL's statusCheckRollup, which needs the
# **Checks** permission — and a fine-grained token cannot be given one: Checks
# is a GitHub App permission and does not appear in the token UI at all. The
# call fails with `Resource not accessible by personal access token`, which is
# not the exit code the old gate looked for, so it never postponed anything.
# Observed 2026-08-11, after the documented scopes had been granted.
#
# The two things that rollup combines are readable one at a time, with
# permissions the token can actually hold:
#   workflow runs   Actions: read
#   everything else Commit statuses: read
#
# Unreadable is not the same as settled: say so and let the review proceed,
# which is what the old behaviour amounted to anyway — but visibly.
#
# Three things are not the same and the log has to keep them apart:
#   settled            both endpoints answered, nothing is running
#   no CI at all       both answered, with zero runs and zero statuses — which
#                      is a settled repository, not a broken gate
#   cannot look        an endpoint refused, most often a missing permission
# The last one is tracked per source rather than as one flag over both. A token
# holding `commit statuses: read` but not `actions: read` made the status half
# answer, which set the flag, which silenced the notice — and the tick reviewed
# without ever having been able to see a workflow run. Half a view reported as
# a whole one is the failure this notice exists to prevent.
# Delegated to platform adapter and lib/core.sh (upstream issue).
ci_pending() {
  platform_ci_pending "$@"
}

only_base_merges_since() {
  platform_only_base_merges_since "$@"
}

# One per machine, not one per repository: this is the credential `claude`
# itself runs on, and every job on this machine reviews with the same one.
CLAUDE_TOKEN_FILE="$TOKEN_DIR/claude.token"
AGY_TOKEN_FILE="$TOKEN_DIR/antigravity-oauth-token"

# Why this file exists at all.
#
# Without it the reviewer runs on the interactive login in the Keychain, whose
# access token is short-lived. Refreshing it means writing the new one back —
# and the reviewer runs under a profile whose whole content is `deny
# file-write*` plus three allowed subpaths. Reading the stored credential
# works, saving a refreshed one does not, so the reviewer is fine for exactly
# as long as something outside the sandbox keeps the stored token fresh. That
# something was the owner using `claude` by hand.
#
# Measured on 2026-08-17, in this order: two ticks in a row died in five
# seconds with `401 OAuth access token has expired`; the same `claude -p` run
# outside the sandbox succeeded; the next tick, seconds later and unchanged,
# reviewed and posted. Nothing about the job changed between the second and
# third — only that something else had refreshed the token in between. A job
# that works only while its owner happens to be using the same CLI is not
# unattended.
#
# A token from `claude setup-token` does not expire on that schedule and needs
# no refresh, so there is nothing for the sandbox to deny. It is handed over in
# the environment, which is the one thing the profile cannot cover either way.
#
# Deliberately the opposite of GH_TOKEN, which is stripped from the reviewer's
# environment: the reviewer makes no GitHub calls, so that token would be
# capability it has no use for, while this one is what it authenticates with.
load_claude_token() {
  [ -r "$CLAUDE_TOKEN_FILE" ] || return 1
  CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' <"$CLAUDE_TOKEN_FILE")"
  [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || return 1
  export CLAUDE_CODE_OAUTH_TOKEN
  return 0
}

load_token() {
  local file
  file="$(token_file_for_read "$1")"
  [ -r "$file" ] || die "no token for $(repo_of "$1") — run: $(basename "$SELF") token $1"
  GH_TOKEN="$(tr -d '[:space:]' <"$file")"
  export GH_TOKEN
  # Every job runs under its own token rather than switching the host's active
  # gh account: `gh auth switch` is global, and a background job flipping it
  # would change the account under an interactive terminal mid-command.
}

# --- token --------------------------------------------------------------

# The clipboard, where there is one this shell can read. pbpaste on macOS.
# Under WSL the clipboard that holds a token copied out of a browser is
# Windows', reachable through interop as `powershell.exe Get-Clipboard` — it
# ends lines in CRLF, which the `tr -d '[:space:]'` after it already removes.
# A Linux with neither has no answer here worth guessing at (X11, Wayland, a
# headless box): pipe the token in.
has_clipboard() {
  command -v pbpaste >/dev/null || command -v powershell.exe >/dev/null
}
clipboard() {
  if command -v pbpaste >/dev/null; then
    pbpaste
  else
    powershell.exe -NoProfile -Command Get-Clipboard
  fi
}
copy_to_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  elif command -v clip.exe >/dev/null 2>&1; then
    clip.exe
  elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command '$input | Set-Clipboard' 2>/dev/null
  elif command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  else
    return 1
  fi
}

cmd_token() {
  local path repo file
  path="$(resolve_path "$1")"
  repo="$(repo_of "$path")"
  file="$(token_file_for "$path")"

  mkdir -p "$TOKEN_DIR"
  chmod 700 "$TOKEN_DIR"

  # Created empty and locked down before anything is written into it: the
  # window between "file exists" and "file is 0600" is the only moment the
  # token would be world-readable.
  local tmp="$file.tmp.$$"
  : >"$tmp"
  chmod 600 "$tmp"

  if [ -t 0 ]; then
    has_clipboard || die "stdin is a terminal and there is no pbpaste (nor, under WSL, powershell.exe) — pipe the token in instead"
    clipboard | tr -d '[:space:]' >"$tmp"
  else
    tr -d '[:space:]' >"$tmp"
  fi

  [ -s "$tmp" ] || {
    rm -f "$tmp"
    die "nothing to store — the clipboard or stdin was empty"
  }
  mv "$tmp" "$file"

  # Prove the token works and say whose it is, without ever printing it. An
  # unattended job that authenticates as the wrong account is the failure this
  # command exists to catch.
  local who
  who="$(GH_TOKEN="$(cat "$file")" gh api user -q .login 2>/dev/null)" || {
    rm -f "$file"
    die "GitHub rejected that token — nothing stored"
  }

  echo "stored $file"
  echo "  repo      $repo"
  echo "  account   $who"
  echo "  reviews   pull requests assigned to $who"

  # Mirror into machine container tmpfs if container is running
  if [ -z "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] && command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "auto-review"; then
    local slug
    slug="$(slug_of "$path")"
    docker exec -i -u "$AUTO_REVIEW_GATE_UID" auto-review sh -c "cat > /run/auto-review/$slug.token && chmod 0600 /run/auto-review/$slug.token" <"$file" 2>/dev/null || true
  fi
}

# The same shape as cmd_token, and validated for the same reason: a job
# authenticating with something that does not work is not visible from the
# outside — it is five seconds of silence per tick, for ever.
#
# The check is worth what it costs because it is a real run. `claude` prefers
# this variable over the stored login and does **not** fall back to it: with a
# made-up value the run came back `is_error: true`, zero output tokens, zero
# cost (measured 2026-08-17). So a bad token is caught here for nothing, and a
# good one costs one small prompt — with the cache write, about thirty cents.
#
# ANTHROPIC_API_KEY and ANTHROPIC_AUTH_TOKEN are removed for the check and
# again where the reviewer is launched. Either of them in the environment would
# be what actually authenticates, and this command would then have proved a
# credential the job does not use.
cmd_claude_token() {
  mkdir -p "$TOKEN_DIR"
  chmod 700 "$TOKEN_DIR"

  local tmp="$CLAUDE_TOKEN_FILE.tmp.$$"
  : >"$tmp"
  chmod 600 "$tmp"

  if [ -t 0 ]; then
    has_clipboard || die "stdin is a terminal and there is no pbpaste (nor, under WSL, powershell.exe) — pipe the token in instead"
    clipboard | tr -d '[:space:]' >"$tmp"
  else
    tr -d '[:space:]' >"$tmp"
  fi

  [ -s "$tmp" ] || {
    rm -f "$tmp"
    die "nothing to store — the clipboard or stdin was empty"
  }

  # A token and nothing else. `claude setup-token` is interactive and writes
  # what it has to say — the URL to open, what to do there — to **stdout**, so
  # `claude setup-token | auto-review claude-token` sends all of it down the
  # pipe: the operator sees an empty terminal and this command receives 2689
  # bytes of instructions with a token somewhere inside. Measured, by writing
  # that pipe into the README and then running it.
  #
  # Without this the whole blob goes to the API as a credential, comes back
  # 401, and the message says the token did not authenticate — which is true
  # and useless, because the token was never the problem.
  if ! grep -qE '^sk-ant-[A-Za-z0-9_-]+$' "$tmp"; then
    rm -f "$tmp"
    die "that does not look like a single token. \`claude setup-token\` prints its instructions to stdout, so piping it here sends those too — run it on its own, copy the token, then run this with no arguments and it reads the clipboard"
  fi

  command -v claude >/dev/null || {
    rm -f "$tmp"
    die "claude is not on PATH"
  }
  command -v jq >/dev/null || {
    rm -f "$tmp"
    die "jq is not on PATH — the check reads the runtime's envelope as JSON"
  }

  # From a directory of its own: a CLAUDE.md in whatever the current directory
  # happens to be is read as instructions, and this check has no business
  # carrying somebody's project prompt into it.
  # stderr to a file of its own, for the same reason run_reviewer keeps one: a
  # runtime that exits without printing an envelope — an older CLI that does
  # not know `--tools`, a binary that will not start — leaves `$out` empty, and
  # this command would then blame a token it never managed to test.
  local out err rc=0
  out="$(mktemp)"
  err="$(mktemp)"
  harness_load claude-code || {
    rm -f "$tmp" "$out" "$err"
    die "no adapter for harness claude-code"
  }
  "harness_${HARNESS_PREFIX}_check_token" "$tmp" "$out" "$err" || rc=$?

  local ok
  ok="$(jq -r 'if type == "object" and .is_error == false
      and ((.usage.output_tokens // 0) > 0) then "yes" else "no" end' <"$out" 2>/dev/null || echo no)"
  if [ "$rc" != 0 ] || [ "$ok" != yes ]; then
    log "the runtime said: $(reviewer_error "$out" "$err")"
    rm -f "$tmp" "$out" "$err"
    die "that token did not authenticate — nothing stored"
  fi

  local cost
  cost="$(jq -r '.total_cost_usd // 0' <"$out" 2>/dev/null || echo 0)"
  rm -f "$out" "$err"
  mv "$tmp" "$CLAUDE_TOKEN_FILE"

  echo "stored $CLAUDE_TOKEN_FILE"
  echo "  used by   every auto-review job on this machine"
  echo "  checked   with one prompt, \$$cost"
  echo "  replaces  the interactive login, which the reviewer cannot refresh"

  # Mirror into machine container tmpfs if container is running
  if [ -z "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] && command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "auto-review"; then
    docker exec -i -u "$AUTO_REVIEW_GATE_UID" auto-review sh -c "cat > /run/auto-review/claude.token && chmod 0600 /run/auto-review/claude.token" <"$CLAUDE_TOKEN_FILE" 2>/dev/null || true
  fi
}

cmd_agy_token() {
  mkdir -p "$TOKEN_DIR"
  chmod 700 "$TOKEN_DIR"

  local tmp="$AGY_TOKEN_FILE.tmp.$$"
  : >"$tmp"
  chmod 600 "$tmp"

  if [ -t 0 ]; then
    local src_token="${HOME:-}/.gemini/antigravity-cli/antigravity-oauth-token"
    if ! command -v agy >/dev/null 2>&1; then
      rm -f "$tmp"
      die "agy is not on PATH — install Antigravity CLI first"
    fi

    if [ -s "$src_token" ] && agy models >/dev/null 2>&1; then
      log "agy is already authenticated."
    else
      log "Launching agy for authorization; please complete login in the browser..."
      local agy_out
      agy_out="$(mktemp)"
      (
        local elapsed=0
        while [ "$elapsed" -lt 300 ]; do
          if [ -s "$src_token" ] && agy models >/dev/null 2>&1; then
            sleep 1
            kill "$AGY_PID" 2>/dev/null || true
            break
          fi
          sleep 1
          elapsed=$((elapsed + 1))
        done
      ) &
      local watcher_pid=$!

      agy >"$agy_out" 2>&1 &
      AGY_PID=$!
      wait "$AGY_PID" 2>/dev/null || true
      kill "$watcher_pid" 2>/dev/null || true
      wait "$watcher_pid" 2>/dev/null || true

      if [ ! -s "$src_token" ] || ! agy models >/dev/null 2>&1; then
        cat "$agy_out" >&2
        rm -f "$agy_out" "$tmp"
        die "agy authorization did not complete — nothing stored"
      fi
      rm -f "$agy_out"
    fi

    tr -d '\r' <"$src_token" >"$tmp"
    [ -s "$tmp" ] || {
      rm -f "$tmp"
      die "antigravity token file at $src_token is empty — nothing stored"
    }
    mv "$tmp" "$AGY_TOKEN_FILE"

    echo "stored $AGY_TOKEN_FILE"
    echo "  used by   Antigravity (agy) harness on this machine"

    if copy_to_clipboard <"$AGY_TOKEN_FILE"; then
      echo "  copied to clipboard"
    else
      echo "  notice: could not copy directly to clipboard"
    fi

    echo "Command to copy token to clipboard manually:"
    if command -v pbcopy >/dev/null 2>&1; then
      echo "  pbcopy < $AGY_TOKEN_FILE"
    elif command -v clip.exe >/dev/null 2>&1; then
      echo "  clip.exe < $AGY_TOKEN_FILE"
    elif command -v wl-copy >/dev/null 2>&1; then
      echo "  wl-copy < $AGY_TOKEN_FILE"
    elif command -v xclip >/dev/null 2>&1; then
      echo "  xclip -selection clipboard < $AGY_TOKEN_FILE"
    else
      echo "  cat $AGY_TOKEN_FILE"
    fi
  else
    tr -d '\r' >"$tmp"
    [ -s "$tmp" ] || {
      rm -f "$tmp"
      die "nothing to store — stdin was empty"
    }
    mv "$tmp" "$AGY_TOKEN_FILE"
    echo "stored $AGY_TOKEN_FILE"
  fi

  if [ -z "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] && command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "auto-review"; then
    docker exec -i -u "$AUTO_REVIEW_GATE_UID" auto-review sh -c "cat > /run/auto-review/antigravity-oauth-token && chmod 0600 /run/auto-review/antigravity-oauth-token" <"$AGY_TOKEN_FILE" 2>/dev/null || true
  fi
}

# --- list ---------------------------------------------------------------

cmd_list() {
  migrate_registry
  registry_list "$@"
}

# --- tick ---------------------------------------------------------------

# Every token value this process holds: GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN and
# friends from the environment, and each *.token and antigravity-oauth-token in
# the token and lock directories. One per line. Values shorter than 8 characters
# are not credentials and would match anything.
held_token_values() {
  local d f v
  for v in "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${GH_ENTERPRISE_TOKEN:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}"; do
    [ "${#v}" -ge 8 ] && printf '%s\n' "$v"
  done
  for d in "${TOKEN_DIR:-}" "${AUTO_REVIEW_LOCK_DIR:-}"; do
    [ -n "$d" ] || continue
    for f in "$d"/*.token "$d/antigravity-oauth-token"; do
      [ -f "$f" ] && [ -r "$f" ] || continue
      v="$(tr -d '\r\n' <"$f" 2>/dev/null)"
      [ "${#v}" -ge 8 ] && printf '%s\n' "$v"
    done
  done
  return 0
}

# Pure: $1 = text, stdin = token values. Succeeds when the text holds any.
text_holds_token() {
  local text="$1" v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$text" in *"$v"*) return 0 ;; esac
  done
  return 1
}

# Posting a review, against the commit it was actually written about.
#
# `gh pr review` does not take a commit, and the API defaults `commit_id` to
# whatever the head is **at the moment of posting**. A review takes minutes;
# anything pushed while it runs takes that commit's place in the record. Both
# halves are wrong at once: the commit that was read is left looking unreviewed
# — except that no tick will ever come back to it, because it is no longer the
# head — and the commit nobody read is marked done, permanently, since this
# tool's entire idea of "reviewed" is a review carrying the head's sha.
#
# Measured here, on this branch, 2026-08-17: a review of `cfddba3` ran for
# eight minutes, a commit was pushed during it, and the review was recorded
# against `ed714fe` — a commit whose diff the reviewer never saw.
#
# So the sha is read out of the checkout the reviewer was handed and sent with
# the review. `gh api --input -` rather than `gh pr review`, because that is
# where the field exists.
post_review() {
  local repo="$1" pr="$2" body="$3" sha="$4" verdict="${5:-clean}" findings="${6:-0}"
  POST_REVIEW_ERROR_KIND=""
  POST_REVIEW_HTTP_STATUS=""
  POST_REVIEW_RETRYABLE="false"
  POST_REVIEW_REASON=""
  if [ -f "$body" ]; then
    local content
    content="$(cat "$body")"
    if text_holds_token "$content" < <(held_token_values); then
      log "#$pr: refusing to post — the review text contains a token value this job holds (value not logged)"
      POST_REVIEW_ERROR_KIND="text_holds_token"
      POST_REVIEW_HTTP_STATUS=""
      POST_REVIEW_RETRYABLE="false"
      POST_REVIEW_REASON="refusing to post — the review text contains a token value this job holds"
      return 1
    fi
    if [ -n "$sha" ]; then
      case "$content" in
        *"• Commit:"*)
          ;;
        *"_Automated review. Not an approval._"*)
          content="$(printf '%s\n' "$content" | sed "s/_Automated review\. Not an approval\._/_Automated review. Not an approval._ • Commit: ${sha:0:7}/")"
          ;;
        *"Automated review. Not an approval."*)
          content="$(printf '%s\n' "$content" | sed "s/Automated review\. Not an approval\./Automated review. Not an approval. • Commit: ${sha:0:7}/")"
          ;;
        *)
          content="$(printf '%s%s' "$content" "$(format_review_footer "$sha")")"
          ;;
      esac
    fi
    if ! parse_machine_mark "$content" >/dev/null 2>&1; then
      if [ -z "$verdict" ] || [ "$verdict" = "clean" -a "$findings" = "0" ]; then
        local first_line
        first_line="$(printf '%s\n' "$content" | awk 'NF { print; exit }')"
        case "$first_line" in
          '**No findings.'* | '**Skipped — generated files only.'*)
            verdict="clean"; findings=0 ;;
          '**Skipped — low-risk paths only.'*)
            verdict="skipped_low_risk"; findings=0 ;;
          '**Not reviewed.'*)
            verdict="refused_size"; findings=0 ;;
          '**'[0-9]*' finding'* | '**1 finding.'*)
            verdict="findings"
            local parsed_cnt
            parsed_cnt="$(printf '%s\n' "$first_line" | sed -n 's/^\*\*\([0-9][0-9]*\) finding.*/\1/p')"
            findings="${parsed_cnt:-1}"
            ;;
          *)
            verdict="malformed"; findings=0 ;;
        esac
      fi
      findings="${findings:-0}"
      content="$(format_review_with_mark "$content" "$sha" "$verdict" "$findings")"
    fi
    printf '%s\n' "$content" >"$body"
  fi
  local delays="${AUTO_REVIEW_POST_RETRY_DELAYS:-5 15 30}"
  local -a delay_arr=()
  read -r -a delay_arr <<<"$delays"
  local attempt=0 max_retries=3 cls cur_head=""
  while true; do
    if platform_post_review "$repo" "$pr" "$body" "$sha"; then
      POST_REVIEW_ERROR_KIND=""
      POST_REVIEW_HTTP_STATUS=""
      POST_REVIEW_RETRYABLE="false"
      POST_REVIEW_REASON=""
      # What a machine tick caches as decided.
      REVIEW_POSTED_SHA="$sha"
      return 0
    fi
    cur_head=""
    if [ "${POST_REVIEW_HTTP_STATUS:-}" = "422" ]; then
      cur_head="$(platform_pr_head_sha "$repo" "$pr" 2>/dev/null || true)"
    fi
    cls="$(classify_post_review_failure "${POST_REVIEW_HTTP_STATUS:-}" "${POST_REVIEW_STDERR:-}" "$sha" "$cur_head")"
    POST_REVIEW_ERROR_KIND="${cls%% *}"
    POST_REVIEW_RETRYABLE="${cls##* }"
    POST_REVIEW_REASON="$(scrub_reason "${POST_REVIEW_STDERR:-post_review failed}")"
    [ -n "$POST_REVIEW_REASON" ] || POST_REVIEW_REASON="post_review failed"
    if [ "$POST_REVIEW_RETRYABLE" != "true" ] || [ "$attempt" -ge "$max_retries" ] || [ "$attempt" -ge "${#delay_arr[@]}" ]; then
      return 1
    fi
    local wait_s="${delay_arr[$attempt]}"
    case "$wait_s" in
      '' | *[!0-9]*) wait_s=0 ;;
    esac
    log "#$pr: post_review transient failure (${POST_REVIEW_HTTP_STATUS:-transport}), retrying in ${wait_s}s"
    [ "$wait_s" -eq 0 ] || sleep "$wait_s"
    attempt=$((attempt + 1))
  done
}

# One pull request, reviewed in its own worktree $2 of the review clone. Runs
# with cmd_tick's locals in scope (repo and the rest); every way out returns 0
# so the caller can remove the worktree and go on to the next one.
review_pr_in_worktree() {
  local pr="$1" wt="$2"
  cd "$wt" || return 0
  # Detached: a local branch named after the head ref would collide with a
  # branch checked out elsewhere (the clone's main, for a fork PR from main).
  local checkout_err
  checkout_err="$(mktemp)"
  if ! gh pr checkout "$pr" --detach --force >/dev/null 2>"$checkout_err"; then
    local err_msg
    err_msg="$(scrub_reason "$(cat "$checkout_err" 2>/dev/null || true)")"
    rm -f "$checkout_err"
    log "#$pr: checkout failed, skipping"
    status_record_result "$repo" "$pr" "${PR_LISTED_SHA:-}" "failed" "checkout_failed" "" "${err_msg:-checkout failed}" "true"
    return 0
  fi
  rm -f "$checkout_err"
  # What the reviewer is about to be shown, and therefore what the review is
  # about — read here rather than taken from the listing, because this is the
  # tree it will read, and sent with the review so a push during it cannot
  # take the record.
  local reviewed_sha
  reviewed_sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
  if [ -z "$reviewed_sha" ]; then
    log "#$pr: cannot read the checked-out commit, skipping"
    status_record_result "$repo" "$pr" "${PR_LISTED_SHA:-}" "failed" "checkout_failed" "" "cannot read the checked-out commit" "true"
    return 0
  fi

  # Removed, not inspected. `gh pr checkout` has just written whatever the
  # branch ships, and two kinds of file in that tree are dangerous to have
  # sitting there:
  #
  #   the staged names — `.auto-review-*` are written below with `>`, which
  #   follows a symlink. A branch shipping `.auto-review-history.md` as a
  #   link to ~/.zshenv would have this shell truncate that file and fill it
  #   with rendered comment bodies the same author wrote. Deleting the link
  #   first means `>` creates a file; `rm` removes the link, never a target.
  #
  #   the config names — `.claude/`, `CLAUDE.md`, `CLAUDE.local.md` are read
  #   by the `claude` this tick starts with the clone as its working
  #   directory, and a project hook in one of them runs commands. The sandbox
  #   denies writes; it does not deny exec or the network.
  #
  # Deleting beats refusing, which is what this used to do. `ln -s AGENTS.md
  # CLAUDE.md` is an ordinary repository layout, and refusing it meant that
  # repository was never reviewed at all, on every tick, for ever. The clone
  # is disposable and the next checkout restores the tree; the reviewer reads
  # these files' contents in the diff either way.
  # The whole tree, not the root. The runtime picks up a `CLAUDE.md` sitting
  # in any directory it opens a file in, so `src/CLAUDE.md` next to a file
  # the reviewer will plausibly read is the same injection as the root one —
  # and this repository ships `claude/CLAUDE.md` today, so it is not a
  # hypothetical shape. `AGENTS.md` goes with them: it is the file the
  # `CLAUDE.md` symlink convention points at, so deleting the link and
  # leaving the target would be theatre.
  #
  # `rm -rf`, and no `-type` test on either side. A branch can commit a
  # *directory* called `CLAUDE.md`, or one called `.auto-review-pr.md`, and a
  # clearing that only removes files leaves it there — where the guard below,
  # which asks only about the name, refuses the review, every tick, for ever,
  # spending the checkout and six API calls each time. A tree entry of one of
  # these names is removed whatever kind of thing it is; the name is what
  # decides, because the name is all the runtime and the redirection care
  # about.
  if ! worktree_scrub "$wt"; then
    log "#$pr: could not clear the checkout of files that are read as instructions — skipping"
    status_record_result "$repo" "$pr" "$reviewed_sha" "failed" "worktree_scrub_failed" "" "could not clear the checkout of files that are read as instructions" "false"
    return 0
  fi
  # The perimeter is the worktree's, so it is built for each review.
  build_perimeter "$wt"

  # Inside the worktree, because the reviewer reads these with Read and a path
  # outside the working directory is the kind of thing a headless run
  # silently declines rather than asks about.
  local body history diff meta
  body="$(mktemp)"
  history="$wt/.auto-review-history.md"
  diff="$wt/.auto-review-diff.patch"
  meta="$wt/.auto-review-pr.md"
  # Both gates postpone rather than review. A briefing with a hole in it
  # still produces a confident review, and posting one marks the commit
  # reviewed for good — the next tick would never come back to it.
  local rc=0
  MATERIAL_ERROR=""
  collect_material "$repo" "$pr" "$diff" "$meta" || rc=$?
  if [ "$rc" = 2 ]; then
    # Nothing to review, and nothing a later tick would change. Posting is
    # what records the work, so record it rather than coming back for ever.
    # Same first line as every other review, for the same reason: whoever
    # sees this in a notification should not have to open it to find out
    # that nothing is being asked of them.
    printf '**No findings.** — this pull request has an empty diff, so there is nothing to review.\n' >"$body"
    format_review_footer "$reviewed_sha" >>"$body"
    if post_review "$repo" "$pr" "$body" "$reviewed_sha" "clean" 0; then
      log "#$pr: the diff is empty — said so and moved on"
      status_record_result "$repo" "$pr" "$reviewed_sha" "posted" "" "" "" "false"
    else
      log "#$pr: the diff is empty, and posting that failed"
      status_record_result "$repo" "$pr" "$reviewed_sha" "post_failed" "${POST_REVIEW_ERROR_KIND:-github_rejected}" "${POST_REVIEW_HTTP_STATUS:-}" "${POST_REVIEW_REASON:-posting empty diff notice failed}" "${POST_REVIEW_RETRYABLE:-false}"
    fi
    rm -f "$body" "$history" "$diff" "$meta"
    return 0
  fi
  if [ "$rc" != 0 ]; then
    log "#$pr: the material is incomplete, leaving it for the next tick"
    status_record_result "$repo" "$pr" "$reviewed_sha" "failed" "material_incomplete" "" "${MATERIAL_ERROR:-the material is incomplete}" "true"
    rm -f "$body" "$history" "$diff" "$meta"
    return 0
  fi
  local low_risk
  if low_risk="$(only_low_risk_paths "$MATERIAL_BASE")"; then
    {
      printf '**Skipped — low-risk paths only.**\n\n'
      printf 'Every file this pull request changes matches one of these globs, which this job is set not to review:\n\n'
      # shellcheck disable=SC2016 # literal backticks for markdown
      printf '%s' "$low_risk" | sed 's/^/- `/; s/$/`/'
      format_review_footer "$reviewed_sha"
    } >"$body"
    if post_review "$repo" "$pr" "$body" "$reviewed_sha" "skipped_low_risk" 0; then
      log "#$pr: only low-risk paths changed ($(printf '%s' "$low_risk" | tr '\n' ' ' | sed 's/ *$//')) — said so and moved on"
      status_record_result "$repo" "$pr" "$reviewed_sha" "posted" "" "" "" "false"
    else
      log "#$pr: only low-risk paths changed, and posting that failed"
      status_record_result "$repo" "$pr" "$reviewed_sha" "post_failed" "${POST_REVIEW_ERROR_KIND:-github_rejected}" "${POST_REVIEW_HTTP_STATUS:-}" "${POST_REVIEW_REASON:-posting low-risk skip notice failed}" "${POST_REVIEW_RETRYABLE:-false}"
    fi
    rm -f "$body" "$history" "$diff" "$meta"
    return 0
  fi
  # Before the table of files, so it lists what somebody wrote. See strip_generated.
  local generated="" generated_note="" kept marked
  kept="$(mktemp)"
  marked="$(mktemp)"
  if ! generated_by_attributes "$diff" "$MATERIAL_BASE" >"$marked" ||
    ! generated="$(strip_generated "$diff" "$kept" "$marked")" || ! mv "$kept" "$diff"; then
    log "#$pr: could not strip generated files from the patch, leaving it for the next tick"
    status_record_result "$repo" "$pr" "$reviewed_sha" "failed" "strip_generated_failed" "" "could not strip generated files from the patch" "true"
    rm -f "$kept" "$marked" "$body" "$history" "$diff" "$meta"
    return 0
  fi
  rm -f "$marked"
  if [ -n "$generated" ]; then
    # shellcheck disable=SC2016 # literal backticks for markdown
    generated_note="_Not read — generated files: $(printf '%s\n' "$generated" | awk -F'\t' '{ printf "%s`%s` (%d lines)", (NR > 1 ? ", " : ""), $1, $2 }')._"
    log "#$pr: left out generated files: $(printf '%s\n' "$generated" | awk -F'\t' '{ printf "%s%s (%d)", (NR > 1 ? ", " : ""), $1, $2 }')"
    if [ ! -s "$diff" ]; then
      printf '**Skipped — generated files only.**\n\n%s\n' "$generated_note" >"$body"
      format_review_footer "$reviewed_sha" >>"$body"
      if post_review "$repo" "$pr" "$body" "$reviewed_sha" "clean" 0; then
        log "#$pr: only generated files changed — said so and moved on"
        status_record_result "$repo" "$pr" "$reviewed_sha" "posted" "" "" "" "false"
      else
        log "#$pr: only generated files changed, and posting that failed"
        status_record_result "$repo" "$pr" "$reviewed_sha" "post_failed" "${POST_REVIEW_ERROR_KIND:-github_rejected}" "${POST_REVIEW_HTTP_STATUS:-}" "${POST_REVIEW_REASON:-posting generated-only skip notice failed}" "${POST_REVIEW_RETRYABLE:-false}"
      fi
      rm -f "$body" "$history" "$diff" "$meta"
      return 0
    fi
    printf '\n## left out of the patch\n\nGenerated files, not in %s and not to be reviewed:\n\n%s\n' \
      "$diff" "$(printf '%s\n' "$generated" | awk -F'\t' '{ printf "- %s (%d lines)\n", $1, $2 }')" >>"$meta"
  fi
  # The files of the patch sorted into kinds by the shell, so the reviewer reads
  # a table instead of guessing which of them are tests, config or vendored
  # code (upstream issue). Generated files are in it too, as
  # not read.
  {
    local vendored_paths generated_rows
    vendored_paths="$(mktemp)"
    generated_rows="$(mktemp)"
    vendored_by_attributes "$diff" "$MATERIAL_BASE" >"$vendored_paths" 2>/dev/null || : >"$vendored_paths"
    [ -z "$generated" ] || printf '%s\n' "$generated" >"$generated_rows"
    printf '\n## files in the patch\n\nSorted by the tool, not by the reviewer. kind, lines, path:\n\n'
    classify_paths "$diff" "$vendored_paths" "$generated_rows" | awk -F'\t' '{ printf "- %s, %d, %s\n", $2, $3, $1 }'
    rm -f "$vendored_paths" "$generated_rows"
  } >>"$meta"
  HISTORY_ERROR=""
  if ! collect_history "$repo" "$pr" "$history"; then
    log "#$pr: the discussion could not be read in full, leaving it for the next tick"
    status_record_result "$repo" "$pr" "$reviewed_sha" "failed" "history_incomplete" "" "${HISTORY_ERROR:-the discussion could not be read in full}" "true"
    rm -f "$body" "$history" "$diff" "$meta"
    return 0
  fi

  # A small diff goes to the cheaper model. The whole patch the reviewer will
  # read, tests included: 50 lines of code with 5000 of tests is not a small
  # thing to read.
  REVIEW_MODEL="$MODEL"
  local patch_lines
  patch_lines="$(wc -l <"$diff" | tr -d ' ')"
  if [ -n "$SMALL_MODEL" ] && [ "$patch_lines" -lt "$SMALL_UNDER" ]; then
    REVIEW_MODEL="$SMALL_MODEL"
  fi
  local patch_files
  patch_files="$(grep -c '^diff --git ' "$diff" || true)"
  READING_PLAN=0
  if plan_needed "$patch_lines" "${patch_files:-0}" "$PLAN_OVER" "$PLAN_OVER_FILES"; then
    READING_PLAN=1
  fi
  # What the kinds say must be read closely, against the read budget. Over it
  # the plan is required whatever the size, and has to say what is skimmed.
  local close_tokens
  close_tokens="$(close_read_estimate "$meta")"
  READING_OVER=0
  if [ "$close_tokens" -gt "$READ_BUDGET" ]; then
    READING_PLAN=1
    READING_OVER=1
    printf '\n## read budget\n\nThe files to read closely come to about %s tokens, past the read budget of %s. Say in your plan which source you skim.\n' \
      "$close_tokens" "$READ_BUDGET" >>"$meta"
  fi
  REVIEW_TIMEOUT_S="$(reviewer_timeout "$patch_lines" "${READING_PLAN:-0}")"
  log "#$pr: reviewing with $REVIEW_MODEL ($patch_lines lines of patch, ${patch_files:-0} files, plan: $READING_PLAN, close reads ~$close_tokens tokens of $READ_BUDGET)"
  status_review_begin "$repo" "$pr" "$reviewed_sha" "$patch_lines" "$REVIEW_MODEL" "$REVIEW_TIMEOUT_S"
  if ! run_reviewer "$pr" "$body" "$history" "$diff" "$meta"; then
    log "#$pr: the reviewer failed, leaving it for the next tick"
    status_review_end "$repo" "$pr" failed "$reviewed_sha" "${REVIEWER_FAIL_KIND:-reviewer_failed}" "" "${REVIEWER_FAIL_REASON:-the reviewer failed}" "${REVIEWER_FAIL_RETRYABLE:-true}"
    rm -f "$body" "$history" "$diff" "$meta"
    return 0
  fi

  # An empty body is rejected by the API anyway, and posting one would mark
  # the commit reviewed with nothing in it.
  if [ ! -s "$body" ] || ! grep -q '[^[:space:]]' "$body"; then
    log "#$pr: the reviewer produced nothing, leaving it for the next tick"
    status_review_end "$repo" "$pr" empty "$reviewed_sha" "reviewer_empty" "" "the reviewer produced nothing" "true"
    rm -f "$body" "$history" "$diff" "$meta"
    return 0
  fi
  rm -f "$history" "$diff" "$meta"

  [ -z "$generated_note" ] || printf '\n\n%s' "$generated_note" >>"$body"
  format_review_footer "$reviewed_sha" >>"$body"

  # Always --comment. An unattended approval would satisfy the very gate that
  # exists so a person looks at the change.
  if post_review "$repo" "$pr" "$body" "$reviewed_sha"; then
    log "#$pr: review posted against ${reviewed_sha:0:7}"
    status_review_end "$repo" "$pr" posted "$reviewed_sha" "" "" "" "false"
  else
    log "#$pr: posting failed, leaving it for the next tick"
    status_review_end "$repo" "$pr" post_failed "$reviewed_sha" "${POST_REVIEW_ERROR_KIND:-github_rejected}" "${POST_REVIEW_HTTP_STATUS:-}" "${POST_REVIEW_REASON:-posting review failed}" "${POST_REVIEW_RETRYABLE:-false}"
  fi
  rm -f "$body"
}

cmd_tick() {
  local path="$1"
  shift
  parse_flags "$@"
  path="$(resolve_path "$path")"
  local repo slug
  repo="$(repo_of "$path")"
  slug="$(slug_of "$path")"

  # After a reboot the tokens are not there until somebody puts them back, and
  # a timer that fires meanwhile is not a failure: it says so and leaves, with
  # status 0 so the unit does not show as failed. Nothing was asked of GitHub
  # and nothing is posted.
  if [ ! -r "$(token_file_for_read "$path")" ]; then
    log "no token for $repo — waiting; run: $(basename "$SELF") token $path"
    exit 0
  fi
  load_token "$path"
  command -v gh >/dev/null || die "gh is not on PATH"
  command -v claude >/dev/null || die "claude is not on PATH"
  # The reviewer's output is read as JSON, and a missing jq must not be found
  # out halfway through a review that has already been paid for.
  command -v jq >/dev/null || die "jq is not on PATH — the reviewer's output is read as JSON"
  # Here, with the others, and not where the reviewer is launched: dying from
  # inside the per-PR loop aborts the tick after the API calls have been spent,
  # skips every later pull request and leaves the staged files in the clone.
  if [ -z "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] && [ ! -f /.dockerenv ]; then
    if [ "$OS" = Linux ]; then
      command -v bwrap >/dev/null || die "bwrap is not on PATH — the reviewer does not run without it"
    else
      command -v sandbox-exec >/dev/null || die "sandbox-exec is not on PATH — the reviewer does not run without it"
      REVIEWER_PROFILE="$(dirname "$SELF")/reviewer.sb"
      [ -r "$REVIEWER_PROFILE" ] || die "cannot read the sandbox profile at $REVIEWER_PROFILE"
    fi
  fi

  # Said once per tick, because which credential the reviewer is about to use is
  # the difference between a job that keeps working and one that stops the next
  # time a token expires — and the log is the only place that answers it.
  local reviewer_auth="the interactive login"
  harness_load "${HARNESS:-claude-code}" || die "no adapter for harness ${HARNESS:-claude-code} (adapters/harness/<name>.sh)"
  if declare -F "harness_${HARNESS_PREFIX}_auth" >/dev/null; then
    REVIEWER_AUTH="$reviewer_auth"
    "harness_${HARNESS_PREFIX}_auth"
    reviewer_auth="$REVIEWER_AUTH"
  fi

  local me
  me="$(gh api user -q .login)" || die "the token is not valid"
  log "tick: $repo as $me, reviewing with $MODEL on $reviewer_auth$([ "$REVIEW_ALL" = 1 ] && echo " (--all)")$([ "$SELF_REVIEW" = 1 ] && echo " (--self-review)")"

  local list_args=(--repo "$repo" --state open --limit "$LIST_LIMIT" --json number,headRefOid,headRefName,baseRefName,isDraft,title,author,labels)
  # The default is deliberately narrow: a pull request nobody assigned to this
  # account is not this account's to review, and unassigning is how you mute a
  # PR without putting it back into draft.
  [ "$REVIEW_ALL" = 1 ] || list_args+=(--assignee "@me")

  # `--review N` is the escape hatch for a pull request whose head already
  # carries a review that should not count. That happens: a reviewer that
  # printed an error and exited zero had its message posted as the review, and
  # a posted review at the head **is** this tool's record that the commit is
  # done, so nothing came back to it. Everything else here decides what is
  # worth reviewing; this says which one, and every filter below is skipped
  # because the person typing it has already made that judgement.
  local open_prs
  if [ -n "$REVIEW_ONLY" ]; then
    open_prs="$(gh pr view "$REVIEW_ONLY" --repo "$repo" \
      --json number,headRefOid,headRefName,baseRefName,author,title,state,labels \
      -q 'select(.state == "OPEN") | [.number, .headRefOid, .baseRefName, "false", (.author.is_bot | tostring), .author.login, .headRefName, ([.labels[].name] | join("\u001f")), "", .title] | @tsv' 2>/dev/null |
      tr '\t' '\035' || echo "")"
    [ -n "$open_prs" ] || die "#$REVIEW_ONLY is not an open pull request on $repo"
    log "forcing a review of #$REVIEW_ONLY, whatever is already on it"
  else
    # `@tsv` rather than an interpolated string, now that a label and a title
    # sit in the same record: it escapes a tab inside a field instead of
    # emitting it, so a label somebody typed with a tab in it cannot shift
    # every field after it by one.
    #
    # Then the separator is translated to a group separator, and that is not
    # cosmetic. Tab is IFS *whitespace*, so `read` collapses a run of them: a
    # pull request with no labels arrived one field short, its title landed in
    # the labels field, and --skip-label was matched against the title. Caught
    # in testing, on the ordinary case of an unlabelled pull request. A
    # non-whitespace separator keeps empty fields, and @tsv is what guarantees
    # no field holds a tab for this translation to hit.
    #
    # Drafts are dropped in the loop below rather than filtered out here, and
    # that is not a rearrangement: the "listing came back full" check counts
    # these records against the number the API was asked for, so filtering
    # first meant one draft among fifty made it forty-nine, the check never
    # fired, and everything past fifty stayed invisible in exactly the silence
    # it was added to break. What is counted has to be what GitHub answered.
    open_prs="$(gh pr list "${list_args[@]}" \
      -q '.[] | [.number, .headRefOid, .baseRefName, (.isDraft | tostring), (.author.is_bot | tostring), .author.login, .headRefName, ([.labels[].name] | join("\u001f")), "", .title] | @tsv' |
      tr '\t' '\035')"
  fi

  if [ -z "$open_prs" ]; then
    log "nothing open to consider"
    exit 0
  fi

  # The listing answers at most $LIST_LIMIT and says nothing about what it left
  # out, so a repository busy enough to hit it has pull requests this job cannot
  # see — and from the log it looks exactly like a job with nothing to do.
  if [ -z "$REVIEW_ONLY" ] &&
    [ "$(printf '%s\n' "$open_prs" | wc -l | tr -d ' ')" -ge "$LIST_LIMIT" ]; then
    log "the listing came back full at $LIST_LIMIT open pull requests — anything past that is invisible to this tick"
  fi

  collect_pending "$repo" "$me" "$open_prs"
  local pending="$PENDING_PRS"

  pending="$(printf '%s' "$pending" | sed '/^$/d')"
  if [ -z "$pending" ]; then
    log "nothing to review"
    exit 0
  fi

  local total selected
  total="$(printf '%s\n' "$pending" | wc -l | tr -d ' ')"
  selected="$(printf '%s\n' "$pending" | head -n "$MAX_PRS")"
  # Every review spends subscription quota, and several projects tick against
  # the same pool without knowing about each other. The cap is a spend knob,
  # not a throughput one.
  [ "$total" -gt "$MAX_PRS" ] && log "$total need a review; taking $MAX_PRS this tick"

  if [ "$DRY_RUN" = 1 ]; then
    log "dry run: would review $(printf '%s' "$selected" | tr '\n' ' ')"
    exit 0
  fi

  local clone="$CLONE_ROOT/$slug"
  review_clone_prepare "$repo" "$slug"

  local wt
  while read -r pr; do
    [ -n "$pr" ] || continue
    log "#$pr: checking out"
    if ! wt="$(worktree_add "$clone" "$pr")"; then
      log "#$pr: cannot add a worktree, skipping"
      continue
    fi
    review_pr_in_worktree "$pr" "$wt"
    cd "$clone"
    worktree_remove "$clone" "$wt"
  done <<<"$selected"

  log "tick done"
  status_active_reset
}

# Everything already said on this pull request: the formal reviews (this job's
# own among them), the inline comments on the diff, and the conversation.
#
# The reviewer has no memory of its own — the state is the review's commit_id,
# so a push starts a review that has never seen what the last one said, and the
# author who explained why a finding was wrong gets it raised again on the next
# commit, and the one after that.
#
# The shell fetches this rather than the reviewer, because reaching the inline
# comments means `gh api`, and `gh api --method POST` is the same command. The
# agent keeps a tool list with nothing that writes.
#
# A source that cannot be read says so in the log. An empty history file turns
# the whole no-repeat instruction off, and a tick that silently reviewed with
# no memory would read exactly like a healthy one.
fetch_history_source() {
  platform_fetch_history_source "$@"
}

# The reviewer has no shell at all, so everything it would have run has to be
# on disk before it starts: the diff, the pull request, the commits, and how
# CI ended.
#
# Returns non-zero when the material is incomplete. The reviewer has no way to
# fetch any of this itself any more, so a half-empty briefing does not produce
# half a review — it produces a confident one written against nothing, and
# posting it marks the commit reviewed for good.
collect_material() {
  local repo="$1" pr="$2" diff="$3" meta="$4" base tmp err_tmp err_msg
  tmp="$(mktemp)"
  err_tmp="$(mktemp)"

  base="$(gh pr view "$pr" --repo "$repo" --json baseRefName -q .baseRefName 2>"$err_tmp" || echo "")"
  if [ -z "$base" ]; then
    err_msg="$(scrub_reason "$(cat "$err_tmp" 2>/dev/null || true)")"
    MATERIAL_ERROR="${err_msg:-could not read the base branch}"
    log "#$pr: could not read the base branch"
    rm -f "$tmp" "$err_tmp"
    return 1
  fi

  # Out of the checkout, not out of `gh pr diff`.
  #
  # `gh pr diff` asks the API for the pull request's diff **now**, and the
  # answer is against whatever its head is at that moment — which is not
  # necessarily the commit checked out a second earlier, nor the sha the review
  # will be recorded against. A push landing in that window produced a briefing
  # describing one commit, a working tree holding another, and a size
  # measured on the first: three answers to "what is being reviewed", and
  # the reviewer told to treat the patch as the whole scope. The window is
  # small — checkout, the sweep over the tree, this call — and it is the same
  # race, in miniature, that pinning the sha was supposed to close. Found by
  # this tool reviewing the commit that pinned it.
  #
  # `A...HEAD` is the merge-base form, which is what the pull request's diff on
  # GitHub shows, so the reviewer sees the same patch as the author. It also
  # costs one fewer API call, and cannot answer for a repository other than the
  # one checked out.
  #
  # Into a temp first: `>"$diff"` truncates before the command runs, so a
  # failure would leave a zero-byte patch that reads as "this pull request
  # changes nothing".
  if ! patch_against "$base" >"$tmp" 2>"$err_tmp"; then
    err_msg="$(scrub_reason "$(cat "$err_tmp" 2>/dev/null || true)")"
    MATERIAL_ERROR="${err_msg:-could not build the diff against origin/$base}"
    log "#$pr: could not build the diff against origin/$base"
    rm -f "$tmp" "$err_tmp"
    return 1
  fi
  # Distinct from the failure above, and said differently, because it will
  # repeat every tick: an empty diff is a pull request with nothing in it,
  # which no amount of retrying fixes.
  # 2, not 1: an empty diff is not a transient failure and postponing it would
  # retry for ever. The caller records it instead.
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$err_tmp"
    return 2
  fi
  mv "$tmp" "$diff"
  # For the --skip-if-only gate in the tick, which needs the same merge-base
  # range as this patch and not a second guess at the base branch.
  MATERIAL_BASE="$base"

  tmp="$(mktemp)"
  # Outside the brace group, or the notice is written into the file the
  # reviewer reads instead of into the log, and the tick still looks healthy.
  if ! gh pr view "$pr" --repo "$repo" \
    --json number,title,body,author,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles \
    -q '"# #\(.number) — \(.title)\n\nby \(.author.login) · \(.headRefName) → \(.baseRefName) · head \(.headRefOid)\n\(.changedFiles) files, +\(.additions) −\(.deletions)\n\n## description\n\n\(.body // "_none_")\n"' >"$tmp" 2>"$err_tmp"; then
    err_msg="$(scrub_reason "$(cat "$err_tmp" 2>/dev/null || true)")"
    MATERIAL_ERROR="${err_msg:-could not fetch the pull request itself}"
    log "#$pr: could not fetch the pull request itself"
    rm -f "$tmp" "$err_tmp"
    return 1
  fi
  rm -f "$err_tmp"

  # Extract PR body and build task briefing (upstream issue).
  local pr_body task_tmp
  pr_body="$(gh pr view "$pr" --repo "$repo" --json body -q '.body // ""' 2>/dev/null || echo "")"
  task_tmp="$(mktemp)"
  task_build_briefing "$repo" "$pr_body" "$task_tmp" "$pr"

  local commits checks
  # Outside the group as well, and fatal: a base branch renamed after the pull
  # request opened passes the check above and fails here, and the reviewer
  # would get a briefing with an empty "commits" section and no sign anything
  # was wrong.
  if ! commits="$(git log --oneline "origin/$base"..HEAD 2>/dev/null)"; then
    log "#$pr: could not list the commits against origin/$base"
    rm -f "$tmp" "$task_tmp"
    return 1
  fi

  # gh's own error text belongs in the log, not in the file the reviewer reads
  # as fact. Note what this cannot tell apart: `gh pr checks` exits non-zero
  # both for "the checks are red" and for "this token may not read them", and
  # with the token scope in README it is the second — so the exit-8 postpone
  # gate upstream has never fired. Saying so here is the whole remedy until
  # the token gains `checks: read`.
  # From the same two sources as the gate, for the same reason: `gh pr checks`
  # needs a permission this token cannot be given. A red result matters most of
  # all here — a failure is worth commenting on — so both are rendered whatever
  # they say.
  local head_sha
  head_sha="$(git rev-parse HEAD)"
  checks="$(
    gh api "repos/$repo/actions/runs?head_sha=$head_sha" \
      -q '.workflow_runs[] | "- \(.name): \(.status)\(if .conclusion then " / " + .conclusion else "" end)"' 2>/dev/null || true
    gh api "repos/$repo/commits/$head_sha/status" \
      -q '.statuses[] | "- \(.context): \(.state)"' 2>/dev/null || true
  )"
  if [ -z "$checks" ]; then
    checks="_nothing reported CI for this commit_"
  fi

  if ! {
    cat "$tmp"
    printf '\n'
    cat "$task_tmp"
    printf '\n## commits\n\n%s\n\n## checks\n\n%s\n' "$commits" "$checks"
  } >"$meta"; then
    log "#$pr: could not write the briefing to $meta"
    rm -f "$tmp" "$task_tmp"
    return 1
  fi
  rm -f "$tmp" "$task_tmp"
  # Explicitly, because `rm` would otherwise be this function's exit status and
  # a failed write above would report success.
  return 0
}

collect_history() {
  local repo="$1" pr="$2" out="$3" raw ok=0 budget=60000 per_entry=8000
  raw="$(mktemp)"

  # One line per entry — when, header, then the body base64'd, so that a
  # comment with blank lines in it survives sort(1) as a single record. A
  # pending review has a null submitted_at, and an empty first field would
  # shift every field left when this is read back: tab is IFS whitespace.
  fetch_history_source "$raw" "repos/$repo/pulls/$pr/reviews" \
    '.[] | select(.body != null and .body != "" and .submitted_at != null) | [.submitted_at, "review by \(.user.login), against \(.commit_id[0:7])", (.body | @base64)] | @tsv' || ok=1
  fetch_history_source "$raw" "repos/$repo/pulls/$pr/comments" \
    '.[] | [.created_at, "comment by \(.user.login), on \(.path)", (.body | @base64)] | @tsv' || ok=1
  fetch_history_source "$raw" "repos/$repo/issues/$pr/comments" \
    '.[] | [.created_at, "comment by \(.user.login)", (.body | @base64)] | @tsv' || ok=1

  # A source that would not load is not "no discussion". Reviewing on a partial
  # history is how a point somebody answered gets raised again, which is the
  # one thing this is here to prevent — so the tick waits instead.
  if [ "$ok" != 0 ]; then
    HISTORY_ERROR="could not read full PR discussion history"
    rm -f "$raw"
    return 1
  fi

  # Oldest first. "Already answered" is a claim about order, and the cut below
  # has to drop the oldest rather than whichever endpoint was fetched first —
  # concatenating by category and cutting bytes off the front threw away every
  # formal review, which is the memory this exists to keep.
  sort -o "$raw" "$raw"

  local entries keep=0 total=0 line body
  entries="$(wc -l <"$raw" | tr -d ' ')"

  # Whole entries, counted from the newest back: a cut through the middle of
  # one leaves a fragment attributed to nobody. The 120 is the header and the
  # blank lines this renders around each body. Always keep one, even if that
  # one is over budget on its own — an empty file would silently switch the
  # no-repeat instruction off.
  #
  # Each body is capped on its own as well, because this job's reviews are much
  # the longest entries here and a one-line "no, that is deliberate" is the
  # most valuable: a single budget would spend the whole file on the bot
  # talking to itself and evict the answers that close things.
  #
  # awk, because neither short way to read a file backwards exists on both
  # platforms: `tail -r` is BSD, `tac` is GNU.
  while IFS= read -r line; do
    body="$(printf '%s\n' "$line" | cut -f3 | base64 -d 2>/dev/null || true)"
    body="${body:0:$per_entry}"
    total=$((total + ${#body} + 120))
    if [ "$total" -gt "$budget" ] && [ "$keep" -gt 0 ]; then
      break
    fi
    keep=$((keep + 1))
  done < <(awk '{ entry[NR] = $0 } END { for (i = NR; i > 0; i--) print entry[i] }' "$raw")

  : >"$out"
  if [ "$keep" -lt "$entries" ]; then
    log "#$pr: discussion is $entries entries — giving the reviewer the $keep most recent"
    printf '_The %s oldest entries were left out; these are the %s most recent._\n\n' \
      "$((entries - keep))" "$keep" >"$out"
  fi
  tail -n "$keep" "$raw" | while IFS=$'\t' read -r when header body; do
    # `|| true`, as in the measuring pass: under `set -e` one undecodable entry
    # would abort this subshell, drop every entry after it, and still report
    # success — the memory silently half-missing is worse than one bad entry.
    body="$(printf '%s\n' "$body" | base64 -d || true)"
    if [ "${#body}" -gt "$per_entry" ]; then
      body="${body:0:$per_entry}
[…the rest of this entry was left out]"
    fi
    local category
    category="$(classify_history_entry "$header" "$body")"
    printf '## [%s] %s, %s\n\n%s\n\n' "$category" "$header" "$when" "$body"
  done >>"$out"

  rm -f "$raw"
  # As in collect_material: `rm` must not become the return value.
  return 0
}

# No timeout(1) on macOS, and a hung reviewer would hold the lock until reboot.
#
# Only stdout becomes the review body. Merging stderr into it published a
# "workspace has not been trusted" warning as the first line of a real review
# (an earlier change, 2026-08-10) — anything the tool says about itself belongs in the log,
# where the tick already writes.
#
# The task is written here, in full, and the built-in `/review` is not used —
# see the comment on REVIEW_TASK.
#
# The history goes in through --append-system-prompt rather than after the task:
# it is what the reviewer must not repeat, which is a standing rule about how to
# work, and the argument is the job. Keeping the two apart also means the
# untrusted half — other people's comments — is never concatenated onto the end
# of an instruction, where a line of it reads as the next instruction.
#
# Every path canonical, every one of them. sandbox-exec compares the path the
# kernel has already resolved against the strings in the profile, as strings: a
# trailing slash, a `//`, a `.` segment, a symlinked component — a symlinked
# ~/.config is what a dotfile manager leaves behind — and the rule matches
# nothing at all. On an allow that shows up as the reviewer failing to write. On
# a deny it shows up as nothing whatsoever, and that is the half that matters:
# with the home directory passed as `/Users/user/`, or `/Users//me`, or
# `/Users/user/../me`, or through a symlink, or in its
# `/System/Volumes/Data/Users/user` firmlink spelling, ~/.ssh and ~/.config/gh
# were readable inside this sandbox (measured 2026-08-11). So the paths the
# denies are built from are resolved here, one parameter each, and none of them
# is derived in the profile by appending to another.
#
# Sets a variable rather than printing one: `die` inside a $(…) exits the
# substitution, and the caller carries on with an empty string.
#
# A path that does not exist yet — ~/.aws on a machine with no AWS — is resolved
# as far as it goes and the rest re-attached. A name nothing has created cannot
# have a symlink hiding under it.
_resolved=""
resolve_or_die() {
  local p="$1" rest="" dir
  while [ ! -d "$p" ]; do
    dir="$(dirname "$p")"
    [ "$dir" != "$p" ] || die "cannot resolve $1 — the reviewer's perimeter is not built from a path this shell cannot find"
    rest="/$(basename "$p")$rest"
    p="$dir"
  done
  p="$(cd "$p" && pwd -P)" || die "cannot resolve $1 — the reviewer's perimeter is not built from a path this shell cannot enter"
  _resolved="$p$rest"
  case "$_resolved" in
    /*) ;;
    *) die "$1 resolved to '$_resolved', which is not absolute — refusing to build the reviewer's perimeter from it" ;;
  esac
  case "$_resolved" in
    */ | *//* | */./* | */. | */../* | */..)
      die "$1 resolved to '$_resolved', which is not canonical — refusing to build the reviewer's perimeter from it" ;;
  esac
}

# Once per tick, before the loop over pull requests, and never from inside it.
# Nothing here depends on which pull request is being reviewed, and every
# failure in it is fatal — so building it in `run_reviewer` meant dying halfway
# through the loop, after the API calls for that pull request had been spent,
# skipping every later one and leaving the staged files behind. Same rule as
# the `command -v sandbox-exec` check: what cannot vary per pull request is
# checked before the first one.
REVIEWER_PERIMETER=()
REVIEWER_CLONE=""
# Linux only: directories the perimeter hides that are not one of the four
# named denies — every Windows drive under WSL. Probed with the others.
REVIEWER_HIDDEN=()
build_perimeter() {
  local clone_arg="$1" tmp tokens sessions ssh_dir aws_dir gh_config

  if [ -n "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] || [ -f /.dockerenv ]; then
    resolve_or_die "$clone_arg"; REVIEWER_CLONE="$_resolved"
    REVIEWER_SANDBOX=()
    return 0
  fi

  # bwrap binds a directory that exists or fails; it cannot be told "writable
  # if it ever appears". The session directory is the runtime's own and the
  # first review would have made it, so it is made here, outside.
  if [ "$OS" = Linux ]; then
    mkdir -p "$HOME/.claude/projects" || die "cannot create $HOME/.claude/projects for the reviewer's sessions"
  fi

  resolve_or_die "${TMPDIR:-/tmp}"; tmp="$_resolved"
  resolve_or_die "$TOKEN_DIR"; tokens="$_resolved"
  resolve_or_die "$HOME/.claude/projects"; sessions="$_resolved"
  resolve_or_die "$HOME/.ssh"; ssh_dir="$_resolved"
  resolve_or_die "$HOME/.aws"; aws_dir="$_resolved"
  resolve_or_die "$HOME/.config/gh"; gh_config="$_resolved"
  resolve_or_die "$clone_arg"; REVIEWER_CLONE="$_resolved"

  if [ "$OS" = Linux ]; then
    build_bwrap_perimeter "$tmp" "$sessions" "$tokens" "$ssh_dir" "$aws_dir" "$gh_config"
  else
    REVIEWER_PERIMETER=(-f "$REVIEWER_PROFILE"
      -D CLONE="$REVIEWER_CLONE"
      -D SESSIONS="$sessions"
      -D TMPDIR="$tmp"
      -D TOKENS="$tokens"
      -D SSH="$ssh_dir"
      -D AWS="$aws_dir"
      -D GH_CONFIG="$gh_config")
  fi

  # Asked, not assumed. Everything above is a way of writing the string the
  # kernel will produce, and every way of getting it wrong reads the same from
  # here — the profile compiles, the reviewer runs, and the deny is not there.
  # So the profile is put in front of the directories it must refuse, in the
  # sandbox the reviewer is about to get.
  #
  # A file under each one, not only the directory: a deny written
  # `(literal (param "SSH"))` where it meant `(subpath …)` refuses the
  # directory node and leaves everything in it readable — one word's
  # difference, and a probe that only stats the directory passes it clean. The
  # file is picked out here, outside the sandbox, because inside it the
  # listing is exactly what is supposed to fail.
  #
  # Exit 9 for the leak, and sandbox-exec's stderr kept: "non-zero" would also
  # be a profile that does not compile, a parameter the profile never uses, or
  # /bin/sh failing to start, and reporting those as "~/.ssh is readable" —
  # with an empty path, because the probe never printed one — describes the
  # wrong emergency. Both stop the tick; only one of them is a leak.
  local d f targets=() probe probe_err leaked rc=0
  for d in "$tokens" "$ssh_dir" "$aws_dir" "$gh_config" ${REVIEWER_HIDDEN[@]+"${REVIEWER_HIDDEN[@]}"}; do
    [ -d "$d" ] || continue
    targets+=("$d")
    # `-quit`, not `| head -1`: `head` leaves after the first line, `find` dies
    # on SIGPIPE, and `set -o pipefail` turns that into a failed assignment
    # which `set -e` turns into a tick that stops here with nothing in the log.
    # It would depend on how many files the directory has, so a small ~/.ssh
    # would never show it.
    f="$(find "$d" -maxdepth 2 -type f -print -quit 2>/dev/null)"
    [ -n "$f" ] && targets+=("$f")
  done

  if [ "${#targets[@]}" -gt 0 ]; then
    probe='for p; do if [ -d "$p" ]; then ls "$p" >/dev/null 2>&1 && { printf %s "$p"; exit 9; }; else [ -r "$p" ] && head -c 1 "$p" >/dev/null 2>&1 && { printf %s "$p"; exit 9; }; fi; done; exit 0'
    probe_err="$(mktemp "${tmp}/probe.XXXXXX")"
    sandbox_command
    leaked="$("${REVIEWER_SANDBOX[@]}" /bin/sh -c "$probe" sh \
      "${targets[@]}" 2>"$probe_err")" || rc=$?
    if [ "$rc" = 9 ]; then
      rm -f "$probe_err"
      die "the reviewer's perimeter does not deny reads of $leaked — refusing to start a review behind it"
    elif [ "$rc" != 0 ]; then
      log "the perimeter probe could not run (exit $rc): $(tr '\n' ' ' <"$probe_err")"
      rm -f "$probe_err"
      die "cannot confirm the reviewer's perimeter — refusing to start a review behind it"
    fi
    rm -f "$probe_err"
  fi
  return 0
}

# The Linux perimeter: bubblewrap, holding what reviewer.sb holds.
#
# The shape is inverted, because bwrap has no rules — only a filesystem it
# assembles. The whole root goes in read-only, which is the profile's
# `deny file-write*`, and then a writable view is mounted back over exactly the
# places the profile allows: the session directory, a temporary directory, and
# /dev. A read deny is an empty tmpfs mounted over the directory, `chmod 0000`
# so that listing it fails as well — an empty listing is a successful `ls`,
# and the probe above would rightly call that a leak.
#
# Three things differ from the profile, each stricter:
#
#   TMPDIR and /tmp are a private tmpfs, not the host's. The profile allows the
#   per-user $TMPDIR macOS hands out; here $TMPDIR is usually unset and /tmp is
#   shared by every user and holds the sockets of everything running — tmux,
#   ssh-agent, the X server. A socket is connected to, not written, so a
#   read-only mount does not stop it, and tmux alone is a shell outside this
#   sandbox. A private one is still writable, and leaves nothing behind.
#
#   /run is hidden for the same reason: the docker socket, the user manager's
#   bus (`systemd-run --user` is a shell outside this sandbox too) and, under
#   WSL, the interop socket that runs Windows programs. The resolver's file is
#   mounted back if /etc/resolv.conf points in there.
#
#   /mnt, and every drvfs mount wherever it sits, are hidden. Under WSL that is
#   the Windows side of the machine — writable through interop, and holding a
#   second ~/.ssh, ~/.aws and gh login that the four denies would otherwise
#   cover only on the Linux side. Docker Desktop mounts C:\ a second time
#   under /mnt/wsl, which is why it is all of /mnt and every drvfs mount
#   rather than /mnt/c.
#
# A deny on a directory that does not exist is skipped, not mounted: bwrap
# would create the mountpoint on the host. That leaves one window — a ~/.aws
# created by something else during a review is readable to that review. The
# profile, matching paths rather than inodes, has no such window.
#
# The clone is the hard part, and it is in sandbox_command, per launch.
build_bwrap_perimeter() {
  local tmp="$1" sessions="$2" d m resolv
  shift 2

  REVIEWER_PERIMETER=(--ro-bind / / --tmpfs /run --tmpfs /mnt)
  REVIEWER_HIDDEN=()
  # /proc/self/mounts escapes a space as \040 and a tab as \011.
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    REVIEWER_HIDDEN+=("$m")
    case "$m" in
      /mnt/* | /run/*) ;;
      *) REVIEWER_PERIMETER+=(--tmpfs "$m" --chmod 0000 "$m") ;;
    esac
  done < <(awk '$3 == "drvfs" || $4 ~ /(^|[,;])aname=drvfs([,;]|$)/ {
      p = $2; gsub(/\\040/, " ", p); gsub(/\\011/, "\t", p); print p }' /proc/self/mounts)
  resolv="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
  case "$resolv" in
    /run/* | /mnt/*)
      if [ -f "$resolv" ]; then
        REVIEWER_PERIMETER+=(--ro-bind "$resolv" "$resolv")
      fi
      ;;
  esac

  # --unshare-pid with a /proc of its own: the host's lists every process on
  # the machine with its command line, and a process of the same user can
  # signal any of the owner's. --new-session so the reviewer cannot push
  # keystrokes into the terminal a tick was started from.
  REVIEWER_PERIMETER+=(--dev /dev --unshare-pid --proc /proc
    --die-with-parent --new-session
    --tmpfs /tmp)
  if [ "$tmp" != /tmp ] && [ -d "$tmp" ]; then
    REVIEWER_PERIMETER+=(--tmpfs "$tmp")
  fi
  REVIEWER_PERIMETER+=(--bind "$sessions" "$sessions"
    --ro-bind "$REVIEWER_CLONE" "$REVIEWER_CLONE")
  # After every writable mount, so none of them can uncover a deny. Not for a
  # directory inside one of the hidden trees — ~/.aws is a link to the Windows
  # side on this machine — where it is already absent: mounting there makes
  # bwrap create its parents in the empty tmpfs, and an empty /mnt/c/Users
  # appears where there was nothing to list.
  for d in "$@"; do
    [ -d "$d" ] || continue
    case "$d" in
      /mnt/* | /run/* | /tmp/* | "$tmp"/*) continue ;;
    esac
    for m in ${REVIEWER_HIDDEN[@]+"${REVIEWER_HIDDEN[@]}"}; do
      case "$d" in
        "$m" | "$m"/*) continue 2 ;;
      esac
    done
    REVIEWER_PERIMETER+=(--tmpfs "$d" --chmod 0000 "$d")
  done
}

# The command the reviewer — and the probe — is started under. On macOS the
# profile and its parameters, fixed for the tick.
#
# On Linux it is rebuilt for every launch, because the clone's writable view
# depends on what the checkout just put at its root. The profile allows the
# clone and then denies five names inside it, existing or not. bwrap can only
# mount over something that is there, and every one of the five is normally
# absent at launch — the sweep after the checkout deleted them. Mounting a
# read-only placeholder at `CLAUDE.md` means bwrap first creating an empty
# `CLAUDE.md` in the real clone, through the writable mount: the perimeter
# leaving behind the very file it exists to keep out, which the next
# `gh pr checkout` then trips over as an untracked file in the way.
#
# So the clone's root goes in read-only (build_bwrap_perimeter mounts it), and
# each entry that is already at the root is mounted back writable
# on top of itself — every one except the five names, and except symlinks,
# which bwrap would follow and so make their target writable instead. Nothing
# is created anywhere. A name that is not there cannot be created, because
# creating it is a write to the read-only root; one that is there and guarded
# stays read-only. `.git` is always there and stays read-only with all of its
# contents.
#
# The cost: the reviewer cannot create, delete or rename anything at the root
# of the clone, only change files already there and work inside its
# directories — stricter than the profile, which allows anything at the root
# except the five names. Its tools are Read, Grep and Glob, so it does not
# write at all; this is a perimeter for when that stops being true. A mount per
# root entry costs nothing measurable.
REVIEWER_SANDBOX=()
sandbox_command() {
  if [ -n "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] || [ -f "${AUTO_REVIEW_DOCKERENV:-/.dockerenv}" ]; then
    REVIEWER_SANDBOX=()
    return 0
  fi
  if [ "$OS" != Linux ]; then
    REVIEWER_SANDBOX=(sandbox-exec "${REVIEWER_PERIMETER[@]}")
    return 0
  fi
  REVIEWER_SANDBOX=(bwrap "${REVIEWER_PERIMETER[@]}")
  local entry
  for entry in "$REVIEWER_CLONE"/* "$REVIEWER_CLONE"/.[!.]* "$REVIEWER_CLONE"/..?*; do
    if [ -L "$entry" ] || [ ! -e "$entry" ]; then
      continue
    fi
    case "${entry##*/}" in
      .git | .claude | .mcp.json | CLAUDE.md | CLAUDE.local.md | AGENTS.md | GEMINI.md | .gemini | .agents | .agent | _agents | _agent) continue ;;
    esac
    if [ -d "$entry" ] || [ -f "$entry" ]; then
      REVIEWER_SANDBOX+=(--bind "$entry" "$entry")
    fi
  done
  REVIEWER_SANDBOX+=(--)
}

# What went wrong, in one line, out of an envelope whose interesting field is
# at the end. This used to be `head -c 300` of the file, and 300 characters of
# that envelope is `is_error`, a duration, a session id and four kinds of token
# count, all of them zero — the same prefix whatever happened. The sentence is
# in `.result`, and `api_error_status` names the class:
#
#   the reviewer exited 1: {"is_error":true,"duration_api_ms":0,"num_turns":1,…
#   the reviewer exited 1: 401 Failed to authenticate. API Error: 401 OAuth
#     access token has expired. Re-authenticate to continue.
#
# The first is what this job logged for two days about an expired credential.
# It cost nothing — the gates refused to post any of it, which is what they are
# for — but "the reviewer failed" with no reason is indistinguishable from a bad
# day, and the remedy here is one interactive login.
#
# When there is no envelope, both files are read — the second argument is the
# reviewer's stderr, captured to a file of its own. An earlier version of this
# comment said stderr was the fallback while nothing captured it: `claude` was
# started with stdout redirected and stderr left alone, so a run that died
# before printing anything (a missing binary, a profile that will not compile)
# produced an empty `$raw` and a log line that ended at the colon — the
# reasonless failure this function exists to remove, in the one case where the
# reason is not in the envelope. Found by this tool reviewing this change.
reviewer_error() {
  local raw="$1" err="${2:-}" why status msg
  why="$(jq -r '.result // empty' <"$raw" 2>/dev/null || true)"
  if [ -n "$why" ]; then
    status="$(jq -r '.api_error_status // empty' <"$raw" 2>/dev/null || true)"
    msg="${status:+$status }$why"
    scrub_reason "$msg"
    return 0
  fi
  why="$(head -c 2048 "$raw" 2>/dev/null | tr '\r\n' '  ')"
  if [ -n "$err" ] && [ -s "$err" ]; then
    why="${why:+$why }$(head -c 2048 "$err" 2>/dev/null | tr '\r\n' '  ')"
  fi
  # Never empty, whatever the two files held: a colon with nothing after it is
  # the shape being fixed here.
  scrub_reason "${why:-nothing on stdout or stderr}"
}

# The one place the reviewer process is started. $1 = the reviewer's HOME, then
# `--`, then the command. The environment is an allowlist: PATH (so the harness
# CLI is found by name), a HOME of its own, locale and temp, and the AI
# credential the harness needs. No GitHub token under any name, and nothing that
# says where the token directories are. In the container (reviewer_uid_mode) the
# command becomes uid 10002 with no capabilities, starts by making its own HOME
# and moves into the material directory (lib/reviewer-uid.sh); elsewhere the
# host sandbox wraps it.
reviewer_launch() {
  local home="$1" var
  shift 2
  local -a keep=("PATH=$PATH" "HOME=$home" "TMPDIR=${TMPDIR:-/tmp}")
  for var in LANG LC_ALL CLAUDE_CODE_OAUTH_TOKEN; do
    if [ -n "${!var:-}" ]; then
      keep+=("$var=${!var}")
    fi
  done
  if reviewer_uid_mode; then
    local -a REVIEWER_PRIV
    reviewer_priv_prefix
    env -i "${keep[@]}" "${REVIEWER_PRIV[@]}" \
      sh -c 'umask 077; mkdir -p "$HOME" && cd "$1" && shift && exec "$@"' sh \
      "${REVIEWER_WORKDIR:-$REVIEWER_CLONE}" "$@"
    return
  fi
  env -i "${keep[@]}" "${REVIEWER_SANDBOX[@]}" "$@"
}

# The wait loop's test: kill -0 cannot see a process of another uid.
reviewer_running() {
  if reviewer_uid_mode; then reviewer_alive "$1"; else kill -0 "$1" 2>/dev/null; fi
}

# $1 = reviewer home. Removes it, by the reviewer where the reviewer owns it.
reviewer_home_clear() {
  if reviewer_uid_mode; then reviewer_home_remove "$1"; else rm -rf "$1"; fi
}

# No Bash. An allowlist of command prefixes is not a write barrier: `git log`
# takes --output=<file> and --format=<anything from a commit message>, so
# `Bash(git log:*)` was a write-anywhere primitive driven by text the pull
# request's author controls (confirmed 2026-08-11). Read, Grep and Glob cannot
# write, so the material the reviewer needs is staged on disk instead.
run_reviewer() {
  local REVIEWER_WORKDIR="$REVIEWER_CLONE" material="" rc=0
  if reviewer_uid_mode; then
    # The reviewer reads a copy the gate prepared, never the clone: the clone
    # holds .git and is the gate's (0700). The briefing files are at the root of
    # the clone and arrive at the root of the copy.
    material="$(reviewer_material_prepare "$REVIEWER_CLONE")" || { log "#$1: cannot prepare the material directory"; return 1; }
    REVIEWER_WORKDIR="$material"
    run_reviewer_in "$1" "$2" "$material/${3##*/}" "$material/${4##*/}" "$material/${5##*/}" || rc=$?
    rm -rf "$material"
    return "$rc"
  fi
  run_reviewer_in "$@"
}

run_reviewer_in() {
  local pr="$1" out="$2" history="$3" diff="$4" meta="$5" waited=0 polls=0 pid guidance

  REVIEWER_FAIL_KIND=""
  REVIEWER_FAIL_REASON=""
  REVIEWER_FAIL_RETRYABLE="true"

  # A prompt that cannot be read is an error, never an empty prompt: this function
  # runs under `|| rc=$?`, where `set -e` is off, so the failure has to be returned.
  guidance=$(reviewer_guidance "$history" "$diff" "$meta") || {
    REVIEWER_FAIL_KIND="reviewer_guidance_failed"
    REVIEWER_FAIL_REASON="could not build reviewer prompt"
    return 1
  }

  # The task, written here rather than delegated to the built-in `/review`.
  #
  # That command's prompt is written for the session an interactive user has,
  # and this one is deliberately not it. On Opus 5 at medium and high effort the
  # prompt it expands to is fixed text that says, in as many words, to run
  # `git diff @{upstream}...HEAD` for the diff and then "submit at most 15
  # findings via the ReportFindings tool" — neither conditional on what the
  # session actually holds. This reviewer has no Bash and no ReportFindings, so
  # the model opened its answer by explaining that it could not do either, and
  # that explanation was the first paragraph of a posted review (an earlier change,
  # 2026-08-12). Read out of the 2.1.226 binary: the level table maps opus-5
  # medium and high to the `o5-bmin` cell, whose text names both unconditionally
  # — so it is what that command does every time here, not a bad day.
  #
  # AUTO-REVIEW-BEGIN exists for exactly this preamble and did not catch it: the
  # model has to remember to write the line, and a model apologising for a
  # missing tool is a model that has already lost the thread. The line stays as
  # a convenience; what fixes this is not asking for the apology.
  #
  # The cost of writing it here is that improvements to the built-in review
  # prompt do not arrive by themselves. That is the trade: a prompt that matches
  # the tools and the material this job actually provides, against one that is
  # better on average and wrong about this session in two specific ways.
  #
  # The invariant, test and holder lines below, and the third history case, come
  # out of 90 findings across 11 pull requests (2026-08-07..14), each classified
  # by the diff of its fix rather than by the wording of the comment. Detection
  # was never what failed — every case was found. 36 of the 90 were not defects
  # in the code the task asked for, 20 of those were created by the previous
  # round's fix to the same file, and 23 carry a regression their own fix
  # produced. One pull request took 8 rounds, of which 3 to 7 are one
  # reference-counted `chrome.power` slot's acquire/release balance being
  # rediscovered a call site at a time; one fix commit says it in its own
  # message — "two of these are regressions from the previous round" — about a
  # review written with the history file in context.
  #
  # So a location, a mechanism and a failing case are not enough: the author
  # repairs the sentence, the rule is never written down, and the untouched call
  # site is next round's finding. Two of the constraints above were narrowed to
  # make room, both deliberately and both against the terseness the rest of this
  # prompt fights for — see the docs's cost list, where the trade is stated
  # rather than made quietly.
  local task
  task=$(reviewer_task "$pr" "$diff" "$meta") || return 1

  local clone="$REVIEWER_WORKDIR"

  # The clearing above is what closes these; this says so out loud, immediately
  # before the reviewer starts, because the interesting failure is the one where
  # it silently did not happen. A symlink at a guarded name walks straight past
  # the write denies — a write to `$clone/.claude/settings.json` through a
  # `.claude` link to `$clone/x` lands on `$clone/x/settings.json`, which is
  # allowed — and the config names are read back by a `claude` started here.
  #
  # `return 1`, not `die`: what is being refused is one branch's tree, and the
  # branch belongs to the untrusted party. `die` would take the tick down from
  # inside the loop, skip every later pull request, and leave this one
  # unreviewed — so it would be selected again on the next tick, which would
  # die again. One file named `.claude` would switch the job off for every
  # repository it watches. The caller logs a failed review and carries on.
  local left left_rc=0
  left="$(find "$clone" -path "$clone/.git" -prune -o \
    \( -iname CLAUDE.md -o -iname CLAUDE.local.md -o -iname AGENTS.md \
    -o -iname .mcp.json -o -iname .claude \
    -o -iname GEMINI.md -o -iname .gemini \
    -o -iname .agents -o -iname .agent \
    -o -iname _agents -o -iname _agent \) -print 2>&1)" || left_rc=$?
  if [ "$left_rc" != 0 ]; then
    log "#$pr: cannot check the checkout for files read as instructions ($left) — not reviewing unchecked"
    return 1
  fi
  if [ -n "$left" ]; then
    log "#$pr: $(printf '%s' "$left" | head -n 1) survived the clearing — not reviewing behind a perimeter that may not hold"
    return 1
  fi
  # The staged files are this shell's own writes. A symlink here would mean the
  # clearing missed one and `>` followed it, which is worth refusing to review
  # over rather than discovering later in whatever it truncated.
  for guarded in .auto-review-history.md .auto-review-diff.patch .auto-review-pr.md; do
    if [ -L "$clone/$guarded" ]; then
      log "#$pr: $guarded is a symlink — the briefing was written through it, not to it"
      return 1
    fi
  done
  if [ -L "$clone/.git" ]; then
    log "#$pr: .git is a symlink in the checkout — not reviewing behind it"
    return 1
  fi

  # The reviewer is started from an environment built here, not from this
  # shell's with a few names removed: a denylist misses whatever it did not
  # think of (GH_ENTERPRISE_TOKEN, a token under a name nobody has invented),
  # and the reviewer makes no GitHub calls. See reviewer_launch.
  # The harness adapter builds every argument of the CLI (upstream issue).
  # stdout and stderr go to files of their own, not into one stream: a warning
  # in front of the output would make a good run unparseable, and stderr is what
  # the log falls back to when a run dies before printing anything at all (a
  # missing binary, a profile that will not compile).
  if ! harness_load "${HARNESS:-claude-code}"; then
    log "#$pr: no adapter for harness ${HARNESS:-claude-code}"
    REVIEWER_FAIL_KIND="harness_missing"
    REVIEWER_FAIL_REASON="no adapter for harness ${HARNESS:-claude-code}"
    REVIEWER_FAIL_RETRYABLE="false"
    return 1
  fi
  if ! "harness_${HARNESS_PREFIX}_probe"; then
    log "#$pr: the CLI of harness ${HARNESS:-claude-code} is not on PATH"
    REVIEWER_FAIL_KIND="harness_missing"
    REVIEWER_FAIL_REASON="the CLI of harness ${HARNESS:-claude-code} is not on PATH"
    REVIEWER_FAIL_RETRYABLE="false"
    return 1
  fi
  # A token too short to be real, or a 401/404 already answered under this
  # configuration, is not retried every tick (upstream issue).
  harness_gate "$pr" "${HARNESS:-claude-code}" "${REVIEW_MODEL:-$MODEL}" || {
    REVIEWER_FAIL_KIND="harness_fault"
    REVIEWER_FAIL_REASON="harness ${HARNESS:-claude-code} blocked by gate"
    REVIEWER_FAIL_RETRYABLE="false"
    return 1
  }
  local raw err
  raw="$(mktemp)"
  err="$(mktemp)"
  local rhome
  if reviewer_uid_mode; then
    rhome="$(reviewer_home_name)"
  else
    rhome="$(mktemp -d "${TMPDIR:-/tmp}/auto-review-home.XXXXXX")"
    chmod 700 "$rhome"
  fi
  # ANTHROPIC_API_KEY and ANTHROPIC_AUTH_TOKEN go with them, and not for the
  # same reason: either one in the environment would outrank the token
  # `claude-token` stored and checked, so the job would authenticate with a
  # credential nothing here has ever verified.
  sandbox_command
  "harness_${HARNESS_PREFIX}_execute" "$rhome" "${REVIEW_MODEL:-$MODEL}" "$task" "$guidance" "$raw" "$err"
  pid="$REVIEWER_PID"
  local timeout patch_lines=0
  [ -f "$diff" ] && patch_lines="$(wc -l <"$diff" | tr -d ' ')"
  timeout="${REVIEW_TIMEOUT_S:-$(reviewer_timeout "$patch_lines" "${READING_PLAN:-0}")}"
  while reviewer_running "$pid"; do
    if [ "$waited" -ge "$timeout" ]; then
      log "#$pr: review exceeded ${timeout}s, killing it"
      if reviewer_uid_mode; then reviewer_kill "$rhome"; fi
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      reviewer_home_clear "$rhome"
      rm -f "$raw" "$err"
      REVIEWER_FAIL_KIND="reviewer_timeout"
      REVIEWER_FAIL_REASON="review exceeded ${timeout}s"
      return 1
    fi
    # Every fifth of a second, so that a review that ends early hands its worker
    # on at once (upstream issue); `waited` still counts whole seconds.
    sleep 0.2
    polls=$((polls + 1))
    [ $((polls % 5)) -ne 0 ] || waited=$((waited + 1))
  done
  local rc=0
  wait "$pid" || rc=$?
  if declare -F "harness_${HARNESS_PREFIX}_finish" >/dev/null; then
    "harness_${HARNESS_PREFIX}_finish" "$rhome"
  fi
  reviewer_home_clear "$rhome"
  if [ "$rc" != 0 ]; then
    # The CLI exits non-zero on a 401 as well; the raw output still says which.
    local prc=0 why_err
    "harness_${HARNESS_PREFIX}_parse" "$raw" >/dev/null 2>"$raw.why" || prc=$?
    if [ "$prc" = 2 ]; then
      why_err="$(scrub_reason "$(cat "$raw.why" 2>/dev/null || true)")"
      harness_fault_raise "$pr" "${HARNESS:-claude-code}" "${REVIEW_MODEL:-$MODEL}" "${why_err:-no reason given}"
      REVIEWER_FAIL_KIND="harness_fault"
      REVIEWER_FAIL_REASON="${why_err:-harness fault}"
      REVIEWER_FAIL_RETRYABLE="false"
      rm -f "$raw" "$raw.why" "$err"
      return 1
    fi
    rm -f "$raw.why"
    why_err="$(reviewer_error "$raw" "$err")"
    log "#$pr: the reviewer exited $rc: $why_err"
    REVIEWER_FAIL_KIND="reviewer_failed"
    REVIEWER_FAIL_REASON="$why_err"
    rm -f "$raw" "$err"
    return 1
  fi

  # Set AUTO_REVIEW_KEEP_RAW=<dir> to keep the runtime's output for a run.
  # Everything about the shape of that output was learned by looking at one,
  # twice after guessing wrong about it first.
  if [ -n "${AUTO_REVIEW_KEEP_RAW:-}" ] && [ -d "${AUTO_REVIEW_KEEP_RAW:-}" ]; then
    cp "$raw" "$AUTO_REVIEW_KEEP_RAW/envelope-$pr.json" 2>/dev/null || true
  fi

  # The adapter decides whether the output is a review at all, and says why not
  # on stderr. An error flag, a run that generated nothing and an unreadable
  # body all mean the same thing here: there is no review, and the commit must
  # stay unreviewed so the next tick comes back to it. Anything this rejects is
  # in the log.
  local why prc=0
  "harness_${HARNESS_PREFIX}_parse" "$raw" >"$raw.result" 2>"$raw.why" || prc=$?
  if [ "$prc" != 0 ]; then
    why="$(scrub_reason "$(cat "$raw.why" 2>/dev/null || true)")"
    if [ "$prc" = 2 ]; then
      harness_fault_raise "$pr" "${HARNESS:-claude-code}" "${REVIEW_MODEL:-$MODEL}" "${why:-no reason given}"
      REVIEWER_FAIL_KIND="harness_fault"
      REVIEWER_FAIL_REASON="${why:-harness fault}"
      REVIEWER_FAIL_RETRYABLE="false"
      rm -f "$raw" "$raw.result" "$raw.why" "$err"
      return 1
    fi
    local rev_err
    rev_err="$(reviewer_error "$raw" "$err")"
    log "#$pr: the reviewer did not return a review: ${why:-no reason given}: $rev_err"
    REVIEWER_FAIL_KIND="reviewer_failed"
    REVIEWER_FAIL_REASON="$(scrub_reason "${why:-no reason given}: $rev_err")"
    rm -f "$raw" "$raw.result" "$raw.why" "$err"
    return 1
  fi
  rm -f "$raw.why"
  # The line, when it is there, marks where the review starts — everything
  # before it is the model explaining itself to nobody, which is not worth
  # posting. When it is not there, the whole thing is the review.
  #
  # `awk`, and not `sed "1,/^X$/d"`, which is what this was. In a sed address
  # range `1,/re/` the closing regex is not tested until line **2**, so a file
  # whose first line is the marker has no closing match at all and the range
  # runs to end of file: the entire review deleted, an empty body, and the
  # caller's "the reviewer produced nothing" — which reads exactly like a
  # crashed run, and is retried at full price for ever.
  #
  # It survived because it was only ever exercised on the shape it was written
  # for: a model that explains itself first and writes the marker on line three
  # or four. The instruction says to write the marker first when there is
  # nothing to explain, so obeying it was what broke the review — the bug lived
  # in the branch that a well-behaved reviewer takes, and the two runs it ate
  # were the first two that had nothing to apologise for.
  if grep -qxF "$REVIEW_SENTINEL" "$raw.result"; then
    awk -v s="$REVIEW_SENTINEL" 'seen { print; next } $0 == s { seen = 1 }' \
      "$raw.result" >"$out"
  else
    cp "$raw.result" "$out"
  fi
  # The plan is written before the sentinel, which is where the line above drops
  # it, so it is taken out of the raw text first (upstream issue).
  rm -f "$out.plan"
  if [ "${READING_PLAN:-0}" = 1 ]; then
    reading_plan "$raw.result" "$REVIEW_SENTINEL" >"$out.plan" || : >"$out.plan"
  fi
  rm -f "$raw" "$raw.result" "$err"

  # The scope block is checked against the table of files the tool wrote into
  # the material (upstream issue): a path the reviewer did not
  # account for is added to the block, and the review is posted as it is.
  local manifest
  manifest="$(mktemp)"
  scope_manifest "$meta" >"$manifest"
  if [ -s "$manifest" ]; then
    if scope_check "$out" "$manifest" >"$out.scope"; then
      cmp -s "$out" "$out.scope" || log "#$pr: the scope block left paths out — added as not accounted for"
      mv "$out.scope" "$out"
    else
      rm -f "$out.scope"
    fi
  fi
  rm -f "$manifest"

  # The plan goes after the scope block, so it can be read against what the
  # block says was done.
  if [ -s "$out.plan" ]; then
    printf '\n' >>"$out"
    cat "$out.plan" >>"$out"
  fi
  rm -f "$out.plan"

  # Looked at, logged, and posted either way. The first line is supposed to be
  # the verdict, and a job whose reviews stop opening with one is worth knowing
  # about — but this is not a gate, deliberately. A check that depends on the
  # model remembering a fixed string has already thrown two real reviews away
  # here (see AUTO-REVIEW-BEGIN above), and there is nothing to substitute
  # either: only the reviewer knows whether it found anything, so a header this
  # shell wrote would be a verdict nobody reached.
  local verdict
  verdict="$(awk 'NF { print; exit }' "$out")"
  case "$verdict" in
    '**No findings.**'* | '**'[0-9]*' finding'*) ;;
    *) log "#$pr: the review does not open with a verdict line — posting it as it is" ;;
  esac
  return 0
}

# --- dispatch -----------------------------------------------------------

# Sourced, by scripts/test-auto-review-*.sh: functions only.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Asked for anywhere — `run -h` is somebody asking what the arguments are, not
# a mistake to scold. Handled here rather than deeper down, because a `usage`
# called from inside a $(…) substitution would print into a variable and then
# exit only the subshell.
for arg in "$@"; do
  case "$arg" in
    -h | --help | help) usage 0 ;;
  esac
done

case "${1:-}" in
  setup)
    shift
    cmd_setup "$@"
    ;;
  adopt)
    shift
    echo "adopt is now setup: checking the token, registering and cloning"
    cmd_setup "$@"
    ;;
  pause)
    shift
    cmd_pause "$@"
    ;;
  resume)
    shift
    cmd_resume "$@"
    ;;
  forget)
    shift
    [ $# -ge 1 ] || die "forget needs a repo"
    migrate_registry
    registry_forget "$@"
    ;;
  unlock-token)
    shift
    name=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$name" ] || die "unlock-token needs --name <slug>"
    mkdir -p "$TOKEN_DIR"
    chmod 0700 "$TOKEN_DIR" 2>/dev/null || true
    cat >"$TOKEN_DIR/$name.token"
    chmod 0600 "$TOKEN_DIR/$name.token" 2>/dev/null || true
    log "unlocked token for $name"
    ;;
  token)
    shift
    [ $# -eq 1 ] || die "token needs a path"
    cmd_token "$1"
    ;;
  claude-token)
    shift
    [ $# -eq 0 ] || die "claude-token takes no arguments — it is one credential for the whole machine"
    cmd_claude_token
    ;;
  credential)
    shift
    cmd_credential "$@"
    ;;
  login)
    shift
    [ $# -eq 1 ] || die "login needs one harness"
    cmd_login "$1"
    ;;
  agy-token)
    shift
    [ $# -eq 0 ] || die "agy-token takes no arguments — it is one credential for the whole machine"
    cmd_agy_token
    ;;
  set)
    shift
    [ $# -eq 3 ] || die "set needs a repo, a key and a value"
    case "$2" in
      model | harness | interval | slots | plan_over | plan_over_files | read_budget)
        die "$2 is the machine's, not $1's: run  $(basename "$SELF") set-global $2 $3" ;;
      enabled | paused | paused_at | paused_reason)
        die "$2 is not set by hand: run  $(basename "$SELF") pause $1 [--reason TEXT]  or  resume $1" ;;
    esac
    registry_init "$REGISTRY_DEFAULT_FILE"
    migrate_registry
    registry_set "$REGISTRY_DEFAULT_FILE" "$1" "$2" "$3" || exit 1
    echo "set $2=$3 on $1"
    ;;
  set-global)
    shift
    [ $# -ge 2 ] || die "set-global needs <key> <val>"
    registry_init "$REGISTRY_DEFAULT_FILE"
    migrate_registry
    case "$1" in
      harness)
        set_checked_global_harness "$REGISTRY_DEFAULT_FILE" "$2" || exit 1
        ;;
      model)
        set_checked_global_model "$REGISTRY_DEFAULT_FILE" "$2" || exit 1
        ;;
      plan_over | plan_over_files | read_budget)
        case "$2" in
          '' | *[!0-9]* | 0) die "$1 takes a number, at least 1" ;;
        esac
        registry_set_global "$REGISTRY_DEFAULT_FILE" "$1" "$2" || exit 1
        ;;
      *) registry_set_global "$REGISTRY_DEFAULT_FILE" "$1" "$2" || exit 1 ;;
    esac
    echo "set-global $1=$2"
    ;;
  models)
    shift
    [ $# -le 1 ] || die "models takes at most one harness"
    cmd_models "$@"
    ;;
  registry)
    shift
    case "${1:-}" in
      show) migrate_registry; registry_show "$REGISTRY_DEFAULT_FILE" ;;
      import) registry_import "$REGISTRY_DEFAULT_FILE" && migrate_registry ;;
      *) die "registry needs show or import (import reads JSON on stdin)" ;;
    esac
    ;;
  list)
    shift
    cmd_list "$@"
    ;;
  status)
    shift
    migrate_registry
    cmd_status "$@"
    ;;
  tick)
    shift
    if [ $# -eq 0 ]; then cmd_machine_tick; else cmd_tick "$@"; fi
    ;;
  *) usage 1 ;;
esac
