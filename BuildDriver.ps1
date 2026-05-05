# =================================================================================================
# Steam Deck: ROG Ally Graphics Driver Builder
# Builds a patched test-signed driver package for Windows test mode.
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

function Find-7Zip {
    $fromPath = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }

    $paths = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) { return $path }
    }

    return $null
}

function Find-WindowsKitTool {
    param(
        [string]$ToolName
    )

    $fromPath = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }

    $kitBin = "C:\Program Files (x86)\Windows Kits\10\bin"
    if (Test-Path -LiteralPath $kitBin) {
        $found = Get-ChildItem -LiteralPath $kitBin -Recurse -Filter $ToolName -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\x64\\" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    return $null
}

function Get-RelativePathCompat {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseUriPath = if ($BasePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) { $BasePath } else { $BasePath + [System.IO.Path]::DirectorySeparatorChar }
    $baseUri = New-Object System.Uri($baseUriPath)
    $fullUri = New-Object System.Uri($FullPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString()).Replace("/", "\")
}

function Get-InfCatalogName {
    param([string]$InfPath)

    $catalogLine = Get-Content -LiteralPath $InfPath | Where-Object { $_ -match "^\s*CatalogFile(?:\.[^=]+)?\s*=" } | Select-Object -First 1
    if ($catalogLine) {
        $name = (($catalogLine -split "=", 2)[1]).Trim()
        if ($name.ToLowerInvariant().EndsWith(".cat")) { return [System.IO.Path]::GetFileName($name) }
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($InfPath) + ".cat"
}

function New-CatalogWithMakeCat {
    param(
        [string]$DriverFolder,
        [string]$CatName,
        [string]$MakeCatPath
    )

    $catalogCdfPath = Join-Path $DriverFolder ([System.IO.Path]::GetFileNameWithoutExtension($CatName) + ".cdf")
    $catalogFiles = @(Get-ChildItem -LiteralPath $DriverFolder -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -notin @(".cat", ".bak", ".cdf") -and
            -not $_.Name.EndsWith(".bak", [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Sort-Object FullName)

    if ($catalogFiles.Count -eq 0) { Fail "No files found for catalog generation." }

    $cdfLines = New-Object System.Collections.Generic.List[string]
    $cdfLines.Add("[CatalogHeader]")
    $cdfLines.Add("Name=$CatName")
    $cdfLines.Add("PublicVersion=0x0000001")
    $cdfLines.Add("EncodingType=0x00010001")
    $cdfLines.Add("CATATTR1=0x10010001:OSAttr:2:10.0")
    $cdfLines.Add("[CatalogFiles]")

    $fileIndex = 1
    foreach ($file in $catalogFiles) {
        $relativePath = Get-RelativePathCompat -BasePath $DriverFolder -FullPath $file.FullName
        $cdfLines.Add("<hash>File$fileIndex=$relativePath")
        $fileIndex++
    }

    [System.IO.File]::WriteAllLines($catalogCdfPath, $cdfLines, [System.Text.Encoding]::ASCII)

    Push-Location $DriverFolder
    try {
        & $MakeCatPath -v $catalogCdfPath
        if ($LASTEXITCODE -ne 0) { Fail "makecat failed (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Definition -Parent }
Set-Location $ScriptDir

$DriverExe = Join-Path $ScriptDir "AMDDriver.exe"
$ExtractRoot = Join-Path $ScriptDir "DRIVERS"
$CertPfx = Join-Path $ScriptDir "SteamDeckTestDriverCert.pfx"
$CertCer = Join-Path $ScriptDir "SteamDeckTestDriverCert.cer"
$CertName = "Steam Deck Test Driver Signing"
$CertPassword = [Guid]::NewGuid().ToString("N") + [Guid]::NewGuid().ToString("N")
$SignToolPath = Find-WindowsKitTool -ToolName "signtool.exe"
$Inf2CatPath = Find-WindowsKitTool -ToolName "inf2cat.exe"
$MakeCatPath = Find-WindowsKitTool -ToolName "makecat.exe"

Clear-Host
Write-Host "Steam Deck: ROG Ally Graphics Driver Builder" -ForegroundColor Cyan
Write-Host ""
Write-Host "This builds a patched test-signed driver package." -ForegroundColor Cyan
Write-Host "InstallDriver.ps1 will enable Windows test mode during installation." -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $DriverExe)) {
    Fail "AMDDriver.exe not found next to this script."
}

$SevenZip = Find-7Zip
if (-not $SevenZip) { Fail "7-Zip not found. Install 7-Zip and make sure 7z.exe is available in Program Files or PATH." }
if (-not $SignToolPath) { Fail "signtool.exe not found. Install Windows SDK Signing Tools." }
if (-not $Inf2CatPath -and -not $MakeCatPath) { Fail "Neither inf2cat.exe nor makecat.exe was found. Install Windows SDK/WDK tools." }

if (Test-Path -LiteralPath $ExtractRoot) {
    Write-Host "Removing existing DRIVERS folder..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $ExtractRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
Write-Host "Extracting AMDDriver.exe..." -ForegroundColor Cyan
& $SevenZip x -y "-o$ExtractRoot" $DriverExe | Out-Null

$DisplayBase = Join-Path $ExtractRoot "Packages\Drivers\Display"
$sysMatches = @(Get-ChildItem -LiteralPath $DisplayBase -Recurse -Filter "amdkmdag.sys" -ErrorAction SilentlyContinue | Sort-Object Length -Descending)
if ($sysMatches.Count -eq 0) { Fail "amdkmdag.sys not found under $DisplayBase." }

$SysFilePath = $sysMatches[0].FullName
$DisplayInfFolder = $sysMatches[0].DirectoryName
while ($DisplayInfFolder -and -not (Get-ChildItem -LiteralPath $DisplayInfFolder -Filter "*.inf" -ErrorAction SilentlyContinue)) {
    $DisplayInfFolder = Split-Path $DisplayInfFolder -Parent
}

Write-Host "Display INF folder: $DisplayInfFolder" -ForegroundColor Green
Write-Host "Using SYS: $SysFilePath" -ForegroundColor Green

$backupPath = $SysFilePath + ".bak"
$patchOffset = 0x56550
$patchBytes = @(0x31, 0xC0, 0xC3, 0x90, 0x90)

Copy-Item -LiteralPath $SysFilePath -Destination $backupPath -Force
$sysBytes = [System.IO.File]::ReadAllBytes($SysFilePath)
$beforePatch = $sysBytes[$patchOffset..($patchOffset + 4)] | ForEach-Object { $_.ToString("X2") }
Write-Host "Before patch: $($beforePatch -join ' ')" -ForegroundColor Yellow
for ($i = 0; $i -lt $patchBytes.Length; $i++) { $sysBytes[$patchOffset + $i] = $patchBytes[$i] }
$afterPatch = $sysBytes[$patchOffset..($patchOffset + 4)] | ForEach-Object { $_.ToString("X2") }
Write-Host "After patch:  $($afterPatch -join ' ')" -ForegroundColor Yellow
[System.IO.File]::WriteAllBytes($SysFilePath, $sysBytes)
Write-Host "SYS patch applied." -ForegroundColor Green

$steamDeckHwid = '"%AMD163F.2%" = ati2mtag_VanGogh, PCI\VEN_1002&DEV_163F&SUBSYS_01231002&REV_AE'
$steamDeckString = 'AMD163F.2 = "AMD Radeon(TM) Graphics"'

$allInfFiles = @(Get-ChildItem -LiteralPath $DisplayInfFolder -Filter "*.inf" -ErrorAction SilentlyContinue)
$displayInfCandidates = @($allInfFiles | Where-Object {
    $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
    $content -match "(?im)^\s*Class\s*=\s*Display\s*$" -and
    $content -match "ati2mtag_VanGogh|VEN_1002&DEV_163F|amdkmdag\.sys"
})

if ($displayInfCandidates.Count -eq 0) { Fail "No compatible display INF found under $DisplayInfFolder." }

$InfPath = $displayInfCandidates[0].FullName
Write-Host "Using INF: $InfPath" -ForegroundColor Green

$infLines = Get-Content -LiteralPath $InfPath
if ($infLines -notcontains $steamDeckHwid) {
    $anchorIndex = -1
    for ($i = 0; $i -lt $infLines.Count; $i++) {
        if ($infLines[$i] -match [regex]::Escape("ati2mtag_VanGogh") -and $infLines[$i] -match "VEN_1002&DEV_163F") {
            $anchorIndex = $i
            break
        }
    }
    if ($anchorIndex -lt 0) { Fail "No VanGogh DEV_163F entry found in $InfPath." }

    $afterAnchor = if ($anchorIndex -lt $infLines.Count - 1) { $infLines[($anchorIndex + 1)..($infLines.Count - 1)] } else { @() }
    Set-Content -LiteralPath $InfPath -Value ($infLines[0..$anchorIndex] + $steamDeckHwid + $afterAnchor) -Encoding ASCII
    Write-Host "Inserted Steam Deck hardware ID." -ForegroundColor Green
}

$infLines = Get-Content -LiteralPath $InfPath
if ($infLines -notcontains $steamDeckString) {
    $strAnchorIndex = -1
    for ($i = 0; $i -lt $infLines.Count; $i++) {
        if ($infLines[$i] -match [regex]::Escape("AMD163F.1")) {
            $strAnchorIndex = $i
            break
        }
    }
    if ($strAnchorIndex -ge 0) {
        $afterStrAnchor = if ($strAnchorIndex -lt $infLines.Count - 1) { $infLines[($strAnchorIndex + 1)..($infLines.Count - 1)] } else { @() }
        Set-Content -LiteralPath $InfPath -Value ($infLines[0..$strAnchorIndex] + $steamDeckString + $afterStrAnchor) -Encoding ASCII
        Write-Host "Inserted Steam Deck display string." -ForegroundColor Green
    }
}

Write-Host "Creating or reusing test-signing certificate..." -ForegroundColor Cyan
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq "CN=$CertName" } |
    Select-Object -First 1

if (-not $cert) {
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=$CertName" `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -KeyExportPolicy Exportable `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -NotAfter (Get-Date).AddYears(10)
}

$securePassword = ConvertTo-SecureString -String $CertPassword -AsPlainText -Force
Export-PfxCertificate -Cert $cert -FilePath $CertPfx -Password $securePassword -Force | Out-Null
Export-Certificate -Cert $cert -FilePath $CertCer -Force | Out-Null

Write-Host "Temporary PFX: $CertPfx" -ForegroundColor Green
Write-Host "CER: $CertCer" -ForegroundColor Green

Write-Host "Signing SYS with test certificate..." -ForegroundColor Cyan
& $SignToolPath sign /fd SHA256 /f $CertPfx /p $CertPassword $SysFilePath
if ($LASTEXITCODE -ne 0) { Fail "SYS signing failed (exit $LASTEXITCODE)." }

$catBaseName = Get-InfCatalogName -InfPath $InfPath
$CatFile = Join-Path $DisplayInfFolder $catBaseName

if (Test-Path -LiteralPath $CatFile) {
    Move-Item -LiteralPath $CatFile -Destination "$CatFile.bak" -Force
}

Write-Host "Generating driver catalog..." -ForegroundColor Cyan
if ($Inf2CatPath) {
    & $Inf2CatPath "/driver:$DisplayInfFolder" "/os:10_X64"
    if ($LASTEXITCODE -ne 0) { Fail "inf2cat failed (exit $LASTEXITCODE)." }
} else {
    New-CatalogWithMakeCat -DriverFolder $DisplayInfFolder -CatName $catBaseName -MakeCatPath $MakeCatPath
}

if (-not (Test-Path -LiteralPath $CatFile)) {
    $generatedCat = Get-ChildItem -LiteralPath $DisplayInfFolder -Filter "*.cat" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($generatedCat) { $CatFile = $generatedCat.FullName } else { Fail "Catalog generation completed but no .cat file was found." }
}

Write-Host "Signing CAT with test certificate..." -ForegroundColor Cyan
& $SignToolPath sign /fd SHA256 /f $CertPfx /p $CertPassword $CatFile
if ($LASTEXITCODE -ne 0) { Fail "Catalog signing failed (exit $LASTEXITCODE)." }

Remove-Item -LiteralPath $CertPfx -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Build complete." -ForegroundColor Green
Write-Host "Next: run InstallDriver.ps1 on the Steam Deck Windows install." -ForegroundColor Yellow
Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor DarkGray
try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to exit" }
