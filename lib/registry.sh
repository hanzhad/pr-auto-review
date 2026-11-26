#!/usr/bin/env bash
# Registry manager for multi-repo auto-review machine service (Issue 4.2).
#
# Manages projects.json configuration registry for adopted repositories.

# The registry is one file in the gate's state volume, outside every git
# checkout (upstream issue). The container's CLI is its only writer, and
# every write is a temp file next to it and an mv, so a reader (the daemon, the
# host through `docker exec`) never sees half a file.
REGISTRY_DEFAULT_FILE="${AUTO_REVIEW_REGISTRY:-/var/lib/auto-review/projects.json}"

# Prints the name of a new temp file in the registry's own directory (mv across
# filesystems is not atomic).
registry_tmp() {
  mkdir -p "$(dirname "$1")" 2>/dev/null || true
  mktemp "$1.XXXXXX"
}

# Moves a finished temp file over the registry.
registry_commit() {
  local file="$1" tmp="$2"
  chmod 0644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file" && return 0
  rm -f "$tmp"
  return 1
}

# True when $1 is JSON with a projects object, the shape every reader needs.
registry_valid() {
  jq -e '(.projects | type) == "object"' "$1" >/dev/null 2>&1
}

# Runs jq with the given arguments over the registry and replaces it with the
# result only when jq succeeded. Usage: registry_edit <file> <jq args...>
registry_edit() {
  local file="$1" tmp
  shift
  tmp="$(registry_tmp "$file")" || return 1
  if jq "$@" "$file" >"$tmp"; then
    registry_commit "$file" "$tmp"
    return $?
  fi
  rm -f "$tmp"
  return 1
}

# Ensures the registry JSON file exists with valid envelope.
registry_init() {
  local file="${1:-$REGISTRY_DEFAULT_FILE}" tmp
  if [ ! -f "$file" ]; then
    tmp="$(registry_tmp "$file")" || return 1
    cat <<'JSON' >"$tmp"
{
  "version": 1,
  "harness": "claude-code",
  "model": "sonnet",
  "projects": {}
}
JSON
    registry_commit "$file" "$tmp"
  fi
}

# Sets a top-level global configuration key (e.g. harness, model).
registry_set_global() {
  local file="$REGISTRY_DEFAULT_FILE" key="" val=""
  if [ $# -ge 1 ] && [ -f "$1" ]; then
    file="$1"; shift
  fi
  key="$1"; val="$2"
  registry_init "$file"
  registry_edit "$file" --arg key "$key" --arg val "$val" '.[$key] = $val'
}

# Sets the global harness and its model in one write, so no reader ever sees a
# harness with a model it does not offer (upstream issue).
# Usage: registry_set_global_harness <file> <harness> <model>
registry_set_global_harness() {
  local file="$1" harness="$2" model="$3"
  registry_init "$file"
  registry_edit "$file" --arg h "$harness" --arg m "$model" '.harness = $h | .model = $m'
}

# Gets a top-level global configuration key (e.g. harness, model).
registry_get_global() {
  local file="$REGISTRY_DEFAULT_FILE" key="" default_val=""
  if [ $# -ge 1 ] && [ -f "$1" ]; then
    file="$1"; shift
  fi
  key="$1"; default_val="${2:-}"

  [ -f "$file" ] || { printf '%s\n' "$default_val"; return 0; }
  local val
  val="$(jq -r --arg key "$key" 'if .[$key] != null then .[$key] else empty end' "$file" 2>/dev/null)"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "$default_val"
  fi
}

# Registers a repository, or changes the flags of one already registered.
# A project carries only what is its own: all, self_review, the skip settings,
# and whether it is paused. Model, harness, interval and slots belong to the
# machine (upstream issue). A flag not given leaves the entry's value as
# it was; a new entry has both false.
# Usage: registry_adopt [file] <repo> [--all] [--self-review]
registry_adopt() {
  local file="$REGISTRY_DEFAULT_FILE" repo="" all=null self_review=null
  # A file argument comes first and is followed by the repository, so it need
  # not exist yet.
  if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
    file="$1"; shift
  fi
  repo="${1:-}"; shift || return 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=true ;;
      --self-review) self_review=true ;;
      *) echo "error: unknown flag $1 (registry_adopt takes --all and --self-review)" >&2; return 1 ;;
    esac
    shift
  done

  registry_init "$file" || return 1
  registry_edit "$file" --arg repo "$repo" --argjson all "$all" --argjson sr "$self_review" \
    '.projects[$repo] = ((.projects[$repo] // {adopted_at: (now | todate), all: false, self_review: false})
      + (if $all != null then {all: $all} else {} end)
      + (if $sr != null then {self_review: $sr} else {} end))'
}

