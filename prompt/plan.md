A reading plan is required for this pull request: it is over the size the tool
reads without one.

Before the line {{sentinel}}, write the plan between two lines, each alone on
its line:

READING-PLAN-BEGIN
...the plan...
READING-PLAN-END

The plan holds, in a line or two each:

- each acceptance criterion in the briefing and the files that implement it;
- the order of reading: entry points and shared state first;
- which tests get a full read, and why;
- what you will skim or leave unread, and why;
- the estimated size of the close reading, in lines.

Write it before you read, then read by it. The tool posts it under the review,
collapsed, so a reader can set it beside the scope block and see where the two
differ.
