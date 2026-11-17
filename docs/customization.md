# Customization

Everything in SessionBridge is a file: policy is JSON, adapters are JSON,
and the job contract is JSON. This page lists the routes, labeled honestly:

- **Built-in** — shipped and tested now.
- **Extension point** — the seam exists; you write a small piece.
- **Roadmap** — documented direction, not yet built.

## Safety-policy knobs (built-in)

`sessionbridge.config.json` in the bridge root (seeded by the installer):

| Key | Default | Meaning |
|---|---|---|
| `modeCeiling` | `readonly` in the shipped example; **no ceiling** if the key is omitted or set to `null` / `"none"` / `"open"` | The owner's dial on job modes. Every job declares its `mode` explicitly (a missing mode is rejected — there is no default). For the common scale the ceiling is a highest-mode cap: `readonly` < `accept-edits` < `auto`, and jobs above it are rejected. An adapter-specific mode name used as the ceiling is **not** a rank — it acts as an exact-match pin: only that one mode runs, and everything else (ranked or not) is rejected. Comparisons are case-insensitive in practice (mode and ceiling matching ignore case); the mode a job declares is recorded in its status verbatim. With no ceiling, any mode an adapter defines is available to any job that declares it — fully open is a legitimate owner choice. |
| `maxConcurrency` | 5 | How many jobs one drain executes at the same time. Claiming and validation always stay serial and in inbox order; only CLI execution overlaps, and two jobs under one id never overlap while the runner lives (the second defers to a later pass). If the runner is killed mid-job, the orphaned CLI keeps running and a same-id job stays queued until it exits — the bridge never kills orphans (see "Interrupted and orphaned jobs" in `docs/install.md`). Set 1 for a fully serial drain — the right choice for job streams that edit the same working tree. Range 1–32. |
| `allowedCwdRoots` | `["%USERPROFILE%"]` | A job's `cwd` must exist and sit under one of these roots. |
| `maxJobsPerDrain` | 10 | Jobs per runner invocation; the rest stay queued. |
| `maxDrainMinutes` | 90 | Wall-clock cap per drain. |
| `defaultTimeoutSec` / `minTimeoutSec` / `maxTimeoutSec` | 600 / 10 / 1800 | Per-job timeout bounds. The runner enforces the timeout and kills the process tree. |
| `retentionDays` | 30 | Outbox artifacts older than this are archived (daily pass); archived artifacts and done job files older than this are deleted, so disk use stays bounded. |
| `logRotateBytes` | 1048576 | `runner.log` rotation size (newest 3 rotations kept). |
| `authProbeTimeoutSec` | 20 | Budget for each adapter's auth check. |
| `promptMaxChars` | 200000 | Maximum prompt size. |
| `outputCapBytes` | 52428800 | Captured stdout+stderr per job; a CLI that produces more is killed and the job fails. Stored artifacts are additionally truncated at 1,000,000 chars per stream. |

Editing the config (or an adapter) changes its hash: re-run `install.ps1`
afterwards to re-record the integrity manifest, or the runner will refuse
to run. A malformed config fails closed — the runner logs a `CONFIG ERROR`,
records it in the health file, and runs nothing.

**Raising the ceiling does not revive an already-rejected job.** A
rejected post claims its bytes (jobs are at-most-once, claimed before
validation), so after you raise the ceiling, resubmitting the *identical*
file is reported "already processed" and silently does nothing. Resubmit
with a **new id** (or any byte change — a comment in the prompt is
enough) and the job runs under the new ceiling.

## Profiles: separate bridges for separate trust levels (built-in pattern)

The ceiling on your main bridge is yours to raise — or remove — whenever
you trust its inbox writers; the bridge does not require separation. A
second bridge still buys you real things when you want them: a separate
audit trail, a separate root you can ACL differently, and a separate task
you can disable independently. Install one with its own root, task, and
ceiling:

