# Operations Runbook

## 1. Repository & Harness Credentials

All credentials are delivered over `stdin` and stored in `tmpfs` (`/run/auto-review`, mode `0600` under `0700`):

```sh
# Store a GitHub token for a repository
printf '%s' "$GH_TOKEN" | bin/auto-review unlock-token --name acme-webapp

# Refresh a harness credential (validates size + runs a live probe before replacing)
printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | bin/auto-review credential set claude
bin/auto-review credential list
```

For unattended reboot recovery, pipe secrets from [`pin-vault`](https://github.com/hanzhad/pin-vault) into `bin/auto-review unlock-token`.

## 2. Managing Repositories

```sh
bin/auto-review setup owner/repo     # register, clone, and verify token access
bin/auto-review list                 # list registered repositories
bin/auto-review pause owner/repo     # pause reviews for a repository
bin/auto-review resume owner/repo    # resume reviews
bin/auto-review tick                 # run one pass across all active repositories
```

See `projects.example.json` for the registry structure (`interval` at top level, `paused` per repository).

## 3. Reading Logs & Status

```sh
bin/auto-review logs -f
bin/auto-review status --json
```

Every tick logs a line, including idle ticks. `/run/auto-review/status.json` exposes active reviews for dashboards such as [`ops-console`](https://github.com/hanzhad/ops-console).

## 4. Troubleshooting

- **`401 token has expired`:** refresh the harness credential via `bin/auto-review credential set claude` or `bin/auto-review login claude`.
- **No PRs are reviewed:** by default only PRs assigned to `@me` are reviewed; enable `all: true` in the registry or pass `--all`.
- **`refusing to run in what may be a working checkout`:** a clone directory's `origin` does not match the registered repository; remove the stale clone directory or touch `<clone>.disowned` to opt out intentionally.
- **Diff budget tests:** run `bash tests/test-auto-review-diff-budget.sh` to verify `read_budget` and `skip-if-only` behavior locally.
