# install.ps1 - installs SessionBridge for the current user and registers the
# scheduled task that runs jobs inside this user's interactive session.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-TargetRoot <path>] [-TaskName SessionBridge] [-TickMinutes 15]
#
# Default target root: %USERPROFILE%\session-bridge
# The install copies the runner + adapters, creates inbox/outbox/done, seeds the
# config from sessionbridge.config.example.json (never overwriting an existing
# config), and records a SHA-256 manifest in sessionbridge.expected.sha256
# covering the runner, the config, and every installed adapter - the runner
# verifies the whole manifest on every start and refuses on any mismatch.
param(
    [string]$TargetRoot = (Join-Path $env:USERPROFILE 'session-bridge'),
    [string]$TaskName = 'SessionBridge',
    [int]$TickMinutes = 15
)
$ErrorActionPreference = 'Stop'
$repoWindows = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $repoWindows
$utf8 = New-Object Text.UTF8Encoding($false)

foreach ($d in @($TargetRoot, (Join-Path $TargetRoot 'inbox'), (Join-Path $TargetRoot 'outbox'), (Join-Path $TargetRoot 'done'), (Join-Path $TargetRoot 'adapters'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

$profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
if (-not ([IO.Path]::GetFullPath($TargetRoot).TrimEnd('\').StartsWith($profileRoot + '\', [StringComparison]::OrdinalIgnoreCase))) {
    Write-Warning "TargetRoot is outside your user profile. Remember: anyone who can write to the bridge root - especially its inbox - can run code as you. Only install into a folder whose permissions you control."
}

Copy-Item (Join-Path $repoWindows 'sessionbridge.ps1') (Join-Path $TargetRoot 'sessionbridge.ps1') -Force
Get-ChildItem (Join-Path $repoRoot 'adapters') -Filter *.json | Where-Object { $_.Name -notlike '*.example.json' } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $TargetRoot (Join-Path 'adapters' $_.Name)) -Force
}

$configPath = Join-Path $TargetRoot 'sessionbridge.config.json'
if (-not (Test-Path $configPath)) {
    Copy-Item (Join-Path $repoRoot 'sessionbridge.config.example.json') $configPath
    Write-Output "seeded default config at $configPath (mode ceiling: readonly - edit it deliberately to allow more)"
} else {
    Write-Output "existing config kept at $configPath"
}

# Record the integrity manifest: one SHA-256 per covered file (runner,
# config, every installed adapter). Re-run this installer after editing any
# of them - the runner refuses to run while the manifest is stale.
$covered = @('sessionbridge.ps1', 'sessionbridge.config.json') + @(
    Get-ChildItem (Join-Path $TargetRoot 'adapters') -Filter *.json | Sort-Object Name | ForEach-Object { 'adapters/' + $_.Name })
$manifestLines = foreach ($rel in $covered) {
    $full = Join-Path $TargetRoot ($rel -replace '/', '\')
    "{0}  {1}" -f $rel, (Get-FileHash $full -Algorithm SHA256).Hash
}
[IO.File]::WriteAllText((Join-Path $TargetRoot 'sessionbridge.expected.sha256'), ($manifestLines -join "`n") + "`n", $utf8)
Write-Output "recorded integrity manifest ($($covered.Count) files) in sessionbridge.expected.sha256"

$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$runnerPath = Join-Path $TargetRoot 'sessionbridge.ps1'
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerPath`""
$logon     = New-ScheduledTaskTrigger -AtLogOn -User $identity
$tick      = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $TickMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $tick) -Principal $principal -Settings $settings -Force | Out-Null

Write-Output ""
Write-Output "SessionBridge installed:"
Write-Output "  bridge root : $TargetRoot"
Write-Output "  task        : $TaskName (runs as $identity, interactive session only)"
Write-Output "  next steps  : sign in to your coding CLI interactively, drop a job JSON into the inbox,"
Write-Output "                run Start-ScheduledTask -TaskName $TaskName, and read outbox\<id>.status.json"
