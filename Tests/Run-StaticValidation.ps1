[CmdletBinding()]
param(
    [switch]$SkipMockEngineTests,
    [switch]$SkipWpfSmokeTest,
    [switch]$SkipGovernanceTests
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$isWindowsPlatform = ($env:OS -eq 'Windows_NT')
$failures = [System.Collections.Generic.List[string]]::new()
$checks = [System.Collections.Generic.List[string]]::new()

function Add-ValidationFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:failures.Add($Message) | Out-Null
}

function ConvertTo-ValidationArray {
    param([AllowNull()][object]$InputObject)
    $result = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $InputObject) { return ,$result.ToArray() }
    $value = $InputObject
    try { $value = [System.Management.Automation.PSObject]::Base($InputObject) } catch { }
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

function Invoke-ValidationTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Marker
    )
    try {
        $output = ConvertTo-ValidationArray -InputObject (& $Path)
        if ($output -notcontains $Marker) { Add-ValidationFailure "$Name did not return '$Marker'." }
        else { $script:checks.Add("$Name passed") | Out-Null }
    }
    catch { Add-ValidationFailure ("{0} failed: {1}" -f $Name,$_.Exception.Message) }
}

$required = @(
    'QuestODMConsole.ps1','QuestODMConsole.UI.ps1','VERSION.txt','README.md','RELEASE_NOTES.md','ROLLBACK.md','SUPPORT.md','NOTICE.md',
    'V1_RELEASE_VALIDATION.json','SIGNING_STATUS.txt','Config\BuildInfo.json','Config\OdmApiCompatibility.json','Engine\Governance.ps1',
    'Tools\Invoke-CodeSigning.ps1','Tools\Test-CodeSigning.ps1','Tools\New-ReleaseManifest.ps1','Shared\LogMaintenance.ps1',
    'Tests\Run-V1Acceptance.ps1','Tests\Run-V1GovernanceTests.ps1','Tests\Run-V1BrandingTests.ps1','Tests\Run-LogMaintenanceTests.ps1','Tests\Run-UiCallbackScopeTests.ps1','Resources\QuestODMConsole.xaml','Resources\QuestSoftwareLogo.png','Resources\BRANDING.md',
    'MappingCollisionUtility\MappingCollisionUtility.ps1','MappingCollisionUtility\MappingCollisionUtility.UI.ps1','MappingCollisionUtility\Start-MappingCollisionUtility.cmd','MappingCollisionUtility\README.md',
    'MappingCollisionUtility\Engine\MappingCollisionEngine.psm1','MappingCollisionUtility\Collectors\Export-SourceIdentityInventory.ps1','MappingCollisionUtility\Collectors\Export-TargetIdentityInventory.ps1',
    'MappingCollisionUtility\Resources\MappingCollisionUtility.xaml','MappingCollisionUtility\Samples\SourceInventory.Sample.csv','MappingCollisionUtility\Samples\TargetInventory.Sample.csv',
    'MappingCollisionUtility\Tests\Run-MappingCollisionTests.ps1','MappingCollisionUtility\Tests\Run-WpfSmokeTest.ps1','MappingCollisionUtility\Tests\StaticValidation.py'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) { Add-ValidationFailure "Missing required V1 file: $relative" }
}
$checks.Add("Required V1 files checked: $($required.Count)") | Out-Null

try {
    $version = (Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw -ErrorAction Stop).Trim()
    if ($version -ne '1.1.0-preview.6') { Add-ValidationFailure "VERSION.txt contains '$version' instead of 1.1.0-preview.6." }
    else { $checks.Add('Version marker is 1.1.0-preview.6') | Out-Null }
}
catch { Add-ValidationFailure ("Version check failed: {0}" -f $_.Exception.Message) }

