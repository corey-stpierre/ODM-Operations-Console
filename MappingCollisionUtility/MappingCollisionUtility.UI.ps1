[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$DataRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-McuUiArray {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    $result = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $InputObject) { return $result.ToArray() }
    $value = $InputObject
    try {
        if ($InputObject -is [System.Management.Automation.PSObject] -and $null -ne $InputObject.BaseObject) { $value = $InputObject.BaseObject }
    }
    catch { $value = $InputObject }
    if ($value -is [string] -or $value -is [System.Collections.IDictionary]) { $result.Add($InputObject) | Out-Null; return $result.ToArray() }
    if ($value -is [System.Collections.IEnumerable]) { foreach ($item in $value) { $result.Add($item) | Out-Null }; return $result.ToArray() }
    $result.Add($InputObject) | Out-Null
    return $result.ToArray()
}

function Get-McuUiProperty {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    foreach ($name in $Names) {
        try {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
        }
        catch { }
        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in $InputObject.Keys) {
                if ([string]::Equals([string]$key,$name,[StringComparison]::OrdinalIgnoreCase)) {
                    if ($null -ne $InputObject[$key]) { return $InputObject[$key] }
                }
            }
        }
    }
    return $Default
}

function Test-McuUiDirectoryWritable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        if (-not (Get-Item -LiteralPath $Path -ErrorAction Stop).PSIsContainer) { return $false }
        $probe = Join-Path $Path ('.write-test-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
        [IO.File]::WriteAllText($probe,'test',(New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch { return $false }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:UtilityRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConsoleRoot = Split-Path -Parent $script:UtilityRoot
$script:XamlPath = Join-Path $script:UtilityRoot 'Resources\MappingCollisionUtility.xaml'
$script:EngineModulePath = Join-Path $script:UtilityRoot 'Engine\MappingCollisionEngine.psm1'
$script:CollectorsPath = Join-Path $script:UtilityRoot 'Collectors'
$script:SourceCollectorPath = Join-Path $script:CollectorsPath 'Export-SourceIdentityInventory.ps1'
$script:TargetCollectorPath = Join-Path $script:CollectorsPath 'Export-TargetIdentityInventory.ps1'
$script:SampleSourcePath = Join-Path $script:UtilityRoot 'Samples\SourceInventory.Sample.csv'
$script:SampleTargetPath = Join-Path $script:UtilityRoot 'Samples\TargetInventory.Sample.csv'
$script:LogoPath = Join-Path $script:ConsoleRoot 'Resources\QuestSoftwareLogo.png'
$script:LogMaintenancePath = Join-Path $script:ConsoleRoot 'Shared\LogMaintenance.ps1'

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $base = if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'QuestODMConsole' } else { Join-Path ([IO.Path]::GetTempPath()) 'QuestODMConsole' }
    $DataRoot = Join-Path $base 'MappingCollisionUtility'
}
$script:DataRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DataRoot))
$script:ConfigPath = Join-Path $script:DataRoot 'Config'
$script:LogsPath = Join-Path $script:DataRoot 'Logs'
$script:ReportsPath = Join-Path $script:DataRoot 'Reports'
$script:SettingsPath = Join-Path $script:ConfigPath 'MappingCollisionUtility.settings.json'
$script:ParentConsoleSettingsPath = Join-Path (Split-Path -Parent $script:DataRoot) 'Config\QuestODMConsole.settings.json'
foreach ($path in @($script:DataRoot,$script:ConfigPath,$script:LogsPath,$script:ReportsPath)) {
    if (-not (Test-McuUiDirectoryWritable -Path $path)) { throw "The utility data directory is unavailable or not writable: $path" }
}
$script:SessionLogPath = Join-Path $script:LogsPath ('MappingCollisionUtility_{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

foreach ($required in @($script:XamlPath,$script:EngineModulePath,$script:SourceCollectorPath,$script:TargetCollectorPath,$script:SampleSourcePath,$script:SampleTargetPath,$script:LogoPath,$script:LogMaintenancePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required utility file was not found: $required" }
}
. $script:LogMaintenancePath

[xml]$xaml = Get-Content -LiteralPath $script:XamlPath -Raw -ErrorAction Stop
$reader = $null
try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $script:Window = [Windows.Markup.XamlReader]::Load($reader)
    if ($null -eq $script:Window) { throw 'The WPF XAML loader returned no utility window.' }
}
finally { if ($null -ne $reader) { $reader.Dispose() } }

$script:Ui = @{}
$nameMatches = [regex]::Matches((Get-Content -LiteralPath $script:XamlPath -Raw), 'x:Name="([A-Za-z_][A-Za-z0-9_]*)"')
foreach ($match in $nameMatches) {
    $name = $match.Groups[1].Value
    $control = $script:Window.FindName($name)
    if ($null -ne $control) { $script:Ui[$name] = $control }
}

function Get-McuUiControl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:Ui.ContainsKey($Name)) { throw "Utility UI control '$Name' was not found." }
    return $script:Ui[$Name]
}

function Set-McuThemeBrush {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Color
    )

    $converted = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($Color)
    $brush = $script:Window.Resources[$Name]
    if ($brush -isnot [Windows.Media.SolidColorBrush]) {
        throw "Theme resource '$Name' is not a SolidColorBrush."
    }
    if (-not $brush.IsFrozen) {
        $brush.Color = $converted
        return
    }

    $replacement = $brush.CloneCurrentValue()
    $replacement.Color = $converted
    $resources = [System.Collections.IDictionary]$script:Window.Resources
    if ($resources.Contains($Name)) { $resources.Remove($Name) }
    $resources.Add($Name,[object]$replacement)
}

