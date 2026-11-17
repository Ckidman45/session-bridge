# Security policy and threat model

## The one-sentence version

**Anyone who can write a file into the bridge's `inbox/` folder can run code as
you, in your desktop session, with your signed-in CLI's credentials.** The inbox
folder's permissions *are* SessionBridge's security boundary. Everything else
in this document is defense in depth around that fact.

## What SessionBridge is (and is not)

SessionBridge is a local automation bridge for *your own* agent workflows: an
external program you control drops a JSON job into a folder; a runner inside
your interactive session executes a coding CLI you are already signed in to;
results come back as files. It opens **no network listener** and adds no remote
access of its own — reaching the inbox requires whatever transport *you* chose
(local folder, SSH, a synced folder, a network share), and that transport's
security is yours to configure.

It is **not** a sandbox, a multi-tenant service, or a safe way to accept jobs
from parties you do not fully trust.

## What the runner enforces

These controls assume the job author is *semi-trusted* (your own orchestrator)
and exist to stop accidents, prompt-injected field values, and silent misuse —
not a determined attacker with inbox write access, who does not need them to
be weak:

- Prompts are delivered on stdin, or as a single quoted argument for CLIs that
  only accept an argument prompt. Job fields are never shell-interpolated, and
  the composed command line quotes every argument using the Win32
  `CommandLineToArgvW` rules (backslashes doubled before quotes) — the test
  suite proves an adversarial prompt arrives as exactly one argv element.
- `mode` is a **required, explicit** job field: a job that does not declare
  its permission level is rejected, never silently defaulted. `mode`,
  `effort`, and `model` are validated against per-adapter allowlists
  and patterns that reject option-shaped values (anything starting with `-`),
  so a job file cannot smuggle flags such as `--dangerously-skip-permissions`
  into the invocation. The runner additionally scans the *composed* argument
  list against a bypass-flag denylist (`--dangerously-*`, `*bypass*`,
  `--yolo`, `skip-permissions` patterns) and rejects the job if an adapter
  file tries to emit one. Adapters are still data files — review any adapter
  you did not write.
- A configurable **mode ceiling** is the *owner's* dial. The shipped example
  config sets it to the read-only mode, but the owner may set it to any
  tier (or an adapter-specific mode name), or to `none` / omitted — **no
  ceiling at all**, in which case any mode an adapter defines is available
  to any job that declares it. When a ceiling is set, jobs above it are
  rejected, and the rejection record still states the mode the job asked
  for. Safety here comes from explicitness, not restriction: every status
  record states the mode the job ran (or asked to run) at.
- Drains execute up to `maxConcurrency` jobs in parallel (**default 5**;
  set 1 for serial). Parallelism does not weaken at-most-once: claims are
  taken serially, in inbox order, as one atomic check-and-append per id
  under a per-id claim lock, before any execution starts; and a per-job
  execution lock means two jobs under one id never run at the same time
  while the runner lives (the second defers to a later pass of the same
  drain). If the runner is killed mid-job, the orphaned CLI keeps
  running and the bridge deliberately will not start a same-id job
  until it exits — the bridge never kills an orphan itself (see
  "Orphans" below). The limits are
  the ones stated for claiming below — a crash between claim and status
  still resolves to "already processed" / `interrupted`, never a re-run.
- `cwd` must exist and sit under a configured allowlist of roots, with
  junctions and symlinks resolved before the comparison.
- Timeouts are enforced by the runner, which kills the CLI's whole process
  tree. Captured output is capped (default 50 MB): the runner checks the
  captured total as it polls (every ~100 ms) and kills the CLI past the
  cap — the check is at poll granularity, so a fast producer can exceed
  the cap in memory before the check lands; stored artifacts are
  additionally truncated at 1,000,000 chars per stream. Jobs are at-most-once, claimed by **content hash**: every status
  record carries `jobSha256`, the SHA-256 of the job file's exact bytes,
  and every claimed hash is also appended — before validation, so rejected
  and malformed posts claim their bytes too — to a per-id **claim set**
  (`outbox\archive\<id>.claims.json`) that retention never prunes.
  Identical bytes under an id never run twice — an intervening
  different-bytes post under the same id cannot evict an earlier claim,
  because the set, not the one live status record, is the authority. A
  duplicate delivery is reported "already processed" and archived with the
  recorded status left untouched, and one left mid-run by a crash (status
  still `running` with the same hash) is recorded `interrupted`, never
  blindly re-run. Changed bytes under the same id are a deliberate repost
  and run fresh, with the prior artifacts archived first. The job file is
  archived *before* the final status is written, on every path, so no crash
  window can leave a finished job looking unclaimed in the inbox. Two
  honest limits: a claims file that exists but cannot be parsed **fails
  closed** — jobs for that id are recorded `failed` and never run until an
  operator deletes the file and lets the runner rebuild a conservative set
  from prior records — and if the runner dies in the milliseconds between
  recording a claim and writing the job's `running` status, those bytes
  are refused as "already processed" even though they never ran; repost
  with changed content or a new id. (A job *held* by a failed auth
  preflight is not processed at all: its claim is withdrawn, and it runs
  normally on a later drain.)
