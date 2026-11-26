#!/usr/bin/env bash
# Agent Harness Adapter: Antigravity (agy) for auto-review.
#
# Starts the agy CLI as the reviewer, seeds its Google login into the reviewer's
# HOME, and reads its JSON output back. The contract is harness_agy_probe,
# _execute, _parse and _parse_verdict (upstream issue); _auth and _finish
# are optional hooks the core calls when they exist.

# shellcheck source=../../lib/agy.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/agy.sh"

# Checks whether the agy CLI is installed and available on PATH.
harness_agy_probe() {
  command -v agy >/dev/null 2>&1
}

# Sets REVIEWER_AUTH to what the reviewer will authenticate with.
harness_agy_auth() {
  local login="${HOME:-/home/reviewer}/.gemini/antigravity-cli/antigravity-oauth-token"
  if [ -s "${TOKEN_DIR:-/nonexistent}/antigravity-oauth-token" ] || [ -s "$login" ]; then
    REVIEWER_AUTH="Google subscription (OAuth)"
  else
    REVIEWER_AUTH="the interactive login"
  fi
}

# The file under the token directory agy authenticates with, and the least
# number of bytes it can have (upstream issue).
harness_agy_token_file() {
  printf '%s\n' antigravity-oauth-token
}
harness_agy_token_min() {
  printf '%s\n' 40
}

# The other names `auto-review credential set` and `login` answer to.
harness_agy_aliases() {
  printf '%s\n' antigravity
}

# The one small prompt a credential check sends.
harness_agy_check_prompt() {
  printf '%s\n' 'reply with exactly: ok'
}

# Runs `agy login` in a HOME of its own and prints the credential on stdout:
# the OAuth file the login wrote there, or else what the command printed.
harness_agy_login() {
  local home out rc=0 rel=".gemini/antigravity-cli/antigravity-oauth-token"
  home="$(mktemp -d)"
  out="$(mktemp)"
  HOME="$home" agy login >"$out" || rc=$?
  if [ "$rc" = 0 ]; then
    if [ -s "$home/$rel" ]; then cat "$home/$rel"; else cat "$out"; fi
  fi
  rm -rf "$home" "$out"
  return "$rc"
}

# Checks a candidate credential with one prompt. $1 = file holding it, $2 = file
# for stdout, $3 = file for stderr. agy reads its login from a file, so the
# check runs in a HOME of its own that holds the candidate (and a copy of the
# rest of ~/.gemini, as a review gets): no environment variable carries it.
harness_agy_check_token() {
  local tokfile="$1" out="$2" err="$3" home rc=0 dir
  home="$(mktemp -d)"
  dir="$home/.gemini/antigravity-cli"
  if [ -d "${HOME:-}/.gemini" ]; then cp -a "$HOME/.gemini" "$home/.gemini" 2>/dev/null || true; fi
  mkdir -p "$dir"
  cp "$tokfile" "$dir/antigravity-oauth-token"
  chmod 0600 "$dir/antigravity-oauth-token"
  agy_write_settings "$dir"
  (
    cd "$home" || exit 1
    HOME="$home" agy -p "$(harness_agy_check_prompt)" --output-format json </dev/null
  ) >"$out" 2>"$err" || rc=$?
  rm -rf "$home"
  return "$rc"
}

