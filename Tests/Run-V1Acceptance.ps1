[CmdletBinding()]
param(
    [switch]$SkipInstalledOdmApiPreflight
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'V1 acceptance requires Windows.' }
if (-not [Environment]::Is64BitProcess) { throw 'V1 acceptance requires a 64-bit PowerShell process.' }
if ([version]$PSVersionTable.PSVersion -lt [version]'5.1') { throw 'V1 acceptance requires PowerShell 5.1 or later.' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) { throw 'V1 acceptance requires STA. Start powershell.exe with -STA.' }

function Invoke-AcceptanceStage {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PassMarker,
        [hashtable]$Parameters = @{}
    )
    Write-Output "--- $Name ---"
    $output = @(& $Path @Parameters)
    $output | ForEach-Object { Write-Output $_ }
    if ($output -notcontains $PassMarker) { throw "$Name did not return '$PassMarker'." }
}

Invoke-AcceptanceStage -Name 'Native static, mock, WPF, and governance validation' `
    -Path (Join-Path $PSScriptRoot 'Run-StaticValidation.ps1') -PassMarker 'STATIC VALIDATION: PASS'

if (-not $SkipInstalledOdmApiPreflight) {
    Invoke-AcceptanceStage -Name 'Installed OdmApi preflight' `
        -Path (Join-Path $PSScriptRoot 'Run-InstalledOdmApiPreflight.ps1') -PassMarker 'INSTALLED ODMAPI PREFLIGHT: PASS'
}

Write-Output 'V1 ACCEPTANCE: PASS'
