# Enhancement Cycle 1 — record

**Subject:** SessionBridge 0.1.0 draft (initial commit `7a952a0`)
**Goal (the standard the cycle judged against):** *a stranger can install
this and safely run their session-bound coding CLIs from an external agent.*
**Protocol:** fresh-eyes critique (critic did not build it) → implement fixes
→ independent Audit Loop gate (auditor neither built nor critiqued) → fix the
gate's findings → regression tests. All work local; nothing published.

## Round 1 — Critique

**25 findings: 2 Blocker / 13 Major / 7 Minor / 3 Note.** Headlines:

- **B1 (Blocker):** Win32 argument quoting escaped quotes but not
  backslashes — a prompt like `x\" --injected-flag rest` split into separate
  argv tokens on all four argument-delivery adapters, defeating the central
  no-flag-injection claim. Reproduced by the critic against the real runner.
- **B2 (Blocker):** the auth-failure "hold" re-processed the same job for the
  full 90-minute drain cap, logging ~24 lines/sec — the most common failure
  state (an expired sign-in) became a spin loop.
- Majors included: no runner-side bypass-flag denylist (adapter JSON trusted
  verbatim); integrity check covered only the runner script, not the config
  or adapters that *are* the policy; the Antigravity adapter contradicted the
  vendor's documented headless form and was labeled "verified" on a
  self-citation; the Codex effort list contradicted its own cited source;
  Gemini CLI presented as current five months after its consumer service
  ended, with the README misstating its prompt delivery; OpenCode's
  "readonly" tier could run arbitrary shell; the test harness left most
  headline guards unproven (no argument-delivery test at all); synced-folder
  docs claimed conflict copies are ignored (they match `*.json` and would
  execute); the README quickstart omitted the copy-into-inbox step; the bash
  client crashed on the runner's 7-digit fractional timestamps under
  Python ≤ 3.10; config load failed *open* and silent; the cwd allowlist
  never resolved junctions/symlinks.
- Notes: sanitization sweep clean (fictional `alex` throughout, no real
  names/paths/IPs); SECURITY.md honest with three gaps, since closed.

## Fix pass 1 (runner 0.2.0)

Correct `CommandLineToArgvW` quoting (`Quote-Arg`); held-adapter set +
per-drain id dedupe + unsafe-filename skip + no-progress drain exit;
runner-side bypass denylist + adapter structural validation; integrity
**manifest** covering runner + config + every adapter, verified before the
empty-inbox exit, recorded identically by `install.ps1` and the test
harness; config loading fails **closed** (log + health record + refusal);
cwd and allowlist roots resolved through junctions/symlinks; explicit type
checks for every job field (malformed = `rejected`); output capture cap
(50 MB) + stored-artifact truncation; retention now prunes archive/done;
lock rework with logged contention; Antigravity adapter moved to the
documented `-p` argument form with official sources; Codex efforts corrected
to `minimal..xhigh`, TOML-quoted effort value, status demoted to
`community`; OpenCode's dishonest `readonly` tier **removed** (jobs are
rejected, never widened); Gemini sunset wording and prompt-delivery cells
corrected; README quickstart made literally followable; held-job exception
documented in the job contract; bash client timestamp parsing fixed and
client prerequisites documented; tests grew from 8 to 12 (argument delivery,
integrity refusal, auth-hold prompt exit, config fail-closed, real
process-tree kill via a spawned child PID).

## Round 2 — Audit Loop gate

**Verdict: PASS WITH FINDINGS — 0 Blocker / 3 Major / 4 Minor / 3 Note.**
The auditor reproduced both Blocker fixes independently (18/18 adversarial
quoting cases byte-exact through a reference `CommandLineToArgvW` parser; a
mixed held/healthy/duplicate/conflict-copy drain bounded at 17 log lines),
cross-checked that `install.ps1`, the runner, and the test harness all write
the identical manifest format, and composed every shipped adapter's argv
against the denylist (zero false positives). Per-item: 21 of the critic's 25
Closed, 4 Partially closed. Ten new findings (N1–N10), three of them Major
defects *in the fix pass itself*:

