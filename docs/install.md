# Installing SessionBridge (Windows)

This guide takes a stranger from nothing to a verified working bridge.
Everything runs as your normal user account — no administrator rights are
needed except whatever your coding CLI's own installer required.

## 1. Prerequisites

- **Windows 10 or 11**, with Windows PowerShell 5.1 (it ships with Windows;
  check with `$PSVersionTable.PSVersion` in a PowerShell window).
- **At least one supported coding CLI** (see the adapter table in the
  README), installed by its vendor's instructions.
- **That CLI signed in, interactively, on this machine.** This is the step
  people skip, and it is the whole point of the bridge: open a terminal in
  your normal desktop session, run the CLI once, complete its sign-in flow,
  and confirm it answers a trivial prompt. SessionBridge reuses that
  session-bound sign-in; it has no credentials of its own and cannot sign in
  for you.

## 2. Get the code

```powershell
git clone <this-repo> session-bridge-src
cd session-bridge-src
```

(Or download the repository ZIP from GitHub and extract it.)

## 3. Install

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\install.ps1
```

Options: `-TargetRoot <path>` (default `%USERPROFILE%\session-bridge`),
`-TaskName <name>` (default `SessionBridge`), `-TickMinutes <n>` (default
15 — how often the task self-heals a missed trigger).

The installer:

1. Creates the bridge root with `inbox\`, `outbox\`, `done\`, `adapters\`.
2. Copies the runner (`sessionbridge.ps1`) and the adapters into it (the
   `generic.example.json` template is not installed — it is a starting point
   for writing your own, not a runnable adapter).
3. Seeds `sessionbridge.config.json` from the example config **only if none
   exists** (reinstalling never overwrites your config). The example config
   sets a `readonly` mode ceiling (your dial — raise it or remove it as you
   see fit; see `docs/customization.md`) and `maxConcurrency` 5 (up to five
   jobs execute at once per drain; set 1 for serial).
4. Records an integrity manifest in `sessionbridge.expected.sha256`: one
   SHA-256 per covered file — the runner, the config, and every installed
   adapter. The runner verifies the whole manifest on every start and
   refuses to run if anything differs, is missing, or is not listed — so if
   you edit the installed runner, config, or an adapter, re-run the
   installer to re-record the manifest. Adding a **new** adapter to an
   installed bridge works the same way: place the adapter file in the
   source tree's `adapters\` folder and re-run the installer (see
   "Adding an adapter" in `docs/customization.md`).
5. Registers the **SessionBridge** scheduled task: principal = you,
   LogonType Interactive (it can only run in your desktop session), triggers
   at logon and every 15 minutes, `IgnoreNew` (one runner at a time),
   StartWhenAvailable, allowed to start on batteries.

## 4. Smoke test

Create `smoke-001.json` (adjust `adapter` to a CLI you actually signed in):

```json
{
  "id": "smoke-001",
  "adapter": "antigravity",
  "prompt": "Reply with exactly: bridge smoke ok",
  "mode": "readonly"
}
```

Copy it into the inbox, **wait about 10 seconds**, then fire the task. The
wait matters: the runner ignores inbox files younger than 5 seconds (a
"still copying" guard against reading a half-written job), and an
invocation that finds nothing it may process exits silently — so a task
fired the instant the copy lands can appear to do nothing. If no status
file appears after a first fire, wait a few seconds and fire again; firing
again is harmless.

```powershell
Copy-Item .\smoke-001.json "$env:USERPROFILE\session-bridge\inbox\"
Start-Sleep -Seconds 10
Start-ScheduledTask -TaskName SessionBridge
# A first drain includes the CLI's version and sign-in probes, and the model
# call itself - poll for the status file instead of guessing a fixed wait.
while (-not (Test-Path "$env:USERPROFILE\session-bridge\outbox\smoke-001.status.json")) { Start-Sleep -Seconds 5 }
Get-Content "$env:USERPROFILE\session-bridge\outbox\smoke-001.status.json"
Get-Content "$env:USERPROFILE\session-bridge\outbox\smoke-001.out.txt"
```

Success looks like `"state": "completed"`, `"exitCode": 0`, and
`bridge smoke ok` in the output file.

## 5. Verify the health record

After any drain, `outbox\_bridge-health.json` shows what the runner found:

```json
{
  "checkedAt": "2026-01-01T12:00:00Z",
  "runnerVersion": "0.3.2",
  "integrityOk": true,
  "maxConcurrency": 5,
  "modeCeiling": "readonly",
  "adapters": {
    "antigravity": { "version": "1.5.9", "authOk": true, "detail": "auth probe ok" }
  }
}
```

- `integrityOk: false` — a covered file (runner, config, or an adapter)
  changed since install, or an unlisted adapter appeared. The `detail`
  field names the file. If that was you, re-run `install.ps1`. If it was
  not you, stop and investigate.
- `authOk: false` for an adapter — its CLI is not signed in *in your desktop
  session* (or its sign-in expired). Jobs for that adapter are **held** (left
  in the inbox), not failed. Sign in interactively, then fire the task again.
- `authOk: null` — the adapter defines no auth check (e.g. API-key CLIs), or
  the probe timed out. See the `detail` field.
- `maxConcurrency` / `modeCeiling` — the active dials from your config
  (how many jobs execute at once per drain; the mode ceiling in force,
  `null` when you have set none), so you can confirm the policy a drain
  actually ran under without reading the config and the manifest.

## 6. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Job sits in `inbox\` forever | You are logged off (the task can only run in your session), or the task is disabled. Log in; check `Get-ScheduledTask -TaskName SessionBridge`. |
| Status `rejected` | Validation fired — read the `error` field: missing `mode` (every job must declare one explicitly), over-ceiling mode, cwd outside the allowlist, unsafe model/effort value, unknown adapter. |
| You raised the ceiling and reposted the same job file, and nothing ran | The rejected post already claimed its bytes (at-most-once): the identical file is now "already processed" by design. Resubmit with a **new id** (or any byte change). |
| Status `failed` with sign-in text in the output | The CLI's sign-in expired mid-drain. Sign in interactively and repost. |
| Status `interrupted` | A previous attempt crashed mid-run (reboot, killed runner). The job was **not** re-run on purpose. Check `runner.log`, then repost **with changed content** if you still want it — reposting the identical file is claimed by its content hash (`jobSha256`) and reported "already processed" instead of running again. |
| No status file and no `runner.log` entry after firing the task | The job file was younger than the runner's 5-second copy-settling guard when the runner took its inbox snapshot, so that invocation skipped it silently and logged nothing. The job has **not** been lost or rejected. Wait a few seconds and fire the task again (`Start-ScheduledTask -TaskName SessionBridge`). |
| Nothing in `runner.log` at all | The task has never fired while you are logged in — or every invocation so far found an empty (or still-copying) inbox and exited before logging anything: the runner only logs when there is work, a refusal, or a lock contention. Put a job in the inbox, run the runner directly once (`powershell -File %USERPROFILE%\session-bridge\sessionbridge.ps1`), and read `runner.log` and `outbox\_bridge-health.json`. |
| Job ran but `outputSuspect: true` | The CLI exited 0 while printing what looks like an error. Treat the result as unverified. |
| A same-id job sits in `inbox\` after a crash, and `runner.log` shows `ORPHAN:` (or `ORPHAN-UNKNOWN:`) | The previous attempt's CLI outlived the killed runner — an orphan. The bridge is deliberately waiting it out; see "Interrupted and orphaned jobs" below. |

### Interrupted and orphaned jobs

The "two jobs under one id never execute at the same time" guarantee
holds **while the runner lives** — a per-job execution lock sees to
that. A crash is the one case the lock cannot cover: if the runner is
killed mid-job (or the machine stops), the job's CLI process may keep
running on its own. That leftover process is an **orphan**, and the
bridge handles it deliberately:

- The next drain finds the previous attempt's `running` status, which
  records the CLI's process id (`cliPid`). While that pid is alive, the
  drain logs an `ORPHAN:` line in `runner.log` naming the job id and
  pid, and leaves every same-id job **queued and unclaimed** — nothing
  starts over a live orphan.
- If the runner died in the instant before the pid could be recorded,
  the `running` status has no `cliPid`. While such a status is younger
  than the job's timeout window, the attempt is treated as possibly
  alive and same-id work defers the same way, logged as
  `ORPHAN-UNKNOWN:`. Only a pid-less `running` status **older** than
  that window is treated as certainly dead.
- What resolves it: the orphan exits (on its own, or because you end
  it). The next drain then resolves the original attempt as
  `interrupted` — visible in the archived status — and the queued
  same-id job runs normally, exactly once.
- The bridge **never kills an orphan itself**. It did not start that
  process in this drain, and it will not guess: waiting is the safe
  failure mode, and a queued job is recoverable while a wrongly killed
  process is not. If an orphan is genuinely stuck, end it yourself
  (Task Manager, or `Stop-Process -Id <pid>` with the pid from the
  `ORPHAN:` line) and fire the task again.

So after a crash, a same-id job sitting in the inbox alongside
`ORPHAN:` log lines is the bridge working as designed — not a hang.

## 7. Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\uninstall.ps1
```

Removes the scheduled task. Your bridge root (job history, results, logs)
is kept unless you add `-RemoveData`. Your CLIs and their sign-ins are never
touched by install or uninstall.
