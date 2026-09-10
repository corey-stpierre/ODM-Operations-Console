[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-OverviewPersistenceCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "OVERVIEW PERSISTENCE TEST ASSERTION FAILED: $Message" }
}

function Import-ProductionFunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)][string]$FunctionName
    )

    $matches = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            [string]::Equals([string]$node.Name, $FunctionName, [StringComparison]::OrdinalIgnoreCase)
    }, $true))
    if ($matches.Count -ne 1) { throw "Expected one production definition for '$FunctionName'; found $($matches.Count)." }
    . ([scriptblock]::Create([string]$matches[0].Extent.Text))
}

if ($env:OS -ne 'Windows_NT') { throw 'The overview persistence test requires Windows.' }
if (-not [Environment]::Is64BitProcess) { throw 'The overview persistence test requires a 64-bit PowerShell host.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'The overview persistence test requires STA. Run powershell.exe with -STA.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $testsRoot
$uiPath = Join-Path $appRoot 'QuestODMConsole.UI.ps1'
$xamlPath = Join-Path $appRoot 'Resources\QuestODMConsole.xaml'

$tokens = $null
$parseErrors = $null
$uiAst = [System.Management.Automation.Language.Parser]::ParseFile($uiPath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) {
    throw ('The production UI controller does not parse: ' + ((@($parseErrors | ForEach-Object { $_.Message })) -join '; '))
}

foreach ($functionName in @(
    'ConvertTo-UiObjectArray',
    'Get-UiControl',
    'Get-SelectedGridItems',
    'Get-SelectedGridItem',
    'Get-ObjectPropertyValue',
    'Test-ObjectPropertyTrue',
    'Get-UiSafeCount',
    'Update-UiEnablement',
    'Set-UiBusy',
    'ConvertTo-OverviewCountText',
    'Format-OverviewRefreshedAt',
    'Show-OverviewSnapshot',
    'Clear-OverviewSnapshot',
    'Set-OverviewSnapshot',
    'Set-OverviewRefreshPending',
    'Set-OverviewRefreshFailed'
)) {
    Import-ProductionFunction -Ast $uiAst -FunctionName $functionName
}

$reader = $null
$script:Window = $null
$script:SessionLogPath = $null
try {
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -ErrorAction Stop
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $script:Window = [Windows.Markup.XamlReader]::Load($reader)
    Assert-OverviewPersistenceCondition -Condition ($null -ne $script:Window) -Message 'XamlReader returned no Window object.'

    $script:Ui = @{}
    $nameMatches = [regex]::Matches((Get-Content -LiteralPath $xamlPath -Raw), 'x:Name="([A-Za-z_][A-Za-z0-9_]*)"')
    foreach ($match in $nameMatches) {
        $name = [string]$match.Groups[1].Value
        $control = $script:Window.FindName($name)
        if ($null -ne $control) { $script:Ui[$name] = $control }
    }

    $script:State = [ordered]@{
        Connected = $true
        WorkloadSelected = $true
        Busy = $false
        ModuleStatusKnown = $true
        ModuleInstalled = $true
        ModuleUpdateAvailable = $false
        ModuleCanInstall = $true
        OverviewSnapshot = $null
        OverviewStatusText = 'No workspace refresh has run.'
    }

    $script:SessionLogPath = Join-Path ([IO.Path]::GetTempPath()) ('QuestODMConsole-overview-test-' + [Guid]::NewGuid().ToString('N') + '.log')
    function Write-UiLog { param([string]$Message,[string]$Level='INFO') }

    $firstRefreshedAt = [DateTime]'2026-08-11T09:30:00'
    $firstDashboard = [pscustomobject]@{
        State = [pscustomobject]@{ WorkloadId = 'accounts-workload-1' }
        ObjectCount = 12500
        TaskCount = 84
        CollectionCount = 21
        RunningTasks = 7
        FailedTasks = 2
        RefreshedAt = $firstRefreshedAt
    }

    Set-OverviewSnapshot -Dashboard $firstDashboard
    $expectedFirst = @{
        OverviewObjectCount = '12500'
        OverviewTaskCount = '84'
        OverviewCollectionCount = '21'
        OverviewRunningCount = '7'
        OverviewFailedCount = '2'
    }
    foreach ($entry in $expectedFirst.GetEnumerator()) {
        Assert-OverviewPersistenceCondition -Condition ([string]::Equals([string](Get-UiControl $entry.Key).Text, [string]$entry.Value, [StringComparison]::Ordinal)) -Message "$($entry.Key) did not display the first snapshot value."
    }
    Assert-OverviewPersistenceCondition -Condition (([string](Get-UiControl 'OverviewRefreshedText').Text) -match '2026-08-11 09:30:00') -Message 'The first refresh timestamp was not displayed.'

    # The metric values must remain readable even though the selected TabItem header uses white text.
    $metricForeground = [string](Get-UiControl 'OverviewObjectCount').Foreground
    Assert-OverviewPersistenceCondition -Condition (-not [string]::Equals($metricForeground, '#FFFFFFFF', [StringComparison]::OrdinalIgnoreCase) -and -not [string]::Equals($metricForeground, 'White', [StringComparison]::OrdinalIgnoreCase)) -Message 'The overview metric value inherited a white foreground.'

    Set-OverviewRefreshPending
    foreach ($entry in $expectedFirst.GetEnumerator()) {
        Assert-OverviewPersistenceCondition -Condition ([string]::Equals([string](Get-UiControl $entry.Key).Text, [string]$entry.Value, [StringComparison]::Ordinal)) -Message "$($entry.Key) changed while a refresh was pending."
    }
    Assert-OverviewPersistenceCondition -Condition (([string](Get-UiControl 'OverviewRefreshedText').Text) -match 'showing the last completed snapshot') -Message 'The pending-refresh status does not explain that previous values remain visible.'

    # Reproduce the production busy-state transition that disables and re-enables MainTabControl.
    Set-UiBusy -Busy $true -Status 'Refreshing workspace…'
    Set-UiBusy -Busy $false -Status 'Ready.'
    foreach ($entry in $expectedFirst.GetEnumerator()) {
        Assert-OverviewPersistenceCondition -Condition ([string]::Equals([string](Get-UiControl $entry.Key).Text, [string]$entry.Value, [StringComparison]::Ordinal)) -Message "$($entry.Key) disappeared across the busy-state transition."
    }

    Set-OverviewRefreshFailed -Message 'Simulated read failure'
    foreach ($entry in $expectedFirst.GetEnumerator()) {
        Assert-OverviewPersistenceCondition -Condition ([string]::Equals([string](Get-UiControl $entry.Key).Text, [string]$entry.Value, [StringComparison]::Ordinal)) -Message "$($entry.Key) changed after a failed refresh."
    }
    Assert-OverviewPersistenceCondition -Condition (([string](Get-UiControl 'OverviewRefreshedText').Text) -match 'remains displayed') -Message 'A failed refresh did not retain an explanatory status.'

    $secondDashboard = [pscustomobject]@{
        State = [pscustomobject]@{ WorkloadId = 'accounts-workload-1' }
        ObjectCount = 13001
        TaskCount = 90
        CollectionCount = 22
        RunningTasks = 4
        FailedTasks = 1
        RefreshedAt = [DateTime]'2026-08-11T10:00:00'
    }
    Set-OverviewSnapshot -Dashboard $secondDashboard
    Assert-OverviewPersistenceCondition -Condition ([string]::Equals([string](Get-UiControl 'OverviewObjectCount').Text, '13001', [StringComparison]::Ordinal)) -Message 'The next successful refresh did not replace the previous object count.'
    Assert-OverviewPersistenceCondition -Condition ([string]::Equals([string](Get-UiControl 'OverviewTaskCount').Text, '90', [StringComparison]::Ordinal)) -Message 'The next successful refresh did not replace the previous task count.'
    Assert-OverviewPersistenceCondition -Condition (([string](Get-UiControl 'OverviewRefreshedText').Text) -match '2026-08-11 10:00:00') -Message 'The next successful refresh did not replace the timestamp.'

    Clear-OverviewSnapshot -StatusText 'No workspace refresh has run for the selected context.'
    foreach ($controlName in @('OverviewObjectCount','OverviewTaskCount','OverviewCollectionCount','OverviewRunningCount','OverviewFailedCount')) {
        Assert-OverviewPersistenceCondition -Condition ([string]::Equals([string](Get-UiControl $controlName).Text, '—', [StringComparison]::Ordinal)) -Message "$controlName was not cleared when the context was reset."
    }

    Write-Output 'OVERVIEW PERSISTENCE TESTS: PASS'
}
finally {
    if ($null -ne $reader) { try { $reader.Close() } catch { } }
    if ($null -ne $script:Window) { try { $script:Window.Close() } catch { } }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:SessionLogPath)) { Remove-Item -LiteralPath $script:SessionLogPath -Force -ErrorAction SilentlyContinue }
}