# Stops reviewing a registered repository; the entry, its clone and its marker
# stay. Usage: registry_pause <file> <repo> [reason]
registry_pause() {
  local file="$1" repo="$2" reason="${3:-}"
  registry_require "$file" "$repo" || return 1
  registry_edit "$file" --arg repo "$repo" --arg reason "$reason" \
    '.projects[$repo] |= (del(.paused_reason) | .paused = true | .paused_at = (now | todate)
      | if $reason != "" then .paused_reason = $reason else . end)'
}

# Starts reviewing a paused repository again. Usage: registry_resume <file> <repo>
registry_resume() {
  local file="$1" repo="$2"
  registry_require "$file" "$repo" || return 1
  registry_edit "$file" --arg repo "$repo" 'del(.projects[$repo].paused, .projects[$repo].paused_at, .projects[$repo].paused_reason)'
}

# Fails, naming the repository, when it is not registered.
registry_require() {
  if ! jq -e --arg repo "$2" '.projects[$repo] != null' "$1" >/dev/null 2>&1; then
    echo "error: $2 is not in the registry" >&2
    return 1
  fi
}

# Brings a registry written before the machine owned the settings up to date,
# in place and in one write: the per-project model, harness, interval and slots
# are dropped, enabled false becomes paused, enabled true becomes not paused.
# Logs one line naming what was dropped, from which repository; a registry with
# nothing to migrate is left alone and logs nothing.
# Usage: registry_migrate [file]
registry_migrate() {
  local file="${1:-$REGISTRY_DEFAULT_FILE}" dropped stale
  [ -f "$file" ] && registry_valid "$file" || return 0
  dropped="$(jq -r '
    [.projects | to_entries[] | . as $e
      | (["model", "harness", "interval", "slots"] | map(. as $k | select($e.value | has($k)))) as $keys
      | select($keys | length > 0) | "\($e.key) (\($keys | join(", ")))"] | join("; ")' "$file")" || return 1
  stale="$(jq '[.projects[] | select(has("enabled"))] | length' "$file")" || return 1
  [ -n "$dropped" ] || [ "$stale" != 0 ] || return 0
  registry_edit "$file" '.projects |= with_entries(.value |=
    ((if .enabled == false then .paused = true | .paused_at = (now | todate) else . end)
     | del(.enabled, .model, .harness, .interval, .slots)))' || return 1
  [ -z "$dropped" ] || echo "[$(date '+%Y-%m-%d %H:%M:%S')] registry: dropped per-project settings, the machine owns them now: $dropped" >&2
  return 0
}

