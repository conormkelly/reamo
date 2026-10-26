# One-time setup of a Windows PC as a harness runner, driven over SSH from a
# Mac or Linux machine. Run in an elevated Windows PowerShell, while the PC
# still has internet access (it installs OpenSSH Server and Python):
#
#   powershell -ExecutionPolicy Bypass -File setup-test-pc.ps1 `
#       -ControllerIp <controller address> -PublicKey "ssh-ed25519 AAAA... reamo-harness"
#
# It creates a standard (non-admin) local user that the harness runs as, and
# logs it in at boot: REAPER needs a desktop session, and Windows only draws
# windows for the session at the console. SSH accepts only that user, only
# by key, and only from ControllerIp; the key file is admin-owned, so the
# test user can't add keys of its own. Safe to run again.

param(
    [Parameter(Mandatory)] [string] $ControllerIp,
    [Parameter(Mandatory)] [string] $PublicKey,
    [string] $User = "reamotest"
)

$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated (Run as administrator) PowerShell."
}
if ($PublicKey -notmatch '^ssh-ed25519 \S+') {
    throw "PublicKey should be the one line in the .pub file, starting ssh-ed25519."
}

Write-Host "== Test user '$User'"
if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
    Write-Host "   exists; keeping it"
    $password = Read-Host "   Its password (for automatic logon)" -AsSecureString
} else {
    $password = Read-Host "   Choose a password for it" -AsSecureString
    New-LocalUser -Name $User -Password $password -PasswordNeverExpires `
        -FullName "REAmo test runner" -Description "Runs the REAmo harness; no admin rights" | Out-Null
    Add-LocalGroupMember -Group "Users" -Member $User
    Write-Host "   created (standard user)"
}

Write-Host "== OpenSSH Server"
$cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*"
if ($cap.State -ne "Installed") { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic
Start-Service sshd  # writes the default sshd_config on first start

$sshDir = "$env:ProgramData\ssh"
$keysFile = "$sshDir\${User}_authorized_keys"
Set-Content -Path $keysFile -Value "from=`"$ControllerIp`" $PublicKey" -Encoding ascii
icacls $keysFile /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null  # Administrators, SYSTEM

$configFile = "$sshDir\sshd_config"
$config = @()
$inOurs = $false
foreach ($line in Get-Content $configFile) {
    if ($line -eq "# >>> REAmo harness") { $inOurs = $true; continue }
    if ($line -eq "# <<< REAmo harness") { $inOurs = $false; continue }
    if (-not $inOurs) { $config += $line }
}
# Global settings must precede the first Match block, so they go first.
$ours = @(
    "# >>> REAmo harness",
    "AllowUsers $User",
    "PasswordAuthentication no",
    "PubkeyAuthentication yes",
    "AuthorizedKeysFile __PROGRAMDATA__/ssh/${User}_authorized_keys",
    "# <<< REAmo harness"
)
Set-Content -Path $configFile -Value ($ours + $config) -Encoding ascii
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Force `
    -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null
Restart-Service sshd

$ruleName = "OpenSSH-Server-In-TCP"
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $ruleName -DisplayName "OpenSSH Server (sshd)" `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
}
# Every profile: an offline PC's network is "Unidentified", which is Public.
Set-NetFirewallRule -Name $ruleName -Enabled True -Profile Any -RemoteAddress $ControllerIp
$rule = Get-NetFirewallRule -Name $ruleName
$remote = ($rule | Get-NetFirewallAddressFilter).RemoteAddress
if ($rule.Profile -ne "Any" -or $remote -ne $ControllerIp) {
    throw "The SSH firewall rule is profile '$($rule.Profile)', remote '$remote'; expected Any and $ControllerIp."
}
Write-Host "   SSH: only $User, key only, only from $ControllerIp, on any network"

Write-Host "== The PC's plugins, hidden from $User"
# REAPER always scans the standard VST3 and CLAP folders, and a plugin's
# activation window would block a test run's startup. The test user may
# not list them; everyone else's access is unchanged. Undo with:
#   icacls "<folder>" /remove:d $User
foreach ($dir in "$env:CommonProgramFiles\VST3", "$env:CommonProgramFiles\CLAP") {
    if (Test-Path $dir) {
        icacls $dir /deny "${User}:(RD)" | Out-Null
        Write-Host "   $dir"
    }
}

Write-Host "== Python (for the harness client)"
if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    winget install --id Python.Python.3.12 --scope machine --silent --accept-package-agreements --accept-source-agreements
} else {
    Write-Host "   already installed"
}

Write-Host "== No network prompts for the test REAPER and Python"
# REAmo's server and some tests listen on ports, and Windows asks whether to
# let them through the firewall: a prompt on the test desktop each time a
# new program listens. The tests only connect from this PC, which the
# firewall never filters, so both are refused network connections outright,
# which also stops Windows asking.
$python = (& py -3 -c "import sys; print(sys.executable)").Trim()
$rules = @{
    "REAmo test REAPER" = "$env:SystemDrive\Users\$User\reamo-harness\run\REAPER\reaper.exe"
    "REAmo test Python" = $python
}
foreach ($name in $rules.Keys) {
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Block -Program $rules[$name] | Out-Null
    Write-Host "   $name`: $($rules[$name])"
}

Write-Host "== Automatic logon as $User"
$autologon = Get-Command Autologon64.exe -ErrorAction SilentlyContinue
if (-not $autologon) {
    winget install --id Microsoft.Sysinternals.Autologon --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $autologon = Get-Command Autologon64.exe -ErrorAction SilentlyContinue
}
if ($autologon) {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
    # Autologon keeps the password as an LSA secret, not in the registry.
    & $autologon.Source $User $env:COMPUTERNAME $plain /accepteula
    $plain = $null
    Write-Host "   set; takes effect at the next restart"
} else {
    Write-Warning "Autologon wasn't found after installing; run Sysinternals Autologon yourself for $User."
}

Write-Host ""
Write-Host "Done. Restart, let $User log in, then from the controller: ssh reamo-win"
