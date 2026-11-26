#!/usr/bin/env bash
# Which models a harness offers (upstream issue).
#
# The answer lives in the adapter (harness_P_models, harness_P_default_model);
# nothing here lists a model. Needs harness_load from auto-review.sh. Each call
# loads the adapter in a subshell, so the adapters never pile up in one shell.

# Prints the harness names, one per line: every adapters/harness/H.sh found.
harness_names() {
  local dir f
  for dir in /usr/local/lib/auto-review "$(dirname "$SELF")" "$(dirname "${BASH_SOURCE[0]:-$0}")/.."; do
    for f in "$dir"/adapters/harness/*.sh; do
      [ -f "$f" ] && basename "$f" .sh
    done
  done | sort -u
}

# Prints the models harness $1 offers, one per line. Non-zero for no adapter.
harness_models_of() {
  (
    harness_load "$1" || exit 1
    "harness_${HARNESS_PREFIX}_models"
  )
}

# Prints the default model of harness $1. Non-zero for no adapter.
harness_default_of() {
  (
    harness_load "$1" || exit 1
    "harness_${HARNESS_PREFIX}_default_model"
  )
}

# True when harness $1 offers model $2.
harness_offers() {
  harness_models_of "$1" 2>/dev/null | awk -v m="$2" '$0 == m { found=1 } END { exit !found }'
}

# Prints {"harness":H,"models":[...],"default":D} for harness $1, compact.
harness_models_json() {
  local models default
  models="$(harness_models_of "$1")" || return 1
  default="$(harness_default_of "$1")" || return 1
  jq -cn --arg h "$1" --arg d "$default" --arg m "$models" \
    '{harness: $h, models: ($m | split("\n") | map(select(. != ""))), default: $d}'
}

# Prints one JSON document covering every adapter:
# {"harnesses":[{"harness":...},...]}. Pure over harness_models_json.
harness_models_all_json() {
  local name
  for name in $(harness_names); do
    harness_models_json "$name" || return 1
  done | jq -cs '{harnesses: .}'
}

# The command: `auto-review models [harness]`.
cmd_models() {
  if [ $# -eq 0 ]; then
    harness_models_all_json
  else
    harness_models_json "$1" || die "no adapter for harness $1 (known: $(harness_names | paste -sd, -))"
  fi
}

# Dies unless harness $1 has an adapter.
require_harness() {
  harness_models_of "$1" >/dev/null 2>&1 \
    || die "no adapter for harness $1 (known: $(harness_names | paste -sd, -))"
}

# Dies unless harness $1 offers model $2.
require_model() {
  harness_offers "$1" "$2" \
    || die "harness $1 does not offer model $2 (offers: $(harness_models_of "$1" | paste -sd, -))"
}

# `set-global harness H`: the global harness and its default model are written
# together, in one write. No project has a harness or a model of its own, so
# there is nothing else to keep consistent (upstream issue).
# Usage: set_checked_global_harness <file> <harness>
set_checked_global_harness() {
  local file="$1" harness="$2" default
  require_harness "$harness"
  default="$(harness_default_of "$harness")" || return 1
  registry_set_global_harness "$file" "$harness" "$default"
}

# `set-global model M`: M must be offered by the global harness.
# Usage: set_checked_global_model <file> <model>
set_checked_global_model() {
  local file="$1" model="$2"
  require_model "$(registry_get_global "$file" harness claude-code)" "$model"
  registry_set_global "$file" model "$model"
}
