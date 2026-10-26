# Run one scenario against a fresh REAPER on this Windows desktop: the
# Windows counterpart of boot.sh. run-scenario.ps1 starts it as a scheduled
# task in the logged-in session, because REAPER needs a desktop to draw on
# and the test needs to see it; a process started over SSH has neither.
#
# Reads job.json beside the harness root (scenario, REAPER version, output
# directory), writes everything it prints to boot.log, and its exit status
# to done.txt: 0 only if the scenario's test.py passed AND REAPER is still
# alive afterwards; 77 when the scenario skipped itself.
#
# Layout under %USERPROFILE%\reamo-harness (set up by run.sh):
#   reaper\<version>\  pristine portable REAPER, unpacked from the installer
#   stage\             harness\ (this directory's parent), web\, effects\,
#                      fixtures\, reaper_reamo.dll, optional reaper-license.rk
#   run\REAPER\        this scenario's REAPER, copied fresh from reaper\<version>
#   out\<name>\        screenshots, copied back to the controller
#
# Scenarios and harness.lua use /tmp paths. Windows reads a path starting
# with / as on the current drive, so /tmp is C:\tmp here, emptied per run.

$ErrorActionPreference = "Stop"
$Root = Join-Path $env:USERPROFILE "reamo-harness"
$Log = Join-Path $Root "boot.log"
$Done = Join-Path $Root "done.txt"

function Say([string] $text) {
    # UTF-8 without the byte-order mark PowerShell 5.1's -Encoding UTF8 adds.
    [IO.File]::AppendAllText($Log, "$text`r`n")
}

function Finish([int] $status) {
    Get-Process reaper -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Set-Content -Path $Done -Value $status -Encoding ascii
    exit $status
}

