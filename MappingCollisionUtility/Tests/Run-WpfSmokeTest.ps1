[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-McuWpf {
    param([Parameter(Mandatory = $true)][bool]$Condition,[Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw "MAPPING COLLISION WPF ASSERTION FAILED: $Message" }
}

if (-not [Environment]::Is64BitProcess) { throw 'The utility WPF smoke test requires a 64-bit PowerShell host.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { throw 'The utility WPF smoke test requires an STA host.' }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$utilityRoot = Split-Path -Parent $testsRoot
$xamlPath = Join-Path $utilityRoot 'Resources\MappingCollisionUtility.xaml'
$uiPath = Join-Path $utilityRoot 'MappingCollisionUtility.UI.ps1'
$enginePath = Join-Path $utilityRoot 'Engine\MappingCollisionEngine.psm1'
$logMaintenancePath = Join-Path (Split-Path -Parent $utilityRoot) 'Shared\LogMaintenance.ps1'

foreach ($path in @($xamlPath,$uiPath,$enginePath,$logMaintenancePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required utility file was not found: $path" }
}
foreach ($path in @($uiPath,$enginePath,$logMaintenancePath,(Join-Path $utilityRoot 'MappingCollisionUtility.ps1'))) {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw "$path does not parse: $((@($parseErrors | ForEach-Object Message)) -join '; ')" }
}
$uiTokens = $null
$uiParseErrors = $null
$uiAst = [System.Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$uiTokens,[ref]$uiParseErrors)
if (@($uiParseErrors).Count -gt 0) { throw "The utility UI does not parse: $((@($uiParseErrors | ForEach-Object Message)) -join '; ')" }
foreach ($functionName in @('Get-McuUiControl','Set-McuThemeBrush','Get-McuThemePalette','Set-McuTheme')) {
    $definitions = @($uiAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            [string]::Equals([string]$node.Name, [string]$functionName, [StringComparison]::OrdinalIgnoreCase)
    }.GetNewClosure(), $true))
    if ($definitions.Count -ne 1) { throw "Unable to extract the production $functionName function." }
    . ([scriptblock]::Create([string]$definitions[0].Extent.Text))
}

$reader = $null
$window = $null
try {
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -ErrorAction Stop
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    Assert-McuWpf -Condition ($null -ne $window) -Message 'XamlReader returned no utility window.'

    foreach ($controlName in @(
        'QuestLogoImage','ExportBothCollectorsButton','SaveSourceCollectorButton','SaveTargetCollectorButton',
        'SourceCsvPathBox','TargetCsvPathBox','OutputDirectoryBox','AnalyzeButton','ResultsTabControl',
        'CollisionsGrid','MappingCandidatesGrid','AmbiguousMappingsGrid','InventoryQualityGrid','UnmatchedSourceGrid',
        'RunLogBox','OpenHtmlReportButton','OpenOutputFolderButton','BusyProgressBar','DarkModeCheckBox',
        'UtilityLogRetentionStatusText','UtilityLogRetentionDaysCombo','OpenUtilityLogsButton','CleanUtilityLogsButton','ClearUtilityStoredLogsButton','ClearRunLogViewButton'
    )) {
        Assert-McuWpf -Condition ($null -ne $window.FindName($controlName)) -Message "$controlName was not created."
    }
    Assert-McuWpf -Condition (-not [bool]$window.FindName('OpenHtmlReportButton').IsEnabled) -Message 'The HTML report button must be disabled before analysis.'
    Assert-McuWpf -Condition (-not [bool]$window.FindName('OpenOutputFolderButton').IsEnabled) -Message 'The output-folder button must be disabled before analysis.'
    Assert-McuWpf -Condition ([bool]$window.FindName('CheckInternalDuplicatesCheckBox').IsChecked) -Message 'Internal duplicate checks must default on.'
    Assert-McuWpf -Condition ([bool]$window.FindName('CheckCrossAttributeCheckBox').IsChecked) -Message 'Cross-attribute checks must default on.'
    foreach ($resourceName in @('BackgroundBrush','SurfaceBrush','TextBrush','MutedBrush','SelectionBrush','WarningLightBrush')) {
        Assert-McuWpf -Condition ($null -ne $window.Resources[$resourceName]) -Message "Theme resource $resourceName was not created."
        Assert-McuWpf -Condition ($window.Resources[$resourceName] -is [Windows.Media.SolidColorBrush]) -Message "Theme resource $resourceName is not a brush. WPF may freeze style resources; the production setter must replace them."
    }
    $frozenProbe = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Colors]::Red)
    $frozenProbe.Freeze()
    $resourceDictionary = [System.Collections.IDictionary]$window.Resources
    if ($resourceDictionary.Contains('AccentBrush')) { $resourceDictionary.Remove('AccentBrush') }
    $resourceDictionary.Add('AccentBrush',[object]$frozenProbe)
    $script:Window = $window
    Set-McuThemeBrush -Name 'AccentBrush' -Color '#62C0DA'
    Assert-McuWpf -Condition ($window.Resources['AccentBrush'] -is [Windows.Media.SolidColorBrush]) -Message 'Frozen-brush fallback returned a non-brush resource.'
    Assert-McuWpf -Condition ([string]$window.Resources['AccentBrush'].Color -eq '#FF62C0DA') -Message 'Frozen-brush fallback did not apply the requested color.'
    $script:Window = $window
    $script:Ui = @{ DarkModeCheckBox = $window.FindName('DarkModeCheckBox') }
    $script:State = [ordered]@{ Theme = 'Light' }
    Set-McuTheme -Theme 'Dark'
    Assert-McuWpf -Condition ($script:State.Theme -eq 'Dark') -Message 'Production Set-McuTheme did not set Dark state.'
    Assert-McuWpf -Condition ([bool]$script:Ui.DarkModeCheckBox.IsChecked) -Message 'Utility dark mode toggle was not synchronized to Dark.'
    Assert-McuWpf -Condition ([string]$window.Resources['BackgroundBrush'].Color -eq '#FF101720') -Message 'Utility dark palette was not applied.'
    Set-McuTheme -Theme 'Light'
    Assert-McuWpf -Condition ($script:State.Theme -eq 'Light') -Message 'Production Set-McuTheme did not restore Light state.'
    Assert-McuWpf -Condition (-not [bool]$script:Ui.DarkModeCheckBox.IsChecked) -Message 'Utility dark mode toggle was not synchronized to Light.'
    Assert-McuWpf -Condition ([string]$window.Resources['BackgroundBrush'].Color -eq '#FFF6FBFE') -Message 'Utility light palette was not restored.'

    # A Window requires an HWND for layout. Keep the smoke-test window off screen.
    $window.ShowInTaskbar=$false
    $window.WindowStartupLocation='Manual'
    $window.Left=-20000
    $window.Top=-20000
    $window.Show()
    $window.Measure([Windows.Size]::new(1450,920))
    $window.Arrange([Windows.Rect]::new(0,0,1450,920))
    $window.UpdateLayout()
    Assert-McuWpf -Condition ($window.ActualWidth -gt 0 -or $window.DesiredSize.Width -gt 0) -Message 'The utility did not complete a layout pass.'

    Write-Output 'MAPPING COLLISION WPF SMOKE TEST: PASS'
}
finally {
    if ($null -ne $reader) { try { $reader.Close() } catch { } }
    if ($null -ne $window) { try { $window.Close() } catch { } }
}
