[CmdletBinding()]
param(
    [switch]$NoRelaunch,

    [AllowEmptyString()]
    [string]$DataRoot = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-McuBootstrapSyntax {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UtilityRoot)

    $files = @(
        Get-Item -LiteralPath (Join-Path $UtilityRoot 'MappingCollisionUtility.ps1') -ErrorAction Stop
        Get-Item -LiteralPath (Join-Path $UtilityRoot 'MappingCollisionUtility.UI.ps1') -ErrorAction Stop
        Get-Item -LiteralPath (Join-Path $UtilityRoot 'Engine\MappingCollisionEngine.psm1') -ErrorAction Stop
        Get-ChildItem -LiteralPath (Join-Path $UtilityRoot 'Collectors') -Filter '*.ps1' -File -ErrorAction Stop
        Get-Item -LiteralPath (Join-Path (Split-Path -Parent $UtilityRoot) 'Shared\LogMaintenance.ps1') -ErrorAction Stop
    ) | Sort-Object FullName -Unique

    $issues = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
        foreach ($parseError in @($parseErrors)) {
            $issues.Add(('{0}:{1}:{2}: {3}' -f $file.FullName,$parseError.Extent.StartLineNumber,$parseError.Extent.StartColumnNumber,$parseError.Message)) | Out-Null
        }
    }
    if ($issues.Count -gt 0) {
        throw ("Mapping Collision Utility PowerShell syntax validation failed.`r`n`r`n" + ($issues.ToArray() -join "`r`n"))
    }
}

function Test-McuBootstrapXaml {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$XamlPath)

    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) { throw "Utility XAML was not found: $XamlPath" }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = $null
    try {
        $reader = [System.Xml.XmlReader]::Create($XamlPath,$settings)
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        if ($null -eq $document.DocumentElement) { throw "Utility XAML does not contain a document element: $XamlPath" }
    }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
}

function Resolve-McuBootstrapDataRoot {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$RequestedPath)

    $candidate = $RequestedPath
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $base = if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
            Join-Path $env:LOCALAPPDATA 'QuestODMConsole'
        }
        else {
            Join-Path ([IO.Path]::GetTempPath()) 'QuestODMConsole'
        }
        $candidate = Join-Path $base 'MappingCollisionUtility'
    }
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($candidate))
}

function Start-McuBootstrapRelaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$ResolvedDataRoot
    )

    $windowsDirectory = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($windowsDirectory)) { throw 'The Windows directory could not be resolved.' }
    $systemFolder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $hostPath = Join-Path $windowsDirectory "$systemFolder\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) { throw "Windows PowerShell was not found: $hostPath" }

    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy','Bypass',
        '-STA',
        '-File',('"{0}"' -f $ScriptPath.Replace('"','')),
        '-NoRelaunch',
        '-DataRoot',('"{0}"' -f $ResolvedDataRoot.Replace('"',''))
    )
    Start-Process -FilePath $hostPath -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $ScriptPath) -ErrorAction Stop | Out-Null
}

if ($env:OS -ne 'Windows_NT') { throw 'The Mapping Collision Utility requires Windows.' }

$utilityRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$xamlPath = Join-Path $utilityRoot 'Resources\MappingCollisionUtility.xaml'
$uiPath = Join-Path $utilityRoot 'MappingCollisionUtility.UI.ps1'
$resolvedDataRoot = Resolve-McuBootstrapDataRoot -RequestedPath $DataRoot

try {
    $requiresRelaunch = (-not [Environment]::Is64BitProcess) -or ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA)
    if ($requiresRelaunch) {
        if ($NoRelaunch) { throw 'A 64-bit STA Windows PowerShell host is required, and the automatic relaunch did not provide one.' }
        Start-McuBootstrapRelaunch -ScriptPath $MyInvocation.MyCommand.Path -ResolvedDataRoot $resolvedDataRoot
        return
    }

    Test-McuBootstrapSyntax -UtilityRoot $utilityRoot
    Test-McuBootstrapXaml -XamlPath $xamlPath
    & $uiPath -DataRoot $resolvedDataRoot
}
catch {
    $message = "Quest ODM Mapping Collision Utility could not start.`r`n`r`n$($_.Exception.Message)"
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [void][Windows.MessageBox]::Show($message,'Mapping Collision Utility startup error',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Error)
    }
    catch { Write-Error $message }
    throw
}
