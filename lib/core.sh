#!/usr/bin/env bash
# Pure core evaluation functions for auto-review.
#
# Contains pure logic with no direct network side effects:
# glob matching, diff line parsing, generated code stripping,
# size checks, and repo identifier parsing.

# owner/repo from checkout's origin.
repo_of() {
  local path="$1" url
  [ -d "$path/.git" ] || die "$path is not a git checkout"
  url="$(git -C "$path" remote get-url origin 2>/dev/null)" || die "$path has no origin"
  url="${url%.git}"
  url="${url#*github.com[:/]}"
  url="${url#https://github.com/}"
  url="${url#git@github.com:}"
  case "$url" in
    */*) echo "$url" ;;
    *) die "cannot read owner/repo out of origin ($url)" ;;
  esac
}

slug_of() { repo_of "$1" | tr '/' '-'; }

# XML escaping for prompt injection into XML tags.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Prints the glob out of $1 (one per line) that $2 matches, or nothing.
matched_glob() {
  local patterns="$1" value="$2" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254 # unquoted on purpose for pattern match
    case "$value" in
      $pattern)
        printf '%s' "$pattern"
        return 0
        ;;
    esac
  done <<<"$patterns"
  return 1
}

# Matches a changed path against globs, handling leading **/ matching root.
path_glob_matched() {
  local patterns="$1" path="$2" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254 # unquoted on purpose
    case "$path" in
      $pattern)
        printf '%s' "$pattern"
        return 0
        ;;
    esac
    case "$pattern" in
      '**/'*)
        # shellcheck disable=SC2254
        case "$path" in
          ${pattern#\*\*/})
            printf '%s' "$pattern"
            return 0
            ;;
        esac
        ;;
    esac
  done <<<"$patterns"
  return 1
}

# Every path touched matches a --skip-if-only glob.
only_low_risk_paths() {
  local base="$1" path matched used="" any=0
  [ -n "$SKIP_IF_ONLY" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    any=1
    matched="$(path_glob_matched "$SKIP_IF_ONLY" "$path")" || return 1
    case $'\n'"$used" in
      *$'\n'"$matched"$'\n'*) ;;
      *) used="${used}${matched}"$'\n' ;;
    esac
  done < <(git diff --name-only --no-renames "origin/$base...HEAD" 2>/dev/null || echo $'\n')
  [ "$any" = 1 ] || return 1
  printf '%s' "$used"
}