# Forgets a repository from the registry.
registry_forget() {
  local file="$REGISTRY_DEFAULT_FILE" repo=""
  if [ $# -ge 1 ] && [ -f "$1" ]; then
    file="$1"; shift
  fi
  repo="$1"; shift || return 1

  registry_init "$file"
  registry_edit "$file" --arg repo "$repo" 'del(.projects[$repo])'
}

# Sets a specific field for an adopted repository.
registry_set() {
  local file="$REGISTRY_DEFAULT_FILE" repo="" key="" val=""
  if [ $# -ge 1 ] && [ -f "$1" ]; then
    file="$1"; shift
  fi
  repo="$1"; key="$2"; val="$3"

  registry_init "$file"

  if ! jq -e --arg repo "$repo" '.projects[$repo] != null' "$file" >/dev/null 2>&1; then
    echo "error: $repo is not in the registry" >&2
    return 1
  fi

  # Booleans and integers stay typed, everything else is a string.
  local jq_expr='.projects[$repo][$key] = $val'
  if [ "$val" = "true" ] || [ "$val" = "false" ] || [[ "$val" =~ ^[0-9]+$ ]]; then
    jq_expr='.projects[$repo][$key] = ($val | fromjson)'
  fi
  registry_edit "$file" --arg repo "$repo" --arg key "$key" --arg val "$val" "$jq_expr"
}

# Replaces the registry with the JSON on stdin, after checking it. A refusal
# leaves the current registry as it was. Usage: registry_import [file]
registry_import() {
  local file="${1:-$REGISTRY_DEFAULT_FILE}" tmp
  tmp="$(registry_tmp "$file")" || return 1
  cat >"$tmp"
  if ! registry_valid "$tmp"; then
    rm -f "$tmp"
    echo "error: not a registry (JSON object with a projects object); nothing changed" >&2
    return 1
  fi
  registry_commit "$file" "$tmp"
}

# Copies a registry that predates the volume into place, once: only when the
# destination does not exist yet. Usage: registry_migrate_legacy <legacy> <dest>
registry_migrate_legacy() {
  local legacy="$1" dest="$2"
  [ -e "$dest" ] && return 0
  [ -s "$legacy" ] || return 0
  if ! registry_valid "$legacy"; then
    echo "warning: $legacy is not a registry; not migrated" >&2
    return 1
  fi
  registry_import "$dest" <"$legacy" && echo "migrated $legacy to $dest"
}

# Prints the registry. Read only: a missing registry is an error, not created.
registry_show() {
  local file="${1:-$REGISTRY_DEFAULT_FILE}"
  [ -f "$file" ] || { echo "error: no registry at $file" >&2; return 1; }
  jq . "$file"
}

# Reads a specific field for a repository.
registry_get() {
  local file="$REGISTRY_DEFAULT_FILE" repo="" key="" default_val=""
  if [ $# -ge 1 ] && [ -f "$1" ]; then
    file="$1"; shift
  fi
  repo="$1"; key="$2"; default_val="${3:-}"

  [ -f "$file" ] || { printf '%s\n' "$default_val"; return 0; }

  local val
  val="$(jq -r --arg repo "$repo" --arg key "$key" 'if .projects[$repo][$key] != null then .projects[$repo][$key] else empty end' "$file" 2>/dev/null)"
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "$default_val"
  fi
}

# Lists the repository slugs a tick picks from, one per line: registered and
# not paused.
registry_list_enabled() {
  local file="${1:-$REGISTRY_DEFAULT_FILE}"
  [ -f "$file" ] || return 0
  jq -r '.projects | to_entries[] | select(.value.paused != true) | .key' "$file" 2>/dev/null
}

# Lists all registered repositories as table or JSON.
registry_list() {
  local file="$REGISTRY_DEFAULT_FILE" json_output=0
  for arg in "$@"; do
    case "$arg" in
      --json) json_output=1 ;;
      *) [ -f "$arg" ] && file="$arg" ;;
    esac
  done

  registry_init "$file"

  if [ "$json_output" = 1 ]; then
    jq . "$file"
    return 0
  fi

  printf '%-30s %-8s %-5s %-5s %s\n' "REPOSITORY" "STATE" "ALL" "SELF" "NOTE"
  printf '%-30s %-8s %-5s %-5s %s\n' "------------------------------" "--------" "-----" "-----" "----"
  jq -r '.projects | to_entries[] | [.key, (if .value.paused == true then "paused" else "active" end),
      (.value.all // false | tostring), (.value.self_review // false | tostring), (.value.paused_reason // "")] | @tsv' "$file" | \
    while IFS=$'\t' read -r repo state all self note; do
      [ -n "$repo" ] || continue
      printf '%-30s %-8s %-5s %-5s %s\n' "$repo" "$state" "$all" "$self" "$note"
    done
}

# Prints the extra `auto-review tick` arguments the registry sets for a
# repository, one per line, flag and value on separate lines. Keys are read
# from the project entry and the global level; a project value replaces the
# global one for the same key. skip_labels defaults to ["no-review"].
# Usage: registry_tick_flags <file> <repo>
registry_tick_flags() {
  local file="${1:-$REGISTRY_DEFAULT_FILE}" repo="${2:-}"
  local default_labels='["no-review"]'
  [ -f "$file" ] || { printf -- '--skip-label\nno-review\n'; return 0; }
  jq -r --arg repo "$repo" --argjson default_labels "$default_labels" '
    def pick($key): (.projects[$repo][$key]) // .[$key];
    def list($key; $flag): (pick($key) // []) | .[] | $flag, .;
    (pick("skip_labels") // $default_labels) as $labels
    | ($labels[] | "--skip-label", .),
      list("skip_branches"; "--skip-branch"),
      list("skip_if_only"; "--skip-if-only"),
      (((.projects[$repo].skip_bots) as $p | if $p == null then .skip_bots else $p end) == true
         | if . then "--skip-bots" else empty end)
  ' "$file" 2>/dev/null
}
