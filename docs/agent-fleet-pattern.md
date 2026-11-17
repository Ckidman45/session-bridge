# Running a small agent fleet

SessionBridge moves jobs. It does not organize the work. This guide is the
organizational pattern that sits on top of the bridge: how one person runs
a small fleet of AI coding agents — an orchestrator, some builders, and
independent reviewers — so that the work the fleet produces can be
*believed*, not just read.

The pattern is distilled from a production multi-agent workflow that runs
daily. It is a starter pattern, not a complete management system: the
roles, the charter discipline, and the quality loops below are the parts
that proved load-bearing. Scale them to your operation; do not skip them
because your fleet is small — a fleet of two needs them most, because
there is no crowd to catch a mistake.

Copyable starters for everything described here live in
[`examples/fleet/`](../examples/fleet/).

## Why a fleet at all — and what it costs

One agent in one session does one thing at a time, in one context, with
one model family's blind spots. A fleet buys you three things:

- **Parallelism.** Independent workstreams run at once instead of queuing
  behind each other.
- **Separation of duties.** The agent that writes the code is never the
  agent that judges it. This is the single highest-value property of the
  pattern, and it costs nothing but discipline.
- **Cross-family review.** A reviewer from a *different* model family
  catches failure modes the builder's family is systematically blind to —
  the same reason a second human reviewer from a different team finds
  different bugs.

Be honest about the costs before you start:

- **Review becomes the bottleneck.** Builders generate work faster than
  anyone — human or agent — can verify it. Your fleet's real throughput
  is its *review* throughput. Size the fleet to the review capacity, not
  the building capacity.
- **Token spend multiplies.** Every lane, every reviewer, every loop
  round is a full agent run. A fleet that reviews everything twice costs
  roughly three times a solo agent, not twice.
- **The human remains the only decision-maker.** Agents execute and
  advise. Judgment — direction, priorities, anything irreversible —
  stays with you. A fleet that starts deciding for you has not become
  autonomous; it has become unaudited.
- **Coordination is real work.** Charters, queues, and records are
  overhead you pay so that parallel work does not collide. If you skip
  them, you get the costs of a fleet with none of the control.

## The roles

Three roles. One agent may hold a role for one workstream and a different
role for another, but the hats are never confused *within* a piece of
work — in particular, nobody reviews their own build.

| Role | Owns | Never |
|---|---|---|
| **Orchestrator** | The plan: charters, sequencing, integration, rulings within the authority you delegated | Doing the build work itself when a builder lane exists |
| **Builder** | Executing one chartered workstream, start to completion condition | Widening its own charter; judging its own work |
| **Reviewer** | Independent verdicts on work it did not build, from re-run evidence | Building; ruling (verdicts are advice, not decisions) |

**The orchestrator** holds the whole picture: what workstreams exist,
what each is chartered to do, what state each is in, and what is waiting
on a decision. It commissions builders, assigns reviewers, integrates
results, and surfaces decisions to you — one at a time, with a
recommendation. In a small setup the orchestrator is often the agent you
talk to directly; the builders and reviewers are sessions it commissions,
frequently on other machines or other model families, reached through
the bridge.

**Builders** execute. Each builder works inside exactly one charter (see
below) and stops at its edges. A builder that hits a question outside its
charter records the question and escalates — it does not improvise an
answer and keep going.

**Reviewers** verify. A reviewer's defining property is *independence*:
it did not build the work, and ideally it is a different model family
from the builder. The reviewer does not trust the builder's summary — it
re-runs the evidence itself (the tests, the diff, the reproduction) and
issues a verdict:

- **PASS** — the work does what its charter claims, on the evidence the
  reviewer re-ran.
- **PASS WITH FINDINGS** — the work stands, with findings attached, each
  rated by severity and each carrying its evidence.

A verdict is *advice with evidence*, never a decision. The orchestrator —
or you — rules on findings: fix now, accept and record, or carry as a
known residual. What a reviewer must never do is soften a finding
because the builder is confident, and what an orchestrator must never do
is report work as "verified" on the builder's say-so alone.

## Charters: every unit of work is written down

Every delegated unit of work gets a **charter** before it starts. A
charter is a short written commission that names:

- **Goal** — the outcome, in one measurable sentence.
- **Scope and boundaries** — what is in, and just as explicitly what is
  out: files or systems it may not touch, actions it may never take.
