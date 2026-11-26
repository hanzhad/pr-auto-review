#!/usr/bin/env bash
# Container entrypoint for auto-review machine service (Issue 4.1).
set -u

# Started as uid 0 (compose `user: "0"`), becomes the gate (uid 10001) before
# anything else runs. What survives the switch is CAP_SETUID/CAP_SETGID, ambient,
# so the gate can start each review as uid 10002 (lib/reviewer-uid.sh) and can
# do nothing else privileged. Everything below, the daemon and the subcommands,
# runs as the gate. (--bounding-set would need CAP_SETPCAP, so it is not used.)
if [ "$(id -u)" = 0 ] && command -v setpriv >/dev/null 2>&1; then
  export HOME=/home/reviewer AUTO_REVIEW_REVIEWER_UID=10002
  exec setpriv --reuid 10001 --regid 10001 --clear-groups     --inh-caps +setuid,+setgid --ambient-caps +setuid,+setgid "$0" "$@"
fi

# Enforce secure sandbox boundary inside container:
# Verify strictly NO Docker socket
if [ -S /var/run/docker.sock ]; then
  echo "FATAL: /var/run/docker.sock is mounted into auto-review container! Exiting for security." >&2
  exit 1
fi

# Source registry functions for path resolution
if [ -f /usr/local/lib/auto-review/lib/registry.sh ]; then
  # shellcheck source=/usr/local/lib/auto-review/lib/registry.sh
  . /usr/local/lib/auto-review/lib/registry.sh
elif [ -f "$(dirname "$0")/lib/registry.sh" ]; then
  . "$(dirname "$0")/lib/registry.sh"
fi

# Source active-status helpers for atomic locked status.json updates
if [ -f /usr/local/lib/auto-review/lib/active-status.sh ]; then
  # shellcheck source=/usr/local/lib/auto-review/lib/active-status.sh
  . /usr/local/lib/auto-review/lib/active-status.sh
elif [ -f "$(dirname "$0")/lib/active-status.sh" ]; then
  . "$(dirname "$0")/lib/active-status.sh"
fi

# The gate's state directories are 0700 whatever mode an older volume has.
if [ -f /usr/local/lib/auto-review/lib/reviewer-uid.sh ]; then
  # shellcheck source=/usr/local/lib/auto-review/lib/reviewer-uid.sh
  . /usr/local/lib/auto-review/lib/reviewer-uid.sh
elif [ -f "$(dirname "$0")/lib/reviewer-uid.sh" ]; then
  . "$(dirname "$0")/lib/reviewer-uid.sh"
fi
if declare -F gate_protect_state_dirs >/dev/null 2>&1; then
  gate_protect_state_dirs
fi

# The registry lives in the state volume. A registry from before the volume
# (the checkout's projects.json, mounted read-only) is copied in once, and
# never over one that is already there (upstream issue).
AUTO_REVIEW_REGISTRY="${AUTO_REVIEW_REGISTRY:-/var/lib/auto-review/projects.json}"
export AUTO_REVIEW_REGISTRY
if declare -F registry_migrate_legacy >/dev/null 2>&1; then
  registry_migrate_legacy "${AUTO_REVIEW_LEGACY_REGISTRY:-/etc/auto-review/legacy/projects.json}" "$AUTO_REVIEW_REGISTRY" || true
fi
# A registry from before the machine owned the settings is brought up to date
# before the daemon reads it (upstream issue).
if declare -F registry_migrate >/dev/null 2>&1; then
  registry_migrate "$AUTO_REVIEW_REGISTRY" || true
fi

