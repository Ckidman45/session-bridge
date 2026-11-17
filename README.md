# SessionBridge

**Run your session-bound AI coding CLIs from anywhere you can drop a file.**

Many AI coding CLIs — Antigravity, Claude Code, Codex, and others — bind their
sign-in to your *interactive desktop session*: OAuth state, OS keychain
entries, and mounted drives all live there. Automation that arrives over SSH
or from a headless agent lands in a *different* session and hits a wall:

```
$ ssh laptop "agy --print 'review this diff'"
Error: Please sign in        <-- you ARE signed in. Just not in this session.
```

SessionBridge crosses that **session wall**. A tiny runner lives inside your
real desktop session (a scheduled task that only runs while you are logged
in). Any client that can drop a JSON job file into the runner's `inbox/`
folder — an orchestrating agent on another machine, a script, you — can run
the local CLI and read structured results from `outbox/`. There is **no
inbound network listener**; the file queue is the whole interface.

```
 client (any machine)                runner machine (your desktop session)
 --------------------                -------------------------------------
 job.json --[scp / sync / share]-->  inbox/
                                       sessionbridge.ps1  (scheduled task,
                                         runs only in your logon session)
                                         |- validates the job
                                         |- runs the CLI (already signed in)
                                         v
 result  <--[scp / sync / share]--   outbox/<id>.status.json + .out.txt
```

## ⚠️ Security first

**Anyone who can write to the inbox can run code as you.** The inbox folder's
permissions are the security boundary. SessionBridge is a bridge for *your
own* agents on *your own* machines — not a service for accepting jobs from
others. The runner adds real guardrails on top of that boundary (explicit
per-job permissions, allowlists, no flag injection — see
[SECURITY.md](SECURITY.md)), but read the threat model before you install.
The shipped example configuration starts conservative — a read-only mode
ceiling, five jobs running at once — and every one of those dials is yours
to turn, including fully open.

## Quickstart (Windows)

Prerequisites: Windows 10/11 with PowerShell 5.1, and at least one supported
coding CLI **already installed and signed in interactively** (the bridge uses
your existing sign-in; it cannot sign in for you).

```powershell
git clone <repo-url> session-bridge-src   # the URL of wherever you obtained this repository
cd session-bridge-src
powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1
```

That installs to `%USERPROFILE%\session-bridge`, registers the
**SessionBridge** scheduled task, and seeds a read-only config. Now create a
job file and copy it **into the inbox** (adjust `adapter` to a CLI you
actually signed in to):

```json
{
  "id": "smoke-001",
  "adapter": "antigravity",
  "prompt": "Reply with exactly: bridge smoke ok",
  "mode": "readonly"
}
```

```powershell
# save the JSON above as .\smoke-001.json, then:
Copy-Item .\smoke-001.json "$env:USERPROFILE\session-bridge\inbox\"
Start-ScheduledTask -TaskName SessionBridge
# a first drain includes CLI probes - wait for the status file to appear
while (-not (Test-Path "$env:USERPROFILE\session-bridge\outbox\smoke-001.status.json")) { Start-Sleep -Seconds 5 }
Get-Content "$env:USERPROFILE\session-bridge\outbox\smoke-001.status.json"
Get-Content "$env:USERPROFILE\session-bridge\outbox\smoke-001.out.txt"
```

Full walkthrough, troubleshooting, and uninstall: **[docs/install.md](docs/install.md)**.
Connecting a client from another machine: **[docs/setup.md](docs/setup.md)**.

## Adapters

An adapter is a single JSON file describing one CLI's noninteractive
invocation, its mode vocabulary mapped to a common scale
(`readonly` / `accept-edits` / `auto`), and its auth check. Every flag is
sourced from the vendor's documentation — see each file's `sources`.

| Adapter | CLI | Prompt via | Status |
|---|---|---|---|
| `antigravity` | Antigravity (`agy`) | argument (`-p`) | verified (official docs) |
| `claude-code` | Claude Code (`claude`) | argument | verified (official docs) |
| `codex` | OpenAI Codex (`codex`) | stdin (`exec -`) | community (official docs; effort form unconfirmed on a live binary — see adapter notes) |
| `gemini-cli` | Gemini CLI (`gemini`) | argument (`-p`) | verified (official docs) — legacy for consumer accounts: Google ended Gemini CLI service for AI Pro / Ultra / free tiers on 2026-06-18; paid API-key and Code Assist access continues, see adapter notes |
| `opencode` | OpenCode (`opencode`) | argument | community (docs-verified; **no readonly tier** — see adapter notes; auto tier has no OS sandbox) |
| `aider` | Aider (`aider`) | argument (`--message`) | community (docs; mapping is an inference) |
| `generic-example` | template | either | copy it to add your own CLI |