function Get-McuThemePalette {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Light','Dark')][string]$Theme)

    if ($Theme -eq 'Dark') {
        return [ordered]@{
            PrimaryBrush        = '#4B68A3'
            PrimaryDarkBrush    = '#38558E'
            MetricValueBrush    = '#8FAAE6'
            AccentBrush         = '#57BBD4'
            AccentLightBrush    = '#183743'
            AccentTextBrush     = '#102A34'
            OnPrimaryBrush      = '#FFFFFF'
            SurfaceBrush        = '#18212D'
            InputSurfaceBrush   = '#202A38'
            BackgroundBrush     = '#101720'
            BorderBrush         = '#39475A'
            TextBrush           = '#E7ECF4'
            HeadingBrush        = '#F5F7FB'
            MutedBrush          = '#AEB9CA'
            GridLineBrush       = '#334153'
            GridAlternateBrush  = '#1D2734'
            GridHeaderBrush     = '#243041'
            GridHeaderTextBrush = '#DCE4F0'
            SelectionBrush      = '#345D84'
            SelectionTextBrush  = '#FFFFFF'
            DangerBrush         = '#C34A52'
            WarningBrush        = '#E6AF59'
            WarningLightBrush   = '#3B301C'
            WarningBorderBrush  = '#7A6337'
            WarningTextBrush    = '#FFD28B'
            SuccessBrush        = '#67D39E'
        }
    }

    return [ordered]@{
        PrimaryBrush        = '#3D5B96'
        PrimaryDarkBrush    = '#2E4778'
        MetricValueBrush    = '#2E4778'
        AccentBrush         = '#62C0DA'
        AccentLightBrush    = '#E8F7FB'
        AccentTextBrush     = '#17384A'
        OnPrimaryBrush      = '#FFFFFF'
        SurfaceBrush        = '#FFFFFF'
        InputSurfaceBrush   = '#FFFFFF'
        BackgroundBrush     = '#F6FBFE'
        BorderBrush         = '#D0D8E5'
        TextBrush           = '#273142'
        HeadingBrush        = '#253148'
        MutedBrush          = '#657086'
        GridLineBrush       = '#E8EDF4'
        GridAlternateBrush  = '#F8FBFD'
        GridHeaderBrush     = '#EDF2F8'
        GridHeaderTextBrush = '#39465A'
        SelectionBrush      = '#DCE9F8'
        SelectionTextBrush  = '#17233A'
        DangerBrush         = '#B54343'
        WarningBrush        = '#A86B18'
        WarningLightBrush   = '#FFF5DF'
        WarningBorderBrush  = '#E3B76A'
        WarningTextBrush    = '#8A5510'
        SuccessBrush        = '#2E7D5B'
    }
}

function Set-McuTheme {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Theme)

    $normalized = if ([string]::Equals($Theme,'Dark',[StringComparison]::OrdinalIgnoreCase)) { 'Dark' } else { 'Light' }
    $palette = Get-McuThemePalette -Theme $normalized
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $palette.GetEnumerator()) {
        try { Set-McuThemeBrush -Name ([string]$entry.Key) -Color ([string]$entry.Value) }
        catch { $failures.Add(("{0}: {1}" -f [string]$entry.Key,$_.Exception.Message)) | Out-Null }
    }
    if ($failures.Count -gt 0) {
        Write-McuUiLog -Message ("Theme '{0}' reported {1} brush update failure(s): {2}" -f $normalized,$failures.Count,($failures -join ' | ')) -Level WARN
    }
    $script:State.Theme = $normalized
    if ($script:Ui.ContainsKey('DarkModeCheckBox')) {
        $checkBox = Get-McuUiControl 'DarkModeCheckBox'
        $desired = ($normalized -eq 'Dark')
        if ([bool]$checkBox.IsChecked -ne $desired) { $checkBox.IsChecked = $desired }
    }
    $script:Window.InvalidateVisual()
}

function Get-McuSavedSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default
    )

    foreach ($path in @($script:SettingsPath,$script:ParentConsoleSettingsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $settings = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $property = $settings.PSObject.Properties[$Name]
            if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
        }
        catch {
            if ([string]::Equals($path,$script:SettingsPath,[StringComparison]::OrdinalIgnoreCase)) {
                try { Move-Item -LiteralPath $path -Destination ("$path.corrupt.$(Get-Date -Format 'yyyyMMdd-HHmmss')") -Force -ErrorAction Stop } catch { }
            }
        }
    }
    return $Default
}

function Get-McuSavedTheme {
    [CmdletBinding()]
    param()

    $theme = [string](Get-McuSavedSetting -Name 'Theme' -Default 'Light')
    if ([string]::Equals($theme,'Dark',[StringComparison]::OrdinalIgnoreCase)) { return 'Dark' }
    return 'Light'
}

function Get-McuLogRetentionDays {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    $days = ConvertTo-QOdmLogRetentionDays -Value $Value -Default 30 -Minimum 1 -Maximum 3650
    if ($days -notin @(7,14,30,60,90,180)) { return 30 }
    return $days
}

function Get-McuComboText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Combo)

    if ($null -eq $Combo.SelectedItem) { return [string]$Combo.Text }
    $contentProperty = $Combo.SelectedItem.PSObject.Properties['Content']
    if ($null -ne $contentProperty) { return [string]$contentProperty.Value }
    return [string]$Combo.SelectedItem
}

