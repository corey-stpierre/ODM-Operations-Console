[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-WpfCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "WPF SMOKE TEST ASSERTION FAILED: $Message" }
}

if (-not [Environment]::Is64BitProcess) {
    throw 'The WPF smoke test requires a 64-bit PowerShell host.'
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'The WPF smoke test requires an STA PowerShell host. Run powershell.exe with -STA.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $testsRoot
$xamlPath = Join-Path $appRoot 'Resources\QuestODMConsole.xaml'
if (-not (Test-Path -LiteralPath $xamlPath -PathType Leaf)) {
    throw "XAML file was not found: $xamlPath"
}

$uiPath = Join-Path $appRoot 'QuestODMConsole.UI.ps1'
$tokens = $null
$parseErrors = $null
$uiAst = [System.Management.Automation.Language.Parser]::ParseFile($uiPath, [ref]$tokens, [ref]$parseErrors)
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
    throw ('The UI controller does not parse: ' + ((@($parseErrors | ForEach-Object { $_.Message })) -join '; '))
}
$normalizerDefinitions = @($uiAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        [string]::Equals([string]$node.Name, 'ConvertTo-UiObjectArray', [StringComparison]::OrdinalIgnoreCase)
}, $true))
if ($normalizerDefinitions.Count -ne 1) { throw 'Unable to extract the production ConvertTo-UiObjectArray function.' }
. ([scriptblock]::Create([string]$normalizerDefinitions[0].Extent.Text))
$themeFunctionNames = @('Get-UiControl','Set-UiThemeBrush','Get-UiThemePalette','Set-UiTheme')
foreach ($functionName in $themeFunctionNames) {
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
    Assert-WpfCondition -Condition ($null -ne $window) -Message 'XamlReader returned no Window object.'

    $organizationCombo = $window.FindName('OrganizationCombo')
    $projectCombo = $window.FindName('ProjectCombo')
    $workloadCombo = $window.FindName('WorkloadCombo')
    Assert-WpfCondition -Condition ($null -ne $organizationCombo) -Message 'OrganizationCombo was not created.'
    Assert-WpfCondition -Condition ($null -ne $projectCombo) -Message 'ProjectCombo was not created.'
    Assert-WpfCondition -Condition ($null -ne $workloadCombo) -Message 'WorkloadCombo was not created.'
    Assert-WpfCondition -Condition ($null -eq $window.FindName('IntegratedAuthCheckBox')) -Message 'Integrated authentication control must not exist.'
    foreach ($resourceName in @('BackgroundBrush','SurfaceBrush','TextBrush','MutedBrush','SelectionBrush','WarningLightBrush','DangerLightBrush')) {
        Assert-WpfCondition -Condition ($null -ne $window.Resources[$resourceName]) -Message "Theme resource $resourceName was not created."
        Assert-WpfCondition -Condition (-not [bool]$window.Resources[$resourceName].IsFrozen) -Message "Theme resource $resourceName was unexpectedly frozen."
    }
    $frozenProbe = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Colors]::Red)
    $frozenProbe.Freeze()
    $resourceDictionary = [System.Collections.IDictionary]$window.Resources
    if ($resourceDictionary.Contains('AccentBrush')) { $resourceDictionary.Remove('AccentBrush') }
    $resourceDictionary.Add('AccentBrush',[object]$frozenProbe)
    $script:Window = $window
    Set-UiThemeBrush -Name 'AccentBrush' -Color '#62C0DA'
    Assert-WpfCondition -Condition ($window.Resources['AccentBrush'] -is [Windows.Media.SolidColorBrush]) -Message 'Frozen-brush fallback returned a non-brush resource.'
    Assert-WpfCondition -Condition ([string]$window.Resources['AccentBrush'].Color -eq '#FF62C0DA') -Message 'Frozen-brush fallback did not apply the requested color.'

    $script:Window = $window
    $script:Ui = @{ DarkModeCheckBox = $window.FindName('DarkModeCheckBox') }
    $script:State = [ordered]@{ Theme = 'Light' }
    Set-UiTheme -Theme 'Dark'
    Assert-WpfCondition -Condition ($script:State.Theme -eq 'Dark') -Message 'Production Set-UiTheme did not set Dark state.'
    Assert-WpfCondition -Condition ([bool]$script:Ui.DarkModeCheckBox.IsChecked) -Message 'Dark mode toggle was not synchronized to the Dark state.'
    Assert-WpfCondition -Condition ([string]$window.Resources['BackgroundBrush'].Color -eq '#FF101720') -Message 'Dark background palette was not applied.'
    Set-UiTheme -Theme 'Light'
    Assert-WpfCondition -Condition ($script:State.Theme -eq 'Light') -Message 'Production Set-UiTheme did not restore Light state.'
    Assert-WpfCondition -Condition (-not [bool]$script:Ui.DarkModeCheckBox.IsChecked) -Message 'Dark mode toggle was not synchronized to the Light state.'
    Assert-WpfCondition -Condition ([string]$window.Resources['BackgroundBrush'].Color -eq '#FFF6FBFE') -Message 'Light background palette was not restored.'

    foreach ($controlName in @(
        'StartSelectedTasksButton','BulkTaskNameBox','BulkStartCreatedTaskCheckBox','OpenBulkTemplateButton',
        'LaunchMappingCollisionUtilityButton','OpenMappingCollisionUtilityFolderButton','MappingCollisionUtilityStatusText',
        'TaskCsvActionCard','TaskCsvActionFooter','TaskCsvInputScrollViewer','TaskCsvExecuteCheckBox','AddCsvUsersToTaskButton','RemoveCsvUsersFromTaskButton',
        'CollectionCsvActionCard','CollectionCsvActionFooter','CollectionCsvInputScrollViewer','CollectionCsvExecuteCheckBox','AddCsvUsersToCollectionButton','RemoveCsvUsersFromCollectionButton',
        'OdmApiModuleStatusText','CheckOdmApiVersionButton','InstallOdmApiButton','UpdateOdmApiButton','DarkModeCheckBox',
        'LogRetentionDaysCombo','CleanOldLogsButton','ClearStoredLogsButton','LogRetentionStatusText'
    )) {
        Assert-WpfCondition -Condition ($null -ne $window.FindName($controlName)) -Message "$controlName was not created."
    }
    foreach ($placementComboName in @(
        'FactoryMailPlacementCombo','FactoryOneDrivePlacementCombo','FactoryMeetingLinkPlacementCombo','FactoryMailboxSwitchPlacementCombo'
    )) {
        $placementCombo = $window.FindName($placementComboName)
        Assert-WpfCondition -Condition ($null -ne $placementCombo) -Message "$placementComboName was not created."
        $placementValues = @($placementCombo.Items | ForEach-Object { [string]$_.Content })
        Assert-WpfCondition -Condition ($placementValues -contains 'Prefix') -Message "$placementComboName does not contain Prefix."
        Assert-WpfCondition -Condition ($placementValues -contains 'Suffix') -Message "$placementComboName does not contain Suffix."
    }

    foreach ($combo in @($organizationCombo, $projectCombo, $workloadCombo)) {
        Assert-WpfCondition -Condition ([string]::Equals([string]$combo.DisplayMemberPath, 'DisplayText', [StringComparison]::Ordinal)) -Message "$($combo.Name) must bind DisplayMemberPath to DisplayText."
        Assert-WpfCondition -Condition ([string]::Equals([string]$combo.SelectedValuePath, 'Id', [StringComparison]::Ordinal)) -Message "$($combo.Name) must bind SelectedValuePath to Id."
    }

    $organizationId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $projectId = 'project-001'
    $workloadId = 'workload-accounts'
    $organizationList = New-Object System.Collections.Generic.List[object]
    $organizationList.Add([pscustomobject]@{ Id=$organizationId; Name='Mock Organization'; DisplayText="Mock Organization [$organizationId]" }) | Out-Null
    $projectList = New-Object System.Collections.Generic.List[object]
    $projectList.Add([pscustomobject]@{ Id=$projectId; Name='Mock Project'; DisplayText='Mock Project - M365' }) | Out-Null
    $workloadList = New-Object System.Collections.Generic.List[object]
    $workloadList.Add([pscustomobject]@{ Id=$workloadId; Name='Accounts'; DisplayText='Accounts - activedirectory'; IsProjectContext=$false }) | Out-Null

    $organizationCombo.ItemsSource = ConvertTo-UiObjectArray -InputObject $organizationList
    $projectCombo.ItemsSource = ConvertTo-UiObjectArray -InputObject $projectList
    $workloadCombo.ItemsSource = ConvertTo-UiObjectArray -InputObject $workloadList

    foreach ($combo in @($organizationCombo, $projectCombo, $workloadCombo)) {
        Assert-WpfCondition -Condition ($combo.Items.Count -eq 1) -Message "$($combo.Name) did not accept one context item."
        $combo.SelectedIndex = 0
        Assert-WpfCondition -Condition ($combo.SelectedIndex -eq 0) -Message "$($combo.Name) could not select its first item."
        Assert-WpfCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$combo.SelectedValue)) -Message "$($combo.Name) returned a blank SelectedValue."
        $selectedDisplayText = [string]$combo.SelectedItem.PSObject.Properties['DisplayText'].Value
        Assert-WpfCondition -Condition (-not [string]::IsNullOrWhiteSpace($selectedDisplayText)) -Message "$($combo.Name) selected item has no DisplayText."
    }

    Assert-WpfCondition -Condition ([string]::Equals([string]$organizationCombo.SelectedValue, $organizationId, [StringComparison]::OrdinalIgnoreCase)) -Message 'Organization SelectedValue did not match the organization ID.'
    Assert-WpfCondition -Condition ([string]::Equals([string]$projectCombo.SelectedValue, $projectId, [StringComparison]::OrdinalIgnoreCase)) -Message 'Project SelectedValue did not match the project ID.'
    Assert-WpfCondition -Condition ([string]::Equals([string]$workloadCombo.SelectedValue, $workloadId, [StringComparison]::OrdinalIgnoreCase)) -Message 'Workload SelectedValue did not match the workload ID.'

    # Reproduce the supported minimum window size and select each CSV membership
    # workspace. The action buttons must be arranged inside their card rather than
    # below a clipped StackPanel.
    $mainTabControl = $window.FindName('MainTabControl')
    $taskDetailTabControl = $window.FindName('TaskDetailTabControl')
    Assert-WpfCondition -Condition ($null -ne $mainTabControl) -Message 'MainTabControl was not created.'
    Assert-WpfCondition -Condition ($null -ne $taskDetailTabControl) -Message 'TaskDetailTabControl was not created.'

    function Select-WpfTabByHeader {
        param(
            [Parameter(Mandatory = $true)][object]$TabControl,
            [Parameter(Mandatory = $true)][string]$Header
        )
        for ($index = 0; $index -lt $TabControl.Items.Count; $index++) {
            $item = $TabControl.Items[$index]
            if ([string]::Equals([string]$item.Header, $Header, [StringComparison]::OrdinalIgnoreCase)) {
                $TabControl.SelectedIndex = $index
                return
            }
        }
        throw "Tab '$Header' was not found."
    }

    function Assert-WpfControlInsideCard {
        param(
            [Parameter(Mandatory = $true)][object]$Control,
            [Parameter(Mandatory = $true)][object]$Card,
            [Parameter(Mandatory = $true)][string]$ControlName
        )
        Assert-WpfCondition -Condition ($Control.ActualWidth -gt 0 -and $Control.ActualHeight -gt 0) -Message "$ControlName has no rendered size."
        Assert-WpfCondition -Condition ($Card.ActualWidth -gt 0 -and $Card.ActualHeight -gt 0) -Message "$($Card.Name) has no rendered size."
        $origin = $Control.TranslatePoint([Windows.Point]::new(0, 0), $Card)
        $right = $origin.X + $Control.ActualWidth
        $bottom = $origin.Y + $Control.ActualHeight
        Assert-WpfCondition -Condition ($origin.X -ge -1 -and $origin.Y -ge -1) -Message "$ControlName begins outside $($Card.Name)."
        Assert-WpfCondition -Condition ($right -le ($Card.ActualWidth + 1)) -Message "$ControlName extends past the right edge of $($Card.Name)."
        Assert-WpfCondition -Condition ($bottom -le ($Card.ActualHeight + 1)) -Message "$ControlName is vertically clipped below $($Card.Name)."
    }

    $window.Width = [double]$window.MinWidth
    $window.Height = [double]$window.MinHeight
    $minimumSize = [Windows.Size]::new([double]$window.MinWidth, [double]$window.MinHeight)

    Select-WpfTabByHeader -TabControl $mainTabControl -Header 'Tasks'
    Select-WpfTabByHeader -TabControl $taskDetailTabControl -Header 'Members'
    $window.Measure($minimumSize)
    $window.Arrange([Windows.Rect]::new(0, 0, $minimumSize.Width, $minimumSize.Height))
    $window.UpdateLayout()
    $taskCard = $window.FindName('TaskCsvActionCard')
    foreach ($buttonName in @('AddCsvUsersToTaskButton', 'RemoveCsvUsersFromTaskButton')) {
        Assert-WpfControlInsideCard -Control ($window.FindName($buttonName)) -Card $taskCard -ControlName $buttonName
    }

    Select-WpfTabByHeader -TabControl $mainTabControl -Header 'Collections'
    $window.Measure($minimumSize)
    $window.Arrange([Windows.Rect]::new(0, 0, $minimumSize.Width, $minimumSize.Height))
    $window.UpdateLayout()
    $collectionCard = $window.FindName('CollectionCsvActionCard')
    foreach ($buttonName in @('AddCsvUsersToCollectionButton', 'RemoveCsvUsersFromCollectionButton')) {
        Assert-WpfControlInsideCard -Control ($window.FindName($buttonName)) -Card $collectionCard -ControlName $buttonName
    }

    # Also force a standard-size layout pass to retain the broader resource/style check.
    Select-WpfTabByHeader -TabControl $mainTabControl -Header 'Overview'
    $window.Width = 1600
    $window.Height = 1000
    $window.Measure([Windows.Size]::new(1600, 1000))
    $window.Arrange([Windows.Rect]::new(0, 0, 1600, 1000))
    $window.UpdateLayout()

    Write-Output 'WPF SMOKE TEST: PASS'
}
finally {
    if ($null -ne $reader) { try { $reader.Close() } catch { } }
    if ($null -ne $window) { try { $window.Close() } catch { } }
}
