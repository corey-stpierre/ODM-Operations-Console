[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-UiInitialStateCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "UI INITIAL-STATE TEST ASSERTION FAILED: $Message"
    }
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

    if ($matches.Count -ne 1) {
        throw "Expected one production definition for '$FunctionName'; found $($matches.Count)."
    }

    . ([scriptblock]::Create([string]$matches[0].Extent.Text))
}

if ($env:OS -ne 'Windows_NT') {
    throw 'The UI initial-state test requires Windows.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'The UI initial-state test requires a 64-bit PowerShell host.'
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'The UI initial-state test requires STA. Run powershell.exe with -STA.'
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
    'Set-ComboItems',
    'Set-GridItems',
    'ConvertTo-OverviewCountText',
    'Format-OverviewRefreshedAt',
    'Show-OverviewSnapshot',
    'Clear-OverviewSnapshot',
    'Assert-UiSelectionCardinalityContract',
    'Update-UiEnablement',
    'Reset-WorkspaceUi'
)) {
    Import-ProductionFunction -Ast $uiAst -FunctionName $functionName
}

$reader = $null
$script:Window = $null
try {
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -ErrorAction Stop
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $script:Window = [Windows.Markup.XamlReader]::Load($reader)
    Assert-UiInitialStateCondition -Condition ($null -ne $script:Window) -Message 'XamlReader returned no Window object.'

    $script:Ui = @{}
    $nameMatches = [regex]::Matches((Get-Content -LiteralPath $xamlPath -Raw), 'x:Name="([A-Za-z_][A-Za-z0-9_]*)"')
    foreach ($match in $nameMatches) {
        $name = [string]$match.Groups[1].Value
        $control = $script:Window.FindName($name)
        if ($null -ne $control) { $script:Ui[$name] = $control }
    }

    $script:State = [ordered]@{
        Connected        = $false
        WorkloadSelected = $false
        Busy             = $false
        TaskItems        = @()
        CollectionItems  = @()
        TemplateItems    = @()
        ModuleStatusKnown = $true
        ModuleInstalled = $true
        ModuleUpdateAvailable = $false
        ModuleCanInstall = $true
        OverviewSnapshot = $null
        OverviewStatusText = 'No workspace refresh has run.'
    }

    # Exercise the exact zero/one/many contract used by task and collection
    # selection handlers before invoking the production initial-state routine.
    Assert-UiSelectionCardinalityContract

    $taskGrid = Get-UiControl 'TaskGrid'
    $collectionGrid = Get-UiControl 'CollectionGrid'
    Assert-UiInitialStateCondition -Condition ((Get-UiSafeCount -Value $taskGrid.SelectedItems) -eq 0) -Message 'TaskGrid must start with zero selected rows.'
    Assert-UiInitialStateCondition -Condition ((Get-UiSafeCount -Value $collectionGrid.SelectedItems) -eq 0) -Message 'CollectionGrid must start with zero selected rows.'

    # This call reproduces the production startup path used while the UI phase is
    # 'Applying initial UI state'. It clears every production grid/combo and then
    # invokes Update-UiEnablement with zero selected task and collection rows.
    # Any unsafe direct .Count access against an empty function result terminates
    # here under StrictMode.
    Reset-WorkspaceUi

    foreach ($overviewControl in @('OverviewObjectCount','OverviewTaskCount','OverviewCollectionCount','OverviewRunningCount','OverviewFailedCount')) {
        Assert-UiInitialStateCondition -Condition ([string]::Equals([string](Get-UiControl $overviewControl).Text, '—', [StringComparison]::Ordinal)) -Message "$overviewControl must show an em dash before the first workspace refresh."
    }
    Assert-UiInitialStateCondition -Condition ([string]::Equals([string](Get-UiControl 'OverviewRefreshedText').Text, 'No workspace refresh has run.', [StringComparison]::Ordinal)) -Message 'The initial overview refresh status is incorrect.'

    Assert-UiInitialStateCondition -Condition ([bool](Get-UiControl 'ConnectButton').IsEnabled) -Message 'Connect must be enabled while disconnected.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'DisconnectButton').IsEnabled) -Message 'Disconnect must be disabled while disconnected.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'LoadTaskMembersButton').IsEnabled) -Message 'Task-member loading must be disabled without a selected workload and task.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'StartSelectedTasksButton').IsEnabled) -Message 'Task start must be disabled with zero selected tasks.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'StopSelectedTasksButton').IsEnabled) -Message 'Task stop must be disabled with zero selected tasks.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'DeleteSelectedTasksButton').IsEnabled) -Message 'Task deletion must be disabled with zero selected tasks.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'DeleteSelectedCollectionsButton').IsEnabled) -Message 'Collection deletion must be disabled with zero selected collections.'
    Assert-UiInitialStateCondition -Condition ([bool](Get-UiControl 'CheckOdmApiVersionButton').IsEnabled) -Message 'Module version checking must be available while disconnected.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'InstallOdmApiButton').IsEnabled) -Message 'Install must be disabled when OdmApi is already installed.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'UpdateOdmApiButton').IsEnabled) -Message 'Update must be disabled when no update is recommended.'

    $script:State.ModuleInstalled = $false
    $script:State.ModuleCanInstall = $true
    Update-UiEnablement
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'ConnectButton').IsEnabled) -Message 'Connect must be disabled when OdmApi is known to be missing.'
    Assert-UiInitialStateCondition -Condition ([bool](Get-UiControl 'InstallOdmApiButton').IsEnabled) -Message 'Install must be enabled when OdmApi is missing and an installer is available.'
    $script:State.ModuleInstalled = $true
    $script:State.ModuleCanInstall = $true

    $script:State.Connected = $true
    $script:State.WorkloadSelected = $false
    Update-UiEnablement
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'ConnectButton').IsEnabled) -Message 'Connect must be disabled after connection.'
    Assert-UiInitialStateCondition -Condition ([bool](Get-UiControl 'DisconnectButton').IsEnabled) -Message 'Disconnect must be enabled after connection.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'UserSearchButton').IsEnabled) -Message 'Workload operations must remain disabled before a workload is opened.'

    $script:State.WorkloadSelected = $true
    Update-UiEnablement
    Assert-UiInitialStateCondition -Condition ([bool](Get-UiControl 'UserSearchButton').IsEnabled) -Message 'Workload operations must be enabled after a workload is opened.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'DeleteSelectedTasksButton').IsEnabled) -Message 'Task deletion must remain disabled with zero selected tasks.'
    Assert-UiInitialStateCondition -Condition (-not [bool](Get-UiControl 'DeleteSelectedCollectionsButton').IsEnabled) -Message 'Collection deletion must remain disabled with zero selected collections.'

    Write-Output 'UI INITIAL-STATE TESTS: PASS'
}
finally {
    if ($null -ne $reader) { try { $reader.Close() } catch { } }
    if ($null -ne $script:Window) { try { $script:Window.Close() } catch { } }
}