function Select-McuComboContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Combo,
        [Parameter(Mandatory = $true)][string]$Content
    )

    for ($index = 0; $index -lt $Combo.Items.Count; $index++) {
        $item = $Combo.Items[$index]
        $value = if ($null -ne $item.PSObject.Properties['Content']) { [string]$item.Content } else { [string]$item }
        if ([string]::Equals($value,$Content,[StringComparison]::OrdinalIgnoreCase)) {
            $Combo.SelectedIndex = $index
            return $true
        }
    }
    return $false
}

function Save-McuUiSettings {
    [CmdletBinding()]
    param()

    $days = $script:State.LogRetentionDays
    if ($script:Ui.ContainsKey('UtilityLogRetentionDaysCombo')) {
        $days = Get-McuLogRetentionDays -Value (Get-McuComboText -Combo (Get-McuUiControl 'UtilityLogRetentionDaysCombo'))
    }
    $script:State.LogRetentionDays = $days

    $temporaryPath = Join-Path $script:ConfigPath ('.MappingCollisionUtility.settings.{0}.{1}.tmp' -f $PID,([Guid]::NewGuid().ToString('N')))
    try {
        $payload = [ordered]@{ SchemaVersion=2; Theme=[string]$script:State.Theme; LogRetentionDays=$days }
        [IO.File]::WriteAllText($temporaryPath,($payload | ConvertTo-Json -Depth 3),(New-Object System.Text.UTF8Encoding -ArgumentList $true))
        Move-Item -LiteralPath $temporaryPath -Destination $script:SettingsPath -Force -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

$script:State = [ordered]@{
    Busy                    = $false
    Pending                 = $null
    Result                  = $null
    Collisions              = @()
    MappingCandidates       = @()
    AmbiguousMappings       = @()
    InventoryQualityIssues  = @()
    UnmatchedSourceObjects  = @()
    PromptShown             = $false
    Theme                   = 'Light'
    LogRetentionDays        = 30
}

function Write-McuUiLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    try { Add-Content -LiteralPath $script:SessionLogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    try {
        $box = Get-McuUiControl 'RunLogBox'
        if ([string]::IsNullOrWhiteSpace([string]$box.Text)) { $box.Text = $line } else { $box.AppendText("`r`n$line") }
        $box.ScrollToEnd()
    }
    catch { }
}

function Set-McuLogMaintenanceStatus {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Result,
        [AllowEmptyString()][string]$Fallback = 'Log maintenance has not run.'
    )

    if (-not $script:Ui.ContainsKey('UtilityLogRetentionStatusText')) { return }
    $control = Get-McuUiControl 'UtilityLogRetentionStatusText'
    if ($null -eq $Result) {
        $control.Text = $Fallback
        $control.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'MutedBrush')
        return
    }
    $control.Text = [string]$Result.Summary
    $control.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,$(if ([int]$Result.FailureCount -gt 0) { 'DangerBrush' } else { 'MutedBrush' }))
}

function Invoke-McuLogMaintenanceFromUi {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Retention','ClearHistorical')][string]$Mode)

    if ($script:State.Busy) { Show-McuUiMessage -Text 'Wait for the current analysis to finish before maintaining logs.' -Type Warning; return }
    $days = Get-McuLogRetentionDays -Value (Get-McuComboText -Combo (Get-McuUiControl 'UtilityLogRetentionDaysCombo'))
    if ($Mode -eq 'ClearHistorical') {
        $answer = [Windows.MessageBox]::Show($script:Window,'Delete all prior Mapping Collision Utility session logs? The active session log will be preserved.','Clear stored logs',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    }

    try {
        $result = Invoke-QOdmLogMaintenance -Application MappingCollisionUtility -DataRoot $script:DataRoot -CurrentSessionLogPath $script:SessionLogPath -RetentionDays $days -Mode $Mode
        $script:State.LogRetentionDays = $days
        Set-McuLogMaintenanceStatus -Result $result
        Write-McuUiLog -Message ("Log maintenance completed. {0}" -f $result.Summary) -Level $(if ([int]$result.FailureCount -gt 0) { 'WARN' } else { 'SUCCESS' })
        Save-McuUiSettings
    }
    catch {
        Set-McuLogMaintenanceStatus -Result $null -Fallback ("Log maintenance failed: {0}" -f $_.Exception.Message)
        Write-McuUiLog -Message ("Log maintenance failed: {0}" -f $_.Exception.ToString()) -Level ERROR
        Show-McuUiMessage -Text $_.Exception.Message -Title 'Log maintenance failed' -Type Error
    }
}

function Show-McuUiMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'Mapping Collision Utility',
        [ValidateSet('Info','Warning','Error')][string]$Type = 'Info'
    )

    $icon = switch ($Type) {
        'Warning' { [Windows.MessageBoxImage]::Warning }
        'Error'   { [Windows.MessageBoxImage]::Error }
        default   { [Windows.MessageBoxImage]::Information }
    }
    [void][Windows.MessageBox]::Show($script:Window,$Text,$Title,[Windows.MessageBoxButton]::OK,$icon)
}

function Set-McuUiBranding {
    [CmdletBinding()]
    param()

    $bitmap = New-Object Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = [Uri]::new($script:LogoPath,[UriKind]::Absolute)
    $bitmap.EndInit()
    if ($bitmap.CanFreeze) { $bitmap.Freeze() }
    (Get-McuUiControl 'QuestLogoImage').Source = $bitmap
}

function Set-McuGridItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Grid,
        [AllowNull()][object]$Items
    )
    $Grid.ItemsSource = $null
    $Grid.ItemsSource = @(ConvertTo-McuUiArray -InputObject $Items)
}

