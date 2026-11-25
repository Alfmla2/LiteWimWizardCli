#Requires -RunAsAdministrator

$params = @{
    Languages  = "ru"
    WimEsdPath = "W:\sources"
	LanguagesAndOptionalFeaturesPath = "E:\Sources\LanguagesAndOptionalFeatures"
    UpdatePath = "E:\Updates"
    OutputPath = "W:\out"
}

& "$PSScriptRoot\WimWizard.ps1" @params
