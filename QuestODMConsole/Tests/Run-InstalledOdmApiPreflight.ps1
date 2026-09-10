[CmdletBinding()]
param(
    [Alias('JsonPath')]
    [string]$JsonOutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$result = [ordered]@{
    Status                 = 'NOT_RUN'
    Installed              = $false
    Loaded                 = $false
    ModuleName             = $null
    ModuleVersion          = $null
    ModulePath             = $null
    ManifestPath           = $null
    ConnectCommandOwner    = $null
    PrivateFunctionPresent = $false
    RuntimeProbeStatus     = 'NOT_RUN'
    RuntimeProbeDetails    = $null
    Error                  = $null
    ExceptionType          = $null
    FullyQualifiedErrorId  = $null
    ScriptStackTrace       = $null
    TestedAt               = Get-Date
    PowerShellVersion      = $PSVersionTable.PSVersion.ToString()
    PowerShellEdition      = $PSVersionTable.PSEdition
    Is64BitProcess         = [Environment]::Is64BitProcess
}

function Write-PreflightJson {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Result)
    if ([string]::IsNullOrWhiteSpace($JsonOutputPath)) { return }
    $parent = Split-Path -Parent $JsonOutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    [pscustomobject]$Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonOutputPath -Encoding UTF8
}

try {
    $available = @(Get-Module -ListAvailable -Name 'OdmApi' -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
    if ($available.Count -eq 0) {
        throw 'The OdmApi module is not installed in a path visible to this PowerShell host.'
    }
    $result.Installed = $true

    $candidate = $available[0]
    $manifestPath = Join-Path -Path $candidate.ModuleBase -ChildPath 'OdmApi.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $manifestPath = [string]$candidate.Path
    }
    if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "OdmApi was discovered, but its manifest or module path could not be resolved. Module base: $($candidate.ModuleBase)"
    }
    $result.ManifestPath = $manifestPath

    $loadedCandidates = @(Get-Module -Name 'OdmApi' -All -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
    $module = if ($loadedCandidates.Count -gt 0) { $loadedCandidates[0] } else { $null }
    if ($null -eq $module) {
        $imported = @(Import-Module -Name $manifestPath -Global -PassThru -ErrorAction Stop)
        $moduleCandidates = @($imported | Where-Object { $_.Name -eq 'OdmApi' } | Sort-Object Version -Descending)
        $module = if ($moduleCandidates.Count -gt 0) { $moduleCandidates[0] } else { $null }
    }
    if ($null -eq $module) {
        $loadedCandidates = @(Get-Module -Name 'OdmApi' -All -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
        $module = if ($loadedCandidates.Count -gt 0) { $loadedCandidates[0] } else { $null }
    }
    if ($null -eq $module) { throw 'OdmApi import completed without loading a module object.' }

    $result.Loaded = $true
    $result.ModuleName = [string]$module.Name
    $result.ModuleVersion = [string]$module.Version
    $result.ModulePath = [string]$module.Path

    $connectCommand = Get-Command -Name 'Connect-OdmService' -ErrorAction Stop
    $owner = if ($null -ne $connectCommand.Module) { [string]$connectCommand.Module.Name } else { $null }
    $result.ConnectCommandOwner = $owner
    if (-not [string]::Equals($owner, 'OdmApi', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Connect-OdmService resolved to module '$owner' instead of 'OdmApi'."
    }
    $module = $connectCommand.Module
    $result.ModuleName = [string]$module.Name
    $result.ModuleVersion = [string]$module.Version
    $result.ModulePath = [string]$module.Path

    $expectedName = [string]$module.Name
    $expectedVersion = [string]$module.Version
    $probeOutput = @(& $module {
        param([string]$ExpectedName, [string]$ExpectedVersion)

        $privateCommand = Get-Command -Name 'Set-ModuleVersion' -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $privateCommand -or -not [string]::Equals([string]$privateCommand.ModuleName, $ExpectedName, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Status='SKIPPED_PRIVATE_FUNCTION_NOT_PRESENT'; PrivateFunctionPresent=$false; Passed=$true
                Details='The installed module does not contain the private Set-ModuleVersion function. Import and command ownership checks passed; Connect-OdmService remains the authoritative runtime test.'
            }
        }

        try {
            & $privateCommand
            $resolvedName = [string](Get-Variable -Name 'ModuleName' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
            $resolvedVersion = [string](Get-Variable -Name 'ModuleVersion' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
            if ([string]::IsNullOrWhiteSpace($resolvedName)) { throw 'Set-ModuleVersion did not set the module-scoped ModuleName value.' }
            if ([string]::IsNullOrWhiteSpace($resolvedVersion)) { throw 'Set-ModuleVersion did not set the module-scoped ModuleVersion value.' }
            if (-not [string]::Equals($resolvedName, $ExpectedName, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Set-ModuleVersion resolved module '$resolvedName' instead of '$ExpectedName'."
            }
            return [pscustomobject]@{
                Status='PASS'; PrivateFunctionPresent=$true; Passed=$true
                Details="Set-ModuleVersion completed successfully for $resolvedName $resolvedVersion."
            }
        }
        catch {
            return [pscustomobject]@{
                Status='FAILED'; PrivateFunctionPresent=$true; Passed=$false
                Details=('The private Set-ModuleVersion function failed: {0}' -f $_.Exception.Message)
            }
        }
    } $expectedName $expectedVersion)

    if ($probeOutput.Count -eq 0) { throw 'The installed-module runtime probe returned no result.' }
    $probe = $probeOutput[$probeOutput.Count - 1]
    $result.PrivateFunctionPresent = [bool]$probe.PrivateFunctionPresent
    $result.RuntimeProbeStatus = [string]$probe.Status
    $result.RuntimeProbeDetails = [string]$probe.Details
    if (-not [bool]$probe.Passed) { throw [string]$probe.Details }

    $result.Status = 'PASS'
    Write-PreflightJson -Result $result
    Write-Output 'INSTALLED ODMAPI PREFLIGHT: PASS'
    Write-Output ([pscustomobject]$result)
}
catch {
    $result.Status = 'FAIL'
    $result.Error = $_.Exception.Message
    $result.ExceptionType = $_.Exception.GetType().FullName
    $result.FullyQualifiedErrorId = $_.FullyQualifiedErrorId
    $result.ScriptStackTrace = $_.ScriptStackTrace
    Write-PreflightJson -Result $result
    Write-Output 'INSTALLED ODMAPI PREFLIGHT: FAIL'
    Write-Output ([pscustomobject]$result)
    throw ('INSTALLED ODMAPI PREFLIGHT FAILED: {0}' -f $_.Exception.Message)
}