function Set-McuComboItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Combo,
        [Parameter(Mandatory = $true)][string[]]$Items,
        [int]$SelectedIndex = 0
    )
    $Combo.ItemsSource = $null
    $Combo.Items.Clear()
    foreach ($item in $Items) { [void]$Combo.Items.Add($item) }
    if ($Combo.Items.Count -gt $SelectedIndex) { $Combo.SelectedIndex = $SelectedIndex }
}

function Browse-McuCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$TargetTextBox)

    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($script:Window)) { $TargetTextBox.Text = $dialog.FileName }
}

function Browse-McuFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$TargetTextBox)

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select a folder'
    $dialog.ShowNewFolderButton = $true
    if (-not [string]::IsNullOrWhiteSpace([string]$TargetTextBox.Text) -and (Test-Path -LiteralPath $TargetTextBox.Text -PathType Container)) { $dialog.SelectedPath = $TargetTextBox.Text }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $TargetTextBox.Text = $dialog.SelectedPath }
    $dialog.Dispose()
}

function Save-McuCollectorScript {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Source','Target')][string]$Side)

    $sourcePath = if ($Side -eq 'Source') { $script:SourceCollectorPath } else { $script:TargetCollectorPath }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'PowerShell scripts (*.ps1)|*.ps1|All files (*.*)|*.*'
    $dialog.FileName = [IO.Path]::GetFileName($sourcePath)
    if ($dialog.ShowDialog($script:Window)) {
        Copy-Item -LiteralPath $sourcePath -Destination $dialog.FileName -Force -ErrorAction Stop
        (Get-McuUiControl 'CollectorStatusText').Text = "$Side collector saved to $($dialog.FileName)"
        Write-McuUiLog -Message "$Side collector exported to $($dialog.FileName)" -Level SUCCESS
    }
}

function Export-McuBothCollectors {
    [CmdletBinding()]
    param()

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the folder that will receive the source and target collector scripts'
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $dialog.Dispose(); return }
    $folder = $dialog.SelectedPath
    $dialog.Dispose()
    $destinations = @(
        [pscustomobject]@{Source=$script:SourceCollectorPath;Destination=(Join-Path $folder ([IO.Path]::GetFileName($script:SourceCollectorPath)))},
        [pscustomobject]@{Source=$script:TargetCollectorPath;Destination=(Join-Path $folder ([IO.Path]::GetFileName($script:TargetCollectorPath)))}
    )
    $existing = @($destinations | Where-Object { Test-Path -LiteralPath $_.Destination -PathType Leaf })
    if ($existing.Count -gt 0) {
        $answer = [Windows.MessageBox]::Show($script:Window,'One or both collector scripts already exist in the selected folder. Replace them?','Replace collector scripts',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning)
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
    }
    foreach ($item in $destinations) { Copy-Item -LiteralPath $item.Source -Destination $item.Destination -Force -ErrorAction Stop }
    (Get-McuUiControl 'CollectorStatusText').Text = "Both collectors saved to $folder"
    Write-McuUiLog -Message "Both collector scripts exported to $folder" -Level SUCCESS
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder.Replace('"','')) -ErrorAction Stop } catch { }
}

function Set-McuUiBusy {
    [CmdletBinding()]
    param(
        [bool]$Busy,
        [AllowEmptyString()][string]$Status = ''
    )

    $script:State.Busy = $Busy
    (Get-McuUiControl 'BusyProgressBar').Visibility = if ($Busy) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    (Get-McuUiControl 'FooterStatusText').Text = if (-not [string]::IsNullOrWhiteSpace($Status)) { $Status } elseif ($Busy) { 'Working…' } else { 'Ready.' }
    foreach ($name in @('AnalyzeButton','LoadSampleDataButton','BrowseSourceCsvButton','BrowseTargetCsvButton','BrowseOutputDirectoryButton','ExportBothCollectorsButton','SaveSourceCollectorButton','SaveTargetCollectorButton','UtilityLogRetentionDaysCombo','OpenUtilityLogsButton','CleanUtilityLogsButton','ClearUtilityStoredLogsButton')) {
        (Get-McuUiControl $name).IsEnabled = -not $Busy
    }
    $script:Window.Cursor = if ($Busy) { [Windows.Input.Cursors]::Wait } else { [Windows.Input.Cursors]::Arrow }
}

function Get-McuActiveView {
    [CmdletBinding()]
    param()

    switch ((Get-McuUiControl 'ResultsTabControl').SelectedIndex) {
        0 { return [pscustomobject]@{Name='Collisions';Rows=$script:State.Collisions;Grid=(Get-McuUiControl 'CollisionsGrid');CategoryProperty='Category'} }
        1 { return [pscustomobject]@{Name='Mapping candidates';Rows=$script:State.MappingCandidates;Grid=(Get-McuUiControl 'MappingCandidatesGrid');CategoryProperty='Disposition'} }
        2 { return [pscustomobject]@{Name='Ambiguous mappings';Rows=$script:State.AmbiguousMappings;Grid=(Get-McuUiControl 'AmbiguousMappingsGrid');CategoryProperty='AmbiguityType'} }
        3 { return [pscustomobject]@{Name='Inventory quality';Rows=$script:State.InventoryQualityIssues;Grid=(Get-McuUiControl 'InventoryQualityGrid');CategoryProperty='Category'} }
        4 { return [pscustomobject]@{Name='Unmatched source';Rows=$script:State.UnmatchedSourceObjects;Grid=(Get-McuUiControl 'UnmatchedSourceGrid');CategoryProperty=''} }
        default { return $null }
    }
}

