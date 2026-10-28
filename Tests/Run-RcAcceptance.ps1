[CmdletBinding()]param([string]$ModuleManifest)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run the RC acceptance suite in an x64 STA PowerShell host.'}
if(-not $ModuleManifest){$module=Get-Module -ListAvailable OdmApi|Sort-Object Version -Descending|Select-Object -First 1;if(-not $module){throw 'Pass the installed OdmApi module manifest. No login is needed.'};$ModuleManifest=$module.Path}
$hostExecutable=(Get-Process -Id $PID).Path
& $hostExecutable -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Run-V1Acceptance.ps1')
if($LASTEXITCODE -ne 0){throw 'Core acceptance failed.'}
foreach($name in @('Run-OperationsCenterTests.ps1','Run-ManagementTests.ps1','Run-ActiveDirectoryTests.ps1')){
    & $hostExecutable -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name) -ModuleManifest $ModuleManifest
    if($LASTEXITCODE -ne 0){throw "$name failed."}
}
Write-Output 'RC ACCEPTANCE: PASS'