# Drops lockfiles and test snapshots from a patch.
strip_generated() {
  awk -v out="$2" -v marked="${3:-}" '
    function flush() { if (drop) printf "%s\t%d\n", name, n }
    BEGIN {
      printf "" >out
      if (marked != "") while ((getline line <marked) > 0) generated[line] = 1
    }
    /^diff --git / {
      flush()
      name = $0
      sub(/^diff --git .* "?b\//, "", name)
      sub(/"$/, "", name)
      n = 0
      drop = name ~ /(^|\/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb|Cargo\.lock|poetry\.lock|uv\.lock|Gemfile\.lock|go\.sum|composer\.lock)$/ ||
        name ~ /\.snap$/ || name ~ /(^|\/)__snapshots__\// || name in generated
    }
    { if (drop) n++; else print >out }
    END { flush() }
  ' "$1"
}

# Paths of the patch that carry a boolean attribute (linguist-generated,
# linguist-vendored) in the base branch's .gitattributes, one per line. Fails
# when the base cannot be read, so a caller can tell "none" from "unknown".
attributes_set() {
  local patch="$1" base="$2" attr="$3" dir ok=0
  dir="$(mktemp -d)"
  if GIT_INDEX_FILE="$dir/index" git read-tree "origin/$base" 2>/dev/null; then
    patch_lines_per_file "$patch" | cut -f1 | sed '/\\/ s/.*/"&"/' |
      GIT_INDEX_FILE="$dir/index" git check-attr --cached --stdin "$attr" \
        >"$dir/attributes" 2>/dev/null || ok=1
  else
    ok=1
  fi
  if [ "$ok" = 0 ]; then
    sed -n -e "s/: $attr: true\$//p" -e "s/: $attr: set\$//p" \
      "$dir/attributes" | sed 's/^"//; s/"$//'
  fi
  rm -rf "$dir"
  return "$ok"
}

# Reads linguist-generated paths from the base branch .gitattributes.
generated_by_attributes() { attributes_set "$1" "$2" linguist-generated; }

# Reads linguist-vendored paths from the base branch .gitattributes.
vendored_by_attributes() { attributes_set "$1" "$2" linguist-vendored; }

# Counts lines per file in a unified patch.
patch_lines_per_file() {
  awk '
    function flush() { if (name != "") printf "%s\t%d\n", name, n }
    /^diff --git / {
      flush()
      name = $0
      sub(/^diff --git .* "?b\//, "", name)
      sub(/"$/, "", name)
      n = 0
    }
    { n++ }
    END { flush() }
  ' "$1"
}

# What kind of file a path is, by its name alone (upstream issue).
# The kinds are generated, vendored, migrations, config, tests, docs and source;
# binary and renamed are decided from the patch, not the name, see classify_paths.
# The order is the precedence: a lockfile in a vendor directory is generated, a
# workflow under a tests directory is config.
path_kind() {
  local p="$1" b="${1##*/}"
  case "$p" in
    __snapshots__/* | */__snapshots__/*) echo generated; return ;;
  esac
  case "$b" in
    package-lock.json | npm-shrinkwrap.json | yarn.lock | pnpm-lock.yaml | bun.lockb | Cargo.lock | poetry.lock | uv.lock | Gemfile.lock | go.sum | composer.lock | *.snap)
      echo generated; return ;;
  esac
  case "$p" in
    vendor/* | */vendor/* | third_party/* | */third_party/*) echo vendored; return ;;
  esac
  case "$b" in
    *.min.*) echo vendored; return ;;
  esac
  case "$p" in
    migrations/* | */migrations/*) echo migrations; return ;;
  esac
  case "$b" in
    *.sql | schema.* | *.prisma | *.proto) echo migrations; return ;;
  esac
  case "$p" in
    .github/* | */.github/* | hooks/* | */hooks/*) echo config; return ;;
  esac
  case "$b" in
    Dockerfile* | *compose*.yml | *compose*.yaml | *.toml | *.ini | settings*.json | package.json | Makefile)
      echo config; return ;;
  esac
  if path_glob_matched "${TEST_PATHS:-}" "$p" >/dev/null; then echo tests; return; fi
  case "$p" in
    docs/* | */docs/*) echo docs; return ;;
  esac
  case "$b" in
    *.md | *.mdx | *.rst | *.txt) echo docs; return ;;
  esac
  echo source
}

# One row per file of a unified patch: path, kind, lines. The shell decides the
# kind, so the reviewer and the scope check read the same table and neither
# guesses.
#
#   classify_paths <patch> [<vendored-paths-file> [<generated-rows-file>]]
#
# <vendored-paths-file> is linguist-vendored paths from the base branch, one per
# line. <generated-rows-file> is the path<TAB>lines rows strip_generated printed
# for the files it took out of the patch; they are listed as generated, because
# "not read" is part of what the reviewer is told. A patch made with rename
# detection shows a pure rename as `rename from/to` with no hunk; that is
# `renamed`, a binary file is `binary`, and a rename with edits is read as the
# kind of its new path.
classify_paths() {
  local patch="$1" vendored="${2:-}" generated="${3:-}" path lines flags kind
  while IFS=$'\t' read -r path lines flags; do
    [ -n "$path" ] || continue
    kind="$(path_kind "$path")"
    if [ "$kind" != generated ]; then
      if [ "$flags" = binary ]; then
        kind=binary
      elif [ "$flags" = renamed ]; then
        kind=renamed
      elif [ "$kind" != vendored ] && [ -n "$vendored" ] && [ -s "$vendored" ] && grep -qxF -- "$path" "$vendored"; then
        kind=vendored
      fi
    fi
    printf '%s\t%s\t%s\n' "$path" "$kind" "$lines"
  done < <(awk '
    function flush() {
      if (name == "") return
      f = ""
      if (bin) f = "binary"
      else if (ren && !hunk) f = "renamed"
      printf "%s\t%d\t%s\n", name, n, f
    }
    /^diff --git / {
      flush()
      name = $0
      sub(/^diff --git .* "?b\//, "", name)
      sub(/"$/, "", name)
      n = 0; bin = 0; ren = 0; hunk = 0
    }
    { n++ }
    /^Binary files .* differ$/ || /^GIT binary patch$/ { bin = 1 }
    /^rename from / { ren = 1 }
    /^@@ / { hunk = 1 }
    END { flush() }
  ' "$patch")
  if [ -n "$generated" ] && [ -s "$generated" ]; then
    while IFS=$'\t' read -r path lines; do
      [ -n "$path" ] || continue
      printf '%s\tgenerated\t%s\n' "$path" "$lines"
    done <"$generated"
  fi
}

# True when a patch is big enough to be planned before it is read: over
# plan_over lines of patch (generated files already removed) or over
# plan_over_files files (upstream issue).
#
#   plan_needed <patch-lines> <files> <over-lines> <over-files>
plan_needed() {
  [ "$1" -gt "$3" ] || [ "$2" -gt "$4" ]
}

# The READING-PLAN block the reviewer wrote before the sentinel, as a collapsed
# section; nothing when it wrote none. Only the text before the sentinel is
# looked at, and the first complete block wins, so a plan quoted in a finding
# adds nothing. A line that would open or close a <details> inside the plan is
# dropped, so the plan cannot end its own section early.
#
#   reading_plan <raw-result-file> <sentinel>
reading_plan() {
  grep -qxF "$2" "$1" || return 0
  awk -v s="$2" '
    $0 == s { exit }
    done { next }
    $0 == "READING-PLAN-BEGIN" && !on { on = 1; next }
    $0 == "READING-PLAN-END" && on { on = 0; done = 1; next }
    on && /<\/?details/ { next }
    on { buf = buf $0 "\n" }
    END {
      if (!done || buf ~ /^[ \t\n]*$/) exit
      printf "<details><summary>Reading plan</summary>\n\n%s</details>\n", buf
    }
  ' "$1"
}

# The paths of the "files in the patch" table the tool wrote into the material,
# one per line (upstream issue). The tool appends the table after the pull
# request's own text, so the last heading is the tool's and an earlier one, or a
# row, in a title or body is not: the list is reset at every heading and the last
# one is printed.
scope_manifest() {
  scope_table "$1" | sed -E 's/^[a-z]+, [0-9]+, //'
}

# The same table with its kind and line count: "kind, lines, path" per line.
scope_table() {
  awk '
    /^## files in the patch$/ { n = 0; on = 1; next }
    on && /^- [a-z]+, [0-9]+, / { sub(/^- /, ""); rows[++n] = $0; on = 2; next }
    on == 2 { on = 0 }
    END { for (i = 1; i <= n; i++) print rows[i] }
  ' "$1"
}

# Checks a review's scope block against the manifest and prints the review with
# what is missing added. Every path of the manifest has to be named,
# in backticks, in the block; the file name alone counts when it is unique in the
# manifest. A path that is not is listed in a `not accounted for` row, which is
# added to the block when there is one and written as a block of its own when the
# review has none. The review is never retried and never refused for this.
#
#   scope_check <review-file> <manifest-file>
scope_check() {
  local review="$1" manifest="$2" block missing="" path base n count=0
  block="$(awk '/<details><summary>Read:/ { on = 1 } on { print } on && /<\/details>/ { exit }' "$review")"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    base="${path##*/}"
    if [[ "$block" == *"\`$path\`"* ]]; then continue; fi
    n="$(awk -v b="/$base" -v p="$path" '("/" $0) ~ (b "$") { c++ } END { print c + 0 }' "$manifest")"
    if [ "$n" = 1 ] && [[ "$block" == *"\`$base\`"* ]]; then continue; fi
    missing="$missing${missing:+, }\`$path\`"
    count=$((count + 1))
  done <"$manifest"
  if [ -z "$missing" ]; then
    cat "$review"
    return 0
  fi
  if [ -n "$block" ]; then
    awk -v m="$missing" -v c="$count" '
      !done && /<details><summary>Read:/ { sub(/<\/summary>/, " · " c " not accounted for</summary>"); inb = 1 }
      inb && /<\/details>/ { print "| not accounted for | " m " |"; inb = 0; done = 1 }
      { print }
    ' "$review"
  else
    cat "$review"
    printf '\n<details><summary>Read: scope block missing · not accounted for</summary>\n\n| how | files |\n|---|---|\n| not accounted for | %s |\n</details>\n' "$missing"
  fi
}

# The tokens the close reads come to: 19 per line of the files whose kind says
# they are read in full (source, config, migrations), from the "files in the
# patch" table in the material. Tests are read by names and assertions and are
# not counted (upstream issue).
#
#   close_read_estimate <material-file>
close_read_estimate() {
  scope_table "$1" | awk -F', ' '$1 == "source" || $1 == "config" || $1 == "migrations" { n += $2 } END { print n * 19 + 0 }'
}

# The patch of the checked-out head against origin/<base>, with rename detection
# asked for explicitly (upstream issue): a pure rename is then a `rename
# from/to` with no hunks instead of a whole file deleted and added, whatever the
# machine's diff.renames says.
#
#   patch_against <base>
patch_against() {
  git -c diff.renames=true diff -M "origin/$1...HEAD"
}

# Checks if any PR label matches a skip pattern.
label_skipped() {
  local labels="$1" label matched
  [ -n "$SKIP_LABELS" ] || return 1
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    if matched="$(matched_glob "$SKIP_LABELS" "$label")"; then
      printf '%s (%s)' "$label" "$matched"
      return 0
    fi
  done < <(printf '%s\n' "$labels" | tr '\037' '\n')
  return 1
}

# Token file path for a repository slug.
token_file_for() { echo "$TOKEN_DIR/$(slug_of "$1").token"; }

# The token file a tick reads for a checkout: the one of the repository's owner,
# gh-<owner>.token (upstream issue), else the per-repository file of
# before. Reading only; `token` still writes token_file_for.
token_file_for_read() {
  local owner_file
  owner_file="$TOKEN_DIR/gh-$(repo_of "$1" | cut -d/ -f1).token"
  if [ -r "$owner_file" ]; then echo "$owner_file"; else token_file_for "$1"; fi
}

# Classifies history entry into AUTO-REVIEW, CI-GUARD, or HUMAN.
classify_history_entry() {
  local header="$1" body="$2"
  if type is_automated_review >/dev/null 2>&1 && is_automated_review "$body"; then
    echo "AUTO-REVIEW"
    return 0
  fi
  case "$header" in
    *"[bot]"* | *"github-actions"* | *"guard"* | *"ci-"*)
      echo "CI-GUARD"
      return 0
      ;;
    *)
      echo "HUMAN"
      return 0
      ;;
  esac
}

# How many seconds the reviewer is given before it is killed (upstream issue,
# the design docs): AUTO_REVIEW_TIMEOUT (default 900 s) below the plan threshold, and
# scaled with the patch size once a plan is needed (at least twice the base
# when READING_PLAN=1, so a planned or 10000-line review is not killed at 900 s).
#
#   reviewer_timeout <patch-lines> [<reading-plan> [<base-seconds> [<plan-over>]]]
reviewer_timeout() {
  local lines="${1:-0}" plan="${2:-${READING_PLAN:-0}}"
  local base="${3:-${AUTO_REVIEW_TIMEOUT:-900}}" over="${4:-${PLAN_OVER:-1500}}"
  [ "$lines" -ge 0 ] 2>/dev/null || lines=0
  [ "$base" -gt 0 ] 2>/dev/null || base=900
  [ "$over" -gt 0 ] 2>/dev/null || over=1500
  if [ "$lines" -gt "$over" ]; then
    plan=1
  fi
  if [ "$plan" != 1 ]; then
    echo "$base"
    return 0
  fi
  local scaled=$((base * 2))
  local by_lines=$((base + (lines - over) * base / (over * 2)))
  if [ "$by_lines" -gt "$scaled" ]; then
    scaled="$by_lines"
  fi
  if [ "$scaled" -gt "$((base * 4))" ]; then
    scaled="$((base * 4))"
  fi
  echo "$scaled"
}
