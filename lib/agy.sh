#!/usr/bin/env bash
# The agy settings file for a review (upstream issue).
#
# The reviewer reads a checkout and prints prose; it writes nothing and runs
# nothing. It used to be allowed everything (`"allow": ["*"]`) and launched with
# --dangerously-skip-permissions, so a prompt injected through a pull request
# could run a shell. The allowlist is the read-only tools only.

# $1 = directory (agy's config directory). Writes $1/settings.json.
agy_write_settings() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/settings.json" <<'JSON'
{
  "trustedWorkspaces": [
    "/var/lib/auto-review"
  ],
  "toolPermission": "request-review",
  "permissions": {
    "allow": [
      "read_file(/var/lib/auto-review)",
      "read_file(/tmp)"
    ],
    "deny": [
      "command(*)",
      "write_file(*)",
      "read_url(*)",
      "execute_url(*)",
      "download_url(*)",
      "mcp(*)"
    ]
  }
}
JSON
  chmod 0600 "$dir/settings.json" 2>/dev/null || true
}
