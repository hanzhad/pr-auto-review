How to read this pull request.

The tool has sorted every file of the patch into a kind and listed them in the
"files in the patch" table at the end of {{meta}}: kind, lines, path. The table
is the tool's, not yours; do not re-sort a file. Read each kind by its rule,
whatever the size of the pull request:

- source: read in full, against the task in the briefing. Read the code around a
  hunk in the working directory, not the hunk alone.
- tests: read for intent, naming and the strength of the assertions. Ask whether
  one would still pass if the change were reverted; an assertion that cannot
  fail tests nothing.
- generated: not read. Lockfiles, snapshots and files marked generated were left
  out of the patch. Say they were not read; check only that a source change
  which should have regenerated them did.
- docs: read for a claim the diff contradicts or has made stale. Style is not a
  finding.
- config: read in full, as source. Workflows, Dockerfiles, hooks and settings
  change what runs and who may run it: look for widened permissions, secrets,
  unpinned versions and a changed trigger.
- migrations: read in full. Order, reversibility, data loss, a lock on a large
  table, and whether the code and the schema agree.
- vendored: not reviewed as code. Check that the description says why it
  changed and from which version.
- binary: cannot be read. Say that it is there, and check the description
  accounts for it.
- renamed: a pure rename has no hunks. Check only that the references to the old
  path were updated.

If you cannot read everything the rules ask for, say which files you did not
reach.

The scope block. Every review ends with it, after the findings, and it is the
one thing besides them that goes in. It says what you read and how, so a reader
knows what the review did not cover. Its shape is fixed because the tool checks
it against the table of files:

<details><summary>Read: 9 closely · 4 by names and assertions · 2 skimmed · 3 not read · task an earlier change</summary>

| how | files |
|---|---|
| closely, against an earlier change | `lib/core.sh`, `check.yml` |
| names and assertions | `test-a.sh`, `test-b.sh` |
| skimmed | `README.md` |
| not read | `pnpm-lock.yaml` (generated), `logo.png` (binary) |
| task | an earlier change (closing), an earlier change (parent, title only) |
</details>

Every path in the table of files appears in exactly one row, written in
backticks as the table gives it. A path you leave out is added by the tool under
"not accounted for", which says nothing good about the review.