#Requires -RunAsAdministrator

$params = @{
    WimEsdPath = "E:\ltsc"
	LanguagesAndOptionalFeaturesPath = "E:\Sources\LanguagesAndOptionalFeatures"
	Languages  = "ru"
	FoDList = "PowerShell-ISE,SnippingTool,VBSCRIPT,WinOcr,DeveloperMode,Ethernet,Wifi,Notepad"
    UpdatePath = "E:\Updates"
    OutputPath = "W:\out"
}

& "$PSScriptRoot\WimWizard.ps1" @params