# The one table behind _model and _models: the name a user types, then the
# model id agy takes. Add a model here and both know it.
harness_agy_model_table() {
  printf '%s\t%s\n' \
    auto gemini-4-hydrogen-high \
    flash-low gemini-4-hydrogen-low \
    flash gemini-4-hydrogen-medium \
    flash-high gemini-4-hydrogen-high \
    hydrogen-low gemini-4-hydrogen-low \
    hydrogen-medium gemini-4-hydrogen-medium \
    hydrogen gemini-4-hydrogen-high \
    hydrogen-xhigh gemini-4-hydrogen-xhigh \
    neon-low gemini-4-neon-low \
    neon-medium gemini-4-neon-medium \
    neon gemini-4-neon-high \
    neon-xhigh gemini-4-neon-xhigh \
    pro gemini-4-carbon-high \
    carbon-low gemini-4-carbon-low \
    carbon-medium gemini-4-carbon-medium \
    carbon gemini-4-carbon-high \
    argon-low gemini-4-argon-low \
    argon gemini-4-argon-medium \
    argon-high gemini-4-argon-high \
    orchestrator gemini-pro-orchestrator \
    orchestrator-argon gemini-pro-orchestrator-argon \
    orchestrator-neon gemini-pro-orchestrator-neon \
    flash-3.8-low gemini-3.8-flash-low \
    flash-3.8 gemini-3.8-flash-medium \
    flash-3.8-high gemini-3.8-flash-high \
    sonnet claude-sonnet-5-5-medium \
    opus claude-opus-5-5-medium
}

# Prints the model names a user may set, one per line.
harness_agy_models() {
  harness_agy_model_table | cut -f1
}

# Prints the one model used when none was chosen. It is in harness_agy_models.
harness_agy_default_model() {
  printf '%s\n' auto
}

# Pure mapper: prints the model id agy takes for the model the job asked for.
# Alternative spellings fold to a name in the table; anything else passes through.
harness_agy_model() {
  local raw="${1:-auto}" base eff folded prefix name bare_resolved
  base="${raw%%:*}"
  eff=""
  [ "$base" != "$raw" ] && eff="${raw#*:}"

  if [ -n "$eff" ]; then
    case "$eff" in
      low|medium|high|xhigh|max) ;;
      *)
        printf "unsupported effort '%s' for model '%s'\n" "$eff" "$base" >&2
        return 1
        ;;
    esac

    folded="${raw/:/-}"
    if harness_agy_model_table | awk -F'\t' -v m="$folded" '$1 == m || $2 == m { print $2; found = 1; exit } END { exit !found }'; then
      return 0
    fi

    case "$base" in
      hydrogen|flash|gemini-4-hydrogen) prefix="gemini-4-hydrogen" ;;
      neon|gemini-4-neon) prefix="gemini-4-neon" ;;
      carbon|pro|gemini-4-carbon) prefix="gemini-4-carbon" ;;
      argon|gemini-4-argon) prefix="gemini-4-argon" ;;
      flash-3.8|gemini-3.8-flash|gemini-3.5-flash) prefix="gemini-3.8-flash" ;;
      sonnet|claude*sonnet*) prefix="claude-sonnet-5-5" ;;
      opus|claude*opus*) prefix="claude-opus-5-5" ;;
      *) prefix="" ;;
    esac
    if [ -n "$prefix" ]; then
      folded="$prefix-$eff"
      if harness_agy_model_table | awk -F'\t' -v m="$folded" '$1 == m || $2 == m { print $2; found = 1; exit } END { exit !found }'; then
        return 0
      fi
    fi

    case "$base" in
      gemini-3.8-flash | gemini-3.5-flash) name=flash-3.8 ;;
      gemini-4-hydrogen) name=hydrogen ;;
      gemini-4-neon) name=neon ;;
      gemini-4-carbon) name=carbon ;;
      gemini-4-argon) name=argon ;;
      claude*sonnet*) name=sonnet ;;
      claude*opus*) name=opus ;;
      *) name="$base" ;;
    esac
    bare_resolved="$(harness_agy_model_table | awk -F'\t' -v m="$name" '$1 == m || $2 == m { print $2; found = 1; exit } END { exit !found }' || printf '%s\n' "$base")"
    case "$bare_resolved" in
      *-low|*-medium|*-high|*-xhigh|*-max)
        printf "unsupported effort '%s' for model '%s'\n" "$eff" "$base" >&2
        return 1
        ;;
      *)
        printf '%s\n' "$bare_resolved"
        return 0
        ;;
    esac
  fi

  folded="${raw/:/-}"
  if harness_agy_model_table | awk -F'\t' -v m="$folded" '$1 == m || $2 == m { print $2; found = 1; exit } END { exit !found }'; then
    return 0
  fi
  case "$base" in
    gemini-3.8-flash | gemini-3.5-flash) name=flash-3.8 ;;
    gemini-4-hydrogen) name=hydrogen ;;
    gemini-4-neon) name=neon ;;
    gemini-4-carbon) name=carbon ;;
    gemini-4-argon) name=argon ;;
    claude*sonnet*) name=sonnet ;;
    claude*opus*) name=opus ;;
    *) name="$base" ;;
  esac
  harness_agy_model_table | awk -F'\t' -v m="$name" '$1 == m { print $2; found = 1; exit } END { exit !found }' \
    || printf '%s\n' "$base"
}

