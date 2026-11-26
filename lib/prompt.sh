# shellcheck shell=bash
# The reviewer's prompt, read from auto-review/prompt/*.md (upstream issue).
#
# The text used to sit inside run_reviewer_in as four double-quoted strings in a
# 2400-line script. It lives in files now, so a change to what the reviewer is
# told is a change to a markdown file and shows up as one in review. The text is
# byte-identical to what the strings produced; scripts/test-auto-review-harness-models.sh
# holds the golden output and fails on a single changed byte.
#
#   guidance.md  what the reviewer may use and how to treat its input
#   history.md   added when this pull request already has a discussion
#   reading.md   how to read each kind of file the tool sorted the patch into
#   task.md      the review itself: what to look for and the shape of the answer
#
# A file holds {{name}} where the string held $name: sentinel, pr, diff, meta,
# history. Nothing else is substituted, so a prompt file can say `$`
# and backticks freely.

# prompt_dir — where the files are: the container's install, then next to the
# script, the same search order the libraries use.
prompt_dir() {
  local d
  for d in /usr/local/lib/auto-review/prompt \
           "$(dirname "${SELF:-$0}")/prompt" \
           "$(dirname "${BASH_SOURCE[0]:-$0}")/../prompt"; do
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  echo "auto-review: the prompt directory is missing — looked in /usr/local/lib/auto-review/prompt and next to the script" >&2
  return 1
}

# prompt_render <name> — print prompt/<name>.md with its {{placeholders}} filled
# from the caller's variables sentinel, pr, diff, meta, history.
# Command substitution drops the file's final newline, which is what the strings
# never had.
prompt_render() {
  local dir text
  dir=$(prompt_dir) || return 1
  [ -f "$dir/$1.md" ] || { echo "auto-review: no prompt file $dir/$1.md" >&2; return 1; }
  text=$(cat "$dir/$1.md")
  text=${text//'{{sentinel}}'/"${sentinel:-}"}
  text=${text//'{{pr}}'/"${pr:-}"}
  text=${text//'{{diff}}'/"${diff:-}"}
  text=${text//'{{meta}}'/"${meta:-}"}
  text=${text//'{{history}}'/"${history:-}"}
  printf '%s' "$text"
}

# reviewer_guidance <history> <diff> <meta>
# The system-side guidance: how to answer, what is on disk, how to read each kind
# of file, and, only when it applies, how to read an earlier discussion.
# REVIEW_SENTINEL is the global the tool sets.
reviewer_guidance() {
  local history="$1" diff="$2" meta="$3" pr="" sentinel="${REVIEW_SENTINEL:-}"
  local guidance part
  guidance=$(prompt_render guidance) || return 1
  part=$(prompt_render reading) || return 1
  guidance="$guidance

$part"
  # Only a pull request over the threshold is asked for a plan; below it the plan
  # would say "everything". READING_PLAN is set by the tick.
  if [ "${READING_PLAN:-0}" = 1 ]; then
    part=$(prompt_render plan) || return 1
    guidance="$guidance

$part"
    if [ "${READING_OVER:-0}" = 1 ]; then
      part=$(prompt_render budget) || return 1
      guidance="$guidance

$part"
    fi
  fi
  # No history is the first review on this pull request. "Do not repeat what is
  # in this empty file" is only a way to confuse it.
  if [ -s "$history" ]; then
    part=$(prompt_render history) || return 1
    guidance="$guidance

$part"
  fi
  printf '%s' "$guidance"
}

# reviewer_task <pr> <diff> <meta> — the review itself, written here rather than
# delegated to the built-in `/review`. Why that is, and what the invariant, test
# and holder lines in it cost and bought, is in the comment above `local task` in
# run_reviewer_in (auto-review.sh) and in the design docs.
reviewer_task() {
  local pr="$1" diff="$2" meta="$3" sentinel="${REVIEW_SENTINEL:-}" history=""
  prompt_render task
}
