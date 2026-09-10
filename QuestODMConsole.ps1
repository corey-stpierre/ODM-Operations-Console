[CmdletBinding()]
param(
    [switch]$NoRelaunch,

    [AllowEmptyString()]
    [string]$DataRoot
)

Set-StrictMode -Version 2.0

function Test-QOdmRuntimePowerShellSyntax {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ApplicationRoot
    )

    $runtimeFiles = @(
        Get-Item -LiteralPath (Join-Path -Path $ApplicationRoot -ChildPath 'QuestODMConsole.ps1') -ErrorAction Stop
        Get-Item -LiteralPath (Join-Path -Path $ApplicationRoot -ChildPath 'QuestODMConsole.UI.ps1') -ErrorAction Stop
        Get-ChildItem -LiteralPath (Join-Path -Path $ApplicationRoot -ChildPath 'Engine') -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') }
        Get-ChildItem -LiteralPath (Join-Path -Path $ApplicationRoot -ChildPath 'Shared') -File -ErrorAction Stop |
            Where-Object { $_.Extension -eq '.ps1' }
    ) | Sort-Object -Property FullName -Unique

    $syntaxIssues = [System.Collections.Generic.List[string]]::new()
    foreach ($runtimeFile in @($runtimeFiles)) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $runtimeFile.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )

        foreach ($parseError in @($parseErrors)) {
            $extent = $parseError.Extent
            $syntaxIssues.Add(('{0}:{1}:{2}: {3}' -f
                    $runtimeFile.FullName,
                    $extent.StartLineNumber,
                    $extent.StartColumnNumber,
                    $parseError.Message))
        }
    }

    if ($syntaxIssues.Count -gt 0) {
        throw ("Runtime PowerShell syntax validation failed before the UI was loaded.`r`n`r`n" +
            ($syntaxIssues -join "`r`n"))
    }
}

function Test-QOdmProductionXaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$XamlPath
    )

    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
        throw "The production XAML file was not found: $XamlPath"
    }

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = $null
    try {
        $reader = [System.Xml.XmlReader]::Create($XamlPath, $settings)
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        if ($null -eq $document.DocumentElement) {
            throw "The production XAML file does not contain a document element: $XamlPath"
        }
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
}

$ErrorActionPreference = 'Stop'

$script:BootstrapLogPath = $null
$script:BootstrapPhase = 'Bootstrap initialization'
$env:QUESTODMCONSOLE_UI_PHASE = ''

function Test-BootstrapDirectoryWritable {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        if (-not (Get-Item -LiteralPath $Path -ErrorAction Stop).PSIsContainer) { return $false }
        $probe = Join-Path $Path ('.write-test-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
        $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        [IO.File]::WriteAllText($probe, 'test', $encoding)
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Resolve-BootstrapDataRoot {
    param([AllowEmptyString()][string]$RequestedPath)

    $explicit = -not [string]::IsNullOrWhiteSpace($RequestedPath)
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($explicit) {
        $candidates.Add($RequestedPath) | Out-Null
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace([string]$env:QUESTODMCONSOLE_DATA_ROOT)) {
            $candidates.Add([string]$env:QUESTODMCONSOLE_DATA_ROOT) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
            $candidates.Add((Join-Path $env:LOCALAPPDATA 'QuestODMConsole')) | Out-Null
        }
        try {
            $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
                $candidates.Add((Join-Path $localAppData 'QuestODMConsole')) | Out-Null
            }
        }
        catch { }
        if (-not [string]::IsNullOrWhiteSpace([string]$env:TEMP)) {
            $candidates.Add((Join-Path $env:TEMP 'QuestODMConsole')) | Out-Null
        }
        try {
            $temporaryPath = [IO.Path]::GetTempPath()
            if (-not [string]::IsNullOrWhiteSpace($temporaryPath)) {
                $candidates.Add((Join-Path $temporaryPath 'QuestODMConsole')) | Out-Null
            }
        }
        catch { }
    }

    foreach ($candidate in ($candidates.ToArray() | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try { $fullPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$candidate)) }
        catch { continue }
        if (Test-BootstrapDirectoryWritable -Path $fullPath) { return $fullPath }
    }

    if ($explicit) { throw "The requested data root is unavailable or not writable: $RequestedPath" }
    throw 'A writable per-user data directory could not be created. Set QUESTODMCONSOLE_DATA_ROOT to a writable local folder.'
}