Details and the customization routes (new adapters, transports, profiles,
other OSes): **[docs/customization.md](docs/customization.md)**.

## The job contract

A job is one JSON file. Required: `id`, `adapter`, `prompt`, `mode`.
**`mode` has no default**: every job declares its permission level
explicitly, choosing any mode its adapter defines (`readonly` /
`accept-edits` / `auto` on the common scale, plus any adapter-specific
modes). A job with a missing or empty `mode` is rejected — permission is
never inherited silently. The owner's config may cap what jobs can
declare with a **mode ceiling** dial; the shipped example config sets it
to `readonly`, and setting it to `none` (or removing it) means no ceiling
at all — the full range, by the owner's choice. Every status record
states the mode the job declared and the ceiling in force. Optional:
`cwd` (must sit under a configured allowlist), `model`, `effort`,
`timeoutSec` (default 600), and provenance fields `author` / `charter` /
`requestedBy`.

**Jobs run in parallel.** A drain validates and claims jobs serially, in
inbox order, then executes up to `maxConcurrency` of them at once —
**default 5**; set the dial to 1 for fully serial drains. The at-most-once
guarantee is unchanged: claiming is atomic per id (a claim lock plus the
content-hash claim set), identical bytes never run twice however they are
delivered, and two jobs under one id never execute at the same time
while the runner lives (a per-job execution lock defers the second to a
later pass of the same drain, where it runs normally). If the runner is
killed mid-job, the orphaned CLI keeps running — and the bridge
deliberately will not start a same-id job until it exits (see
"Interrupted and orphaned jobs" in `docs/install.md`). The honest
limit: parallelism overlaps
*execution*, not claiming — and jobs that edit the same working tree in
parallel can still conflict with each other, which is a reason to set the
dial to 1 for edit queues against a single checkout.

Every job ends in exactly one status, written atomically to
`outbox/<id>.status.json` in a single unified shape:
`completed`, `failed`, `rejected` (validation fired *before* the CLI ran),
`timed-out` (the runner killed the process tree), or `interrupted` (a
previous attempt crashed mid-run — jobs are at-most-once and are never
blindly re-run). Every status records `jobSha256`, the SHA-256 of the job
file's exact bytes: jobs are claimed by content hash, and every claimed
hash is kept in a per-id claim set (`outbox/archive/<id>.claims.json`), so
re-delivering identical bytes under the same id is reported "already
processed" and never runs twice — even if a different-bytes post under the
same id came in between — while posting *changed* bytes under an id is a
deliberate repost: it runs fresh, and the previous artifacts are archived
instead of overwritten.

One exception to "every job ends in a status": if an adapter's **auth
preflight** fails (the CLI is signed out in your desktop session), its jobs
are **held** — they stay in the inbox with no new status, the health file
(`outbox/_bridge-health.json`) records why, and they run on a later drain
once you sign in again. A client waiting on a held job reports a wait
timeout (exit 2), not a failure — check the health file.

A client CLI is included (`client/sessionbridge.sh`, `client/sessionbridge.ps1`)
with submit/wait/status/output and explicit exit codes — but anything that
can write a file and read JSON can be a client. Workflows built on this
contract: **[docs/examples.md](docs/examples.md)**.

## Running a small agent fleet

The bridge moves jobs; it does not organize the work. The pattern that
sits on top of it — one orchestrator, chartered builders, and designated
reviewers who never judge their own work, closed out by audit and
improvement loops — is written up in
**[docs/agent-fleet-pattern.md](docs/agent-fleet-pattern.md)**, with
copyable starter templates (a team charter, a reviewer brief, and a
build/review job pair) in **[examples/fleet/](examples/fleet/)**. Start
there if you want several agents working in parallel without giving up
the ability to believe their output.

## Project status

Pre-1.0 and Windows-first: the runner is PowerShell because the session wall
is sharpest on Windows. macOS (LaunchAgent) and Linux (systemd --user)
launchers are documented routes in
[docs/customization.md](docs/customization.md); the runner already executes
under PowerShell 7 on those platforms for testing. The test harness
(`tests/run-tests.ps1`) exercises the guards against a fake CLI — including
argument-delivery quoting, integrity refusal, auth-hold behavior,
process-tree kill, the required-mode and ceiling-dial rules in both
directions, and the parallel-drain exactly-once probes at the shipped
dial of 5 — with no real AI CLI needed.

## License

Apache-2.0. See [LICENSE](LICENSE). Contributions — especially adapters —
welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