try {
    $job = Get-Content (Join-Path $Root "job.json") -Raw | ConvertFrom-Json
    $Scenario = $job.scenario
    $Stage = Join-Path $Root "stage"
    $Harness = Join-Path $Stage "harness"
    $SDir = Join-Path $Harness "scenarios\$Scenario"
    $Pristine = Join-Path $Root "reaper\$($job.reaper)"
    $ReaperHome = Join-Path $Root "run\REAPER"
    $Tmp = "C:\tmp"
    $Ready = "$Tmp\harness_fixture_ready"
    $Out = Join-Path $Root "out\$($job.out)"

    # A REAPER left by an interrupted run would take this run's port.
    Get-Process reaper -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
    # Folder windows an earlier run opened (Open Log Folder) stay open.
    & { $ErrorActionPreference = "Continue"
        & py -3 -c "import sys; sys.path.insert(0, r'$Harness'); import win_desktop; win_desktop.close_explorer_windows('REAPER'); win_desktop.close_explorer_windows('Logs')" 2>$null }
    foreach ($dir in @($Tmp, $ReaperHome, $Out)) {
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        New-Item -ItemType Directory -Force $dir | Out-Null
    }

    # robocopy's exit codes below 8 all mean success.
    robocopy $Pristine $ReaperHome /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "copying REAPER $($job.reaper) failed (robocopy $LASTEXITCODE)" }

    # REAPER runs with -cfgfile reaper.ini, which makes this folder its
    # resource folder (a reaper.ini beside reaper.exe alone doesn't, on
    # Windows: REAPER then sets up %APPDATA%\REAPER). Plugin paths name an
    # empty folder, so no plugin's own activation window can block startup.
    # REAPER adds the standard VST3 folders to the path whatever it says;
    # setup-test-pc.ps1 keeps the test user from listing those. Audio mode 4
    # is REAPER's Dummy Audio device, which still runs the full audio path
    # (left unset, REAPER asks for a device at startup). verchk=0
    # stops the update check, whose modal
    # would block the main thread (as would the unlicensed evaluation nag);
    # diskcheck=0 and promptendrec=0 skip the low-disk-space warning and the
    # "keep recorded files?" prompt.
    $noPlugins = "$ReaperHome\NoPlugins"
    New-Item -ItemType Directory -Force $noPlugins | Out-Null
    Set-Content -Path "$ReaperHome\reaper.ini" -Encoding ascii -Value @(
        "[REAPER]", "vstpath64=$noPlugins", "vstpath=$noPlugins", "clap_path_win64=$noPlugins",
        "lv2path_win64=$noPlugins", "verchk=0", "diskcheck=0", "promptendrec=0",
        "[audioconfig]", "mode=4"
    )
    if (Test-Path "$Stage\reaper-license.rk") { Copy-Item "$Stage\reaper-license.rk" $ReaperHome }
    foreach ($d in "UserPlugins", "Scripts", "reaper_www_root", "Effects") {
        New-Item -ItemType Directory -Force "$ReaperHome\$d" | Out-Null
    }
    Copy-Item "$Stage\effects\*" "$ReaperHome\Effects" -Recurse -Force
    Copy-Item "$Stage\reaper_reamo.dll" "$ReaperHome\UserPlugins\reaper_reamo.dll"
    Copy-Item "$Stage\web" "$ReaperHome\reaper_www_root\web" -Recurse
    # Writable copy: REAPER writes peak files beside media, as in a real project dir.
    Copy-Item "$Stage\fixtures" "$Tmp\fixtures" -Recurse
    # Fixtures load files from /harness, where the container mounts this
    # directory: C:\harness here, a junction to the staged harness. rmdir
    # removes only the junction; Remove-Item -Recurse would follow it.
    if (Test-Path C:\harness) { cmd /c rmdir C:\harness }
    New-Item -ItemType Junction -Path C:\harness -Target $Harness | Out-Null
    Copy-Item "$Harness\harness.lua" "$ReaperHome\Scripts\harness.lua"
    if (Test-Path "$SDir\startup.lua") {
        Copy-Item "$SDir\startup.lua" "$ReaperHome\Scripts\fixture.lua"
    } else {
        Set-Content -Path "$ReaperHome\Scripts\fixture.lua" -Encoding ascii -Value @(
            'dofile(reaper.GetResourcePath() .. "/Scripts/harness.lua")', 'harness.ready()'
        )
    }
    # The fixture runs under pcall: an uncaught Lua error would otherwise open
    # REAPER's modal error dialog and hang the run until the timeout.
    Set-Content -Path "$ReaperHome\Scripts\__startup.lua" -Encoding ascii -Value @(
        'local ok, err = pcall(dofile, reaper.GetResourcePath() .. "/Scripts/fixture.lua")',
        'if not ok then',
        '  local f = io.open("/tmp/harness_lua.log", "a")',
        '  f:write("FIXTURE ERROR: " .. tostring(err) .. "\n")',
        '  f:close()',
        'end'
    )

    $env:HARNESS_SCENARIO = $Scenario
    $env:HARNESS_OUT = $Out
    $env:TOUR_ONLY = "$($job.tour_only)"
    $env:PYTHONPATH = $Harness
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    $env:PYTHONDONTWRITEBYTECODE = "1"
    # /tmp resolves against the current directory's drive.
    Set-Location C:\
    [Environment]::CurrentDirectory = "C:\"

    function Shot([string] $name) {
        # A native program's stderr is an error record to PowerShell; here it
        # only means no screenshot.
        $ErrorActionPreference = "Continue"
        & py -3 -c "import reamo_client; reamo_client.screenshot('$name')" 2>$null | Out-Null
        if (Test-Path "$Out\$name.png") { Say "screenshot: out/$($job.out)/$name.png" }
    }

    $reaper = Start-Process -FilePath "$ReaperHome\reaper.exe" `
        -ArgumentList "-newinst", "-nosplash", "-cfgfile", "`"$ReaperHome\reaper.ini`"" `
        -WorkingDirectory $ReaperHome -PassThru
    $null = $reaper.Handle  # held from the start, so ExitCode is readable after a crash

    # Ready = the fixture has run and the extension's server accepts connections.
    $ok = $false
    for ($i = 0; $i -lt 240; $i++) {
        if ((Test-Path $Ready) -and -not $reaper.HasExited) {
            $tcp = New-Object Net.Sockets.TcpClient
            try { $tcp.Connect("127.0.0.1", 9224); $ok = $true } catch { } finally { $tcp.Dispose() }
            if ($ok) { break }
        }
        Start-Sleep -Milliseconds 250
    }
    if (Test-Path "$Tmp\harness_lua.log") {
        Get-Content "$Tmp\harness_lua.log" -Encoding UTF8 | ForEach-Object { Say "[lua] $_" }
    }
    if ($ok -and -not (Test-Path "$ReaperHome\Logs\reamo.log")) {
        Say "--- REAPER isn't using $ReaperHome as its resource folder (no Logs\reamo.log there)"
        $ok = $false
    }
    if (-not $ok) {
        Shot "not-ready"
        $ErrorActionPreference = "Continue"
        $titles = & py -3 -c "import win_desktop; print('|'.join(f'{t} ({e})' for _, t, e in win_desktop.all_visible_windows()))"
        Say "--- windows: $titles"
        $reaperWindows = & py -3 -c "import win_desktop; [print(win_desktop.describe(h)) for h, _ in win_desktop.visible_windows()]"
        $reaperWindows | ForEach-Object { Say "--- REAPER window: $_" }
        Say "RESULT: FAIL ($Scenario`: REAPER/extension not ready within 60 s)"
        Finish 2
    }

    # cmd keeps the test's stdout and stderr in order, byte for byte.
    cmd /c "py -3 `"$SDir\test.py`" >> `"$Log`" 2>&1"
    $testStatus = $LASTEXITCODE
    Start-Sleep -Seconds 1  # let a deferred crash surface

    $logFile = "$ReaperHome\Logs\reamo.log"
    # Kept with the screenshots: REAmo's own account of the run.
    if (Test-Path $logFile) { Copy-Item $logFile "$Out\reamo.log" }
    if (Test-Path $logFile) {
        $errors = Select-String -Path $logFile -Pattern "ERROR|PANIC" -Encoding UTF8 |
            Where-Object { $_.Line -notmatch "FastTimer" } | Select-Object -First 20
        if ($errors) {
            Say "--- reamo.log errors"
            $errors | ForEach-Object { Say $_.Line }
        }
    }
    if ($reaper.HasExited) {
        Say "--- REAPER exited (status $($reaper.ExitCode))"
        Say "RESULT: FAIL ($Scenario`: REAPER crashed)"
        Finish 3
    }
    if ($testStatus -eq 77) {
        Say "RESULT: SKIP ($Scenario)"
        Finish 77
    }
    if ($testStatus -ne 0) {
        Shot "failed"
        Say "RESULT: FAIL ($Scenario`: assertions failed)"
        Finish 1
    }
    Say "RESULT: PASS ($Scenario)"
    Finish 0
} catch {
    Say "RESULT: FAIL (harness error: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber))"
    Finish 4
}
