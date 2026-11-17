# uninstall.ps1 - removes the SessionBridge scheduled task. By default the
# bridge root (jobs, results, logs) is left in place; pass -RemoveData to
# delete it as well.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 [-TaskName SessionBridge] [-TargetRoot <path>] [-RemoveData]
param(
    [string]$TargetRoot = (Join-Path $env:USERPROFILE 'session-bridge'),
    [string]$TaskName = 'SessionBridge',
    [switch]$RemoveData
)
$ErrorActionPreference = 'Stop'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "removed scheduled task '$TaskName'"
} else {
    Write-Output "scheduled task '$TaskName' not found (already removed?)"
}
if ($RemoveData) {
    if (Test-Path $TargetRoot) {
        Remove-Item $TargetRoot -Recurse -Force
        Write-Output "removed bridge root $TargetRoot"
    }
} else {
    Write-Output "bridge root kept at $TargetRoot (pass -RemoveData to delete it)"
}
