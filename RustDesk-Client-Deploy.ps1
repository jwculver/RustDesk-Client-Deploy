# ============================================================
# RustDesk Client Setup Script
# ------------------------------------------------------------
# Downloads and installs the latest RustDesk silently, applies
# custom server config, sets the permanent password, and
# validates the result.
#
# Usage:
#   .\RustDesk-Client-Deploy.ps1               # install latest + enforce config/password
#   .\RustDesk-Client-Deploy.ps1 -SkipInstall  # only re-apply config and password
# ============================================================

param([switch]$SkipInstall)
# === Self-elevate: relaunch as Administrator if not already ===
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($SkipInstall) { $argList += '-SkipInstall' }   # pass the switch through
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Warning "Administrator elevation was declined or failed. Exiting."
    }
    exit
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes Invoke-WebRequest much faster
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# === Create Temp Directory ===
if (-not (Test-Path "C:\Temp")) {
    New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
}

# === Logging ===
$logFile = "C:\Temp\rustdesk_combined.log"
function Write-Log {
    param([string]$msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts - $msg" | Out-File -Append -FilePath $logFile
    Write-Output $msg
}
Write-Log "Temp directory ready."

# === General Variables ===
$installerPath = "C:\Temp\rustdesk.exe"
$exePath       = "$env:ProgramFiles\RustDesk\rustdesk.exe"

# === Custom Configuration ===
$rendezvousAddress = "your.domain.com"
$relayAddress      = "your.domain.com"
$idServerPort      = "21116"
$publicKey         = "located in id_ed25519.pub"
# Assign the value random password to the password variable
$rustdesk_pw=(-join ((65..90) + (97..122) | Get-Random -Count 10 | % {[char]$_}))
#$rustdesk_pw      = "REPLACE_PASSWORD"

# Service profile (used by the RustDesk Windows service)
$svcConfigDir = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config"
$svcTomlPath  = Join-Path $svcConfigDir "RustDesk2.toml"

# === Configuration Template ===
# Note: 'whitelist' limits which IPs may connect directly. Remove that line
# if you need to connect from outside these ranges.
$tomlContent = @"
rendezvous_server = '${rendezvousAddress}:${idServerPort}'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '$rendezvousAddress'
relay-server = '$relayAddress'
key = '$publicKey'
direct-server = 'Y'
allow-remote-config-modification = 'Y'
verification-method = 'use-both-passwords'
"@

# === Find Latest Version and Download Link ===
function Get-LatestRustDesk {
    # Method 1: GitHub API
    try {
        $rel   = Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' `
                                   -Headers @{ 'User-Agent' = 'PowerShell' }
        $asset = $rel.assets | Where-Object { $_.name -match 'x86_64\.exe$' } | Select-Object -First 1
        if ($asset) {
            return [pscustomobject]@{ Version = $rel.tag_name.TrimStart('v'); Url = $asset.browser_download_url }
        }
    } catch {
        Write-Log "GitHub API lookup failed ($($_.Exception.Message)); trying redirect fallback."
    }

    # Method 2: read the tag from the /releases/latest redirect
    $req = [Net.HttpWebRequest]::Create('https://github.com/rustdesk/rustdesk/releases/latest')
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'PowerShell'
    $resp = $req.GetResponse()
    $loc  = $resp.Headers['Location']
    $resp.Close()
    if (-not $loc) { throw "Could not determine the latest RustDesk version." }
    $tag = $loc.TrimEnd('/').Split('/')[-1]
    $ver = $tag.TrimStart('v')
    return [pscustomobject]@{
        Version = $ver
        Url     = "https://github.com/rustdesk/rustdesk/releases/download/$tag/rustdesk-$ver-x86_64.exe"
    }
}

# === Download and Install RustDesk ===
if (-not $SkipInstall) {
    $latest = Get-LatestRustDesk
    Write-Log "Latest RustDesk version: $($latest.Version)"

    Write-Log "Downloading $($latest.Url)"
    if (Test-Path $installerPath) { Remove-Item $installerPath -Force }
    Invoke-WebRequest -Uri $latest.Url -OutFile $installerPath -UseBasicParsing
    Write-Log "Download complete ($([math]::Round((Get-Item $installerPath).Length / 1MB, 1)) MB)."

    Write-Log "Installing RustDesk silently..."
    Stop-Service -Name 'RustDesk' -Force -ErrorAction SilentlyContinue
    Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2

    # No -Wait: the installer launches RustDesk, which never exits and would hang the script
    $inst = Start-Process $installerPath -ArgumentList "--silent-install" -PassThru

    # Wait up to 3 minutes for the exe AND the service to appear
    $deadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 5
        $svcReady = Get-Service | Where-Object { $_.Name -match 'rustdesk' }
    } until (((Test-Path $exePath) -and $svcReady) -or (Get-Date) -gt $deadline)

    if (-not (Test-Path $exePath)) { throw "Installer finished but $exePath was not created." }
    Write-Log "Installation complete."

    # Clean up the installer process if it is still running
    if ($inst -and -not $inst.HasExited) { $inst.WaitForExit(10000) | Out-Null }
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
} else {
    Write-Log "SkipInstall set; not downloading or installing."
}
# === Make Sure the Service Exists ===
function Get-RDService {
    Get-Service | Where-Object { $_.Name -match 'rustdesk' } | Select-Object -First 1
}

