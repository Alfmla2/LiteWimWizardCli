#Requires -RunAsAdministrator
<#
.SYNOPSIS
    WIM Wizard - Windows 11 x64 Image Servicing Tool

.DESCRIPTION
    Services a Windows 11 25H2/24H2 x64 WIM/ESD file for personal deployment.
    Takes a folder containing install.wim/install.esd and a LanguagesAndOptionalFeatures
    folder with LP/FoD cab files, then:
      - Detects Windows version from the mounted WIM
      - Downloads LCU + checkpoint (KB5043080) + .NET CU from Microsoft Update Catalog
      - Injects language packs and Language.* FoDs (when -Languages given)
      - Applies user-selected Features on Demand (-FoDList)
      - Removes provisioned Store Appx packages (built-in list or -AppxListPath)
      - Applies offline Defender platform/engine/definitions (KB4568292)
      - Exports and compresses the finished WIM

    To apply updates only to an existing WIM, place it as install.wim in WimEsdPath
    and run with -SkipLanguagePacks -SkipAppxRemoval -SkipDefenderUpdate.

.PARAMETER WimEsdPath
    Folder containing install.wim or install.esd (searched recursively).
    Default: <ScriptFolder>\WimEsd

.PARAMETER LanguagesAndOptionalFeaturesPath
    Folder containing language pack and FoD cab files.
    Default: <ScriptFolder>\LanguagesAndOptionalFeatures
    When not set, auto-detects <WimEsdPath>\LanguagesAndOptionalFeatures.

.PARAMETER UpdatePath
    Override folder with pre-downloaded .msu/.cab files.
    When empty: auto-download from Microsoft Update Catalog.

.PARAMETER OutputPath
    Output WIM path (folder to auto-generate name, or full path with .wim).

.PARAMETER WimIndex
    Force a specific WIM index. 0 = auto-detect Enterprise.

.PARAMETER Languages
    Comma-separated 2-letter codes (e.g. "ru", "de,fr"). Any code from
    the supported list works. -Unattended with no -Languages = English-only.

.PARAMETER FoDList
    Comma-separated Features on Demand to install. Short keys:
      PowerShell-ISE, SnippingTool, VBSCRIPT, WinOcr, DeveloperMode,
      Ethernet, Wifi, Notepad
    Any other value is treated as a DISM capability name:
      - Value containing "~" is used as-is (e.g. "Microsoft.Windows.Foo~~~~0.0.1.0")
      - Value without "~" gets "~~~~" appended (e.g. "NetFX3" -> "NetFX3~~~~")

.PARAMETER DriverPath
    Root folder to recurse for driver .inf packages to inject.

.PARAMETER DriverListPath
    XML file with a pre-selected list of driver INF paths (overrides DriverPath).
    Format: <DriverList><Driver><InfPath>...</InfPath></Driver>...</DriverList>

.PARAMETER AppxListPath
    XML file with a custom Appx removal list (overrides built-in default).
    Format: <AppxRemovalList><Package><Id>...</Id></Package>...</AppxRemovalList>

.PARAMETER SkipUpdates
    Skip downloading and applying LCU / checkpoint / .NET CU.

.PARAMETER SkipLanguagePacks
    Skip language pack and Language.* FoD injection.

.PARAMETER SkipAppxRemoval
    Skip removal of provisioned Appx packages.

.PARAMETER SkipDefenderUpdate
    Skip the offline Defender platform/engine/definitions update.

.PARAMETER Unattended
    No interactive prompts (uses defaults for all paths).

.PARAMETER DebugBuild
    Extra DISM diagnostics.

    Version : 7.0.1
    Date    : 2026-11-24
    Requires: Windows PowerShell 5.1+, Administrator, DISM

    CHANGELOG 7.0.1
    Fix: documented and validated the required layout of
    LanguagesAndOptionalFeatures. Removing locale-specific .cab files
    for a target locale (or leaving <43 per locale) causes 0x80070002
    on the main LP install, because DISM resolves satellite packages
    per-locale (LP + LanguageFeatures + ~38 FoD satellites incl.)
    Cabs for locales already in the image (en-US) are NOT needed —
    DISM resolves those against installed components.
    New Test-LPSourceComplete pre-flight in Step 2:
     - missing metadata (FoDMetadata_Client.cab, FodMetadataServicing-*,
       metadata\DesktopTargetCompDB_*) = fatal
     - per-locale cab count < 43 = warning with likely-missing list
     - per-locale required files (LP, LanguageFeatures-Basic,
       DesktopTargetCompDBForISO[_FOD]_<locale>) = warning
     - prints per-locale cab counts (green >= 43, yellow 30-42, red < 30)

    CHANGELOG 7.0.0
    - Removed -PatchExistingWim and all patch-mode code. To apply updates
      only, place the existing WIM as install.wim and run with
      -SkipLanguagePacks -SkipAppxRemoval -SkipDefenderUpdate.
    - Removed Dismount-AllISOs no-op stub and every call site.
    - Removed $Architecture variable (already unused after 6.1.0).
    - Replaced corporate FoD catalog (NetFx3, RsatAD, RsatGPO, RsatSrvMgr)
      with a home-user catalog: PowerShell-ISE, SnippingTool, VBSCRIPT,
      WinOcr, DeveloperMode, Ethernet, Wifi, Notepad.
      Also accepts arbitrary capability names via fallback.
    - Removed Step 15a (NetFx3 special-case). "NetFX3" in -FoDList now
      works through the generic FoD path ("NetFX3~~~~").
    - Decoupled from WimWizard-GUI.ps1 (docs/help only). -AppxListPath
      and -DriverListPath remain as plain XML inputs for any caller.
    - Help examples reduced to -Languages "ru"; language map unchanged.
    - Fixed Step 3 checkpoint pre-check: was on "elseif" and skipped
      after manual update-path entry; now always runs when path known.
    - Cleanup: removed unused PatchMode-related variables and dead code.

    CHANGELOG 6.3.0
    - Added Resolve-WimEsdFolder; removed ISO mounting entirely.
      -SourceFolder renamed to -WimEsdPath; added
      -LanguagesAndOptionalFeaturesPath.

    CHANGELOG 6.2.x
    - Restored checkpoint KB5043080; LCU pruning preserves it;
      $lcuFile selector excludes it. Fixed -SkipUpdates guard.

    CHANGELOG 6.1.0
    - Removed SCCM/MECM, ARM64, SafeOS, WinRE, Inbox App Language Fix.

.LINK
    https://admin.microsoft.com/adminportal/home#/subscriptions/vlnew/downloadsandkeys
    https://catalog.update.microsoft.com
#>

