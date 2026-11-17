# fake-cli.ps1 - a stub "AI coding CLI" for the SessionBridge test harness.
# It records every invocation (argv + stdin) as a JSON line in $env:FAKECLI_LOG,
# and behaves according to $env:FAKECLI_MODE:
#   echo  (default) print FAKE OUTPUT, the argv, and the stdin it received
#   sleep           record 'sleep-start', sleep $env:FAKECLI_SLEEP seconds, exit 0
#   fail            write to stderr and exit 3
# --version and fake-auth are answered without reading stdin (the runner's
# version/auth probes close stdin immediately).

function Record($obj) {
    if ($env:FAKECLI_LOG) {
        $line = ($obj | ConvertTo-Json -Depth 4 -Compress)
        # Parallel drains run several fake CLIs at once: retry the append
        # briefly on a sharing violation instead of losing the record.
        for ($i = 0; $i -lt 25; $i++) {
            try { [IO.File]::AppendAllText($env:FAKECLI_LOG, $line + "`n"); return }
            catch { Start-Sleep -Milliseconds 40 }
        }
    }
}

if ($args -contains '--version') { Write-Output 'fake-cli 1.2.3'; exit 0 }
if ($args -contains 'fake-auth-fail') { [Console]::Error.WriteLine('Please sign in'); exit 1 }
if ($args -contains 'fake-auth') { Write-Output 'fake auth ok'; exit 0 }

$stdin = [Console]::In.ReadToEnd()
Record @{ argv = @($args | ForEach-Object { [string]$_ }); stdin = $stdin; phase = 'invoked' }

$mode = if ($env:FAKECLI_MODE) { $env:FAKECLI_MODE } else { 'echo' }
switch ($mode) {
    'sleep' {
        $secs = if ($env:FAKECLI_SLEEP) { [int]$env:FAKECLI_SLEEP } else { 30 }
        # Concurrency marker: while this invocation sleeps, a marker file
        # named by PID sits in $env:FAKECLI_MARKDIR, and the sleep-start
        # record reports how many markers coexisted - a direct overlap
        # measure for the parallel-drain test (wall-clock bounds are not
        # portable to throttled machines).
        $markFile = $null; $conc = $null
        if ($env:FAKECLI_MARKDIR) {
            if (-not (Test-Path $env:FAKECLI_MARKDIR)) { New-Item -ItemType Directory -Path $env:FAKECLI_MARKDIR -Force | Out-Null }
            $markFile = Join-Path $env:FAKECLI_MARKDIR "$PID.mark"
            [IO.File]::WriteAllText($markFile, "$PID")
            $conc = @(Get-ChildItem $env:FAKECLI_MARKDIR -Filter '*.mark' -ErrorAction SilentlyContinue).Count
        }
        # Spawn a marked child sleeper so the timeout test can prove the
        # runner kills the whole process TREE, not just the direct process.
        $selfExe = (Get-Process -Id $PID).Path
        $child = Start-Process -FilePath $selfExe -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300') -PassThru -NoNewWindow
        if ($env:FAKECLI_LOG) {
            [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $env:FAKECLI_LOG) 'fake-child.pid'), "$($child.Id)")
        }
        Record @{ phase = 'sleep-start'; seconds = $secs; childPid = $child.Id; concurrent = $conc }
        Start-Sleep -Seconds $secs
        if ($markFile) { Remove-Item $markFile -Force -ErrorAction SilentlyContinue }
        Record @{ phase = 'sleep-end' }
        Write-Output 'slept'
        exit 0
    }
    'fail' {
        [Console]::Error.WriteLine('fake failure')
        Record @{ phase = 'failed' }
        exit 3
    }
    default {
        Write-Output 'FAKE OUTPUT'
        Write-Output ("argv: " + ($args -join ' '))
        Write-Output '--- stdin ---'
        Write-Output $stdin
        exit 0
    }
}