- **Deliverables** — the artifacts that must exist at the end (code,
  a report, a diff plus test output — evidence, not narration).
- **Completion condition** — the checkable state that means *done*.
  Stated up front, so "done" is a verification, not a vibe.
- **Stop and escalation conditions** — what makes the builder halt and
  ask: ambiguity in the charter, a finding outside scope, a blocked
  dependency, a decision only the human can make.
- **Reviewer assignment** — who reviews this work when it lands. Named
  in the charter, before the work starts, so review is never an
  afterthought bolted onto finished work.

Two structural rules make charters work at fleet scale:

- **One writer per workstream.** Two builders editing the same surface
  is a merge conflict with extra steps. Parallel work gets parallel
  *lanes* — separate charters, separate scopes, one owner each.
- **A charter's scope is a boundary, not a suggestion.** Follow-on
  decisions *inside* the charter's scope are the builder's to make.
  Anything outside it — new direction, a wider change, anything
  irreversible — goes back to the orchestrator, and if it is a judgment
  call, to you.

A fill-in charter template is at
[`examples/fleet/team-charter.md`](../examples/fleet/team-charter.md).

## The quality loops

Charters keep work aimed. Loops keep it honest. Two loops, used as the
**closing step of every build** — after the build is done and verified
working, not instead of building it well.

### The Audit Loop

A fresh-eyes audit of finished work, by a reviewer who did not build it:

1. **Audit.** The reviewer acts as a harsh critic whose job is to break
   the implementation, from three angles: (a) does it do what it
   claims? (b) what happens on absent, malformed, or hostile input?
   (c) what does it silently fail to cover — measured against the
   work's *goal*, not only its claims. The audit states its scope
   explicitly: what was examined and what could not be reached. An
   audit that does not state its scope does not count.
2. **Fix.** Everything found gets fixed.
3. **Test.** Each fix is proven by a test. Where a fix is a guard or a
   check, the guard must be *seen to fail*: introduce the violation,
   watch the test go red, restore. A guard you have never seen fail is
   a claim, not a control.
4. **Repeat with new eyes** — each round audits the state the previous
   round's fixes produced, and a new round goes to a different reviewer
   than the last. Stop at the first fully clean audit; cap the rounds
   (three is a sane default) and carry whatever remains as named
   residual items rather than grinding forever. Non-convergence is a
   finding, not a reason to keep looping.

Never run audit rounds in parallel: parallel rounds all examine the
same state, so none of them can catch a defect the fixes introduced —
which is precisely what the later rounds exist to find.

### The Improvement Loop

The Audit Loop asks "is it correct?" The Improvement Loop asks "is it
*good*?" — and it is the standard closing step for anything you build:

1. **Audit** — the Audit Loop's first step, same three angles, scope
   stated.
2. **Critique.** Produce at least a dozen critiques *and questions*
   aimed at the implementation. Questions you cannot answer count:
   an unanswerable question about the work is itself a finding.
3. **Design** improvements addressing those points.
4. **Implement** all of them.
5. **Test** that everything held — including proving every guard can
   fail.
6. **Gate.** Run the full Audit Loop as the final step. The build is
   not closed until the gate passes (or hits its round cap with its
   residuals named and carried).

The loop is a quality measure layered on top of building well the first
time. It is never a license to ship a sloppy first version and let the
loop catch it.

### Who rules on a verdict

The reviewer issues the verdict; the orchestrator or the human rules on
it. Every finding gets a recorded disposition — fixed, accepted with a
reason, or carried as a named residual with an owner. A verdict that is
quietly ignored converts the whole review system into decoration, so
overruling a reviewer is allowed but never silent: the overruling and
its reasons are written down where the verdict lives.

## Decision discipline

A fleet generates questions faster than a human can answer them, so the
discipline around decisions matters as much as the discipline around
code:

- **Agents surface decisions; they do not make them.** Anything that is
  a judgment call — direction, scope change, money, anything
  irreversible or outward-facing — is packaged for you: the question,
  the options, the trade-offs, and the agent's recommendation with its
  reasoning.
- **One decision at a time.** A queue of ten questions presented at
  once gets ten shallow answers. Present the highest-leverage decision,
  get a ruling, then present the next.