[CmdletBinding()]
param(
    [switch]$Help,
    [string]$WimEsdPath = "",
    [string]$LanguagesAndOptionalFeaturesPath = "",
    [string]$UpdatePath,
    [string]$OutputPath,
    [int]   $WimIndex = 0,
    [string]$Languages = "",
    [switch]$SkipUpdates,
    [switch]$SkipLanguagePacks,
    [string]$AppxListPath = "",
    [switch]$SkipAppxRemoval,
    [switch]$SkipDefenderUpdate,
    [string]$FoDList = "",
    [string]$DriverPath = "",
    [string]$DriverListPath = "",
    [switch]$Unattended,
    [switch]$DebugBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptVersion = "7.0.0"
$MinFreeSpaceGB = 30

if ($WimEsdPath -eq '/?') { $Help = $true; $WimEsdPath = "" }

if ($Help) {
    Write-Host ""
    Write-Host "  WIM Wizard v$ScriptVersion" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  USAGE" -ForegroundColor White
    Write-Host "  -----"
    Write-Host "  Interactive full build:"
    Write-Host "    .\WimWizard.ps1"
    Write-Host ""
    Write-Host "  Unattended full build (Russian):"
    Write-Host "    .\WimWizard.ps1 -Languages `"ru`" -Unattended"
    Write-Host ""
    Write-Host "  Unattended full build (Russian + FoDs):"
    Write-Host "    .\WimWizard.ps1 -Languages `"ru`" -FoDList `"PowerShell-ISE,Wifi`" -Unattended"
    Write-Host ""
    Write-Host "  Full build with explicit paths:"
    Write-Host "    .\WimWizard.ps1 -Languages `"ru`" ``"
    Write-Host "      -WimEsdPath `"D:\WimEsd`" ``"
    Write-Host "      -LanguagesAndOptionalFeaturesPath `"D:\LanguagesAndOptionalFeatures`" ``"
    Write-Host "      -Unattended"
    Write-Host ""
    Write-Host "  Full build with driver injection:"
    Write-Host "    .\WimWizard.ps1 -Languages `"ru`" -DriverPath `"D:\Drivers\Laptop`" -Unattended"
    Write-Host ""
    Write-Host "  Offline build with pre-downloaded updates:"
    Write-Host "    .\WimWizard.ps1 -Languages `"ru`" -UpdatePath `"C:\Updates`" -Unattended"
    Write-Host ""
    Write-Host "  Update-only build (place existing WIM as install.wim in WimEsdPath):"
    Write-Host "    .\WimWizard.ps1 -SkipLanguagePacks -SkipAppxRemoval -SkipDefenderUpdate -Unattended"
    Write-Host ""
    Write-Host "  PARAMETERS" -ForegroundColor White
    Write-Host "  ----------"
    Write-Host "  -WimEsdPath       <path>   Folder containing install.wim or install.esd"
    Write-Host "                             (default: <ScriptRoot>\WimEsd\)"
    Write-Host "  -LanguagesAndOptionalFeaturesPath <path>"
    Write-Host "                             Folder with LP and FoD cab files"
    Write-Host "                             (default: <ScriptRoot>\LanguagesAndOptionalFeatures\)"
    Write-Host "  -Languages        <codes>  Comma-separated 2-letter codes (e.g. ru, de, fr)"
    Write-Host "  -OutputPath       <path>   Output WIM path (folder or folder\file.wim)"
    Write-Host "  -UpdatePath       <path>   Folder with pre-downloaded .msu/.cab files"
    Write-Host "  -AppxListPath     <path>   XML with custom Appx removal list"
    Write-Host "  -WimIndex         <int>    WIM index (0 = auto-detect Enterprise)"
    Write-Host "  -FoDList          <keys>   PowerShell-ISE,SnippingTool,VBSCRIPT,WinOcr,"
    Write-Host "                             DeveloperMode,Ethernet,Wifi,Notepad"
    Write-Host "                             (any other value = DISM capability name)"
    Write-Host "  -DriverPath       <path>   Root folder to recurse for driver .inf packages"
    Write-Host "  -DriverListPath   <path>   XML with pre-selected driver INF paths"
    Write-Host "  -SkipUpdates               Skip LCU / checkpoint / .NET CU"
    Write-Host "  -SkipLanguagePacks         Skip language pack and Language.* FoD injection"
    Write-Host "  -SkipAppxRemoval           Skip removal of provisioned Appx packages"
    Write-Host "  -SkipDefenderUpdate        Skip the offline Defender update"
    Write-Host "  -DebugBuild                Extra diagnostics"
    Write-Host "  -Unattended                No interactive prompts"
    Write-Host "  -Help                      Show this help (also: /?)"
    Write-Host ""
    exit 0
}

$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

if (-not $WimEsdPath) { $WimEsdPath = "$ScriptRoot\WimEsd" }
if (-not $LanguagesAndOptionalFeaturesPath) { $LanguagesAndOptionalFeaturesPath = "$ScriptRoot\LanguagesAndOptionalFeatures" }
if (-not $OutputPath) { $OutputPath = "$ScriptRoot\Output\install.wim" }

# ── Locale map (2-letter code → locale tags) ─────────────────────────────────
$LocaleMap = @{
    'ar' = @('ar-SA'); 'bg' = @('bg-BG'); 'cs' = @('cs-CZ'); 'da' = @('da-DK'); 'de' = @('de-DE');
    'dk' = @('da-DK'); 'el' = @('el-GR'); 'en' = @('en-GB', 'en-US'); 'es' = @('es-ES', 'es-MX');
    'et' = @('et-EE'); 'fi' = @('fi-FI'); 'fr' = @('fr-CA', 'fr-FR'); 'gb' = @('en-GB'); 'gr' = @('el-GR');
    'he' = @('he-IL'); 'hr' = @('hr-HR'); 'hu' = @('hu-HU'); 'il' = @('he-IL'); 'it' = @('it-IT');
    'ja' = @('ja-JP'); 'jp' = @('ja-JP'); 'ko' = @('ko-KR'); 'kr' = @('ko-KR'); 'lt' = @('lt-LT');
    'lv' = @('lv-LV'); 'mx' = @('es-MX'); 'nl' = @('nl-NL'); 'no' = @('nb-NO'); 'pl' = @('pl-PL');
    'pt' = @('pt-BR', 'pt-PT'); 'ro' = @('ro-RO'); 'ru' = @('ru-RU'); 'se' = @('sv-SE'); 'sk' = @('sk-SK');
    'sl' = @('sl-SI'); 'sr' = @('sr-Latn-RS'); 'sv' = @('sv-SE'); 'th' = @('th-TH'); 'tr' = @('tr-TR');
    'tw' = @('zh-TW'); 'hk' = @('zh-TW'); 'ua' = @('uk-UA'); 'uk' = @('uk-UA'); 'us' = @('en-US');
    'vn' = @('vi-VN'); 'zh' = @('zh-CN', 'zh-TW'); 'cn' = @('zh-CN');
    'ca' = @('ca-ES'); 'eu' = @('eu-ES'); 'gl' = @('gl-ES'); 'id' = @('id-ID'); 'vi' = @('vi-VN')
}
$SupportedCodesLine = ($LocaleMap.Keys | Sort-Object) -join ", "

# ── Output helpers ───────────────────────────────────────────────────────────
function Write-OK { param([string]$msg) Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "  [!]   $msg" -ForegroundColor Yellow }
function Write-Info { param([string]$msg) Write-Host "  [i]   $msg" -ForegroundColor Cyan }
function Write-Fail { param([string]$msg) Write-Host "  [ERR] $msg" -ForegroundColor Red }
function Write-DiskWarn { param([string]$msg) Write-Host "  [!]   $msg" -ForegroundColor DarkYellow }

# ── Disk space helpers ───────────────────────────────────────────────────────
function Get-FreeSpaceGB {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $dir = $Path
        if ([System.IO.Path]::GetExtension($dir)) {
            $parent = Split-Path $dir -Parent
            if ($parent) { $dir = $parent }
        }
        if ([string]::IsNullOrWhiteSpace($dir)) { return $null }
        if ($dir -match '^[A-Za-z]:\\?$|^[A-Za-z]:\\') {
            $psDrive = Get-PSDrive -Name $dir.Substring(0, 1) -ErrorAction SilentlyContinue
            if ($psDrive) { return [math]::Round($psDrive.Free / 1GB, 1) }
            return $null
        }
        $probe = $dir
        while ($probe -and -not (Test-Path -LiteralPath $probe)) {
            $parentProbe = Split-Path $probe -Parent
            if (-not $parentProbe -or $parentProbe -eq $probe) { break }
            $probe = $parentProbe
        }
        if (-not $probe -or -not (Test-Path -LiteralPath $probe)) { return $null }
        $drive = New-Object System.IO.DriveInfo($probe)
        return [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    }
    catch { return $null }
}

function Test-OutputDiskSpace {
    param([string]$Path, [string]$Label = "output location")
    $freeGB = Get-FreeSpaceGB -Path $Path
    if ($null -eq $freeGB -or $freeGB -ge $MinFreeSpaceGB) { return }
    Write-Host ""
    Write-DiskWarn "Low disk space: only $freeGB GB free at the $Label (>= $MinFreeSpaceGB GB recommended)."
    Write-DiskWarn "The build will continue, but may fail partway through if space runs out."
    if (-not $Unattended) {
        Write-Host ""
        Write-Host "  Press any key to continue anyway..." -ForegroundColor DarkYellow
        try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
        catch { Read-Host "  (Press Enter to continue)" | Out-Null }
    }
    Write-Host ""
}

# ── Driver INF helpers ───────────────────────────────────────────────────────
function Get-InfStringsTable {
    param([Parameter(Mandatory)][string]$Content)
    $strings = @{}
    if ($Content -match '(?ms)^\[Strings\](.*?)(?:^\[|\z)') {
        foreach ($line in ($Matches[1] -split "`r?`n")) {
            if ($line -match '^\s*([A-Za-z0-9_.]+)\s*=\s*"?([^"\r\n]*)"?\s*$') {
                $strings[$Matches[1]] = Remove-InfComment $Matches[2].Trim()
            }
        }
    }
    return $strings
}
function Remove-InfComment {
    param([string]$Value)
    if (-not $Value) { return $Value }
    $idx = $Value.IndexOf(';')
    if ($idx -ge 0) { return $Value.Substring(0, $idx).Trim() }
    return $Value.Trim()
}
function Resolve-InfToken {
    param([string]$Value, [hashtable]$Strings)
    if (-not $Value) { return $Value }
    if ($Value -match '^%(.+)%$') {
        $token = $Matches[1]
        foreach ($key in $Strings.Keys) { if ($key -ieq $token) { return $Strings[$key] } }
        return $token
    }
    return $Value
}
function Get-InfDriverInfo {
    param([Parameter(Mandatory)][string]$InfPath)
    $content = Get-Content -LiteralPath $InfPath -Raw -ErrorAction Stop
    $stringsTable = Get-InfStringsTable -Content $content
    $versionBlock = if ($content -match '(?ms)^\[Version\](.*?)(?:^\[|\z)') { $Matches[1] } else { $content }
    $provider = if ($versionBlock -match '(?im)^\s*Provider\s*=\s*(.+?)\s*$') { Remove-InfComment ($Matches[1].Trim('"', ' ')) } else { "" }
    $class = if ($versionBlock -match '(?im)^\s*Class\s*=\s*(.+?)\s*$') { Remove-InfComment ($Matches[1].Trim('"', ' ')) } else { "" }
    $driverVer = if ($versionBlock -match '(?im)^\s*DriverVer\s*=\s*(.+?)\s*$') { Remove-InfComment ($Matches[1].Trim()) } else { "" }
    $provider = Resolve-InfToken -Value $provider -Strings $stringsTable
    $class = Resolve-InfToken -Value $class    -Strings $stringsTable
    $date = ""; $version = ""
    if ($driverVer -match '^([\d/]+)\s*,\s*(.+)$') { $date = $Matches[1]; $version = $Matches[2] }
    elseif ($driverVer) { $version = $driverVer }
    $classLabels = @{
        'Net' = 'Network'; 'HDC' = 'Storage controller'; 'System' = 'System device';
        'Display' = 'Display / GPU'; 'Media' = 'Audio / media'; 'Monitor' = 'Monitor';
        'Battery' = 'Battery / ACPI'; 'USB' = 'USB controller'; 'Bluetooth' = 'Bluetooth';
        'SmartCardReader' = 'Smart card reader'
    }
    $classLabel = if ($class -and $classLabels.ContainsKey($class)) { $classLabels[$class] } else { $class }
    [PSCustomObject]@{
        InfPath = $InfPath; FileName = Split-Path $InfPath -Leaf;
        Manufacturer = $provider; Class = $classLabel; ClassRaw = $class;
        Version = $version; Date = $date
    }
}
function Get-DriverInfoFromFolder {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { throw "Driver path not found: $Root" }
    Get-ChildItem -LiteralPath $Root -Recurse -Filter *.inf -ErrorAction Stop | ForEach-Object {
        try { Get-InfDriverInfo -InfPath $_.FullName }
        catch {
            [PSCustomObject]@{ InfPath = $_.FullName; FileName = $_.Name; Manufacturer = "?";
                Class = "(parse error)"; ClassRaw = ""; Version = ""; Date = ""
            }
        }
    }
}
function Install-WimWizardDrivers {
    param([Parameter(Mandatory)][string]$MountDir, [Parameter(Mandatory)][string]$ScratchDir,
        [string]$DriverPath, [string]$DriverListPath)
    $driverInfPaths = @()
    $driverListLoaded = $false
    if (($DriverListPath -is [string]) -and $DriverListPath.Length -gt 0 -and (Test-Path -LiteralPath $DriverListPath)) {
        try {
            [xml]$driverXml = Get-Content $DriverListPath -ErrorAction Stop
            [array]$driverNodes = $driverXml.DriverList.Driver
            if ($null -eq $driverNodes -or $driverNodes.Count -eq 0 -or $null -eq $driverNodes[0]) { $driverInfPaths = @() }
            else { $driverInfPaths = @($driverNodes | ForEach-Object { $_.InfPath } | Where-Object { $_ }) }
            $driverListLoaded = $true
            Write-Info "Loaded driver selection from: $DriverListPath ($($driverInfPaths.Count) drivers)"
            Write-Log "Loaded driver list: $DriverListPath ($($driverInfPaths.Count) drivers)"
        }
        catch {
            Write-Warn "Could not load DriverListPath: $($_.Exception.Message) - falling back to DriverPath"
            Write-Log "WARN: Could not load DriverListPath: $($_.Exception.Message)" "WARN"
        }
    }
    if (-not $driverListLoaded -and $driverInfPaths.Count -eq 0 -and $DriverPath -ne "") {
        try {
            $driverInfPaths = @(Get-DriverInfoFromFolder -Root $DriverPath | ForEach-Object { $_.InfPath })
            Write-Info "Scanned $DriverPath - $($driverInfPaths.Count) driver INFs found"
            Write-Log "Scanned DriverPath: $DriverPath ($($driverInfPaths.Count) INFs found)"
        }
        catch {
            Write-Warn "Could not scan DriverPath: $($_.Exception.Message)"
            Write-Log "WARN: Could not scan DriverPath: $($_.Exception.Message)" "WARN"
            return
        }
    }
    if ($driverInfPaths.Count -eq 0) { Write-Info "No drivers to inject - skipping"; return }
    Write-Section "install.wim - Driver injection"
    $driverOK = 0; $driverFailed = 0
    foreach ($inf in $driverInfPaths) {
        $label = Split-Path $inf -Leaf
        try {
            Add-WindowsDriver -Path $MountDir -Driver $inf -ScratchDirectory $ScratchDir -ErrorAction Stop | Out-Null
            Write-OK "Driver: $label"; Write-Log "Driver OK: $inf"; $driverOK++
        }
        catch {
            Write-Warn "Driver failed: $label - $($_.Exception.Message)"
            Write-Log "WARN Driver failed $inf`: $($_.Exception.Message)" "WARN"; $driverFailed++
        }
    }
    Write-Info "Drivers: $driverOK injected, $driverFailed failed (non-fatal)"
    Write-Log "Driver injection summary: $driverOK OK, $driverFailed failed"
}

# ── Language code resolution ─────────────────────────────────────────────────
function Resolve-LanguageCodes {
    param([string]$CodeString)
    $codes = $CodeString.ToLower().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $result = [System.Collections.Generic.List[string]]::new()
    $errors = @()
    foreach ($code in $codes) {
        if ($LocaleMap.ContainsKey($code)) {
            foreach ($tag in $LocaleMap[$code]) { if (-not $result.Contains($tag)) { $result.Add($tag) } }
        }
        else { $errors += $code }
    }
    if ($errors.Count -gt 0) {
        Write-Fail "Unknown language code(s): $($errors -join ', ')"
        Write-Host ""
        Write-Host "  Supported codes: $SupportedCodesLine" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    return @($result)
}

$ResolvedLocales = @()

trap {
    Write-Host ""; Write-Fail "Unhandled error: $($_.Exception.Message)"
    break
}

$CatalogSearchTerms = $null

# ── Windows version detection (for Catalog search terms) ─────────────────────
function Get-CatalogSearchTerms {
    param([string]$WimVersion)
    $build = 0
    if ($WimVersion -match '^\d+\.\d+\.(\d+)\.') { $build = [int]$Matches[1] }
    $versionString = switch ($true) {
        ($build -ge 26300) { "26H2" }
        ($build -ge 26200 -and $build -lt 26300) { "25H2" }
        ($build -ge 26100 -and $build -lt 26200) { "24H2" }
        ($build -ge 22631 -and $build -lt 26100) { "23H2" }
        default {
            Write-Warn "Unknown build number $build - defaulting to 25H2 search terms"
            "25H2"
        }
    }
    Write-Info "Detected Windows 11 version: $versionString (build $build)"
    $buildFilter = $build.ToString()
    return @{
        LCU           = "Cumulative Update for Windows 11 Version $versionString for x64"
        DotNet        = "Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version $versionString for x64"
        BuildFilter   = $buildFilter
        VersionString = $versionString
    }
}

# ── UI helpers ───────────────────────────────────────────────────────────────
function Write-Banner {
    Clear-Host
    $w = "=" * 66
    Write-Host "+$w+" -ForegroundColor Cyan
    Write-Host ("|  WIM WIZARD  v{0,-55}|" -f $ScriptVersion) -ForegroundColor Cyan
    Write-Host "+$w+" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Section {
    param([string]$Title)
    Write-Host ""; Write-Host ("-" * 66) -ForegroundColor DarkCyan
    Write-Host "  >> $Title" -ForegroundColor White
    Write-Host ("-" * 66) -ForegroundColor DarkCyan
}
function Confirm-Continue {
    param([string]$Message = "Continue?")
    if ($Unattended) { return $true }
    Write-Host ""; $answer = Read-Host "  $Message [Y/n]"
    return ($answer -eq "" -or $answer -match "^[yY]")
}
function Read-PathWithDefault {
    param([string]$Prompt, [string]$Default, [switch]$MustExist)
    if ($Unattended) {
        Write-Info "$Prompt"
        Write-Info "  [Unattended] Using default: $Default"
        $path = $Default
    }
    else {
        Write-Host ""
        Write-Host "  $Prompt" -ForegroundColor White
        Write-Host "  [Default: $Default]" -ForegroundColor DarkGray
        $inp = Read-Host "  Path (press Enter for default)"
        $path = if ($inp.Trim() -eq "") { $Default } else { $inp.Trim() }
    }
    if ($MustExist -and -not (Test-Path $path)) {
        Write-Fail "Path not found: $path"
        return $null
    }
    return $path
}

# ── Default Appx removal list ────────────────────────────────────────────────
$AppxToRemoveDefault = @(
    "Microsoft.BingSearch"
    "Clipchamp.Clipchamp"
    "Microsoft.Copilot"
    "Microsoft.Windows.DevHome"
    "MicrosoftCorporationII.MicrosoftFamily"
    "Microsoft.WindowsFeedbackHub"
    "Microsoft.GamingApp"
    "Microsoft.GetHelp"
    "Microsoft.MicrosoftJournal"
    "Microsoft.Messaging"
    "Microsoft.BingWeather"
    "Microsoft.BingNews"
    "Microsoft.MicrosoftOfficeHub"
    "Microsoft.MicrosoftPCManager"
    "Microsoft.MicrosoftSolitaireCollection"
    "Microsoft.ZuneMusic"
    "Microsoft.ZuneVideo"
    "Microsoft.OutlookForWindows"
    "MicrosoftCorporationII.QuickAssist"
    "Microsoft.Whiteboard"
    "Microsoft.XboxGamingOverlay"
    "Microsoft.XboxIdentityProvider"
    "Microsoft.XboxSpeechToTextOverlay"
    "Microsoft.Xbox.TCUI"
    "Microsoft.YourPhone"
    "Microsoft.QuickAssist"
)
$AppxToRemove = $AppxToRemoveDefault

# ── WIM/ESD folder discovery ─────────────────────────────────────────────────
function Resolve-WimEsdFolder {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [string]$LanguagesAndOptionalFeaturesPath = ""
    )

    if (-not (Test-Path -LiteralPath $Folder)) {
        Write-Warn "WIM/ESD folder not found: $Folder"
        return $null
    }

    Write-Info "Scanning $Folder for install.wim or install.esd..."

    $wimFile = Get-ChildItem -LiteralPath $Folder -Filter "install.wim" -ErrorAction SilentlyContinue |
    Select-Object -First 1
    if (-not $wimFile) {
        $wimFile = Get-ChildItem -LiteralPath $Folder -Filter "install.esd" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    }
    if (-not $wimFile) {
        Write-Info "Searching recursively..."
        $wimFile = Get-ChildItem -LiteralPath $Folder -Filter "install.wim" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if (-not $wimFile) {
            $wimFile = Get-ChildItem -LiteralPath $Folder -Filter "install.esd" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        }
    }
    if (-not $wimFile) {
        Write-Warn "No install.wim or install.esd found in: $Folder"
        return $null
    }
    Write-OK "Found WIM/ESD: $($wimFile.FullName)"

    $lpRoot = $null
    if ($LanguagesAndOptionalFeaturesPath -and (Test-Path -LiteralPath $LanguagesAndOptionalFeaturesPath)) {
        $lpRoot = $LanguagesAndOptionalFeaturesPath
        Write-OK "LP/FoD source (explicit): $lpRoot"
    }
    else {
        if ($LanguagesAndOptionalFeaturesPath) {
            Write-Warn "LanguagesAndOptionalFeaturesPath not found: $LanguagesAndOptionalFeaturesPath"
        }
        $autoSub = Join-Path $Folder "LanguagesAndOptionalFeatures"
        if (Test-Path -LiteralPath $autoSub) {
            $lpRoot = $autoSub
            Write-OK "LP/FoD source (auto-detected): $lpRoot"
        }
        else {
            Write-Warn "No LanguagesAndOptionalFeatures folder found."
            Write-Warn "LP/FoD injection may fail. Set -LanguagesAndOptionalFeaturesPath explicitly."
            $lpRoot = $Folder
        }
    }

    return @{
        WimFile       = $wimFile.FullName
        LPSearchRoot  = $lpRoot
        FODSearchRoot = $lpRoot
    }
}
function Test-LPSourceComplete {
    # Validates that LPSearchRoot is a usable FOD/LP repository:
    #   1. required metadata files in root + metadata\ (FATAL if missing)
    #   2. per-required-locale: LP cab + LanguageFeatures-Basic + per-locale
    #      CompDB + MINIMUM cab count (WARNING if under threshold)
    # The minimum-count check catches the common "deleted one or two cabs"
    # case that produces 0x80070002 at install time. A complete locale has
    # ~43 cabs (LP + 4× LanguageFeatures + ~38 FoD satellites covering
    # amd64/wow64, incl. HyperV VM platform and two WMIC packages).
    # Locales already in the image (en-US) need nothing — DISM resolves
    # them against installed components, not against the source repo.
    param(
        [Parameter(Mandatory)][string]$LPSourceRoot,
        [string[]]$RequiredLocales,
        [int]$MinCabsPerLocale = 43
    )

    $missing = @()
    $fatal   = $false
    $localeCounts = @{}

    if (-not (Test-Path -LiteralPath $LPSourceRoot)) {
        return @{ Missing = @("LPSourceRoot does not exist: $LPSourceRoot"); Fatal = $true; LocaleCounts = @{} }
    }

    # ── Root-level metadata (fatal) ─────────────────────────────────────────
    foreach ($f in @(
        'FoDMetadata_Client.cab',
        'Microsoft-Windows-FodMetadataServicing-Desktop-Metadata-Package.cab',
        'Microsoft-Windows-FodMetadataServicing-Desktop-CompDB-Package.cab'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $LPSourceRoot $f))) {
            $missing += "root: $f (required)"
            $fatal = $true
        }
    }

    # ── metadata\ subfolder (fatal) ─────────────────────────────────────────
    $metaDir = Join-Path $LPSourceRoot 'metadata'
    if (-not (Test-Path -LiteralPath $metaDir)) {
        $missing += "metadata\ subfolder (required)"
        $fatal = $true
    } else {
        foreach ($f in @(
            'DesktopTargetCompDB_Neutral.xml.cab',
            'DesktopTargetCompDB_FOD_Neutral.xml.cab',
            'DesktopTargetCompDB_FOD_Metadata_Neutral.xml.cab',
            'DesktopTargetCompDB_Conditions.xml.cab'
        )) {
            if (-not (Test-Path -LiteralPath (Join-Path $metaDir $f))) {
                $missing += "metadata\$f (required)"
                $fatal = $true
            }
        }
    }

    # ── Per-required-locale (warning) ───────────────────────────────────────
    if (-not $fatal) {
        $allCabs = @(Get-ChildItem -LiteralPath $LPSourceRoot -Filter "*.cab" -ErrorAction SilentlyContinue)

        foreach ($locale in @($RequiredLocales | Where-Object { $_ } | Select-Object -Unique)) {
            $lcLow = $locale.ToLower()
            $lcRef = $locale   # metadata and FoD names use original case (ru-RU)

            # Locale-specific cabs: "~<locale>~" satellites, LanguageFeatures-<type>-<lc>,
            # and the main Client-Language-Pack. Uses -match, so a stray leftover
            # from another locale does NOT count toward this locale.
            $localeCabs = @($allCabs | Where-Object {
                $_.Name -match "~$([regex]::Escape($lcRef))~" -or
                $_.Name -match "LanguageFeatures-[^-]+-$([regex]::Escape($lcLow))-Package" -or
                $_.Name -match "Client-Language-Pack_x64_$([regex]::Escape($lcLow))\.cab"
            })
            $localeCounts[$locale] = $localeCabs.Count

            if ($localeCabs.Count -lt $MinCabsPerLocale) {
                $missing += "$locale`: only $($localeCabs.Count) locale-specific cabs found, $MinCabsPerLocale+ expected"
                $missing += "   likely missing: HyperV-OptionalFeature-VirtualMachinePlatform-Client-Disabled-FOD-Package~...~amd64~$lcRef~.cab"
                $missing += "   likely missing: Microsoft-Windows-WMIC-FoD-Package~...~{amd64,wow64}~$lcRef~.cab"
            }

            # Individually required files (better messages than count alone)
            if (-not ($localeCabs | Where-Object { $_.Name -match "Client-Language-Pack_x64_$([regex]::Escape($lcLow))\.cab" })) {
                $missing += "Microsoft-Windows-Client-Language-Pack_x64_$lcLow.cab (for $locale)"
            }
            if (-not ($localeCabs | Where-Object { $_.Name -match "LanguageFeatures-Basic-$([regex]::Escape($lcLow))-Package" })) {
                $missing += "Microsoft-Windows-LanguageFeatures-Basic-$lcLow-Package~*.cab (for $locale)"
            }
            if (Test-Path -LiteralPath $metaDir) {
                if (-not (Get-ChildItem -LiteralPath $metaDir -Filter "DesktopTargetCompDBForISO_$lcRef.xml.cab" -ErrorAction SilentlyContinue)) {
                    $missing += "metadata\DesktopTargetCompDBForISO_$lcRef.xml.cab (for $locale)"
                }
                if (-not (Get-ChildItem -LiteralPath $metaDir -Filter "DesktopTargetCompDBForISO_FOD_$lcRef.xml.cab" -ErrorAction SilentlyContinue)) {
                    $missing += "metadata\DesktopTargetCompDBForISO_FOD_$lcRef.xml.cab (for $locale)"
                }
            }
        }
    }

    return @{ Missing = $missing; Fatal = $fatal; LocaleCounts = $localeCounts }
}
# ── MSCatalogLTS / update download ───────────────────────────────────────────
function Install-MSCatalogLTS {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (Get-Module -Name MSCatalogLTS -ListAvailable) {
        Import-Module MSCatalogLTS -Force; Write-OK "MSCatalogLTS module loaded"; return $true
    }
    Write-Info "MSCatalogLTS module not found - installing from PSGallery..."
    $nugetDir = "$env:ProgramFiles\PackageManagement\ProviderAssemblies\nuget\2.8.5.208"
    $nugetDest = "$nugetDir\Microsoft.PackageManagement.NuGetProvider.dll"
    if (-not (Test-Path $nugetDest)) {
        Write-Info "Installing NuGet provider..."
        New-Item $nugetDir -ItemType Directory -Force | Out-Null
        Invoke-WebRequest -Uri 'https://cdn.oneget.org/providers/Microsoft.PackageManagement.NuGetProvider-2.8.5.208.dll' `
            -OutFile $nugetDest -UseBasicParsing
    }
    Import-PackageProvider -Name NuGet -RequiredVersion 2.8.5.208 -Force | Out-Null
    try {
        Install-Module -Name MSCatalogLTS -Force -Scope AllUsers -AllowClobber
        Import-Module MSCatalogLTS -Force
        Write-OK "MSCatalogLTS installed and loaded"; return $true
    }
    catch {
        Write-Warn "Could not install MSCatalogLTS: $($_.Exception.Message)"; return $false
    }
}

function Invoke-UpdateFolderCleanup {
    param([string]$DownloadDir)
    if (-not (Test-Path $DownloadDir)) { return }
    $cleaned = 0
    Get-ChildItem $DownloadDir -Filter "*.msu" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^windows11\.0-kb\d+-" -and $_.Name -notmatch '_[0-9a-f]{8,}' } |
    ForEach-Object {
        $kb = ([regex]::Match($_.Name, 'kb(\d+)', 'IgnoreCase')).Groups[1].Value
        $hasCanonical = [bool](Get-ChildItem $DownloadDir -Filter "*_KB${kb}*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^[0-9]_' })
        if ($hasCanonical) {
            Write-Info "Cleanup: removing old-named MSU (canonical exists): $($_.Name)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; $cleaned++
        }
    }
    $canonicalPattern = '^(\d+_[^_]+)_KB(\d+)_(\w+)\.(msu|cab)$'
    $allCanonical = Get-ChildItem $DownloadDir -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match $canonicalPattern }
    $groups = $allCanonical | Group-Object {
        $m = [regex]::Match($_.Name, $canonicalPattern)
        "$($m.Groups[1].Value)_$($m.Groups[3].Value)_$($m.Groups[4].Value)"
    }
    foreach ($group in $groups) {
        if ($group.Count -le 1) { continue }
        $sorted = $group.Group | Sort-Object {
            $m = [regex]::Match($_.Name, $canonicalPattern); [int]$m.Groups[2].Value
        } -Descending
        $sorted | Select-Object -Skip 1 | ForEach-Object {
            Write-Info "Cleanup: removing superseded file: $($_.Name)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; $cleaned++
        }
    }
    if ($cleaned -gt 0) {
        Write-OK "Update folder cleanup: removed $cleaned stale/superseded file(s)"
        Write-Log "Update folder cleanup removed $cleaned file(s)"
    }
}

function Invoke-AutoUpdateDownload {
    param([string]$DownloadDir)
    if (-not (Test-Path $DownloadDir)) { New-Item $DownloadDir -ItemType Directory -Force | Out-Null }
    if (-not (Install-MSCatalogLTS)) {
        Write-Warn "Cannot download updates automatically without MSCatalogLTS."; return $null
    }
    Write-Info "Searching Microsoft Update Catalog via MSCatalogLTS..."
    $downloaded = 0

    foreach ($type in @("LCU", "DotNet")) {
        $label = switch ($type) { "LCU" { "Cumulative Update (LCU + SSU)" } "DotNet" { ".NET Framework CU" } }
        $prefix = switch ($type) { "LCU" { "1" } "DotNet" { "2" } }

        Write-Host ""
        Write-Host "  >> $label" -ForegroundColor White
        Write-Info "     Query: $($CatalogSearchTerms[$type])"

        try {
            $results = Get-MSCatalogUpdate -Search $CatalogSearchTerms[$type] -ErrorAction Stop
        }
        catch {
            Write-Warn "Search failed for $label`: $($_.Exception.Message)"; continue
        }
        if (-not $results -or $results.Count -eq 0) { Write-Warn "No results found for $label."; continue }

        $buildFilter = $CatalogSearchTerms.BuildFilter
        $filtered = $results | Where-Object {
            $_.Title -notmatch "\bPreview\b" -and
            $_.Title -notmatch "\bx86\b" -and
            $_.Title -notmatch "\barm64\b" -and
            ($buildFilter -eq "" -or $_.Title -match [regex]::Escape("($buildFilter") -or $_.Title -match [regex]::Escape("($buildFilter."))
        }
        if (-not $filtered) {
            Write-Warn "Build filter ($buildFilter) matched nothing - falling back to unfiltered results"
            $filtered = $results | Where-Object {
                $_.Title -notmatch "\bPreview\b" -and $_.Title -notmatch "\bx86\b" -and $_.Title -notmatch "\barm64\b"
            }
        }
        if (-not $filtered) { $filtered = $results }

        $best = $filtered | Select-Object -First 1
        Write-Host "  Found   : $($best.Title)" -ForegroundColor Green
        Write-Host "  Date    : $($best.LastUpdated)" -ForegroundColor DarkGray

        $kbMatch = [regex]::Match($best.Title, "KB\d+")
        $kbNum = if ($kbMatch.Success) { $kbMatch.Value } else { "KB_unknown" }
        $kbLower = $kbNum.ToLower()
        $archMsu = "x64"
        $fileName = if ($type -eq "LCU") {
            "windows11.0-$kbLower-$archMsu.msu"
        }
        else {
            "${prefix}_${type}_${kbNum}_x64.msu"
        }
        $destPath = Join-Path $DownloadDir $fileName

        if ($type -eq "LCU") {
            $alreadyHave = Get-ChildItem $DownloadDir -Filter "*.msu" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $kbNum -and $_.Name -match $archMsu -and
                $_.Name -notmatch "kb5043080" -and $_.Length -gt 1MB } |
            Select-Object -First 1

            $lcuCached = $false
            if ($alreadyHave -and $alreadyHave.Name -match '_[0-9a-f]{8,}') {
                Write-OK "LCU already cached: $($alreadyHave.Name) ($([math]::Round($alreadyHave.Length/1MB,0)) MB)"
                $destPath = $alreadyHave.FullName
                $lcuCached = $true
            }
            elseif ($alreadyHave) {
                Write-Info "Cached LCU has no hash in filename - re-downloading with correct name..."
                Remove-Item $alreadyHave.FullName -Force -ErrorAction SilentlyContinue
            }

            $checkpointCached = [bool](Get-ChildItem $DownloadDir -Filter "*.msu" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "kb5043080" -and $_.Name -match $archMsu -and
                    $_.Name -match '_[0-9a-f]{8,}' -and $_.Length -gt 1MB })

            if ($lcuCached -and $checkpointCached) {
                Write-OK "Checkpoint KB5043080 also cached - done with LCU"
                $downloaded++
                continue
            }

            Write-Info "     Fetching download URLs via Update Catalog API..."
            try {
                $guid = $best.Guid
                $post = @{size = 0; UpdateID = $guid; UpdateIDInfo = $guid } | ConvertTo-Json -Compress
                $body = @{UpdateIDs = "[$post]" }
                $response = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" `
                    -Body $body -ContentType "application/x-www-form-urlencoded" `
                    -UseBasicParsing -ErrorAction Stop
                $content = $response.Content -replace "www.download.windowsupdate", "download.windowsupdate"
                $regex = "downloadInformation\[(\d+)\]\.files\[(\d+)\]\.url\s*=\s*'([^']*)'"
                $matches2 = [regex]::Matches($content, $regex)

                if (-not $lcuCached) {
                    $lcuUrl = $null
                    foreach ($m in $matches2) {
                        $url = $m.Groups[3].Value
                        if ($url -match $archMsu -and $url -match $kbLower -and $url -match "\.msu" -and
                            $url -notmatch "kb5043080") {
                            $lcuUrl = $url; break
                        }
                    }
                    if (-not $lcuUrl) { throw "No LCU URL found in API response" }
                    $originalName = $lcuUrl.Split('/')[-1]
                    $destPath = Join-Path $DownloadDir $originalName
                    Write-Info "     Downloading LCU: $originalName..."
                    Start-BitsTransfer -Source $lcuUrl -Destination $destPath -ErrorAction Stop
                    Unblock-File -Path $destPath -ErrorAction SilentlyContinue
                    Write-OK "LCU downloaded: $originalName ($([math]::Round((Get-Item $destPath).Length/1MB,0)) MB)"
                }

                if (-not $checkpointCached) {
                    $checkpointUrl = $null
                    foreach ($m in $matches2) {
                        $url = $m.Groups[3].Value
                        if ($url -match "kb5043080" -and $url -match $archMsu -and $url -match "\.msu") {
                            $checkpointUrl = $url; break
                        }
                    }
                    if ($checkpointUrl) {
                        $cpName = $checkpointUrl.Split('/')[-1]
                        $cpPath = Join-Path $DownloadDir $cpName
                        Write-Info "     Downloading checkpoint (KB5043080): $cpName..."
                        Start-BitsTransfer -Source $checkpointUrl -Destination $cpPath -ErrorAction Stop
                        Unblock-File -Path $cpPath -ErrorAction SilentlyContinue
                        Write-OK "Checkpoint downloaded: $cpName"
                    }
                    else {
                        Write-Warn "Checkpoint KB5043080 not present in API response for this KB."
                        Write-Warn "Manual download may be required: https://www.catalog.update.microsoft.com (search KB5043080)"
                    }
                }

                $keepName = if ($lcuCached) { $alreadyHave.Name } else { Split-Path $destPath -Leaf }
                Get-ChildItem $DownloadDir -Filter "windows11.0-kb*-$archMsu*.msu" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $keepName -and $_.Name -notmatch "kb5043080" } |
                ForEach-Object {
                    Write-Info "Removing superseded LCU: $($_.Name)"
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }

                $downloaded++
                continue
            }
            catch {
                Write-Fail "LCU/checkpoint download via DownloadDialog API failed: $($_.Exception.Message)"
                Write-Host ""
                Write-Host "  Manual download required. Both files must be in: $DownloadDir" -ForegroundColor Yellow
                Write-Host "    1. Go to https://www.catalog.update.microsoft.com" -ForegroundColor Cyan
                Write-Host "    2. Search for: $kbNum  and  KB5043080" -ForegroundColor Cyan
                Write-Host "    3. Click Download -> right-click link -> Save link as" -ForegroundColor Cyan
                Write-Host "       (do NOT use Download button - it strips the SHA1 hash)" -ForegroundColor Yellow
                Write-Host "    4. Save both files with original filenames (with hash)" -ForegroundColor Cyan
                Write-Host "    5. Re-run the script" -ForegroundColor Cyan
                Write-Host ""
                return $null
            }
        }

        $alreadyHave = Get-ChildItem $DownloadDir -Filter "*.msu" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $kbNum -and $_.Name -match $archMsu -and $_.Length -gt 1MB } |
        Select-Object -First 1
        if ($alreadyHave) {
            if ($alreadyHave.FullName -ne $destPath) {
                Rename-Item $alreadyHave.FullName $destPath -ErrorAction SilentlyContinue
                Write-OK "Found in cache (renamed to canonical): $fileName"
            }
            else {
                Write-OK "Already downloaded: $fileName ($([math]::Round($alreadyHave.Length/1MB,0)) MB)"
            }
            $downloaded++; continue
        }
        Write-Info "     Downloading $fileName (this may take a while)..."
        try {
            Save-MSCatalogUpdate -Update $best -Destination $DownloadDir -ErrorAction Stop
            $allNewMSUs = Get-ChildItem $DownloadDir -Filter "*.msu" | Where-Object { $_.Name -notmatch "^[0-9]_" }
            foreach ($newFile in $allNewMSUs) {
                $fileKB = ([regex]::Match($newFile.Name, 'KB\d+', 'IgnoreCase')).Value.ToUpper()
                if ($fileKB -eq $kbNum -and $newFile.FullName -ne $destPath) {
                    Rename-Item $newFile.FullName $destPath -Force -ErrorAction SilentlyContinue
                }
            }
            if (Test-Path $destPath) {
                Write-OK "Downloaded: $fileName ($([math]::Round((Get-Item $destPath).Length/1MB,0)) MB)"
                $downloaded++
            }
        }
        catch {
            Write-Warn "Download failed for $label`: $($_.Exception.Message)"
            if (Test-Path $destPath) { Remove-Item $destPath -Force -ErrorAction SilentlyContinue }
        }
    }

    if ($downloaded -eq 0) { return $null }
    Write-Host ""
    Write-OK "$downloaded of 2 update types downloaded to: $DownloadDir"
    return $DownloadDir
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 0: prerequisites
# ═════════════════════════════════════════════════════════════════════════════
Write-Banner
Write-Section "Checking prerequisites"

