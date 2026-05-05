# =================================================================================================
# Steam Deck: ROG Ally Graphics Driver Installer
# Installs the test-signed driver package produced by BuildDriver.ps1.
# =================================================================================================

$Host.UI.RawUI.BackgroundColor = 'Black'
$Host.UI.RawUI.ForegroundColor = 'Gray'
$ErrorActionPreference = "Stop"

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
} catch {
    $isAdmin = $false
}

if (-not $isAdmin) {
    Write-Host "Restarting with administrative privileges..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = "runas"
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { Write-Host "Elevation declined. Exiting." -ForegroundColor Red }
    exit
}

function Fail {
    param([string]$Message)
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to exit" }
    exit 1
}

function Force-InstallDisplayDriver {
    param(
        [string]$InfPath,
        [string]$HardwareId = "PCI\VEN_1002&DEV_163F&SUBSYS_01231002&REV_AE"
    )

    $newDevSource = @"
using System;
using System.Runtime.InteropServices;

public static class NewDevNative
{
    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool UpdateDriverForPlugAndPlayDevices(
        IntPtr hwndParent,
        string HardwareId,
        string FullInfPath,
        uint InstallFlags,
        out bool RebootRequired);
}
"@

    if (-not ("NewDevNative" -as [type])) {
        Add-Type -TypeDefinition $newDevSource -ErrorAction Stop
    }

    $rebootRequired = $false
    $installFlagForce = 0x00000001
    $ok = [NewDevNative]::UpdateDriverForPlugAndPlayDevices([IntPtr]::Zero, $HardwareId, $InfPath, $installFlagForce, [ref]$rebootRequired)
    $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()

    return [PSCustomObject]@{
        Success = $ok
        RebootRequired = $rebootRequired
        LastError = $lastError
    }
}

function Install-CertificateToStore {
    param(
        [string]$CertificatePath,
        [string]$StoreName
    )

    $certObject = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($StoreName, "LocalMachine")
    $store.Open("ReadWrite")
    try {
        $store.Add($certObject)
    } finally {
        $store.Close()
    }
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Definition -Parent }
Set-Location $ScriptDir

$DriversRoot = Join-Path $ScriptDir "DRIVERS"
$DisplayRoot = Join-Path $DriversRoot "Packages\Drivers\Display"
$TestCertPath = Join-Path $ScriptDir "SteamDeckTestDriverCert.cer"
$SteamDeckLcdHwid = "PCI\VEN_1002&DEV_163F&SUBSYS_01231002&REV_AE"

Clear-Host
Write-Host "Steam Deck: ROG Ally Graphics Driver Installer" -ForegroundColor Cyan
Write-Host ""
Write-Host "This installs the test-signed driver built by BuildDriver.ps1." -ForegroundColor Cyan
Write-Host "Windows test mode will be enabled for this driver path." -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path -LiteralPath $DisplayRoot)) {
    Fail "Display driver folder not found: $DisplayRoot`nRun BuildDriver.ps1 first."
}

if (-not (Test-Path -LiteralPath $TestCertPath)) {
    Fail "SteamDeckTestDriverCert.cer not found next to this script. Run BuildDriver.ps1 first."
}

Write-Host "Installing test certificate to Windows trust stores..." -ForegroundColor Cyan
Install-CertificateToStore -CertificatePath $TestCertPath -StoreName "Root"
Install-CertificateToStore -CertificatePath $TestCertPath -StoreName "TrustedPublisher"
Write-Host "Test certificate installed to Root and TrustedPublisher." -ForegroundColor Green

Write-Host "Enabling Windows test-signing mode..." -ForegroundColor Cyan
& bcdedit.exe /set testsigning on
if ($LASTEXITCODE -ne 0) { Fail "bcdedit failed to enable testsigning (exit $LASTEXITCODE)." }

Write-Host "Searching for patched display INF..." -ForegroundColor Cyan
$allInfFiles = @(Get-ChildItem -LiteralPath $DisplayRoot -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue)
$infCandidates = @($allInfFiles | Where-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
    $content -match '(?im)^\s*Class\s*=\s*Display\s*$' -and
    ($content -match [regex]::Escape($SteamDeckLcdHwid) -or $content -match 'AMD163F\.2')
})

if ($infCandidates.Count -eq 0) {
    $infCandidates = @($allInfFiles | Where-Object {
        $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
        $content -match '(?im)^\s*Class\s*=\s*Display\s*$' -and
        $content -match 'amdkmdag\.sys'
    })
}

if ($infCandidates.Count -eq 0) {
    Fail "No patched display INF found under: $DisplayRoot"
}

$InfPath = $infCandidates[0].FullName
Write-Host "Using INF:" -ForegroundColor Green
Write-Host "  $InfPath" -ForegroundColor Green
Write-Host ""

Write-Host "Adding driver package with pnputil..." -ForegroundColor Cyan
& pnputil.exe /add-driver $InfPath
if ($LASTEXITCODE -ne 0) { Fail "pnputil failed to add the driver package (exit $LASTEXITCODE)." }

Write-Host "Forcing selected display INF onto the Steam Deck LCD GPU..." -ForegroundColor Cyan
$forceResult = Force-InstallDisplayDriver -InfPath $InfPath -HardwareId $SteamDeckLcdHwid
if ($forceResult.Success) {
    Write-Host "Forced display driver install completed." -ForegroundColor Green
    if ($forceResult.RebootRequired) {
        Write-Host "Windows reports that a reboot is required." -ForegroundColor Yellow
    }
} else {
    Fail "Forced install failed. Win32 error: $($forceResult.LastError)."
}

Write-Host ""
Write-Host "Installation step completed." -ForegroundColor Green
Write-Host "Reboot Windows now." -ForegroundColor Yellow
Write-Host ""
Write-Host "After reboot, verify with:" -ForegroundColor Cyan
Write-Host "  pnputil /enum-devices /class Display /drivers" -ForegroundColor Gray
Write-Host ""
Write-Host "Expected: Status Started, driver from the patched ROG package, and no Code 52." -ForegroundColor Cyan
Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor DarkGray
try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to exit" }
