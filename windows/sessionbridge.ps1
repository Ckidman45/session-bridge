# SessionBridge runner - runs AI coding CLI jobs inside the user's interactive session.
# Jobs arrive as JSON files in inbox\; results land in outbox\; finished jobs archive to done\.
# Invoked by the SessionBridge scheduled task (see install.ps1), or directly for testing.
# Windows PowerShell 5.1 compatible. Plain ASCII only.
#
# Design notes (see docs/ and SECURITY.md):
# - Prompts reach the CLI on stdin, or as ONE quoted argument for CLIs that only
#   accept an argument prompt. Job fields are never shell-interpolated.
# - Mode is a REQUIRED, explicit per-job declaration: a job without a mode is
#   rejected, never silently defaulted. Mode/effort/model values are validated
#   against per-adapter allowlists. A config mode ceiling, WHEN THE OWNER SETS
#   ONE, caps how much autonomy any job may request; with no ceiling set the
#   full range each adapter defines is available (the owner's dial, not the
#   bridge's restriction - see SECURITY.md).
# - Jobs run in parallel up to the config maxConcurrency dial (default 5).
#   Claiming and validation stay serial, in inbox order, under per-id claim
#   locks; only CLI execution overlaps, and two jobs under one id never
#   execute at the same time while the runner lives (per-job execution
#   locks). If the runner is killed mid-job, its CLI may outlive it as an
#   orphan: the next drain detects it (the recorded cliPid, or a fresh
#   pid-less 'running' status inside its timeout window) and defers
#   same-id work until it exits - the bridge never kills an orphan.
# - Jobs are at-most-once, claimed by CONTENT HASH (content-hash claiming
#   ported from AgyBridge v2.2; claim-set persistence added by the GAP-B4
#   Improvement Loop, runner 0.2.3): every status records the job file's
#   SHA-256 as jobSha256, and every claimed hash is also appended to a
#   per-id claim SET (outbox\archive\<id>.claims.json) BEFORE validation -
#   a set, not the single slot of the live status, so an intervening
#   different-bytes post (even a rejected or malformed one) can never evict
#   an earlier claim, and retention cannot expire one. Identical bytes
#   under an id never run twice; changed bytes under the same id are a
#   deliberate repost. A job left in 'running' state by a crash, with the
#   same hash, is recorded 'interrupted' and never blindly re-run. The job
#   file is archived BEFORE the final status is written, on every path, so
#   no crash window can leave a completed job looking unclaimed in the
#   inbox.

$ErrorActionPreference = 'Stop'
$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$inbox      = Join-Path $root 'inbox'
$outbox     = Join-Path $root 'outbox'
$doneDir    = Join-Path $root 'done'
$adapterDir = Join-Path $root 'adapters'
$logFile    = Join-Path $root 'runner.log'
$lockFile   = Join-Path $root 'bridge.lock'
$hashFile   = Join-Path $root 'sessionbridge.expected.sha256'
$healthFile = Join-Path $outbox '_bridge-health.json'
$configFile = Join-Path $root 'sessionbridge.config.json'
$utf8       = New-Object Text.UTF8Encoding($false)
$runnerPathSelf = $MyInvocation.MyCommand.Path
$RUNNER_VERSION = '0.3.2'

$ID_PATTERN    = '^[A-Za-z0-9._\-]+$'
$MODEL_PATTERN = '^[A-Za-z0-9._][A-Za-z0-9._\-/]*$'
$VALUE_PATTERN = '^[A-Za-z0-9._\-]+$'
$KNOWN_FIELDS  = @('id','adapter','prompt','cwd','mode','model','effort','timeoutSec','author','charter','requestedBy')
$MODE_RANK     = @{ 'readonly' = 0; 'accept-edits' = 1; 'auto' = 2 }