$staleMounts = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.MountStatus -ne "Ok" }
if ($staleMounts) {
    Write-Warn "Stale WIM mount point(s) detected from a previous run:"
    $staleMounts | ForEach-Object { Write-Host "    $($_.Path)" -ForegroundColor Yellow }
    Write-Info "Cleaning up stale mounts..."
    & dism.exe /Cleanup-Mountpoints | Out-Null
    Write-OK "Stale mounts cleaned"
}

$dismOut = & dism.exe /English /? 2>&1
if ($LASTEXITCODE -gt 1) { Write-Fail "DISM not found."; exit 1 }
Write-OK "DISM available"

$drive = Get-PSDrive ($env:SystemDrive.TrimEnd(':'))
$freeGB = [math]::Round($drive.Free / 1GB, 1)
if ($freeGB -lt 30) { Write-Warn "Only $freeGB GB free. At least 30 GB recommended." }
else { Write-OK "$freeGB GB free disk space" }

$internetOK = $false
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $null = Invoke-WebRequest "https://www.catalog.update.microsoft.com" -UseBasicParsing -TimeoutSec 10 `
        -Headers @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
    $internetOK = $true
    Write-OK "Internet access available"
}
catch {
    Write-Warn "No internet access detected ($($_.Exception.Message))"
    Write-Warn "Automatic update download not available - manual mode only"
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 1: WIM/ESD folder + index selection
# ═════════════════════════════════════════════════════════════════════════════
Write-Section "Step 1/4 - Source folder"
Write-Host ""
Write-Host "  WIM/ESD source folder:" -ForegroundColor White
Write-Host "    Contains install.wim or install.esd" -ForegroundColor DarkGray
Write-Host ""

if (-not (Test-Path $WimEsdPath)) {
    $WimEsdPath = Read-PathWithDefault `
        -Prompt  "Path to folder containing install.wim or install.esd:" `
        -Default "$ScriptRoot\WimEsd" `
        -MustExist
    if (-not $WimEsdPath) { exit 1 }
}

