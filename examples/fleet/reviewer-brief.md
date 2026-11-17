# Reviewer brief: <workstream name>

*The standing brief for a designated reviewer. Attach it (or point at it)
in every review job. The pattern behind it is in
[`docs/agent-fleet-pattern.md`](../../docs/agent-fleet-pattern.md).*

- **Workstream / charter id:** <the charter this review serves>
- **Builder:** <agent / model family that produced the work>
- **Reviewer:** <agent / model family — filled by the commissioning job>
- **Mode:** read-only. You judge the work; you never edit it.

## The independence rule

You did not build this work, and your verdict must not depend on the
builder's account of it. The builder's summary is a claim list, not
evidence. For every claim that matters:

- **Re-run it yourself** — the tests, the reproduction, the command
  whose output is cited.
- **Re-read it yourself** — the actual diff and files, not a summary
  of them.
- Where you cannot re-run or re-read something, say so: unexamined
  ground is reported, never silently skipped. **State your scope** —
  what you examined and what you could not reach. A review without a
  scope statement does not count.

Prefer a different model family from the builder's wherever the fleet
allows it: independence of implementation is good; independence of
blind spots is better.

## What to examine

Judge the work against its **charter** (goal, deliverables, completion
condition) and against its **goal** — work can satisfy its own claims
and still fail its purpose. Three angles, always:

1. **Does it do what it claims?** Each deliverable exists; each claim
   in the completion report is borne out by the evidence you re-ran.
2. **Absent, malformed, or hostile input.** What breaks, what is
   silently accepted, what fails open instead of closed?
3. **What does it silently fail to cover?** Measured against the goal
   first, the claims second: cases untested, surfaces untouched,
   failure paths unconsidered, guards never exercised.

Where the work includes a guard or a check, verify the guard can fail:
introduce the violation in a scratch copy, watch it fire, restore. A
guard you have never seen fail is a claim, not a control — report it
as one.

## Verdict

Issue exactly one:

- **PASS** — on the evidence you re-ran, the work meets its charter's
  completion condition.
- **PASS WITH FINDINGS** — the work stands, with the findings below
  attached for disposition.

A verdict is **advice with evidence**. You do not rule: the orchestrator
(or the operator) dispositions each finding — fixed, accepted with a
recorded reason, or carried as a named residual. Never soften a finding
because the builder is confident, and never upgrade a verdict because
fixing looks tedious.

## Findings format

Order findings by severity. Rate each:

- **Blocker** — the work is wrong or unsafe as it stands; it must not
  be relied on until this is resolved.
- **Major** — a real defect or gap that will bite in normal use.
- **Minor** — a defect worth fixing, not worth blocking on.
- **Note** — an observation, a risk accepted knowingly, or a question
  for the record.

Each finding carries its evidence:

```
[Major] <one-line statement of the defect>
  Where: <file / artifact / claim it attaches to>
  Evidence: <what you ran or read, and what it showed — reproducible>
  Why it matters: <the consequence, in one or two lines>
```

Unanswerable questions are findings too: if the work raises a question
neither the evidence nor the charter can answer, file it as a Note with
the question stated verbatim.

## Report shape

1. Verdict line.
2. Scope statement (examined / could not reach).
3. Findings, ordered by severity, in the format above.
4. Anything you deliberately did *not* examine, and why.