# The installer registers the service a few seconds after it exits, so wait for it first
$service = $null
for ($i = 0; $i -lt 12 -and -not $service; $i++) {
    $service = Get-RDService
    if (-not $service) { Start-Sleep -Seconds 5 }
}

if (-not $service) {
    Write-Log "Service not found after waiting; installing it..."

    # Method 1: --install-service WITHOUT -Wait (the process doesn't exit on its own)
    $p = Start-Process $exePath -ArgumentList "--install-service" -PassThru
    for ($i = 0; $i -lt 6 -and -not $service; $i++) {
        Start-Sleep -Seconds 5
        $service = Get-RDService
    }

    # Method 2: create the service manually (this is what RustDesk registers)
    if (-not $service) {
        Write-Log "--install-service did not create it; creating service with sc.exe..."
        & sc.exe create RustDesk binPath= "`"$exePath`" --service" start= auto DisplayName= "RustDesk Service" | Out-Null
        Start-Sleep -Seconds 3
        $service = Get-RDService
    }

    if (-not $service) { throw "RustDesk service could not be installed." }
}
Write-Log "Service found: $($service.Name) ($($service.Status))"

# === Stop Service and Client ===
Write-Log "Stopping RustDesk service and client..."
Stop-Service $service.Name -Force -ErrorAction SilentlyContinue
Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

# === Apply Configuration (service profile + every user profile) ===
$configDirs = @($svcConfigDir)
$configDirs += Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin 'Public','Default','Default User','All Users' } |
    ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\RustDesk\config' }

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
foreach ($dir in $configDirs) {
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    $path = Join-Path $dir 'RustDesk2.toml'
    if (Test-Path $path) { Copy-Item $path "$path.bak" -Force }
    [IO.File]::WriteAllText($path, $tomlContent, $utf8NoBom)
    Write-Log "Config written to $path."
}

# === Start RustDesk Service Again ===
Write-Log "Starting service..."
Start-Service $service.Name
(Get-Service $service.Name).WaitForStatus('Running', '00:00:30')
Start-Sleep -Seconds 5

# === Set Permanent Password ===
# (called with & so the password is passed exactly, with no stray quotes)
Write-Log "Setting permanent password..."
& $exePath --password $rustdesk_pw | Out-Null
Start-Sleep -Seconds 5

# === Validation ===
# Config check: server and options present in the service config
foreach ($needle in $rendezvousAddress, 'allow-remote-config-modification') {
    if (Select-String -Path $svcTomlPath -Pattern $needle -SimpleMatch -Quiet) {
        Write-Log "[OK] '$needle' present in service config."
    } else {
        Write-Log "[WARN] '$needle' NOT found in $svcTomlPath"
    }
}

# Password check: a stored password entry should exist in RustDesk.toml
$svcMainToml = Join-Path $svcConfigDir 'RustDesk.toml'
if ((Test-Path $svcMainToml) -and (Select-String -Path $svcMainToml -Pattern '^\s*password\s*=' -Quiet)) {
    Write-Log "[OK] Permanent password entry found in service RustDesk.toml."
} else {
    Write-Log "[WARN] No password entry found in $svcMainToml. Test a connection to confirm."
}

$id = (& $exePath --get-id | Out-String).Trim()
# Show the value of the Password Variable
Write-Output "Password: $rustdesk_pw"
Write-Output "..............................................."
# Show the value of the Password Variable
Write-Log "Password: $rustdesk_pw"
Write-Log "RustDesk ID: $id"
Write-Log "Script finished."
Read-Host -Prompt "Press Enter to exit"