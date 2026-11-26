# WimWizard (home-user fork)

Personal fork of [WimWizard](https://github.com/TacII/WimWizard) by Mathias Haas,
retargeted for home lab / single-machine Windows 11 image servicing rather than
enterprise fleet management. The enterprise-only pieces (SCCM/MECM, ARM64,
SafeOS/WinRE patching, GUI integration) are removed, and the workflow switched
from ISO mounting to plain folders containing `install.wim`/`install.esd` plus
an extracted `LanguagesAndOptionalFeatures` directory.

Inspired by [WIM Witch](https://msendpointmgr.com/wim-witch/) by Donna Ryan.
Original license: **GNU GPL v3.0** (inherited).

---

## What this fork changes vs upstream

| Aspect | Upstream (5.8.1) | This fork (7.0.5) |
| --- | --- | --- |
| Input | Windows ISO + LP ISO files | Extracted folders: `install.wim`/`install.esd` + `LanguagesAndOptionalFeatures\` |
| GUI | `WimWizard-GUI.ps1` (Windows Forms) | None — CLI only, driven by parameters + `help.txt` |
| Scope | Enterprise (SCCM, fleet, x64+ARM64) | Home / single-machine (x64 only) |
| Patch mode | `-PatchExistingWim` parameter | Place WIM as `install.wim` + `-SkipLanguagePacks -SkipAppxRemoval -SkipDefenderUpdate` |
| FoD catalog | Corporate (`NetFx3`, `RsatAD`, …) | Home (`PowerShell-ISE`, `SnippingTool`, `VBSCRIPT`, `WinOcr`, `DeveloperMode`, `Ethernet`, `Wifi`, `Notepad`) + raw capability names |
| Output name | Version from source ISO | Post-servicing version (read from exported WIM after LCU) |
| LP validation | None | `Test-LPSourceComplete` pre-flight — catches `0x80070002` before mount |
| Checkpoint KB5043080 | Required for WinRE + install.wim | Required only for install.wim (post-LP/FoD baseline restoration) |

## What this fork removes

| Removed | Reason |
| --- | --- |
| `-SCCMImport` and all `-SCCM*` parameters | No SCCM in scope |
| `-ARM64`, `-X64`, ARM64 filters, ARM64 ISOs | x64 only |
| SafeOS Dynamic Update download/apply | WinRE not patched |
| WinRE (`winre.wim`) mount / patch / commit | WinRE updates handled online at first boot |
| `-SkipInboxAppLanguageFix` and winget RunOnce fix | `winget --source msstore` reinstall failed in practice |
| ISO mounting (`Mount-DiskImage`, `Dismount-AllISOs`) | Folder-based workflow |
| `-PatchExistingWim` | Replaced by Skip-flag combination |
| GUI hooks (`WimWizard-GUI.ps1` parameter hand-off) | CLI only |

## Features (current)

- **Language packs** — main LP cab + `Language.*` FoDs via `Add-WindowsCapability`
- **Features on Demand** — catalog of home-user FoDs + raw capability names
- **Driver injection** — recursive INF scan or curated XML list, per-driver try/catch
- **Appx removal** — built-in default list (26 packages) or custom XML, exact-match preferred
- **Offline Defender update** — KB4568292 platform/engine/definitions, cached, signed-cab validated
- **Automatic update download** — LCU + **checkpoint KB5043080** + .NET CU via MSCatalogLTS;
  hash-preserving filenames (DISM signature validation)
- **Two-pass LCU** — SSU (pass 1) → LP/FoD → full LCU (pass 2). Checkpoint is copied alongside LCU
  in both passes so DISM restores the baseline after LP/FoD invalidation
- **Component store cleanup** — `/StartComponentCleanup` (no `/ResetBase` on main OS)
- **LP repository pre-flight** — required metadata cabs + ≥ 43 locale-specific cabs per language
- **Post-servicing rename** — auto-generated output filename gets the build number from
  `Get-WindowsImage .Version` after export (e.g. `26100.1742` → `26100.9974`)
- **x64 only**, Windows 11 24H2 / 25H2 / 26H2

## Requirements

- **Windows PowerShell 5.1+** or **PowerShell 7.x**
- **Administrator rights** — DISM mount/commit require elevation
- **Windows 11 source WIM/ESD** — `install.wim` or `install.esd`, Enterprise/Pro/Education, x64, 24H2 or later
- **LanguagesAndOptionalFeatures folder** — extracted from the matching LP ISO, metadata + per-locale cabs intact
- **Internet access** for auto-download, or `-UpdatePath` pointing to pre-downloaded `.msu`/`.cab`
- **MSCatalogLTS** PowerShell module (installed from PSGallery automatically if missing)

> **Defender Realtime Scanning:** add the output and work folders to the Defender
> exclusion list, otherwise DISM LCU-patching will most likely fail.

## Files

| File | Description |
| --- | --- |
| `WimWizard.ps1` | Main servicing script |
| `help.txt` | Companion file — text shown by `-Help` / `/?` |
| `CHANGELOG.md` | Full version history |
| `README.md` | This file |
| `WimWizard-AppxList.xml` | Optional custom Appx removal list (`-AppxListPath`) |
| `WimWizard-DriverList.xml` | Optional curated driver INF list (`-DriverListPath`) |

Default folder layout (created on demand):
<ScriptRoot>
├── WimEsd\ # install.wim / install.esd
├── LanguagesAndOptionalFeatures\ # LP + FoD cabs + metadata
│ └── metadata
├── Updates\ # cached updates (auto-created)
│ └── DefenderKit
└── Output\ # finished WIM + logs (auto-created)

## Getting started

1. Download the **Windows 11** and **Language Pack** ISOs from the
   [Microsoft 365 Admin Center](https://admin.microsoft.com/adminportal/home#/subscriptions/vlnew/downloadsandkeys).

2. **Extract** both ISOs:
Windows ISO → <ScriptRoot>\WimEsd\ (sources\install.wim → install.wim)
LP ISO → <ScriptRoot>\LanguagesAndOptionalFeatures
(preserve the metadata\ subfolder and every .cab file)

3. Launch `WimWizard.ps1` **as Administrator**.

4. Interactive mode prompts for language, output path, work folder, and (if
needed) the LP folder. Unattended mode takes everything via CLI.

## The LanguagesAndOptionalFeatures folder

This folder is **not optional** for localized builds, and its contents must be
preserved. Removing locale-specific `.cab` files that DISM expects at install
time causes `0x80070002` on the main LP install — DISM resolves satellite
packages per-locale, not just for the locale being installed.

**Root — required metadata:**
- `FoDMetadata_Client.cab`
- `Microsoft-Windows-FodMetadataServicing-Desktop-Metadata-Package.cab`
- `Microsoft-Windows-FodMetadataServicing-Desktop-CompDB-Package.cab`

**`metadata\` — required:**
- `DesktopTargetCompDB_Neutral.xml.cab`
- `DesktopTargetCompDB_FOD_Neutral.xml.cab`
- `DesktopTargetCompDB_FOD_Metadata_Neutral.xml.cab`
- `DesktopTargetCompDB_Conditions.xml.cab`

**Per language in `-Languages` (43 cabs minimum each):**
- `Microsoft-Windows-Client-Language-Pack_x64_<lc>.cab`
- `Microsoft-Windows-LanguageFeatures-Basic-<lc>-Package~*.cab`
- `Microsoft-Windows-LanguageFeatures-{OCR,Handwriting,TextToSpeech,Speech}-<lc>-Package~*.cab`
(whichever exist in the ISO)
- ~38 additional `~<locale>~` FoD satellite cabs (PowerShell-ISE, Notepad,
WinOcr, WMIC, HyperV VM platform, etc.)
- `metadata\DesktopTargetCompDBForISO_<locale>.xml.cab`
- `metadata\DesktopTargetCompDBForISO_FOD_<locale>.xml.cab`

**Locales already in the source image** (typically `en-US`) do **not** need
cabs here — DISM resolves them against installed components.

The `Test-LPSourceComplete` pre-flight in Step 2 checks the layout and warns
(with per-locale cab counts in green / yellow / red) before mounting.

## Language packs

Any 2-letter code from the supported list works:
ar bg cs da de dk el en es et fi fr gb gr he hr hu il it ja jp ko kr lt lv
mx nl no pl pt ro ru se sk sl sr sv th tr tw hk ua uk us vn zh cn ca eu gl id vi

- `-Unattended` without `-Languages` → English-only build (no LP injection).
- Interactive mode prompts with default `ru`.
- Unrecognized codes fail immediately with the supported list.

Supported languages beyond `ru` work with the same mechanism — just include
the per-locale cabs for that language in `LanguagesAndOptionalFeatures` and
pass the code in `-Languages`.

## Features on Demand

`-FoDList` accepts comma-separated short keys or raw DISM capability names:

| Short key | Capability / package | Method |
| --- | --- | --- |
| `PowerShell-ISE` | `Microsoft.Windows.PowerShell.ISE~~~~0.0.1.0` | Add-WindowsCapability |
| `SnippingTool` | `Microsoft.Windows.SnippingTool~~~~0.0.1.0` | Add-WindowsCapability |
| `VBSCRIPT` | `VBSCRIPT~~~~` | Add-WindowsCapability |
| `WinOcr` | `Microsoft.Windows.WinOcr~~~~0.0.1.0` | Add-WindowsCapability |
| `DeveloperMode` | `Tools.DeveloperMode.Core~~~~0.0.1.0` | Add-WindowsCapability |
| `Notepad` | `Microsoft.Windows.Notepad~~~~0.0.1.0` | Add-WindowsCapability |
| `Ethernet` | `Microsoft-Windows-Ethernet-Client-*-FOD-Package-*.cab` | Add-WindowsPackage |
| `Wifi` | `Microsoft-Windows-Wifi-Client-*-FOD-Package-*.cab` | Add-WindowsPackage |

Any other value is treated as a DISM capability name:
- Contains `~` → used verbatim (e.g. `Microsoft.Windows.Foo~~~~0.0.1.0`)
- No `~` → `~~~~` appended (e.g. `NetFX3` → `NetFX3~~~~`)

The `.cab` wildcard packages are installed individually per matching file
(e.g. both Intel and Realtek Wi-Fi drivers, if present in the folder).

## Update-only mode (monthly patching)

To apply only the latest LCU + checkpoint + .NET CU to an existing serviced WIM:

1. Place the WIM as `install.wim` in `-WimEsdPath`, **or** point `-WimFilePath`
   directly at the file.
2. Run with three Skip flags to disable LP/FoD/Appx/Defender phases:
.\WimWizard.ps1 -WimFilePath "D:\Custom\my-image.wim" -WorkPath "W:\work" -UpdatePath "C:\Updates"
-SkipLanguagePacks -SkipAppxRemoval -SkipDefenderUpdate -Unattended

The output filename gets the post-servicing build number, e.g.
`Win11_24H2_26100.1742_ru_20261126.wim` → `Win11_24H2_26100.9974_ru_20261126.wim`.
User-supplied output filenames (`-OutputPath` with `.wim` extension) are **never**
renamed.

## Standalone usage examples
Interactive build
.\WimWizard.ps1

Unattended Russian build
.\WimWizard.ps1 -Languages "ru" -Unattended

Unattended Russian build with FoDs
.\WimWizard.ps1 -Languages "ru" -FoDList "PowerShell-ISE,Wifi" -Unattended

Full build with explicit paths
.\WimWizard.ps1 -Languages "ru" -WimEsdPath "D:\WimEsd"
-LanguagesAndOptionalFeaturesPath "D:\LanguagesAndOptionalFeatures" -OutputPath "W:\out" -WorkPath "W:\work"
-Unattended

With driver injection
.\WimWizard.ps1 -Languages "ru" -DriverPath "\dfs\Drivers\Laptop" -Unattended

Offline build with pre-downloaded updates
.\WimWizard.ps1 -Languages "ru" -UpdatePath "C:\Updates" -Unattended

Update-only build
.\WimWizard.ps1 -WimFilePath "D:\Custom\my-image.wim" `
-SkipLanguagePacks -SkipAppxRemoval -SkipDefenderUpdate -Unattended

Show help (reads help.txt)
.\WimWizard.ps1 -Help

First-time update download is 10–20 min (LCU alone is 500–800 MB). Already-cached
KBs in `Updates\` are reused by KB number and hash.

## Parameters

| Parameter | Description |
| --- | --- |
| `-WimEsdPath` | Folder containing `install.wim`/`install.esd`. Default: `<ScriptRoot>\WimEsd` |
| `-WimFilePath` | Explicit path to a `.wim`/`.esd` — overrides folder search |
| `-LanguagesAndOptionalFeaturesPath` | LP/FoD cab folder. Default: `<ScriptRoot>\LanguagesAndOptionalFeatures`. Auto-detects `<WimEsdPath>\LanguagesAndOptionalFeatures` |
| `-Languages` | Comma-separated 2-letter codes (`ru`, `de,fr`, …). Interactive prompt if omitted |
| `-OutputPath` | Output WIM (folder = auto-name, or full path with `.wim`) |
| `-WorkPath` | Work folder for mount + scratch. Default: `<outputDir>\WIMServicing_Work` |
| `-UpdatePath` | Folder with pre-downloaded `.msu`/`.cab` files. Empty = auto-download |
| `-AppxListPath` | XML with custom Appx removal list |
| `-WimIndex` | WIM index. `0` = auto-detect Enterprise |
| `-FoDList` | Comma-separated FoDs (see catalog above) |
| `-DriverPath` | Folder to recurse for `.inf` packages to inject |
| `-DriverListPath` | XML of pre-selected driver INF paths (overrides `-DriverPath`) |
| `-SkipUpdates` | Skip LCU / checkpoint / .NET CU |
| `-SkipLanguagePacks` | Skip language pack and `Language.*` FoD injection |
| `-SkipAppxRemoval` | Keep all provisioned Appx packages |
| `-SkipDefenderUpdate` | Skip the offline Defender update |
| `-Unattended` | No interactive prompts |
| `-DebugBuild` | Extra DISM diagnostics (full stdout to screen and log) |
| `-Help` | Show help (also `/?`) |

## Offline Defender update

The script downloads Microsoft's `defender-update-kit-amd64.zip` (KB4568292)
and copies the current platform, engine, and security intelligence into the
image, so freshly deployed systems don't run inbox Defender binaries until
their first online update.

- The zip is cached in `Updates\DefenderKit\` and reused on subsequent runs.
  Delete `defender-update-kit-amd64.zip` to force a fresh download.
- The kit's cab must carry a **valid Authenticode signature from Microsoft
  Corporation**, and the cab's `package-defender.xml` arch must match the
  image arch (x64).
- A drift-detection hash of Microsoft's `DefenderUpdateWinImage.ps1` (the
  unsigned body) is compared against a known baseline; a mismatch produces a
  warning rather than a failure.
- All Defender failures are **non-fatal**: the build continues without the
  update, and the DONE summary reports the status.

## Versions

| Component | Version |
| --- | --- |
| `WimWizard.ps1` | **7.0.5** |
| `help.txt` | 7.0.5 |
| Windows 11 target | **x64**, 24H2 / 25H2 / 26H2 |
| PowerShell | 5.1+ or 7.x |
| DISM | Windows 11 / Server 2022 or later |

## Changelog

The full version history, including the fork lineage from upstream 5.8.1 →
7.0.5, is in [CHANGELOG.md](CHANGELOG.md). Highlights of the fork:

- **7.0.5** — output WIM renamed to post-servicing version, `Write-Log` no
  longer fails when called before the main try block
- **7.0.4** — `Write-Log` moved to top (no-op until log file set); removed
  unused variables
- **7.0.3** — interactive prompts for `LanguagesAndOptionalFeaturesPath`;
  `-OutputPath` / `-WorkPath` / `-WimFilePath` honored without re-prompt
- **7.0.2** — fallback search for any `.wim`/`.esd`; version-aware rename
- **7.0.1** — `Test-LPSourceComplete` pre-flight (metadata + ≥ 43 cabs per locale)
- **7.0.0** — removed `-PatchExistingWim`, SCCM, ARM64, SafeOS/WinRE, GUI hooks,
  Inbox App Language Fix; switched from ISO mount to folder-based workflow

## License

Licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE)
for the full text.

The original WimWizard project is © Mathias Haas / TacII, also GPLv3. This fork
inherits the same license and redistributes under identical terms.

## Credits

- **Original project:** [TacII/WimWizard](https://github.com/TacII/WimWizard) by Mathias Haas
- **Inspiration:** [WIM Witch](https://msendpointmgr.com/wim-witch/) by Donna Ryan
- **Update catalog module:** [MSCatalogLTS](https://www.powershellgallery.com/packages/MSCatalogLTS) (community)

Changes specific to this fork are documented in [CHANGELOG.md](CHANGELOG.md).