function Update-McuFilterChoices {
    [CmdletBinding()]
    param()

    $view = Get-McuActiveView
    if ($null -eq $view) { return }
    $rows = @(ConvertTo-McuUiArray -InputObject $view.Rows)
    $statuses = [System.Collections.Generic.List[string]]::new()
    $statuses.Add('All') | Out-Null
    foreach ($row in $rows) {
        foreach ($propertyName in @('Severity','Disposition','Confidence')) {
            $value = [string](Get-McuUiProperty -InputObject $row -Names @($propertyName) -Default '')
            if (-not [string]::IsNullOrWhiteSpace($value) -and -not $statuses.Contains($value)) { $statuses.Add($value) | Out-Null }
        }
    }
    Set-McuComboItems -Combo (Get-McuUiControl 'StatusFilterCombo') -Items $statuses.ToArray()

    $categories = [System.Collections.Generic.List[string]]::new()
    $categories.Add('All') | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($view.CategoryProperty)) {
        foreach ($row in $rows) {
            $value = [string](Get-McuUiProperty -InputObject $row -Names @($view.CategoryProperty) -Default '')
            if (-not [string]::IsNullOrWhiteSpace($value) -and -not $categories.Contains($value)) { $categories.Add($value) | Out-Null }
        }
    }
    Set-McuComboItems -Combo (Get-McuUiControl 'CategoryFilterCombo') -Items $categories.ToArray()
}

function Apply-McuFilters {
    [CmdletBinding()]
    param()

    $view = Get-McuActiveView
    if ($null -eq $view) { return }
    $status = [string](Get-McuUiControl 'StatusFilterCombo').SelectedItem
    $category = [string](Get-McuUiControl 'CategoryFilterCombo').SelectedItem
    $search = ([string](Get-McuUiControl 'SearchFilterBox').Text).Trim()
    $filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($row in (ConvertTo-McuUiArray -InputObject $view.Rows)) {
        $include = $true
        if (-not [string]::IsNullOrWhiteSpace($status) -and $status -ne 'All') {
            $rowStatuses = @(
                [string](Get-McuUiProperty -InputObject $row -Names @('Severity') -Default ''),
                [string](Get-McuUiProperty -InputObject $row -Names @('Disposition') -Default ''),
                [string](Get-McuUiProperty -InputObject $row -Names @('Confidence') -Default '')
            )
            if ($rowStatuses -notcontains $status) { $include = $false }
        }
        if ($include -and -not [string]::IsNullOrWhiteSpace($category) -and $category -ne 'All' -and -not [string]::IsNullOrWhiteSpace($view.CategoryProperty)) {
            $rowCategory = [string](Get-McuUiProperty -InputObject $row -Names @($view.CategoryProperty) -Default '')
            if (-not [string]::Equals($rowCategory,$category,[StringComparison]::OrdinalIgnoreCase)) { $include = $false }
        }
        if ($include -and -not [string]::IsNullOrWhiteSpace($search)) {
            $values = [System.Collections.Generic.List[string]]::new()
            foreach ($property in (ConvertTo-McuUiArray -InputObject $row.PSObject.Properties)) {
                if ($null -ne $property.Value) { $values.Add([string]$property.Value) | Out-Null }
            }
            $haystack = $values.ToArray() -join ' '
            if ($haystack.IndexOf($search,[StringComparison]::OrdinalIgnoreCase) -lt 0) { $include = $false }
        }
        if ($include) { $filtered.Add($row) | Out-Null }
    }
    Set-McuGridItems -Grid $view.Grid -Items $filtered.ToArray()
    (Get-McuUiControl 'FooterStatusText').Text = '{0}: {1:N0} of {2:N0} rows displayed.' -f $view.Name,$filtered.Count,@(ConvertTo-McuUiArray -InputObject $view.Rows).Count
}

function Clear-McuFilters {
    [CmdletBinding()]
    param()

    if ((Get-McuUiControl 'StatusFilterCombo').Items.Count -gt 0) { (Get-McuUiControl 'StatusFilterCombo').SelectedIndex = 0 }
    if ((Get-McuUiControl 'CategoryFilterCombo').Items.Count -gt 0) { (Get-McuUiControl 'CategoryFilterCombo').SelectedIndex = 0 }
    (Get-McuUiControl 'SearchFilterBox').Text = ''
    Apply-McuFilters
}

function ConvertTo-McuCandidateDisplayRows {
    [CmdletBinding()]
    param([AllowNull()][object]$Rows)
    return @((ConvertTo-McuUiArray -InputObject $Rows) | Select-Object CandidateId,Disposition,Confidence,Score,SourceObjectId,SourceDisplayName,SourceUPN,SourceSamAccountName,SourceDirectoryType,TargetObjectId,TargetDisplayName,TargetUPN,TargetSamAccountName,TargetDirectoryType,SourceCandidateCount,TargetClaimCount,HasStrongIdentity,InternalDuplicateEvidence,EvidenceCount,MatchedNamespaces,MatchedValues,Evidence)
}

