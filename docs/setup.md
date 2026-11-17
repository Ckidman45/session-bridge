# Connecting a client: transports

The runner only ever sees a folder. A "client" is anything that can put a
job JSON into `inbox/` and read files from `outbox/` — the transport is
whatever moves files between the client and that folder. Four routes are in
use; all of them work with the included clients
(`client/sessionbridge.sh` for bash, `client/sessionbridge.ps1` for
PowerShell). If you write your own client, the contract is in the README:
one JSON file in, one status JSON + one output text out.

Remember the security rule while choosing: **whoever can write the inbox can
run code as the bridge user.** Pick the transport whose access control you
trust.

Client prerequisites: the bash client needs `bash` and `python3` (any 3.x —
it parses the status JSON with python3) on the client machine, plus `scp` /
`ssh` for Route 2. The PowerShell client needs only PowerShell.

## Route 1 — Local folder (same machine)

The client is a script or agent running on the same machine as the runner
(outside the desktop session, e.g. an SSH session or a service).

Bash:

```bash
export SB_DIR="$HOME/session-bridge"          # the bridge root
client/sessionbridge.sh submit job.json --wait
```

PowerShell:

```powershell
client\sessionbridge.ps1 -Action submit -JobFile .\job.json -BridgeDir "$env:USERPROFILE\session-bridge" -Wait
```

Triggering: the runner fires at logon and on its 15-minute tick, so a local
job may wait up to a tick. To fire it immediately from the same machine,
start the task yourself (`Start-ScheduledTask -TaskName SessionBridge`) or
set the client aside and use Route 2's fire step over ssh.

## Route 2 — SSH / scp (client on another machine) — recommended for remote agents

The client pushes the job with `scp` and (optionally) fires the task with
`ssh`. The runner machine needs an SSH server reachable by the client
(Windows: the OpenSSH Server optional feature; any SSH setup you already
use is fine), with key-based auth for the bridge user's account.

Bash:

```bash
export SB_HOST="alex@laptop"                  # ssh target
export SB_REMOTE="C:/Users/alex/session-bridge"   # bridge root on the runner, forward slashes
export SB_TASK="SessionBridge"                # optional; this is the default
client/sessionbridge.sh submit job.json --wait
```

PowerShell:

```powershell
client\sessionbridge.ps1 -Action submit -JobFile .\job.json `
  -HostName "alex@laptop" -RemoteDir "C:/Users/alex/session-bridge" -Wait
```

Notes:

- Use forward slashes in the remote path with scp, as above — Windows
  OpenSSH + scp accept that form reliably.
- The ssh fire step runs `Start-ScheduledTask`. If your SSH session cannot
  start the task (permissions), omit firing: jobs still drain at logon and
  on the tick.
- `SB_SSH_OPTS` (bash client) passes extra ssh/scp options, e.g.
  `SB_SSH_OPTS="-i ~/.ssh/bridge_key -o ConnectTimeout=15"`.

## Route 3 — Synced folder (OneDrive, Dropbox, Syncthing, ...)

Point the client at the synced copy of the bridge root with `SB_DIR` /
`-BridgeDir`, and let the sync tool carry the files. Works with zero network
configuration.

Caveats, honestly:

- **Latency and conflicts:** a job is only visible to the runner after the
  sync uploads it; results likewise. Sync conflict copies (`job (1).json`)
  are **not executed**: the runner skips inbox files whose names are not
  safe job ids. Jobs are claimed by content hash (`jobSha256` in every
  status, persisted per id in `outbox\archive\<id>.claims.json`), so a copy
  that arrives again — in the same drain or a later one, even after other
  posts under the same id — under the *same* id with identical bytes is
  reported "already processed"
  and never runs twice. But a conflict copy that a sync tool (or a helpful
  human) renames to a *different* safe id is a new claim, indistinguishable
  from a deliberate repost, and will run — check the inbox if a job seems
  lost, and prefer the SSH route for anything beyond read-only jobs.
- **Content exposure:** prompts and model output sync through the provider.
  Do not use this route for sensitive codebases unless you accept that.
- **Firing:** there is no remote fire step; rely on the logon trigger and
  the 15-minute tick, or combine with Route 2's ssh fire.

## Route 4 — Network share (SMB)

Host the bridge root on a share the client can mount, then use the local
folder route with the share path:

```bash
export SB_DIR="/mnt/bridge/session-bridge"    # mounted share
```

or on a Windows client, `-BridgeDir "\\FILESERVER\bridge\session-bridge"`.

The share's ACLs are the whole security story on this route: grant write
access to the inbox **only** to the accounts that should be able to run
jobs. Never expose the share anonymously or beyond your LAN/VPN.

## Parallel drains (all routes)

Whichever transport you use, one drain executes up to `maxConcurrency`
jobs at the same time — **default 5**, configured in
`sessionbridge.config.json` (see `docs/customization.md`). Claiming and
validation stay serial, in inbox order; only the CLI executions overlap.
The exactly-once guarantees do not change at any setting of the dial:
identical bytes never run twice however they arrive, and two jobs under
one id never execute simultaneously while the runner lives — the second
defers to a later pass of the same drain and runs there. If the runner
is killed mid-job, the orphaned CLI keeps running and the bridge
deliberately will not start a same-id job until it exits; the bridge
never kills orphans itself (see "Interrupted and orphaned jobs" in
`docs/install.md`). Set the dial to **1** if you want the
old fully serial behavior, and prefer 1 for job streams whose jobs edit
the same working tree, since parallel CLIs cannot merge each other's
edits. Every job must declare its `mode` explicitly (there is no
default); the included clients refuse to submit a job that does not.

One scheduling honesty note: execution is **batched**. Jobs are claimed
in inbox order and started in batches of up to `maxConcurrency`; the
next batch starts only when the current batch completes. A batch's own
jobs never wait on each other, but one long job can hold back the
*following* batch — mixed workloads drain in waves, not as a continuous
flow. If you run one very long job alongside many short ones, expect
the short ones queued behind it to start in the next wave.

## Choosing

| Route | Latency | Setup | Trust requirement |
|---|---|---|---|
| Local folder | tick-bound | none | same machine |
| SSH / scp | seconds (with fire) | SSH server + key | your SSH key management |
| Synced folder | sync-bound | a sync account | the sync provider sees job content |
| Network share | tick-bound | a share + ACLs | your share ACLs |

Whichever you pick, test the full round trip with the smoke job from
`docs/install.md` before sending real work.