harness_agy_effort() {
  local raw="${1:-}" base eff resolved
  base="${raw%%:*}"
  [ "$base" != "$raw" ] || return 0
  eff="${raw#*:}"
  case "$eff" in
    low|medium|high|xhigh|max) ;;
    *) return 1 ;;
  esac
  resolved="$(harness_agy_model "$raw")" || return 1
  case "$resolved" in
    *-"$eff") return 0 ;;
    *-low|*-medium|*-high|*-xhigh|*-max) return 1 ;;
  esac
  printf '%s\n' "$eff"
}

# Gives agy the reviewer HOME's copy of the gate's CLI state (the OAuth login)
# and the read-only settings. $1 = reviewer home.
harness_agy_seed() {
  local home="$1"
  if reviewer_uid_mode; then
    # The gate cannot write in the reviewer's HOME: stream the login in.
    reviewer_seed_dir "$home" .gemini
    reviewer_exec "$home" bash -c "$(declare -f agy_write_settings)"'; agy_write_settings "$HOME/.gemini/antigravity-cli"' || true
    return 0
  fi
  if [ -d "${HOME:-}/.gemini" ]; then
    cp -a "$HOME/.gemini" "$home/.gemini" 2>/dev/null || true
  fi
  agy_write_settings "$home/.gemini/antigravity-cli"
}

# Starts the reviewer in the background and leaves its pid in REVIEWER_PID.
# $1 = reviewer HOME, $2 = model, $3 = task, $4 = guidance, $5 = file for
# stdout, $6 = file for stderr. stdin is /dev/null. agy has no system-prompt
# flag here, so the guidance goes in front of the task. Read-only access comes
# from the settings file seeded above, never from a permission-skipping flag.
harness_agy_execute() {
  local rhome="$1" model="$2" task="$3" guidance="$4" raw="$5" err="$6"
  local prompt="$task"
  if [ -n "$guidance" ]; then
    prompt="${guidance}"$'\n\n'"${task}"
  fi
  local resolved_model eff eff_flag=()
  resolved_model="$(harness_agy_model "$model")" || return 1
  eff="$(harness_agy_effort "$model")" || return 1
  [ -n "$eff" ] && eff_flag=(--effort "$eff")
  harness_agy_seed "$rhome"
  reviewer_launch "$rhome" -- \
    agy -p "$prompt" \
    --model "$resolved_model" \
    ${eff_flag[@]+"${eff_flag[@]}"} \
    --disable-slash-commands \
    --output-format json \
    </dev/null >"$raw" 2>"$err" &
  REVIEWER_PID=$!
}

# $1 = reviewer home. agy refreshes its OAuth login during a run; the refreshed
# file goes back to the token directory, read out through the reviewer's own uid
# where the gate cannot read the reviewer's HOME.
harness_agy_finish() {
  local home="$1" rel=".gemini/antigravity-cli/antigravity-oauth-token" tmp
  [ -d "$TOKEN_DIR" ] || return 0
  if reviewer_uid_mode; then
    tmp="$(mktemp)"
    reviewer_read_file "$home" "$rel" >"$tmp" 2>/dev/null || true
    if [ -s "$tmp" ]; then cp "$tmp" "$TOKEN_DIR/antigravity-oauth-token" 2>/dev/null || true; fi
    rm -f "$tmp"
  elif [ -s "$home/$rel" ]; then
    cp "$home/$rel" "$TOKEN_DIR/antigravity-oauth-token" 2>/dev/null || true
  fi
}

