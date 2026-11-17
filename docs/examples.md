# Example workflows

Four workflows the bridge exists for. The job files live in `examples/` so
you can copy and adapt them. All examples use fictional users and projects.

## (a) Cross-family code review

**Shape:** an orchestrator working with vendor A's CLI wants a second
opinion from vendor B's CLI — which is signed in only on your laptop's
desktop session. The review is read-only: the reviewing CLI must not be
able to edit the code it judges.

Your orchestrator writes the job (note `author` / `charter` — the audit
trail matters when an agent commissions another agent):

```json
{
  "id": "review-pr482-20260101-001",
  "adapter": "claude-code",
  "prompt": "Review the changes in this repository's working tree (git diff HEAD). Focus on: tenant-isolation mistakes, missing tests for the new billing path, and anything that would surprise a careful maintainer. Reply with a verdict line (PASS or PASS WITH FINDINGS), then findings ordered by severity with file and line references.",
  "cwd": "C:\\Users\\alex\\projects\\billing-api",
  "mode": "readonly",
  "effort": "high",
  "timeoutSec": 900,
  "author": "orchestrator",
  "charter": "cross-family review of PR 482 before merge"
}
```

The job declares `readonly` explicitly (a job with no `mode` is rejected),
and the laptop's bridge also runs a `readonly` ceiling, so even a mistaken
`mode` in a job could not have widened it. The bridge runs the review
in-session; the orchestrator
reads `outbox/review-pr482-20260101-001.out.txt` and records the verdict.
This is the workflow SessionBridge was generalized from: independent
review by a *different model family* than the one that wrote the code.

## (b) Overnight build queue

**Shape:** you queue small, well-specified build tasks before bed; they
drain in your session while the machine is idle (up to `maxConcurrency`
at once — default 5; set it to 1 on the build profile if the tasks edit
the same checkout, as these do), and you review the results — and the
diffs — in the morning.

Use a **separate edit-enabled profile** for this (see
`docs/customization.md`, Profiles): its ceiling is `accept-edits`, its root
is `session-bridge-build`, and your main bridge stays read-only. A job:

```json
{
  "id": "night-20260101-003",
  "adapter": "codex",
  "prompt": "In this repository, implement the change described in TASKS.md item 3 only. Run the existing test suite afterward and summarize: what you changed, which files, and the test results. Do not commit.",
  "cwd": "C:\\Users\\alex\\projects\\billing-api",
  "mode": "accept-edits",
  "timeoutSec": 1500,
  "author": "alex",
  "charter": "overnight queue, TASKS.md item 3"
}
```

Post several before sleep (`submit` without `--wait`); the drain cap (10
jobs / 90 minutes per invocation, then the next tick continues) paces them.
Morning checklist: read each status (expect `completed`, `timed-out`, or
an honestly `failed`), read the summaries, review the diffs, and only then
commit — the adapters are configured not to commit for you. Anything left
`interrupted` after an overnight reboot is *not* silently re-run; repost
it deliberately — with changed content, since jobs are claimed by content
hash and an identical repost is reported "already processed" — if the
half-finished state looks safe.

## (c) The mounted-drive job (session-only resources)

**Shape:** the work lives somewhere only your desktop session can reach —
a mounted network drive, an unlocked encrypted volume, a drive letter that
exists only when you're logged in. Headless automation cannot even see the
path; the in-session runner can.

```json
{
  "id": "nas-summary-20260101-001",
  "adapter": "antigravity",
  "prompt": "Summarize the markdown notes in this folder: one line per file (name + gist), then a short list of anything that looks like an open decision.",
  "cwd": "Z:\\Shared\\Projects\\Website",
  "mode": "readonly",
  "timeoutSec": 600,
  "author": "alex",
  "charter": "weekly notes summary from the NAS"
}
```

The config's `allowedCwdRoots` must include the drive
(`["%USERPROFILE%", "Z:\\Shared"]`) — cwd allowlisting is how you say
*which* session-only places jobs may touch.

## (d) Two machines: the client is not the runner

**Shape:** a small always-on box (or a cloud VM, or a teammate's script —
any computer) orchestrates; your laptop does the CLI work because that's
where the sign-ins live.

On the orchestrator, with the SSH transport from `docs/setup.md`:

```bash
export SB_HOST="alex@laptop"
export SB_REMOTE="C:/Users/alex/session-bridge"
client/sessionbridge.sh submit review-job.json --wait 900
echo "client exit code: $?"   # 0 completed, 1 job failed, 2 wait timed out
```

The orchestrator never holds CLI credentials and never sees a sign-in
prompt; it holds only SSH access to one folder on the laptop. If the
laptop is asleep or logged out, the job waits in the inbox and the client
exits 2 (wait timeout) — distinguishable from a job failure, so the
orchestrator can repost later instead of alarming anyone.

---

Running several of these workflows as one coordinated fleet — charters,
designated reviewers, quality loops — is covered by
[docs/agent-fleet-pattern.md](agent-fleet-pattern.md), with starter
templates in [`examples/fleet/`](../examples/fleet/).
