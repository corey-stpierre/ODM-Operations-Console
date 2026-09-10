[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $testsRoot
$mockManifest = Join-Path $testsRoot 'Mocks\OdmApi\2.1.396\OdmApi.psd1'
$enginePath = Join-Path $appRoot 'Engine\QuestODMConsole.Engine.psm1'

function ConvertTo-BoundaryArray {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    $result = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $InputObject) { return ,$result.ToArray() }
    $value = $InputObject
    try {
        if ($InputObject -is [System.Management.Automation.PSObject] -and $null -ne $InputObject.BaseObject) {
            $value = $InputObject.BaseObject
        }
    }
    catch { $value = $InputObject }
    if ($value -is [string] -or $value -is [System.Collections.IDictionary]) {
        $result.Add($InputObject) | Out-Null
        return ,$result.ToArray()
    }
    if ($value -is [System.Collections.IEnumerable]) {
        foreach ($item in $value) { $result.Add($item) | Out-Null }
        return ,$result.ToArray()
    }
    $result.Add($InputObject) | Out-Null
    return ,$result.ToArray()
}

function Assert-BoundaryCondition {
    param([Parameter(Mandatory=$true)][bool]$Condition,[Parameter(Mandatory=$true)][string]$Message)
    if (-not $Condition) { throw "WORKER BOUNDARY ASSERTION FAILED: $Message" }
}

$runspace = $null
$initializer = $null
$operationPowerShell = $null
try {
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialSessionState)
    if ($null -eq $runspace) { throw 'RunspaceFactory returned no runspace.' }
    $runspace.ApartmentState = [Threading.ApartmentState]::STA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $initializer = [PowerShell]::Create()
    $initializer.Runspace = $runspace
    $initializationScript = @'
param($MockManifest,$EnginePath)
$ErrorActionPreference='Stop'
$imported = Import-Module -Name $MockManifest -Global -PassThru -ErrorAction Stop
$module = $imported | Where-Object { $_.Name -eq 'OdmApi' } | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $module) { $module = Get-Module -Name 'OdmApi' -All | Sort-Object Version -Descending | Select-Object -First 1 }
if ($null -eq $module) { throw 'Mock OdmApi did not load globally in the worker runspace.' }
$global:QuestODMConsoleOdmApiPreload = [pscustomobject]@{
    Status='LOADED';Installed=$true;Loaded=$true;Version=[string]$module.Version;Path=[string]$module.Path
    ManifestPath=$MockManifest;CommandOwner='OdmApi';Details='Worker-boundary regression preload.';Error=$null;PreloadedAt=Get-Date
}
Import-Module -Name $EnginePath -Force -ErrorAction Stop
Set-MockOrganizationMode -Mode NewObjectList
'@
    [void]$initializer.AddScript($initializationScript).AddArgument($mockManifest).AddArgument($enginePath)
    $null = $initializer.Invoke()
    $initErrors = ConvertTo-BoundaryArray -InputObject $initializer.Streams.Error
    Assert-BoundaryCondition -Condition (-not $initializer.HadErrors -and $initErrors.Count -eq 0) -Message ('Worker initialization failed: ' + (($initErrors | ForEach-Object { $_.ToString() }) -join '; '))

    $operationPowerShell = [PowerShell]::Create()
    $operationPowerShell.Runspace = $runspace
    [void]$operationPowerShell.AddCommand('Invoke-QOdmOperation').AddParameter('Operation','Connect').AddParameter('Parameters',@{Region='US'})
    $async = $operationPowerShell.BeginInvoke()
    if ($null -eq $async) { throw 'BeginInvoke returned no asynchronous handle.' }
    $rawOutput = $operationPowerShell.EndInvoke($async)
    $streamErrors = ConvertTo-BoundaryArray -InputObject $operationPowerShell.Streams.Error
    Assert-BoundaryCondition -Condition (-not $operationPowerShell.HadErrors -and $streamErrors.Count -eq 0) -Message ('Async Connect emitted errors: ' + (($streamErrors | ForEach-Object { $_.ToString() }) -join '; '))

    $output = ConvertTo-BoundaryArray -InputObject $rawOutput
    Assert-BoundaryCondition -Condition ($output.Count -gt 0) -Message 'Async Connect returned no pipeline result.'
    $result = $output[$output.Count - 1]
    Assert-BoundaryCondition -Condition ([bool]$result.Success) -Message ("Async Connect failed: $($result.Error)`r`n$($result.Details)")
    $organizations = ConvertTo-BoundaryArray -InputObject $result.Data.Organizations
    Assert-BoundaryCondition -Condition ($organizations.Count -eq 2) -Message "Expected two organizations across the worker boundary; received $($organizations.Count)."
    $attempts = ConvertTo-BoundaryArray -InputObject $result.Data.OrganizationDiscovery.Attempts
    $primary = ConvertTo-BoundaryArray -InputObject ($attempts | Where-Object { $_.Command -eq 'Get-OdmOrganizations' })
    Assert-BoundaryCondition -Condition ($primary.Count -eq 1 -and [bool]$primary[0].Succeeded -and [int]$primary[0].ConvertedCount -eq 2) -Message 'The adversarial organization response was not converted across the async worker boundary.'

    Write-Output 'WORKER BOUNDARY TESTS: PASS'
}
finally {
    if ($null -ne $operationPowerShell) { try { $operationPowerShell.Stop() } catch { }; try { $operationPowerShell.Dispose() } catch { } }
    if ($null -ne $initializer) { try { $initializer.Dispose() } catch { } }
    if ($null -ne $runspace) { try { $runspace.Close() } catch { }; try { $runspace.Dispose() } catch { } }
}