# $1 = the file the CLI printed. rc 0 and the review text on stdout when the
# run produced a review; otherwise rc 1, nothing on stdout, one line on stderr.
# The proof that the model ran is generated output: tokens under any of the
# places agy reports them, or a response with length.
harness_agy_parse() {
  local raw="$1" envelope produced result status
  # An error object with a status: rc 2 for a 401 or a 404 (the credential or
  # the model, which retrying cannot change), rc 1 for the rest, all named.
  status="$(jq -r 'if type == "object" and (.error | type) == "object"
      and (.error.code | type) == "number" then .error.code else empty end' <"$raw" 2>/dev/null || true)"
  if [ -n "$status" ]; then
    printf 'the API answered %s: %s\n' "$status" \
      "$(jq -r '.error.message // ""' <"$raw" 2>/dev/null | head -n 1 | cut -c1-200)" >&2
    case "$status" in 401 | 404) return 2 ;; *) return 1 ;; esac
  fi
  envelope="$(jq -r 'if type == "object"
      and (.response != null or .result != null)
      and (.error == null or .error == false)
    then "ok" else "bad" end' <"$raw" 2>/dev/null || echo bad)"
  if [ "$envelope" != ok ]; then
    printf 'no successful response in the output\n' >&2
    return 1
  fi
  local denied
  denied="$(jq -r 'if type == "object" and (.denied_actions | type) == "array" and (.denied_actions | length) > 0
      then [.denied_actions[] | (.action // .display_name // tostring)] | join(", ")
      else empty end' <"$raw" 2>/dev/null || true)"
  if [ -n "$denied" ]; then
    printf 'review aborted due to denied_actions: %s\n' "$denied" >&2
    return 1
  fi
  produced="$(jq -r '[(.usage.output_tokens // 0),
    (.stats.outputTokens // 0),
    ((.stats.models // {}) | to_entries | map(.value.tokens.candidates // 0) | add // 0),
    ((.response // "") | length)]
    | max' <"$raw" 2>/dev/null || echo 0)"
  case "$produced" in
    '' | *[!0-9]*) produced=0 ;;
  esac
  if [ "$produced" -lt 1 ]; then
    printf 'the model generated nothing, so this is the runtime talking, not a review\n' >&2
    return 1
  fi
  result="$(jq -r '.response // .result' <"$raw" 2>/dev/null)" || {
    printf 'could not read the review out of the output\n' >&2
    return 1
  }
  if [ -z "$(printf '%s' "$result" | tr -d '[:space:]')" ]; then
    printf 'the review is empty\n' >&2
    return 1
  fi
  printf '%s\n' "$result"
}

# Output format:
#   NO_FINDINGS  (exit 0)
#   FINDINGS:<N> (exit 0)
#   MALFORMED    (exit 1)
harness_agy_parse_verdict() {
  local output_file="$1"
  [ -f "$output_file" ] || { printf 'MALFORMED\n'; return 1; }

  local verdict
  verdict="$(awk 'NF { print; exit }' "$output_file" | tr -d '\r')"
  [ -n "$verdict" ] || { printf 'MALFORMED\n'; return 1; }

  case "$verdict" in
    '**No findings.'*)
      printf 'NO_FINDINGS\n'
      return 0
      ;;
    '**'[0-9]*' finding'*)
      printf 'FINDINGS:%s\n' "$(printf '%s\n' "$verdict" | sed -E 's/^\*\*([0-9]+) finding.*/\1/')"
      return 0
      ;;
    *)
      printf 'MALFORMED\n'
      return 1
      ;;
  esac
}
