#!/usr/bin/env bash
set -euo pipefail
uid=$(id -u)
src="${AUTO_REVIEW_TOKEN_DIR:-/run/user/$uid/auto-review}"
AUTO_REVIEW_GATE_UID="${AUTO_REVIEW_GATE_UID:-10001}"
rc=0
if [ ! -d "$src" ]; then
  exit 0
fi
for f in "$src"/*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  if docker exec -i -u "$AUTO_REVIEW_GATE_UID" auto-review sh -c "cat > /run/auto-review/$name && chmod 0600 /run/auto-review/$name" < "$f"; then
    echo "Delivered $name into auto-review container"
  else
    echo "Could not deliver $name into auto-review container" >&2
    rc=1
  fi
done
exit "$rc"