function Apply-McuAnalysisResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Result)

    $script:State.Result = $Result
    $script:State.Collisions = @(ConvertTo-McuUiArray -InputObject (Get-McuUiProperty -InputObject $Result -Names @('Collisions') -Default @()))
    $script:State.MappingCandidates = @(ConvertTo-McuCandidateDisplayRows -Rows (Get-McuUiProperty -InputObject $Result -Names @('MappingCandidates') -Default @()))
    $script:State.AmbiguousMappings = @(ConvertTo-McuUiArray -InputObject (Get-McuUiProperty -InputObject $Result -Names @('AmbiguousMappings') -Default @()))
    $script:State.InventoryQualityIssues = @(ConvertTo-McuUiArray -InputObject (Get-McuUiProperty -InputObject $Result -Names @('InventoryQualityIssues') -Default @()))
    $script:State.UnmatchedSourceObjects = @(ConvertTo-McuUiArray -InputObject (Get-McuUiProperty -InputObject $Result -Names @('UnmatchedSourceObjects') -Default @()))

    Set-McuGridItems -Grid (Get-McuUiControl 'CollisionsGrid') -Items $script:State.Collisions
    Set-McuGridItems -Grid (Get-McuUiControl 'MappingCandidatesGrid') -Items $script:State.MappingCandidates
    Set-McuGridItems -Grid (Get-McuUiControl 'AmbiguousMappingsGrid') -Items $script:State.AmbiguousMappings
    Set-McuGridItems -Grid (Get-McuUiControl 'InventoryQualityGrid') -Items $script:State.InventoryQualityIssues
    Set-McuGridItems -Grid (Get-McuUiControl 'UnmatchedSourceGrid') -Items $script:State.UnmatchedSourceObjects

    $summary = Get-McuUiProperty -InputObject $Result -Names @('Summary')
    (Get-McuUiControl 'SourceCountText').Text = [string](Get-McuUiProperty -InputObject $summary -Names @('SourceObjectCount') -Default 0)
    (Get-McuUiControl 'TargetCountText').Text = [string](Get-McuUiProperty -InputObject $summary -Names @('TargetObjectCount') -Default 0)
    (Get-McuUiControl 'CriticalCountText').Text = [string](Get-McuUiProperty -InputObject $summary -Names @('CriticalCollisionCount') -Default 0)
    (Get-McuUiControl 'HighCountText').Text = [string](Get-McuUiProperty -InputObject $summary -Names @('HighCollisionCount') -Default 0)
    (Get-McuUiControl 'AmbiguousCountText').Text = [string](Get-McuUiProperty -InputObject $summary -Names @('AmbiguousMappingCount') -Default 0)
    (Get-McuUiControl 'RecommendedCountText').Text = [string](Get-McuUiProperty -InputObject $summary -Names @('RecommendedCount') -Default 0)
    (Get-McuUiControl 'OpenHtmlReportButton').IsEnabled = $true
    (Get-McuUiControl 'OpenOutputFolderButton').IsEnabled = $true
    (Get-McuUiControl 'ResultsTabControl').SelectedIndex = 0
    Update-McuFilterChoices
    Clear-McuFilters

    $runId = [string](Get-McuUiProperty -InputObject $summary -Names @('RunId') -Default '')
    $collisionCount = [string](Get-McuUiProperty -InputObject $summary -Names @('CollisionCount') -Default 0)
    $candidateCount = [string](Get-McuUiProperty -InputObject $summary -Names @('CandidateCount') -Default 0)
    $reports = Get-McuUiProperty -InputObject $Result -Names @('Reports')
    $folder = [string](Get-McuUiProperty -InputObject $reports -Names @('OutputDirectory') -Default '')
    Write-McuUiLog -Message "Analysis $runId completed. Collisions: $collisionCount; candidates: $candidateCount; output: $folder" -Level SUCCESS
}

function Complete-McuAnalysis {
    [CmdletBinding()]
    param()

    $pending = $script:State.Pending
    if ($null -eq $pending -or -not $pending.AsyncResult.IsCompleted) { return }
    try {
        $pending.Timer.Stop()
        $output = @($pending.PowerShell.EndInvoke($pending.AsyncResult))
        $errors = @($pending.PowerShell.Streams.Error)
        if ($output.Count -eq 0) {
            if ($errors.Count -gt 0) { throw (($errors | ForEach-Object { $_.ToString() }) -join "`r`n") }
            throw 'The analysis engine returned no result.'
        }
        $result = $output[-1]
        Apply-McuAnalysisResult -Result $result
        Set-McuUiBusy -Busy $false -Status 'Analysis complete.'
    }
    catch {
        Write-McuUiLog -Message $_.Exception.ToString() -Level ERROR
        Set-McuUiBusy -Busy $false -Status 'Analysis failed.'
        Show-McuUiMessage -Text $_.Exception.Message -Title 'Analysis failed' -Type Error
    }
    finally {
        try { $pending.PowerShell.Dispose() } catch { }
        try { $pending.Runspace.Close() } catch { }
        try { $pending.Runspace.Dispose() } catch { }
        $script:State.Pending = $null
    }
}