- **N1 (Major):** the denylist scanned the composed argv *including the
  prompt* — a job asking to "review this cache bypass logic" was rejected.
- **N2 (Major):** a config whose top level is valid JSON but not an object
  (`null`, `[1,2,3]`) silently fell back to default policy.
- **N4 (Major):** path resolution missed a junction *inside* a link target.
- N3 numeric coercion (`1.9` → 2), N5 lock probe/open race, N6 probes not
  denylist-scanned, N7 Profiles snippet missing the re-install step, N8 a
  stale version string in an example, N9 retention aged by original write
  time, N10 legacy-hash fallback discarded its explanatory detail.

## Fix pass 2

All ten audit findings fixed: the denylist scans only adapter-emitted args,
before prompt substitution, and also covers version/auth probe argv (N1,
N6); config root must be a JSON object and numerics must be whole JSON
numbers (N2, N3); path resolution rewritten as a queue-based walk that
re-walks every link target's components, hop-capped (N4); the lock is a
single atomic `OpenOrCreate` + `FileShare.None` open held for the whole run,
heartbeat rewritten through the held handle (N5); docs corrected (N7, N8);
archived files' write times reset so retention ages from archiving (N9);
the legacy-hash detail is logged (N10). Two regression tests added
(T13: a prompt about bypasses completes, intact, on the argument path;
T14: a `null` config fails closed).

## Final state

- **Tests: 14/14 PASS** (`tests/run-tests.ps1`, PowerShell 7.4.6, no real
  AI CLI installed): T1 happy path/stdin byte-exact · T2 option injection
  rejected · T3 over-ceiling rejected · T4 bad cwd rejected · T5 broken
  JSON isolated · T6 timeout kills the process tree (child PID verified
  dead) · T7 rerun archives prior artifacts · T8 interrupted job not
  re-run · T9 adversarial argument delivery (one intact argv element) ·
  T10 integrity refusal · T11 auth hold exits promptly · T12 malformed
  config fails closed · T13 denylist never scans the prompt · T14
  non-object config fails closed.
