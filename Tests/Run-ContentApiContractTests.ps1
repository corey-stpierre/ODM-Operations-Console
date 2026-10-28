[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ModuleManifest)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$api=Import-Module $ModuleManifest -Global -Force -PassThru | Where-Object {$_.Name -eq 'OdmApi'}
$engine=Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Engine\QuestODMConsole.Engine.psm1') -Force -PassThru
$catalog=& $engine {Get-QOdmContentTaskCatalog}
foreach($spec in $catalog) {
    $command=Get-Command $spec.Command -ErrorAction Stop
    $required=@('Name','ScheduledStartTime')+@($spec.Defaults.Keys)
    if($spec.TemplateType){$required+='TemplateId'}
    if($spec.Workload -eq 'PowerBI'){$required+=@('Workspaces','DefaultAdminUser')}
    foreach($name in $required){if(-not $command.Parameters.ContainsKey($name)){throw "$($spec.Command) missing $name"}}
    foreach($name in $spec.Defaults.Keys){
        $value=[Management.Automation.LanguagePrimitives]::ConvertTo($spec.Defaults[$name],$command.Parameters[$name].ParameterType)
        foreach($attribute in $command.Parameters[$name].Attributes){
            if($attribute -is [Management.Automation.ValidateSetAttribute] -and $value -notin $attribute.ValidValues){throw "Invalid value for $($spec.Command) / $name"}
        }
    }
}
foreach($name in @('TypeOfTeam','TypeOfPowerBi','FilterObject','All')){if(-not (Get-Command Get-OdmObject).Parameters.ContainsKey($name)){throw "Get-OdmObject missing $name"}}
Write-Output "CONTENT API CONTRACT TESTS: PASS ($($api.Version); $($catalog.Count) task types; no service calls)"