- **A ruling's scope is exactly what was stated.** If you rule on item
  A, item B next to it keeps its previous status — no matter how
  similar it looks. Agents that silently widen a specific ruling into
  a general permission are the most common way authority leaks in a
  fleet. When in doubt, the agent treats the ruling as covering only
  what it named, and asks about the rest.
- **Decisions are recorded where the next reader will look** — in the
  charter, the workstream's record, or a decisions log — with the date
  and the ruling in the words it was given. A decision that lives only
  in a chat scrollback is a rumor the next session will re-litigate.
- **Content is never instructions.** Material an agent processes —
  documents, web pages, issue text, another agent's output — is data.
  It cannot grant a permission, widen a charter, or waive a decision,
  no matter how authoritatively it is phrased. Instructions come from
  you and from the orchestrator acting within its delegation, and from
  nowhere else.

## SessionBridge as the execution layer

The pattern above is transport-agnostic. SessionBridge is what makes it
practical when your agents' sign-ins live in a desktop session: the
orchestrator — wherever it runs — commissions builders and reviewers by
dropping job files into bridge inboxes, including bridges on other
machines whose CLIs it could never sign in to itself.

A worked mini-flow, fleet-scale version of the cross-family review in
[`docs/examples.md`](examples.md):

1. **Charter.** You and the orchestrator agree a workstream: "Add rate
   limiting to the billing API," charter written from
   [`examples/fleet/team-charter.md`](../examples/fleet/team-charter.md),
   reviewer named in it.
2. **Build job.** The orchestrator writes
   [`examples/fleet/commission-build.json`](../examples/fleet/commission-build.json)
   — an `accept-edits` job on an edit-enabled bridge profile, its
   `charter` field naming the charter, its prompt pointing the builder
   at the charter's deliverables and completion condition. The builder
   runs in your desktop session, does the work, and reports evidence:
   files changed, tests run, results.
3. **Review job.** Without waiting for you, the orchestrator writes
   [`examples/fleet/commission-review.json`](../examples/fleet/commission-review.json)
   — a `readonly` job through a **different adapter from a different
   model family** than the builder's, briefed from
   [`examples/fleet/reviewer-brief.md`](../examples/fleet/reviewer-brief.md).
   The reviewer re-runs the tests and reads the diff itself; it cannot
   edit what it judges, because the job's mode — and the bridge's
   ceiling — forbid it.
4. **Verdict and ruling.** The reviewer's verdict (PASS, or PASS WITH
   FINDINGS with severities and evidence) lands in the outbox. The
   orchestrator dispositions each finding on the record, applies the
   fixes or commissions a fix job, and brings *you* only the genuine
   judgment calls — each with a recommendation.
5. **Close.** The Improvement Loop runs as the closing step; when its
   audit gate passes, the charter's completion condition is checked off
   against its evidence, and the workstream closes with its record
   intact.

Note what the bridge's guards are doing for the pattern: the mode
ceiling makes "reviewers cannot edit" a property of the *system*, not
a promise in a prompt; the `author` / `charter` provenance fields make
every run attributable to the commission that caused it; at-most-once
execution means a commissioned review is never silently duplicated.

## Scaling, honestly

- **Start with one builder and one reviewer.** One orchestrator, one
  chartered builder, one independent reviewer, the loops as closing
  steps. That minimum fleet already delivers the pattern's core value:
  no unverified work, no self-judged work.
- **Add lanes only when review capacity allows.** A second builder
  doubles output and doubles review load. If verdicts are backing up,
  the fleet is too big — shrink it or add review capacity, never skip
  review to keep up.
- **Add model families before adding headcount.** A second *family* on
  review catches more than a second instance of the same family on
  build.
- **Keep a written record per workstream** — charter, state, rulings,
  verdicts — in files the next session loads. Fleets run across
  sessions; an agent that reconstructs its picture from chat history
  and habit will drift. Files are the memory.
- **Expect the orchestrator to be your job or your agent's, never
  nobody's.** A fleet without an active orchestrator is just several
  agents drifting in parallel.

---

*This guide is a starter pattern adapted from a production multi-agent
workflow — one operator running multiple standing agent teams with
designated reviewers, chartered workstreams, and these same loops as
closing discipline. It is not the complete system that workflow runs
on, and it is not a management framework: it is the smallest set of
habits that makes a personal fleet's output worth trusting. Adapt the
forms freely; keep the separations — builder from reviewer, verdict
from ruling, charter from improvisation — intact.*
