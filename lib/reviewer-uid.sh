#!/usr/bin/env bash
# The reviewer as its own uid (upstream issue).
#
# In the machine container the gate (uid 10001) holds the GitHub tokens, the
# clones, the registry and the logs, all 0700. The reviewer runs the harness CLI
# over a pull request's text, so it is the process a prompt injection lands in.
# It therefore runs as uid 10002 with no capabilities, and can read exactly two
# things: the material directory the gate prepared for this review (a copy of
# the tree without .git, plus the .auto-review-* briefing files; owned by the
# gate, read-only to the reviewer) and its own HOME on a tmpfs. Nothing of the
# gate is reachable: not the token files, not /proc/<gate pid>/environ.
#
# The gate holds CAP_SETUID/CAP_SETGID (ambient) for this and nothing else; it
# cannot chown, so it never creates anything in the reviewer's HOME. The
# reviewer creates its own directory there, and files that must get into it
# (the agy login) are streamed in on stdin to a reviewer-side `tar`.
#
# Outside the container the host sandbox (bwrap / sandbox-exec) is the
# perimeter and none of this applies.

REVIEWER_UID_DEFAULT=10002
REVIEWER_HOME_ROOT_DEFAULT=/home/rv
# The directory the reviewer starts in: the material dir in uid mode, the clone
# otherwise. Set per review by run_reviewer.
REVIEWER_WORKDIR=""

# True when this process is the gate in the container: setpriv is there, and
# either the entrypoint said so (AUTO_REVIEW_REVIEWER_UID) or this is a
# non-root process in a container holding CAP_SETUID.
reviewer_uid_mode() {
  command -v setpriv >/dev/null 2>&1 || return 1
  [ -n "${AUTO_REVIEW_REVIEWER_UID:-}" ] && return 0
  { [ -n "${AUTO_REVIEW_INSIDE_CONTAINER:-}" ] || [ -f /.dockerenv ]; } || return 1
  [ "$(id -u)" != 0 ] || return 1
  local eff
  eff="$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status 2>/dev/null)"
  [ -n "$eff" ] || return 1
  [ $((0x$eff & 0x80)) -ne 0 ]
}

# Sets REVIEWER_PRIV to the command prefix that becomes the reviewer: uid and
# gid switched, supplementary groups dropped, every capability gone (so it
# cannot setpriv back).
reviewer_priv_prefix() {
  local uid="${AUTO_REVIEW_REVIEWER_UID:-$REVIEWER_UID_DEFAULT}"
  REVIEWER_PRIV=(setpriv --reuid "$uid" --regid "$uid" --clear-groups
    --inh-caps -all --ambient-caps -all)
}

# $1 = reviewer HOME, then a command. Runs it as the reviewer in a clean
# environment; stdin passes through.
reviewer_exec() {
  local home="$1"
  shift
  local -a REVIEWER_PRIV
  reviewer_priv_prefix
  env -i "PATH=$PATH" "HOME=$home" "${REVIEWER_PRIV[@]}" "$@"
}

# A name for this review's HOME. Not created: the gate cannot write in the
# reviewer's tmpfs, the reviewer's own launch command makes it.
reviewer_home_name() {
  printf '%s/r.%s.%s' "${AUTO_REVIEW_REVIEWER_HOME_ROOT:-$REVIEWER_HOME_ROOT_DEFAULT}" "$$" "$RANDOM$RANDOM"
}

# $1 = the tree to copy. Prints the path of a new directory holding that tree
# without .git, owned by the caller, 0755/0644: readable by the reviewer, not
# writable by it.
reviewer_material_prepare() {
  local src="$1" dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/auto-review-material.XXXXXX")" || return 1
  tar -C "$src" --exclude=./.git -cf - . | tar -C "$dir" --no-same-owner --no-same-permissions -xf -
  local -a st=("${PIPESTATUS[@]}")
  if [ "${st[0]:-1}" != 0 ] || [ "${st[1]:-1}" != 0 ]; then
    rm -rf "$dir"
    return 1
  fi
  chmod -R u+rwX,go+rX,go-w "$dir" && chmod 755 "$dir" || { rm -rf "$dir"; return 1; }
  printf '%s' "$dir"
}

# The gate's state directories: the clone root and its parent. Only the gate may
# enter them (0700), so the reviewer cannot list or read a clone. Run by the
# entrypoint at every start, because a volume that predates this keeps the
# modes it was created with. Each clone lives under the clone root and is
# protected by it. No arguments = the container's own paths.
gate_protect_state_dirs() {
  local d
  [ "$#" -gt 0 ] || set -- /var/lib/auto-review "${AUTO_REVIEW_CLONE_ROOT:-/var/lib/auto-review/clones}"
  for d in "$@"; do
    [ -d "$d" ] || continue
    chmod 0700 "$d" 2>/dev/null || echo "warning: cannot chmod 0700 $d (not owned by uid $(id -u))" >&2
  done
}

# $1 = the reviewer's HOME. Removed by the reviewer, who owns it.
reviewer_home_remove() {
  reviewer_exec "$1" rm -rf -- "$1" 2>/dev/null || true
}

# The gate has no CAP_KILL, so the timeout kill goes through the reviewer's own
# uid: everything of its owner dies.
reviewer_kill() {
  reviewer_exec "$1" pkill -9 -U "${AUTO_REVIEW_REVIEWER_UID:-$REVIEWER_UID_DEFAULT}" 2>/dev/null || true
}

# kill -0 on another uid's process is EPERM, i.e. "false"; ask bash's own job
# table instead.
reviewer_alive() {
  jobs -rp 2>/dev/null | grep -qx "$1"
}

# $1 = reviewer HOME. Streams the gate's ~/.gemini (the AI login) into it.
reviewer_seed_dir() {
  local home="$1" rel="$2"
  [ -d "${HOME:-}/$rel" ] || return 0
  tar -C "$HOME" -cf - "$rel" 2>/dev/null |
    reviewer_exec "$home" sh -c 'umask 077; mkdir -p "$HOME" && tar -C "$HOME" -xf -' 2>/dev/null || true
}

# $1 = reviewer HOME, $2 = file relative to it. Prints it, if the reviewer has it.
reviewer_read_file() {
  reviewer_exec "$1" sh -c 'cat "$HOME/$1" 2>/dev/null' sh "$2"
}
