[CmdletBinding()]param([string]$ScreenshotPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path -Parent $PSScriptRoot
$uiPath=Join-Path $root 'QuestODMConsole.UI.ps1'
$ast=[System.Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$null,[ref]$null)
# Import production functions into this script scope without starting the application or connecting.
foreach($fn in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$stateAst=$ast.Find({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:State'},$false)
. ([scriptblock]::Create($stateAst.Extent.Text))
$script:MappingCollisionUtilityRoot=Join-Path $root 'MappingCollisionUtility'
$script:MappingCollisionUtilityLauncher=Join-Path $script:MappingCollisionUtilityRoot 'Start-MappingCollisionUtility.cmd'
$script:MappingCollisionUtilityScript=Join-Path $script:MappingCollisionUtilityRoot 'MappingCollisionUtility.ps1'
$script:MappingCollisionUtilityBootstrapPath=$script:MappingCollisionUtilityScript
$script:MappingCollisionUtilityXamlPath=Join-Path $script:MappingCollisionUtilityRoot 'Resources\MappingCollisionUtility.xaml'
$script:MappingCollisionUtilityEnginePath=Join-Path $script:MappingCollisionUtilityRoot 'Engine\MappingCollisionEngine.psm1'
$script:OperationHistoryPath=Join-Path $root 'Logs\ContentUiTest-Nonexistent.jsonl'
function Assert-ContentUi {param($Value,[string]$Message) if(-not $Value){throw "CONTENT UI: $Message"}}
[xml]$xaml=Get-Content -LiteralPath (Join-Path $root 'Resources\QuestODMConsole.xaml') -Raw
$reader=New-Object Xml.XmlNodeReader $xaml
$script:Window=[Windows.Markup.XamlReader]::Load($reader)
$script:Ui=@{}
foreach($match in [regex]::Matches($xaml.OuterXml,'x:Name="([^"]+)"')) {$script:Ui[$match.Groups[1].Value]=$script:Window.FindName($match.Groups[1].Value)}
try {
    Reset-WorkspaceUi
    Assert-ContentUi (-not (Get-UiControl 'ContentLoadOptionsButton').IsEnabled) 'Disconnected options disabled'
    $script:State.Connected=$true
    $script:State.WorkloadSelected=$true
    $script:State.Context=[pscustomobject]@{WorkloadType='Teams';WorkloadName='Synthetic Teams';WorkloadId='content-Teams'}
    $script:State['ContentOptions']=[pscustomobject]@{TaskKinds=@(
        [pscustomobject]@{Key='TeamsMigrate';Name='Migrate teams (template)';ObjectKind='Teams';Available=$true;RequiresTemplate=$true;Details='Ready';Settings='{}'}
        [pscustomobject]@{Key='GroupsMigrate';Name='Migrate groups (template)';ObjectKind='Groups';Available=$true;RequiresTemplate=$true;Details='Ready';Settings='{}'}
    )}
    Set-ComboItems -Combo (Get-UiControl 'ContentObjectKindCombo') -Items @('Teams','Groups')
    (Get-UiControl 'ContentObjectKindCombo').SelectedIndex=0
    Update-ContentTaskKinds
    Assert-ContentUi ((Get-UiControl 'ContentTaskKindCombo').SelectedValue -eq 'TeamsMigrate') 'Task choices follow object kind'
    (Get-UiControl 'ContentExecuteCheckBox').IsChecked=$true
    Update-UiEnablement
    Assert-ContentUi (-not (Get-UiControl 'ContentExecuteButton').IsEnabled) 'Safe Mode blocks execute'
    $script:State.SafeMode=$false
    Update-UiEnablement
    Assert-ContentUi ((Get-UiControl 'ContentExecuteButton').IsEnabled) 'Both write gates allow execute'
    $script:State.Busy=$true
    Update-UiEnablement
    Assert-ContentUi (-not (Get-UiControl 'ContentExecuteButton').IsEnabled -and -not (Get-UiControl 'ContentObjectKindCombo').IsEnabled) 'Busy locks content controls'
    $script:State.Busy=$false
    (Get-UiControl 'ContentObjectKindCombo').SelectedIndex=1
    Update-ContentTaskKinds
    Assert-ContentUi ((Get-UiControl 'ContentTaskKindCombo').SelectedValue -eq 'GroupsMigrate') 'Groups do not use the teams task kind'
    Assert-ContentUi (-not (Get-UiControl 'ContentExecuteCheckBox').IsChecked) 'Changing object kind resets local execute'
    # Test the actual CSV controller and callback using an in-memory transport.
    function Confirm-UiAction {param($Text,$Title) $true}
    function Refresh-Workspace {}
    function Invoke-EngineAsync {
        param($Operation,$Parameters,$Status,$OnSuccess)
        $script:CapturedOperation=$Operation;$script:CapturedParameters=$Parameters
        & $OnSuccess ([pscustomobject]@{Rows=@([pscustomobject]@{ObjectId='Groups-1';Status='PREVIEW'});Status='PREVIEW';ReportPath='test-report.csv';Execute=$false})
    }
    (Get-UiControl 'ContentCsvPathBox').Text='synthetic.csv'
    (Get-UiControl 'ContentActionCombo').SelectedIndex=1
    (Get-UiControl 'ContentTemplateBox').Text='template-migrategroups'
    Invoke-ContentCsvFromUi
    Assert-ContentUi ($script:CapturedOperation -eq 'ContentCsv' -and -not $script:CapturedParameters.Execute) 'Preview dispatches without writes'
    Assert-ContentUi ((Get-UiControl 'ContentResultsGrid').Items.Count -eq 1) 'Callback renders single result row'
    (Get-UiControl 'ContentExecuteCheckBox').IsChecked=$true
    Invoke-ContentCsvFromUi -Execute $true
    Assert-ContentUi ($script:CapturedParameters.Execute -and $script:CapturedParameters.TaskKind -eq 'GroupsMigrate') 'Execute carries task kind and local gate'
    Clear-WorkloadDataUi
    Assert-ContentUi ((Get-UiControl 'ContentResultsGrid').Items.Count -eq 0 -and (Get-UiControl 'ContentObjectKindCombo').Items.Count -eq 0) 'Context switch clears inventory and choices'
    if($ScreenshotPath) {
        $tabs=Get-UiControl 'MainTabControl'
        $tabs.SelectedItem=@($tabs.Items | Where-Object {$_.Header -eq 'Teams / SharePoint / Power BI'})[0]
        $surface=$script:Window.Content
        $script:Window.Content=$null
        $surface.Resources=$script:Window.Resources
        $surface.Measure([Windows.Size]::new(1440,960));$surface.Arrange([Windows.Rect]::new(0,0,1440,960));$surface.UpdateLayout()
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1440,960,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($surface)
        $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Create($ScreenshotPath);try{$encoder.Save($stream)}finally{$stream.Dispose()}
    }
    Write-Output 'CONTENT WPF TESTS: PASS'
}
finally {$reader.Close();$script:Window.Close()}