Write-Info "Scanning $WimEsdPath for install.wim or install.esd..."
$wimEsdDiscovered = Resolve-WimEsdFolder -Folder $WimEsdPath `
    -LanguagesAndOptionalFeaturesPath $LanguagesAndOptionalFeaturesPath

$wimFile = $null
$LPSearchRoot = $null
$FODSearchRoot = $null

if ($wimEsdDiscovered) {
    $wimFile = $wimEsdDiscovered.WimFile
    $LPSearchRoot = $wimEsdDiscovered.LPSearchRoot
    $FODSearchRoot = $wimEsdDiscovered.FODSearchRoot
}
else {
    Write-Fail "No install.wim or install.esd found in: $WimEsdPath"
    Write-Host ""
    Write-Host "  Make sure install.wim or install.esd is present in the folder." -ForegroundColor Yellow
    exit 1
}

if (-not $wimFile -or -not (Test-Path $wimFile)) {
    Write-Fail "Could not locate install.wim or install.esd."
    exit 1
}

# Select WIM index
$images = Get-WindowsImage -ImagePath $wimFile
$enterpriseImage = $images | Where-Object {
    $_.ImageName -match "Enterprise" -and $_.ImageName -notmatch "Evaluation"
} | Select-Object -First 1

if ($WimIndex -ne 0) {
    $chosenImage = $images | Where-Object { $_.ImageIndex -eq $WimIndex }
    if (-not $chosenImage) { Write-Fail "Index $WimIndex not found in WIM."; exit 1 }
    Write-OK "Using forced index: [$WimIndex] $($chosenImage.ImageName)"
}
elseif ($enterpriseImage) {
    $WimIndex = $enterpriseImage.ImageIndex
    $chosenImage = $enterpriseImage
    Write-OK "Auto-selected: [$WimIndex] $($chosenImage.ImageName)"
}
elseif (@($images).Count -eq 1) {
    $chosenImage = @($images)[0]
    $WimIndex = $chosenImage.ImageIndex
    Write-OK "Auto-selected (only edition available): [$WimIndex] $($chosenImage.ImageName)"
}
else {
    Write-Warn "Could not auto-detect Enterprise edition. Available editions:"
    foreach ($img in $images) { Write-Host ("    [{0}] {1}" -f $img.ImageIndex, $img.ImageName) -ForegroundColor White }
    Write-Host ""
    if ($Unattended) {
        Write-Fail "Unattended mode: cannot prompt for WIM index. Use -WimIndex to specify one."
        exit 1
    }
    $WimIndex = [int](Read-Host "  Enter index number")
    $chosenImage = $images | Where-Object { $_.ImageIndex -eq $WimIndex }
    if (-not $chosenImage) { Write-Fail "Index $WimIndex not found."; exit 1 }
    Write-OK "Selected: [$WimIndex] $($chosenImage.ImageName)"
}

$chosenImageFull = Get-WindowsImage -ImagePath $wimFile -Index $WimIndex
$CatalogSearchTerms = Get-CatalogSearchTerms -WimVersion $chosenImageFull.Version

# ═════════════════════════════════════════════════════════════════════════════
# Step 2: language packs pre-flight
# ═════════════════════════════════════════════════════════════════════════════
$allLPCabs = @()

if (-not $SkipLanguagePacks) {
    if ($Languages -ne "") {
        $ResolvedLocales = @(Resolve-LanguageCodes -CodeString $Languages)
    }
    elseif ($Unattended) {
        Write-Info "Unattended with no -Languages - skipping language packs (English only)."
        $SkipLanguagePacks = $true
    }
    else {
        Write-Host ""
        Write-Host "  Supported language codes:" -ForegroundColor White
        Write-Host "  $SupportedCodesLine" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Enter comma-separated 2-letter country codes, e.g: ru" -ForegroundColor White
        Write-Host "  (Press Enter for default: ru)" -ForegroundColor DarkGray
        $langInput = Read-Host "  Languages"
        if ($langInput.Trim() -eq "") { $langInput = "ru" }
        $Languages = $langInput
        $ResolvedLocales = @(Resolve-LanguageCodes -CodeString $langInput)
    }
}

if (-not $SkipLanguagePacks) {
    Write-Section "Step 2/4 - Language Packs + Language.* FoD"
    Write-Host "  Languages to install: $($ResolvedLocales -join ', ')" -ForegroundColor Cyan
    Write-Host ""

    Write-Info "Scanning language pack folder (this may take a moment)..."
    $allLPCabs = @(Get-ChildItem $LPSearchRoot -Filter "*.cab" -ErrorAction SilentlyContinue)
    Write-Info "Found $($allLPCabs.Count) cab files in LP folder."
    # ── Pre-flight: validate LPSearchRoot is a usable repository ────────────
    $lpCheck = Test-LPSourceComplete -LPSourceRoot $LPSearchRoot `
        -RequiredLocales $ResolvedLocales -MinCabsPerLocale 43
    # Show per-locale counts so the operator sees the threshold at a glance
    if ($lpCheck.LocaleCounts.Count -gt 0) {
        foreach ($loc in ($lpCheck.LocaleCounts.Keys | Sort-Object)) {
            $cnt = $lpCheck.LocaleCounts[$loc]
            $col = if ($cnt -ge 43) { "Green" } elseif ($cnt -ge 30) { "Yellow" } else { "Red" }
            Write-Host ("    [{0}] {1} locale-specific cabs" -f $loc, $cnt) -ForegroundColor $col
        }
    }

    if ($lpCheck.Missing.Count -gt 0) {
        Write-Host ""
        if ($lpCheck.Fatal) {
            Write-Fail "LP repository is missing required metadata files:"
            $lpCheck.Missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
            Write-Host ""
            Write-Host "  Copy FoDMetadata_Client.cab, FodMetadataServicing-*.cab, and the" -ForegroundColor Yellow
            Write-Host "  metadata\DesktopTargetCompDB_*.xml.cab files from the original" -ForegroundColor Yellow
            Write-Host "  LanguagesAndOptionalFeatures folder." -ForegroundColor Yellow
            Write-Host ""
            if ($Unattended) { exit 1 }
            if (-not (Confirm-Continue "Continue anyway (LP install will fail)?")) {
                exit 0
            }
        } else {
            Write-Warn "LP repository incomplete for requested locales:"
            $lpCheck.Missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
            Write-Host ""
            Write-Host "  Restore the missing .cab files from the original LanguagesAndOptionalFeatures" -ForegroundColor Yellow
            Write-Host "  folder. Removing any locale-specific cab that DISM expects at install" -ForegroundColor Yellow
            Write-Host "  time produces 0x80070002 (file not found)." -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        $countsStr = ($lpCheck.LocaleCounts.Keys | Sort-Object | ForEach-Object { "$_=$($lpCheck.LocaleCounts[$_])" }) -join ", "
        Write-OK "LP repository complete ($countsStr locale-specific cabs)"
    }
    $lpArchStr = "x64"
    $fodArchStr = "amd64"

    $anyMissing = $false
    foreach ($lang in $ResolvedLocales) {
        $lp = $allLPCabs | Where-Object { $_.Name -match "Language-Pack_${lpArchStr}_$lang" } | Select-Object -First 1
        $fod = $allLPCabs | Where-Object { $_.Name -match "LanguageFeatures-Basic-$lang" -and
            $_.Name -match "~${fodArchStr}~" } | Select-Object -First 1
        if (-not $lp) { $anyMissing = $true }
        if (-not $fod) { $anyMissing = $true }
        $lc = if ($lp) { "Green" } else { "Red" }
        $fc = if ($fod) { "Green" } else { "Red" }
        Write-Host ("  [$($lang.ToUpper())]  LP: ") -NoNewline
        Write-Host ("{0,-8}" -f $(if ($lp) { "OK" } else { "MISSING" })) -ForegroundColor $lc -NoNewline
        Write-Host "  FOD Basic: " -NoNewline
        Write-Host ("{0,-8}" -f $(if ($fod) { "OK" } else { "MISSING" })) -ForegroundColor $fc -NoNewline
        Write-Host "  [$(if ($lp) { $lp.Name } else { 'NOT FOUND' })]" -ForegroundColor DarkGray
    }
    if ($anyMissing) {
        Write-Host ""
        Write-Fail "Language pack or FoD cab files missing in: $LPSearchRoot"
        Write-Host ""
        Write-Host "  The LanguagesAndOptionalFeatures folder must contain the .cab files." -ForegroundColor Yellow
        Write-Host "  Set -LanguagesAndOptionalFeaturesPath explicitly, or place the folder" -ForegroundColor White
        Write-Host "  next to install.wim (auto-detected as <WimFolder>\LanguagesAndOptionalFeatures)." -ForegroundColor White
        Write-Host ""
        Write-Host "  Download from the Microsoft 365 Admin Center:" -ForegroundColor White
        Write-Host "  https://admin.microsoft.com/adminportal/home#/subscriptions/vlnew/downloadsandkeys" -ForegroundColor Cyan
        Write-Host ""
        if ($Unattended) { exit 1 }
        if (-not (Confirm-Continue "Continue anyway (missing languages will be skipped)?")) {
            exit 0
        }
    }
    else {
        Write-OK "All language pack files found"
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 3: updates
# ═════════════════════════════════════════════════════════════════════════════
$resolvedUpdatePath = $null

if (-not $SkipUpdates) {
    Write-Section "Step 3/4 - Updates (Patch Tuesday)"
    if ($UpdatePath) {
        $resolvedUpdatePath = $UpdatePath
        $updCount = @(
            Get-ChildItem $resolvedUpdatePath -Filter "*.msu" -ErrorAction SilentlyContinue
            Get-ChildItem $resolvedUpdatePath -Filter "*.cab" -ErrorAction SilentlyContinue
        ).Count
        Write-OK "Using specified update folder: $UpdatePath ($updCount files)"
    }
    elseif ($internetOK) {
        Write-Host ""
        Write-Host "  Automatic download from Microsoft Update Catalog." -ForegroundColor White
        Write-Host "  The script will search and download the latest version of:" -ForegroundColor DarkGray
        Write-Host "    1. LCU        - Cumulative Update (includes SSU)" -ForegroundColor White
        Write-Host "    2. Checkpoint - KB5043080 (required for LCU after LP/FoD)" -ForegroundColor White
        Write-Host "    3. .NET       - .NET Framework 3.5 / 4.8.1 Cumulative Update" -ForegroundColor White
        Write-Host ""
        Write-Host "  Already-downloaded KBs are reused automatically (checked by KB number)." -ForegroundColor DarkGray
        Write-Warn "  First-time download may take 10-20 min (LCU alone is 500-800 MB)."

        if (Confirm-Continue "Download updates now?") {
            $cacheDir = Read-PathWithDefault `
                -Prompt  "Folder to download and cache updates:" `
                -Default "$ScriptRoot\Updates"
            if (-not $cacheDir) { $cacheDir = "$ScriptRoot\Updates" }
            if (-not (Test-Path $cacheDir)) {
                try {
                    New-Item $cacheDir -ItemType Directory -Force | Out-Null
                    Write-OK "Created update folder: $cacheDir"
                }
                catch {
                    Write-Warn "Cannot create update folder: $($_.Exception.Message)"
                    $cacheDir = $null
                }
            }
            if ($cacheDir) {
                Invoke-UpdateFolderCleanup -DownloadDir $cacheDir
                $resolvedUpdatePath = Invoke-AutoUpdateDownload -DownloadDir $cacheDir
                if (-not $resolvedUpdatePath) {
                    Write-Warn "Automatic download failed. Falling back to manual mode..."
                }
            }
        }
    }

    if (-not $resolvedUpdatePath) {
        Write-Host ""
        Write-Host "  MANUAL DOWNLOAD - from Microsoft Update Catalog:" -ForegroundColor White
        Write-Host "  Link: https://www.catalog.update.microsoft.com" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Search for the following for Windows 11 Version $($CatalogSearchTerms.VersionString) x64:" -ForegroundColor White
        Write-Host "    LCU        - 'Cumulative Update for Windows 11 Version $($CatalogSearchTerms.VersionString) for x64'" -ForegroundColor Yellow
        Write-Host "    Checkpoint - 'KB5043080' (checkpoint update for 24H2+)" -ForegroundColor Yellow
        Write-Host "    .NET CU    - '.NET Framework 3.5 4.8.1 Windows 11 $($CatalogSearchTerms.VersionString) x64'" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  IMPORTANT - LCU filename must include the SHA1 hash from Microsoft:" -ForegroundColor White
        Write-Host "    Correct : windows11.0-kb5083769-x64_57f4bd47...msu" -ForegroundColor Green
        Write-Host "    Wrong   : windows11.0-kb5083769-x64.msu  (hash stripped - DISM will reject)" -ForegroundColor Red
        Write-Host "  To get the correct filename: click Download -> right-click the link -> Save link as." -ForegroundColor White
        Write-Host ""
        Write-Host "  NOTE: SSU is bundled inside LCU for 24H2/25H2 - no separate download needed." -ForegroundColor DarkGray
        Write-Host ""

        $manualPath = Read-PathWithDefault `
            -Prompt  "Path to folder with downloaded .msu/.cab files (press Enter to skip):" `
            -Default "$ScriptRoot\Updates"

        if ($manualPath -and (Test-Path $manualPath)) {
            $updFiles = @(
                Get-ChildItem $manualPath -Filter "*.msu" -ErrorAction SilentlyContinue
                Get-ChildItem $manualPath -Filter "*.cab" -ErrorAction SilentlyContinue
            )
            if ($updFiles -and $updFiles.Count -gt 0) {
                $resolvedUpdatePath = $manualPath
                Write-Info "Found $($updFiles.Count) update file(s):"
                $updFiles | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor White }
            }
            else {
                Write-Warn "No .msu/.cab files found - skipping updates."
            }
        }
        else {
            Write-Warn "Skipping updates."
        }
    }

    # Early checkpoint check — runs whether path came from -UpdatePath, auto-download,
    # or manual prompt (previously on "elseif", so manual path skipped it).
    if ($resolvedUpdatePath -and (Test-Path $resolvedUpdatePath)) {
        $lcuInFolder = Get-ChildItem $resolvedUpdatePath -Filter "windows11.0-kb*-x64*.msu" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "kb5043080" } | Select-Object -First 1
        $cpInFolder = Get-ChildItem $resolvedUpdatePath -Filter "*kb5043080*.msu" -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($lcuInFolder -and -not $cpInFolder) {
            Write-Host ""
            Write-Warn "LCU found but checkpoint KB5043080 is missing from: $resolvedUpdatePath"
            Write-Warn "Without checkpoint, LCU pass 2 (after LP/FoD) will fail with 0x800F0838."
            Write-Host ""
            Write-Host "  Options:" -ForegroundColor White
            Write-Host "    1. Download KB5043080 from https://www.catalog.update.microsoft.com" -ForegroundColor Cyan
            Write-Host "    2. Place it in: $resolvedUpdatePath" -ForegroundColor Cyan
            Write-Host ""
            if (-not $Unattended) {
                if (-not (Confirm-Continue "Continue anyway (pass 2 will likely fail)?")) {
                    exit 0
                }
            }
        }
        elseif ($lcuInFolder -and $cpInFolder) {
            Write-OK "Checkpoint KB5043080 found: $($cpInFolder.Name)"
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Step 4: output path + work folder
# ═════════════════════════════════════════════════════════════════════════════
Write-Section "Step 4/4 - Output"

$_buildStr = $chosenImageFull.Version -replace '^\d+\.\d+\.', ''
$_versionStr = $CatalogSearchTerms.VersionString
$_dateStr = Get-Date -Format "yyyyMMdd"

$_langStr = if ($SkipLanguagePacks -or @($ResolvedLocales).Count -eq 0) {
    "en"
}
else {
    $rawCodes = $Languages.ToLower().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if ($rawCodes) { $rawCodes -join "_" } else { "en" }
}
$_autoName = "Win11_${_versionStr}_${_buildStr}_${_langStr}_${_dateStr}.wim"

if ($OutputPath -and (Test-Path $OutputPath -PathType Container)) {
    $OutputPath = Join-Path $OutputPath $_autoName
}
elseif ($OutputPath -and -not [System.IO.Path]::GetExtension($OutputPath)) {
    $OutputPath = Join-Path $OutputPath $_autoName
}

$_autoPath = Join-Path (Split-Path $OutputPath -Parent) $_autoName
if (-not $OutputPath -or $OutputPath -eq "$ScriptRoot\Output\install.wim") { $OutputPath = $_autoPath }

$OutputPath = Read-PathWithDefault `
    -Prompt  "Output WIM path (folder only = auto-name, or full path with .wim):" `
    -Default $OutputPath

if ($OutputPath -and (Test-Path $OutputPath -PathType Container)) {
    $OutputPath = Join-Path $OutputPath $_autoName
}
elseif ($OutputPath -and -not [System.IO.Path]::GetExtension($OutputPath)) {
    $OutputPath = Join-Path $OutputPath $_autoName
}

$outputDir = Split-Path $OutputPath -Parent
if (-not $outputDir) { $outputDir = Split-Path $OutputPath -Qualifier }
if (-not (Test-Path $outputDir)) {
    New-Item $outputDir -ItemType Directory -Force | Out-Null
    Write-OK "Created: $outputDir"
}
if (Test-Path $OutputPath) { Write-Warn "File already exists and will be overwritten." }
Write-OK "Output WIM: $OutputPath"

Test-OutputDiskSpace -Path $OutputPath -Label "output location"

# Work folder for WIM mount + scratch (~20 GB)
$workRootDefault = Join-Path $outputDir "WIMServicing_Work"
Write-Host ""
Write-Host "  Work folder (WIM mount + scratch, ~20 GB needed during build)." -ForegroundColor White
Write-Host "  Delete-able after build completes." -ForegroundColor DarkGray
$workRoot = Read-PathWithDefault `
    -Prompt  "Work folder for WIM mount + scratch files:" `
    -Default $workRootDefault
if (-not $workRoot) { $workRoot = $workRootDefault }
if (-not (Test-Path $workRoot)) {
    try {
        New-Item $workRoot -ItemType Directory -Force | Out-Null
        Write-OK "Created work folder: $workRoot"
    }
    catch {
        Write-Fail "Cannot create work folder: $($_.Exception.Message)"
        exit 1
    }
}
Write-OK "Work folder: $workRoot"

Test-OutputDiskSpace -Path $workRoot -Label "work folder"

# ── Summary and confirmation ─────────────────────────────────────────────────
Write-Section "Summary"
Write-Host ""
Write-Host "  The following actions will be performed:" -ForegroundColor White
Write-Host ""
Write-Host "    WIM/ESD source : $WimEsdPath" -ForegroundColor Cyan
Write-Host "    WIM file       : $wimFile" -ForegroundColor Cyan
Write-Host "    Edition       : [$WimIndex] $($chosenImage.ImageName)" -ForegroundColor Cyan

if (-not $SkipLanguagePacks) {
    Write-Host "    Language packs: $($ResolvedLocales -join ', ')  (+ Language.* FoD)" -ForegroundColor Cyan
    Write-Host "    LP/FoD source : $LPSearchRoot" -ForegroundColor Cyan
}

if (-not $SkipUpdates -and $resolvedUpdatePath) {
    $n = @(
        Get-ChildItem $resolvedUpdatePath -Filter "*.msu" -ErrorAction SilentlyContinue
        Get-ChildItem $resolvedUpdatePath -Filter "*.cab" -ErrorAction SilentlyContinue
    ).Count
    Write-Host "    Updates       : $resolvedUpdatePath ($n files)" -ForegroundColor Cyan
}
elseif (-not $SkipUpdates) {
    Write-Host "    Updates       : Skipped" -ForegroundColor Yellow
}

if ($FoDList -ne "") { Write-Host "    Features (FoD): $FoDList" -ForegroundColor Cyan }
if ($DriverListPath -ne "") {
    Write-Host "    Drivers       : $DriverListPath (selected list)" -ForegroundColor Cyan
}
elseif ($DriverPath -ne "") {
    Write-Host "    Drivers       : $DriverPath (full folder)" -ForegroundColor Cyan
}
Write-Host "    Output WIM    : $OutputPath" -ForegroundColor Cyan
Write-Host "    Work folder   : $workRoot" -ForegroundColor Cyan
Write-Host ""

Write-Warn "This process typically takes ~30-60 min. Do NOT abort while the WIM is mounted."
Write-Host ""

if (-not (Confirm-Continue "Start servicing now?")) {
    Write-Info "Cancelled by user."
    exit 0
}

# ── Work dirs and log ────────────────────────────────────────────────────────
$mountDir = Join-Path $workRoot "Mount"
$workWim = Join-Path $workRoot "install_work.wim"
$scratchDir = Join-Path $workRoot "Scratch"
$logFile = Join-Path $outputDir ("WIMServicing_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmm"))

@($workRoot, $mountDir, $scratchDir) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item $_ -ItemType Directory -Force | Out-Null }
}