function Write-BootstrapFailure {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $invocation = $ErrorRecord.InvocationInfo
    $scriptName = if ($null -ne $invocation) { [string]$invocation.ScriptName } else { '' }
    $lineNumber = if ($null -ne $invocation) { [int]$invocation.ScriptLineNumber } else { 0 }
    $columnNumber = if ($null -ne $invocation) { [int]$invocation.OffsetInLine } else { 0 }
    $positionMessage = if ($null -ne $invocation) { [string]$invocation.PositionMessage } else { '' }
    $uiPhase = [string]$env:QUESTODMCONSOLE_UI_PHASE
    $effectivePhase = if (-not [string]::IsNullOrWhiteSpace($uiPhase)) { $uiPhase } else { [string]$script:BootstrapPhase }
    $location = if (-not [string]::IsNullOrWhiteSpace($scriptName) -and $lineNumber -gt 0) {
        '{0}, line {1}, column {2}' -f $scriptName, $lineNumber, $columnNumber
    }
    elseif ($lineNumber -gt 0) {
        'line {0}, column {1}' -f $lineNumber, $columnNumber
    }
    else {
        'Location unavailable'
    }

    $details = @(
        ('Timestamp: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('Bootstrap phase: {0}' -f $script:BootstrapPhase),
        ('UI phase: {0}' -f $uiPhase),
        ('Effective phase: {0}' -f $effectivePhase),
        ('Message: {0}' -f $ErrorRecord.Exception.Message),
        ('FullyQualifiedErrorId: {0}' -f $ErrorRecord.FullyQualifiedErrorId),
        ('CategoryInfo: {0}' -f $ErrorRecord.CategoryInfo),
        ('Location: {0}' -f $location),
        ('Position: {0}' -f $positionMessage),
        ('Exception: {0}' -f $ErrorRecord.Exception.ToString()),
        ('Script stack: {0}' -f $ErrorRecord.ScriptStackTrace),
        ('PowerShell: {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition),
        ('Process bitness: {0}' -f $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' }))
    ) -join "`r`n"

    if (-not [string]::IsNullOrWhiteSpace($script:BootstrapLogPath)) {
        try {
            Add-Content -LiteralPath $script:BootstrapLogPath -Value ("`r`n$details`r`n") -Encoding UTF8 -ErrorAction Stop
        }
        catch { }
    }

    $message = "Quest ODM Operations Console could not start.`r`n`r`n$($ErrorRecord.Exception.Message)"
    if (-not [string]::IsNullOrWhiteSpace($effectivePhase)) {
        $message += "`r`n`r`nPhase: $effectivePhase"
    }
    if ($location -ne 'Location unavailable') {
        $message += "`r`nLocation: $location"
    }
    if (-not [string]::IsNullOrWhiteSpace($script:BootstrapLogPath)) {
        $message += "`r`n`r`nBootstrap log:`r`n$script:BootstrapLogPath"
    }

    $shown = $false
    if ($env:OS -eq 'Windows_NT') {
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
            [void][Windows.MessageBox]::Show($message, 'Quest ODM Console startup error', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error)
            $shown = $true
        }
        catch { }
        if (-not $shown) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                [void][System.Windows.Forms.MessageBox]::Show($message, 'Quest ODM Console startup error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                $shown = $true
            }
            catch { }
        }
    }

    if (-not $shown) { [Console]::Error.WriteLine($message) }
}

try {
    $script:BootstrapPhase = 'Resolving the writable application data root'
    $resolvedDataRoot = Resolve-BootstrapDataRoot -RequestedPath $DataRoot
    $env:QUESTODMCONSOLE_DATA_ROOT = $resolvedDataRoot
    $bootstrapLogDirectory = Join-Path $resolvedDataRoot 'Logs'
    if (-not (Test-BootstrapDirectoryWritable -Path $bootstrapLogDirectory)) {
        throw "The bootstrap log directory is unavailable or not writable: $bootstrapLogDirectory"
    }
    $script:BootstrapLogPath = Join-Path $bootstrapLogDirectory 'QuestODMConsole-bootstrap.log'

    $script:BootstrapPhase = 'Validating the Windows and process architecture requirements'
    if ($env:OS -ne 'Windows_NT') {
        throw 'Quest ODM Operations Console requires 64-bit Windows because it uses WPF and the Quest OdmApi module.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Quest ODM Operations Console requires a 64-bit Windows operating system.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Quest ODM Operations Console requires a 64-bit PowerShell process. Use one of the included launchers.'
    }

    $script:BootstrapPhase = 'Resolving application files'
    $scriptPath = $MyInvocation.MyCommand.Path
    $root = Split-Path -Parent $scriptPath
    $uiScript = Join-Path $root 'QuestODMConsole.UI.ps1'
    if (-not (Test-Path -LiteralPath $uiScript)) { throw "UI script not found: $uiScript" }

    $script:BootstrapPhase = 'Validating the PowerShell host version'
    $isWindowsPowerShell51 = ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSEdition -eq 'Desktop')
    $isPowerShell7Plus = ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSEdition -eq 'Core')
    if (-not ($isWindowsPowerShell51 -or $isPowerShell7Plus)) {
        throw 'Use 64-bit Windows PowerShell 5.1 or 64-bit PowerShell 7.'
    }

    $script:BootstrapPhase = 'Validating the STA execution mode'
    $isSta = ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA)
    if (-not $isSta -and -not $NoRelaunch) {
        $powerShellExecutable = if ($isPowerShell7Plus) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
        if (-not (Test-Path -LiteralPath $powerShellExecutable)) {
            throw "PowerShell executable was not found at $powerShellExecutable"
        }

        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-STA',
            '-File', ('"{0}"' -f $scriptPath.Replace('"', '')),
            '-NoRelaunch',
            '-DataRoot', ('"{0}"' -f $resolvedDataRoot.Replace('"', ''))
        )
        $script:BootstrapPhase = 'Relaunching PowerShell in STA mode'
        $process = Start-Process -FilePath $powerShellExecutable -ArgumentList $arguments -PassThru -Wait -ErrorAction Stop
        exit $process.ExitCode
    }
    if (-not $isSta) {
        throw 'The console requires an STA PowerShell thread. Launch it with -STA or use an included launcher.'
    }

    $script:BootstrapPhase = 'Validating runtime PowerShell syntax'

    Test-QOdmRuntimePowerShellSyntax -ApplicationRoot $PSScriptRoot
    $script:BootstrapPhase = 'Validating production XAML'
    Test-QOdmProductionXaml -XamlPath (Join-Path -Path $PSScriptRoot -ChildPath 'Resources\QuestODMConsole.xaml')



    $script:BootstrapPhase = 'Loading the WPF UI controller'
    $env:QUESTODMCONSOLE_UI_PHASE = ''
    & $uiScript -DataRoot $resolvedDataRoot
}
catch {
    Write-BootstrapFailure -ErrorRecord $_
    exit 1
}