# Native PowerShell parser gate over every shipped non-legacy source file.
$sourceFiles = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction Stop | Where-Object {
    $_.Extension -in @('.ps1','.psm1','.psd1') -and $_.FullName -notmatch '[\\/]LegacyScripts[\\/]'
}
foreach ($file in $sourceFiles) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors) | Out-Null
    foreach ($parseError in (ConvertTo-ValidationArray -InputObject $parseErrors)) {
        Add-ValidationFailure ("PowerShell parse error in {0} at line {1}, column {2}: {3}" -f $file.FullName,$parseError.Extent.StartLineNumber,$parseError.Extent.StartColumnNumber,$parseError.Message)
    }
}
$checks.Add("Native PowerShell parser files checked: $($sourceFiles.Count)") | Out-Null

# Production XAML parse and UI reference validation.
try {
    [xml]$xaml = Get-Content -LiteralPath (Join-Path $root 'Resources\QuestODMConsole.xaml') -Raw -ErrorAction Stop
    $namespace = New-Object System.Xml.XmlNamespaceManager($xaml.NameTable)
    $namespace.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
    $nodes = $xaml.SelectNodes('//*[@x:Name]',$namespace)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($node in $nodes) { $names.Add([string]$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')) | Out-Null }
    $duplicates = $names.ToArray() | Group-Object | Where-Object Count -gt 1
    if ($duplicates) { Add-ValidationFailure ('Duplicate XAML control names: ' + (($duplicates.Name | Sort-Object) -join ', ')) }
    $uiText = Get-Content -LiteralPath (Join-Path $root 'QuestODMConsole.UI.ps1') -Raw -ErrorAction Stop
    $matches = [regex]::Matches($uiText,'Get-UiControl\s+(?:-Name\s+)?[''"]([^''"]+)[''"]',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $references = $matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $missing = @($references | Where-Object { $names -notcontains $_ })
    if ($missing.Count -gt 0) { Add-ValidationFailure ('UI references missing XAML controls: ' + ($missing -join ', ')) }
    foreach ($requiredControl in @('SafeModeStatusText','TaskDetailsTextBox','TaskEventsGrid','RunReadinessButton','ReadinessGrid','CreateSupportBundleButton','OperationHistoryGrid','ProfileCombo','AboutTextBox','QuestLogoImage','LaunchMappingCollisionUtilityButton','OpenMappingCollisionUtilityFolderButton','MappingCollisionUtilityStatusText','TaskCsvActionCard','TaskCsvActionFooter','TaskCsvInputScrollViewer','CollectionCsvActionCard','CollectionCsvActionFooter','CollectionCsvInputScrollViewer','AddCsvUsersToTaskButton','RemoveCsvUsersFromTaskButton','AddCsvUsersToCollectionButton','RemoveCsvUsersFromCollectionButton','DarkModeCheckBox','LogRetentionDaysCombo','CleanOldLogsButton','ClearStoredLogsButton','LogRetentionStatusText')) {
        if ($names -notcontains $requiredControl) { Add-ValidationFailure "V1 XAML control missing: $requiredControl" }
    }
    foreach ($layoutName in @('Task','Collection')) {
        $cardName = "${layoutName}CsvActionCard"
        $footerName = "${layoutName}CsvActionFooter"
        $scrollName = "${layoutName}CsvInputScrollViewer"
        $card = $xaml.SelectSingleNode("//*[@x:Name='$cardName']",$namespace)
        $footer = $xaml.SelectSingleNode("//*[@x:Name='$footerName']",$namespace)
        $scroller = $xaml.SelectSingleNode("//*[@x:Name='$scrollName']",$namespace)
        if ($null -eq $card -or $null -eq $footer -or $null -eq $scroller) {
            Add-ValidationFailure "$layoutName CSV membership action layout containers are incomplete."
            continue
        }
        if ([string]$footer.GetAttribute('DockPanel.Dock') -ne 'Bottom') { Add-ValidationFailure "$layoutName CSV action footer is not bottom-docked." }
        if ([string]$scroller.GetAttribute('VerticalScrollBarVisibility') -ne 'Auto') { Add-ValidationFailure "$layoutName CSV input area is not vertically scrollable." }
        $expectedActionControls = if ($layoutName -eq 'Task') { @('TaskCsvExecuteCheckBox','AddCsvUsersToTaskButton','RemoveCsvUsersFromTaskButton') } else { @('CollectionCsvExecuteCheckBox','AddCsvUsersToCollectionButton','RemoveCsvUsersFromCollectionButton') }
        foreach ($actionControl in $expectedActionControls) {
            $contained = $footer.SelectSingleNode(".//*[@x:Name='$actionControl']",$namespace)
            if ($null -eq $contained) { Add-ValidationFailure "$actionControl is not contained in the pinned $layoutName CSV action footer." }
        }
    }
    foreach ($marker in @(
        'function Complete-UiCsvMembershipAction',
        "Complete-UiCsvMembershipAction -EntityType Task -GridName 'TaskMembersGrid'",
        "Complete-UiCsvMembershipAction -EntityType Collection -GridName 'CollectionMembersGrid'",
        "& `$taskCsvAction 'AddUsersToEntityFromCsv' 'Add'",
        "& `$taskCsvAction 'RemoveUsersFromEntityFromCsv' 'Remove'",
        "& `$collectionCsvAction 'AddUsersToEntityFromCsv' 'Add'",
        "& `$collectionCsvAction 'RemoveUsersFromEntityFromCsv' 'Remove'",
        'No API changes were submitted','CommandSucceededCount','VerifiedCount'
    )) {
        if ($uiText.IndexOf($marker,[StringComparison]::Ordinal) -lt 0) { Add-ValidationFailure "CSV membership action marker missing: $marker" }
    }
    foreach ($themeMarker in @(
        'function Get-UiThemePalette','function Set-UiThemeBrush','function Set-UiTheme',
        "Get-SettingValue -Name 'Theme' -Default 'Light'",'Theme                     = [string]$script:State.Theme',
        "Get-UiControl 'DarkModeCheckBox'","Set-UiTheme -Theme 'Dark'","Set-UiTheme -Theme 'Light'",
        'CloneCurrentValue','[System.Collections.IDictionary]$script:Window.Resources'
    )) {
        if ($uiText.IndexOf($themeMarker,[StringComparison]::Ordinal) -lt 0) { Add-ValidationFailure "Main-console theme marker missing: $themeMarker" }
    }
    $xamlText = Get-Content -LiteralPath (Join-Path $root 'Resources\QuestODMConsole.xaml') -Raw -ErrorAction Stop
    foreach ($xamlThemeMarker in @(
        'Background="{DynamicResource BackgroundBrush}" Foreground="{DynamicResource TextBrush}"',
        '<Setter Property="TextElement.Foreground" Value="{DynamicResource TextBrush}" />',
        'Text="Mapping collision utility" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource TextBrush}"',
        'x:Name="DarkModeCheckBox"','x:Name="LogRetentionDaysCombo"','x:Name="ClearStoredLogsButton"',
        'xmlns:po="http://schemas.microsoft.com/winfx/2006/xaml/presentation/options"','po:Freeze="False"'
    )) {
        if ($xamlText.IndexOf($xamlThemeMarker,[StringComparison]::Ordinal) -lt 0) { Add-ValidationFailure "Main-console theme XAML marker missing: $xamlThemeMarker" }
    }
    $themeBrushNodes = $xaml.SelectNodes("//*[local-name()='SolidColorBrush' and @x:Key]",$namespace)
    foreach ($themeBrushNode in $themeBrushNodes) {
        $freezeValue = [string]$themeBrushNode.GetAttribute('Freeze','http://schemas.microsoft.com/winfx/2006/xaml/presentation/options')
        if ($freezeValue -ne 'False') { Add-ValidationFailure ("Theme brush '{0}' is not explicitly unfrozen." -f $themeBrushNode.GetAttribute('Key','http://schemas.microsoft.com/winfx/2006/xaml')) }
    }
    if ($uiText -match '\$script:Window\.Resources\s*\[\s*\$Name\s*\]\s*=') { Add-ValidationFailure 'Unsafe direct ResourceDictionary indexer assignment remains in the main theme setter.' }
    if ($uiText.IndexOf('.GetNewClosure()',[StringComparison]::OrdinalIgnoreCase) -ge 0) { Add-ValidationFailure 'Production UI callbacks still use GetNewClosure and can lose script-scope helper resolution.' }
    foreach ($callbackMarker in @(
        '$script:State.BulkUiContext = [pscustomobject]@{',
        'Get-BulkResultRows -Data $data',
        '-OnSuccess $successCallback -OnFailure $failureCallback',
        '$script:State.ProfileLoadContext',
        '$script:State.OdmApiModuleActionContext',
        '$button.Tag = [pscustomobject]@{ Action = $action; ErrorText = $Text; Dialog = $dialog }',
        'The underlying operation was not rolled back. Verify the generated report and Quest state before retrying an executed write.'
    )) {
        if ($uiText.IndexOf($callbackMarker,[StringComparison]::Ordinal) -lt 0) { Add-ValidationFailure "UI callback-scope marker missing: $callbackMarker" }
    }
    foreach ($logMarker in @(
        'Shared\LogMaintenance.ps1','function Get-UiLogRetentionDays','function Set-UiLogMaintenanceStatus','function Invoke-UiLogMaintenanceFromUi',
        'Invoke-QOdmLogMaintenance -Application MainConsole',"Get-UiControl 'CleanOldLogsButton'","Get-UiControl 'ClearStoredLogsButton'",
        "Get-SettingValue -Name 'LogRetentionDays' -Default 30",'LogRetentionDays           = Get-UiLogRetentionDays'
    )) {
        if ($uiText.IndexOf($logMarker,[StringComparison]::Ordinal) -lt 0) { Add-ValidationFailure "Main-console log-maintenance marker missing: $logMarker" }
    }
    $logHelperText = Get-Content -LiteralPath (Join-Path $root 'Shared\LogMaintenance.ps1') -Raw -ErrorAction Stop
    foreach ($helperMarker in @('function Invoke-QOdmLogMaintenance','ClearHistorical','OperationHistory.jsonl','QuestODMConsole-bootstrap.log','CurrentSessionLogPath')) {
        if ($logHelperText.IndexOf($helperMarker,[StringComparison]::Ordinal) -lt 0) { Add-ValidationFailure "Shared log-maintenance marker missing: $helperMarker" }
    }
    $checks.Add("XAML/UI controls checked: $($names.Count) names, $($references.Count) references; CSV action footers pinned; theme resources wired") | Out-Null
}
catch { Add-ValidationFailure ("XAML validation failed: {0}" -f $_.Exception.Message) }

# V1 policy/settings JSON.
foreach ($jsonName in @('Config\BuildInfo.json','Config\OdmApiCompatibility.json','Config\QuestODMConsole.settings.json','V1_RELEASE_VALIDATION.json')) {
    try { $null = Get-Content -LiteralPath (Join-Path $root $jsonName) -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { Add-ValidationFailure ("Invalid JSON in {0}: {1}" -f $jsonName,$_.Exception.Message) }
}
$checks.Add('V1 JSON files parsed') | Out-Null
try {
    $defaultSettings = Get-Content -LiteralPath (Join-Path $root 'Config\QuestODMConsole.settings.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([string]$defaultSettings.Theme -notin @('Light','Dark')) { Add-ValidationFailure 'Default settings Theme must be Light or Dark.' }
    if ([int]$defaultSettings.LogRetentionDays -notin @(7,14,30,60,90,180)) { Add-ValidationFailure 'Default settings LogRetentionDays is not allowed.' }
}
catch { Add-ValidationFailure ("Default theme settings validation failed: {0}" -f $_.Exception.Message) }

# Exact prior parser regression and cardinality regressions.
Invoke-ValidationTest -Name 'Parser regression tests' -Path (Join-Path $PSScriptRoot 'Run-ParserRegressionTests.ps1') -Marker 'PARSER REGRESSION TESTS: PASS'
Invoke-ValidationTest -Name 'Collection normalization tests' -Path (Join-Path $PSScriptRoot 'Run-CollectionNormalizationTests.ps1') -Marker 'COLLECTION NORMALIZATION TESTS: PASS'
Invoke-ValidationTest -Name 'V1 branding tests' -Path (Join-Path $PSScriptRoot 'Run-V1BrandingTests.ps1') -Marker 'V1 BRANDING TESTS: PASS'
Invoke-ValidationTest -Name 'Log maintenance tests' -Path (Join-Path $root 'Tests\Run-LogMaintenanceTests.ps1') -Marker 'LOG MAINTENANCE TESTS: PASS'
Invoke-ValidationTest -Name 'UI callback scope tests' -Path (Join-Path $root 'Tests\Run-UiCallbackScopeTests.ps1') -Marker 'UI CALLBACK SCOPE TESTS: PASS'
Invoke-ValidationTest -Name 'Mapping Collision Utility engine tests' -Path (Join-Path $root 'MappingCollisionUtility\Tests\Run-MappingCollisionTests.ps1') -Marker 'MAPPING COLLISION TESTS: PASS'

if (-not $SkipMockEngineTests) {
    Invoke-ValidationTest -Name 'Mock engine tests' -Path (Join-Path $PSScriptRoot 'Run-MockEngineTests.ps1') -Marker 'MOCK ENGINE TESTS: PASS'
    Invoke-ValidationTest -Name 'Worker boundary tests' -Path (Join-Path $PSScriptRoot 'Run-WorkerBoundaryTests.ps1') -Marker 'WORKER BOUNDARY TESTS: PASS'
}

if (-not $SkipGovernanceTests) {
    if (-not $isWindowsPlatform) { Add-ValidationFailure 'V1 governance tests require Windows.' }
    else { Invoke-ValidationTest -Name 'V1 governance tests' -Path (Join-Path $PSScriptRoot 'Run-V1GovernanceTests.ps1') -Marker 'V1 GOVERNANCE TESTS: PASS' }
}

if (-not $SkipWpfSmokeTest) {
    if (-not $isWindowsPlatform) { Add-ValidationFailure 'WPF tests require Windows.' }
    else {
        Invoke-ValidationTest -Name 'WPF smoke test' -Path (Join-Path $PSScriptRoot 'Run-WpfSmokeTest.ps1') -Marker 'WPF SMOKE TEST: PASS'
        Invoke-ValidationTest -Name 'Mapping Collision Utility WPF smoke test' -Path (Join-Path $root 'MappingCollisionUtility\Tests\Run-WpfSmokeTest.ps1') -Marker 'MAPPING COLLISION WPF SMOKE TEST: PASS'
        Invoke-ValidationTest -Name 'UI initial-state tests' -Path (Join-Path $PSScriptRoot 'Run-UiInitialStateTests.ps1') -Marker 'UI INITIAL-STATE TESTS: PASS'
        Invoke-ValidationTest -Name 'Overview persistence tests' -Path (Join-Path $PSScriptRoot 'Run-OverviewPersistenceTests.ps1') -Marker 'OVERVIEW PERSISTENCE TESTS: PASS'
    }
}

if ($failures.Count -gt 0) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('STATIC VALIDATION: FAIL') | Out-Null
    foreach ($failure in $failures) { $lines.Add("  - $failure") | Out-Null }
    $lines.Add('Checks completed:') | Out-Null
    foreach ($check in $checks) { $lines.Add("  - $check") | Out-Null }
    throw ($lines.ToArray() -join "`r`n")
}

Write-Output 'STATIC VALIDATION: PASS'
foreach ($check in $checks) { Write-Output "  - $check" }
