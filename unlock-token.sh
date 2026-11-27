#!/usr/bin/env bash
# Token receiver script for pr-auto-review container.
#
# Receives token from stdin and stores it in RAM/tmpfs (/run/auto-review).
# If the auto-review Docker container is running, injects into container tmpfs.
set -euo pipefail

name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$name" ] || { echo "unlock-token needs --name <slug>" >&2; exit 1; }

# The gate uid owns /run/auto-review in the container (0700), so the exec goes in
# as it.
AUTO_REVIEW_GATE_UID="${AUTO_REVIEW_GATE_UID:-10001}"

# Deliver into the container tmpfs. A container that exists but is stopped, or
# whose exec fails, is an error: the host directory is not mounted into it, so a
# token left there would never be read. The host fallback is only for a machine
# with no auto-review container at all.
if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "auto-review"; then
    if ! docker exec -i -u "$AUTO_REVIEW_GATE_UID" auto-review sh -c "cat > /run/auto-review/$name.token && chmod 0600 /run/auto-review/$name.token"; then
      echo "auto-review: could not deliver token for $name into the machine container" >&2
      exit 1
    fi
    echo "auto-review: delivered token for $name into machine container"
    exit 0
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "auto-review"; then
    echo "auto-review: the machine container is not running; start it and re-run to deliver the token for $name" >&2
    exit 1
  fi
fi

# Host fallback: no docker, or no auto-review container at all.
token_dir="${AUTO_REVIEW_TOKEN_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/auto-review}"
mkdir -p "$token_dir" 2>/dev/null || true
chmod 0700 "$token_dir" 2>/dev/null || true
cat >"$token_dir/$name.token"
chmod 0600 "$token_dir/$name.token" 2>/dev/null || true
echo "auto-review: delivered token for $name into host runtime directory $token_dir"