- All JSON parses; all PowerShell files parse; code files ASCII-clean.
- **Not done, deliberately:** a delta re-audit of fix pass 2 was not run in
  this cycle — the gate's verdict stands as PASS WITH FINDINGS with all ten
  findings dispositioned above and covered by tests, and a short delta
  audit is the recommended step before any public release. Real-Windows
  verification (scheduled task, junction behavior under NTFS, each vendor
  CLI's live `--help`) likewise remains a pre-release step: this cycle ran
  on PowerShell 7 under Linux, where .NET's argument parsing is a proxy for
  Win32 parsing and symlinks stand in for junctions.

## Delta audit + fix pass 3

**Delta audit (of fix pass 2): PASS WITH FINDINGS — 0 Blocker / 1 Major /
1 Minor / 2 Notes.**

- **D1 (Major):** the bypass denylist never scanned `invoke.promptArgs`
  templates. The scan ran on the partially composed argv *before* `{prompt}`
  substitution — correctly, so the prompt itself is never scanned (N1) —
  but `promptArgs` were appended *after* the scan, unscanned. An
  argument-delivery adapter could therefore emit a bypass flag verbatim.
  The auditor proved it live: an adapter with promptArgs
  `["--dangerously-skip-permissions", "{prompt}"]` completed a job, and
  the fake CLI's invocation log showed the flag as a delivered argv element.
- **D2 (Minor):** no test could make the denylist fire.
- **D4 (Note):** `ArchiveJobFile` did not reset `LastWriteTime` after the
  move (N9 fixed this for artifacts but not job files), so done-folder
  pruning aged a job file from its inbox arrival rather than its archiving.
- A second Note was accepted without a code change in this pass.

## Fix pass 3 (runner 0.2.1)

- **D1:** the pre-substitution denylist pass now also scans the raw
  `invoke.promptArgs` templates — adapter-authored elements with `{prompt}`
  still an unsubstituted placeholder token — before any of them are
  appended or substituted. The N1 property stands absolute: the prompt
  TEXT is never scanned; only adapter-authored template elements are. The
  version/auth probe scanning is unchanged.
- **D2:** new regression test **T15** — a fourth fake adapter
  (`fakebypass`) whose promptArgs emit `--dangerously-skip-permissions`;
  its job must be `rejected` with the fake CLI never invoked. Confirmed
  able to fail: with the D1 scan temporarily reverted, T15 went red
  (the job `completed` and the flag was delivered; suite 14/15, exit 1);
  with the fix restored, the suite is green again.
- **D4:** `ArchiveJobFile` resets the moved file's `LastWriteTime`, so
  retention ages done job files from archiving — the same pattern N9
  applied to artifacts.
- Runner version bumped 0.2.0 → 0.2.1; the install guide's health-record
  example was updated to match. (The "Fix pass 1 (runner 0.2.0)" heading
  above is a historical record of that pass and is unchanged.)

**Evidence:** full suite **15/15 PASS** (`tests/run-tests.ps1`). An
independent re-run of the auditor's Probe A construction against the
fixed runner: the job is `rejected` at composition ("adapter 'probea'
tried to emit a blocked bypass argument '--dangerously-skip-permissions'
in invoke.promptArgs; refusing to run") and the fake CLI was never
started — its invocation log does not exist.

## Bridge Perfection — runner 0.3.0 (2026-11-14)

A later change set, driven by two rulings from the project owner:
*"Parallelization is a massive win and all bridges should have that
dial"*, and bridges should *"be able to allow any permission type — the
bridge doesn't need to restrict that, because users will want different
permission levels for different tasks."* The design settlement: **safety
moves from restriction to explicitness, and control moves to the owner.**

- **Parallel drain dial (A).** New config key `maxConcurrency`,
  **default 5** (an owner who wants serial sets it to 1; range 1–32).
  Claiming and validation stay serial, in inbox order; only CLI
  execution overlaps, via cooperative polling inside the one runner
  process. Claiming was hardened for concurrency: the check-and-append
  is now one atomic step per id (`Test-And-AddClaim`) under a per-id
  claim lock, and a per-job execution lock guarantees two jobs under
  one id never execute at the same time — a same-id job whose bytes are
  a distinct claim defers to a later pass of the same drain and runs
  there. Exactly-once is unchanged: identical bytes never run twice,
  however delivered.
- **Permission model (B).** `mode` is now a **required** job field:
  missing or empty is a validation error, never a silent fallback to a
  default. Any mode an adapter defines — including adapter-specific
  modes beyond the common scale — is a legitimate explicit choice. The
  `modeCeiling` config key remains as the **owner's dial**: set it to
  cap jobs (the shipped example still sets `readonly` for strangers),
  or omit it / set `none` for no ceiling at all. A job above a set
  ceiling is rejected, and the rejection record states the mode it
  asked for; every status records the mode the job ran at and the
  ceiling in force. Both clients refuse to submit a modeless job. The
  bypass denylist is untouched: it still scans adapter templates and
  arguments only, never prompt text.
- **Threat model unchanged.** Anyone who can write to the inbox can run
  code as the user; inbox permissions are the security boundary, and no
  mode setting — and no setting of either new dial — changes that.
  README, SECURITY, and the setup/customization/install/example docs
  were rewritten to say all of this plainly.

**Tests: 26 → 35**, all passing (`tests/run-tests.ps1`, PowerShell
7.4.6, fake CLI). New: T27/T28 missing/empty mode rejected; T29 ceiling
removed = full range runs, including a custom adapter-defined mode,
with modes recorded; T30 a ceiling rejection records the requested
mode; T34 a custom mode is rejected under a ranked ceiling; T31 five
10-second jobs at dial 5 overlap — measured by concurrency marker
files the fake CLI leaves while sleeping (max concurrent observed: 5),
not by wall clock, after a first timing-based version of the test
proved non-portable on a throttled VM; T32 identical bytes delivered
three ways concurrently run exactly once; T33 same-id different-bytes
concurrently both run exactly once, serially per id; T35 the
PowerShell client refuses a modeless job at submit. Nineteen existing
tests that posted modeless jobs now declare `mode` explicitly — the
property each guards is unchanged. **Mutation evidence** (probes
against throwaway copies of the runner; the repo source was never
mutated): disabling the claim check makes the A-B-A eviction sequence
run the original bytes twice; restoring a silent `readonly` mode
fallback makes a modeless job complete instead of being rejected;
disabling the ceiling check makes an `auto` job complete under a
`readonly` ceiling; forcing batch size 1 drops measured concurrency
from 5 to 1; making the per-job execution lock non-exclusive lets two
same-id jobs overlap (concurrency 2 instead of 1). Every new guard was
seen to fail before it was trusted.

### Fix pass — runner 0.3.1 (2026-11-14, gate findings on 0.3.0)

The fresh-eyes gate on 0.3.0 returned **PASS WITH FINDINGS — 0 Blocker /
3 Major / 7 Minor / 5 Notes**; everything claimed for the non-crash paths
verified independently (suite re-run 35/35, mutations reproduced). The
findings concentrated in crash-adjacent concurrency and docs precision.
Dispositions, all implemented in 0.3.1:

- **M1 (Major) — orphan guard, detect-and-defer (no auto-kill).** Running
  statuses now record the CLI's pid (`cliPid`). A later drain that finds
  a `running` status whose pid is still alive (start-time checked, so a
  recycled pid does not count) treats the id as still executing: it logs
  an `ORPHAN` line naming id + pid, leaves same-id jobs queued and
  unclaimed, and never resolves the live attempt as `interrupted`. Once
  the pid is gone, the corpse is resolved `interrupted` *before* the
  queued job is processed, so the successor still runs exactly once.
  New test **T36** is the auditor's kill test: runner killed -9
  mid-flight, changed bytes posted — drain 2 executes nothing (ORPHAN
  logged, file queued), drain 3 (after the orphan exits) archives the
  original as `interrupted` and runs the successor exactly once.
  Mutation evidence: with the guard disabled, the successor starts over
  the live orphan (successor calls 1, measured concurrency 2); intact,
  successor calls 0, concurrency 1.
- **M2 (Major) — lock before side effects.** The per-job execution lock
  is now taken *before* `ArchivePriorArtifacts`, the `running` status,
  and the prompt write; a deferring attempt leaves zero trace (0.3.0
  wrote both first, disturbing the in-flight job's records and leaving a
  `running` status a later drain could mis-resolve). **T33b** asserts
  the archived set after a same-id drain is exactly the first job's own
  artifacts — its prompt, a `completed` status, nothing from the
  deferral. The deferral path's claim-withdrawal failure now also logs a
  warning (m6, matching the auth-hold posture).
- **M3 (Major, docs) — the CLI's own config is not bounded by mode.**
  SECURITY.md's "does not protect against" list now names it explicitly:
  config resident in a job's `cwd` applies at every mode — for Claude
  Code, project `.claude/settings(.local).json` allow-rules, hooks
  (which execute shell commands), and `.mcp.json` MCP servers — with the
  equivalent one-line surfaces for Codex, Gemini CLI, and OpenCode, and
  a matching config-surface line added to all four adapter notes.
  **Not built:** adapter-level isolation flags are recorded here as a
  named future item, per the coordinator's decision — disclosure now,
  machinery later.
- **Minors/Notes fixed:** m1 batch scheduling disclosed in
  `docs/setup.md` (batches complete before the next starts; one long job
  can hold back the following batch — intentional simplicity, kept);
  m2 T2 was passing vacuously through the mode-required rejection — it
  declares `mode` again and its PASS line shows the model-pattern error;
  m3 ceiling semantics stated accurately in `docs/customization.md`
  (an adapter-mode ceiling is an exact-match pin, not a rank; matching
  is case-insensitive in practice, declared mode recorded verbatim);
  m4 the ceiling-raise workflow is documented (a rejected post claims
  its bytes — resubmit with a new id after raising the ceiling) in
  customization and the install troubleshooting table; m5 the retention
  prune now also exempts `*.claims.lock` (T24 extended); m7 the output
  cap is described as what it is — a poll-granularity check, with stored
  artifacts truncated at 1M chars; N2 stale `locks/<id>.lock` files are
  removed at drain start when the id has no running status and no queued
  job (T37); N4 health records now carry `maxConcurrency` and
  `modeCeiling` (T38).
- **Tests: 35 → 39**, all passing (T33b, T36, T37, T38 new; T2, T24,
  T33 extended).
- **Residuals carried, named:** N1 — under claim-lock contention a job
  whose claim cannot be taken inside the retry window is recorded
  `failed` rather than deferred (fail-closed posture kept deliberately;
  revisit if it ever fires in practice). N3 — `FinishCapture`'s
  `WaitForExit` is unbounded if `KillTree` itself fails; the timeout
  path relies on the tree kill. Adapter-level isolation flags (above).
  Real-Windows verification of the 0.3.x line (PS 5.1, scheduled task,
  NTFS lock behavior, live vendor CLIs) is still outstanding and remains
  a pre-release step — 0.3.0/0.3.1 were verified on PowerShell 7.4.6
  under Linux.

### Fix pass — runner 0.3.2 (2026-11-14, round-2 re-gate findings on 0.3.1)

The round-2 re-gate of 0.3.1 returned **PASS WITH FINDINGS — 0 Blocker /
0 Major / 2 Minor / 2 Notes**; M2, M3, and all round-1 Minors were
verified closed, and the M1 orphan guard's code was closed and
mutation-proven. Four items remained; all four are dispositioned here:

- **NF1 (Minor, docs) — M1's docs leg.** The "two jobs under one id
  never execute at the same time" claim stood UNQUALIFIED in README,
  SECURITY.md, and `docs/customization.md`, and no user-facing doc
  mentioned orphans at all. The claim is now qualified everywhere it
  appears in user-facing docs (README, SECURITY.md,
  `docs/customization.md`, `docs/setup.md`, and the runner's own header
  comment): the guarantee holds **while the runner lives**; if the
  runner is killed mid-job, the orphaned CLI keeps running and the
  bridge deliberately will not start a same-id job until it exits. The
  behavior is documented where an owner will look: a new "Interrupted
  and orphaned jobs" section in `docs/install.md` (the `ORPHAN:` /
  `ORPHAN-UNKNOWN:` `runner.log` lines, why a same-id job may sit
  queued after a crash, what resolves it — orphan exits → original
  resolves `interrupted` → queued job runs — and that the bridge never
  kills orphans itself), a troubleshooting row pointing to it, and an
  "Orphans" bullet in SECURITY.md. (The 0.3.0/0.3.1 entries in this
  record keep their original wording: they are the historical record
  of what was claimed then, and this entry is the correction.)
- **NF2 (Minor, code) — the unrecorded-PID window.** In 0.3.1 the
  `cliPid` was written in a second status write immediately after
  `StartCapture`; a runner killed inside that sub-second gap left a
  `running` status with `cliPid` null, invisible to the orphan guard:
  a changed-bytes successor could start over the live orphan, and an
  identical-bytes successor was mis-resolved `interrupted` while its
  CLI still ran. Closed conservatively: (a) the cliPid write is the
  very first post-start action (nothing intervened in 0.3.1; the call
  site now states the invariant so it stays that way), and every
  status now also records the job's `timeoutSec`, so the window below
  is recoverable from the status itself; (b) a `running` status with
  NO recorded pid whose age is less than its timeout window — the
  status's recorded `timeoutSec` if present, else the config's
  `maxTimeoutSec` (the only bound covering every job the dead runner
  could have started), plus a 60-second grace — is treated as POSSIBLY
  ALIVE: same-id work defers, unclaimed, with an `ORPHAN-UNKNOWN` log
  line, exactly like a live recorded pid. Only a pid-less `running`
  status OLDER than that window is resolved `interrupted` (the
  hash-carrying case resolves before the queued job is processed,
  mirroring the recorded-pid corpse; the claim-less legacy case keeps
  its legacy-fallback semantics). The guard sits at the earliest
  prior-status check, before claiming, with defense-in-depth repeats
  in the already-claimed and legacy-fallback paths. An unparseable
  `startedAt` counts as possibly alive — defer, never double-run.
- **NF3 (Note, code) — last silent `RemoveClaim`.** The legacy
  claim-less-status fallback's claim withdrawal swallowed failures in
  an empty catch, unlike the auth-hold and execution-lock paths fixed
  earlier. It now logs the same warning line as those paths (as does
  the new NF2 deferral in the same fallback). All four `RemoveClaim`
  call sites now warn on failure.
- **NF4 (Note, docs) — install health example.** The
  `docs/install.md` health-record example (bumped to runner 0.3.2) now
  also shows `maxConcurrency` and `modeCeiling`, the fields the real
  health record has carried since T38, with a bullet explaining them.

**Tests: 39 → 41**, all passing (`tests/run-tests.ps1`, PowerShell
7.4.6, fake CLI). New: **T39** — a hand-crafted FRESH pid-less
`running` status (hash + `timeoutSec` recorded, `cliPid` null) plus a
live detached fake CLI: the changed-bytes successor does NOT start
(deferred, `ORPHAN-UNKNOWN` logged, file queued, status still
`running`); **T40** — the same status aged beyond its window resolves
`interrupted` (visible in the archive) and the queued successor runs
exactly once, its claim never consumed by T39's deferral. Fixture
notes, assertions unchanged: the T8 and T18 seeds — pid-less `running`
statuses that have always meant *corpses* — are now aged 3 hours,
beyond every timeout window, because a fresh pid-less `running`
status is precisely what T39 proves must defer; their PASS lines and
assertions are untouched. T36 (recorded-pid orphan), T33/T33b
(same-id concurrency, zero-trace deferral), and every other
pre-existing test pass unchanged. **Mutation / probe evidence**
(private scratch probes against throwaway bridge copies; the repo
source was never mutated): with the fixed runner, a fresh pid-less
status + a live detached sleeper defers both a changed-bytes
successor (0 calls, `ORPHAN-UNKNOWN` logged, still queued) and an
identical-bytes successor (stays `running`, not mis-resolved); aged
past the window, the original resolves `interrupted` into the archive
and the successor runs exactly once. Against the pre-fix 0.3.1 runner
the same probe overlaps: the changed-bytes successor executes while
the detached process still lives, and the identical-bytes delivery is
mis-resolved `interrupted` under the live CLI. The same two failures
reproduce against the 0.3.2 runner with `Test-NullPidPossiblyAlive`
mutated to always return `$false` (null pid treated as dead — the
pre-fix behavior), and the full suite run against that mutated runner
in a scratch repo copy goes red: T39 FAILs (successor calls 1, state
`completed`, no `ORPHAN-UNKNOWN` logged) and T40 FAILs downstream
(the mutation let T39's drain consume the successor T40 depends on),
39/41, exit 1. Intact, the suite is green.
- **Residuals carried, unchanged and restated:** N1 — under claim-lock
  contention a job whose claim cannot be taken inside the retry window
  is recorded `failed` rather than deferred (fail-closed posture kept
  deliberately; revisit if it ever fires in practice). N3 —
  `FinishCapture`'s `WaitForExit` is unbounded if `KillTree` itself
  fails; the timeout path relies on the tree kill. Adapter-level
  isolation flags remain a named future item (disclosure in
  SECURITY.md and the adapter notes since 0.3.1; machinery later).
  Real-Windows verification of the 0.3.x line (PS 5.1, scheduled task,
  NTFS lock behavior, live vendor CLIs) is still outstanding and
  remains a pre-release step — 0.3.2 was verified on PowerShell 7.4.6
  under Linux, like 0.3.0/0.3.1 before it.

## Post-cycle verification (0.2.x line)

Real-Windows verification ran 2026-11-14 (Windows PowerShell 5.1): the
full suite passed 15/15 on Windows, NTFS junction behavior was exercised
live, and the Antigravity and Claude Code adapter claims were verified
against the live CLIs. It produced two documentation findings, both
fixed in the docs with no code changes: D-1 — the install guide's smoke
flow did not account for the runner's 5-second copy-settling guard, so a
copy-then-fire-immediately first run could silently no-op; D-2 — the
custom-adapter path for an already-installed bridge (source tree +
installer re-run, because the integrity manifest refuses unlisted
adapters) was not stated in any single place.
