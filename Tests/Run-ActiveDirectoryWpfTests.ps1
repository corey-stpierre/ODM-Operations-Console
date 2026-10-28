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
    Initialize-OperationsCenterUi;Initialize-ManagementUi;Initialize-AdUi;Reset-WorkspaceUi
    Assert-OperationsUi (-not (Get-UiControl 'AdOpenButton').IsEnabled -and -not (Get-UiControl 'AdApplyButton').IsEnabled) 'AD disconnected controls disabled'
    $script:State.Connected=$true;$script:State.WorkloadSelected=$false
    $script:State.Context=[pscustomobject]@{OrganizationId='pilot-org';OrganizationName='Synthetic AD pilot';ContextMode='Microsoft365';ContextValid=$true}
    Update-UiEnablement
    Assert-OperationsUi ((Get-UiControl 'AdOpenButton').IsEnabled -and -not (Get-UiControl 'AdLoadButton').IsEnabled) 'AD-only organization can open workspace without M365 project'
    function Invoke-EngineAsync {
        param($Operation,$Parameters,$Status,$OnSuccess,$OnFailure)
        $script:CapturedOperation=$Operation;$script:CapturedParameters=$Parameters
        if($Operation -eq 'OpenActiveDirectory'){
            $catalog=Get-Content -LiteralPath (Join-Path $script:AppRoot 'Config\ActiveDirectoryCatalog.json') -Raw|ConvertFrom-Json
            foreach($entry in @($catalog.Inventories)+@($catalog.Operations)){$entry|Add-Member Available $true;$entry|Add-Member AvailabilityNote 'Synthetic module fixture'}
            & $OnSuccess ([pscustomobject]@{State=[pscustomobject]@{Connected=$true;ContextMode='ActiveDirectory';ContextValid=$true;OrganizationId='pilot-org';OrganizationName='Synthetic AD pilot';Region='US';SafeMode=$true};Catalog=$catalog})
        }elseif($Operation -eq 'AdDefinition'){
            & $OnSuccess ([pscustomobject]@{Command=$Parameters.CommandName;Name='AD device pilot';TargetKind='Devices';Risk='Immediate/scheduled action';UnsupportedParameters=@();Fields=@(
                [pscustomobject]@{Name='DoNotStartBefore';Required=$false;Kind='Text';Choices=@();Description='Optional future ISO timestamp with timezone; blank permits immediate execution.'}
                [pscustomobject]@{Name='IgnoreReACLStatus';Required=$false;Kind='Choice';Choices=@('true','false');Description='Bypasses the vendor ReACL prerequisite only for a reviewed exception.'}
                [pscustomobject]@{Name='LocalFolders';Required=$false;Kind='Lines';Choices=@();Description='One path per line. Commas within a path are preserved.'}
            )})
        }elseif($Operation -eq 'AdAction'){
            & $OnSuccess ([pscustomobject]@{PreviewToken='ad-preview';Plan=[pscustomobject]@{Status='PREVIEW';OrganizationId='pilot-org';Targets=@('1','2');Settings=$Parameters.Values;Execution='May take effect immediately.'}})
        }elseif($Operation -eq 'AdInventory'){
            & $OnSuccess ([pscustomobject]@{Rows=@([pscustomobject]@{TargetId='1';Name='AD-PILOT-1';EnvironmentId='7';Status='Ready';Details='{"AgentKey":"<redacted>","DeviceId":1}'});Note='Bounded synthetic inventory'})
        }else{throw "Unexpected test operation: $Operation"}
    }
    (Get-UiControl 'AdOpenButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-OperationsUi ($script:State.Context.ContextMode -eq 'ActiveDirectory' -and -not $script:State.WorkloadSelected -and (Get-UiControl 'ToggleSafeModeButton').IsEnabled) 'Organization-scoped AD context and safe-mode gate'
    Assert-OperationsUi (-not (Get-UiControl 'OperationsLoadButton').IsEnabled -and (Get-UiControl 'AdLoadButton').IsEnabled) 'AD and M365 UI isolation'
    (Get-UiControl 'AdLoadButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-OperationsUi ($script:CapturedParameters.Limit -eq 1000 -and $script:CapturedParameters.Kind -eq 'Devices') 'Inventory uses explicit bounded limit'
    (Get-UiControl 'AdCommandCombo').SelectedIndex=7
    (Get-UiControl 'AdTargetIdsBox').Text="1`n2"
    $script:State.AdFields.LocalFolders.Control.Text="C:\Pilot,One`nC:\PilotTwo"
    Invoke-AdActionFromUi
    Assert-OperationsUi ($script:CapturedOperation -eq 'AdAction' -and -not $script:CapturedParameters.Execute -and -not $script:CapturedParameters.Values.ContainsKey('IgnoreReACLStatus')) 'AD preview preserves optional omission'
    (Get-UiControl 'AdExecuteCheckBox').IsChecked=$true
    Assert-OperationsUi (-not (Get-UiControl 'AdApplyButton').IsEnabled) 'AD global Safe Mode blocks execute'
    $script:State.SafeMode=$false;Update-UiEnablement
    Assert-OperationsUi ((Get-UiControl 'AdApplyButton').IsEnabled) 'AD local and global gates required'
    $script:State.AdFields.IgnoreReACLStatus.Control.SelectedIndex=2
    Assert-OperationsUi (-not $script:State.AdPreviewToken -and -not (Get-UiControl 'AdExecuteCheckBox').IsChecked) 'AD fields invalidate preview'
    Invoke-AdActionFromUi;(Get-UiControl 'AdExecuteCheckBox').IsChecked=$true
    (Get-UiControl 'AdCsvBox').Text='changed.csv'
    Assert-OperationsUi (-not $script:State.AdPreviewToken) 'CSV input invalidates preview'
    $script:State.Busy=$true;Update-UiEnablement
    Assert-OperationsUi (-not (Get-UiControl 'AdOpenButton').IsEnabled -and -not (Get-UiControl 'AdFieldsPanel').IsEnabled) 'Busy locks AD controls'
    $script:State.Busy=$false;Update-UiEnablement
    $script:Window.WindowStartupLocation='Manual';$script:Window.Left=-20000;$script:Window.Top=-20000;$script:Window.ShowInTaskbar=$false
    $script:Window.Width=1180;$script:Window.Height=760;$script:Window.Show()
    $tabs=Get-UiControl 'MainTabControl';$tabs.SelectedItem=@($tabs.Items|Where-Object {$_.Header -eq 'Active Directory'})[0]
    foreach($theme in @('Light','Dark')){
        Set-UiTheme -Theme $theme
        foreach($index in @(0,1)){
            (Get-UiControl 'AdTabs').SelectedIndex=$index;$script:Window.UpdateLayout()
            $names=if($index -eq 0){@('AdLoadButton','AdLimitBox','AdExportButton','AdDetailsBox')}else{@('AdPreviewButton','AdApplyButton','AdExecuteCheckBox','AdCommandCombo')}
            foreach($name in $names){$control=Get-UiControl $name;$point=$control.TransformToAncestor($script:Window).Transform([Windows.Point]::new(0,0));Assert-OperationsUi ($control.ActualWidth -gt 0 -and $control.ActualHeight -gt 0 -and $point.Y -ge 0 -and ($point.Y+$control.ActualHeight) -le $script:Window.ActualHeight) "$name visible at minimum size in $theme"}
            if($index -eq 0){Assert-OperationsUi ((Get-UiControl 'AdGrid').Columns[1].ActualWidth -ge 260) 'Device names remain readable in the inventory'} 
            if($ScreenshotDirectory){
                $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1180,760,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($script:Window)
                $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                $stream=[IO.File]::Create((Join-Path $ScreenshotDirectory ("ActiveDirectory-$theme-$index.png")));try{$encoder.Save($stream)}finally{$stream.Dispose()}
            }
        }
    }
    Clear-WorkloadDataUi
    Assert-OperationsUi (-not $script:State.AdDefinition -and -not $script:State.AdPreviewToken -and $script:State.AdFields.Count -eq 0 -and -not (Get-UiControl 'AdTargetIdsBox').Text) 'Context reset removes AD targets, fields, token and local gate'
    Write-Output 'ACTIVE DIRECTORY WPF TESTS: PASS'
} finally {$reader.Close();$script:Window.Close()}
