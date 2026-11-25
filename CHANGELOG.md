7.0.2
	Interactive-mode fixes:
	- Prompts for -LanguagesAndOptionalFeaturesPath when the folder
	  isn't at the default location and LP/FoD injection is requested.
	- No longer re-prompts for -OutputPath when the caller passed it
	  explicitly (folder-typed paths still get the auto-generated name).
	- New -WorkPath parameter; also no longer prompts when -Unattended.
	- New -WimFilePath parameter for explicit .wim/.esd selection;
	  folder search now falls back to any *.wim/*.esd (not only
	  install.wim/install.esd), with a warning when ambiguous.
	- Output filename now reflects the post-servicing version:
	  after export, Get-WindowsImage .Version is read and the build
	  token in the auto-generated name is updated (e.g. 26100.1742
	 -> 26100.9974 after LCU). User-supplied filenames untouched.
	- Removed system-drive free-space check from Step 0; the only
	  free-space checks are Test-OutputDiskSpace calls for the actual
	  output and work folders, where WIM mount/scratch actually live.
7.0.1
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

7.0.0
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

6.3.0
    - Added Resolve-WimEsdFolder; removed ISO mounting entirely.
      -SourceFolder renamed to -WimEsdPath; added
      -LanguagesAndOptionalFeaturesPath.

6.2.x
    - Restored checkpoint KB5043080; LCU pruning preserves it;
      $lcuFile selector excludes it. Fixed -SkipUpdates guard.

6.1.0
    - Removed SCCM/MECM, ARM64, SafeOS, WinRE, Inbox App Language Fix.