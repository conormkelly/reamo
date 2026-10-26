# Run one scenario on this PC's desktop and wait for it: what run.sh calls
# over SSH. A process started over SSH runs in a session with no desktop,
# so this hands the scenario to boot.ps1 through a scheduled task, which
# runs in the logged-in user's session, and waits for its done.txt.
#
#   powershell -ExecutionPolicy Bypass -File run-scenario.ps1 <scenario> <reaper-version> <out-name> [-TourOnly <words>]
#
# Exits with boot.ps1's status (124 if it didn't finish in time); its output
# is %USERPROFILE%\reamo-harness\boot.log, which run.sh copies back as is.

param(
    [Parameter(Mandatory)] [string] $Scenario,
    [Parameter(Mandatory)] [string] $Reaper,
    [Parameter(Mandatory)] [string] $OutName,
    [string] $TourOnly = "",
    [int] $TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"
$Root = Join-Path $env:USERPROFILE "reamo-harness"
$Done = Join-Path $Root "done.txt"
$Log = Join-Path $Root "boot.log"
$Task = "reamo-harness-boot"
$Boot = Join-Path $Root "stage\harness\windows\boot.ps1"

# A run the controller gave up on (interrupted, timed out) may still be going.
& { $ErrorActionPreference = "Continue"; schtasks /End /TN $Task 2>$null | Out-Null }  # none yet on a fresh PC
Get-Process reaper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item $Done, $Log -ErrorAction SilentlyContinue
@{ scenario = $Scenario; reaper = $Reaper; out = $OutName; tour_only = $TourOnly } | ConvertTo-Json |
    Set-Content -Path (Join-Path $Root "job.json") -Encoding ascii

# /IT: only while the user is logged on, in their session. The start time is
# required but unused; the task only ever runs on demand.
$action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Boot`""
schtasks /Create /TN $Task /TR $action /SC ONCE /ST 23:59 /IT /F | Out-Null
if ($LASTEXITCODE -ne 0) { throw "couldn't create the scheduled task $Task" }
schtasks /Run /TN $Task | Out-Null
if ($LASTEXITCODE -ne 0) { throw "couldn't start the scheduled task $Task (is $env:USERNAME logged in at the desktop?)" }

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while (-not (Test-Path $Done)) {
    if ((Get-Date) -gt $deadline) {
        schtasks /End /TN $Task | Out-Null
        Get-Process reaper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        [IO.File]::AppendAllText($Log, "RESULT: FAIL ($Scenario`: didn't finish within $TimeoutSeconds s)`r`n")
        exit 124
    }
    Start-Sleep -Milliseconds 250
}
exit [int](Get-Content $Done -Raw).Trim()