- **Orphans.** If the runner is killed mid-job (or the machine stops),
  the job's CLI may outlive it — an *orphan*. The bridge detects it on
  the next drain: a `running` status records the CLI's pid (`cliPid`),
  and while that pid is alive the drain logs an `ORPHAN:` line in
  `runner.log` and leaves every same-id job queued, unclaimed — no
  same-id job starts until the orphan exits, at which point the
  original attempt is resolved `interrupted` and the queued job runs
  normally. The bridge **never kills an orphan itself**: it did not
  start that process in this drain, and killing a process it cannot
  fully account for would be worse than waiting. One narrow case has no
  pid to check: if the runner died in the instant between starting the
  CLI and recording its pid, the `running` status has no `cliPid`.
  While such a status is younger than the job's timeout window the
  attempt is treated as possibly alive — same-id work defers with an
  `ORPHAN-UNKNOWN:` log line — and only a pid-less `running` status
  older than that window is resolved `interrupted`. The cost of a
  crash is therefore a same-id job that sits queued until its orphan
  exits (or its window passes), never a double execution.
- The runner verifies a SHA-256 **manifest** recorded at install time,
  covering the runner script, the config, and every adapter file, and refuses
  to run on any mismatch, missing file, or unlisted file. This is
  tamper-evidence against accidents and drift — anyone who can write the
  bridge root can also re-record the manifest (that is the installer's normal
  job), so it does not protect against a writer to the root.
- A malformed config fails closed: the runner logs the error, records it in
  the health file, and refuses to run — it never silently falls back to
  default policy.
- Every run leaves an audit trail: the exact prompt, stdout/stderr, and a
  structured status record with the job's author/charter provenance fields.
  That trail is retained in the outbox (readable by anyone with access to
  your profile) and pruned after the configured retention window.

## What it does not protect against

- **Inbox writers.** Write access to `inbox/` is code execution as the
  logged-in user, at any mode your ceiling allows. If you raise the ceiling
  to an edit or auto mode — or remove the ceiling entirely, which is your
  right as the owner — an inbox writer can make the CLI edit files and run
  commands accordingly. **No mode setting changes this boundary**: a
  read-only ceiling limits what a job can *do*, but the inbox's permissions
  decide who can *ask*, and anyone who can ask can spend your CLI quota and
  read whatever the CLI can read. The threat model is unchanged by every
  dial in this document.
- **The CLI's own configuration in the job's `cwd`.** A job's mode bounds
  what the *bridge* asks the CLI to do; it does not sandbox the CLI, and
  config files resident in the working directory are part of the CLI's own
  surface — they apply to bridge jobs exactly as they apply to interactive
  runs, at every mode. For Claude Code that means project
  `.claude/settings.json` / `.claude/settings.local.json` **allow-rules**
  (which can pre-approve tool calls the mode would otherwise gate),
  **hooks** (which execute shell commands on CLI events), and `.mcp.json`
  **MCP servers** (which the CLI launches as processes). Equivalently:
  Codex reads its `config.toml` / project `.codex/` configuration,
  including MCP servers and approval defaults; Gemini CLI reads
  `.gemini/settings.json`, including MCP servers; OpenCode reads
  `opencode.json`, including its permission rules and MCP servers. A
  `readonly` job run in a directory whose config pre-approves edits or
  defines hooks is not, in fact, read-only — review a directory's CLI
  config before pointing jobs at it, the same as you would before running
  the CLI there yourself.
- **Prompt content.** A read-only-*mode* job still sends its prompt to a model
  with your CLI account. Prompts you did not write can waste quota, and a CLI's
  read-only mode is the vendor's enforcement, not ours.
- **The CLI itself.** SessionBridge inherits each CLI's own bugs, permission
  model, and data handling. Read the vendor's documentation for the mode you
  map to `auto` — for some adapters that mode is intentionally unsandboxed and
  exists only so the common scale is complete.
- **Your transport.** A synced-folder provider can read your job files and
  results (they contain prompts and model output). An SSH route is only as
  strong as your key management. A world-writable network share would be a
  critical misconfiguration. Synced folders carry one more risk: a conflict
  copy delivered again under the *same* id is recognized by its content
  hash and never executes twice, but a duplicate renamed to a *different*
  id is a new claim the runner cannot recognize as the same job — prefer
  the SSH route for edit-enabled bridges.
- **A compromised runner machine.** If the machine or the user account is
  compromised, the bridge's hash check and logs do not save you.

## Recommendations

- Choose your mode ceiling deliberately. The shipped example starts at
  read-only, which is the right default while a bridge's inbox writers are
  unproven; raising it, or removing it entirely, is a legitimate owner
  choice once you trust everyone who can write to the inbox — the bridge
  does not second-guess it. If you want edit-enabled work *separated*
  (its own audit trail, its own root), a second bridge profile (see
  `docs/customization.md`, Profiles) gives you that separation; it is an
  organizational option, not a requirement.
- Set `maxConcurrency` to 1 for job streams whose jobs edit the same
  working tree: parallel CLIs are independent processes, and the bridge
  cannot merge their edits for them.
- Keep the bridge root under your user profile, with default ACLs. Never place
  the inbox on an anonymously writable share.
- Treat job files from other machines as code: prefer the SSH transport with
  key auth over synced folders for anything beyond read-only jobs.
- Review `outbox/` results and `runner.log` periodically; the audit trail only
  helps if someone reads it.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to the maintainers rather
than in a public issue: if you obtained this project from a git host with a
private vulnerability-reporting feature (for example GitHub Security
Advisories, "Report a vulnerability"), use it; otherwise use the contact
shown on the repository page. Allow a reasonable fix window before
disclosure. Because this project's central
risk is by-design (inbox write = execution), reports that restate the threat
model above are appreciated as documentation feedback, not security issues.
