#!/usr/bin/env bash
# Clones that carry no credential (upstream issue).
#
# The remote URL used to be https://x-access-token:<token>@github.com/..., which
# writes the token into .git/config, a file the reviewer's checkout holds and
# the reviewer can read. Here the URL is bare and the token is handed to git at
# the moment it talks to the network, by a credential helper that reads
# $GH_TOKEN from the environment. The helper text holds the variable's name,
# not its value, so neither argv nor .git/config ever has the token.

# git with GitHub authentication for this one invocation. `-c` before the
# subcommand is not persisted, unlike `git clone -c`, which writes the config
# into the new repository.
clone_git() {
  if [ -n "${GH_TOKEN:-}" ]; then
    git -c credential.helper= \
      -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
      "$@"
  else
    git "$@"
  fi
}

# $1 = owner/repo, $2 = path. Base is AUTO_REVIEW_GITHUB_BASE, default GitHub.
clone_repo() {
  local repo="$1" path="$2" base="${AUTO_REVIEW_GITHUB_BASE:-https://github.com}"
  clone_git clone --quiet "$base/$repo.git" "$path"
}

# Strips userinfo from every remote.*.url and remote.*.pushurl of an existing
# clone.
clone_scrub_credentials() {
  local path="$1" key url clean
  [ -d "$path/.git" ] || return 0
  while read -r key url; do
    [ -n "$key" ] || continue
    clean="$(printf '%s' "$url" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@#\1#')"
    if [ "$clean" != "$url" ]; then
      git -C "$path" config "$key" "$clean"
    fi
  done < <(git -C "$path" config --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null)
  return 0
}
