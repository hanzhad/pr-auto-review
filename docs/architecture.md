# Architecture & Sandbox Perimeter

## Two-UID Isolation (`10001` vs `10002`)

The container starts as `uid 0` only long enough for `entrypoint.sh` to drop privileges, then runs the daemon as `reviewer` (`uid 10001`):

- **`uid 10001` (Daemon):** owns `/run/auto-review` (`tmpfs`, mode `0700`) containing GitHub tokens and harness credentials, maintains clean clones in `/var/lib/auto-review/clones`, and posts GitHub PR reviews.
- **`uid 10002` (Sandbox):** invoked per review inside `bwrap` (Linux/Docker) or `sandbox-exec` (`reviewer.sb` on macOS). It has no read access to `/run/auto-review`, no GitHub token in its environment, and `--tools "Read,Grep,Glob"` with no shell execution tool.

## Why No Shell Tool

A malicious PR could embed prompt-injection payloads in code or comments. By disabling shell tools (`Bash`) and running under a read-only filesystem sandbox (`uid 10002`), the reviewer can inspect staged repository files (`prompt/reading.md`, `prompt/task.md`) without executing repository scripts or exfiltrating credentials.

## Commit-Pinned State Model

`pr-auto-review` stores no external review database. A GitHub PR review's `commit_id` (plus an embedded HTML comment marker in the review body) is the source of truth:

- If the latest review matches `headRefOid`, the PR is skipped on subsequent ticks.
- If a new commit is pushed (`commit_id != headRefOid`), the PR is queued for a new review.
- Oversized diffs exceeding the configured budget are marked `**Not reviewed.**` so [`pr-gate`](https://github.com/hanzhad/pr-gate) escalates them to `5|NEEDS_OWNER`.

## Harness Adapters

`adapters/code/` and `adapters/task/` abstract CLI harnesses (`claude-code`, `agy`) behind a uniform `credential set` / `login` / `review` contract.
