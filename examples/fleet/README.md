# Fleet starter templates

Copyable starters for the pattern in
[`docs/agent-fleet-pattern.md`](../../docs/agent-fleet-pattern.md) —
read the guide first; these files are its forms, not a substitute for it.

| File | What it is |
|---|---|
| [`team-charter.md`](team-charter.md) | Fill-in charter for one workstream: goal, scope and boundaries, deliverables, completion condition, stop conditions, reviewer assignment. One per workstream, written before work starts. |
| [`reviewer-brief.md`](reviewer-brief.md) | The designated reviewer's standing brief: the independence rule (re-run the evidence, never trust the summary), the three audit angles, the verdict scale (PASS / PASS WITH FINDINGS), and the findings format with severities. |
| [`commission-build.json`](commission-build.json) | A bridge job that commissions a build under a charter: `codex` adapter, `accept-edits` mode (post it to an edit-enabled bridge profile — the example-seeded bridge ceiling is `readonly` and will reject it; raise the ceiling or use a profile whose owner set it higher). |
| [`commission-review.json`](commission-review.json) | A bridge job that commissions the independent review of that build: `claude-code` adapter — a *different model family* from the builder — `readonly` mode, briefed from `reviewer-brief.md`. |

The pair is the pattern in miniature: the build job's `charter` field
and the review job's `charter` field name the same charter, so every
run is attributable to the commission that caused it, and the review is
structurally read-only — the job declares `readonly` explicitly, and on
a profile whose owner set a `readonly` ceiling the ceiling enforces it
too.

Adapt the fictional project (`billing-api`), paths, and limits to your
own work; keep the separations — builder from reviewer, verdict from
ruling, charter from improvisation — intact.