```powershell
# Read-only review bridge (already installed by default)
powershell -File windows\install.ps1 -TargetRoot "$env:USERPROFILE\session-bridge-review" -TaskName SessionBridgeReview

# Edit-enabled build bridge, deliberately separate
powershell -File windows\install.ps1 -TargetRoot "$env:USERPROFILE\session-bridge-build" -TaskName SessionBridgeBuild
# then edit session-bridge-build\sessionbridge.config.json: "modeCeiling": "accept-edits"
# and RE-RUN the installer for that root, so the integrity manifest covers the edited config:
powershell -File windows\install.ps1 -TargetRoot "$env:USERPROFILE\session-bridge-build" -TaskName SessionBridgeBuild
```

Clients pick the profile by pointing at its root (`SB_DIR` / `SB_REMOTE` /
`-BridgeDir`) and, for the ssh route, its task name (`SB_TASK`).

## Adding an adapter (extension point — the main one)

1. Copy `adapters/generic.example.json` to `adapters/<your-cli>.json`. The
   filename (minus `.json`) is the adapter id jobs will use.
2. Verify every flag against the CLI's own `--help` or vendor docs. Do not
   guess: an adapter is a promise about someone else's CLI.
3. Fill in:
   - `executable.names` (looked up on PATH) and/or `executable.paths`
     (checked first; `%ENVVAR%` expansion supported).
   - `versionArgs` — prints a version, exits 0.
   - `authCheck.args` — a cheap command that exits 0 iff signed in (no model
     calls). If the CLI has none, set `authCheck: null` and explain in
     `notes`; the runner then skips preflight for that adapter and says so
     in the health record.
   - `promptDelivery`:
     - `"stdin"` — the CLI reads the whole prompt from stdin in its
       noninteractive mode (preferred; nothing is ever placed on a command
       line).
     - `"argument"` — the CLI only accepts a prompt argument. Set
       `invoke.promptArgs` to show where it goes, e.g. `["{prompt}"]` or
       `["--message", "{prompt}"]`. The runner passes it as **one quoted
       argument**.
   - `invoke.baseArgs` — flags that always precede the mode flags (e.g. a
     `run` or `exec` subcommand, an output-format flag).
   - `invoke.cliTimeoutArg` / `cliTimeoutSuffix` — optional: if the CLI has
     its own timeout flag, the runner sets it 20s past the job budget so the
     runner's kill remains the single timeout authority.
   - `modes` — map the common scale to the CLI's flags:
     - `readonly` **must not be able to edit files.** If the CLI cannot
       guarantee that, omit the key.
     - `accept-edits` — file edits allowed, no blanket command approval if
       the CLI can express that.
     - `auto` — the CLI's most autonomous mode. If that mode is unsandboxed,
       say so in `notes` in plain words.
     - Omit any tier the CLI cannot express; jobs asking for it are
       rejected, which is correct.
   - `modelArgs` / `effortArgs` — arrays containing one `"{value}"`
     placeholder, e.g. `["--model", "{value}"]`. `efforts` lists permitted
     values, or `null` for free-form (still pattern-checked: no leading
     `-`, no spaces, so a value can never become a flag).
4. Set `status`: `verified` (facts sourced from vendor docs or a live
   binary, sources listed), `community` (documented but the mapping is your
   inference or untested end-to-end), `unverified` (a stub — fine for local
   experiments, not for sharing).
5. Re-run `windows\install.ps1` to copy the adapter into the bridge root,
   then smoke-test it with a read-only job.

**Adding an adapter to an already-installed bridge:** the runner's
integrity manifest covers every installed adapter by hash, and the runner
refuses to run if an adapter appears that the manifest does not list. So
do not drop the new file into the bridge root's `adapters\` folder
directly — it will be treated as tampering, not as an addition. Place the
adapter file in the **source tree's** `adapters\` folder and re-run
`windows\install.ps1`; the installer copies it into the bridge root and
re-records the manifest. Editing an installed adapter works the same way:
edit the source-tree copy and re-run the installer.