case "${1:-daemon}" in
  probe)
    fail=0
    echo "=== auto-review machine container security probe ==="
    # 1. The gate is uid 10001, not root, holding only SETUID/SETGID
    uid="$(id -u)"
    if [ "$uid" -eq 10001 ]; then
      echo "ok    gate runs as uid $uid after the drop"
    else
      echo "FAIL  gate runs as uid $uid, want 10001"
      fail=1
    fi
    caps="$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status)"
    if [ "$caps" = "00000000000000c0" ]; then
      echo "ok    gate capabilities are SETUID|SETGID only"
    else
      echo "FAIL  gate CapEff is $caps, want 00000000000000c0"
      fail=1
    fi
    # 1b. The reviewer's uid cannot read the gate's directories, and holds no caps
    rv_out="$(setpriv --reuid 10002 --regid 10002 --clear-groups --inh-caps -all --ambient-caps -all       sh -c 'ls /run/auto-review >/dev/null 2>&1 && echo readable; sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status' 2>&1)"
    case "$rv_out" in
      *readable*) echo "FAIL  uid 10002 can read /run/auto-review"; fail=1 ;;
      *0000000000000000) echo "ok    uid 10002 cannot read /run/auto-review and holds no capabilities" ;;
      *) echo "FAIL  reviewer uid probe: $rv_out"; fail=1 ;;
    esac

    # 2. No docker socket
    if [ ! -e /var/run/docker.sock ]; then
      echo "ok    no docker socket"
    else
      echo "FAIL  docker socket present"
      fail=1
    fi

    # 3. Essential binaries on PATH
    for b in git gh jq claude; do
      if command -v "$b" >/dev/null 2>&1; then
        echo "ok    binary available: $b"
      else
        echo "FAIL  missing binary: $b"
        fail=1
      fi
    done
    if command -v agy >/dev/null 2>&1; then
      echo "ok    binary available: agy"
    else
      echo "FAIL  missing binary: agy"
      fail=1
    fi

    # 4. Token directory
    if [ -d /run/auto-review ]; then
      echo "ok    runtime token dir present: /run/auto-review"
    else
      echo "FAIL  missing /run/auto-review"
      fail=1
    fi

    exit "$fail"
    ;;

  daemon)
    shift || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting auto-review machine daemon..."
    export AUTO_REVIEW_REGISTRY="${AUTO_REVIEW_REGISTRY:-/var/lib/auto-review/projects.json}"
    export AUTO_REVIEW_LOCK_DIR="${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}"
    export AUTO_REVIEW_STATUS_FILE="${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}/status.json"
    if [ -d "${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}" ] && declare -F status_daemon_started >/dev/null 2>&1; then
      status_daemon_started
    fi

    # Source what the daemon needs
    # shellcheck source=/usr/local/lib/auto-review/lib/registry.sh
    . /usr/local/lib/auto-review/lib/registry.sh
    # shellcheck source=/usr/local/lib/auto-review/lib/clone.sh
    . /usr/local/lib/auto-review/lib/clone.sh
    # shellcheck source=/usr/local/lib/auto-review/lib/agy.sh
    . /usr/local/lib/auto-review/lib/agy.sh

    registry_init "$AUTO_REVIEW_REGISTRY"

    # One tick over every project (upstream issue). The per-project tokens,
    # worktrees and scheduling are the tick's own; what is done here is what only
    # the container knows: where the state lives, the harness credentials, and a
    # credential-free clone for a project that has none yet.
    run_machine_tick() {
      export AUTO_REVIEW_INSIDE_CONTAINER=1
      export AUTO_REVIEW_TOKEN_DIR="${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}"
      export AUTO_REVIEW_CLONE_ROOT="${AUTO_REVIEW_CLONE_ROOT:-/var/lib/auto-review/clones}"
      unset GH_TOKEN GITHUB_TOKEN
      local agy_token_file="${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}/antigravity-oauth-token"
      local agy_dir="${HOME:-/home/reviewer}/.gemini/antigravity-cli"

      if [ -s "$agy_token_file" ] || [ -s "$agy_dir/antigravity-oauth-token" ]; then
        if [ -s "$agy_token_file" ] && [ ! -s "$agy_dir/antigravity-oauth-token" ]; then
          mkdir -p "$agy_dir"
          cp "$agy_token_file" "$agy_dir/antigravity-oauth-token"
          chmod 0600 "$agy_dir/antigravity-oauth-token" 2>/dev/null || true
        fi
        # Always rewritten: a settings.json left by an earlier version allows "*".
        agy_write_settings "$agy_dir"
      fi
      local claude_token_file="${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}/claude.token"
      # Only a token of the adapter's minimum length: a placeholder in the
      # environment would outrank the interactive login and fail every review.
      local claude_token_min
      claude_token_min="$(bash -c '. /usr/local/lib/auto-review/adapters/harness/claude-code.sh; harness_claude_token_min' 2>/dev/null || true)"
      if [ -r "$claude_token_file" ] && [ "$(tr -d '[:space:]' < "$claude_token_file" | wc -c)" -ge "${claude_token_min:-40}" ]; then
        export CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '\r\n' < "$claude_token_file")"
      fi
      local repo repo_slug clone_path token_file
      while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        repo_slug="$(echo "$repo" | tr '/' '-')"
        clone_path="$AUTO_REVIEW_CLONE_ROOT/$repo_slug"
        if [ ! -d "$clone_path/.git" ]; then
          token_file="$AUTO_REVIEW_TOKEN_DIR/gh-${repo%%/*}.token"
          [ -r "$token_file" ] || token_file="$AUTO_REVIEW_TOKEN_DIR/$repo_slug.token"
          if [ -r "$token_file" ]; then
            mkdir -p "$clone_path"
            ( GH_TOKEN="$(tr -d '[:space:]' < "$token_file")"; export GH_TOKEN; clone_repo "$repo" "$clone_path" 2>/dev/null ) || true
          fi
        fi
        # Clones made by an earlier version carry the token in their remote url.
        clone_scrub_credentials "$clone_path"
      done < <(registry_list_enabled "$AUTO_REVIEW_REGISTRY")

      /usr/local/bin/auto-review tick || true

      # Cleanup ephemeral conversation trajectories and logs to prevent unbounded tmpfs growth:
      rm -rf "$agy_dir/conversations"/* "$agy_dir/brain"/* "$agy_dir/log"/* "$agy_dir/cache"/* 2>/dev/null || true

      if [ -s "$agy_dir/antigravity-oauth-token" ] && [ -d "${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}" ]; then
        cp "$agy_dir/antigravity-oauth-token" "${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}/antigravity-oauth-token" 2>/dev/null || true
      fi
    }

    daemon_compute_sleep_s() {
      local base_s="$1" status_file="$2" now_s="$3"
      local rl_info err_kind throttled core_rem core_rst gql_rem gql_rst reset_at wait_s
      if [ -r "$status_file" ] && command -v jq >/dev/null 2>&1; then
        rl_info="$(jq -r '[
          (.tick_errors._global.error_kind // ""),
          (if .rate_limit.throttled == true then "true" else "false" end),
          (.rate_limit.core_remaining // 0 | tostring),
          (.rate_limit.core_reset_at // 0 | tostring),
          (.rate_limit.graphql_remaining // 0 | tostring),
          (.rate_limit.graphql_reset_at // 0 | tostring)
        ] | join("|")' "$status_file" 2>/dev/null || true)"
        if [ -n "$rl_info" ]; then
          IFS='|' read -r err_kind throttled core_rem core_rst gql_rem gql_rst <<<"$rl_info"
          if [ "$err_kind" = "rate_limited" ]; then
            reset_at=0
            if [ "$core_rem" -lt 150 ] 2>/dev/null && [ "$gql_rem" -lt 150 ] 2>/dev/null; then
              if [ "$core_rst" -ge "$gql_rst" ] 2>/dev/null; then
                reset_at="$core_rst"
              else
                reset_at="$gql_rst"
              fi
            elif [ "$gql_rem" -lt 150 ] 2>/dev/null; then
              reset_at="$gql_rst"
            else
              reset_at="$core_rst"
            fi
            case "$reset_at" in
              '' | *[!0-9]* | 0)
                wait_s=$((base_s * 2))
                [ "$wait_s" -le 600 ] || wait_s=600
                printf '%s\n' "$wait_s"
                return 0
                ;;
              *)
                wait_s=$((reset_at + 5 - now_s))
                [ "$wait_s" -gt 0 ] || wait_s=5
                [ "$wait_s" -le 600 ] || wait_s=600
                printf '%s\n' "$wait_s"
                return 0
                ;;
            esac
          elif [ "$throttled" = "true" ]; then
            printf '%s\n' "$((base_s * 2))"
            return 0
          fi
        fi
      fi
      printf '%s\n' "$base_s"
    }

    while true; do
      run_machine_tick
      if [ -d "${AUTO_REVIEW_LOCK_DIR:-/run/auto-review}" ] && declare -F status_daemon_idle_refresh >/dev/null 2>&1; then
        status_daemon_idle_refresh
      fi
      if declare -F status_interval_s >/dev/null 2>&1; then
        daemon_sleep_s="$(status_interval_s)"
      else
        daemon_sleep_s="${AUTO_REVIEW_INTERVAL:-180}"
      fi
      daemon_sleep_s="$(daemon_compute_sleep_s "$daemon_sleep_s" "${AUTO_REVIEW_STATUS_FILE:-/run/auto-review/status.json}" "$(date +%s)")"
      sleep "$daemon_sleep_s"
    done
    ;;

  setup|adopt|pause|resume|forget|set|set-global|models|registry|list|tick|token|claude-token|agy-token|credential|login|status)
    exec /usr/local/bin/auto-review "$@"
    ;;

  *)
    exec "$@"
    ;;
esac
