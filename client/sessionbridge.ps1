# sessionbridge.ps1 - SessionBridge client for Windows: submit jobs, read results.
#
# Usage:
#   sessionbridge.ps1 -Action submit -JobFile <job.json> [-Wait] [-WaitSeconds 1200]
#   sessionbridge.ps1 -Action wait   -Id <job-id> [-WaitSeconds 1200]
#   sessionbridge.ps1 -Action status -Id <job-id>
#   sessionbridge.ps1 -Action output -Id <job-id>
#
# Transport (parameters):
#   -BridgeDir <path>          Local bridge root (same machine, mounted, or synced folder).
#   -HostName <user@host>      ssh/scp target for the runner machine, with
#   -RemoteDir <path>          the bridge root on that machine.
#   -TaskName SessionBridge    Scheduled-task name fired over ssh after a submit.
#
# Exit codes for submit -Wait and wait:
#   0 = job completed, 1 = job failed/rejected/timed-out/interrupted,
#   2 = waited the full time with no final status (a wait timeout, not a failure)
param(
    [Parameter(Mandatory = $true)][ValidateSet('submit', 'wait', 'status', 'output')][string]$Action,
    [string]$JobFile,
    [string]$Id,
    [switch]$Wait,
    [int]$WaitSeconds = 1200,
    [string]$BridgeDir,
    [string]$HostName,
    [string]$RemoteDir,
    [string]$TaskName = 'SessionBridge'
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)

function Fetch($rel, $dest) {
    if ($BridgeDir) {
        $src = Join-Path $BridgeDir $rel
        if (Test-Path $src) { Copy-Item $src $dest -Force; return $true }
        return $false
    }
    & scp -q "${HostName}:${RemoteDir}/$rel" $dest 2>$null
    return ($LASTEXITCODE -eq 0)
}
function Put($src, $rel) {
    if ($BridgeDir) {
        Copy-Item $src (Join-Path $BridgeDir $rel) -Force
    } else {
        & scp -q $src "${HostName}:${RemoteDir}/$rel"
        if ($LASTEXITCODE -ne 0) { throw 'scp to the bridge inbox failed' }
    }
}
function Fire {
    if (-not $BridgeDir -and $HostName) {
        & ssh $HostName "powershell -NoProfile -Command `"Start-ScheduledTask -TaskName $TaskName`"" 2>$null | Out-Null
    }
}
function DoWait($jobId, $seconds, $notBefore) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sb-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Fire
        $elapsed = 0
        while ($elapsed -lt $seconds) {
            $statusPath = Join-Path $tmp 'status.json'
            if (Fetch "outbox/$jobId.status.json" $statusPath) {
                try {
                    $d = [IO.File]::ReadAllText($statusPath, $utf8) | ConvertFrom-Json
                    $startedEp = 0
                    if ($d.startedAt) { $startedEp = [DateTimeOffset]::Parse([string]$d.startedAt).ToUnixTimeSeconds() }
                    $state = if ($startedEp -ge ($notBefore - 10)) { [string]$d.state } else { 'stale' }
                    if ($state -and $state -ne 'running' -and $state -ne 'stale') {
                        Get-Content $statusPath -Raw
                        $outPath = Join-Path $tmp 'out.txt'
                        if (Fetch "outbox/$jobId.out.txt" $outPath) { Write-Output '--- output ---'; Get-Content $outPath -Raw }
                        if ($state -eq 'completed') { exit 0 } else { exit 1 }
                    }
                } catch {}
            }
            Start-Sleep -Seconds 5
            $elapsed += 5
            if (($elapsed % 60) -eq 0) { Fire }
        }
        Write-Error "no final status after ${seconds}s (exit 2 = wait timeout, not a job failure)"
        exit 2
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

switch ($Action) {
    'submit' {
        if (-not $JobFile) { throw '-JobFile is required for submit' }
        $job = [IO.File]::ReadAllText($JobFile, $utf8) | ConvertFrom-Json
        # Mode is a required, explicit job field (runner 0.3.0): refuse
        # here, with a clear message, rather than submitting a job the
        # runner would only reject.
        if ($job.mode -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$job.mode)) {
            throw "job file has no explicit 'mode' - every job must declare its mode (see the adapter file for the modes it defines); refusing to submit"
        }
        $Id = [string]$job.id
        $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Put $JobFile "inbox/$Id.json"
        Write-Output "submitted job $Id"
        Fire
        if ($Wait) { DoWait $Id $WaitSeconds $since }
    }
    'wait'   { DoWait $Id $WaitSeconds 0 }
    'status' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sb-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            if (Fetch "outbox/$Id.status.json" (Join-Path $tmp 's.json')) { Get-Content (Join-Path $tmp 's.json') -Raw }
            else { Write-Error "no status found for job $Id"; exit 1 }
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    'output' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sb-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            if (Fetch "outbox/$Id.out.txt" (Join-Path $tmp 'o.txt')) { Get-Content (Join-Path $tmp 'o.txt') -Raw }
            else { Write-Error "no output found for job $Id"; exit 1 }
        } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