### Worked example: a fictional CLI

`acme-code` documents: `acme run --ask "prompt"` for one-shot runs,
`--level read|write|full` for permissions, `--m` for model, `acme whoami`
(exit 0 when signed in), `acme --version`. Its adapter:

```json
{
  "id": "acme-code",
  "displayName": "Acme Code (fictional example)",
  "status": "community",
  "executable": { "names": ["acme.exe", "acme"], "paths": [] },
  "versionArgs": ["--version"],
  "authCheck": { "args": ["whoami"], "timeoutSec": 15 },
  "promptDelivery": "argument",
  "invoke": { "baseArgs": ["run"], "promptArgs": ["--ask", "{prompt}"] },
  "modes": {
    "readonly": ["--level", "read"],
    "accept-edits": ["--level", "write"],
    "auto": ["--level", "full"]
  },
  "modelArgs": ["--m", "{value}"],
  "effortArgs": null,
  "efforts": null,
  "sources": ["(the CLI's docs, if this were real)"],
  "notes": "Fictional; shown to illustrate the shape."
}
```

## Changing the transport (built-in)

The runner doesn't know transports exist. Any mechanism that delivers files
to the bridge root works — see `docs/setup.md` for the local, SSH/scp,
synced-folder, and network-share routes with exact client configuration.
A custom client needs to do exactly three things: write `<id>.json` into
`inbox/`, optionally fire the task, and read `outbox/<id>.status.json` +
`outbox/<id>.out.txt`. The included clients additionally ignore stale
statuses from earlier runs of the same id; copy that guard if you write
your own (compare the status's `startedAt` with when you submitted).

## Per-OS session launchers

- **Windows (built-in):** `windows/install.ps1` registers the scheduled
  task described in `docs/install.md`.
- **macOS (extension point):** the runner is a PowerShell script, and
  PowerShell 7 runs on macOS — the missing piece is only the launcher. A
  LaunchAgent in `~/Library/LaunchAgents` runs inside your GUI session
  (where the keychain lives), which is exactly the session the CLIs sign in
  to. A minimal plist that fires the runner every 15 minutes and at login:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
    <key>Label</key><string>io.sessionbridge.runner</string>
    <key>ProgramArguments</key>
    <array>
      <string>/usr/local/bin/pwsh</string>
      <string>-NoProfile</string><string>-File</string>
      <string>/Users/alex/session-bridge/sessionbridge.ps1</string>
    </array>
    <key>StartInterval</key><integer>900</integer>
    <key>RunAtLoad</key><true/>
  </dict></plist>
  ```

  Copy the runner, adapters, and config into `/Users/alex/session-bridge`
  first, and record the hash the same way `install.ps1` does
  (`Get-FileHash` → `sessionbridge.expected.sha256`). This route is
  documented but not yet packaged as an installer — that's the roadmap.
- **Linux (extension point):** same pattern with a `systemd --user`
  service + timer (user services run in your desktop session for
  keyring-bound CLIs), invoking `pwsh -File sessionbridge.ps1`. Also
  roadmap as a packaged installer.

## Signed jobs (extension point, not built-in)

If jobs ever cross a folder you don't fully control, add verification:
a `signature` field in the job (HMAC-SHA256 of the canonical job JSON,
keyed by a secret file that lives *outside* the synced/shared folder),
checked by a small pre-runner step that deletes unsigned jobs before the
runner sees them. The seam is deliberate — jobs are self-contained JSON and
the inbox is a plain folder — but no signing code ships in v0.1, and the
threat model in `SECURITY.md` does not assume it. Treat any folder an
untrusted party can write as hostile, signed or not, until you've built
and tested this yourself.

## Roadmap

Packaged macOS/Linux installers; a first-party HMAC job-signing option;
per-adapter job caps; a `--once` runner flag for cron-style launches
(the runner already exits when the inbox is empty, so cron works today —
only the packaging is missing).
