# auto-review

> [!NOTE]
> For the machine-wide container service that consolidates all repositories
> under an independent Docker service with fair round-robin scheduling and
> RAM-only token delivery, see [`tools/auto-review/`](../tools/auto-review/README.md).

One container per machine that reviews open pull requests unattended, for every
project registered in it. the docs argues the shape and supersedes the docs's
per-project launchd and systemd jobs; the docs still argues the state model (a
review's `commit_id` is the only record). This file is how the review itself
works and what its flags do; the container is in `tools/auto-review/`.

```
auto-review setup <owner/repo>   register, clone and check a project
auto-review pause|resume <repo>  stop / restart reviewing it
auto-review claude-token         store the credential the reviewer runs on
auto-review list                 the registered projects
auto-review tick                 one machine tick: every project that is not paused
auto-review tick <path>          one pass over one checkout
```

## Before the first run

One token per repository. Copy it, then:

```
auto-review.sh token <path>
```

It reads the clipboard (or stdin, if you pipe), writes the file at `0600` under
a `0700` directory, and calls `GET /user` to tell you **which account** it
belongs to. A rejected token stores nothing. That last check is the point of
having a command rather than a `pbpaste >` line: an unattended job
authenticating as the wrong account is not something you notice from the
outside.

### Refreshing a harness credential

One command per harness, the same for all of them. The credential is read from
stdin byte for byte (no trimming), its size is checked against the adapter's
minimum, and one real prompt goes through the harness CLI with it. Only then is
it renamed into the token directory at `0600`, so a rejected credential leaves
the old file untouched and no temporary file behind. The value is never an
argument or a log line, and is in the environment only where the harness CLI
reads it from there (`CLAUDE_CODE_OAUTH_TOKEN` for claude).

```bash
<something that prints it> | docker exec -i auto-review auto-review credential set claude
docker exec -it auto-review auto-review login claude
docker exec auto-review auto-review credential list
```

Success prints `ok`. A failure exits non-zero and names the step and the reason:
`step validate` (empty, too short), `step check` (the harness answered 401, 404,
429 or something else) or `step login` (the login command failed). `login` runs
the adapter's login command, takes the credential from its stdout and sends it
down the same path; run it interactively. `<harness>` is the adapter's name
(`claude-code`, `agy`) or an alias it declares (`claude`, `antigravity`).
`credential list` prints `<harness> present age=<N>s check=<ok|401|404|429|fail|none>`
or `<harness> missing check=...`, never a value. `status --json` names a missing
credential together with the `command` to run.

A harness is added by its adapter file alone. Beside `harness_P_execute` and the
rest, the adapter declares `harness_P_aliases`, `harness_P_login`,
`harness_P_check_prompt` and `harness_P_check_token TOKFILE OUT ERR`; the core
classifies the answer with `harness_P_parse`. `AUTO_REVIEW_ADAPTER_DIR` names a
directory holding `harness/<name>.sh`, searched before the built-in adapters.

### Where the tokens live

On Linux the file is `${XDG_RUNTIME_DIR:-/run/user/<uid>}/auto-review/`, a
per-user tmpfs: nothing readable stays on disk, and a reboot empties it. The
uid fallback is there because a logon task under `wsl --exec` has no
`XDG_RUNTIME_DIR`. `auto-review.sh` does not know what puts the tokens back:
that is the receiver of whatever restores them, which runs `token <path>` and
`credential set <harness>` with the token on stdin (the docs). After a reboot a tick that
finds no token logs `no token for <repo> — waiting; run: auto-review.sh token
<path>`, posts nothing and exits 0. The reviewer's sandbox mounts a `tmpfs` over `/run`, so the
directory is not visible inside it either. A file left in `~/.config/auto-review`
is ignored, with no fallback to it. On macOS the tokens stay under `~/.config/auto-review`.

The tokens are in memory only while unlocked, and a process running as the
owner can read them then; that protection is out of scope, see the docs.

Fine-grained, that repository only, `pull_requests: write` and
`contents: read`. Nothing wider: this token drives an unattended process whose
input is text other people wrote.

Add **`actions: read`** and **`commit statuses: read`** for the "postpone while
CI is running" gate. There is no `checks` to add: **Checks is a GitHub App
permission and a fine-grained token cannot hold one** — it is not in the list,
and searching for it returns nothing. That is why the gate is not built on
`gh pr checks`, which reads a GraphQL rollup that needs exactly that
permission and answers `Resource not accessible by personal access token`
without it. The two halves of the rollup are readable separately, with the two
permissions above.

Grant neither and nothing breaks loudly: the tick says in the log that it
cannot read either of them and reviews without waiting. That is what it always
did — the difference is that it says so. Grant one and not the other and it
names the half it cannot read, because that is the half you have to go and fix.

Silence from the gate means both halves answered and nothing is running — and
that includes a repository with no CI at all, which is settled, not broken.

The account the token belongs to **is** the reviewing account — the tick resolves
it, and the default filter (`--assignee @me`) resolves against it. That is how
one machine reviews several projects under several identities without
`gh auth switch`, which is global and would change the account under an
interactive terminal mid-command.

## The credential the reviewer runs on

One per machine, and separate from the GitHub tokens above:

Two steps, and **not** a pipe:

```
claude setup-token
```

```
/Users/user/Projects/pr-auto-review/auto-review.sh claude-token
```

With no arguments it reads the clipboard, so the token goes from that window
into the 0600 file without passing through shell history. It is never put in a
job definition or an `Environment=` line: those are world-readable.

The pipe was what this file said first, and it does not work.
`claude setup-token` is interactive and writes what it has to say — the URL to
open, what to do there — to **stdout**, so the pipe swallows all of it: the
terminal sits empty while the command waits on a browser flow nobody was shown,
and what arrives here is 2689 bytes of instructions with a token somewhere
inside. It is refused on shape now, with that explanation, rather than sent to
the API as a credential and reported back as a token that did not
authenticate — which was true and useless, the token never having been the
problem.

What it accepts is one `sk-ant-…` token and nothing else.

The absolute path is this machine's checkout. Anywhere else, run the script
from wherever it lives.

Without it the reviewer uses your interactive login, and that is a job which
works only while you happen to be using `claude` yourself. The stored access
token is short-lived; refreshing it means writing the new one back, and the
reviewer runs under a profile whose entire content is `deny file-write*` plus
three allowed subpaths. It can read the credential and cannot save a refreshed
one, so every tick dies in about five seconds with `401 OAuth access token has
expired` until something outside the sandbox refreshes it — which, until this
existed, was the owner opening a session by hand.

Measured on 2026-08-17, in this order: two ticks in a row failed that way; the
same `claude -p` run outside the sandbox succeeded; the next tick, seconds
later and otherwise unchanged, reviewed and posted. Nothing about the job
changed between the second and the third.

A `setup-token` token does not expire on that schedule and needs no refresh, so
there is nothing for the sandbox to deny. It is stored `0600` under the same
`0700` directory as the GitHub tokens, and handed to the reviewer in its
environment — deliberately, and deliberately the opposite of `GH_TOKEN`, which
is stripped: the reviewer makes no GitHub calls, so that one would be
capability it has no use for, while this one is what it authenticates with.
`ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are stripped as well, because
either would outrank the token this command checked.

The check is a real run, and it is worth what it costs: `claude` prefers this
variable over the stored login and does **not** fall back to it, so a token
that does not work comes back `is_error: true` with zero output tokens and zero
cost. A good one costs one small prompt. Nothing is stored either way until it
answers.

Then, before installing anything:

```
auto-review.sh tick <path> --dry-run
```

## Flags

| flag            | effect                                                             |
| --------------- | ------------------------------------------------------------------ |
| _(none)_        | only pull requests **assigned to the token's account**             |
| `--all`         | every open pull request                                            |
| `--self-review` | include pull requests the token's account wrote                    |
| `--skip-branch P` | never review a head branch matching the glob `P`, repeatable     |
| `--skip-label P`  | the same, against every label on the pull request                |
| `--skip-bots`   | skip pull requests GitHub says an app opened                       |
| `--skip-if-only G` | when every changed file matches a glob `G`, post a skip instead of a review, repeatable |
| `--model N`     | which model reviews, alias or full name, default `sonnet`          |
| `--small-model N` | the model for a diff under `--small-under` lines (both or neither) |
| `--small-under N` | lines of patch below which `--small-model` reviews               |
| `--max N`       | reviews per tick, default 2                                        |
| `--dry-run`     | print the selection, spend nothing                                 |
| `--review N`    | `tick` only: review PR N now, whatever is already on it            |

`--review` is the way out of a review that should not count. A posted review
carrying the head's `commit_id` **is** the record that the commit is done, so
if the wrong thing gets posted — an error message that reached stdout, a review
written against a briefing that was wrong — nothing ever comes back to it. This
skips every filter: assignment, draft, authorship, the already-reviewed check
and the CI wait, because you have already made that call by typing it.

```
auto-review.sh tick <path> --review 534
```

It is deliberately a `tick <path>` flag only: a standing setting carrying it
would review the same pull request every interval, for ever.

`--skip-branch` is for the pull requests nobody wrote by hand. The generated
release PR is the case it exists for: `changeset-release/master` carries a
version bump and a changelog its tool assembled, there is nothing in it a
reviewer can find, and it is reviewed again every time the branch moves — ten
reviews on one of them here before this existed. The three mute levers in the
last section do not reach it: nothing assigns it, so `--all` picks it up
regardless; it is never a draft; and pausing the project mutes the repository.

```
auto-review.sh tick <path> --all --self-review --skip-branch 'changeset-release/*'
```

Quote the pattern so the shell does not expand it, repeat the flag for more
than one, and remember it is a glob against the **head branch** — `release/*`
matches `release/1.2.0` and not `x/release/1.2.0`. `--review N` ignores it: you
have already made that call by typing the number.

`--skip-label` is the same matching against every label the pull request
carries, and it is the one to reach for first. A label goes on from the pull
request's own page, by whoever is looking at it, and it takes effect on the
next tick; a branch glob is a standing rule about a class of pull request and
only changes when the job is reinstalled. Make a `no-review` label and it is a
mute switch anybody on the repository can throw.

`--skip-bots` covers whatever GitHub calls an app — dependabot, renovate, the
release generator — without having to learn their branch names. It is not a
superset of `--skip-branch`: the generated release PR that prompted all this
was opened under a **person's** account by a workflow, and `is_bot` is false
for it.

Every review reads each changed file by the rule for its kind (upstream issue). The tool sorts the patch into nine kinds (source, tests, generated,
docs, config, migrations, vendored, binary, renamed), lists them in a "files in
the patch" table in the material, and `auto-review/prompt/reading.md` tells the
reviewer how to read each. There is no separate mode for a large pull request,
and nothing is refused for its size. `--max-diff` is gone (upstream issue)
and stops with a pointer to `read_budget`.

A patch over `plan_over` lines (default 1500, generated files not counted) or
`plan_over_files` files (default 40) is planned before it is read
(upstream issue): the reviewer writes a `READING-PLAN-BEGIN` ...
`READING-PLAN-END` block before the sentinel, and the tool posts it as a
collapsed "Reading plan" section after the scope block. Both are machine-wide:
`auto-review set-global plan_over N`. Below the threshold no plan is asked for.
The reviewer timeout (`AUTO_REVIEW_TIMEOUT`, default 900 s) follows the plan
(upstream issue): below the threshold it stays `900` s, and when a plan
is required (`READING_PLAN=1` or over `plan_over` lines) it doubles to at
least `1800` s and scales with patch lines up to four times the base (`3600` s),
so a 10000-line review is not killed at `900` s.

Every review ends with a scope block, a collapsed `<details>` section after the
findings: which files were read closely, by names and assertions, skimmed or not
read, and the task. The tool checks it against the same table of files
(upstream issue): a path the block does not name, in backticks, is added
under `not accounted for` and the summary says how many. A review with no block
gets one that lists every path that way. The review is posted as it is, never
retried or refused for this, and the tick logs it.

`read_budget` (machine-wide, `auto-review set-global read_budget N`, tokens,
default 150000, the size of a 200k window) is a budget, not a ceiling. The tool
estimates the close reads at 19 tokens per line of source, config and migrations
(tests are read by names and assertions and are not counted); past the budget a
plan is required whatever the size and has to name which source is skimmed. The
review always runs and is always posted. `--small-under` looks at the whole patch.

Generated files are taken out of the patch before it is counted and before
the reviewer reads it: `*.snap`, anything under `__snapshots__/`, the
lockfiles `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`,
`pnpm-lock.yaml`, `bun.lockb`, `Cargo.lock`, `poetry.lock`, `uv.lock`,
`Gemfile.lock`, `go.sum` and `composer.lock`, and whatever the repository marks
`linguist-generated=true` in `.gitattributes`. This is not a flag — no project reviews its
lockfile, and the mark is how a repository says the rest, the one GitHub folds
diffs by. A regenerated schema goes on that list with one line in
`.gitattributes`, and until it does it counts as code. The mark is read from the
**base branch**, never the pull request, or a pull request could declare its own
code generated; a marked file is still there in the checkout for the reviewer to
open. What was left out is listed with its line counts in one line of the
posted comment, so what went unread is visible on the pull request; a pull
request with nothing else in it gets `**Skipped — generated files only.**`.
The filter is `strip_generated`, tested by
`scripts/test-auto-review-diff-budget.sh`.

`--skip-if-only G` is for pull requests where a review adds nothing:
regenerated snapshots, a changeset, prose, tests. When **every** path the pull
request touches matches one of the globs, the job posts
`**Skipped — low-risk paths only.**` with the globs that matched, and the head
counts as reviewed: the posted line carries its `commit_id`. A rename is counted on
both ends, so moving a file out of a reviewed tree still gets a review. `*`
crosses `/` (these are shell `case` globs), and a leading `**/` also matches at
the root, so `**/*.md` covers `README.md`. There are no defaults: which trees
are low-risk is the project's call. demo-app runs with
`**/__snapshots__/**`, `.changeset/**`, `**/*.md`, `**/*.test.*`,
`**/*.spec.*` and `tests/**`. Scripts, infrastructure and `.github/workflows/**`
are left off on purpose.

`--small-model N --small-under L` sends a patch shorter than `L` lines to a
cheaper model (demo-app: `haiku`, `100`). The tick logs which model reviewed
each pull request.

Flags are given to `tick <path>`. The machine tick takes the machine's settings
from `set-global` and each project's `all` and `self_review` from the registry
(the docs). Spend is capped by `slots` and `--max`, not by the interval: a
faster tick means reviews come round more often, not fewer.

## Which model reviews

`sonnet`, unless `--model` or `set-global model` says otherwise. The tick's
opening line names it.

It used to be whichever model `~/.claude/settings.json` held, because `claude
-p` with no `--model` takes the interactive setting. Three things were wrong
with that: an unattended job changed model whenever its owner changed theirs,
no log line said which model had written a review, and two jobs on one machine
could not be told apart.

Sonnet by default because the work is bounded — read a staged patch, name what
breaks and on what input — and it runs on every push of every pull request.
The reasons to reach for a larger model are a long unfamiliar codebase and an
open-ended question, and a review of one diff is neither. `--model opus` is
there for a repository where that turns out to be wrong.

The name is passed to `claude --model` untouched: an alias like `sonnet` or
`opus`, or a full name like `claude-sonnet-5`. Nothing here validates it,
because the list of models belongs to the runtime — a name it does not know
fails the run with its own message, in the log.

## What a tick does

```
open PRs → (assigned to me, unless --all) → drop drafts
         → drop --skip-branch / --skip-label matches → drop bots (--skip-bots)
         → drop my own (unless --self-review)
         → drop any reviewed at headRefOid → postpone any with checks running
         → take N → skip if only --skip-if-only paths changed
         → read each file by the rule for its kind
         → review (--small-model under --small-under) → post as a PR review
```

The three skip filters come first because they are the only ones that cost
nothing: the branch, the labels and the author all arrive with the listing,
where the already-reviewed check and the CI gate are two API calls each — spent
every tick, on a pull request the job was going to refuse anyway.

The listing itself asks for 50 and says nothing about what it left out, so a
tick that gets 50 back logs that it did. Drafts are dropped after that count,
not before it, or one draft among fifty would make it forty-nine and the line
would never fire. Past that number there are pull requests this job cannot see,
and from the log that looks exactly like a job with nothing to do.

There is no state file. A review carries the `commit_id` it was written
against; a PR needs one when no review matches its `headRefOid`. Posting is
what records the work, and a new commit moves the head so the PR comes back
round by itself.

Only this job's own reviews are matched: the account's, and carrying the
signature line every posted review ends with. The login alone is not enough,
because the job runs on the owner's token and the owner reviews by hand on the
same login. On 2026-11-04 demo-app#4284 was approved at its head before the
first tick reached it, and the tick logged `reviewed at 8c750c0` for an hour;
dismissing the approval did not help while a dismissed review kept counting.
A dismissed review of this job's own no longer counts as the record: the owner
dismissing it is a request to review again, and it drops out of the list
before the base-merge check as well. The escape hatch for a review nobody
dismissed is `--review N`.

That list of reviews is fetched with `--paginate`, and the reason is the
arithmetic of the paragraph above: the endpoint answers 30 at a time and this
job adds one review per push, so a pull request busy enough to collect 31 walks
its own head's review off the first page. From that tick on it reads as never
reviewed — reviewed again, one more review, for ever, at full price.

## What the reviewer is given

Files. It has `Read`, `Grep` and `Glob` and nothing else — `--tools` sets the
built-in set, and the sandbox below bounds the filesystem underneath it — so
everything a review needs is staged in the review clone before it starts:

| file                       | what is in it                                    |
| -------------------------- | ------------------------------------------------ |
| `.auto-review-pr.md`       | title, description, author, commits, CI result   |
| `.auto-review-diff.patch`  | the full diff as a unified patch                 |
| `.auto-review-history.md`  | the discussion, oldest first                     |
| the working directory      | the branch, checked out at the commit under review |

The three files are written before the review and deleted after it; the
checkout stays. The history is the merge of the formal reviews (the ones this
job wrote included), the inline comments on the diff and the conversation; the
reviewer is pointed at all of it through `--append-system-prompt`.

**If any of it cannot be assembled, the tick postpones the pull request instead
of reviewing it.** A briefing with a hole in it does not produce half a review,
it produces a confident one written against nothing — and posting that marks
the commit reviewed for good, so nothing ever comes back to it.

`.auto-review-history.md` is the only memory the reviewer has. Without it it
starts from nothing on every push, so a finding you have already explained away
comes back on the next commit, and the one after that. Answer a point once — in a review
reply, an inline comment or the thread — and it is closed unless the new diff
makes your answer wrong. **Ignoring one is not answering it**: a finding nobody
replied to comes back as a single line under "Still open", not as the same
argument a second time.

Three things follow. The standing rules go in the **system prompt** and the job
in the **prompt**, and the history after neither — a file of other people's
comments concatenated onto the end of an instruction has a line in it that
reads as the next instruction. The comments are **input to an unattended
agent**, and they are text other people wrote, which is why the tool list has
nothing in it that can write — see below.
And **a review with nothing new to say still posts one line**, naming the
review it is unchanged from — an empty body is how a crashed reviewer looks
from here, and it is retried, so silence would mean re-reviewing the same
commit every tick at full price.

## What a review looks like

The first line is the verdict and nothing else:

```
**No findings.** — adds the citing document's own directory as a last resolution base.
```

```
**2 findings.** — adds the citing document's own directory as a last resolution base.

1. **`scripts/agent/check-docs-paths.ts:855`** — …
   Invariant: …
   Test: …
2. **`scripts/agent/check-docs-paths.ts:626`** — …
   Invariant: …
   Test: …
```

The number is exactly how many numbered points follow, carried-over `Still
open` lines included, because the count answers one question: **is this review
asking me for a change?** That question arrives in a notification, before
anybody opens anything, and it used to take three paragraphs to answer.

Each finding — whether a runtime bug or one of five structural defect classes
created by the diff (an overfitted rule, pattern, or literal misclassifying a
concrete adjacent valid or invalid input; a local copy duplicating or bypassing
a canonical module or helper, or leaving sibling copies out of sync; a `Reader`
doing heuristic parsing or guessing after an upstream `Writer` discarded or
concatenated structure; a generic module embedding a caller-specific branch or
sorting/filtering on an unindexed payload expression; or wall-clock timing
assertions such as `Date.now()`, `performance.now()`, or elapsed duration bounds
used to test algorithmic complexity or logic instead of deterministic operation or
comparison counters) — must be grounded at
a concrete `file:line` with either the concrete failing input or state or the
concrete canonical owner, sibling sites, or `Writer` path in the tree. Each
finding carries two more lines than the objection itself. `Invariant:` is the
rule the code broke, phrased so it can be checked away from the site it was
found at; `Test:` is the test that fails on this commit and passes once it is
fixed, asserted against that rule. They are there because a finding that gives
only a location and a mechanism gets the reported line repaired and the rule
never written down — measured, and argued in the docs. A finding about state
that outlives a call, or a shared rule, table, or `Writer`/`Reader` contract,
also lists every holder, canonical owner, sibling copy, or upstream `Writer` in
the tree, marked reached by this diff or not, since the untouched one is what
the fix misses. Formatting, naming, taste, and speculative "code quality"
notes remain excluded unless the diff makes something wrong. And where a
finding sits in a hunk written to answer an earlier review, it names that
commit and says the fix is what is wrong — otherwise it reads as a defect in the
original code and gets patched the same way twice.

Three first lines are written by the shell rather than the reviewer, and all
exist so that a pull request nothing can be said about is answered once instead
of retried for ever: `**No findings.**` on an empty diff,
`**Skipped — low-risk paths only.**` under `--skip-if-only`,
`**Skipped — generated files only.**` when lockfiles and snapshots are all it
changes. Past the read budget there is no shell-written line: the review runs.

After the findings the review stops. Not in it, by instruction: what the
reviewer read, what it checked and found correct, what it considered and
decided not to raise, adjacent notes marked "not a finding", tradeoffs that are
the author's call. Those paragraphs were most of the length and none of the
value, and a review that has to be mined for the actual objection is one people
stop reading — which costs more than the findings buy.

The verdict is asked for in the prompt, checked after the review comes back,
and **never enforced**: a missing one is a line in the log and the review posts
as it is. Two things say it has to work that way. A gate that depends on the
model remembering a fixed string already threw two real reviews away here (see
below), and there is nothing this shell could put there instead — only the
reviewer knows whether it found anything, so a header written by the tool would
be a verdict nobody reached.

## Why the task is written here, not `/review`

This used to launch the built-in `claude -p "/review <N>"`. It does not any
more, and the reason is worth keeping: **that command's prompt is written for
the session an interactive user has, and this one is deliberately not it.**

On Opus 5 at medium and high effort, `/review` expands to fixed text that says
to run `git diff @{upstream}...HEAD` for the diff and then to "submit at most 15
findings via the `ReportFindings` tool". Neither is conditional on what the
session actually holds, and this reviewer has neither Bash nor `ReportFindings`.
So the model opened its answer by explaining that, and the explanation was
posted as the first paragraph of a review:

> I could not call ReportFindings — this session exposes only Glob/Grep/Read
> (Bash is disabled), so the findings are below in full.

The level table in the 2.1.226 binary maps opus-5 medium and high to one cell
whose text names both unconditionally, so this was every review at those levels,
not a bad day. `AUTO-REVIEW-BEGIN` is exactly the preamble-stripper this needed
and did not catch it: the model has to remember to write the line, and a model
apologising for a missing tool has already lost the thread.

The task now lives in `run_reviewer`, next to the guidance, and names the staged
patch as the scope. What that costs is real: improvements to the built-in review
prompt no longer arrive on their own. The trade is a prompt that matches the
tools and the material this job actually hands over, against a better average
one that is wrong about this session in two specific ways — and both of those
ways get published.

## What counts as a review

Not "whatever the reviewer printed". Twice now, something that was not a review
arrived on the same channel and was posted as one — the subscription's session
limit, and an expired OAuth token — and a posted review carries the head's
`commit_id`, which is this tool's whole record that the commit is done. So the
pull request stopped being reviewable, permanently, over somebody else's error
message.

The first attempt at fixing it read `--output-format json` and required the
envelope to say `is_error: false, subtype: success`. It was not enough: the 401
came back **inside** a successful envelope, as the result. Enumerating the ways
a run can fail is the deny-list mistake in another costume, and this tool has
now made that mistake three times — with command prefixes, with tool names, and
here.

The second attempt asked the reviewer to mark its own output with a fixed line
and posted nothing without it. That is a sound idea and a bad gate: on two live
runs the model opened with a sentence about the reporting tool it did not have,
never wrote the line, and two real seven-minute reviews were thrown away. A
check that depends on the model remembering something is a check that fails on
the day it is needed.

What holds is `usage.output_tokens` from the same envelope. Either the model
generated text or it did not, and a run that never reached the model produces
none — measured, by pointing the runtime at a dead endpoint:

```
{"is_error":true,"subtype":"success","terminal_reason":"api_error",
 "usage":{"output_tokens":0,…},"result":"API Error: Unable t…"}
```

Note `subtype` reads `success` on a run that failed, which is why the word is
not the signal. Zero tokens and no review is posted; the commit stays
unreviewed and the next tick comes back to it.

What the log then says about it is `.result` out of that envelope, with
`api_error_status` in front of it when there is one. It used to be the first
300 characters of the file, which is `is_error`, a duration, a session id and
four token counts that are all zero — the same prefix whatever went wrong. The
sentence that names the remedy sits at the **end**:

```
#22: the reviewer exited 1: 401 Failed to authenticate. API Error: 401 OAuth
     access token has expired. Re-authenticate to continue.
```

That one is worth recognising, because the fix is not in this repository: the
`claude` this job launches uses your own credential, and when it expires every
tick fails in about five seconds until somebody logs in again. Nothing is
posted and nothing is lost — but the log has to say so, or a dead job reads
like a quiet week.

The marker line survives as what it is actually good for: `AUTO-REVIEW-BEGIN`,
when the model writes it, marks where the review starts, and the preamble above
it is dropped rather than posted. When it is absent, the whole answer is the
review.

## Why there is no shell

There used to be one, allowlisted down to `gh pr view`, `gh pr diff`, `git
log`, `git diff` and friends. That is not a barrier. `--allowedTools` matches
the **start** of a command, and `git log` takes `--output=<file>` and
`--format=<anything out of a commit message>`:

```
git log --format=%s --output=/tmp/anything    # exit 0, file written
```

Path arbitrary, contents written by whoever wrote the commit — that is, by the
author of the pull request being reviewed. An unattended job on the host, with
untrusted input, and a write primitive: that is not a review tool, it is a
delivery mechanism. Found by this tool reviewing its own change, 2026-08-11.

The lesson generalises past this repository. **A list of allowed command
prefixes bounds intent, not capability.** If the bound has to hold, remove the
tool or move the process behind a real perimeter; do not enumerate flags.

Replacing it with a **tool** allowlist did not work either, and for a duller
reason than the one that was written here first: `--allowedTools Read Grep
Glob` was the wrong flag. It lists the tools that run **without a prompt**. It
never removed one, in any permission mode, so the deny list beside it was the
only thing biting — and a deny list is an enumeration. It was missing
`Monitor`, which runs an arbitrary shell script. The reviewer used it during a
review to prove the point.

`defaultMode: "auto"` took the blame for that and did not deserve it. It does
not approve everything undenied: it sends anything outside the working
directory to a second classifier and drops blanket `Bash(*)`-shaped allow
rules when it starts. It was the tighter setting, not the looser one.

The flag that removes tools is `--tools`, and beside it `--strict-mcp-config`,
because `--tools` bounds the built-in set and nothing else — without it the
reviewer keeps every MCP server configured on the machine:

```
claude -p "<the review task>" --tools "Read,Grep,Glob" \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}'
```

Checked by asking a session to name its own tools: with `--tools` alone it
listed the three plus nineteen `mcp__…` ones; with both flags, three. There is
deliberately no deny list any more — an enumeration reads as coverage and is
not.

The perimeter under all of it is a sandbox profile, `reviewer.sb`:

```
sandbox-exec -f reviewer.sb -D CLONE=… -D SESSIONS=… … claude -p "<the review task>"
```

On Linux the same perimeter is assembled with `bwrap` instead; how, and where
it is stricter, is under [On Linux](#the-perimeter).

Nothing may be written outside the review clone, the session directory and the
temporary directories; the job's tokens, `~/.ssh`, `~/.aws` and `~/.config/gh`
may not be read at all. Verified against the original exploit and the paths
below, each one run through `sandbox-exec` and its result read off the exit
status, 2026-08-11:

```
git log --format=%s --output=$HOME/pwn.txt   blocked
~/.zshenv, ~/Library/LaunchAgents/…          blocked
~/.claude/settings.json                      blocked
the job's token, ~/.config/gh/hosts.yml      blocked
~/.ssh/known_hosts, ~/.aws/credentials       blocked
~/.ssh through /System/Volumes/Data/…        blocked
the clone's .git/config, .git/hooks/…        blocked
the clone's .claude/…, .mcp.json, CLAUDE.md  blocked
a symlink named .claude in the clone         cannot be created
inside the clone, anywhere else              allowed
$TMPDIR/…, ~/.claude/projects/…              allowed
GH_TOKEN in the reviewer's environment       absent
```

Four of those lines are there because a version of this was weaker than it
read, each time in the same way — the rule was in the file and matched nothing.

`.git` sits **inside** the clone, and the shell runs `git fetch` and
`gh pr checkout` in that directory on the next tick, outside the sandbox — a
`remote.origin.url` of `ext::sh -c …` or a `post-checkout` hook would be code
execution with the perimeter no longer around it.

`.claude` sits inside the clone too, and `claude` runs with the clone as its
working directory: a hook in `.claude/settings.json` is a command line, run for
an event as ordinary as a session starting — the `Monitor` hole again, planted
rather than called, and it is whoever opens that directory by hand who runs it
with nothing around it. `.mcp.json` is a list of servers to launch, which is
code by another name, and `CLAUDE.md` is read as instructions by every `claude`
started there. All four are denied at the root of the clone, which is
defence in depth and not the bound: the profile matches literal paths, so it
says nothing about `src/CLAUDE.md`, about `AGENTS.md`, or about the
differently-cased `Claude.md` that this filesystem resolves to the same file.
What covers those is the sweep after every checkout, above — the denies are
there for the narrower job of stopping a reviewer that somehow had a write tool
from planting one at the root, and for making a `.claude` symlink useless
rather than a way through.

`~/.ssh`, `~/.aws` and `~/.config/gh` were denied by appending to a `HOMEDIR`
parameter. `sandbox-exec` compares the path the kernel has **already resolved**
against the strings in the profile, as strings: pass `HOMEDIR` as
`/Users/user/`, or `/Users//me`, or `/Users/user/../me`, or a symlink to it, or in
its `/System/Volumes/Data/Users/user` firmlink spelling, and all three denies
match nothing whatsoever and the reviewer reads the keys. Every one of those
five spellings was confirmed to do it. The paths are resolved in the shell now
and passed one parameter each — never derived in the profile by appending to
another, because `~/.config` is exactly the directory a dotfile manager turns
into a symlink — and a path that will not resolve canonically stops the tick.
Then, because "resolved" is itself a thing that can be got wrong, the tick puts
the profile in front of those directories and tries to read them before it
hands the reviewer a pull request. Anything still readable is a failed tick and
a log line naming the path, not a review. It costs about 13ms.

And `load_token` exports `GH_TOKEN`, which a child inherits no matter what the
profile says about files: denying reads of the token directory while handing
the token over in the environment is decoration, not a boundary. The reviewer
is launched with `env -u GH_TOKEN`.

The tools that reach the outside world without writing a file locally —
`Artifact`, `CronCreate`, `RemoteTrigger`, `SendMessage`, `PushNotification` —
are the class a file sandbox cannot see at all. They used to be handled by
naming them in a deny list, which is why the list had to be complete and never
was. `--tools "Read,Grep,Glob"` covers them by construction instead: they are
not in the session, named or not. That is the difference between the two shapes
of rule, and it is the whole reason for the change.

**What it does not buy.** Reads and network stay open, because `claude` needs
its own credentials and the API. The perimeter stops the reviewer leaving
anything behind on the machine and stops it reading this job's GitHub tokens.
It does not stop it reading whatever else your user can read. A container
would not have helped here: what would have to go inside it is `claude`'s own
credential, not the repository token — the shell keeps that, outside.

A branch that **ships** `.claude/`, `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`
or `.mcp.json` gets it written into the clone by `gh pr checkout`, outside the
sandbox — the deny stops the reviewer leaving one behind, not the pull request
bringing one. So the tick deletes them after every checkout, **anywhere in the
tree and not only at the root**: the runtime reads a `CLAUDE.md` out of any
directory it opens a file in, so `src/CLAUDE.md` beside a file the reviewer
will plausibly read is the same injection one directory down. This repository
ships `claude/CLAUDE.md` today, so it is not a hypothetical shape.

The three `.auto-review-*` names go with them, for a different reason: they are
written with `>`, which follows a symlink, so a branch shipping
`.auto-review-history.md` as a link to `~/.zshenv` would have had this shell
truncate that file and fill it with comment bodies the same author wrote. `rm`
takes the link and never the target, so the write afterwards makes a file.

Deleting rather than refusing, because `ln -s AGENTS.md CLAUDE.md` is an
ordinary layout and refusing it would mean that repository is never reviewed at
all, on every tick, with the API calls spent each time. The clone is
disposable; the next checkout brings the tree back, and the reviewer sees those
files' contents in the diff regardless.

One it does not buy: `~/.claude/projects` is writable, all of it, not only this
job's own transcript — a session file another project would resume is a place
to leave text for a `claude` that is not behind any of this.

If a tick cannot read part of the discussion it says so in the log, per source.
An empty history file silently turns the whole thing off, and that must not
look like a healthy tick.

Five ways to mute a PR, in increasing order of bluntness: label it with
whatever `--skip-label` names, unassign yourself (does nothing under `--all`),
put it back into draft, `--skip-branch` its head branch, or `pause` the project.

## On Linux

The same script, the same commands and flags; `uname -s` picks the sandbox
and the clipboard, and nothing else differs.
Written for and measured on WSL2 Ubuntu 24.04 (the docs), and nothing in it is
WSL-only except what is said to be.

### Installing

```
sudo apt install bubblewrap jq gh git
```

plus `claude` on `PATH` (`~/.local/bin` is searched). No Node: the native
`claude` binary is the whole runtime.

`token` and `claude-token` read the clipboard when nothing is piped in: under
WSL that is Windows' clipboard, through `powershell.exe Get-Clipboard`, since
that is where a token copied out of a browser lands. On a Linux without
`powershell.exe` there is no clipboard reader and they say so — pipe the token
in.

### The perimeter

`reviewer.sb` is not read. The reviewer runs under `bwrap` (bubblewrap), which
has no rules, only a filesystem it assembles — so the profile's shape is
built the other way round. The root goes in read-only, which is
`deny file-write*`; then a writable view is mounted back over the session
directory and `/dev`, and each read deny is an empty `tmpfs` mounted over the
directory with its mode set to `0000`, so that listing it fails as well. The
probe works unchanged: it reads a file under each denied directory through the
same command the reviewer is started with, and still tells exit 9, a leak, from
`bwrap` refusing to start.

**The clone.** The profile allows the clone and then denies `.git`, `.claude`,
`.mcp.json`, `CLAUDE.md` and `CLAUDE.local.md` inside it, existing or not.
bwrap can only mount over something that exists, and four of those five are
normally absent when the reviewer starts — the sweep after the checkout deleted
them. Mounting a read-only placeholder there means bwrap first creating an
empty `CLAUDE.md` in the real clone, through the writable mount: the perimeter
leaving behind the file it exists to keep out, and the next `gh pr checkout` of
a branch that ships one tripping over an untracked file in the way.

So the clone's root is mounted **read-only**, and each entry already at the
root is mounted back writable over itself — every one except those five names,
and except symlinks, which bwrap would follow and so make their target
writable. The list is made at each launch, from what the checkout just put
there. Nothing is created: a guarded name that is absent cannot be created,
because that is a write to the read-only root, and one that is present stays
read-only. **The cost**: the reviewer cannot create, delete or rename anything
at the root of the clone, only change what is there and work inside its
directories. That is stricter than the profile, and it costs nothing today —
the reviewer's tools are `Read`, `Grep` and `Glob`.

**Stricter elsewhere, each for a socket.** A read-only mount stops writes, not
`connect()`, and a socket is a way out as good as a writable file. So:

- `/tmp` and `$TMPDIR` are a private `tmpfs`, not the host's. macOS hands out a
  per-user `$TMPDIR`; here it is usually unset and `/tmp` holds tmux's socket
  (a shell outside the sandbox), ssh-agent's and the X server's. Still
  writable, and nothing written there survives the review.
- `/run` is hidden: the docker socket, the user manager's bus (`systemd-run
  --user` is another shell outside), and under WSL the interop socket that
  starts Windows programs. The resolver's file is mounted back if
  `/etc/resolv.conf` points in there.
- `/mnt` and every `drvfs` mount are hidden. Under WSL that is the Windows side
  of the machine — writable through interop, and holding a second `~/.ssh`,
  `~/.aws` and `gh` login that the four denies cover only on the Linux side.
  All of `/mnt` rather than `/mnt/c`, because Docker Desktop mounts `C:\` a
  second time under `/mnt/wsl`. On this machine `~/.aws` is itself a link to
  `/mnt/c/Users/…/.aws`.
- A `/proc` of its own (`--unshare-pid`): the host's lists every process's
  command line, and lets the reviewer signal any of the owner's — measured, a
  `kill -STOP` from inside stopped a `sleep` outside.

Verified on 2026-10-05 with the perimeter `build_perimeter` builds and the
command `run_reviewer` launches, each line one attempt from inside, read off its
exit status:

```
the job's token, list of the token dir       denied
~/.ssh/…, ~/.config/gh/hosts.yml             denied
~/.aws (a link to /mnt/c), /mnt/c, Windows ~/.ssh   denied
/mnt/wsl (Docker Desktop's second C:)        denied
/run/docker.sock, /run/user/…/bus            absent
cmd.exe through interop                      denied
git log --format=%s --output=$HOME/pwn.txt   blocked
$HOME/pwn, ~/.bashrc, ~/.claude/settings.json  blocked
the clone's .git/config, .git/hooks/…        blocked
the clone's CLAUDE.md, CLAUDE.local.md, .mcp.json   cannot be created
a directory or symlink named .claude         cannot be created
a new file at the clone's root               cannot be created (the cost)
an existing file at the root, a file in src/ allowed
~/.claude/projects/…, /tmp/…, /dev/null      allowed (/tmp private)
a host pid in /proc                          not visible
DNS and the API                              reachable
the clone's root after the run               unchanged — no mountpoints
claude -p under it, made-up token            starts, reaches the API, 401
```

What it does not buy is what the profile does not buy, plus two. A denied
directory that does not exist when the review starts is not mounted over —
bwrap would create the mountpoint on the host — so a `~/.aws` some other process
creates during a review is readable to that review; the profile, matching paths
rather than directories, has no such window. And abstract-namespace sockets are
reachable, because the network is shared — an X server listening on one is the
case that matters; closing that means a network namespace, and with it the API.

## Reading it

```
docker compose -f tools/auto-review/docker-compose.yml logs -f
```

Every tick logs a line, including the ones that find nothing — a log that goes
quiet means the daemon is dead, not that the repositories are calm. The log is
the container's, rotated by Docker; the tick keeps no log file of its own.
`status.json` in `/run/auto-review` lists the reviews running now under
`active`.

## When it misbehaves

**Every review fails in about five seconds.** Read the reason off the log line;
if it is `401 … token has expired`, the job is on the interactive login and
that login has expired. `claude-token` is the fix, and the tick's opening line
says which of the two it is using.

**Nothing is ever reviewed.** Most likely nothing is assigned to you. Check
with `gh pr list --assignee @me`; the default filter is deliberate, and `--all`
is the escape hatch.

**A PR is reviewed for ever.** Something is posting issue comments instead of
reviews. Only a review carries `commit_id`.

**Two reviews for one commit.** Two machine ticks overlapped and the daemon
lock did not hold. It is `daemon.lock` in `/run/auto-review`, outside the
reviewer's sandbox on purpose, so a planted lock cannot silence the daemon.
`tick <path>` takes no lock of its own and can overlap a machine tick: use it
for `--dry-run` and `--review N`, not as a second scheduler.

**"refusing to run in what may be a working checkout".** There is a directory
at `~/.cache/auto-review/<owner>-<repo>` whose `origin` is not this repository.
The record is the file `~/.cache/auto-review/clones/<owner>-<repo>`; delete the
directory and let the next tick re-clone rather than writing the record by
hand, because the guard exists so the reviewer is never handed somebody's
uncommitted work as part of a pull request.

That record lives **outside** the clone, for the same reason the daemon lock
does. It used to be a `.auto-review-clone` file inside the clone, which is
exactly the directory the reviewer is allowed to write to — deleting it made
every later tick refuse to run, so the code under review could switch off its
own reviewer. A clone from before the move is adopted on the next tick **by its
path and its `origin`**, neither of which a branch can touch; nothing has to be
re-cloned, and the old file is deleted rather than consulted.

Which means the record cannot be removed to disown a clone — the next tick
would write it back. To refuse one, `touch` the same path with `.disowned` on
the end:

```
touch ~/.cache/auto-review/clones/<owner>-<repo>.disowned
```

The tick then stops with that filename in the log until you delete it.