function Write-Log {
    param([string]$msg, [string]$level = "INFO")
    [System.IO.File]::AppendAllText($logFile, ("[{0}] [{1}] {2}`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $level, $msg))
}

Write-Log "=== WIM Wizard v$ScriptVersion ==="

# Load custom Appx list from XML
if (($AppxListPath -is [string]) -and ($AppxListPath.Length -gt 0) -and (Test-Path -LiteralPath $AppxListPath)) {
    try {
        [xml]$AppxXml = Get-Content $AppxListPath -ErrorAction Stop
        [array]$pkgNodes = $AppxXml.AppxRemovalList.Package
        if ($null -eq $pkgNodes -or $pkgNodes.Count -eq 0 -or $null -eq $pkgNodes[0]) {
            $AppxToRemove = @()
        }
        else {
            $AppxToRemove = @($pkgNodes | ForEach-Object { $_.Id } | Where-Object { $_ })
        }
        Write-Info "Loaded custom Appx list from: $AppxListPath ($($AppxToRemove.Count) packages)"
        Write-Log "Loaded custom Appx list: $AppxListPath ($($AppxToRemove.Count) packages)"
        if ($AppxToRemove.Count -eq 0) {
            Write-Info "Appx list is empty - skipping Appx removal"
            $SkipAppxRemoval = $true
        }
    }
    catch {
        Write-Warn "Could not load AppxListPath: $($_.Exception.Message) - using default list"
        Write-Log "WARN: Could not load AppxListPath: $($_.Exception.Message)" "WARN"
        $AppxToRemove = $AppxToRemoveDefault
    }
}
else {
    $AppxToRemove = $AppxToRemoveDefault
}

if (-not $SkipAppxRemoval) {
    Write-Host "    Appx removal  : $($AppxToRemove.Count) packages removed if present" -ForegroundColor Cyan
}

# Cut-pasteable command line for the log
$_cmdParts = @(".\WimWizard.ps1")
if ($WimEsdPath) { $_cmdParts += "-WimEsdPath `"$WimEsdPath`"" }
if ($LanguagesAndOptionalFeaturesPath) { $_cmdParts += "-LanguagesAndOptionalFeaturesPath `"$LanguagesAndOptionalFeaturesPath`"" }
if ($OutputPath) { $_cmdParts += "-OutputPath `"$OutputPath`"" }
if ($WimIndex -ne 0) { $_cmdParts += "-WimIndex $WimIndex" }
if ($Languages) { $_cmdParts += "-Languages `"$Languages`"" }
if ($UpdatePath) { $_cmdParts += "-UpdatePath `"$UpdatePath`"" }
if ($FoDList) { $_cmdParts += "-FoDList `"$FoDList`"" }
if ($DriverPath) { $_cmdParts += "-DriverPath `"$DriverPath`"" }
if ($DriverListPath) { $_cmdParts += "-DriverListPath `"$DriverListPath`"" }
if ($AppxListPath) { $_cmdParts += "-AppxListPath `"$AppxListPath`"" }
if ($SkipUpdates) { $_cmdParts += "-SkipUpdates" }
if ($SkipLanguagePacks) { $_cmdParts += "-SkipLanguagePacks" }
if ($SkipAppxRemoval) { $_cmdParts += "-SkipAppxRemoval" }
if ($SkipDefenderUpdate) { $_cmdParts += "-SkipDefenderUpdate" }
if ($Unattended) { $_cmdParts += "-Unattended" }
if ($DebugBuild) { $_cmdParts += "-DebugBuild" }
Write-Log ($_cmdParts -join " ")
Write-Log "WIM/ESD source: $WimEsdPath  WIM: $wimFile  Index: $WimIndex  Edition: $($chosenImage.ImageName)"
Write-Log "Work folder: $workRoot"

# ── Defender kit (KB4568292) ─────────────────────────────────────────────────
$DefenderKitUrls = @{
    amd64 = 'https://go.microsoft.com/fwlink/?linkid=2144531'
}
$DefenderKitScriptKnownHash = '5684930AE11529387E78A0BA0A61BA2971E45CAAED941694A3197331A664F491'

function Get-DefenderKitScriptHash {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $idx = $text.IndexOf('# SIG # Begin signature block')
    if ($idx -ge 0) { $text = $text.Substring(0, $idx) }
    $norm = [regex]::Replace($text, '\s+', '')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm)) }
    finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '')
}

function Get-ImageArchTag {
    param($ImageInfo)
    $a = [string]$ImageInfo.Architecture
    if ($a -eq '9' -or $a -eq 'x64') { return 'amd64' }
    return $null
}

function Initialize-DefenderKit {
    param([string]$ArchTag, [string]$CacheDir, [string]$ExtractDir)

    if (-not $DefenderKitUrls.ContainsKey($ArchTag)) { throw "No Defender kit URL for image architecture '$ArchTag'" }
    if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item $CacheDir -ItemType Directory -Force | Out-Null }

    $zipPath = Join-Path $CacheDir "defender-update-kit-$ArchTag.zip"

    if (Test-Path -LiteralPath $zipPath) {
        $age = (Get-Item -LiteralPath $zipPath).LastWriteTime
        $ageDays = [math]::Round(((Get-Date) - $age).TotalDays, 1)
        Write-OK "Defender kit cached: $zipPath (age: $ageDays days)"
        Write-Log "Defender kit using cached copy: $zipPath (age: $ageDays days)"
    }
    else {
        if (-not $internetOK) {
            Write-Warn "No internet and no cached Defender kit - skipping Defender update"
            Write-Log "WARN: No internet and no cached Defender kit - skipped" "WARN"
            return $null
        }
        Write-Info "Downloading Defender update kit ($ArchTag, ~150-250 MB)..."
        $tmpPath = "$zipPath.download"
        $oldPP = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $DefenderKitUrls[$ArchTag] -OutFile $tmpPath -UseBasicParsing -ErrorAction Stop
            $fs = [System.IO.File]::OpenRead($tmpPath)
            try { $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte() } finally { $fs.Dispose() }
            if ($b0 -ne 0x50 -or $b1 -ne 0x4B) { throw "downloaded file is not a ZIP archive" }
            Move-Item -LiteralPath $tmpPath -Destination $zipPath -Force
            $mb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 0)
            Write-OK "Defender kit downloaded ($mb MB)"
            Write-Log "Defender kit downloaded: $zipPath ($mb MB)"
        }
        catch {
            Write-Warn "Defender kit download failed: $($_.Exception.Message)"
            Write-Log "WARN: Defender kit download failed: $($_.Exception.Message)" "WARN"
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
            return $null
        }
        finally { $ProgressPreference = $oldPP }
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        Write-Warn "Defender kit zip not on disk - skipping Defender update"
        Write-Log "WARN: Defender kit zip missing - skipped" "WARN"
        return $null
    }

    if (Test-Path -LiteralPath $ExtractDir) { Remove-Item -LiteralPath $ExtractDir -Recurse -Force }
    $zipOut = Join-Path $ExtractDir 'zip'
    $cabOut = Join-Path $ExtractDir 'cab'
    New-Item $zipOut -ItemType Directory -Force | Out-Null
    New-Item $cabOut -ItemType Directory -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $zipOut -Force

    $cab = Get-ChildItem -LiteralPath $zipOut -Recurse -File -Filter 'defender-dism-*.cab' | Select-Object -First 1
    if (-not $cab) { throw "defender-dism-*.cab not found in kit" }

    $sig = Get-AuthenticodeSignature -LiteralPath $cab.FullName
    if ($sig.Status -ne 'Valid') { throw "Defender cab signature is not valid ($($sig.Status): $($sig.StatusMessage))" }
    if ($null -eq $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "Defender cab is not signed by Microsoft Corporation (signer: $($sig.SignerCertificate.Subject))"
    }
    Write-OK "Cab signature valid ($($cab.Name), Microsoft Corporation)"

    $kitPs1 = Get-ChildItem -LiteralPath $zipOut -Recurse -File -Filter 'DefenderUpdateWinImage.ps1' | Select-Object -First 1
    if ($kitPs1) {
        $h = Get-DefenderKitScriptHash -Path $kitPs1.FullName
        if ([string]::IsNullOrEmpty($DefenderKitScriptKnownHash)) {
            Write-Info "DefenderUpdateWinImage.ps1 hash (no baseline set): $h"
            Write-Log "Defender kit script hash (no baseline): $h"
        }
        elseif ($h -ne $DefenderKitScriptKnownHash) {
            Write-Warn "DefenderUpdateWinImage.ps1 has changed since WimWizard's implementation was written."
            Write-Warn "Review its AddUpdate logic against WimWizard. New hash: $h"
            Write-Log "WARN: Defender kit script changed. Expected $DefenderKitScriptKnownHash, got $h" "WARN"
        }
        else {
            Write-OK "DefenderUpdateWinImage.ps1 unchanged (hash matches baseline)"
        }
    }
    else {
        Write-Warn "DefenderUpdateWinImage.ps1 not found in kit - cannot check for logic changes"
        Write-Log "WARN: DefenderUpdateWinImage.ps1 missing from kit" "WARN"
    }

    $expOut = & expand.exe $cab.FullName '-F:*' $cabOut 2>&1
    if ($LASTEXITCODE -ne 0) { throw "expand.exe failed (exit $LASTEXITCODE): $(($expOut | Out-String).Trim())" }

    $xmlPath = Join-Path $cabOut 'package-defender.xml'
    $defSrc = Join-Path $cabOut 'Definition Updates\Updates'
    $platSrc = Join-Path $cabOut 'Platform'
    foreach ($p in @($xmlPath, $defSrc, $platSrc)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Unexpected kit layout - missing: $($p.Substring($cabOut.Length + 1))" }
    }
    if (@(Get-ChildItem -LiteralPath $defSrc -Force).Count -eq 0) { throw "Unexpected kit layout - 'Definition Updates\Updates' is empty" }
    if (@(Get-ChildItem -LiteralPath $platSrc -Force).Count -eq 0) { throw "Unexpected kit layout - 'Platform' is empty" }

    try {
        [xml]$x = Get-Content -LiteralPath $xmlPath -Raw
        $pkg = @{
            Arch             = [string]$x.packageinfo.arch
            PackageVersion   = [string]$x.packageinfo.versions.defender
            PlatformVersion  = [string]$x.packageinfo.versions.platform
            EngineVersion    = [string]$x.packageinfo.versions.engine
            SignatureVersion = [string]$x.packageinfo.versions.signatures
        }
    }
    catch { throw "package-defender.xml is missing expected fields: $($_.Exception.Message)" }

    if ($pkg.Arch -notmatch $ArchTag) {
        throw "Defender kit architecture '$($pkg.Arch)' does not match image architecture '$ArchTag'"
    }

    Write-OK ("Defender package {0} (platform {1}, engine {2}, security intelligence {3})" -f `
            $pkg.PackageVersion, $pkg.PlatformVersion, $pkg.EngineVersion, $pkg.SignatureVersion)
    Write-Log ("Defender kit ready: package {0}, platform {1}, engine {2}, SI {3}" -f `
            $pkg.PackageVersion, $pkg.PlatformVersion, $pkg.EngineVersion, $pkg.SignatureVersion)

    $pkg.XmlPath = $xmlPath
    $pkg.DefSrc = $defSrc
    $pkg.PlatSrc = $platSrc
    return $pkg
}

function Clear-DefenderKitFromImage {
    param([string]$MountPath)
    $base = Join-Path $MountPath 'ProgramData\Microsoft\Windows Defender'
    $marker = Join-Path $MountPath 'Windows\Temp\package-defender.xml'
    foreach ($sub in @('Definition Updates\Updates', 'Platform')) {
        $t = Join-Path $base $sub
        if (Test-Path -LiteralPath $t) {
            Get-ChildItem -LiteralPath $t -Force | Remove-Item -Recurse -Force -ErrorAction Stop
        }
    }
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction Stop }
}

function Install-DefenderKitToImage {
    param([hashtable]$Kit, [string]$MountPath)

    $base = Join-Path $MountPath 'ProgramData\Microsoft\Windows Defender'
    $defTarget = Join-Path $base 'Definition Updates\Updates'
    $platTarget = Join-Path $base 'Platform'
    $tempTarget = Join-Path $MountPath 'Windows\Temp'
    $marker = Join-Path $tempTarget 'package-defender.xml'

    try {
        if (Test-Path -LiteralPath $marker) {
            $oldVer = 'unknown'
            try { [xml]$ox = Get-Content -LiteralPath $marker -Raw; $oldVer = [string]$ox.packageinfo.versions.defender } catch {}
            Write-Info "Image already contains Defender package $oldVer - replacing"
            Write-Log "Defender: existing package $oldVer found in image - clearing before add"
            Clear-DefenderKitFromImage -MountPath $MountPath
        }
        foreach ($d in @($defTarget, $platTarget, $tempTarget)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
        }
        Write-Info "Copying security intelligence and engine..."
        Copy-Item -Path (Join-Path $Kit.DefSrc '*')  -Destination $defTarget  -Recurse -Force -ErrorAction Stop
        Write-Info "Copying platform..."
        Copy-Item -Path (Join-Path $Kit.PlatSrc '*') -Destination $platTarget -Recurse -Force -ErrorAction Stop
        Copy-Item -LiteralPath $Kit.XmlPath -Destination $tempTarget -Force -ErrorAction Stop
        Write-OK "Defender updated in image (package $($Kit.PackageVersion))"
        Write-Log "Defender update applied: package $($Kit.PackageVersion)"
        return $true
    }
    catch {
        Write-Warn "Defender update failed: $($_.Exception.Message)"
        Write-Log "WARN: Defender update failed: $($_.Exception.Message) - rolling back" "WARN"
        try {
            Clear-DefenderKitFromImage -MountPath $MountPath
            Write-Warn "Defender changes rolled back - image keeps its inbox Defender"
            Write-Log "Defender rollback OK" "WARN"
        }
        catch {
            throw "Defender update failed and rollback also failed ($($_.Exception.Message)) - image state is inconsistent, aborting build"
        }
        return $false
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Main servicing try block
# ═════════════════════════════════════════════════════════════════════════════
try {

    # Copy WIM
    Write-Section "Copying source WIM"
    if ($wimFile -match "\.esd$") {
        Write-Info "ESD format - exporting to WIM first (this may take a while)..."
        Export-WindowsImage -SourceImagePath $wimFile -SourceIndex $WimIndex `
            -DestinationImagePath $workWim -CompressionType fast
        $workWimIndex = 1
        Write-OK "ESD exported to WIM"
    }
    else {
        Copy-Item $wimFile $workWim -Force
        Set-ItemProperty $workWim -Name IsReadOnly -Value $false
        $workWimIndex = $WimIndex
        Write-OK "WIM copied"
    }
    Write-Log "WIM copied: $workWim (index $workWimIndex)"

    # Defender kit - prepare BEFORE mount
    $script:DefenderKit = $null
    $script:DefenderStatus = "Skipped (-SkipDefenderUpdate)"
    if (-not $SkipDefenderUpdate) {
        Write-Section "Defender update kit (KB4568292)"
        try {
            $defImgInfo = Get-WindowsImage -ImagePath $workWim -Index $workWimIndex -ErrorAction Stop
            $defArch = Get-ImageArchTag -ImageInfo $defImgInfo
            if (-not $defArch) { throw "unsupported image architecture '$($defImgInfo.Architecture)'" }
            $defKitCacheDir = if ($resolvedUpdatePath -and (Test-Path $resolvedUpdatePath)) {
                Join-Path $resolvedUpdatePath "DefenderKit"
            }
            else {
                Join-Path $ScriptRoot "Updates\DefenderKit"
            }
            $script:DefenderKit = Initialize-DefenderKit -ArchTag $defArch `
                -CacheDir   $defKitCacheDir `
                -ExtractDir (Join-Path $workRoot "DefenderKit")
            $script:DefenderStatus = if ($script:DefenderKit) { "Pending" } else { "Not applied - no kit available" }
        }
        catch {
            Write-Warn "Defender kit preparation failed: $($_.Exception.Message)"
            Write-Warn "Continuing without Defender update."
            Write-Log "WARN: Defender kit preparation failed: $($_.Exception.Message)" "WARN"
            $script:DefenderKit = $null
            $script:DefenderStatus = "Not applied - kit preparation failed (see log)"
        }
    }

    # Mount
    Write-Section "Mounting WIM"
    $existingFiles = @(Get-ChildItem $mountDir -ErrorAction SilentlyContinue)
    if ($existingFiles.Count -gt 0) {
        Write-Warn "Mount directory is not empty - attempting to clean up stale mount..."
        try { Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction Stop; Write-OK "Stale mount dismounted (discarded)" }
        catch { Write-Warn "Could not dismount: $($_.Exception.Message)" }
        Remove-Item "$mountDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-OK "Mount directory cleared"
    }
    Mount-WindowsImage -ImagePath $workWim -Index $workWimIndex -Path $mountDir
    Write-OK "Mounted at: $mountDir"
    Write-Log "WIM mounted"

    # ── Update enumeration ───────────────────────────────────────────────────
    # $applyUpdates gates ONLY enumeration + LCU/DotNet/checkpoint selection.
    # The install.wim pipeline (drivers, LP, FoD, cleanup) runs regardless.
    $allUpdateFiles = @()
    $dotNetFiles = @()
    $lcuFile = $null
    $checkpointFile = $null
    $lcuAllFiles = @()

    $applyUpdates = (-not $SkipUpdates) -and [bool]$resolvedUpdatePath
    if ($applyUpdates) {
        $allUpdateFiles = @(
            Get-ChildItem $resolvedUpdatePath -Filter "*.msu" -ErrorAction SilentlyContinue
            Get-ChildItem $resolvedUpdatePath -Filter "*.cab" -ErrorAction SilentlyContinue
        ) | Where-Object { $_.Name -notmatch "-arm64[_.]" } | Sort-Object Name

        $dotNetFiles = @($allUpdateFiles | Where-Object { $_.Name -match "^2_DotNet" })

        $lcuFile = $allUpdateFiles |
        Where-Object { $_.Extension -eq ".msu" -and
            $_.Name -match "^windows11\.0-kb\d+-" -and
            $_.Name -notmatch "kb5043080" } |
        Select-Object -First 1

        $checkpointFile = $allUpdateFiles |
        Where-Object { $_.Extension -eq ".msu" -and
            $_.Name -match "^windows11\.0-kb5043080" } |
        Select-Object -First 1

        if ($lcuFile) {
            Write-Info "LCU selected: $($lcuFile.Name)"
            if ($checkpointFile) {
                Write-Info "Checkpoint selected: $($checkpointFile.Name)"
            }
            else {
                Write-Warn "Checkpoint KB5043080 not found in update folder"
                Write-Warn "LCU pass 2 may fail with 0x800F0838 if LP/FoD is installed between passes."
                Write-Warn "Add the checkpoint .msu to: $resolvedUpdatePath"
            }
        }

        $lcuAllFiles = @($lcuFile) + @($checkpointFile) | Where-Object { $_ }
    }   # END if ($applyUpdates)

    # ── PART 2: install.wim servicing ────────────────────────────────────────
    # Order (MS docs): drivers → SSU(LCU pass 1) → LP → FoD → Full LCU(pass 2)
    #                  → Cleanup → .NET CU

    if ($DriverPath -ne "" -or $DriverListPath -ne "") {
        Install-WimWizardDrivers -MountDir $mountDir -ScratchDir $scratchDir `
            -DriverPath $DriverPath -DriverListPath $DriverListPath
    }

    # Step 9: SSU via LCU pass 1
    if ($lcuFile) {
        Write-Section "install.wim - Step 9: SSU via LCU (pass 1)"
        $lcuTempDir = Join-Path $workRoot "LCU_temp"
        New-Item $lcuTempDir -ItemType Directory -Force | Out-Null
        foreach ($f in $lcuAllFiles) { Copy-Item $f.FullName $lcuTempDir }
        $lcuTempTarget = Join-Path $lcuTempDir $lcuFile.Name

        Write-Host "  >> LCU: $($lcuFile.Name)" -ForegroundColor White
        if ($checkpointFile) { Write-Host "  >> Checkpoint (auto-applied): $($checkpointFile.Name)" -ForegroundColor DarkGray }
        Write-Info "     Applying LCU pass 1 - this takes ~25 minutes..."
        try {
            $dismResult = & dism.exe /Image:$mountDir /Add-Package /PackagePath:$lcuTempTarget /ScratchDir:$scratchDir 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-OK "LCU pass 1 installed"; Write-Log "LCU pass 1 OK: $($lcuFile.Name)"
            }
            elseif ($LASTEXITCODE -eq -2146498530) {
                Write-Warn "LCU pass 1 not applicable (0x800f081e) - skipping"
                Write-Log "WARN 0x800f081e LCU pass 1" "WARN"
            }
            else {
                $errMsg = ($dismResult | Where-Object { $_ -match "Error" }) -join " "
                Remove-Item $lcuTempDir -Recurse -Force -ErrorAction SilentlyContinue
                throw "LCU pass 1 failed (exit $LASTEXITCODE): $errMsg"
            }
        }
        catch {
            Remove-Item $lcuTempDir -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }
        Remove-Item $lcuTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Step 10: Language packs
    if (-not $SkipLanguagePacks) {
        Write-Section "install.wim - Step 10: Language Packs"
        foreach ($lang in $ResolvedLocales) {
            Write-Host ""
            Write-Host "  >> $($lang.ToUpper())" -ForegroundColor White
            $lp = $allLPCabs | Where-Object { $_.Name -match "Language-Pack_x64_$lang" } | Select-Object -First 1
            if ($lp) {
                try {
                    Add-WindowsPackage -PackagePath $lp.FullName -Path $mountDir -ScratchDirectory $scratchDir | Out-Null
                    Write-OK "LP: $($lp.Name)"; Write-Log "LP: $($lp.FullName)"
                }
                catch {
                    $err = $_.Exception.Message
                    if ($err -match "0x800f0952") {
                        Write-Info "LP $lang already present in base image (0x800f0952) - skipping"
                        Write-Log "LP $lang skipped - already in base image (0x800f0952)" "INFO"
                    }
                    elseif ($err -match "0x800f081e") {
                        Write-Info "LP $lang not applicable (0x800f081e) - skipping"
                        Write-Log "LP $lang skipped - not applicable (0x800f081e)" "INFO"
                    }
                    else { throw }
                }
            }
            else {
                Write-Warn "LP not found for $lang"; Write-Log "WARN: LP not found for $lang" "WARN"
            }

            $FontTagMap = @{
                'ar-SA' = 'Arab'; 'he-IL' = 'Hebr'; 'ja-JP' = 'Jpan'
                'ko-KR' = 'Kore'; 'th-TH' = 'Thai'; 'zh-CN' = 'Hans'; 'zh-TW' = 'Hant'
            }
            if ($FontTagMap.ContainsKey($lang)) {
                $tag = $FontTagMap[$lang]
                Add-WindowsCapability -Name "Language.Fonts.$tag~~~und-$tag~0.0.1.0" `
                    -Path $mountDir -Source $LPSearchRoot -ScratchDirectory $scratchDir -ErrorAction SilentlyContinue | Out-Null
                Write-OK "  Font capability [$tag]"; Write-Log "Font capability [$tag]: OK"
            }
        }

        Write-Info "Configuring offline registry to preserve language FODs..."
        try {
            $offlineSoftware = "$mountDir\Windows\System32\config\SOFTWARE"
            reg load "HKLM\WW_SOFTWARE" $offlineSoftware | Out-Null
            reg add "HKLM\WW_SOFTWARE\Policies\Microsoft\Control Panel\International" `
                /v "BlockCleanupOfUnusedPreinstalledLangPacks" /t REG_DWORD /d 1 /f | Out-Null
            foreach ($locale in $ResolvedLocales) {
                reg add "HKLM\WW_SOFTWARE\Microsoft\Windows NT\CurrentVersion\MUI\UILanguages\$locale" /f | Out-Null
                Write-Log "MUI UILanguages registered: $locale"
            }
            [GC]::Collect(); Start-Sleep -Seconds 1
            reg unload "HKLM\WW_SOFTWARE" | Out-Null
            Write-OK "Offline registry: language cleanup suppressed for $($ResolvedLocales -join ', ')"
            Write-Log "Registry: BlockCleanupOfUnusedPreinstalledLangPacks=1, locales registered: $($ResolvedLocales -join ', ')"
        }
        catch {
            Write-Warn "Could not configure offline registry: $($_.Exception.Message)"
            try { reg unload "HKLM\WW_SOFTWARE" 2>$null | Out-Null } catch {}
        }
    }

    # Step 11: Features on Demand
    Write-Section "install.wim - Step 11: Features on Demand"

    if (-not $SkipLanguagePacks) {
        foreach ($lang in $ResolvedLocales) {
            Write-Host "  >> Language FoDs: $($lang.ToUpper())" -ForegroundColor White
            foreach ($fodType in @("Basic", "OCR", "Handwriting", "TextToSpeech", "Speech")) {
                $capName = "Language.$fodType~~~$lang~0.0.1.0"
                try {
                    Add-WindowsCapability -Name $capName -Path $mountDir -Source $LPSearchRoot -ScratchDirectory $scratchDir | Out-Null
                    Write-OK "  $fodType"; Write-Log "Language FoD OK: $capName"
                }
                catch {
                    $err = $_.Exception.Message
                    if ($err -match "0x800f081e" -or $err -match "not present\|not applicable") {
                        Write-Info "  $fodType not available for $lang - skipping"
                    }
                    else {
                        Write-Warn "  $fodType failed: $err"
                        Write-Log "WARN Language FoD $capName`: $err" "WARN"
                    }
                }
            }
        }
    }

    if ($FoDList -ne "") {
        # Home-user short-key catalog.
        # Capability-based FoDs use Add-WindowsCapability.
        # Package-based FoDs (Ethernet, Wifi drivers) use Add-WindowsPackage.
        $FoDCatalog = @{
            # --- Capability-based FoDs (Add-WindowsCapability) ---
            'PowerShell-ISE' = @{ Label = "PowerShell ISE"; Name = "Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0"; Type = 'Capability' }
            'SnippingTool'   = @{ Label = "Snipping Tool"; Name = "Microsoft.Windows.SnippingTool~~~~0.0.1.0"; Type = 'Capability' }
            'VBSCRIPT'       = @{ Label = "VBScript"; Name = "VBSCRIPT~~~~"; Type = 'Capability' }
            'Notepad'        = @{ Label = "Notepad"; Name = "Microsoft.Windows.Notepad~~~~0.0.1.0"; Type = 'Capability' }
            'DeveloperMode'  = @{ Label = "Developer Mode"; Name = "Tools.DeveloperMode.Core~~~~0.0.1.0"; Type = 'Capability' }
            'WinOcr'         = @{ Label = "Windows OCR"; Name = "Microsoft.Windows.WinOcr~~~~0.0.1.0"; Type = 'Capability' }

            # --- Package-based FoDs (Add-WindowsPackage) ---
            # The 'Name' here is a wildcard pattern to find the .cab in the source folder.
            'Ethernet'       = @{ Label = "Ethernet drivers"; Name = "Microsoft-Windows-Ethernet-Client-*-FOD-Package-*.cab"; Type = 'Package' }
            'Wifi'           = @{ Label = "Wi-Fi drivers"; Name = "Microsoft-Windows-Wifi-Client-*-FOD-Package-*.cab"; Type = 'Package' }
        }
        $fodKeys = $FoDList.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        foreach ($key in $fodKeys) {
            # Resolve: catalog hit | raw capability name (with ~) | short name (append ~~~~)
            $fodInfo = $null
            $capName = $null
            $label = $null
            $type = 'Capability'   # default for raw capability names

            if ($FoDCatalog.ContainsKey($key)) {
                $fodInfo = $FoDCatalog[$key]
                $capName = $fodInfo.Name
                $label = $fodInfo.Label
                $type = $fodInfo.Type
            }
            elseif ($key -match "~") {
                $capName = $key
                $label = $key
            }
            else {
                $capName = "$key~~~~"
                $label = "$key (capability $capName)"
            }

            Write-Host "  >> $label" -ForegroundColor White

            if ($type -eq 'Package') {
                $cabFiles = @(Get-ChildItem -Path $LPSearchRoot -Filter $fodInfo.Name -ErrorAction SilentlyContinue)
                if ($cabFiles.Count -eq 0) {
                    Write-Warn "$label`: no package files match $($fodInfo.Name) in $LPSearchRoot"
                    Write-Log "WARN FoD $label`: no packages match $($fodInfo.Name)" "WARN"
                }
                foreach ($cabFile in $cabFiles) {
                    try {
                        Add-WindowsPackage -PackagePath $cabFile.FullName -Path $mountDir -ScratchDirectory $scratchDir | Out-Null
                        Write-OK "$label installed: $($cabFile.Name)"
                        Write-Log "FoD Package OK: $label ($($cabFile.Name))"
                    }
                    catch {
                        $err = $_.Exception.Message
                        if ($err -match "0x800f081e") {
                            Write-Info "$($cabFile.Name) not applicable - skipping"
                            Write-Log "FoD $($cabFile.Name) skipped - not applicable (0x800f081e)" "INFO"
                        }
                        else {
                            Write-Warn "$($cabFile.Name) failed: $err"
                            Write-Log "WARN FoD $($cabFile.Name): $err" "WARN"
                        }
                    }
                }
            }
            else {
                # Capability-based FoD (PowerShell-ISE, Notepad, VBSCRIPT, WinOcr,
                # DeveloperMode, SnippingTool, NetFX3, and any raw capability name).
                try {
                    Add-WindowsCapability -Name $capName -Path $mountDir -Source $LPSearchRoot -ScratchDirectory $scratchDir | Out-Null
                    Write-OK "$label enabled"
                    Write-Log "FoD OK: $label ($capName)"
                }
                catch {
                    $err = $_.Exception.Message
                    if ($err -match "0x800f081e") {
                        Write-Info "$label already present - skipping"
                        Write-Log "FoD $label skipped - already present (0x800f081e)" "INFO"
                    }
                    elseif ($err -match "0x800f0805") {
                        Write-Warn "$label unknown on this image - skipping"
                        Write-Log "WARN FoD $label`: capability not found ($capName)" "WARN"
                    }
                    else {
                        Write-Warn "$label failed: $err"
                        Write-Log "WARN FoD $label`: $err" "WARN"
                    }
                }
            }
        }
    }

    # Step 13: Full LCU pass 2 — checkpoint copied alongside to restore baseline
    if ($lcuFile) {
        Write-Section "install.wim - Step 13: Full LCU (pass 2, after LP/FoD)"
        $lcuTempDir2 = Join-Path $workRoot "LCU_temp2"
        New-Item $lcuTempDir2 -ItemType Directory -Force | Out-Null
        foreach ($f in $lcuAllFiles) { Copy-Item $f.FullName $lcuTempDir2 }
        $lcuTempTarget2 = Join-Path $lcuTempDir2 $lcuFile.Name

        Write-Host "  >> LCU: $($lcuFile.Name)" -ForegroundColor White
        if ($checkpointFile) { Write-Host "  >> Checkpoint (auto-applied): $($checkpointFile.Name)" -ForegroundColor DarkGray }
        Write-Info "     Applying full LCU - this takes ~25 minutes..."
        $dismResult = & dism.exe /Image:$mountDir /Add-Package /PackagePath:$lcuTempTarget2 /ScratchDir:$scratchDir 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Full LCU installed (pass 2)"; Write-Log "LCU pass 2 OK: $($lcuFile.Name)"
        }
        elseif ($LASTEXITCODE -eq -2146498530) {
            Write-Warn "LCU pass 2 not applicable (0x800f081e) - skipping"
            Write-Log "WARN 0x800f081e LCU pass 2" "WARN"
        }
        else {
            $errMsg = ($dismResult | Where-Object { $_ -match "Error" }) -join " "
            Remove-Item $lcuTempDir2 -Recurse -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -eq -2146498504) {
                Write-Fail "LCU pass 2 failed with 0x800F0838 (CBS_E_IMAGE_UNSERVICEABLE)."
                Write-Fail "This means the checkpoint (KB5043080) is missing or invalidated."
                Write-Fail "Make sure the checkpoint .msu is present in: $resolvedUpdatePath"
            }
            throw "LCU pass 2 failed (exit $LASTEXITCODE): $errMsg"
        }
        Remove-Item $lcuTempDir2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Step 14: Cleanup (/StartComponentCleanup only — no /ResetBase on main OS)
    Write-Section "install.wim - Step 14: Component store cleanup"
    Write-Info "Running /StartComponentCleanup (no /ResetBase per Microsoft docs)..."
    if ($DebugBuild) {
        $cleanupResult = & dism.exe /Image:$mountDir /Cleanup-Image /StartComponentCleanup /ScratchDir:$scratchDir 2>&1
        $cleanupResult | ForEach-Object { Write-Host "    $_" -ForegroundColor Magenta; Write-Log "[DEBUG] $_" }
    }
    else {
        $cleanupResult = & dism.exe /Image:$mountDir /Cleanup-Image /StartComponentCleanup /ScratchDir:$scratchDir 2>&1
    }
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Component cleanup complete"; Write-Log "Component cleanup OK"
    }
    elseif ($LASTEXITCODE -eq -2146498554) {
        Write-Warn "Cleanup: pending operations (0x800F0806) - image must boot to complete. Non-fatal, continuing."
        Write-Log "WARN: Component cleanup 0x800F0806 (pending ops)" "WARN"
    }
    else {
        Write-Warn "Component cleanup returned exit code $LASTEXITCODE (non-fatal, continuing)"
        Write-Log "WARN: Component cleanup exit $LASTEXITCODE" "WARN"
    }

    # Step 15: .NET CU
    if ($dotNetFiles -and $dotNetFiles.Count -gt 0) {
        Write-Section "install.wim - Step 15: .NET CU"
        foreach ($upd in $dotNetFiles) {
            Write-Host "  >> .NET: $($upd.Name)" -ForegroundColor White
            try {
                Add-WindowsPackage -PackagePath $upd.FullName -Path $mountDir -IgnoreCheck -ScratchDirectory $scratchDir | Out-Null
                Write-OK "Installed"; Write-Log ".NET OK: $($upd.Name)"
            }
            catch {
                $err = $_.Exception.Message
                if ($err -match "0x800f081e") {
                    Write-Warn "Not applicable (0x800f081e) - skipping"
                    Write-Log "WARN 0x800f081e .NET" "WARN"
                }
                else {
                    Write-Warn "Failed: $err"; Write-Log "ERROR .NET: $err" "ERROR"
                }
            }
        }
    }

    # Appx removal
    if (-not $SkipAppxRemoval) {
        Write-Section "Removing Appx packages"
        $installed = @(Get-AppxProvisionedPackage -Path $mountDir)
        $removed = 0
        $handled = New-Object 'System.Collections.Generic.HashSet[string]'

        foreach ($appx in $AppxToRemove) {
            $how = 'exact'
            $pkgs = @($installed | Where-Object { $_.DisplayName -eq $appx })
            if ($pkgs.Count -eq 0) {
                $how = 'substring'
                $pkgs = @($installed | Where-Object { $_.DisplayName -like "*$appx*" })
            }
            if ($pkgs.Count -eq 0) {
                Write-Info "Appx not present in image (skipped): $appx"
                Write-Log "Appx not present (skipped): $appx"
                continue
            }
            if ($pkgs.Count -gt 1) {
                $names = ($pkgs | ForEach-Object { $_.DisplayName }) -join '; '
                Write-Warn "Appx '$appx' matched $($pkgs.Count) packages ($how) - skipping ambiguous match"
                Write-Log "WARN Ambiguous Appx '$appx' ($how): $names" "WARN"
                continue
            }
            $pkg = $pkgs[0]
            if ($handled.Contains($pkg.DisplayName)) {
                Write-Info "Already removed by earlier entry: $($pkg.DisplayName)"
                continue
            }
            try {
                Remove-AppxProvisionedPackage -Path $mountDir -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                [void]$handled.Add($pkg.DisplayName)
                Write-OK "Removed: $($pkg.DisplayName)"
                Write-Log "Removed Appx: $($pkg.DisplayName) [$($pkg.PackageName)]"
                $removed++
            }
            catch {
                Write-Warn "Failed to remove $($pkg.DisplayName): $($_.Exception.Message)"
                Write-Log "WARN Remove-Appx failed $($pkg.DisplayName): $($_.Exception.Message)" "WARN"
            }
        }

        Write-OK "Appx removal: $removed package(s) removed"
        Write-Log "Appx removal summary: $removed removed"
    }

    # Defender apply
    if ($script:DefenderKit) {
        Write-Section "Applying Defender update kit"
        $ok = Install-DefenderKitToImage -Kit $script:DefenderKit -MountPath $mountDir
        $script:DefenderStatus = if ($ok) {
            "Applied (package $($script:DefenderKit.PackageVersion))"
        }
        else {
            "Not applied - install failed (rolled back)"
        }
    }

    # Save & unmount
    Write-Section "Saving WIM"
    Dismount-WindowsImage -Path $mountDir -Save
    Write-OK "WIM saved"; Write-Log "WIM saved"

    # Export & compress
    Write-Section "Exporting and compressing"
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    Write-Info "Exporting to: $OutputPath (this takes ~10-15 min)..."
    Export-WindowsImage -SourceImagePath $workWim -SourceIndex 1 `
        -DestinationImagePath $OutputPath -CompressionType Max -CheckIntegrity
    $sizeGB = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1GB, 2)
    Write-OK "Exported: $OutputPath ($sizeGB GB)"
    Write-Log "Exported: $OutputPath ($sizeGB GB)"

}
catch {
    Write-Host ""
    Write-Fail "Servicing failed: $($_.Exception.Message)"
    Write-Log "ERROR: $($_.Exception.Message)" "ERROR"
    try { Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null } catch {}
    exit 1
}

# ── Cleanup & final summary ─────────────────────────────────────────────────
try {
    if (Test-Path -LiteralPath $mountDir) {
        try { Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}
catch {}
Remove-Item $workRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Section "DONE"
Write-Host ""
Write-Host "  Output       : $OutputPath" -ForegroundColor Cyan
Write-Host "  Size         : $sizeGB GB" -ForegroundColor Cyan
Write-Host "  Edition      : $($chosenImage.ImageName)" -ForegroundColor Cyan
Write-Host "  Languages    : $(if ($ResolvedLocales.Count) { $ResolvedLocales -join ', ' } else { 'en (none injected)' })" -ForegroundColor Cyan
if ($FoDList) { Write-Host "  Features     : $FoDList" -ForegroundColor Cyan }
Write-Host "  Defender     : $script:DefenderStatus" -ForegroundColor Cyan
Write-Host "  Log          : $logFile" -ForegroundColor Cyan
Write-Host ""
Write-Log "=== Build completed OK ==="

if ($Unattended) { exit 0 }
if (Confirm-Continue "Open output folder?") {
    Start-Process explorer.exe "/select,`"$OutputPath`""
}
exit 0