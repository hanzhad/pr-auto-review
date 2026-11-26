#!/usr/bin/env bash
# Pure functions to emit and inspect structured machine marks for auto-review.
#
# Generates and parses machine-readable HTML comment metadata embedded in reviews:
# <!-- auto-review: {"v":1,"tool":"auto-review","sha":"$sha","verdict":"$verdict","findings":$findings,"ts":$ts} -->

# emit_machine_mark(sha, verdict, findings, ts)
# Generates an HTML comment block containing compact JSON metadata:
# <!-- auto-review: {"v":1,"tool":"auto-review","sha":"$sha","verdict":"$verdict","findings":$findings,"ts":$ts} -->
emit_machine_mark() {
  local sha="${1:-}"
  local verdict="${2:-}"
  local findings="${3:-0}"
  local ts="${4:-}"

  case "$findings" in
    '' | *[!0-9]*) findings=0 ;;
  esac

  if [ -z "$ts" ]; then
    ts="$(date +%s 2>/dev/null || echo 0)"
  fi

  case "$ts" in
    '' | *[!0-9]*)
      printf '<!-- auto-review: {"v":1,"tool":"auto-review","sha":"%s","verdict":"%s","findings":%s,"ts":"%s"} -->\n' \
        "$sha" "$verdict" "$findings" "$ts"
      ;;
    *)
      printf '<!-- auto-review: {"v":1,"tool":"auto-review","sha":"%s","verdict":"%s","findings":%s,"ts":%s} -->\n' \
        "$sha" "$verdict" "$findings" "$ts"
      ;;
  esac
}

# parse_machine_mark(text)
# Extracts the JSON object from the <!-- auto-review: ... --> comment if present.
# Returns 0 and prints JSON if found; returns 1 if not found.
parse_machine_mark() {
  local text="${1:-}"
  [ -n "$text" ] || return 1

  local raw=""
  raw="$(printf '%s\n' "$text" | awk '
    /<!--[[:space:]]*auto-review:/ {
      sub(/.*<!--[[:space:]]*auto-review:[[:space:]]*/, "")
      sub(/[[:space:]]*-->.*/, "")
      print
      exit
    }
  ')"

  [ -n "$raw" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    local json
    json="$(printf '%s' "$raw" | jq -c 'if type == "object" then . else empty end' 2>/dev/null)" || return 1
    [ -n "$json" ] || return 1
    printf '%s\n' "$json"
    return 0
  else
    case "$raw" in
      \{*\})
        printf '%s\n' "$raw"
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  fi
}

# is_automated_review(text)
# Checks whether the review text originated from auto-review:
# - Returns 0 if <!-- auto-review: is present and valid.
# - Fallback: Returns 0 if text contains legacy footer string: Automated review. Not an approval.
# - Returns 1 otherwise (human approval, manual comment, CI bot).
is_automated_review() {
  local text="${1:-}"
  [ -n "$text" ] || return 1

  # Check 1: Valid machine mark
  if parse_machine_mark "$text" >/dev/null 2>&1; then
    return 0
  fi

  # Check 2: Fallback to legacy footer
  case "$text" in
    *"Automated review. Not an approval."*)
      return 0
      ;;
  esac

  return 1
}

# extract_mark_field(mark_json, field)
# Extracts a specific field from the mark JSON (e.g. sha, verdict, findings).
# Returns 0 and prints field value if found; returns 1 if not found.
extract_mark_field() {
  local mark_json="${1:-}"
  local field="${2:-}"

  [ -n "$mark_json" ] || return 1
  [ -n "$field" ] || return 1

  local parsed_mark=""
  # If passed full review body or comment block instead of bare JSON, extract mark first
  case "$mark_json" in
    *"<!-- auto-review:"*)
      parsed_mark="$(parse_machine_mark "$mark_json" 2>/dev/null || echo "")"
      ;;
  esac

  if [ -n "$parsed_mark" ]; then
    mark_json="$parsed_mark"
  elif [ "$field" = "sha" ]; then
    local footer_sha=""
    footer_sha="$(printf '%s\n' "$mark_json" | sed -n 's/.*• Commit:[[:space:]]*\([a-zA-Z0-9]\{7,40\}\).*/\1/p' | head -n1)"
    if [ -n "$footer_sha" ]; then
      printf '%s\n' "$footer_sha"
      return 0
    fi
  fi

  [ -n "$mark_json" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    if ! printf '%s' "$mark_json" | jq -e --arg f "$field" 'has($f) and .[$f] != null' >/dev/null 2>&1; then
      return 1
    fi
    local val
    val="$(printf '%s' "$mark_json" | jq -r --arg f "$field" '.[$f]')"
    printf '%s\n' "$val"
    return 0
  else
    local escaped_field
    escaped_field="$(printf '%s' "$field" | sed 's/[][\/.^$*]/\\&/g')"
    local raw_val
    raw_val="$(printf '%s' "$mark_json" | sed -n 's/.*"'"$escaped_field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ -n "$raw_val" ]; then
      printf '%s\n' "$raw_val"
      return 0
    fi
    raw_val="$(printf '%s' "$mark_json" | sed -n 's/.*"'"$escaped_field"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
    if [ -n "$raw_val" ]; then
      printf '%s\n' "$raw_val"
      return 0
    fi
    return 1
  fi
}

# format_review_footer([sha])
# Emits human-readable review footer with commit SHA if provided:
# ---
# _Automated review. Not an approval._ • Commit: <short_sha>
format_review_footer() {
  local sha="${1:-}"
  if [ -n "$sha" ]; then
    printf '\n\n---\n_Automated review. Not an approval._ • Commit: %s\n' "${sha:0:7}"
  else
    printf '\n\n---\n_Automated review. Not an approval._\n'
  fi
}

# format_review_with_mark(body, sha, verdict, findings, [ts])
# Appends the machine mark comment to the review body.
format_review_with_mark() {
  local body="${1:-}"
  local sha="${2:-}"
  local verdict="${3:-}"
  local findings="${4:-0}"
  local ts="${5:-}"

  local mark
  mark="$(emit_machine_mark "$sha" "$verdict" "$findings" "$ts")"

  if [ -n "$body" ]; then
    case "$body" in
      *"
")
        printf '%s%s\n' "$body" "$mark"
        ;;
      *)
        printf '%s\n%s\n' "$body" "$mark"
        ;;
    esac
  else
    printf '%s\n' "$mark"
  fi
}