# ---- Config (sessionbridge.config.json; every key optional) ----
# Loading FAILS CLOSED: a config that does not parse, or holds a value of the
# wrong shape, is a hard refusal (logged + health record), never a silent
# fallback to defaults - the config is the user's safety policy.
$cfg = @{
    # modeCeiling $null means NO ceiling (fully open): the dial belongs to
    # the owner. The shipped example config sets 'readonly' for strangers;
    # a config that omits the key, or sets it to null / 'none' / 'open',
    # runs with no ceiling. See docs/customization.md.
    modeCeiling        = $null
    maxConcurrency     = 5
    allowedCwdRoots    = @($env:USERPROFILE)
    maxJobsPerDrain    = 10
    maxDrainMinutes    = 90
    maxTimeoutSec      = 1800
    defaultTimeoutSec  = 600
    minTimeoutSec      = 10
    retentionDays      = 30
    logRotateBytes     = 1048576
    authProbeTimeoutSec = 20
    promptMaxChars     = 200000
    outputCapBytes     = 52428800
}
$configError = $null
if (Test-Path $configFile) {
    try {
        $raw = [IO.File]::ReadAllText($configFile, $utf8) | ConvertFrom-Json
        if ($null -eq $raw -or $raw -isnot [PSCustomObject]) { throw 'config root must be a JSON object' }
        if ($null -ne $raw.modeCeiling) {
            if ($raw.modeCeiling -isnot [string]) { throw 'modeCeiling must be a string, null, or omitted' }
            $mc = $raw.modeCeiling.Trim().ToLower()
            if ($mc -eq '' -or $mc -eq 'none' -or $mc -eq 'open' -or $mc -eq 'off' -or $mc -eq 'unlimited') { $cfg.modeCeiling = $null }
            else { $cfg.modeCeiling = $raw.modeCeiling }
        }
        foreach ($k in @('maxJobsPerDrain','maxDrainMinutes','maxTimeoutSec','defaultTimeoutSec','minTimeoutSec','retentionDays','logRotateBytes','authProbeTimeoutSec','promptMaxChars','outputCapBytes','maxConcurrency')) {
            if ($null -ne $raw.$k) {
                $v = $raw.$k
                if ($v -isnot [int] -and $v -isnot [long] -and $v -isnot [double]) { throw "$k must be a number" }
                if ($v -is [double] -and [double]$v -ne [math]::Floor([double]$v)) { throw "$k must be a whole number" }
                $cfg[$k] = [int]$v
            }
        }
        if ($null -ne $raw.allowedCwdRoots) {
            $roots = @($raw.allowedCwdRoots)
            if ($roots.Count -eq 0) { throw 'allowedCwdRoots must not be empty' }
            foreach ($r in $roots) { if ($r -isnot [string]) { throw 'allowedCwdRoots entries must be strings' } }
            $cfg.allowedCwdRoots = @($roots | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) })
        }
    } catch { $configError = $_.Exception.Message }
}
if (-not $configError) {
    if ($null -ne $cfg.modeCeiling -and ([string]$cfg.modeCeiling) -notmatch '^[A-Za-z0-9._\-]+$') { $configError = "modeCeiling '$($cfg.modeCeiling)' contains unsafe characters (use readonly, accept-edits, auto, an adapter mode name, or none/open for no ceiling)" }
    elseif ([int]$cfg.maxConcurrency -lt 1 -or [int]$cfg.maxConcurrency -gt 32) { $configError = 'maxConcurrency must be between 1 and 32' }
    elseif ([int]$cfg.maxJobsPerDrain -lt 1 -or [int]$cfg.maxDrainMinutes -lt 1 -or [int]$cfg.minTimeoutSec -lt 1 -or
            [int]$cfg.maxTimeoutSec -lt [int]$cfg.minTimeoutSec -or [int]$cfg.defaultTimeoutSec -lt 1 -or
            [int]$cfg.retentionDays -lt 1 -or [int]$cfg.logRotateBytes -lt 1024 -or [int]$cfg.authProbeTimeoutSec -lt 1 -or
            [int]$cfg.promptMaxChars -lt 1 -or [int64]$cfg.outputCapBytes -lt 1024) { $configError = 'one or more numeric config values are out of range' }
}
if ($configError) {
    try { Add-Content -Path $logFile -Value ("{0}Z CONFIG ERROR: {1}; refusing to run (fix or delete sessionbridge.config.json)" -f (Get-Date).ToUniversalTime().ToString('s'), $configError) -Encoding UTF8 } catch {}
    try {
        if (-not (Test-Path $outbox)) { New-Item -ItemType Directory -Path $outbox | Out-Null }
        $healthJson = ([ordered]@{ checkedAt = (Get-Date).ToUniversalTime().ToString('o'); runnerVersion = $RUNNER_VERSION; integrityOk = $null; configOk = $false; maxConcurrency = [int]$cfg.maxConcurrency; modeCeiling = $cfg.modeCeiling; adapters = @{}; detail = "config error: $configError" } | ConvertTo-Json -Depth 5)
        [IO.File]::WriteAllText($healthFile, $healthJson, $utf8)
    } catch {}
    exit 1
}
$allowedRoots = @($cfg.allowedCwdRoots | ForEach-Object { [IO.Path]::GetFullPath([string]$_).TrimEnd('\') })

function Log($msg) {
    Add-Content -Path $logFile -Value ("{0}Z {1}" -f (Get-Date).ToUniversalTime().ToString('s'), $msg) -Encoding UTF8
}

function WriteAtomic($path, $text) {
    $tmp = "$path.tmp$PID"
    [IO.File]::WriteAllText($tmp, $text, $utf8)
    Move-Item $tmp $path -Force
}

function WriteStatus($id, $fields) {
    WriteAtomic (Join-Path $outbox "$id.status.json") ($fields | ConvertTo-Json -Depth 5)
}

function WriteHealth($fields) {
    try { WriteAtomic $healthFile ($fields | ConvertTo-Json -Depth 5) } catch {}
}

function KillTree($procId) {
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        try {
            $tk = Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', "$procId", '/T', '/F') -NoNewWindow -PassThru -ErrorAction Stop
            [void]$tk.WaitForExit(10000)
            return
        } catch {}
    }
    # Non-Windows fallback (the test environment): kill descendants first via
    # pgrep -P, then the process itself - a bare direct kill would orphan the
    # CLI's children.
    try {
        $kids = & pgrep -P $procId 2>$null
        foreach ($k in @($kids)) { if ($k) { KillTree ([int]$k) } }
    } catch {}
    try { (Get-Process -Id $procId -ErrorAction Stop).Kill() } catch {}
}

# Correct Win32 command-line quoting (CommandLineToArgvW rules): a backslash
# is literal except before a double quote or the closing quote, where it must
# be doubled; an embedded quote is emitted as \" with any preceding
# backslashes doubled. Getting this wrong both corrupts ordinary prompts
# (quotes eaten) and lets a crafted prompt split into separate argv tokens.
function Quote-Arg($s) {
    $s = [string]$s
    if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { return $s }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '\') { $bs++ }
        elseif ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0 }
        else { if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }; [void]$sb.Append($ch) }
    }
    [void]$sb.Append('\' * ($bs * 2))
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Resolve a path through junctions/symlinks so the cwd allowlist compares
# the path the CLI will actually run in - not a string that merely starts
# with an allowed root. The walk is queue-based: when a component turns out
# to be a link, its target's components are pushed back onto the queue and
# walked too (a junction INSIDE a link target must not escape resolution),
# with a hop cap against link loops.
function Resolve-FinalPath($path) {
    try {
        $full = [IO.Path]::GetFullPath($path)
        $rootPart = [IO.Path]::GetPathRoot($full)
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        foreach ($seg in ($full.Substring($rootPart.Length) -split '[\\/]' | Where-Object { $_ -ne '' })) { $queue.Enqueue($seg) }
        $cur = $rootPart.TrimEnd('\')
        if (-not $cur) { $cur = $rootPart }
        $hops = 0
        while ($queue.Count -gt 0) {
            $seg = $queue.Dequeue()
            $cur = Join-Path $cur $seg
            $item = Get-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
            if ($item -and $item.LinkType -and $item.Target) {
                $hops++
                if ($hops -gt 20) { break }
                $target = [string](@($item.Target)[0])
                if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $cur) $target }
                $target = [IO.Path]::GetFullPath($target)
                $tRoot = [IO.Path]::GetPathRoot($target)
                $rest = @($queue.ToArray())
                $queue.Clear()
                foreach ($tseg in ($target.Substring($tRoot.Length) -split '[\\/]' | Where-Object { $_ -ne '' })) { $queue.Enqueue($tseg) }
                foreach ($r in $rest) { $queue.Enqueue($r) }
                $cur = $tRoot.TrimEnd('\')
                if (-not $cur) { $cur = $tRoot }
            }
        }
        return $cur.TrimEnd('\')
    } catch { return [IO.Path]::GetFullPath($path).TrimEnd('\') }
}

# Runs a process with byte-level stdin/stdout/stderr control. The capture
# is split into Start/Poll/Finish so a drain can keep up to maxConcurrency
# CLI processes in flight at once (cooperative polling in this one runner
# process - claiming stays serial, only execution overlaps). InvokeCapture
# remains as the blocking form for the short version/auth probes.
function StartCapture($fileName, $argList, $stdinText, $timeoutSec, $workDir) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $fileName
    $psi.Arguments = (($argList | ForEach-Object { Quote-Arg $_ }) -join ' ')
    if ($workDir) { $psi.WorkingDirectory = $workDir }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outMs = New-Object IO.MemoryStream
    $errMs = New-Object IO.MemoryStream
    $outCopy = $proc.StandardOutput.BaseStream.CopyToAsync($outMs)
    $errCopy = $proc.StandardError.BaseStream.CopyToAsync($errMs)
    $stdinTask = $null
    $stdinClosed = $false
    if ($null -ne $stdinText) {
        $bytes = $utf8.GetBytes($stdinText)
        if ($bytes.Length -eq 0) {
            try { $proc.StandardInput.Close() } catch {}
            $stdinClosed = $true
        } else {
            $stdinTask = $proc.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
        }
    }
    return @{
        proc = $proc; outMs = $outMs; errMs = $errMs; outCopy = $outCopy; errCopy = $errCopy
        stdinTask = $stdinTask; stdinClosed = $stdinClosed; timeoutSec = $timeoutSec
        timedOut = $false; outputLimit = $false; sw = [Diagnostics.Stopwatch]::StartNew()
    }
}

function FinishCapture($h) {
    $proc = $h.proc
    try { $proc.WaitForExit() } catch {}
    try { $proc.StandardInput.Close() } catch {}
    if ($h.stdinTask) { try { [void]$h.stdinTask.Wait(250) } catch {} }
    try { [void]$h.outCopy.Wait(1000) } catch {}
    try { [void]$h.errCopy.Wait(1000) } catch {}
    return @{
        exitCode = if ($h.timedOut) { -1 } else { $proc.ExitCode }
        timedOut = $h.timedOut
        outputLimit = $h.outputLimit
        stdout   = $utf8.GetString($h.outMs.ToArray())
        stderr   = $utf8.GetString($h.errMs.ToArray())
    }
}

# Non-blocking step for one in-flight capture: returns the result hashtable
# once the process has exited (or has been killed for timeout/output cap),
# or $null while it is still running.
function PollCapture($h) {
    $proc = $h.proc
    # CLIs that read a prompt from stdin read until EOF: once the write has
    # drained into the pipe, close stdin so the run can actually start.
    if ($h.stdinTask -and -not $h.stdinClosed -and ($h.stdinTask.IsCompleted -or $h.stdinTask.IsFaulted)) {
        try { $proc.StandardInput.Close() } catch {}
        $h.stdinClosed = $true
    }
    if ($proc.HasExited) { return FinishCapture $h }
    if ($h.sw.Elapsed.TotalSeconds -gt $h.timeoutSec) {
        $h.timedOut = $true
        KillTree $proc.Id
        try { $proc.Kill() } catch {}
        return FinishCapture $h
    }
    if (($h.outMs.Length + $h.errMs.Length) -gt [int64]$cfg.outputCapBytes) {
        # A runaway CLI must not exhaust memory/disk through the capture.
        $h.outputLimit = $true
        KillTree $proc.Id
        try { $proc.Kill() } catch {}
        return FinishCapture $h
    }
    return $null
}

function InvokeCapture($fileName, $argList, $stdinText, $timeoutSec, $workDir) {
    $h = StartCapture $fileName $argList $stdinText $timeoutSec $workDir
    $lastTouch = Get-Date
    while ($true) {
        $r = PollCapture $h
        if ($null -ne $r) { return $r }
        if (((Get-Date) - $lastTouch).TotalSeconds -gt 20) {
            # Heartbeat: rewrite the PID through the held lock handle (the
            # handle is exclusive, so no second handle could touch the file).
            try {
                if ($lockStream) {
                    $lockStream.Position = 0
                    $hb = $utf8.GetBytes("$PID")
                    $lockStream.Write($hb, 0, $hb.Length)
                    $lockStream.Flush()
                }
            } catch {}
            $lastTouch = Get-Date
        }
        Start-Sleep -Milliseconds 150
    }
}

# Finalizes one executed job (the post-execution half of the old serial
# loop): stores the captured output, writes the final status, archives the
# job file BEFORE that status (the crash-window order), and releases the
# per-job execution lock.
function Complete-OneJob($ctx, $result) {
    $id = $ctx.id; $fields = $ctx.fields; $started = $ctx.started
    $finished = Get-Date
    $script:sessionSeconds += ($finished - $started).TotalSeconds
    $stdoutText = $result.stdout
    $stderrText = $result.stderr
    if ($stdoutText.Length -gt 1000000) { $stdoutText = $stdoutText.Substring(0, 1000000) + "`n[truncated by the runner at 1000000 chars]"; $fields.warnings += 'stdout truncated at 1000000 chars in the stored artifacts' }
    if ($stderrText.Length -gt 1000000) { $stderrText = $stderrText.Substring(0, 1000000) + "`n[truncated by the runner at 1000000 chars]"; $fields.warnings += 'stderr truncated at 1000000 chars in the stored artifacts' }
    WriteAtomic (Join-Path $outbox "$id.stdout.txt") $stdoutText
    WriteAtomic (Join-Path $outbox "$id.stderr.txt") $stderrText
    $combinedText = $stdoutText
    if ($stderrText) { $combinedText += "`n--- STDERR ---`n" + $stderrText }
    WriteAtomic (Join-Path $outbox "$id.out.txt") $combinedText
    $fields.finishedAt = $finished.ToUniversalTime().ToString('o')
    $fields.durationSec = [math]::Round(($finished - $started).TotalSeconds, 1)
    $fields.exitCode = $result.exitCode
    $fields.timedOut = $result.timedOut
    if ($result.outputLimit) {
        $fields.state = 'failed'
        $fields.error = "output exceeded the capture cap ($([int64]$cfg.outputCapBytes) bytes); the CLI was killed"
    }
    elseif ($result.timedOut) { $fields.state = 'timed-out' }
    elseif ($result.exitCode -ne 0) { $fields.state = 'failed' }
    else {
        $fields.state = 'completed'
        $head = $result.stdout
        if ($head.Length -gt 500) { $head = $head.Substring(0, 500) }
        if ($head -match '(?im)^\s*error[:\s]' -or $result.stdout -match 'authentication failed' -or $result.stdout -match 'quota[^\n]*(exceeded|exhausted)') {
            $fields.outputSuspect = $true
            $fields.suspectNote = 'exit 0 but the output looks like an error message; treat the result as unverified'
        }
    }
    # The job file is archived BEFORE the final status is written: a crash
    # between the two then leaves a 'running' status carrying this file's
    # hash, which the claim check resolves as 'interrupted' if the bytes
    # are ever delivered again - never a second execution.
    ArchiveJobFile $ctx.jobFile
    WriteStatus $id $fields
    try { SetClaimState $id $ctx.jobHash $fields.state } catch {}
    $script:jobsRun++
    Log "job $id $($fields.state) exit=$($result.exitCode) timedOut=$($result.timedOut)"
    Exit-JobLock $id $ctx.execLock
}

# Waits for every in-flight job in $batch, finalizing each as it finishes.
# Polling is cooperative and single-threaded: timeouts and output caps are
# enforced per job by PollCapture, exactly as in the serial path.
function Complete-Batch($batch) {
    $lastTouch = Get-Date
    while ($batch.Count -gt 0) {
        $progress = $false
        foreach ($ctx in @($batch.ToArray())) {
            $res = PollCapture $ctx.handle
            if ($null -ne $res) {
                $batch.Remove($ctx)
                Complete-OneJob $ctx $res
                $progress = $true
            }
        }
        if ($batch.Count -gt 0 -and -not $progress) {
            if (((Get-Date) - $lastTouch).TotalSeconds -gt 20) {
                try {
                    if ($lockStream) {
                        $lockStream.Position = 0
                        $hb = $utf8.GetBytes("$PID")
                        $lockStream.Write($hb, 0, $hb.Length)
                        $lockStream.Flush()
                    }
                } catch {}
                $lastTouch = Get-Date
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

function ArchivePriorArtifacts($id) {
    # Only this id's OWN artifacts: an "$id.*" glob would also match a
    # dotted sibling id's files (job 'a' archiving job 'a.b' - ids may
    # contain dots), so the suffixes the runner writes are listed exactly.
    $existing = @()
    foreach ($suffix in @('status.json', 'out.txt', 'stdout.txt', 'stderr.txt', 'prompt.txt')) {
        $p = Join-Path $outbox "$id.$suffix"
        if (Test-Path $p) { $existing += Get-Item $p }
    }
    if ($existing) {
        # Millisecond resolution: two archives for one id inside the same
        # second must not merge into one directory and overwrite each other.
        $stamp = (Get-Date).ToString('yyyyMMddHHmmssfff')
        $dest = Join-Path (Join-Path $outbox 'archive') "$id-$stamp"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        foreach ($f in $existing) {
            Move-Item $f.FullName $dest -Force
            # The retention clock runs from the archive date (Move-Item
            # preserves the original write time).
            try { (Get-Item (Join-Path $dest $f.Name)).LastWriteTime = Get-Date } catch {}
        }
    }
}

function ArchiveJobFile($jobFile) {
    $dest = Join-Path $doneDir $jobFile.Name
    if (Test-Path $dest) {
        $stamp = (Get-Date).ToString('yyyyMMddHHmmss')
        $dest = Join-Path $doneDir ("{0}-{1}{2}" -f [IO.Path]::GetFileNameWithoutExtension($jobFile.Name), $stamp, $jobFile.Extension)
    }
    Move-Item $jobFile.FullName $dest -Force
    # The retention clock runs from the archive date (Move-Item preserves
    # the original write time) - same pattern as ArchivePriorArtifacts.
    try { (Get-Item $dest).LastWriteTime = Get-Date } catch {}
}

# --- Content-hash claim sets (at-most-once authority) ---
# One file per job id: outbox\archive\<id>.claims.json, holding the SET of
# every job-file SHA-256 ever claimed under that id. It lives in the archive
# tree because ArchivePriorArtifacts only moves the exact per-id artifact
# names listed above (a claims file is never one of them), and DoRetention
# exempts *.claims.json (and *.claims.lock) from its archive prune, so a claim cannot expire.
# The live status record's jobSha256 stays as the per-attempt receipt; this
# set is the authority the claim check reads.
#
# Concurrency (runner 0.3.0): every read-modify-write of a claim set runs
# under a per-id CLAIM LOCK - an exclusively held lock file
# (outbox\archive\<id>.claims.lock; liveness is the held handle, exactly
# like the bridge lock) - and the claim check + claim append are ONE atomic
# step (Test-And-AddClaim). Claiming therefore stays correct when several
# jobs are in flight at once and even if two runner processes ever overlap:
# the second opener waits, then re-reads the set the first one wrote.

function GetClaimsPath($id) {
    Join-Path (Join-Path $outbox 'archive') "$id.claims.json"
}

function GetClaimsLockPath($id) {
    Join-Path (Join-Path $outbox 'archive') "$id.claims.lock"
}

function Enter-ClaimsLock($id) {
    $archiveDir = Join-Path $outbox 'archive'
    if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
    $lockPath = GetClaimsLockPath $id
    for ($i = 0; $i -lt 100; $i++) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            return $stream
        } catch { Start-Sleep -Milliseconds 50 }
    }
    throw "claims: could not acquire the claims lock for job '$id' after 5s; refusing to run (at-most-once cannot be verified)"
}

function Exit-ClaimsLock($stream) {
    if ($stream) { try { $stream.Close() } catch {} }
}

function SaveClaimsUnlocked($id, $entries) {
    $archiveDir = Join-Path $outbox 'archive'
    if (-not (Test-Path $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
    $doc = [ordered]@{ id = $id; claimsVersion = 1; claims = @($entries) }
    WriteAtomic (GetClaimsPath $id) ($doc | ConvertTo-Json -Depth 5)
}

function AddClaimEntry($entries, $seen, $hash, $state, $statusStartedAt) {
    if ($hash -isnot [string] -or $hash -notmatch '^[0-9a-fA-F]{64}$') { return }
    $h = $hash.ToLower()
    if ($seen.ContainsKey($h)) { return }
    $seen[$h] = $true
    $entries.Add([ordered]@{ sha256 = $h; firstClaimedAt = (Get-Date).ToUniversalTime().ToString('o'); state = $state; statusStartedAt = $statusStartedAt }) | Out-Null
}

# Loads the claim set for an id. CALLER MUST HOLD the claims lock. A MISSING
# file is seeded once from prior records (the live status, archived
# statuses, and archived job files in done\) and persisted, so
# pre-claims deployments migrate conservatively: a false claim costs a
# changed-bytes repost, a missed claim costs a re-run. A file that exists
# but cannot be parsed FAILS CLOSED (throws): silently falling back to the
# single-slot status check would re-open the eviction hole exactly when
# state is damaged.
function LoadClaimsUnlocked($id) {
    $path = GetClaimsPath $id
    if (Test-Path $path) {
        $doc = $null
        try { $doc = [IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json } catch {}
        if ($null -eq $doc -or $null -eq $doc.claims) {
            throw "claims: the claims file for job '$id' is unreadable; refusing to run (at-most-once cannot be verified) - delete outbox\archive\$id.claims.json to rebuild a conservative claim set from prior records"
        }
        $entries = New-Object 'System.Collections.ArrayList'
        foreach ($e in @($doc.claims)) {
            if ($e.sha256 -is [string]) {
                $entries.Add([ordered]@{ sha256 = $e.sha256.ToLower(); firstClaimedAt = $e.firstClaimedAt; state = $e.state; statusStartedAt = $e.statusStartedAt }) | Out-Null
            }
        }
        return ,$entries   # unary comma: an ArrayList return would otherwise unroll into the pipeline (empty set -> $null)
    }
    $entries = New-Object 'System.Collections.ArrayList'
    $seen = @{}
    $statusPaths = @()
    $liveStatus = Join-Path $outbox "$id.status.json"
    if (Test-Path $liveStatus) { $statusPaths += $liveStatus }
    $archiveDir = Join-Path $outbox 'archive'
    if (Test-Path $archiveDir) {
        $statusPaths += @(Get-ChildItem $archiveDir -Recurse -File -Filter "$id.status.json" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    foreach ($sp in $statusPaths) {
        try {
            $st = [IO.File]::ReadAllText($sp, $utf8) | ConvertFrom-Json
            if ($st) { AddClaimEntry $entries $seen $st.jobSha256 $st.state $st.startedAt }
        } catch {}
    }
    foreach ($df in @(Get-ChildItem $doneDir -File -Filter "$id*.json" -ErrorAction SilentlyContinue)) {
        if ($df.Name -ne "$id.json" -and $df.Name -notmatch ('^' + [regex]::Escape($id) + '-\d{14}\.json$')) { continue }
        try {
            $bytes = [IO.File]::ReadAllBytes($df.FullName)
            $innerId = $null
            try { $innerId = ($utf8.GetString($bytes) | ConvertFrom-Json).id } catch {}
            if ($innerId -is [string] -and $innerId -ne $id) { continue }
            $h = -join (([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) | ForEach-Object { $_.ToString('x2') })
            AddClaimEntry $entries $seen $h 'archived' $null
        } catch {}
    }
    SaveClaimsUnlocked $id $entries
    Log "claims seeded for ${id}: $($entries.Count) hash(es) from prior records"
    return ,$entries
}

function TestClaim($entries, $hash) {
    foreach ($e in $entries) { if ($e.sha256 -ieq $hash) { return $true } }
    return $false
}

# THE claim operation: under the per-id claims lock, load the set, report
# whether these bytes were already claimed, and if not append the claim -
# atomically, so no concurrent claimant can slip between the check and the
# append. Returns $true when the bytes were ALREADY claimed (the caller
# takes the duplicate/interrupted path and never runs them).
function Test-And-AddClaim($id, $hash, $statusStartedAt) {
    $lock = Enter-ClaimsLock $id
    try {
        $entries = LoadClaimsUnlocked $id
        if (TestClaim $entries $hash) { return $true }
        $seen = @{}
        foreach ($e in $entries) { $seen[$e.sha256] = $true }
        AddClaimEntry $entries $seen $hash 'running' $statusStartedAt
        SaveClaimsUnlocked $id $entries
        return $false
    } finally { Exit-ClaimsLock $lock }
}

# Withdraws a claim appended by THIS attempt (used by the auth-hold and
# same-id-deferral paths: a job that was not processed must not consume its
# bytes, or the duplicate check would archive it unrun later). Precise by
# construction: had this hash already been claimed before this attempt,
# the job would have taken the duplicate path and never reached the hold.
function RemoveClaim($id, $hash) {
    $path = GetClaimsPath $id
    if (-not (Test-Path $path)) { return }
    $lock = Enter-ClaimsLock $id
    try {
        $entries = LoadClaimsUnlocked $id
        $kept = New-Object 'System.Collections.ArrayList'
        foreach ($e in $entries) { if (-not ($e.sha256 -ieq $hash)) { $kept.Add($e) | Out-Null } }
        SaveClaimsUnlocked $id $kept
    } finally { Exit-ClaimsLock $lock }
}

# Advisory bookkeeping only (design: entry state is evidence, never the
# key - the duplicate path distinguishes its sub-cases from the LIVE
# status, not from entry state). Failures are swallowed by the callers.
function SetClaimState($id, $hash, $state) {
    $path = GetClaimsPath $id
    if (-not (Test-Path $path)) { return }
    $lock = Enter-ClaimsLock $id
    try {
        $entries = LoadClaimsUnlocked $id
        foreach ($e in $entries) { if ($e.sha256 -ieq $hash) { $e.state = $state } }
        SaveClaimsUnlocked $id $entries
    } finally { Exit-ClaimsLock $lock }
}

# --- Per-job execution locks ---
# One lock file per job id (locks\<id>.lock), held exclusively for the
# whole CLI execution. Two executions under one id NEVER overlap: their
# status and artifact files are shared, so parallel same-id runs would
# corrupt each other's records even though their claims are distinct.
# A job that cannot take its id's execution lock is DEFERRED (claim
# withdrawn, file left in the inbox) and runs on a later pass, serially.
$locksDir = Join-Path $root 'locks'

function Enter-JobLock($id) {
    if (-not (Test-Path $locksDir)) { New-Item -ItemType Directory -Path $locksDir -Force | Out-Null }
    try {
        $stream = [IO.File]::Open((Join-Path $locksDir "$id.lock"), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        return $stream
    } catch { return $null }
}

function Exit-JobLock($id, $stream) {
    if ($stream) { try { $stream.Close() } catch {} }
    try { Remove-Item (Join-Path $locksDir "$id.lock") -Force -ErrorAction SilentlyContinue } catch {}
}

# Orphan detection (gate finding M1): a job's running status records the
# CLI's process id (cliPid). If a later drain finds that status still
# 'running' and the pid is still alive, the previous attempt is NOT dead -
# its CLI outlived the runner (runner or machine stopped, CLI kept
# going). The id is treated as still executing: no same-id job may start
# until the pid is gone. NO auto-kill: the bridge never kills a process
# it did not start in this drain. PID-reuse guard: the process must have
# started around the attempt's recorded start; a process started long
# after it is a recycled pid, not the orphan. If the start time cannot be
# read, the pid is treated as alive (defer, never double-run).
function Test-CliPidAlive($st) {
    if (-not $st.cliPid) { return $false }
    $proc = Get-Process -Id ([int]$st.cliPid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    try {
        $pStart = $proc.StartTime.ToUniversalTime()
        $jStart = [DateTimeOffset]::Parse([string]$st.startedAt).UtcDateTime
        if ($pStart -lt $jStart.AddSeconds(-10) -or $pStart -gt $jStart.AddSeconds(120)) { return $false }
    } catch {}
    return $true
}

# Null-PID possibly-alive check (gate finding NF2, runner 0.3.2): the
# cliPid is recorded in a second status write immediately after the CLI
# starts (see the StartCapture call site - that write is the very first
# post-start action, and must stay so). A runner killed inside that
# sub-second gap leaves a 'running' status with cliPid $null, which the
# orphan guard above cannot see: there is no pid to test. Such a status
# is therefore judged by AGE. While its age is less than the attempt's
# timeout window - the timeoutSec recorded in the status if present,
# else the largest timeout the config allows (the only bound that
# covers every job the dead runner could have started), plus a 60s
# grace for clock and kill latency - the attempt is treated as POSSIBLY
# ALIVE: same-id work defers, exactly as for a live recorded pid. Only a
# null-PID 'running' status OLDER than that window is certainly a
# corpse and may be resolved 'interrupted'. An unparseable start time
# proves nothing, so it counts as possibly alive (defer, never
# double-run) - the same posture Test-CliPidAlive takes when a start
# time cannot be read.
function Get-NullPidWindowSec($st) {
    $t = $null
    if ($st.timeoutSec) { try { $t = [int]$st.timeoutSec } catch {} }
    if (-not $t -or $t -lt 1) { $t = [int]$cfg.maxTimeoutSec }
    return $t + 60
}

function Test-NullPidPossiblyAlive($st) {
    if ($st.cliPid) { return $false }
    try {
        $ageSec = ((Get-Date).ToUniversalTime() - [DateTimeOffset]::Parse([string]$st.startedAt).UtcDateTime).TotalSeconds
    } catch { return $true }
    return ($ageSec -lt (Get-NullPidWindowSec $st))
}

function DoRetention {
    $marker = Join-Path $root 'last-retention.txt'
    if (Test-Path $marker) {
        if (((Get-Date) - (Get-Item $marker).LastWriteTime).TotalHours -lt 24) { return }
    }
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt [int64]$cfg.logRotateBytes) {
        $rot = Join-Path $root ("runner-{0}.log" -f (Get-Date).ToString('yyyyMMddHHmmss'))
        Move-Item $logFile $rot -Force
        Get-ChildItem $root -Filter 'runner-*.log' | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 3 | ForEach-Object { Remove-Item $_.FullName -Force }
    }
    $old = Get-ChildItem $outbox -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-[int]$cfg.retentionDays) -and $_.Name -notlike '_*' }
    if ($old) {
        $dest = Join-Path (Join-Path $outbox 'archive') ("old-{0}" -f (Get-Date).ToString('yyyyMMdd'))
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        foreach ($f in $old) {
            Move-Item $f.FullName $dest -Force
            try { (Get-Item (Join-Path $dest $f.Name)).LastWriteTime = Get-Date } catch {}
        }
    }
    # Prune, so disk use stays bounded: archived artifacts and done job files
    # older than the retention window are deleted, not kept forever.
    $cutoff = (Get-Date).AddDays(-[int]$cfg.retentionDays)
    $archiveDir = Join-Path $outbox 'archive'
    if (Test-Path $archiveDir) {
        Get-ChildItem $archiveDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Name -notlike '*.claims.json' -and $_.Name -notlike '*.claims.lock' } | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        Get-ChildItem $archiveDir -Recurse -Directory -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { -not (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue) } |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    }
    Get-ChildItem $doneDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    Set-Content -Path $marker -Value (Get-Date).ToString('o')
}

function Assert-StringArray($arr, $what, $adapterId) {
    foreach ($el in @($arr)) {
        if ($el -isnot [string]) { throw "validation: adapter '$adapterId' is malformed ($what must be an array of strings)" }
    }
}

# Bypass-flag denylist, enforced by the RUNNER on adapter-emitted arguments
# (job invocations, the invoke.promptArgs templates - scanned BEFORE the
# prompt is substituted into them - AND the version/auth probes). It is
# never applied to the prompt: the prompt is user content, and a job about
# 'cache bypass logic' is legitimate work, not an injection.
function Assert-NoBypassArgs($argList, $adapterId, $what) {
    foreach ($a in @($argList)) {
        $s = [string]$a
        if ($s -match '(?i)dangerously' -or $s -match '(?i)bypass' -or $s -match '(?i)skip-permissions' -or $s -eq '--yolo') {
            throw "validation: adapter '$adapterId' tried to emit a blocked bypass argument '$s' in $what; refusing to run"
        }
    }
}

# Adapter files are data, and they are the project's main contribution
# surface - so their structure is validated, not trusted: required sections
# must exist and every argument list must be an array of strings.
function LoadAdapter($adapterId) {
    $path = Join-Path $adapterDir "$adapterId.json"
    if (-not (Test-Path $path)) { return $null }
    $a = $null
    try { $a = ([IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json) } catch { return $null }
    if ($null -eq $a) { return $null }
    if ($null -eq $a.executable -or $null -eq $a.executable.names -or $null -eq $a.invoke -or $null -eq $a.modes) {
        throw "validation: adapter '$adapterId' is malformed (missing executable.names, invoke, or modes)"
    }
    Assert-StringArray $a.executable.names 'executable.names' $adapterId
    if ($a.executable.paths) { Assert-StringArray $a.executable.paths 'executable.paths' $adapterId }
    if ($a.invoke.baseArgs) { Assert-StringArray $a.invoke.baseArgs 'invoke.baseArgs' $adapterId }
    if ($a.invoke.promptArgs) { Assert-StringArray $a.invoke.promptArgs 'invoke.promptArgs' $adapterId }
    if ($a.modelArgs) { Assert-StringArray $a.modelArgs 'modelArgs' $adapterId }
    if ($a.effortArgs) { Assert-StringArray $a.effortArgs 'effortArgs' $adapterId }
    if ($a.efforts) { Assert-StringArray $a.efforts 'efforts' $adapterId }
    if ($a.versionArgs) { Assert-StringArray $a.versionArgs 'versionArgs' $adapterId }
    if ($a.authCheck -and $a.authCheck.args) { Assert-StringArray $a.authCheck.args 'authCheck.args' $adapterId }
    # Every mode the adapter defines is validated (not just the common
    # scale): an adapter may offer modes beyond readonly/accept-edits/auto,
    # and any of them is a legitimate explicit per-job choice.
    foreach ($mp in @($a.modes.PSObject.Properties)) {
        if ($null -ne $mp.Value) { Assert-StringArray $mp.Value "modes.$($mp.Name)" $adapterId }
    }
    return $a
}

# ---- Integrity manifest ----
# install.ps1 records one SHA-256 per covered file (the runner, the config,
# and every adapter) in sessionbridge.expected.sha256. The runner verifies
# the whole set: any mismatch, any covered file missing from the manifest,
# and any manifest entry without a file is a refusal. This is tamper-evidence
# against accidents and drift - anyone who can write the bridge root can also
# re-record the manifest (that is the installer's normal job).
function Get-CoveredFiles {
    $files = @([pscustomobject]@{ Rel = 'sessionbridge.ps1'; Full = $runnerPathSelf })
    if (Test-Path $configFile) { $files += [pscustomobject]@{ Rel = 'sessionbridge.config.json'; Full = $configFile } }
    if (Test-Path $adapterDir) {
        Get-ChildItem $adapterDir -Filter *.json | Sort-Object Name | ForEach-Object {
            $files += [pscustomobject]@{ Rel = ('adapters/' + $_.Name); Full = $_.FullName }
        }
    }
    return $files
}

function Test-Integrity {
    if (-not (Test-Path $hashFile)) { return @{ ok = $false; detail = 'expected-hash file missing (run install.ps1)' } }
    $expectedText = ([IO.File]::ReadAllText($hashFile)).Trim()
    if ($expectedText -notmatch "`n" -and $expectedText -match '^[0-9A-Fa-f]{64}$') {
        # Legacy single-hash form from pre-manifest installs: runner only.
        $selfHash = (Get-FileHash $runnerPathSelf -Algorithm SHA256).Hash
        if ($expectedText -ieq $selfHash) { return @{ ok = $true; detail = 'legacy runner-only hash (re-run install.ps1 to record the full manifest)' } }
        return @{ ok = $false; detail = 'runner hash mismatch' }
    }
    $seen = @{}
    foreach ($line in ($expectedText -split "`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -notmatch '^(\S+)\s+([0-9A-Fa-f]{64})$') { return @{ ok = $false; detail = "malformed manifest line: $t" } }
        $seen[$Matches[1]] = $Matches[2]
    }
    $covered = @(Get-CoveredFiles)
    foreach ($f in $covered) {
        if (-not $seen.ContainsKey($f.Rel)) { return @{ ok = $false; detail = "covered file not in the manifest: $($f.Rel) (re-run install.ps1)" } }
        $h = (Get-FileHash $f.Full -Algorithm SHA256).Hash
        if ($seen[$f.Rel] -ine $h) { return @{ ok = $false; detail = "hash mismatch: $($f.Rel)" } }
    }
    $coveredRels = @($covered | ForEach-Object { $_.Rel })
    foreach ($rel in @($seen.Keys)) {
        if ($coveredRels -notcontains $rel) { return @{ ok = $false; detail = "manifest lists a file that is not installed: $rel" } }
    }
    return @{ ok = $true; detail = 'manifest ok' }
}

function ResolveExecutable($adapter) {
    foreach ($p in @($adapter.executable.paths)) {
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$p)
        if (Test-Path $expanded) { return $expanded }
    }
    foreach ($n in @($adapter.executable.names)) {
        $cmd = Get-Command ([string]$n) -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

foreach ($d in @($inbox, $outbox, $doneDir, $locksDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# Single-runner lock: ONE open, held exclusively (FileShare.None) for the
# whole run. OpenOrCreate + FileShare.None is atomic - there is no
# probe-then-open window in which two starters can both acquire. If the open
# throws, a live runner holds the lock and this instance exits (and says so
# in the log - a silent contention exit is indistinguishable from a dead
# bridge). The PID inside is for humans; liveness is the held handle.
$lockStream = $null
$lockExisted = Test-Path $lockFile
$lockAgeMin = if ($lockExisted) { ((Get-Date) - (Get-Item $lockFile).LastWriteTime).TotalMinutes } else { 0 }
try {
    $lockStream = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
} catch {
    Log 'another runner holds the bridge lock; exiting'
    exit 0
}
if ($lockExisted -and $lockAgeMin -ge 10) { Log 'stale lock found (previous holder gone), taking over' }
$lockStream.SetLength(0)
$pidBytes = $utf8.GetBytes("$PID")
$lockStream.Write($pidBytes, 0, $pidBytes.Length)
$lockStream.Flush()

try {
    # Integrity self-check FIRST (before the empty-inbox exit): the deployed
    # runner, config, and adapters must match the manifest install.ps1 recorded.
    $integ = Test-Integrity
    $integrityOk = $integ.ok
    if (-not $integrityOk) {
        Log "INTEGRITY MISMATCH: $($integ.detail); refusing to run jobs"
        WriteHealth ([ordered]@{ checkedAt = (Get-Date).ToUniversalTime().ToString('o'); runnerVersion = $RUNNER_VERSION; integrityOk = $false; maxConcurrency = [int]$cfg.maxConcurrency; modeCeiling = $cfg.modeCeiling; adapters = @{}; detail = $integ.detail })
        exit 1
    }
    if ($integ.detail -ne 'manifest ok') { Log "integrity: $($integ.detail)" }

    # Resolve the allowlist roots through junctions/symlinks once per run, so
    # cwd checks compare resolved paths on both sides.
    $allowedRoots = @($allowedRoots | ForEach-Object { Resolve-FinalPath $_ })

    # Jobs younger than 5 seconds may still be copying in; leave them for the next pass.
    $pending = Get-ChildItem $inbox -Filter *.json |
        Where-Object { ((Get-Date) - $_.LastWriteTime).TotalSeconds -gt 5 } |
        Sort-Object LastWriteTime, Name
    if (-not $pending) { exit 0 }

    DoRetention
    $healthAdapters = [ordered]@{}
    $adapterState = @{}   # adapterId -> @{ exe; version; authOk; detail }
    $heldAdapters = @{}   # adapterId -> $true once its preflight has failed this drain
    # (In-drain dedupe needs no map of its own: claims are appended to the
    # persisted per-id claim set synchronously, before validation, so the
    # claim check below sees this drain's earlier jobs too.)
    $skippedNames = @{}   # inbox filenames already logged as skipped this drain
    # Stale job-lock cleanup (N2): a lock FILE left by a dead runner is
    # removed when its id has no running status and no queued inbox job.
    # (Liveness is the held handle, so a stale file never blocks a run;
    # this keeps locks\ from accumulating corpses.)
    if (Test-Path $locksDir) {
        $queuedIds = @{}
        Get-ChildItem $inbox -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { $queuedIds[[IO.Path]::GetFileNameWithoutExtension($_.Name)] = $true }
        foreach ($lf in @(Get-ChildItem $locksDir -Filter *.lock -ErrorAction SilentlyContinue)) {
            $lid = [IO.Path]::GetFileNameWithoutExtension($lf.Name)
            $lst = $null
            $lsp = Join-Path $outbox "$lid.status.json"
            if (Test-Path $lsp) { try { $lst = [IO.File]::ReadAllText($lsp, $utf8) | ConvertFrom-Json } catch {} }
            if ($lst -and $lst.state -eq 'running') { continue }
            if ($queuedIds.ContainsKey($lid)) { continue }
            Remove-Item $lf.FullName -Force -ErrorAction SilentlyContinue
            Log "removed stale job lock for $lid (no running status, no queued job)"
        }
    }
    # Orphan scan (M1): any still-'running' status whose recorded CLI pid
    # is alive names an orphan from a previous drain. Log it loudly once
    # per drain; the per-job check below defers same-id work while it lives.
    # A 'running' status with NO recorded pid inside its timeout window
    # (NF2) is logged as ORPHAN-UNKNOWN and deferred the same way.
    foreach ($sp in @(Get-ChildItem $outbox -Filter *.status.json -ErrorAction SilentlyContinue)) {
        $sst = $null
        try { $sst = [IO.File]::ReadAllText($sp.FullName, $utf8) | ConvertFrom-Json } catch {}
        if ($sst -and $sst.state -eq 'running' -and $sst.cliPid -and (Test-CliPidAlive $sst)) {
            Log "ORPHAN: job $($sst.id) CLI (pid $($sst.cliPid)) from a previous drain is still running; same-id jobs stay queued until it exits"
        }
        elseif ($sst -and $sst.state -eq 'running' -and -not $sst.cliPid -and (Test-NullPidPossiblyAlive $sst)) {
            Log "ORPHAN-UNKNOWN: job $($sst.id) has a 'running' status with no recorded CLI pid, started $($sst.startedAt), inside its timeout window; the previous attempt may still be executing - same-id jobs stay queued until the window passes"
        }
    }
    Log "runner start, SessionBridge $RUNNER_VERSION, $($pending.Count) job(s) queued"
    $drainStart = Get-Date
    $jobsRun = 0
    $sessionSeconds = 0.0
    $passCount = 0
    $batch = New-Object 'System.Collections.ArrayList'   # in-flight executions (parallel drain)

    while ($true) {
        $passCount++
        if ($passCount -gt 200) { Log 'drain pass cap reached; exiting drain'; break }
        $passStartJobs = $jobsRun
        $passStartInbox = @(Get-ChildItem $inbox -Filter *.json -ErrorAction SilentlyContinue).Count
        $jobs = Get-ChildItem $inbox -Filter *.json |
            Where-Object { ((Get-Date) - $_.LastWriteTime).TotalSeconds -gt 5 } |
            Sort-Object LastWriteTime, Name
        if (-not $jobs) { break }
        foreach ($jobFile in $jobs) {
            if (($jobsRun + $batch.Count) -ge [int]$cfg.maxJobsPerDrain) { Log "drain job cap ($($cfg.maxJobsPerDrain)) reached; remaining jobs stay queued"; break }
            if (((Get-Date) - $drainStart).TotalMinutes -gt [int]$cfg.maxDrainMinutes) { Log "drain wall-clock cap ($($cfg.maxDrainMinutes) min) reached; remaining jobs stay queued"; break }

            $fileId = [IO.Path]::GetFileNameWithoutExtension($jobFile.Name)
            # A filename that is not itself a safe job id (the classic case is a
            # sync conflict copy like "job (1).json") is never executed.
            if ($fileId -notmatch $ID_PATTERN) {
                if (-not $skippedNames.ContainsKey($jobFile.Name)) {
                    $skippedNames[$jobFile.Name] = $true
                    Log "skipping inbox file whose name is not a safe job id: $($jobFile.Name) (sync conflict copy? rename it to <id>.json to run it)"
                }
                continue
            }
            # Jobs for an adapter already held this drain are skipped without
            # re-probing or re-logging - a failed auth preflight must not turn
            # the drain into a spin loop.
            $peekAdapter = $null
            try {
                $peek = [IO.File]::ReadAllText($jobFile.FullName, $utf8) | ConvertFrom-Json
                if ($peek.adapter -is [string]) { $peekAdapter = $peek.adapter }
            } catch {}
            if ($peekAdapter -and $heldAdapters.ContainsKey($peekAdapter)) { continue }
            $id = $fileId
            $started = Get-Date
            $fields = [ordered]@{
                id = $id; adapter = $null; state = 'running'; startedAt = $started.ToUniversalTime().ToString('o')
                finishedAt = $null; durationSec = $null; cwd = $null; mode = $null; model = $null
                effort = $null; cliVersion = $null; authOk = $null; integrityOk = $integrityOk
                exitCode = $null; timedOut = $false; error = $null; warnings = @()
                author = $null; charter = $null; requestedBy = $null; modeCeiling = $cfg.modeCeiling; maxConcurrency = [int]$cfg.maxConcurrency
                jobSha256 = $null; cliPid = $null; timeoutSec = $null; outputSuspect = $false; suspectNote = $null
            }
            $statusOwned = $false   # $true once THIS attempt has written its 'running' status
            $execLock = $null       # this attempt's per-job execution lock stream, once taken
            $jobHash = $null        # this file's claim hash, once computed below
            try {
                # The claim key is the job file's own content hash, computed
                # from the raw bytes BEFORE parsing: every status written for
                # this file - including a 'failed' record for unparseable
                # JSON - carries it as jobSha256.
                $rawBytes = [IO.File]::ReadAllBytes($jobFile.FullName)
                # Still-copying guard, re-checked at READ time (the drain's
                # enumeration snapshot may be minutes old by now, and a sync
                # client may have replaced the file since): if the file
                # changed during the read, or was written within the last 5
                # seconds, its bytes are not a stable claim - leave it in
                # the inbox for the next drain, unclaimed and unrecorded.
                $fiNow = [IO.FileInfo]::new($jobFile.FullName)
                if ($fiNow.Length -ne $rawBytes.Length -or ((Get-Date) - $fiNow.LastWriteTime).TotalSeconds -le 5) {
                    if (-not $skippedNames.ContainsKey($jobFile.Name)) {
                        $skippedNames[$jobFile.Name] = $true
                        Log "job $id skipped this pass: file is still settling (copy in progress?); left in the inbox"
                    }
                    continue
                }
                $jobHash = -join (([Security.Cryptography.SHA256]::Create().ComputeHash($rawBytes)) | ForEach-Object { $_.ToString('x2') })
                $fields.jobSha256 = $jobHash
                # A parse failure is DEFERRED, not thrown yet: malformed
                # bytes must still be claimed below (under the filename id)
                # before the failure is recorded, or an identical
                # redelivery would be re-failed - and claim-checked never.
                $job = $null
                $parseError = $null
                try { $job = $utf8.GetString($rawBytes) | ConvertFrom-Json } catch { $parseError = $_.Exception.Message }
                if ($job -and $job.id) {
                    if ($job.id -isnot [string]) { throw 'validation: id must be a string' }
                    if ($job.id -match $ID_PATTERN) { $id = $job.id; $fields.id = $id }
                    else { $fields.warnings += "job id '$($job.id)' is not a safe id; using the filename id" }
                }

                # At-most-once, keyed on the job file's content hash against
                # the persisted per-id claim SET (Test-And-AddClaim): if these exact
                # bytes were ever claimed under this id - in any earlier
                # drain, in this drain, in any crash window - they are never
                # run again. The live status is read only to distinguish the
                # sub-cases: a 'running' live status carrying this hash (or
                # a claim-less legacy one) is a crashed attempt and resolves
                # to 'interrupted'; anything else is 'already processed' and
                # the recorded status is left untouched.
                # Orphan / corpse handling for a prior 'running' status
                # under this id (gate findings M1/M2): if the recorded CLI
                # pid is still alive, the previous attempt is still
                # executing - leave this file queued, unclaimed, and log
                # it loudly; never start a same-id job over a live one,
                # and never resolve a live attempt as 'interrupted'. If
                # the pid is gone and the status predates this drain, the
                # attempt is a corpse: resolve it 'interrupted' FIRST
                # (its artifacts archived), then process this file
                # normally - a queued successor both sees the original
                # honestly resolved and still runs exactly once.
                $priorStatusPath = Join-Path $outbox "$id.status.json"
                if (Test-Path $priorStatusPath) {
                    $priorRun = $null
                    try { $priorRun = [IO.File]::ReadAllText($priorStatusPath, $utf8) | ConvertFrom-Json } catch {}
                    if ($priorRun -and $priorRun.state -eq 'running') {
                        $fromPriorDrain = $true
                        try { if ([DateTimeOffset]::Parse([string]$priorRun.startedAt).UtcDateTime -ge $drainStart.ToUniversalTime().AddSeconds(-2)) { $fromPriorDrain = $false } } catch {}
                        if ($priorRun.cliPid) {
                            if (Test-CliPidAlive $priorRun) {
                                if ($fromPriorDrain) { Log "ORPHAN: job $id previous attempt's CLI (pid $($priorRun.cliPid)) is still running; job left queued - no same-id job starts until it exits" }
                                else { Log "job ${id}: a previous attempt is still executing in this drain (pid $($priorRun.cliPid)); file left queued for a later pass" }
                                continue
                            }
                            if ($fromPriorDrain) {
                                ArchivePriorArtifacts $id
                                $corpse = [ordered]@{
                                    id = $id; adapter = $priorRun.adapter; state = 'interrupted'; startedAt = $priorRun.startedAt
                                    finishedAt = (Get-Date).ToUniversalTime().ToString('o'); durationSec = $null; cwd = $priorRun.cwd; mode = $priorRun.mode; model = $priorRun.model
                                    effort = $priorRun.effort; cliVersion = $priorRun.cliVersion; authOk = $priorRun.authOk; integrityOk = $integrityOk
                                    exitCode = $null; timedOut = $false; error = 'previous attempt did not finish (runner or machine stopped mid-job); not re-run automatically - repost with changed content to retry'; warnings = @()
                                    author = $priorRun.author; charter = $priorRun.charter; requestedBy = $priorRun.requestedBy; modeCeiling = $priorRun.modeCeiling; maxConcurrency = $priorRun.maxConcurrency
                                    jobSha256 = $priorRun.jobSha256; cliPid = $priorRun.cliPid; timeoutSec = $priorRun.timeoutSec; outputSuspect = $false; suspectNote = $null
                                }
                                WriteStatus $id $corpse
                                try { if ($priorRun.jobSha256) { SetClaimState $id $priorRun.jobSha256 'interrupted' } } catch {}
                                Log "job $id interrupted: previous attempt's CLI (pid $($priorRun.cliPid)) is gone and the attempt never finished; resolved before processing the queued job"
                            }
                        }
                        elseif (Test-NullPidPossiblyAlive $priorRun) {
                            # NF2: no pid was ever recorded for this attempt
                            # (the runner died in the gap before the cliPid
                            # write, or the record predates that write) and
                            # the attempt is inside its timeout window, so
                            # its CLI may still be running with no pid to
                            # test. Defer exactly like a live orphan: leave
                            # the file queued and UNCLAIMED (this check runs
                            # before Test-And-AddClaim), and never resolve a
                            # possibly-live attempt as 'interrupted'.
                            if ($fromPriorDrain) { Log "ORPHAN-UNKNOWN: job $id previous attempt left a 'running' status with no recorded CLI pid, started $($priorRun.startedAt), inside its timeout window ($(Get-NullPidWindowSec $priorRun)s); it may still be executing - job left queued, unclaimed, until the window passes" }
                            else { Log "job ${id}: a previous attempt in this drain has a 'running' status with no recorded CLI pid and is inside its timeout window; file left queued for a later pass" }
                            continue
                        }
                        elseif ($fromPriorDrain -and $priorRun.jobSha256 -and -not (Test-NullPidPossiblyAlive $priorRun)) {
                            # NF2 corpse: a hash-carrying 'running' status
                            # with no recorded pid, OLDER than its timeout
                            # window - the attempt is certainly dead (had
                            # the runner lived, its own timeout would have
                            # ended the CLI inside the window). Resolve it
                            # 'interrupted' FIRST, exactly like the
                            # recorded-pid corpse above, then process this
                            # file normally. A claim-LESS status this old
                            # is NOT resolved here: with no hash there is
                            # nothing to compare the queued bytes against,
                            # so the legacy fallback below keeps its
                            # semantics (it resolves the delivery itself
                            # as 'interrupted' without running it).
                            ArchivePriorArtifacts $id
                            $corpse = [ordered]@{
                                id = $id; adapter = $priorRun.adapter; state = 'interrupted'; startedAt = $priorRun.startedAt
                                finishedAt = (Get-Date).ToUniversalTime().ToString('o'); durationSec = $null; cwd = $priorRun.cwd; mode = $priorRun.mode; model = $priorRun.model
                                effort = $priorRun.effort; cliVersion = $priorRun.cliVersion; authOk = $priorRun.authOk; integrityOk = $integrityOk
                                exitCode = $null; timedOut = $false; error = 'previous attempt did not finish (runner or machine stopped mid-job); not re-run automatically - repost with changed content to retry'; warnings = @()
                                author = $priorRun.author; charter = $priorRun.charter; requestedBy = $priorRun.requestedBy; modeCeiling = $priorRun.modeCeiling; maxConcurrency = $priorRun.maxConcurrency
                                jobSha256 = $priorRun.jobSha256; cliPid = $priorRun.cliPid; timeoutSec = $priorRun.timeoutSec; outputSuspect = $false; suspectNote = $null
                            }
                            WriteStatus $id $corpse
                            try { SetClaimState $id $priorRun.jobSha256 'interrupted' } catch {}
                            Log "job $id interrupted: previous attempt left a 'running' status with no recorded CLI pid and its timeout window has passed; resolved before processing the queued job"
                        }
                    }
                }
                $alreadyClaimed = Test-And-AddClaim $id $jobHash $fields.startedAt
                if ($alreadyClaimed) {
                    $priorLive = $null
                    if (Test-Path $priorStatusPath) {
                        try { $priorLive = [IO.File]::ReadAllText($priorStatusPath, $utf8) | ConvertFrom-Json }
                        catch { Log "job $id warning: prior status file is unreadable; the claim set remains authoritative" }
                    }
                    if ($priorLive -and $priorLive.state -eq 'running' -and ((-not $priorLive.jobSha256) -or ($priorLive.jobSha256 -ieq $jobHash))) {
                        if ($priorLive.cliPid -and (Test-CliPidAlive $priorLive)) {
                            Log "ORPHAN: job $id previous attempt's CLI (pid $($priorLive.cliPid)) is still running; duplicate left queued - a live attempt is never resolved as interrupted"
                            continue
                        }
                        if (-not $priorLive.cliPid -and (Test-NullPidPossiblyAlive $priorLive)) {
                            # NF2 defense in depth (the per-job check above
                            # normally defers this first): a pid-less
                            # 'running' status inside its timeout window is
                            # possibly live - never resolve it 'interrupted'.
                            # No claim withdrawal here: this attempt added
                            # no claim (the bytes were already claimed).
                            Log "ORPHAN-UNKNOWN: job $id previous attempt has a 'running' status with no recorded CLI pid inside its timeout window; duplicate left queued - a possibly-live attempt is never resolved as interrupted"
                            continue
                        }
                        ArchivePriorArtifacts $id
                        $fields.state = 'interrupted'
                        $fields.error = 'previous attempt did not finish (runner or machine stopped mid-job); not re-run automatically - repost with changed content to retry'
                        $fields.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
                        ArchiveJobFile $jobFile
                        WriteStatus $id $fields
                        try { SetClaimState $id $jobHash 'interrupted' } catch {}
                        $jobsRun++
                        Log "job $id interrupted: previous attempt never finished; archived without re-running"
                        continue
                    }
                    ArchiveJobFile $jobFile
                    $jobsRun++
                    Log "job $id already processed (content hash previously claimed under this id); identical job file archived without running"
                    continue
                }
                # New bytes under this id were claimed atomically above
                # (Test-And-AddClaim), BEFORE validation, the run, or any
                # status write - a rejected or malformed post claims its
                # bytes too, so it can never evict another claim by
                # overwriting the live status later.
                if ($parseError) { throw $parseError }
                foreach ($prop in $job.PSObject.Properties.Name) {
                    if ($KNOWN_FIELDS -notcontains $prop) { $fields.warnings += "unknown field ignored: $prop" }
                }
                foreach ($pf in @('author','charter','requestedBy')) {
                    if ($null -ne $job.$pf) {
                        if ($job.$pf -isnot [string]) { throw "validation: $pf must be a string" }
                        $fields.$pf = $job.$pf
                    }
                }

                # Legacy fallback, kept for claim-less records: the claim
                # set above is authoritative for every hash-carrying status
                # (the claim set seeds from them), so what can still reach here
                # is a pre-hash status - above all a claim-less 'running'
                # one, which must still block a blind re-run. An unreadable
                # prior status is logged, never silently ignored.
                if (Test-Path $priorStatusPath) {
                    $prior = $null
                    try { $prior = [IO.File]::ReadAllText($priorStatusPath, $utf8) | ConvertFrom-Json }
                    catch { Log "job $id warning: prior status file is unreadable; treating the job as new (the claim set found no claim for these bytes)" }
                    if ($prior) {
                        $priorHash = if ($prior.jobSha256 -is [string]) { $prior.jobSha256 } else { $null }
                        $hashMatches = [bool]($priorHash -and ($priorHash -ieq $jobHash))
                        if ($prior.state -eq 'running' -and ($hashMatches -or -not $priorHash)) {
                            if ($prior.cliPid -and (Test-CliPidAlive $prior)) {
                                try { RemoveClaim $id $jobHash }
                                catch { Log "job $id warning: could not withdraw the deferred job's claim ($($_.Exception.Message)); it may be reported already processed next drain" }
                                Log "ORPHAN: job $id previous attempt's CLI (pid $($prior.cliPid)) is still running; job left queued - a live attempt is never resolved as interrupted"
                                continue
                            }
                            if (-not $prior.cliPid -and (Test-NullPidPossiblyAlive $prior)) {
                                # NF2 defense in depth (the per-job check
                                # above normally defers this first): a
                                # pid-less 'running' status inside its
                                # timeout window is possibly live - defer
                                # and withdraw this attempt's claim, exactly
                                # like the recorded-pid orphan path above.
                                try { RemoveClaim $id $jobHash }
                                catch { Log "job $id warning: could not withdraw the deferred job's claim ($($_.Exception.Message)); it may be reported already processed next drain" }
                                Log "ORPHAN-UNKNOWN: job $id previous attempt has a 'running' status with no recorded CLI pid inside its timeout window; job left queued - a possibly-live attempt is never resolved as interrupted"
                                continue
                            }
                            # Same bytes (or a pre-hash legacy status, which
                            # carries no claim to compare) still reading
                            # 'running' can only be a crashed previous attempt
                            # (the runner is single-instance). Prior artifacts
                            # are archived first, and the job file is archived
                            # BEFORE the interrupted status is written.
                            ArchivePriorArtifacts $id
                            $fields.state = 'interrupted'
                            $fields.error = 'previous attempt did not finish (runner or machine stopped mid-job); not re-run automatically - repost with changed content to retry'
                            $fields.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
                            ArchiveJobFile $jobFile
                            WriteStatus $id $fields
                            try { SetClaimState $id $jobHash 'interrupted' } catch {}
                            $jobsRun++
                            Log "job $id interrupted: previous attempt never finished; archived without re-running"
                            continue
                        }
                        if ($prior.state -ne 'running' -and $hashMatches) {
                            # Already processed: the recorded status (and its
                            # artifacts) are left untouched; only the duplicate
                            # job file is archived away.
                            ArchiveJobFile $jobFile
                            $jobsRun++
                            Log "job $id already processed (state $($prior.state)); identical job file archived without running"
                            continue
                        }
                        # Otherwise the bytes differ from the recorded claim
                        # (or the prior status predates content-hash claiming
                        # and is not 'running'): a deliberate repost. It falls
                        # through to validation; its prior artifacts are
                        # archived after validation, before the run, at the
                        # ArchivePriorArtifacts call below.
                    }
                }

                # --- Validation: any failure rejects the job before the CLI ever runs. ---
                # Field TYPES are checked explicitly: a malformed field is a
                # rejection, never a silent cast into garbage.
                if ($null -ne $job.adapter -and $job.adapter -isnot [string]) { throw 'validation: adapter must be a string' }
                $adapterId = if ($job.adapter) { $job.adapter } else { $null }
                if (-not $adapterId -or ($adapterId -notmatch $ID_PATTERN)) { throw 'validation: adapter is missing or not a safe id' }
                $adapter = LoadAdapter $adapterId
                if (-not $adapter) { throw "validation: unknown adapter '$adapterId'" }
                $fields.adapter = $adapterId

                if ($null -eq $job.prompt -or $job.prompt -isnot [string]) { throw 'validation: prompt must be a string' }
                $promptText = $job.prompt
                if ($promptText.Trim().Length -eq 0) { throw 'validation: prompt is empty' }
                if ($promptText.Length -gt [int]$cfg.promptMaxChars) { throw "validation: prompt exceeds $($cfg.promptMaxChars) characters" }

                # Mode is REQUIRED and explicit (runner 0.3.0): a missing,
                # empty, or non-string mode is a validation error - never a
                # silent fallback to a default. Any mode the ADAPTER defines
                # is a legitimate choice; the owner's modeCeiling dial, when
                # set, is the only cap. The requested mode is recorded in
                # the status BEFORE the ceiling check, so even a rejection
                # states the mode the job asked for.
                if ($null -ne $job.mode -and $job.mode -isnot [string]) { throw 'validation: mode must be a string' }
                $mode = if ($job.mode -is [string]) { $job.mode.Trim() } else { $null }
                if (-not $mode) { throw 'validation: mode is required - every job must declare its mode explicitly (the modes the adapter defines are listed in its adapter file); there is no default mode' }
                $fields.mode = $mode
                $modeArgs = $adapter.modes.$mode
                if ($null -eq $modeArgs) { throw "validation: adapter '$adapterId' does not define mode '$mode'" }
                if ($null -ne $cfg.modeCeiling) {
                    $ceiling = [string]$cfg.modeCeiling
                    $overCeiling = $false
                    if ($mode -ieq $ceiling) { $overCeiling = $false }
                    elseif ($MODE_RANK.ContainsKey($mode) -and $MODE_RANK.ContainsKey($ceiling)) { $overCeiling = ($MODE_RANK[$mode] -gt $MODE_RANK[$ceiling]) }
                    else { $overCeiling = $true }
                    if ($overCeiling) { throw "validation: mode '$mode' exceeds the bridge mode ceiling '$ceiling' (sessionbridge.config.json)" }
                }

                if ($null -ne $job.effort -and $job.effort -isnot [string]) { throw 'validation: effort must be a string' }
                $effort = if ($job.effort) { $job.effort } else { $null }
                if ($effort) {
                    if ($adapter.efforts) {
                        if (@($adapter.efforts) -notcontains $effort) { throw "validation: effort '$effort' is not allowed for adapter '$adapterId'" }
                    } elseif ($effort -notmatch $VALUE_PATTERN) { throw "validation: effort '$effort' contains unsafe characters" }
                }
                if ($null -ne $job.model -and $job.model -isnot [string]) { throw 'validation: model must be a string' }
                $model = if ($job.model) { $job.model } else { $null }
                if ($model -and ($model -notmatch $MODEL_PATTERN)) { throw "validation: model '$model' contains characters outside [A-Za-z0-9._/-] or starts with '-'" }

                $timeoutSec = [int]$cfg.defaultTimeoutSec
                if ($null -ne $job.timeoutSec) {
                    if ($job.timeoutSec -isnot [int] -and $job.timeoutSec -isnot [long] -and $job.timeoutSec -isnot [double]) { throw 'validation: timeoutSec must be a number' }
                    if ([double]$job.timeoutSec -ne [math]::Floor([double]$job.timeoutSec)) { throw 'validation: timeoutSec must be a whole number of seconds' }
                    $timeoutSec = [int]$job.timeoutSec
                }
                if ($timeoutSec -lt [int]$cfg.minTimeoutSec -or $timeoutSec -gt [int]$cfg.maxTimeoutSec) { throw "validation: timeoutSec $timeoutSec outside $($cfg.minTimeoutSec)..$($cfg.maxTimeoutSec)" }

                if ($null -ne $job.cwd -and $job.cwd -isnot [string]) { throw 'validation: cwd must be a string' }
                $cwd = if ($job.cwd) { $job.cwd } else { [string]$allowedRoots[0] }
                $cwd = [Environment]::ExpandEnvironmentVariables($cwd)
                if (-not (Test-Path $cwd)) { throw "validation: cwd does not exist: $cwd" }
                $cwdFull = Resolve-FinalPath $cwd
                $cwdOk = $false
                foreach ($r in $allowedRoots) {
                    if ($cwdFull -ieq $r -or $cwdFull.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase) -or $cwdFull.StartsWith($r + '/', [StringComparison]::OrdinalIgnoreCase)) { $cwdOk = $true }
                }
                if (-not $cwdOk) { throw "validation: cwd is outside the configured allowed roots: $cwd" }
                $fields.cwd = $cwdFull; $fields.model = $model; $fields.effort = $effort
                # Record the job's timeout in its status (NF2): if this
                # attempt is later found as a pid-less 'running' status,
                # the next drain recovers the exact timeout window from
                # here instead of falling back to the configured maximum.
                $fields.timeoutSec = $timeoutSec

                # --- Adapter preflight (once per adapter per drain): resolve the
                # executable, capture its version, and run its auth check. A failed
                # auth check holds this adapter's jobs (files stay in the inbox). ---
                if (-not $adapterState.ContainsKey($adapterId)) {
                    $exe = ResolveExecutable $adapter
                    $st = @{ exe = $exe; version = $null; authOk = $null; detail = '' }
                    if (-not $exe) {
                        $st.authOk = $false; $st.detail = 'adapter executable not found'
                    } else {
                        # The denylist covers the probe argv too, not just jobs.
                        if ($adapter.versionArgs) { Assert-NoBypassArgs $adapter.versionArgs $adapterId 'versionArgs' }
                        if ($adapter.authCheck -and $adapter.authCheck.args) { Assert-NoBypassArgs $adapter.authCheck.args $adapterId 'authCheck.args' }
                        if ($adapter.versionArgs) {
                            $v = InvokeCapture $exe @($adapter.versionArgs) '' 20 $cwdFull
                            if (-not $v.timedOut -and $v.stdout) { $st.version = ($v.stdout -split "`n")[0].Trim() }
                        }
                        if ($adapter.authCheck -and $adapter.authCheck.args) {
                            $probeTimeout = [int]$cfg.authProbeTimeoutSec
                            if ($adapter.authCheck.timeoutSec) { $probeTimeout = [int]$adapter.authCheck.timeoutSec }
                            $probe = InvokeCapture $exe @($adapter.authCheck.args) '' $probeTimeout $cwdFull
                            if ($probe.timedOut) {
                                $st.detail = 'auth probe timed out; auth state unknown, drain proceeds'
                            } elseif ($probe.exitCode -eq 0) {
                                $st.authOk = $true; $st.detail = 'auth probe ok'
                            } else {
                                $st.authOk = $false
                                $firstLine = (($probe.stdout + "`n" + $probe.stderr) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                                $st.detail = "auth probe exit $($probe.exitCode): $firstLine"
                            }
                        } else {
                            $st.detail = 'adapter defines no auth check; skipped'
                        }
                    }
                    $adapterState[$adapterId] = $st
                    $healthAdapters[$adapterId] = [ordered]@{ version = $st.version; authOk = $st.authOk; detail = $st.detail }
                    WriteHealth ([ordered]@{ checkedAt = (Get-Date).ToUniversalTime().ToString('o'); runnerVersion = $RUNNER_VERSION; integrityOk = $integrityOk; maxConcurrency = [int]$cfg.maxConcurrency; modeCeiling = $cfg.modeCeiling; adapters = $healthAdapters })
                    Log "adapter $adapterId preflight: exe=$exe version=$($st.version) authOk=$($st.authOk) ($($st.detail))"
                }
                $ast = $adapterState[$adapterId]
                $fields.cliVersion = $ast.version
                $fields.authOk = $ast.authOk
                if ($ast.authOk -eq $false) {
                    # Held: the job stays in the inbox for a later drain (after
                    # the user signs in again). The adapter is marked held so
                    # the rest of this drain skips its jobs without re-probing,
                    # and the no-progress check below ends the drain instead of
                    # spinning on the held queue.
                    if (-not $heldAdapters.ContainsKey($adapterId)) {
                        $heldAdapters[$adapterId] = $true
                        Log "job $id held: adapter $adapterId preflight failed ($($ast.detail)); its jobs stay queued this drain"
                    }
                    # A held job was NOT processed: withdraw the claim this
                    # attempt appended above, or the next drain would
                    # archive it unrun as 'already processed' instead of
                    # running it after sign-in.
                    try { RemoveClaim $id $jobHash }
                    catch { Log "job $id warning: could not withdraw the held job's claim ($($_.Exception.Message)); it may be reported already processed next drain" }
                    continue
                }
                $exePath = $ast.exe

                # Per-job execution lock, taken BEFORE any side effect
                # (gate finding M2): two executions under one id never
                # overlap (their status/artifact files are shared), and a
                # deferring attempt must leave ZERO trace - in 0.3.0 the
                # lock was taken after the running status and prompt file
                # were written, so a deferred attempt overwrote the
                # in-flight job's records and left a 'running' status a
                # later drain could mis-resolve as interrupted.
                # Contention means another execution of this id is in
                # flight - defer: withdraw the claim and leave the file
                # queued, unrun, with nothing written.
                $execLock = Enter-JobLock $id
                if (-not $execLock) {
                    try { RemoveClaim $id $jobHash }
                    catch { Log "job $id warning: could not withdraw the deferred job's claim ($($_.Exception.Message)); it may be reported already processed next drain" }
                    Log "job $id deferred: another execution under this id is in flight; left in the inbox for a later pass"
                    continue
                }

                ArchivePriorArtifacts $id
                WriteStatus $id $fields
                $statusOwned = $true
                Log "job $id start (adapter=$adapterId cwd=$cwdFull mode=$mode timeout=${timeoutSec}s)"
                WriteAtomic (Join-Path $outbox "$id.prompt.txt") $promptText

                # Compose the command line from validated pieces only.
                $cliArgs = @()
                foreach ($a in @($adapter.invoke.baseArgs)) { $cliArgs += [string]$a }
                if ($adapter.invoke.cliTimeoutArg) {
                    $suffix = if ($adapter.invoke.cliTimeoutSuffix) { [string]$adapter.invoke.cliTimeoutSuffix } else { '' }
                    $cliArgs += [string]$adapter.invoke.cliTimeoutArg
                    $cliArgs += ("{0}{1}" -f ($timeoutSec + 20), $suffix)
                }
                foreach ($a in @($modeArgs)) { $cliArgs += [string]$a }
                if ($model -and $adapter.modelArgs) {
                    foreach ($a in @($adapter.modelArgs)) { $cliArgs += ([string]$a).Replace('{value}', $model) }
                }
                if ($effort -and $adapter.effortArgs) {
                    foreach ($a in @($adapter.effortArgs)) { $cliArgs += ([string]$a).Replace('{value}', $effort) }
                }
                # Denylist scan of the ADAPTER-EMITTED args, done BEFORE the
                # prompt is substituted in (see Assert-NoBypassArgs). The raw
                # promptArgs TEMPLATES are adapter-authored too, so they are
                # scanned in this same pre-substitution pass - with {prompt}
                # still an unsubstituted placeholder token, the prompt TEXT
                # itself is never scanned.
                Assert-NoBypassArgs $cliArgs $adapterId 'the job invocation'
                $promptArgs = $null
                if ([string]$adapter.promptDelivery -eq 'argument') {
                    $promptArgs = $adapter.invoke.promptArgs
                    if (-not $promptArgs) { $promptArgs = @('{prompt}') }
                    Assert-NoBypassArgs @($promptArgs) $adapterId 'invoke.promptArgs'
                }

                $stdinText = $promptText
                if ([string]$adapter.promptDelivery -eq 'argument') {
                    $stdinText = ''
                    foreach ($a in @($promptArgs)) { $cliArgs += ([string]$a).Replace('{prompt}', $promptText) }
                }

                try {
                    # NF2 (a): the cliPid write is the VERY FIRST action
                    # after StartCapture returns - nothing may intervene
                    # between starting the CLI and recording its pid, so
                    # the pid-less window stays as small as this one write.
                    # Record the CLI's pid in the running status (M1): if
                    # this runner dies mid-flight, the next drain reads it
                    # to tell a live orphan from a corpse.
                    $handle = StartCapture $exePath $cliArgs $stdinText $timeoutSec $cwdFull
                    $fields.cliPid = $handle.proc.Id
                    WriteStatus $id $fields
                } catch {
                    Exit-JobLock $id $execLock
                    $execLock = $null
                    throw
                }
                $ctx = @{ id = $id; fields = $fields; jobFile = $jobFile; jobHash = $jobHash; handle = $handle; started = $started; execLock = $execLock }
                [void]$batch.Add($ctx)
                if ($batch.Count -ge [int]$cfg.maxConcurrency) { Complete-Batch $batch }
                continue
            }
            catch {
                $finished = Get-Date
                $fields.finishedAt = $finished.ToUniversalTime().ToString('o')
                $fields.durationSec = [math]::Round(($finished - $started).TotalSeconds, 1)
                $isValidation = $_.Exception.Message -like 'validation:*'
                $fields.state = if ($isValidation) { 'rejected' } else { 'failed' }
                $fields.error = $_.Exception.Message
                Log "job $id $($fields.state): $($_.Exception.Message)"
                if ($execLock) { Exit-JobLock $id $execLock; $execLock = $null }
                # If this attempt never reached its own 'running' status
                # (validation rejection, malformed JSON, claims failure),
                # the prior attempt's artifacts are archived BEFORE this
                # status replaces theirs - a rejected repost must not leave
                # the previous run's outputs sitting beside a status that
                # no longer describes them.
                if (-not $statusOwned) { try { ArchivePriorArtifacts $id } catch {} }
                # Same archive-before-final-status order as the success
                # path (see above): the job file leaves the inbox first.
                try { ArchiveJobFile $jobFile } catch {}
                try { WriteStatus $id $fields } catch {}
                try { SetClaimState $id $jobHash $fields.state } catch {}
                $jobsRun++
            }
        }
        if ($batch.Count -gt 0) { Complete-Batch $batch }
        if ($jobsRun -ge [int]$cfg.maxJobsPerDrain) { break }
        if (((Get-Date) - $drainStart).TotalMinutes -gt [int]$cfg.maxDrainMinutes) { break }
        # No-progress guard: if a whole pass processed nothing and the inbox
        # did not shrink (every remaining job is held or skipped), the drain
        # ends now instead of re-scanning the same files until the wall cap.
        $inboxNow = @(Get-ChildItem $inbox -Filter *.json -ErrorAction SilentlyContinue).Count
        if ($jobsRun -eq $passStartJobs -and $inboxNow -ge $passStartInbox) {
            Log 'no progress possible this drain (remaining jobs are held or skipped); exiting drain'
            break
        }
    }
    Log "drain complete: $jobsRun job(s), $([math]::Round($sessionSeconds, 0)) in-session seconds total"
}
catch {
    Log ("runner error: " + $_.Exception.Message)
    exit 1
}
finally {
    if ($lockStream) { try { $lockStream.Close() } catch {} }
    Remove-Item $lockFile -ErrorAction SilentlyContinue
}
