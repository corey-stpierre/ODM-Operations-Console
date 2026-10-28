[CmdletBinding()]param([string]$ScreenshotDirectory)
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
function Assert-OperationsUi {param($Value,[string]$Message) if(-not $Value){throw "OPERATIONS UI: $Message"}}
[xml]$xaml=Get-Content -LiteralPath (Join-Path $root 'Resources\QuestODMConsole.xaml') -Raw
$reader=New-Object Xml.XmlNodeReader $xaml
$script:Window=[Windows.Markup.XamlReader]::Load($reader)
$script:Ui=@{}
foreach($match in [regex]::Matches($xaml.OuterXml,'x:Name="([^"]+)"')) {$script:Ui[$match.Groups[1].Value]=$script:Window.FindName($match.Groups[1].Value)}
$script:AppRoot=$root
$script:ReportsPath=[IO.Path]::GetTempPath()
try {
    Initialize-OperationsCenterUi
    Initialize-ManagementUi
    Reset-WorkspaceUi
    Assert-OperationsUi (-not (Get-UiControl 'OperationsLoadButton').IsEnabled) 'Disconnected controls disabled'
    Assert-OperationsUi ((Get-UiControl 'GuideTextBox').Text.Length -gt 100) 'Guides load offline'
    $script:State.Connected=$true;$script:State.WorkloadSelected=$true
    $script:State.Context=[pscustomobject]@{WorkloadType='PowerBi';WorkloadName='Synthetic pilot';WorkloadId='workload'}
    $definition=[pscustomobject]@{Command='New-OdmPbiCreateNewConnectionProfileTask';Name='Create connection profile';Mode='Create';Risk='Write';SupportsMembers=$false;Fields=@(
        [pscustomobject]@{Name='Name';Required=$true;Kind='Text';Choices=@();Default='';Description='Choose a unique task name.'}
        [pscustomobject]@{Name='ProfileName';Required=$true;Kind='Text';Choices=@();Default='';Description='The new profile name.'}
        [pscustomobject]@{Name='Password';Required=$true;Kind='Secret';Choices=@();Default='';Description='Masked and excluded from preview values.'}
        [pscustomobject]@{Name='NotifyOnTaskCompletion';Required=$false;Kind='Choice';Choices=@('true','false');Default='$false';Description='Send the configured Quest notification on completion.'}
    )}
    Show-OperationsDefinition $definition
    Assert-OperationsUi ($script:State.OperationsFields.Password.Control -is [Windows.Controls.PasswordBox]) 'Secrets are masked'
    Assert-OperationsUi (-not (Get-UiControl 'OperationsMemberIdsBox').IsEnabled) 'Unsupported membership disabled'
    $script:State.OperationsFields.Name.Control.Text='Pilot connection profile'
    $script:State.OperationsFields.ProfileName.Control.Text='Pilot profile'
    $script:State.OperationsFields.Password.Control.Password='synthetic-secret'
    (Get-UiControl 'OperationsScopeCheckBox').IsChecked=$true
    function Confirm-UiAction {param($Text,$Title) $true}
    function Invoke-EngineAsync {
        param($Operation,$Parameters,$Status,$OnSuccess,$OnFailure)
        $script:CapturedOperation=$Operation;$script:CapturedParameters=$Parameters
        & $OnSuccess ([pscustomobject]@{PreviewToken=if($Parameters.Execute){''}else{'test-preview'};Plan=[pscustomobject]@{Status=if($Parameters.Execute){'SUBMITTED_REVIEW_REQUIRED'}else{'PREVIEW'};Parameters=@{Password='<redacted>'};WorkloadId='workload';Schedule='Held - no automatic start'}})
    }
    Invoke-OperationsTaskFromUi
    Assert-OperationsUi ($script:CapturedOperation -eq 'OperationsTask' -and -not $script:CapturedParameters.Execute) 'Preview dispatches without execution'
    Assert-OperationsUi (-not $script:CapturedParameters.Values.ContainsKey('NotifyOnTaskCompletion')) 'Optional defaults are omitted'
    Assert-OperationsUi ((Get-UiControl 'OperationsResultBox').Text -notmatch 'synthetic-secret') 'Preview uses redacted result'
    (Get-UiControl 'OperationsExecuteCheckBox').IsChecked=$true
    Assert-OperationsUi (-not (Get-UiControl 'OperationsCreateButton').IsEnabled) 'Safe Mode blocks execution'
    $script:State.SafeMode=$false;Update-UiEnablement
    Assert-OperationsUi ((Get-UiControl 'OperationsCreateButton').IsEnabled) 'Both write gates allow execution'
    $script:State.OperationsFields.Name.Control.Text='Changed pilot'
    Assert-OperationsUi (-not $script:State.OperationsPreviewToken -and -not (Get-UiControl 'OperationsExecuteCheckBox').IsChecked) 'Field change clears preview and gate'
    Invoke-OperationsTaskFromUi;(Get-UiControl 'OperationsExecuteCheckBox').IsChecked=$true
    Invoke-OperationsTaskFromUi -Execute $true
    Assert-OperationsUi ($script:CapturedParameters.Execute -and -not $script:State.OperationsFields.Password.Control.Password) 'Execute clears secret field'
    $definition.Mode='Update';Show-OperationsDefinition $definition
    Assert-OperationsUi ((Get-UiControl 'OperationsCreateButton').Content -eq 'Apply task update' -and $script:State.OperationsFields.NotifyOnTaskCompletion.Control.Items[0] -eq 'Leave unchanged') 'Updates show preservation semantics'
    (Get-UiControl 'ManagementIdBox').Text='collection';(Get-UiControl 'ManagementNameBox').Text='Pilot collection'
    Invoke-ManagementFromUi
    Assert-OperationsUi ($script:CapturedOperation -eq 'Management' -and $script:State.ManagementPreviewToken) 'Management preview callback'
    (Get-UiControl 'ManagementExecuteCheckBox').IsChecked=$true
    Assert-OperationsUi ((Get-UiControl 'ManagementApplyButton').IsEnabled) 'Management execute available with gates'
    (Get-UiControl 'ManagementNameBox').Text='Changed collection'
    Assert-OperationsUi (-not $script:State.ManagementPreviewToken) 'Management edits clear token'
    $script:State.Busy=$true;Update-UiEnablement
    Assert-OperationsUi (-not (Get-UiControl 'OperationsFieldsPanel').IsEnabled -and -not (Get-UiControl 'ManagementPreviewButton').IsEnabled) 'Busy locks both new forms'
    $script:State.Busy=$false;Update-UiEnablement
    # Use a real offscreen WPF window so layout includes native presentation state.
    $script:Window.WindowStartupLocation='Manual';$script:Window.Left=-20000;$script:Window.Top=-20000;$script:Window.ShowInTaskbar=$false
    $script:Window.Width=1180;$script:Window.Height=760;$script:Window.Show()
    $tabs=Get-UiControl 'MainTabControl';$operations=@($tabs.Items|Where-Object {$_.Header -eq 'Operations Center'})[0];$tabs.SelectedItem=$operations
    $inner=@($operations.Content.Children|Where-Object {$_ -is [Windows.Controls.TabControl]})[0]
    foreach($theme in @('Light','Dark')){
        Set-UiTheme -Theme $theme
        foreach($index in @(0,2)){
            $inner.SelectedIndex=$index;$script:Window.UpdateLayout()
            $names=if($index -eq 0){@('OperationsPreviewButton','OperationsCreateButton','OperationsScopeCheckBox')}else{@('ManagementPreviewButton','ManagementApplyButton','ManagementIdBox')}
            foreach($name in $names){
                $control=Get-UiControl $name;$point=$control.TransformToAncestor($script:Window).Transform([Windows.Point]::new(0,0))
                Assert-OperationsUi ($control.ActualWidth -gt 0 -and $control.ActualHeight -gt 0 -and $point.Y -ge 0 -and ($point.Y+$control.ActualHeight) -le $script:Window.ActualHeight) "$name visible at minimum size in $theme"
            }
            if($ScreenshotDirectory){
                $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1180,760,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($script:Window)
                $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                $stream=[IO.File]::Create((Join-Path $ScreenshotDirectory ("Operations-$theme-$index.png")));try{$encoder.Save($stream)}finally{$stream.Dispose()}
            }
        }
    }
    Clear-WorkloadDataUi
    Assert-OperationsUi (-not $script:State.OperationsDefinition -and -not $script:State.OperationsPreviewToken -and -not $script:State.ManagementPreviewToken -and $script:State.OperationsFields.Count -eq 0) 'Workload switch clears all new form state'
    Write-Output 'OPERATIONS WPF TESTS: PASS'
} finally {$reader.Close();$script:Window.Close()}