function Start-McuAnalysis {
    [CmdletBinding()]
    param()

    if ($script:State.Busy) { return }
    $source = ([string](Get-McuUiControl 'SourceCsvPathBox').Text).Trim()
    $target = ([string](Get-McuUiControl 'TargetCsvPathBox').Text).Trim()
    $output = ([string](Get-McuUiControl 'OutputDirectoryBox').Text).Trim()
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { Show-McuUiMessage -Text 'Select a valid source CSV file.' -Type Warning; return }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { Show-McuUiMessage -Text 'Select a valid target CSV file.' -Type Warning; return }
    if ([string]::IsNullOrWhiteSpace($output)) { $output = $script:ReportsPath; (Get-McuUiControl 'OutputDirectoryBox').Text = $output }
    if (-not (Test-McuUiDirectoryWritable -Path $output)) { Show-McuUiMessage -Text "The report folder is unavailable or not writable: $output" -Type Error; return }

    $options = @{
        CheckInternalDuplicates = [bool](Get-McuUiControl 'CheckInternalDuplicatesCheckBox').IsChecked
        CheckCrossAttribute = [bool](Get-McuUiControl 'CheckCrossAttributeCheckBox').IsChecked
        IncludeEmployeeId = [bool](Get-McuUiControl 'IncludeEmployeeIdCheckBox').IsChecked
        IncludeWeakAliasMatches = [bool](Get-McuUiControl 'IncludeWeakAliasCheckBox').IsChecked
        MaxCandidatePairs = 250000
    }

    $runspace = $null
    $powerShell = $null
    $timer = $null
    try {
        Set-McuUiBusy -Busy $true -Status 'Analyzing source and target identity anchors…'
        Write-McuUiLog -Message "Analysis started. Source: $source; target: $target; report root: $output"
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = [Threading.ApartmentState]::MTA
        $runspace.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $powerShell = [powershell]::Create()
        $powerShell.Runspace = $runspace
        $workerScript = @'
param($ModulePath,$SourcePath,$TargetPath,$OutputPath,$AnalysisOptions)
$ErrorActionPreference = 'Stop'
Import-Module -Name $ModulePath -Force -ErrorAction Stop
Invoke-MappingCollisionAnalysis -SourceCsvPath $SourcePath -TargetCsvPath $TargetPath -OutputDirectory $OutputPath -Options $AnalysisOptions
'@
        $null = $powerShell.AddScript($workerScript)
        $null = $powerShell.AddArgument($script:EngineModulePath)
        $null = $powerShell.AddArgument($source)
        $null = $powerShell.AddArgument($target)
        $null = $powerShell.AddArgument($output)
        $null = $powerShell.AddArgument($options)
        $asyncResult = $powerShell.BeginInvoke()
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $timer.Add_Tick({ Complete-McuAnalysis })
        $script:State.Pending = [pscustomobject]@{PowerShell=$powerShell;Runspace=$runspace;AsyncResult=$asyncResult;Timer=$timer}
        $timer.Start()
    }
    catch {
        try { if ($null -ne $timer) { $timer.Stop() } } catch { }
        try { if ($null -ne $powerShell) { $powerShell.Dispose() } } catch { }
        try { if ($null -ne $runspace) { $runspace.Close() } } catch { }
        try { if ($null -ne $runspace) { $runspace.Dispose() } } catch { }
        $script:State.Pending = $null
        Set-McuUiBusy -Busy $false -Status 'Analysis could not start.'
        Write-McuUiLog -Message $_.Exception.ToString() -Level ERROR
        Show-McuUiMessage -Text $_.Exception.Message -Title 'Analysis could not start' -Type Error
    }
}

function Open-McuReport {
    [CmdletBinding()]
    param([ValidateSet('Html','Folder')][string]$Type)

    if ($null -eq $script:State.Result) { return }
    $reports = Get-McuUiProperty -InputObject $script:State.Result -Names @('Reports')
    $path = if ($Type -eq 'Html') { [string](Get-McuUiProperty -InputObject $reports -Names @('HtmlSummary') -Default '') } else { [string](Get-McuUiProperty -InputObject $reports -Names @('OutputDirectory') -Default '') }
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { Show-McuUiMessage -Text "The requested report path is unavailable: $path" -Type Warning; return }
    if ($Type -eq 'Folder') { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $path.Replace('"','')) -ErrorAction Stop }
    else { Start-Process -FilePath $path -ErrorAction Stop }
}

$script:State.LogRetentionDays = Get-McuLogRetentionDays -Value (Get-McuSavedSetting -Name 'LogRetentionDays' -Default 30)
Set-McuTheme -Theme (Get-McuSavedTheme)
Select-McuComboContent -Combo (Get-McuUiControl 'UtilityLogRetentionDaysCombo') -Content ([string]$script:State.LogRetentionDays) | Out-Null
try {
    $startupLogMaintenance = Invoke-QOdmLogMaintenance -Application MappingCollisionUtility -DataRoot $script:DataRoot -CurrentSessionLogPath $script:SessionLogPath -RetentionDays $script:State.LogRetentionDays -Mode Retention
    Set-McuLogMaintenanceStatus -Result $startupLogMaintenance
    if ([int]$startupLogMaintenance.DeletedFileCount -gt 0 -or [int]$startupLogMaintenance.FailureCount -gt 0) {
        Write-McuUiLog -Message ("Startup log retention completed. {0}" -f $startupLogMaintenance.Summary) -Level $(if ([int]$startupLogMaintenance.FailureCount -gt 0) { 'WARN' } else { 'SUCCESS' })
    }
}
catch {
    Set-McuLogMaintenanceStatus -Result $null -Fallback ("Startup log retention failed: {0}" -f $_.Exception.Message)
    Write-McuUiLog -Message ("Startup log retention failed: {0}" -f $_.Exception.Message) -Level WARN
}
Set-McuUiBranding
(Get-McuUiControl 'OutputDirectoryBox').Text = $script:ReportsPath
Set-McuComboItems -Combo (Get-McuUiControl 'StatusFilterCombo') -Items @('All')
Set-McuComboItems -Combo (Get-McuUiControl 'CategoryFilterCombo') -Items @('All')

