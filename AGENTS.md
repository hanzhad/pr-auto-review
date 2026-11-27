# Agent Rules (hanzhad/pr-auto-review)

- **Workflow:** Work on a feature branch, open a pull request with full context, and ensure CI (`test`, `docker-isolation`, and `scan`) passes before merging.
- **Commits:** Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `test:`).
- **Public safety:** Every change must pass `python3 scripts/scan.py --tree .` and `python3 scripts/scan.py --history`. Never commit tokens, credentials, personal emails, private repo references, or host-specific home paths.
- **Dependencies:** Keep runtime dependencies minimal (Bash, Docker, `jq`, `curl`, Python 3 stdlib for tooling) and preserve the two-UID sandbox boundary.
