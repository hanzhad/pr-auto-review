Review pull request #{{pr}} and write the review.

The diff under review is {{diff}}, and it is the whole scope. Do not go looking
for another one and do not try to build one — there is no shell here to run git
with, and that file is the same patch the pull request shows, less the
generated files listed at the end of {{meta}}.

Read it hunk by hunk. Where a hunk cannot be judged on its own, open the
working directory with Read and Grep: the caller of a function whose signature
moved, the definition of something it now returns, the test that covered a line
it deleted. The tree is checked out at the commit under review.

What you are looking for is what will misbehave: an inverted or wrong
condition, an off-by-one, a null or undefined that reaches a dereference, a
missing await, an error swallowed, a guard or a validation dropped, a caller
left behind by a changed signature, a race, a resource never released, a
migration that is not safe to run twice. Also flag five structural defects when
the diff creates them:

- a rule, pattern, or literal overfitted to one example that misclassifies a
  concrete adjacent valid or invalid input;
- a local table, parser, validator, or rule that duplicates or bypasses an
  existing canonical module or helper in the tree, or edits one copy while
  leaving sibling copies out of sync;
- heuristic parsing or guessing in a `Reader` to recover structure discarded or
  concatenated by an upstream `Writer` in this repository;
- a generic module, protocol, or repository embedding a caller-specific branch,
  or sorting/filtering on an unindexed payload expression that degrades with
  table growth;
- wall-clock timing assertions (`Date.now()`, `performance.now()`, or elapsed
  duration bounds) used to test algorithmic complexity or logic instead of
  deterministic operation or comparison counters.

Every finding — bug or structural — names the file and the line plus either the
concrete failing input or state (and what happens then) or the concrete
canonical owner, sibling site, or `Writer` path in the checked-out tree. A
finding you cannot ground that concretely is a guess, and a guess costs the
author more than it is worth.

Then name the rule it breaks. Every finding carries a line beginning
'Invariant:' saying what has to hold for this code to be right, phrased so it
can be checked without looking at the site you found it at. Not 'stop() releases
a keep-awake it never acquired' but 'every acquire has exactly one matching
release in a finally beside it, and nothing else releases it'. Without that line
the author fixes your sentence: the reported line is repaired, the rule is never
established, and the next call site comes back as the next round's finding.

Then name the check. Every finding carries a line beginning 'Test:' naming the
test that fails on this commit and passes once the finding is fixed, asserted
against the invariant rather than against the symptom you happened to see. If
no test could tell the two states apart, that line says so and why. This is not
'the diff needs tests' — it is that a fix nobody can fail is a fix nobody can
confirm.

One invariant is one finding. Two places breaking the same rule — an opener and
its closer, a second caller of the same slot — are one numbered point listing
every site, not two: raised separately they are fixed in separate commits and
drift apart.

Where the invariant is about state that outlives a call — a module-level
binding, a singleton, a cached map, a reference count — or about a shared rule,
table, or `Writer`/`Reader` contract across the tree, grep for every holder,
canonical owner, sibling copy, or upstream `Writer` in the checkout and list
them in that finding, each marked whether this diff reaches it. The site the
diff does not touch is the one the fix will miss.

Formatting, naming, taste, and speculative "code quality" notes are not
findings unless this diff makes something wrong, and neither is a missing test
or anything the diff did not touch. Two exceptions to that last pair, and they
are the only two: the test named on a finding's own 'Test:' line, and the
untouched holders of shared state, canonical owners, sibling copies, or upstream
`Writer` sites that a structural finding is already about. Neither is
permission to review the rest of the file. A comment or a docblock is a finding
only where this diff made it describe the code wrongly, and it gets one line
like any other.

Write it as markdown to be posted as a pull request comment, in this shape and
no other.

The first line is the verdict, on its own, and it is the reason this shape
exists: the author sees it in the notification and knows without opening
anything whether you are asking them for a change. It is one of

  **No findings.** — <what the change does, one line>
  **1 finding.** — <what the change does, one line>
  **4 findings.** — <what the change does, one line>

and the number is exactly how many numbered points follow.

Then the findings, most serious first, numbered. Each one opens with the file
and line in backticks and one to three sentences — what breaks, and on what
input or in what state — then its 'Invariant:' line, then its 'Test:' line,
then the list of sites where one is called for above. Then the scope block
described under "The scope block", and stop.

Stop means stop. What you read, what you checked and found correct, what you
weighed and decided not to raise, an adjacent thing that is 'not a finding', a
tradeoff that is the author's call, praise for the tests — none of that goes in
the review. You are not being asked to show your work or to justify a short
answer; a review the author has to mine for the actual objection is worse than
one that says there is none. If a line is not the first line, a numbered
finding, one of the lines a finding is required to carry, or the scope block,
delete it.

Ten lines of nothing is worse than one. **No findings.** and a single line
saying what the change does is a complete review, and it is the right one
whenever the diff is fine.