(Get-McuUiControl 'DarkModeCheckBox').Add_Checked({
    if ($script:State.Theme -ne 'Dark') {
        Set-McuTheme -Theme 'Dark'
        Save-McuUiSettings
        Write-McuUiLog -Message 'Dark mode enabled.' -Level SUCCESS
    }
})
(Get-McuUiControl 'DarkModeCheckBox').Add_Unchecked({
    if ($script:State.Theme -ne 'Light') {
        Set-McuTheme -Theme 'Light'
        Save-McuUiSettings
        Write-McuUiLog -Message 'Light mode enabled.' -Level SUCCESS
    }
})

(Get-McuUiControl 'OpenUtilityLogsButton').Add_Click({ try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:LogsPath.Replace('"','')) -ErrorAction Stop } catch { Show-McuUiMessage -Text $_.Exception.Message -Type Error } })
(Get-McuUiControl 'CleanUtilityLogsButton').Add_Click({ Invoke-McuLogMaintenanceFromUi -Mode Retention })
(Get-McuUiControl 'ClearUtilityStoredLogsButton').Add_Click({ Invoke-McuLogMaintenanceFromUi -Mode ClearHistorical })
(Get-McuUiControl 'ClearRunLogViewButton').Add_Click({ (Get-McuUiControl 'RunLogBox').Clear() })

(Get-McuUiControl 'ExportBothCollectorsButton').Add_Click({ try { Export-McuBothCollectors } catch { Write-McuUiLog -Message $_.Exception.ToString() -Level ERROR; Show-McuUiMessage -Text $_.Exception.Message -Type Error } })
(Get-McuUiControl 'SaveSourceCollectorButton').Add_Click({ try { Save-McuCollectorScript -Side Source } catch { Write-McuUiLog -Message $_.Exception.ToString() -Level ERROR; Show-McuUiMessage -Text $_.Exception.Message -Type Error } })
(Get-McuUiControl 'SaveTargetCollectorButton').Add_Click({ try { Save-McuCollectorScript -Side Target } catch { Write-McuUiLog -Message $_.Exception.ToString() -Level ERROR; Show-McuUiMessage -Text $_.Exception.Message -Type Error } })
(Get-McuUiControl 'OpenCollectorFolderButton').Add_Click({ try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:CollectorsPath.Replace('"','')) -ErrorAction Stop } catch { Show-McuUiMessage -Text $_.Exception.Message -Type Error } })
(Get-McuUiControl 'BrowseSourceCsvButton').Add_Click({ Browse-McuCsv -TargetTextBox (Get-McuUiControl 'SourceCsvPathBox') })
(Get-McuUiControl 'BrowseTargetCsvButton').Add_Click({ Browse-McuCsv -TargetTextBox (Get-McuUiControl 'TargetCsvPathBox') })
(Get-McuUiControl 'BrowseOutputDirectoryButton').Add_Click({ Browse-McuFolder -TargetTextBox (Get-McuUiControl 'OutputDirectoryBox') })
(Get-McuUiControl 'LoadSampleDataButton').Add_Click({
    (Get-McuUiControl 'SourceCsvPathBox').Text = $script:SampleSourcePath
    (Get-McuUiControl 'TargetCsvPathBox').Text = $script:SampleTargetPath
    (Get-McuUiControl 'OutputDirectoryBox').Text = $script:ReportsPath
    Write-McuUiLog -Message 'Packaged sample source and target inventories loaded.'
})
(Get-McuUiControl 'AnalyzeButton').Add_Click({ Start-McuAnalysis })
(Get-McuUiControl 'ApplyFilterButton').Add_Click({ Apply-McuFilters })
(Get-McuUiControl 'ClearFilterButton').Add_Click({ Clear-McuFilters })
(Get-McuUiControl 'ResultsTabControl').Add_SelectionChanged({
    param($sender,$eventArgs)
    if ($script:State.Busy -or $eventArgs.OriginalSource -ne $sender) { return }
    Update-McuFilterChoices
    Clear-McuFilters
})
(Get-McuUiControl 'OpenHtmlReportButton').Add_Click({ try { Open-McuReport -Type Html } catch { Show-McuUiMessage -Text $_.Exception.Message -Type Error } })
(Get-McuUiControl 'OpenOutputFolderButton').Add_Click({ try { Open-McuReport -Type Folder } catch { Show-McuUiMessage -Text $_.Exception.Message -Type Error } })

$script:Window.Add_ContentRendered({
    if ($script:State.PromptShown) { return }
    $script:State.PromptShown = $true
    Write-McuUiLog -Message "Utility started. Data root: $script:DataRoot"
    $answer = [Windows.MessageBox]::Show($script:Window,'The workflow starts by running one collector in the source environment and one in the target environment. Export both collector scripts now?','Export collector scripts',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question)
    if ($answer -eq [Windows.MessageBoxResult]::Yes) {
        try { Export-McuBothCollectors } catch { Write-McuUiLog -Message $_.Exception.ToString() -Level ERROR; Show-McuUiMessage -Text $_.Exception.Message -Type Error }
    }
})

$script:Window.Add_Closing({
    try { Save-McuUiSettings } catch { Write-McuUiLog -Message "Utility settings could not be saved: $($_.Exception.Message)" -Level WARN }
    if ($null -ne $script:State.Pending) {
        try { $script:State.Pending.Timer.Stop() } catch { }
        try { $script:State.Pending.PowerShell.Stop() } catch { }
        try { $script:State.Pending.PowerShell.Dispose() } catch { }
        try { $script:State.Pending.Runspace.Close() } catch { }
        try { $script:State.Pending.Runspace.Dispose() } catch { }
        $script:State.Pending = $null
    }
})

[void]$script:Window.ShowDialog()
