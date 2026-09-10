[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$DataRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-UiObjectArray {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    $result = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $InputObject) { return ,$result.ToArray() }

    $value = $InputObject
    try {
        if ($InputObject -is [System.Management.Automation.PSObject] -and $null -ne $InputObject.BaseObject) {
            $value = $InputObject.BaseObject
        }
    }
    catch { $value = $InputObject }

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

$env:QUESTODMCONSOLE_UI_PHASE = 'Loading WPF assemblies'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function Test-UiDirectoryWritable {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$Create = $true
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            if (-not $Create) { return $false }
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        if (-not (Get-Item -LiteralPath $Path -ErrorAction Stop).PSIsContainer) { return $false }
        $probe = Join-Path $Path ('.write-test-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
        [IO.File]::WriteAllText($probe, 'test', (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

function Resolve-UiDataRoot {
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

    foreach ($candidate in (ConvertTo-UiObjectArray -InputObject ($candidates.ToArray() | Select-Object -Unique))) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try { $fullPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$candidate)) }
        catch { continue }
        if (Test-UiDirectoryWritable -Path $fullPath -Create $true) { return $fullPath }
    }

    if ($explicit) { throw "The requested data root is unavailable or not writable: $RequestedPath" }
    throw 'A writable per-user data directory could not be created. Set QUESTODMCONSOLE_DATA_ROOT to a writable local folder.'
}

$env:QUESTODMCONSOLE_UI_PHASE = 'Resolving application paths and writable data directories'
$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:EngineModulePath = Join-Path $script:AppRoot 'Engine\QuestODMConsole.Engine.psm1'
$script:XamlPath = Join-Path $script:AppRoot 'Resources\QuestODMConsole.xaml'
$script:DefaultSettingsPath = Join-Path $script:AppRoot 'Config\QuestODMConsole.settings.json'
$script:LogMaintenancePath = Join-Path $script:AppRoot 'Shared\LogMaintenance.ps1'
$script:MappingCollisionUtilityRoot = Join-Path $script:AppRoot 'MappingCollisionUtility'
$script:MappingCollisionUtilityBootstrapPath = Join-Path $script:MappingCollisionUtilityRoot 'MappingCollisionUtility.ps1'
$script:MappingCollisionUtilityXamlPath = Join-Path $script:MappingCollisionUtilityRoot 'Resources\MappingCollisionUtility.xaml'
$script:MappingCollisionUtilityEnginePath = Join-Path $script:MappingCollisionUtilityRoot 'Engine\MappingCollisionEngine.psm1'
$script:DataRoot = Resolve-UiDataRoot -RequestedPath $DataRoot
$env:QUESTODMCONSOLE_DATA_ROOT = $script:DataRoot
$script:ConfigPath = Join-Path $script:DataRoot 'Config'
$script:LogsPath = Join-Path $script:DataRoot 'Logs'
$script:ReportsPath = Join-Path $script:DataRoot 'Reports'
foreach ($directory in @($script:ConfigPath, $script:LogsPath, $script:ReportsPath)) {
    if (-not (Test-UiDirectoryWritable -Path $directory -Create $true)) {
        throw "The application data directory is unavailable or not writable: $directory"
    }
}
$script:SettingsPath = Join-Path $script:ConfigPath 'QuestODMConsole.settings.json'
$script:ProfilesPath = Join-Path $script:ConfigPath 'QuestODMConsole.profiles.json'
$script:OperationHistoryPath = Join-Path $script:LogsPath 'OperationHistory.jsonl'

if (-not (Test-Path -LiteralPath $script:EngineModulePath)) { throw "Engine module not found: $script:EngineModulePath" }
if (-not (Test-Path -LiteralPath $script:XamlPath)) { throw "XAML file not found: $script:XamlPath" }
if (-not (Test-Path -LiteralPath $script:LogMaintenancePath -PathType Leaf)) { throw "Log-maintenance helper not found: $script:LogMaintenancePath" }
. $script:LogMaintenancePath
$script:SessionLogPath = Join-Path $script:LogsPath ("QuestODMConsole_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$env:QUESTODMCONSOLE_UI_PHASE = 'Loading XAML and constructing WPF controls'
[xml]$xaml = Get-Content -LiteralPath $script:XamlPath -Raw
$reader = $null
try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $script:Window = [Windows.Markup.XamlReader]::Load($reader)
    if ($null -eq $script:Window) { throw 'The WPF XAML loader returned no window object.' }
}
finally {
    if ($null -ne $reader) { $reader.Dispose() }
}

$script:Ui = @{}
$nameMatches = [regex]::Matches((Get-Content -LiteralPath $script:XamlPath -Raw), 'x:Name="([A-Za-z_][A-Za-z0-9_]*)"')
foreach ($match in $nameMatches) {
    $name = $match.Groups[1].Value
    $control = $script:Window.FindName($name)
    if ($null -ne $control) { $script:Ui[$name] = $control }
}

function Get-UiControl {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:Ui.ContainsKey($Name)) { throw "UI control '$Name' was not found in the XAML." }
    return $script:Ui[$Name]
}

function Set-UiBrandAssets {
    [CmdletBinding()]
    param()

    $logoPath = Join-Path -Path $script:AppRoot -ChildPath 'Resources\QuestSoftwareLogo.png'
    if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf)) {
        throw "The Quest Software logo asset was not found: $logoPath"
    }

    $bitmap = New-Object Windows.Media.Imaging.BitmapImage
    try {
        $bitmap.BeginInit()
        $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat
        $bitmap.UriSource = [Uri]::new($logoPath, [UriKind]::Absolute)
        $bitmap.EndInit()
        if ($bitmap.CanFreeze) { $bitmap.Freeze() }
        (Get-UiControl 'QuestLogoImage').Source = $bitmap
    }
    catch {
        throw "The Quest Software logo could not be loaded from '$logoPath': $($_.Exception.Message)"
    }
}



function Get-Brush {
    param([Parameter(Mandatory = $true)][string]$Color)
    return (New-Object Windows.Media.BrushConverter).ConvertFromString($Color)
}

function Get-UiResourceBrush {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $brush = $script:Window.Resources[$Name]
    if ($null -eq $brush -or $brush -isnot [Windows.Media.SolidColorBrush]) {
        throw "Theme brush '$Name' was not found in the main window resources."
    }
    return $brush
}

function Set-UiThemeBrush {
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

    # The XAML explicitly marks theme brushes as unfrozen. This fallback protects
    # hosts that still freeze a resource and avoids PowerShell's ResourceDictionary
    # indexer conversion path, which caused Preview 3 to pass a brush as text.
    $replacement = $brush.CloneCurrentValue()
    $replacement.Color = $converted
    $resources = [System.Collections.IDictionary]$script:Window.Resources
    if ($resources.Contains($Name)) { $resources.Remove($Name) }
    $resources.Add($Name,[object]$replacement)
}

function Get-UiThemePalette {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Light','Dark')][string]$Theme)

    if ($Theme -eq 'Dark') {
        return [ordered]@{
            PrimaryBrush          = '#4B68A3'
            PrimaryDarkBrush      = '#38558E'
            MetricValueBrush      = '#8FAAE6'
            AccentBrush           = '#57BBD4'
            AccentLightBrush      = '#183743'
            AccentTextBrush       = '#102A34'
            OnPrimaryBrush        = '#FFFFFF'
            SurfaceBrush          = '#18212D'
            InputSurfaceBrush     = '#202A38'
            BackgroundBrush       = '#101720'
            SubtleSurfaceBrush    = '#1E2835'
            StatusSurfaceBrush    = '#202A37'
            BorderBrush           = '#39475A'
            TextBrush             = '#E7ECF4'
            HeadingBrush          = '#F5F7FB'
            MutedBrush            = '#AEB9CA'
            GridLineBrush         = '#334153'
            GridAlternateBrush    = '#1D2734'
            GridHeaderBrush       = '#243041'
            GridHeaderTextBrush   = '#DCE4F0'
            SelectionBrush        = '#345D84'
            SelectionTextBrush    = '#FFFFFF'
            DangerBrush           = '#C34A52'
            DangerLightBrush      = '#3A2228'
            DangerBorderBrush     = '#7F454D'
            DangerTextBrush       = '#FFB5B5'
            SuccessBrush          = '#67D39E'
            SuccessLightBrush     = '#17382A'
            WarningBrush          = '#E6AF59'
            WarningLightBrush     = '#3B301C'
            WarningBorderBrush    = '#7A6337'
            WarningTextBrush      = '#FFD28B'
            NeutralDotBrush       = '#8D99AD'
        }
    }

    return [ordered]@{
        PrimaryBrush          = '#3D5B96'
        PrimaryDarkBrush      = '#2E4778'
        MetricValueBrush      = '#2E4778'
        AccentBrush           = '#62C0DA'
        AccentLightBrush      = '#E8F7FB'
        AccentTextBrush       = '#17384A'
        OnPrimaryBrush        = '#FFFFFF'
        SurfaceBrush          = '#FFFFFF'
        InputSurfaceBrush     = '#FFFFFF'
        BackgroundBrush       = '#F6FBFE'
        SubtleSurfaceBrush    = '#F7F9FC'
        StatusSurfaceBrush    = '#F1F3F7'
        BorderBrush           = '#D0D8E5'
        TextBrush             = '#273142'
        HeadingBrush          = '#253148'
        MutedBrush            = '#657086'
        GridLineBrush         = '#E8ECF2'
        GridAlternateBrush    = '#F8FAFD'
        GridHeaderBrush       = '#EDF2F8'
        GridHeaderTextBrush   = '#39465A'
        SelectionBrush        = '#DCE9F8'
        SelectionTextBrush    = '#17233A'
        DangerBrush           = '#B54343'
        DangerLightBrush      = '#FBECEC'
        DangerBorderBrush     = '#D78484'
        DangerTextBrush       = '#9B2E2E'
        SuccessBrush          = '#2E7D5B'
        SuccessLightBrush     = '#EAF6F0'
        WarningBrush          = '#A86B18'
        WarningLightBrush     = '#FFF5DF'
        WarningBorderBrush    = '#E3B76A'
        WarningTextBrush      = '#8A5510'
        NeutralDotBrush       = '#7A8496'
    }
}

function Set-UiTheme {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Theme)

    $normalized = if ([string]::Equals($Theme,'Dark',[StringComparison]::OrdinalIgnoreCase)) { 'Dark' } else { 'Light' }
    $palette = Get-UiThemePalette -Theme $normalized
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $palette.GetEnumerator()) {
        try { Set-UiThemeBrush -Name ([string]$entry.Key) -Color ([string]$entry.Value) }
        catch { $failures.Add(("{0}: {1}" -f [string]$entry.Key,$_.Exception.Message)) | Out-Null }
    }

    # A theme failure must never prevent the console from opening. The XAML light
    # palette remains the safe visual fallback and the exact failures are logged.
    if ($failures.Count -gt 0) {
        Write-UiLog -Message ("Theme '{0}' reported {1} brush update failure(s): {2}" -f $normalized,$failures.Count,($failures -join ' | ')) -Level WARN
    }

    $script:State.Theme = $normalized
    if ($script:Ui.ContainsKey('DarkModeCheckBox')) {
        $checkBox = Get-UiControl 'DarkModeCheckBox'
        $desired = ($normalized -eq 'Dark')
        if ([bool]$checkBox.IsChecked -ne $desired) { $checkBox.IsChecked = $desired }
    }
    $script:Window.InvalidateVisual()
}

function Set-UiResourceReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Control,
        [Parameter(Mandatory = $true)][Windows.DependencyProperty]$Property,
        [Parameter(Mandatory = $true)][string]$ResourceKey
    )
    $Control.SetResourceReference($Property,$ResourceKey)
}

$script:State = [ordered]@{
    Connected        = $false
    WorkloadSelected = $false
    Busy             = $false
    Pending          = $null
    WorkerRunspace   = $null
    WorkerTimer      = $null
    WorkerModulePreload = $null
    TaskItems        = @()
    CollectionItems  = @()
    TemplateItems    = @()
    OperationCatalog = @()
    Context          = $null
    Settings         = $null
    ModuleStatusKnown = $false
    ModuleInstalled   = $false
    ModuleUpdateAvailable = $false
    ModuleCanInstall  = $false
    ModuleOnlineChecked = $false
    ModuleStatus      = $null
    OverviewSnapshot  = $null
    OverviewStatusText = 'No workspace refresh has run.'
    SafeMode         = $true
    SafeModeReason   = 'Safe Mode enabled at startup.'
    LastReadiness    = $null
    ReadinessHtmlPath = $null
    ReadinessJsonPath = $null
    TaskDetails      = $null
    TaskDetailsTimer = $null
    BuildInfo        = $null
    Profiles         = @()
    LastErrorDetails = $null
    BlockedFeatures  = @()
    PreferredProjectId = $null
    PreferredWorkloadId = $null
    Theme            = 'Light'
    LogRetentionDays = 30
    ProfileLoadContext = $null
    OdmApiModuleActionContext = $null
    BulkUiContext    = $null
}

function Write-UiLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:SessionLogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    try {
        if ($null -ne $script:Ui -and $script:Ui.ContainsKey('DiagnosticsLogBox')) {
            $logBox = $script:Ui['DiagnosticsLogBox']
            if ($null -ne $logBox) {
                if ([string]::IsNullOrEmpty([string]$logBox.Text)) { $logBox.Text = $line }
                else { $logBox.AppendText("`r`n$line") }
                $logBox.ScrollToEnd()
            }
        }
    }
    catch { }
}

function Get-UiLogRetentionDays {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    $days = ConvertTo-QOdmLogRetentionDays -Value $Value -Default 30 -Minimum 1 -Maximum 3650
    if ($days -notin @(7,14,30,60,90,180)) { return 30 }
    return $days
}

function Set-UiLogMaintenanceStatus {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Result,
        [AllowEmptyString()][string]$Fallback = 'Log maintenance has not run.'
    )

    if (-not $script:Ui.ContainsKey('LogRetentionStatusText')) { return }
    $control = Get-UiControl 'LogRetentionStatusText'
    if ($null -eq $Result) {
        $control.Text = $Fallback
        Set-UiResourceReference -Control $control -Property ([Windows.Controls.TextBlock]::ForegroundProperty) -ResourceKey 'MutedBrush'
        return
    }

    $control.Text = [string]$Result.Summary
    $resource = if ([int]$Result.FailureCount -gt 0) { 'DangerTextBrush' } else { 'MutedBrush' }
    Set-UiResourceReference -Control $control -Property ([Windows.Controls.TextBlock]::ForegroundProperty) -ResourceKey $resource
}

function Invoke-UiLogMaintenanceFromUi {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Retention','ClearHistorical')][string]$Mode)

    if ($script:State.Busy) { Show-UiMessage -Text 'Wait for the current operation to finish before maintaining logs.' -Type Warning; return }
    $days = Get-UiLogRetentionDays -Value (Get-ComboText (Get-UiControl 'LogRetentionDaysCombo'))
    if ($Mode -eq 'ClearHistorical') {
        $confirmation = "Delete prior console session logs and clear stored bootstrap and operation-history data?`r`n`r`nThe active session log will be preserved. Mapping Collision Utility logs are maintained from that utility."
        if (-not (Confirm-UiAction -Text $confirmation -Title 'Clear stored logs')) { return }
    }

    try {
        $result = Invoke-QOdmLogMaintenance -Application MainConsole -DataRoot $script:DataRoot -CurrentSessionLogPath $script:SessionLogPath -RetentionDays $days -Mode $Mode
        $script:State.LogRetentionDays = $days
        Set-UiLogMaintenanceStatus -Result $result
        Write-UiLog -Message ("Log maintenance completed. {0}" -f $result.Summary) -Level $(if ([int]$result.FailureCount -gt 0) { 'WARN' } else { 'SUCCESS' })
        if ($Mode -eq 'ClearHistorical') { Set-GridItems -Grid (Get-UiControl 'OperationHistoryGrid') -Items @() }
        Update-UiEnablement
    }
    catch {
        Set-UiLogMaintenanceStatus -Result $null -Fallback ("Log maintenance failed: {0}" -f $_.Exception.Message)
        Write-UiLog -Message ("Log maintenance failed: {0}" -f $_.Exception.ToString()) -Level ERROR
        Show-UiMessage -Text $_.Exception.Message -Title 'Log maintenance failed' -Type Error
    }
}

function Show-UiMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'Quest ODM Operations Console',
        [ValidateSet('Info', 'Warning', 'Error')][string]$Type = 'Info'
    )

    if ($Type -eq 'Error') {
        $script:State.LastErrorDetails = $Text
        Show-UiErrorDialog -Text $Text -Title $Title
        return
    }
    $icon = if ($Type -eq 'Warning') { [Windows.MessageBoxImage]::Warning } else { [Windows.MessageBoxImage]::Information }
    [void][Windows.MessageBox]::Show($script:Window, $Text, $Title, [Windows.MessageBoxButton]::OK, $icon)
}


function New-UiEmergencySupportBundle {
    [CmdletBinding()]
    param([AllowNull()][string]$ErrorText)

    $bundle = Join-Path $script:ReportsPath ("QuestODMConsole_EmergencySupport_{0}.zip" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("QuestODMConsole-Emergency-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -Path $temp -ItemType Directory -Force -ErrorAction Stop | Out-Null
    try {
        if (Test-Path -LiteralPath $script:SessionLogPath -PathType Leaf) { Copy-Item -LiteralPath $script:SessionLogPath -Destination $temp -Force }
        if (-not [string]::IsNullOrWhiteSpace($ErrorText)) { $ErrorText | Set-Content -LiteralPath (Join-Path $temp 'Error.txt') -Encoding UTF8 }
        @"
Created: $(Get-Date -Format o)
Console: 1.1.0-preview.6
PowerShell: $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)
Process bitness: $([Environment]::Is64BitProcess)
Data root: $script:DataRoot
Session log: $script:SessionLogPath
This emergency bundle excludes access tokens, credentials, cookies, and authentication artifacts.
"@ | Set-Content -LiteralPath (Join-Path $temp 'Environment.txt') -Encoding UTF8
        if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
            try {
                $settings = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $safe = [ordered]@{}
                foreach ($property in (ConvertTo-UiObjectArray -InputObject $settings.PSObject.Properties)) {
                    $name = [string]$property.Name
                    if ($name -match '(?i)(token|secret|password|credential|cookie|authorization)') { $safe[$name] = '<redacted>' }
                    else { $safe[$name] = $property.Value }
                }
                [pscustomobject]$safe | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $temp 'Settings.redacted.json') -Encoding UTF8
            }
            catch { }
        }
        if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Force }
        if (Get-Command -Name 'Compress-Archive' -ErrorAction SilentlyContinue) {
            Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $bundle -CompressionLevel Optimal -Force -ErrorAction Stop
        }
        else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::CreateFromDirectory($temp,$bundle,[System.IO.Compression.CompressionLevel]::Optimal,$false)
        }
        return $bundle
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } }
}

function Show-UiErrorDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'Quest ODM Operations Console error'
    )

    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Owner = $script:Window
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dialog.Width = 820
    $dialog.Height = 520
    $dialog.MinWidth = 620
    $dialog.MinHeight = 380
    $dialog.Background = Get-UiResourceBrush -Name 'BackgroundBrush'
    $dialog.Foreground = Get-UiResourceBrush -Name 'TextBrush'
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '16'
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='Auto'}))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='*'}))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{Height='Auto'}))
    $heading = New-Object Windows.Controls.TextBlock
    $heading.Text = 'The operation could not be completed.'
    $heading.FontSize = 18
    $heading.FontWeight = 'SemiBold'
    $heading.Foreground = Get-UiResourceBrush -Name 'DangerBrush'
    [Windows.Controls.Grid]::SetRow($heading,0)
    $box = New-Object Windows.Controls.TextBox
    $box.Text = $Text
    $box.IsReadOnly = $true
    $box.AcceptsReturn = $true
    $box.TextWrapping = 'Wrap'
    $box.VerticalScrollBarVisibility = 'Auto'
    $box.HorizontalScrollBarVisibility = 'Auto'
    $box.FontFamily = 'Consolas'
    $box.Margin = '0,12,0,12'
    $box.Background = Get-UiResourceBrush -Name 'InputSurfaceBrush'
    $box.Foreground = Get-UiResourceBrush -Name 'TextBrush'
    $box.BorderBrush = Get-UiResourceBrush -Name 'BorderBrush'
    [Windows.Controls.Grid]::SetRow($box,1)
    $buttons = New-Object Windows.Controls.WrapPanel
    $buttons.HorizontalAlignment = 'Right'
    [Windows.Controls.Grid]::SetRow($buttons,2)
    foreach ($spec in @(
        [pscustomobject]@{Text='Copy details';Action='Copy'},
        [pscustomobject]@{Text='Open logs';Action='Logs'},
        [pscustomobject]@{Text='Create support bundle';Action='Bundle'},
        [pscustomobject]@{Text='Support tools';Action='Tools'},
        [pscustomobject]@{Text='Close';Action='Close'}
    )) {
        $button = New-Object Windows.Controls.Button
        $button.Content = $spec.Text
        $button.MinWidth = 105
        $button.Margin = '4,0,0,0'
        $action = [string]$spec.Action
        if ($action -eq 'Close') {
            $button.Background = Get-UiResourceBrush -Name 'PrimaryBrush'
            $button.Foreground = Get-UiResourceBrush -Name 'OnPrimaryBrush'
            $button.BorderBrush = Get-UiResourceBrush -Name 'PrimaryBrush'
        }
        else {
            $button.Background = Get-UiResourceBrush -Name 'SurfaceBrush'
            $button.Foreground = Get-UiResourceBrush -Name 'MetricValueBrush'
            $button.BorderBrush = Get-UiResourceBrush -Name 'MetricValueBrush'
        }
        $button.Padding = '10,5'
        $button.Tag = [pscustomobject]@{ Action = $action; ErrorText = $Text; Dialog = $dialog }
        $button.Add_Click({
            param($sender,$eventArgs)
            $context = if ($null -ne $sender) { $sender.Tag } else { $null }
            $buttonAction = [string](Get-ObjectPropertyValue -InputObject $context -Names @('Action'))
            $errorText = [string](Get-ObjectPropertyValue -InputObject $context -Names @('ErrorText'))
            $ownerDialog = Get-ObjectPropertyValue -InputObject $context -Names @('Dialog')
            try {
                switch ($buttonAction) {
                    'Copy' { [Windows.Clipboard]::SetText($errorText) }
                    'Logs' { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:LogsPath.Replace('"','')) -ErrorAction Stop }
                    'Bundle' {
                        $path = New-UiEmergencySupportBundle -ErrorText $errorText
                        [Windows.Clipboard]::SetText($path)
                        [void][Windows.MessageBox]::Show($ownerDialog,"Emergency support bundle created:`r`n$path`r`n`r`nThe path was copied to the clipboard.",'Support bundle',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Information)
                    }
                    'Tools' { $ownerDialog.Close(); $null = Select-MainTabByHeader -Header 'Diagnostics' }
                    'Close' { $ownerDialog.Close() }
                    default { throw "Unknown support action: $buttonAction" }
                }
            }
            catch { [void][Windows.MessageBox]::Show($ownerDialog,$_.Exception.Message,'Support action failed',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning) }
        })
        $buttons.Children.Add($button) | Out-Null
    }
    $grid.Children.Add($heading) | Out-Null
    $grid.Children.Add($box) | Out-Null
    $grid.Children.Add($buttons) | Out-Null
    $dialog.Content = $grid
    [void]$dialog.ShowDialog()
}

function Confirm-UiAction {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'Confirm operation'
    )

    $answer = [Windows.MessageBox]::Show($script:Window, $Text, $Title, [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning)
    return ($answer -eq [Windows.MessageBoxResult]::Yes)
}

function Get-SettingValue {
    param([Parameter(Mandatory = $true)][string]$Name, [AllowNull()][object]$Default)
    if ($null -ne $script:State.Settings) {
        $property = $script:State.Settings.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function Merge-UiSettingsObject {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Target,
        [AllowNull()][object]$Source
    )

    if ($null -eq $Source) { return }
    foreach ($property in (ConvertTo-UiObjectArray -InputObject $Source.PSObject.Properties)) {
        $Target[[string]$property.Name] = $property.Value
    }
}

function Load-UiSettings {
    $merged = [ordered]@{}

    if (Test-Path -LiteralPath $script:DefaultSettingsPath) {
        try {
            $defaults = Get-Content -LiteralPath $script:DefaultSettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            Merge-UiSettingsObject -Target $merged -Source $defaults
        }
        catch {
            Write-UiLog -Message "Packaged defaults could not be read: $($_.Exception.Message)" -Level WARN
        }
    }

    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $userSettings = Get-Content -LiteralPath $script:SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            Merge-UiSettingsObject -Target $merged -Source $userSettings
        }
        catch {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $corruptPath = '{0}.corrupt.{1}' -f $script:SettingsPath, $stamp
            try {
                Move-Item -LiteralPath $script:SettingsPath -Destination $corruptPath -Force -ErrorAction Stop
                Write-UiLog -Message "Malformed user settings were moved to: $corruptPath" -Level WARN
            }
            catch {
                Write-UiLog -Message "Malformed user settings were ignored and could not be renamed: $($_.Exception.Message)" -Level WARN
            }
        }
    }

    $script:State.Settings = [pscustomobject]$merged
}

function Get-UiReportDirectory {
    param([AllowEmptyString()][string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $script:ReportsPath }
    try { return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Candidate.Trim())) }
    catch { throw "The report directory is not a valid path: $Candidate" }
}

function Test-UiPathEqual {
    param(
        [AllowEmptyString()][string]$Left,
        [AllowEmptyString()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    try {
        $trimCharacters = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $leftPath = [IO.Path]::GetFullPath($Left).TrimEnd($trimCharacters)
        $rightPath = [IO.Path]::GetFullPath($Right).TrimEnd($trimCharacters)
        return [string]::Equals($leftPath, $rightPath, [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Save-UiSettings {
    $temporaryPath = $null
    try {
        $region = Get-ComboText (Get-UiControl 'RegionCombo')
        $selectedReportDirectory = Get-UiReportDirectory -Candidate ([string](Get-UiControl 'FactoryOutputDirectoryBox').Text)
        $reportSetting = $selectedReportDirectory
        if (Test-UiPathEqual -Left $selectedReportDirectory -Right $script:ReportsPath) {
            $reportSetting = ''
        }

        $settings = [ordered]@{
            Region                    = $region
            ReportDirectory           = $reportSetting
            NotifyRecipients          = [string](Get-UiControl 'FactoryNotifyRecipientsBox').Text
            LastOrganizationId        = [string](Get-UiControl 'OrganizationIdBox').Text
            MailFrom                  = if ((Get-UiControl 'FactoryMailFromPicker').SelectedDate) { (Get-UiControl 'FactoryMailFromPicker').SelectedDate.ToString('yyyy-MM-dd') } else { '2025-11-01' }
            OneDriveFilterItems       = Get-ComboText (Get-UiControl 'FactoryOneDriveFilterCombo')
            ExistingTaskBehavior      = Get-ComboText (Get-UiControl 'ExistingTaskBehaviorCombo')
            MailSuffix                = [string](Get-UiControl 'FactoryMailSuffixBox').Text
            OneDriveSuffix            = [string](Get-UiControl 'FactoryOneDriveSuffixBox').Text
            MeetingLinkSuffix         = [string](Get-UiControl 'FactoryMeetingLinkSuffixBox').Text
            MailboxSwitchSuffix       = [string](Get-UiControl 'FactoryMailboxSwitchSuffixBox').Text
            MailPlacement             = Get-ComboText (Get-UiControl 'FactoryMailPlacementCombo')
            OneDrivePlacement         = Get-ComboText (Get-UiControl 'FactoryOneDrivePlacementCombo')
            MeetingLinkPlacement      = Get-ComboText (Get-UiControl 'FactoryMeetingLinkPlacementCombo')
            MailboxSwitchPlacement    = Get-ComboText (Get-UiControl 'FactoryMailboxSwitchPlacementCombo')
            SafeModeOnStartup          = $true
            TaskDetailsAutoRefresh     = [bool](Get-UiControl 'TaskDetailsAutoRefreshCheckBox').IsChecked
            TaskDetailsRefreshSeconds  = ConvertTo-UiInt -Text (Get-ComboText (Get-UiControl 'TaskDetailsRefreshSecondsCombo')) -Default 30 -Minimum 15
            SelectedProfileName        = [string](Get-UiControl 'ProfileCombo').SelectedValue
            ReadinessCheckOnlineModuleVersion = [bool](Get-UiControl 'ReadinessOnlineCheckBox').IsChecked
            Theme                     = [string]$script:State.Theme
            LogRetentionDays           = Get-UiLogRetentionDays -Value (Get-ComboText (Get-UiControl 'LogRetentionDaysCombo'))
        }

        if (-not (Test-UiDirectoryWritable -Path $script:ConfigPath -Create $true)) {
            throw "The settings directory is not writable: $script:ConfigPath"
        }
        $temporaryPath = Join-Path $script:ConfigPath ('.QuestODMConsole.settings.{0}.{1}.tmp' -f $PID, ([Guid]::NewGuid().ToString('N')))
        $json = $settings | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
        Move-Item -LiteralPath $temporaryPath -Destination $script:SettingsPath -Force -ErrorAction Stop
        $temporaryPath = $null
    }
    catch {
        Write-UiLog -Message "Settings could not be saved: $($_.Exception.Message)" -Level WARN
    }
    finally {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}


function Save-UiProfilesFile {
    [CmdletBinding()]
    param([AllowNull()][object]$Profiles)

    $temporaryPath = Join-Path $script:ConfigPath ('.QuestODMConsole.profiles.{0}.{1}.tmp' -f $PID,([Guid]::NewGuid().ToString('N')))
    try {
        $payload = [pscustomobject]@{ SchemaVersion=1; Profiles=(ConvertTo-UiObjectArray -InputObject $Profiles) }
        [IO.File]::WriteAllText($temporaryPath,($payload | ConvertTo-Json -Depth 8),(New-Object System.Text.UTF8Encoding -ArgumentList $true))
        Move-Item -LiteralPath $temporaryPath -Destination $script:ProfilesPath -Force -ErrorAction Stop
    }
    finally { if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue } }
}

function Load-UiProfiles {
    [CmdletBinding()]
    param()

    $profiles = @()
    if (Test-Path -LiteralPath $script:ProfilesPath -PathType Leaf) {
        try {
            $payload = Get-Content -LiteralPath $script:ProfilesPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $profiles = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $payload -Names @('Profiles') -Default @())
        }
        catch {
            $corrupt = "$script:ProfilesPath.corrupt.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            try { Move-Item -LiteralPath $script:ProfilesPath -Destination $corrupt -Force -ErrorAction Stop } catch { }
            Write-UiLog -Message "Profile file was malformed and was moved aside: $($_.Exception.Message)" -Level WARN
            $profiles = @()
        }
    }
    $valid = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($profile in $profiles) {
        $name = [string](Get-ObjectPropertyValue -InputObject $profile -Names @('Name'))
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $key = $name.Trim().ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $valid.Add($profile) | Out-Null
    }
    $script:State.Profiles = ConvertTo-UiObjectArray -InputObject ($valid.ToArray() | Sort-Object Name)
    Set-ComboItems -Combo (Get-UiControl 'ProfileCombo') -Items $script:State.Profiles
    $selected = [string](Get-SettingValue -Name 'SelectedProfileName' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        foreach ($profile in $script:State.Profiles) {
            if ([string]::Equals([string]$profile.Name,$selected,[StringComparison]::OrdinalIgnoreCase)) { (Get-UiControl 'ProfileCombo').SelectedItem=$profile; break }
        }
    }
}

function Get-CurrentUiProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $reportDirectory = Get-UiReportDirectory -Candidate ([string](Get-UiControl 'FactoryOutputDirectoryBox').Text)
    [pscustomobject]@{
        Name=$Name.Trim()
        Region=Get-ComboText (Get-UiControl 'RegionCombo')
        OrganizationId=[string](Get-UiControl 'OrganizationIdBox').Text
        ProjectId=if ($null -ne $script:State.Context) { [string](Get-ObjectPropertyValue -InputObject $script:State.Context -Names @('ProjectId')) } else { [string](Get-UiControl 'ProjectCombo').SelectedValue }
        WorkloadId=if ($null -ne $script:State.Context) { [string](Get-ObjectPropertyValue -InputObject $script:State.Context -Names @('WorkloadId')) } else { [string](Get-UiControl 'WorkloadCombo').SelectedValue }
        ReportDirectory=$reportDirectory
        NotifyRecipients=[string](Get-UiControl 'FactoryNotifyRecipientsBox').Text
        ExistingTaskBehavior=Get-ComboText (Get-UiControl 'ExistingTaskBehaviorCombo')
        MailNameText=[string](Get-UiControl 'FactoryMailSuffixBox').Text
        MailPlacement=Get-ComboText (Get-UiControl 'FactoryMailPlacementCombo')
        OneDriveNameText=[string](Get-UiControl 'FactoryOneDriveSuffixBox').Text
        OneDrivePlacement=Get-ComboText (Get-UiControl 'FactoryOneDrivePlacementCombo')
        MeetingLinkNameText=[string](Get-UiControl 'FactoryMeetingLinkSuffixBox').Text
        MeetingLinkPlacement=Get-ComboText (Get-UiControl 'FactoryMeetingLinkPlacementCombo')
        MailboxSwitchNameText=[string](Get-UiControl 'FactoryMailboxSwitchSuffixBox').Text
        MailboxSwitchPlacement=Get-ComboText (Get-UiControl 'FactoryMailboxSwitchPlacementCombo')
        OneDriveFilterItems=Get-ComboText (Get-UiControl 'FactoryOneDriveFilterCombo')
        SavedAt=(Get-Date)
    }
}

function Save-CurrentUiProfile {
    [CmdletBinding()]
    param()

    $name = [string](Get-UiControl 'ProfileNameBox').Text
    if ([string]::IsNullOrWhiteSpace($name)) { Show-UiMessage -Text 'Enter a profile name.' -Type Warning; return }
    if ($name -match '[\\/:*?"<>|]') { Show-UiMessage -Text 'The profile name contains an unsupported character.' -Type Warning; return }
    $profile = Get-CurrentUiProfile -Name $name
    $updated = [System.Collections.Generic.List[object]]::new()
    foreach ($existing in (ConvertTo-UiObjectArray -InputObject $script:State.Profiles)) {
        if (-not [string]::Equals([string]$existing.Name,$profile.Name,[StringComparison]::OrdinalIgnoreCase)) { $updated.Add($existing) | Out-Null }
    }
    $updated.Add($profile) | Out-Null
    Save-UiProfilesFile -Profiles $updated.ToArray()
    $script:State.Profiles = ConvertTo-UiObjectArray -InputObject ($updated.ToArray() | Sort-Object Name)
    Set-ComboItems -Combo (Get-UiControl 'ProfileCombo') -Items $script:State.Profiles
    foreach ($item in $script:State.Profiles) { if ([string]::Equals([string]$item.Name,$profile.Name,[StringComparison]::OrdinalIgnoreCase)) { (Get-UiControl 'ProfileCombo').SelectedItem=$item; break } }
    Write-UiLog -Message "Saved configuration profile '$($profile.Name)'." -Level SUCCESS
}

function Apply-UiProfile {
    [CmdletBinding()]
    param([AllowNull()][object]$Profile)

    if ($null -eq $Profile) { Show-UiMessage -Text 'Select a saved profile.' -Type Warning; return }
    Select-ComboContent -Combo (Get-UiControl 'RegionCombo') -Content ([string](Get-ObjectPropertyValue -InputObject $Profile -Names @('Region') -Default 'US'))
    (Get-UiControl 'OrganizationIdBox').Text = [string](Get-ObjectPropertyValue -InputObject $Profile -Names @('OrganizationId'))
    $script:State.PreferredProjectId = [string](Get-ObjectPropertyValue -InputObject $Profile -Names @('ProjectId'))
    $script:State.PreferredWorkloadId = [string](Get-ObjectPropertyValue -InputObject $Profile -Names @('WorkloadId'))
    $null = Select-ContextComboById -Combo (Get-UiControl 'OrganizationCombo') -Id ([string](Get-ObjectPropertyValue -InputObject $Profile -Names @('OrganizationId')))
    $null = Select-ContextComboById -Combo (Get-UiControl 'ProjectCombo') -Id $script:State.PreferredProjectId
    $null = Select-ContextComboById -Combo (Get-UiControl 'WorkloadCombo') -Id $script:State.PreferredWorkloadId
    $report = [string](Get-ObjectPropertyValue -InputObject $Profile -Names @('ReportDirectory') -Default $script:ReportsPath)
    foreach ($name in @('TaskOutputDirectoryBox','CollectionOutputDirectoryBox','FactoryOutputDirectoryBox','BulkOutputDirectoryBox')) { (Get-UiControl $name).Text=$report }
    (Get-UiControl 'FactoryNotifyRecipientsBox').Text=[string](Get-ObjectPropertyValue -InputObject $Profile -Names @('NotifyRecipients'))
    Select-ComboContent -Combo (Get-UiControl 'ExistingTaskBehaviorCombo') -Content ([string](Get-ObjectPropertyValue -InputObject $Profile -Names @('ExistingTaskBehavior') -Default 'Skip'))
    (Get-UiControl 'FactoryMailSuffixBox').Text=[string](Get-ObjectPropertyValue -InputObject $Profile -Names @('MailNameText') -Default 'Email Sync')
    Select-ComboContent -Combo (Get-UiControl 'FactoryMailPlacementCombo') -Content ([string](Get-ObjectPropertyValue -InputObject $Profile -Names @('MailPlacement') -Default 'Suffix'))
    (Get-UiControl 'FactoryOneDriveSuffixBox').Text=[string](Get-ObjectPropertyValue -InputObject $Profile -Names @('OneDriveNameText') -Default 'OneDrive Sync')
    Select-ComboContent -Combo (Get-UiControl 'FactoryOneDrivePlacementCombo') -Content ([string](Get-ObjectPropertyValue -InputObject $Profile -Names @('OneDrivePlacement') -Default 'Suffix'))
    (Get-UiControl 'FactoryMeetingLinkSuffixBox').Text=[string](Get-ObjectPropertyValue -InputObject $Profile -Names @('MeetingLinkNameText') -Default 'Meeting Link Migration')
    Select-ComboContent -Combo (Get-UiControl 'FactoryMeetingLinkPlacementCombo') -Content ([string](Get-ObjectPropertyValue -InputObject $Profile -Names @('MeetingLinkPlacement') -Default 'Suffix'))
    (Get-UiControl 'FactoryMailboxSwitchSuffixBox').Text=[string](Get-ObjectPropertyValue -InputObject $Profile -Names @('MailboxSwitchNameText') -Default 'Mailbox Switch')
    Select-ComboContent -Combo (Get-UiControl 'FactoryMailboxSwitchPlacementCombo') -Content ([string](Get-ObjectPropertyValue -InputObject $Profile -Names @('MailboxSwitchPlacement') -Default 'Suffix'))
    Select-ComboContent -Combo (Get-UiControl 'FactoryOneDriveFilterCombo') -Content ([string](Get-ObjectPropertyValue -InputObject $Profile -Names @('OneDriveFilterItems') -Default 'AfterLastSuccessfulRun'))
    (Get-UiControl 'ProfileNameBox').Text=[string]$Profile.Name
    if (-not $script:State.SafeMode) {
        $script:State.ProfileLoadContext = [pscustomobject]@{ Name = [string]$Profile.Name }
        Invoke-EngineAsync -Operation 'SetSafeMode' -Parameters @{Enabled=$true;Reason='Safe Mode reset because a configuration profile was loaded.'} -Status 'Resetting Safe Mode after profile load…' -OnSuccess {
            param($data)
            $profileContext = Get-ObjectPropertyValue -InputObject $script:State -Names @('ProfileLoadContext')
            $profileName = [string](Get-ObjectPropertyValue -InputObject $profileContext -Names @('Name') -Default 'Selected profile')
            try {
                Set-UiSafeModeState -SafeModeState $data
                Write-UiLog -Message "Loaded configuration profile '$profileName'. Safe Mode was reset and no Quest context was opened automatically." -Level SUCCESS
            }
            finally { $script:State.ProfileLoadContext = $null }
        } -OnFailure {
            param($message,$result)
            $script:State.ProfileLoadContext = $null
            Show-UiMessage -Text $message -Type Error
        }
    }
    else {
        Write-UiLog -Message "Loaded configuration profile '$($Profile.Name)'. Safe Mode remains enabled and no Quest context was opened automatically." -Level SUCCESS
    }
}

function Delete-SelectedUiProfile {
    [CmdletBinding()]
    param()

    $profile = (Get-UiControl 'ProfileCombo').SelectedItem
    if ($null -eq $profile) { Show-UiMessage -Text 'Select a profile to delete.' -Type Warning; return }
    if (-not (Confirm-UiAction -Text "Delete configuration profile '$($profile.Name)'?" -Title 'Delete profile')) { return }
    $remaining = ConvertTo-UiObjectArray -InputObject ($script:State.Profiles | Where-Object { -not [string]::Equals([string]$_.Name,[string]$profile.Name,[StringComparison]::OrdinalIgnoreCase) })
    Save-UiProfilesFile -Profiles $remaining
    $script:State.Profiles=$remaining
    Set-ComboItems -Combo (Get-UiControl 'ProfileCombo') -Items $remaining
    (Get-UiControl 'ProfileNameBox').Clear()
    Write-UiLog -Message "Deleted configuration profile '$($profile.Name)'." -Level SUCCESS
}

function Get-ComboText {
    param([Parameter(Mandatory = $true)][object]$ComboBox)
    if ($null -ne $ComboBox.SelectedItem) {
        if ($ComboBox.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { return [string]$ComboBox.SelectedItem.Content }
        $contentProperty = $ComboBox.SelectedItem.PSObject.Properties['Content']
        if ($null -ne $contentProperty) { return [string]$contentProperty.Value }
        if (-not [string]::IsNullOrWhiteSpace([string]$ComboBox.Text)) { return [string]$ComboBox.Text }
        return [string]$ComboBox.SelectedItem
    }
    return [string]$ComboBox.Text
}

function Get-ComboIdOrText {
    param([Parameter(Mandatory = $true)][object]$ComboBox)
    if ($null -ne $ComboBox.SelectedValue -and -not [string]::IsNullOrWhiteSpace([string]$ComboBox.SelectedValue)) {
        return [string]$ComboBox.SelectedValue
    }
    return [string]$ComboBox.Text
}

function ConvertTo-UiInt {
    param([AllowNull()][string]$Text, [int]$Default, [int]$Minimum = 0)
    $value = 0
    if (-not [int]::TryParse($Text, [ref]$value)) { return $Default }
    if ($value -lt $Minimum) { return $Default }
    return $value
}

function Set-GridItems {
    param([Parameter(Mandatory = $true)][object]$Grid, [AllowNull()][object]$Items)
    $Grid.ItemsSource = $null
    $Grid.ItemsSource = ConvertTo-UiObjectArray -InputObject $Items
}

function Set-ComboItems {
    param(
        [Parameter(Mandatory = $true)][object]$Combo,
        [AllowNull()][object]$Items,
        [int]$SelectIndex = -1
    )

    $normalizedBuffer = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (ConvertTo-UiObjectArray -InputObject $Items)) { if ($null -ne $item) { $normalizedBuffer.Add($item) | Out-Null } }
    $normalized = $normalizedBuffer.ToArray()
    $Combo.ItemsSource = $null
    $Combo.Items.Clear()
    $Combo.SelectedIndex = -1
    $Combo.ItemsSource = $normalized
    if ($SelectIndex -ge 0 -and $Combo.Items.Count -gt $SelectIndex) { $Combo.SelectedIndex = $SelectIndex }
}

function Set-ContextComboItems {
    param(
        [Parameter(Mandatory = $true)][object]$Combo,
        [AllowNull()][object]$Items,
        [int]$SelectIndex = -1
    )

    # Re-materialize engine results in the UI runspace. This avoids relying on WPF to
    # bind directly to PSObjects that originated in the background API runspace.
    $normalized = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (ConvertTo-UiObjectArray -InputObject $Items)) {
        if ($null -eq $item) { continue }
        $id = [string](Get-ObjectPropertyValue -InputObject $item -Names @('Id','ID'))
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $name = [string](Get-ObjectPropertyValue -InputObject $item -Names @('Name','DisplayName') -Default $id)
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
        $displayText = [string](Get-ObjectPropertyValue -InputObject $item -Names @('DisplayText') -Default $name)
        if ([string]::IsNullOrWhiteSpace($displayText)) { $displayText = $name }
        $normalized.Add([pscustomobject]@{
            Id               = $id
            Name             = $name
            DisplayText      = $displayText
            Type             = [string](Get-ObjectPropertyValue -InputObject $item -Names @('Type'))
            SourceTenant     = [string](Get-ObjectPropertyValue -InputObject $item -Names @('SourceTenant'))
            TargetTenant     = [string](Get-ObjectPropertyValue -InputObject $item -Names @('TargetTenant'))
            IsProjectContext = [bool](Get-ObjectPropertyValue -InputObject $item -Names @('IsProjectContext') -Default $false)
            ContextKind      = [string](Get-ObjectPropertyValue -InputObject $item -Names @('ContextKind'))
        }) | Out-Null
    }

    Set-ComboItems -Combo $Combo -Items $normalized.ToArray() -SelectIndex $SelectIndex
    return $normalized.Count
}

function Select-ContextComboById {
    param(
        [Parameter(Mandatory = $true)][object]$Combo,
        [AllowNull()][string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    foreach ($item in $Combo.Items) {
        $itemId = [string](Get-ObjectPropertyValue -InputObject $item -Names @('Id'))
        if ([string]::Equals($itemId, $Id, [StringComparison]::OrdinalIgnoreCase)) {
            $Combo.SelectedItem = $item
            return $true
        }
    }
    return $false
}

function Write-UiDiscoveryDiagnostics {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][object]$Discovery
    )

    if ($null -eq $Discovery) {
        Write-UiLog -Message "$Label discovery returned no diagnostic object." -Level WARN
        return
    }

    $items = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Discovery -Names @('Items') -Default @())
    $attempts = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Discovery -Names @('Attempts') -Default @())
    if ($attempts.Count -gt 0) {
        foreach ($attempt in $attempts) {
            $command = [string](Get-ObjectPropertyValue -InputObject $attempt -Names @('Command') -Default 'Unknown')
            $available = [bool](Get-ObjectPropertyValue -InputObject $attempt -Names @('Available') -Default $false)
            $succeeded = [bool](Get-ObjectPropertyValue -InputObject $attempt -Names @('Succeeded') -Default $false)
            $rawCount = [int](Get-ObjectPropertyValue -InputObject $attempt -Names @('RawCount') -Default 0)
            $convertedCount = [int](Get-ObjectPropertyValue -InputObject $attempt -Names @('ConvertedCount') -Default 0)
            $errorText = [string](Get-ObjectPropertyValue -InputObject $attempt -Names @('Error'))
            $level = if ($succeeded) { 'INFO' } elseif ($available) { 'WARN' } else { 'INFO' }
            $message = "${Label} discovery via ${command}: available=$available; succeeded=$succeeded; raw=$rawCount; usable=$convertedCount"
            if (-not [string]::IsNullOrWhiteSpace($errorText)) { $message = "$message; error=$errorText" }
            Write-UiLog -Message $message -Level $level
        }
    }
    else {
        $succeeded = [bool](Get-ObjectPropertyValue -InputObject $Discovery -Names @('Succeeded') -Default $true)
        $rawCount = [int](Get-ObjectPropertyValue -InputObject $Discovery -Names @('RawCount') -Default 0)
        $convertedCount = [int](Get-ObjectPropertyValue -InputObject $Discovery -Names @('ConvertedCount') -Default $items.Count)
        $errorText = [string](Get-ObjectPropertyValue -InputObject $Discovery -Names @('Error'))
        $level = if ($succeeded) { 'INFO' } else { 'WARN' }
        $message = "$Label discovery: succeeded=$succeeded; raw=$rawCount; usable=$convertedCount"
        if (-not [string]::IsNullOrWhiteSpace($errorText)) { $message = "$message; error=$errorText" }
        Write-UiLog -Message $message -Level $level
    }
}

function Select-ComboContent {
    param([Parameter(Mandatory = $true)][object]$Combo, [AllowNull()][string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return }
    foreach ($item in $Combo.Items) {
        $value = if ($item -is [System.Windows.Controls.ComboBoxItem]) { [string]$item.Content } else { [string]$item }
        if ($value -eq $Content) { $Combo.SelectedItem = $item; break }
    }
}

function Get-SelectedGridItems {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Grid)

    # PowerShell enumerates arrays written by a function. Preserve the normalized
    # object[] as one pipeline object so zero-, one-, and many-row selections do
    # not collapse to $null or a scalar under StrictMode.
    $items = ConvertTo-UiObjectArray -InputObject $Grid.SelectedItems
    return ,$items
}

function Get-SelectedGridItem {
    param([Parameter(Mandatory = $true)][object]$Grid)
    return $Grid.SelectedItem
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace([string]$name)) { continue }
        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in @($InputObject.Keys)) {
                if ([string]::Equals([string]$key, [string]$name, [StringComparison]::OrdinalIgnoreCase)) {
                    return $InputObject[$key]
                }
            }
        }
        try {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property) { return $property.Value }
        }
        catch { }
    }
    return $Default
}

function Test-ObjectPropertyTrue {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string[]]$Names)
    return [bool](Get-ObjectPropertyValue -InputObject $InputObject -Names $Names -Default $false)
}

function Get-UiSafeCount {
    param([AllowNull()][object]$Value)
    return (ConvertTo-UiObjectArray -InputObject $Value).Count
}

function Assert-UiSelectionCardinalityContract {
    [CmdletBinding()]
    param()

    $cases = @(
        [pscustomobject]@{ Name = 'empty'; Items = [object[]]@(); Expected = 0 },
        [pscustomobject]@{ Name = 'single'; Items = [object[]]@([pscustomobject]@{ Id = 'one' }); Expected = 1 },
        [pscustomobject]@{ Name = 'multiple'; Items = [object[]]@([pscustomobject]@{ Id = 'one' }, [pscustomobject]@{ Id = 'two' }); Expected = 2 }
    )

    foreach ($case in $cases) {
        $probeGrid = [pscustomobject]@{ SelectedItems = $case.Items }
        $actual = Get-UiSafeCount -Value (Get-SelectedGridItems -Grid $probeGrid)
        if ($actual -ne [int]$case.Expected) {
            throw ("UI selection cardinality self-test failed for '{0}': expected {1}, received {2}." -f $case.Name, $case.Expected, $actual)
        }
    }
}

function Get-UiDiagnosticText {
    param(
        [AllowNull()][object]$Result,
        [AllowNull()][string]$FallbackMessage,
        [AllowNull()][string]$Operation
    )

    $message = [string](Get-ObjectPropertyValue -InputObject $Result -Names @('Error','Message') -Default $FallbackMessage)
    if ([string]::IsNullOrWhiteSpace($message)) { $message = 'The operation failed without an error message.' }
    $details = [string](Get-ObjectPropertyValue -InputObject $Result -Names @('Details'))
    $diagnostic = Get-ObjectPropertyValue -InputObject $Result -Names @('Diagnostic')
    $diagnosticId = [string](Get-ObjectPropertyValue -InputObject $Result -Names @('DiagnosticId'))
    $phase = [string](Get-ObjectPropertyValue -InputObject $Result -Names @('Phase'))
    if ([string]::IsNullOrWhiteSpace($phase) -and $null -ne $diagnostic) {
        $phase = [string](Get-ObjectPropertyValue -InputObject $diagnostic -Names @('Phase'))
    }
    $source = [string](Get-ObjectPropertyValue -InputObject $diagnostic -Names @('ScriptName'))
    $line = [int](Get-ObjectPropertyValue -InputObject $diagnostic -Names @('ScriptLineNumber') -Default 0)
    $fqid = [string](Get-ObjectPropertyValue -InputObject $diagnostic -Names @('FullyQualifiedErrorId'))
    $moduleVersion = [string](Get-ObjectPropertyValue -InputObject $diagnostic -Names @('OdmApiVersion'))
    $modulePath = [string](Get-ObjectPropertyValue -InputObject $diagnostic -Names @('OdmApiPath'))

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($message) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($details) -and $details -ne $message) { $lines.Add('') | Out-Null; $lines.Add($details) | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($operation)) { $lines.Add('') | Out-Null; $lines.Add("Operation: $operation") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($phase)) { $lines.Add("Phase: $phase") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($diagnosticId)) { $lines.Add("Diagnostic ID: $diagnosticId") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($fqid)) { $lines.Add("Error ID: $fqid") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($source)) {
        $location = if ($line -gt 0) { "$source, line $line" } else { $source }
        $lines.Add("Source: $location") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($moduleVersion) -or -not [string]::IsNullOrWhiteSpace($modulePath)) {
        $lines.Add("OdmApi: $moduleVersion $modulePath") | Out-Null
    }
    $lines.Add("Session log: $script:SessionLogPath") | Out-Null
    return ($lines.ToArray() -join "`r`n")
}

function New-UiCallbackArguments {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$First,
        [AllowNull()][object]$Second
    )

    # Build callback arguments with CLR collection semantics so an array or
    # generic list passed as the first logical argument remains one argument.
    $arguments = [System.Collections.Generic.List[object]]::new()
    $arguments.Add($First) | Out-Null
    $arguments.Add($Second) | Out-Null
    return ,$arguments.ToArray()
}

function Invoke-UiCallbackSafely {
    param(
        [AllowNull()][scriptblock]$Callback,
        [AllowNull()][object]$Arguments,
        [Parameter(Mandatory = $true)][string]$CallbackName,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    if ($null -eq $Callback) { return $true }
    try {
        $callbackArguments = ConvertTo-UiObjectArray -InputObject $Arguments
        & $Callback @callbackArguments
        return $true
    }
    catch {
        $text = "The Quest operation '$Operation' completed, but its $CallbackName UI callback failed.`r`n`r`nThe underlying operation was not rolled back. Verify the generated report and Quest state before retrying an executed write.`r`n`r`n$($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)`r`n`r`nSession log: $script:SessionLogPath"
        Write-UiLog -Message $text -Level ERROR
        Show-UiMessage -Text $text -Title 'Quest ODM Console UI error' -Type Error
        return $false
    }
}

function Browse-ForCsv {
    param([Parameter(Mandatory = $true)][object]$TargetTextBox)
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($script:Window)) { $TargetTextBox.Text = $dialog.FileName }
}

function Browse-ForFolder {
    param([Parameter(Mandatory = $true)][object]$TargetTextBox)
    $dialog = $null
    try {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select an output directory'
        if (-not [string]::IsNullOrWhiteSpace([string]$TargetTextBox.Text) -and (Test-Path -LiteralPath $TargetTextBox.Text)) { $dialog.SelectedPath = $TargetTextBox.Text }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $TargetTextBox.Text = $dialog.SelectedPath }
    }
    finally {
        if ($null -ne $dialog) { try { $dialog.Dispose() } catch { } }
    }
}


function Set-UiSafeModeState {
    [CmdletBinding()]
    param([AllowNull()][object]$SafeModeState)

    $enabled = if ($null -eq $SafeModeState) { $true } else { [bool](Get-ObjectPropertyValue -InputObject $SafeModeState -Names @('Enabled','SafeMode') -Default $true) }
    $reason = if ($null -eq $SafeModeState) { 'Safe Mode enabled.' } else { [string](Get-ObjectPropertyValue -InputObject $SafeModeState -Names @('Reason','SafeModeReason') -Default 'Safe Mode enabled.') }
    $script:State.SafeMode = $enabled
    $script:State.SafeModeReason = $reason
    $border = Get-UiControl 'SafeModeStatusBorder'
    $text = Get-UiControl 'SafeModeStatusText'
    $button = Get-UiControl 'ToggleSafeModeButton'
    if ($enabled) {
        Set-UiResourceReference -Control $border -Property ([Windows.Controls.Border]::BackgroundProperty) -ResourceKey 'WarningLightBrush'
        Set-UiResourceReference -Control $border -Property ([Windows.Controls.Border]::BorderBrushProperty) -ResourceKey 'WarningBorderBrush'
        Set-UiResourceReference -Control $text -Property ([Windows.Controls.TextBlock]::ForegroundProperty) -ResourceKey 'WarningTextBrush'
        $text.Text = 'SAFE MODE — Read-only'
        $button.Content = 'Enable changes'
    }
    else {
        Set-UiResourceReference -Control $border -Property ([Windows.Controls.Border]::BackgroundProperty) -ResourceKey 'DangerLightBrush'
        Set-UiResourceReference -Control $border -Property ([Windows.Controls.Border]::BorderBrushProperty) -ResourceKey 'DangerBorderBrush'
        Set-UiResourceReference -Control $text -Property ([Windows.Controls.TextBlock]::ForegroundProperty) -ResourceKey 'DangerTextBrush'
        $text.Text = 'CHANGES ENABLED'
        $button.Content = 'Return to Safe Mode'
    }
    $border.ToolTip = $reason
    Update-UiEnablement
}

function Get-UiActiveContextText {
    $context = $script:State.Context
    return @(
        "Organization: $([string](Get-ObjectPropertyValue -InputObject $context -Names @('OrganizationName'))) [$([string](Get-ObjectPropertyValue -InputObject $context -Names @('OrganizationId')))]",
        "Project:      $([string](Get-ObjectPropertyValue -InputObject $context -Names @('ProjectName'))) [$([string](Get-ObjectPropertyValue -InputObject $context -Names @('ProjectId')))]",
        "Workload:     $([string](Get-ObjectPropertyValue -InputObject $context -Names @('WorkloadName'))) [$([string](Get-ObjectPropertyValue -InputObject $context -Names @('WorkloadId')))]"
    ) -join "`r`n"
}

function Invoke-UiSafeModeToggle {
    [CmdletBinding()]
    param()

    if (-not $script:State.SafeMode) {
        Invoke-EngineAsync -Operation 'SetSafeMode' -Parameters @{Enabled=$true;Reason='Safe Mode enabled by the operator.'} -Status 'Enabling Safe Mode…' -OnSuccess { param($data); Set-UiSafeModeState -SafeModeState $data; Write-UiLog -Message 'Safe Mode enabled.' -Level SUCCESS }
        return
    }
    if (-not $script:State.WorkloadSelected) { Show-UiMessage -Text 'Connect and open a workload before enabling changes.' -Type Warning; return }
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop }
    catch { Show-UiMessage -Text "Microsoft.VisualBasic could not be loaded for the confirmation prompt: $($_.Exception.Message)" -Type Error; return }
    $contextText = Get-UiActiveContextText
    $prompt = "Write operations will be enabled only for this active context:`r`n`r`n$contextText`r`n`r`nEnter the exact text ENABLE CHANGES to continue."
    $confirmation = [Microsoft.VisualBasic.Interaction]::InputBox($prompt,'Enable Quest ODM changes','')
    if ([string]::IsNullOrWhiteSpace($confirmation)) { return }
    $context = $script:State.Context
    Invoke-EngineAsync -Operation 'SetSafeMode' -Parameters @{
        Enabled=$false
        OrganizationId=[string](Get-ObjectPropertyValue -InputObject $context -Names @('OrganizationId'))
        ProjectId=[string](Get-ObjectPropertyValue -InputObject $context -Names @('ProjectId'))
        WorkloadId=[string](Get-ObjectPropertyValue -InputObject $context -Names @('WorkloadId'))
        ConfirmationText=$confirmation
    } -Status 'Enabling changes for the active context…' -OnSuccess {
        param($data)
        Set-UiSafeModeState -SafeModeState $data
        Write-UiLog -Message "Changes enabled for the active context.`r`n$(Get-UiActiveContextText)" -Level WARN
    }
}

function Set-ConnectionStatus {
    param([bool]$Connected, [AllowNull()][string]$Text)
    $statusText = Get-UiControl 'ConnectionStatusText'
    $statusDot = Get-UiControl 'ConnectionStatusDot'
    $statusBorder = Get-UiControl 'ConnectionStatusBorder'
    if ($Connected) {
        $statusText.Text = if ($Text) { $Text } else { 'Connected' }
        Set-UiResourceReference -Control $statusText -Property ([Windows.Controls.TextBlock]::ForegroundProperty) -ResourceKey 'SuccessBrush'
        Set-UiResourceReference -Control $statusDot -Property ([Windows.Shapes.Shape]::FillProperty) -ResourceKey 'SuccessBrush'
        Set-UiResourceReference -Control $statusBorder -Property ([Windows.Controls.Border]::BackgroundProperty) -ResourceKey 'SuccessLightBrush'
    }
    else {
        $statusText.Text = if ($Text) { $Text } else { 'Disconnected' }
        Set-UiResourceReference -Control $statusText -Property ([Windows.Controls.TextBlock]::ForegroundProperty) -ResourceKey 'MutedBrush'
        Set-UiResourceReference -Control $statusDot -Property ([Windows.Shapes.Shape]::FillProperty) -ResourceKey 'NeutralDotBrush'
        Set-UiResourceReference -Control $statusBorder -Property ([Windows.Controls.Border]::BackgroundProperty) -ResourceKey 'StatusSurfaceBrush'
    }
}

function Set-UiBusy {
    param([bool]$Busy, [AllowNull()][string]$Status)
    $script:State.Busy = $Busy
    (Get-UiControl 'BusyProgressBar').Visibility = if ($Busy) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    (Get-UiControl 'FooterStatusText').Text = if ($Status) { $Status } elseif ($Busy) { 'Working…' } else { 'Ready.' }
    $script:Window.Cursor = if ($Busy) { [Windows.Input.Cursors]::Wait } else { [Windows.Input.Cursors]::Arrow }
    (Get-UiControl 'MainTabControl').IsEnabled = -not $Busy
    Update-UiEnablement
    # Overview values are backed by application state rather than transient control state.
    # Reapplying them after the tab control changes enabled state keeps the last completed
    # snapshot visible throughout refreshes and other asynchronous operations.
    Show-OverviewSnapshot
}

function Test-UiFeatureAllowed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Feature)

    $blocked = ConvertTo-UiObjectArray -InputObject $script:State.BlockedFeatures
    return (-not ($blocked -contains 'AllWrites')) -and (-not ($blocked -contains $Feature))
}

function Get-UiBulkWriteFeature {
    [CmdletBinding()]
    param([AllowNull()][string]$Operation)

    switch ([string]$Operation) {
        'DiscoverAllAccounts'       { return 'AccountDiscovery' }
        'DiscoverAccountsFromCsv'   { return 'AccountDiscovery' }
        'MapAccountsFromCsv'        { return 'AccountDiscovery' }
        'StartTasksFromCsv'         { return 'TaskLifecycle' }
        'StopTasksFromCsv'          { return 'TaskLifecycle' }
        'DeleteTasksFromCsv'        { return 'TaskLifecycle' }
        'DeleteTasksAcrossProjects' { return 'TaskLifecycle' }
        'DeleteAllTasks'            { return 'TaskLifecycle' }
        default                     { return 'Membership' }
    }
}

function Update-UiEnablement {
    $notBusy = -not $script:State.Busy
    $connected = $script:State.Connected -and $notBusy
    $workload = $script:State.WorkloadSelected -and $notBusy
    $changesEnabled = $workload -and (-not $script:State.SafeMode)
    $membershipChanges = $changesEnabled -and (Test-UiFeatureAllowed -Feature 'Membership')
    $taskLifecycleChanges = $changesEnabled -and (Test-UiFeatureAllowed -Feature 'TaskLifecycle')
    $taskFactoryChanges = $changesEnabled -and (Test-UiFeatureAllowed -Feature 'TaskFactory')
    $reportingChanges = $changesEnabled -and (Test-UiFeatureAllowed -Feature 'Reporting')
    $localChanges = $notBusy -and (-not $script:State.SafeMode) -and (Test-UiFeatureAllowed -Feature 'LocalWrite')

    $moduleAllowsConnect = (-not $script:State.ModuleStatusKnown) -or $script:State.ModuleInstalled
    (Get-UiControl 'ConnectButton').IsEnabled = (-not $script:State.Connected) -and $notBusy -and $moduleAllowsConnect
    (Get-UiControl 'DisconnectButton').IsEnabled = $connected
    (Get-UiControl 'RefreshWorkspaceButton').IsEnabled = $workload
    (Get-UiControl 'OverviewRefreshButton').IsEnabled = $workload
    (Get-UiControl 'ToggleSafeModeButton').IsEnabled = $notBusy -and (($script:State.WorkloadSelected -and $script:State.Connected) -or (-not $script:State.SafeMode))

    (Get-UiControl 'OrganizationCombo').IsEnabled = $connected
    (Get-UiControl 'SelectOrganizationButton').IsEnabled = $connected
    (Get-UiControl 'ProjectCombo').IsEnabled = $connected -and ((Get-UiControl 'ProjectCombo').Items.Count -gt 0)
    (Get-UiControl 'SelectProjectButton').IsEnabled = (Get-UiControl 'ProjectCombo').IsEnabled
    (Get-UiControl 'WorkloadCombo').IsEnabled = $connected -and ((Get-UiControl 'WorkloadCombo').Items.Count -gt 0)
    (Get-UiControl 'SelectWorkloadButton').IsEnabled = (Get-UiControl 'WorkloadCombo').IsEnabled

    foreach ($name in @(
        'UserSearchButton','UserRefreshButton','TaskSearchButton','TaskRefreshButton','ExportTasksButton',
        'CollectionSearchButton','CollectionRefreshButton','ExportCollectionsButton','PreviewTaskFactoryButton'
    )) { (Get-UiControl $name).IsEnabled = $workload }
    (Get-UiControl 'CreateCollectionButton').IsEnabled = $membershipChanges
    (Get-UiControl 'RunTaskFactoryButton').IsEnabled = $taskFactoryChanges

    $bulkSelected = (Get-UiControl 'BulkOperationCombo').SelectedItem
    $bulkSupportsExecute = [bool](Get-ObjectPropertyValue -InputObject $bulkSelected -Names @('SupportsExecute') -Default $false)
    $bulkExecute = [bool](Get-UiControl 'BulkExecuteCheckBox').IsChecked
    $bulkKey = [string](Get-ObjectPropertyValue -InputObject $bulkSelected -Names @('Key'))
    $bulkFeatureAllowed = Test-UiFeatureAllowed -Feature (Get-UiBulkWriteFeature -Operation $bulkKey)
    (Get-UiControl 'RunBulkOperationButton').IsEnabled = $workload -and (-not $bulkSupportsExecute -or -not $bulkExecute -or ($changesEnabled -and $bulkFeatureAllowed))

    $mappingUtilityAvailable = Test-MappingCollisionUtilityAvailable
    (Get-UiControl 'LaunchMappingCollisionUtilityButton').IsEnabled = $notBusy -and $mappingUtilityAvailable
    (Get-UiControl 'OpenMappingCollisionUtilityFolderButton').IsEnabled = $notBusy -and (Test-Path -LiteralPath $script:MappingCollisionUtilityRoot -PathType Container)

    $selectedUser = $null -ne (Get-SelectedGridItem (Get-UiControl 'UserGrid'))
    (Get-UiControl 'LoadUserAssociationsButton').IsEnabled = $workload -and $selectedUser
    (Get-UiControl 'UserTargetTaskCombo').IsEnabled = $workload -and $selectedUser
    (Get-UiControl 'UserTargetCollectionCombo').IsEnabled = $workload -and $selectedUser
    $taskTarget = -not [string]::IsNullOrWhiteSpace([string](Get-UiControl 'UserTargetTaskCombo').SelectedValue)
    $collectionTarget = -not [string]::IsNullOrWhiteSpace([string](Get-UiControl 'UserTargetCollectionCombo').SelectedValue)
    (Get-UiControl 'AddUserToTaskButton').IsEnabled = $membershipChanges -and $selectedUser -and $taskTarget
    (Get-UiControl 'RemoveUserFromTaskButton').IsEnabled = $membershipChanges -and $selectedUser -and $taskTarget
    (Get-UiControl 'AddUserToCollectionButton').IsEnabled = $membershipChanges -and $selectedUser -and $collectionTarget
    (Get-UiControl 'RemoveUserFromCollectionButton').IsEnabled = $membershipChanges -and $selectedUser -and $collectionTarget

    $taskGrid = Get-UiControl 'TaskGrid'
    $taskSelectionCount = Get-UiSafeCount -Value $taskGrid.SelectedItems
    $oneTask = $workload -and ($taskSelectionCount -eq 1)
    (Get-UiControl 'LoadTaskMembersButton').IsEnabled = $oneTask
    (Get-UiControl 'RefreshTaskDetailsButton').IsEnabled = $oneTask
    (Get-UiControl 'ExportTaskDetailsButton').IsEnabled = $oneTask
    (Get-UiControl 'CopyTaskIdButton').IsEnabled = $oneTask
    (Get-UiControl 'CopyTaskDiagnosticButton').IsEnabled = $oneTask -and ($null -ne $script:State.TaskDetails)
    (Get-UiControl 'CreateTaskErrorExportButton').IsEnabled = $oneTask -and $reportingChanges
    (Get-UiControl 'StartSelectedTasksButton').IsEnabled = $taskLifecycleChanges -and ($taskSelectionCount -gt 0)
    (Get-UiControl 'StopSelectedTasksButton').IsEnabled = $taskLifecycleChanges -and ($taskSelectionCount -gt 0)
    (Get-UiControl 'DeleteSelectedTasksButton').IsEnabled = $taskLifecycleChanges -and ($taskSelectionCount -gt 0)
    $taskCsvExecute = [bool](Get-UiControl 'TaskCsvExecuteCheckBox').IsChecked
    (Get-UiControl 'AddCsvUsersToTaskButton').IsEnabled = $oneTask -and (-not $taskCsvExecute -or $membershipChanges)
    (Get-UiControl 'RemoveCsvUsersFromTaskButton').IsEnabled = $oneTask -and (-not $taskCsvExecute -or $membershipChanges)

    $collectionGrid = Get-UiControl 'CollectionGrid'
    $collectionSelectionCount = Get-UiSafeCount -Value $collectionGrid.SelectedItems
    $oneCollection = $workload -and ($collectionSelectionCount -eq 1)
    (Get-UiControl 'LoadCollectionMembersButton').IsEnabled = $oneCollection
    (Get-UiControl 'DeleteSelectedCollectionsButton').IsEnabled = $membershipChanges -and ($collectionSelectionCount -gt 0)
    $collectionCsvExecute = [bool](Get-UiControl 'CollectionCsvExecuteCheckBox').IsChecked
    (Get-UiControl 'AddCsvUsersToCollectionButton').IsEnabled = $oneCollection -and (-not $collectionCsvExecute -or $membershipChanges)
    (Get-UiControl 'RemoveCsvUsersFromCollectionButton').IsEnabled = $oneCollection -and (-not $collectionCsvExecute -or $membershipChanges)

    (Get-UiControl 'CheckOdmApiVersionButton').IsEnabled = $notBusy
    (Get-UiControl 'InstallOdmApiButton').IsEnabled = $notBusy -and $script:State.ModuleStatusKnown -and $script:State.ModuleCanInstall -and (-not $script:State.ModuleInstalled -or -not [bool](Get-ObjectPropertyValue -InputObject $script:State.ModuleStatus -Names @('ValidatedInstalled') -Default $false))
    (Get-UiControl 'UpdateOdmApiButton').IsEnabled = $notBusy -and $script:State.ModuleStatusKnown -and $script:State.ModuleCanInstall -and $script:State.ModuleInstalled
    (Get-UiControl 'InstallLatestOdmApiButton').IsEnabled = $notBusy -and $script:State.ModuleStatusKnown -and $script:State.ModuleCanInstall -and [bool](Get-ObjectPropertyValue -InputObject $script:State.ModuleStatus -Names @('OnlineCheckSucceeded') -Default $false)

    (Get-UiControl 'RunReadinessButton').IsEnabled = $notBusy
    (Get-UiControl 'CreateSupportBundleButton').IsEnabled = $notBusy
    (Get-UiControl 'LogRetentionDaysCombo').IsEnabled = $notBusy
    (Get-UiControl 'CleanOldLogsButton').IsEnabled = $notBusy
    (Get-UiControl 'ClearStoredLogsButton').IsEnabled = $notBusy
    (Get-UiControl 'RefreshOperationHistoryButton').IsEnabled = $notBusy
    (Get-UiControl 'OpenOperationHistoryButton').IsEnabled = $notBusy -and (Test-Path -LiteralPath $script:OperationHistoryPath -PathType Leaf)
    (Get-UiControl 'RemoveMmpcButton').IsEnabled = $localChanges
    (Get-UiControl 'SaveProfileButton').IsEnabled = $notBusy
    (Get-UiControl 'LoadProfileButton').IsEnabled = $notBusy -and ($null -ne (Get-UiControl 'ProfileCombo').SelectedItem)
    (Get-UiControl 'DeleteProfileButton').IsEnabled = $notBusy -and ($null -ne (Get-UiControl 'ProfileCombo').SelectedItem)
}

function Get-WorkerRunspaceState {
    $runspace = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerRunspace')
    if ($null -eq $runspace) { return 'NotCreated' }
    try {
        $stateInfo = Get-ObjectPropertyValue -InputObject $runspace -Names @('RunspaceStateInfo')
        return [string](Get-ObjectPropertyValue -InputObject $stateInfo -Names @('State') -Default 'Unknown')
    }
    catch { return 'Unknown' }
}

function Test-WorkerRunspaceHealthy {
    return ((Get-WorkerRunspaceState) -eq 'Opened')
}

function Dispose-UiPendingOperation {
    param([AllowNull()][object]$Pending, [bool]$Stop = $false)

    if ($null -eq $Pending) { return }
    $powerShell = Get-ObjectPropertyValue -InputObject $Pending -Names @('PowerShell')
    if ($null -ne $powerShell) {
        if ($Stop) { try { $powerShell.Stop() } catch { } }
        try { $powerShell.Dispose() } catch { }
    }
}

function Stop-WorkerRunspace {
    $timer = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerTimer')
    if ($null -ne $timer) { try { $timer.Stop() } catch { } }
    $script:State.WorkerTimer = $null
    $script:State.WorkerModulePreload = $null

    $pending = Get-ObjectPropertyValue -InputObject $script:State -Names @('Pending')
    $script:State.Pending = $null
    Dispose-UiPendingOperation -Pending $pending -Stop $true

    $runspace = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerRunspace')
    $script:State.WorkerRunspace = $null
    if ($null -ne $runspace) {
        try { $runspace.Close() } catch { }
        try { $runspace.Dispose() } catch { }
    }
}

function Start-WorkerRunspace {
    Stop-WorkerRunspace
    $runspace = $null
    $timer = $null
    $preloader = $null
    $initializer = $null
    $verifier = $null
    $preloadResult = $null
    try {
        $runspace = [RunspaceFactory]::CreateRunspace()
        if ($null -eq $runspace) { throw 'RunspaceFactory returned no worker runspace.' }
        $runspace.ApartmentState = [Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $runspaceState = [string](Get-ObjectPropertyValue -InputObject (Get-ObjectPropertyValue -InputObject $runspace -Names @('RunspaceStateInfo')) -Names @('State') -Default 'Unknown')
        if ($runspaceState -ne 'Opened') {
            throw "The worker runspace did not enter the Opened state. State: $runspaceState"
        }

        # OdmApi is loaded in the worker's global session state before the console engine
        # module is imported. Quest's private Set-ModuleVersion function uses Get-Module
        # against its own module name, so preloading avoids nested-module visibility issues.
        $preloader = [PowerShell]::Create()
        if ($null -eq $preloader) { throw 'PowerShell.Create returned no module-preloader instance.' }
        $preloader.Runspace = $runspace
        $preloadScript = @'
$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    Status='NOT_RUN'; Installed=$false; Loaded=$false; Version=$null; Path=$null; ManifestPath=$null
    CommandOwner=$null; Details=$null; Error=$null; ExceptionType=$null; FullyQualifiedErrorId=$null
    ScriptStackTrace=$null; PreloadedAt=Get-Date
}
try {
    $module = Get-Module -Name 'OdmApi' -All -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -ne $module) {
        $result.Status = 'ALREADY_LOADED'
        $result.Installed = $true
        $result.Loaded = $true
    }
    else {
        $candidate = Get-Module -ListAvailable -Name 'OdmApi' -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($null -eq $candidate) {
            $result.Status = 'NOT_INSTALLED'
            $result.Details = 'The OdmApi module is not installed in a module path visible to the worker runspace.'
        }
        else {
            $result.Installed = $true
            $manifestPath = Join-Path -Path $candidate.ModuleBase -ChildPath 'OdmApi.psd1'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { $manifestPath = [string]$candidate.Path }
            if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                throw "OdmApi was discovered, but its manifest or module path could not be resolved. Module base: $($candidate.ModuleBase)"
            }
            $result.ManifestPath = $manifestPath
            # This script runs inside the isolated worker runspace before the
            # console engine is imported. Do not call UI-runspace helper
            # functions here. Select the module object directly from the
            # Import-Module output and fall back to the worker's global module
            # table when Import-Module emits no object.
            $module = Import-Module -Name $manifestPath -Global -PassThru -ErrorAction Stop |
                Where-Object { $_.Name -eq 'OdmApi' } |
                Sort-Object Version -Descending |
                Select-Object -First 1
            if ($null -eq $module) {
                $module = Get-Module -Name 'OdmApi' -All -ErrorAction SilentlyContinue |
                    Sort-Object Version -Descending |
                    Select-Object -First 1
            }
            if ($null -eq $module) { throw 'OdmApi import completed without loading a module object.' }
            $result.Status = 'LOADED'
            $result.Loaded = $true
        }
    }

    if ($null -ne $module) {
        $result.Version = [string]$module.Version
        $result.Path = [string]$module.Path
        if ([string]::IsNullOrWhiteSpace([string]$result.ManifestPath)) {
            $resolvedManifest = Join-Path -Path $module.ModuleBase -ChildPath 'OdmApi.psd1'
            if (Test-Path -LiteralPath $resolvedManifest -PathType Leaf) { $result.ManifestPath = $resolvedManifest }
        }
        $connectCommand = Get-Command -Name 'Connect-OdmService' -ErrorAction Stop
        $owner = if ($null -ne $connectCommand.Module) { [string]$connectCommand.Module.Name } else { $null }
        $result.CommandOwner = $owner
        if (-not [string]::Equals($owner, 'OdmApi', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Connect-OdmService resolved to module '$owner' instead of 'OdmApi'."
        }
        $module = $connectCommand.Module
        $result.Version = [string]$module.Version
        $result.Path = [string]$module.Path
        $result.Details = "OdmApi $($result.Version) is globally loaded in the worker runspace."
    }
}
catch {
    $result.Status = 'FAILED'
    $result.Loaded = $false
    $result.Error = $_.Exception.Message
    $result.Details = 'Worker-level OdmApi preload failed: ' + $_.Exception.Message
    $result.ExceptionType = $_.Exception.GetType().FullName
    $result.FullyQualifiedErrorId = $_.FullyQualifiedErrorId
    $result.ScriptStackTrace = $_.ScriptStackTrace
}
$global:QuestODMConsoleOdmApiPreload = [pscustomobject]$result
$global:QuestODMConsoleOdmApiPreload
'@
        [void]$preloader.AddScript($preloadScript)
        $preloadOutput = ConvertTo-UiObjectArray -InputObject ($preloader.Invoke())
        $preloadErrors = ConvertTo-UiObjectArray -InputObject $preloader.Streams.Error
        if ($preloader.HadErrors -or $preloadErrors.Count -gt 0) {
            $message = ($preloadErrors | ForEach-Object { $_.ToString() }) -join "`r`n"
            if ([string]::IsNullOrWhiteSpace($message)) { $message = 'The worker module preloader reported an unspecified error.' }
            throw "Unable to run the Quest OdmApi preloader.`r`n$message"
        }
        if ($preloadOutput.Count -gt 0) { $preloadResult = $preloadOutput[$preloadOutput.Count - 1] }
        if ($null -eq $preloadResult) { throw 'The worker module preloader returned no status object.' }

        $initializer = [PowerShell]::Create()
        if ($null -eq $initializer) { throw 'PowerShell.Create returned no initializer instance.' }
        $initializer.Runspace = $runspace
        [void]$initializer.AddCommand('Import-Module').AddParameter('Name', $script:EngineModulePath).AddParameter('ErrorAction', 'Stop')
        $null = $initializer.Invoke()
        $initializerErrors = ConvertTo-UiObjectArray -InputObject $initializer.Streams.Error
        if ($initializer.HadErrors -or $initializerErrors.Count -gt 0) {
            $message = ($initializerErrors | ForEach-Object { $_.ToString() }) -join "`r`n"
            if ([string]::IsNullOrWhiteSpace($message)) { $message = 'The engine module import reported an unspecified error.' }
            throw "Unable to import the Quest ODM engine.`r`n$message"
        }

        $verifier = [PowerShell]::Create()
        if ($null -eq $verifier) { throw 'PowerShell.Create returned no verifier instance.' }
        $verifier.Runspace = $runspace
        [void]$verifier.AddCommand('Get-Command').AddParameter('Name', 'Invoke-QOdmOperation').AddParameter('ErrorAction', 'Stop')
        $commands = ConvertTo-UiObjectArray -InputObject ($verifier.Invoke())
        $verifyErrors = ConvertTo-UiObjectArray -InputObject $verifier.Streams.Error
        if ($verifier.HadErrors -or $verifyErrors.Count -gt 0 -or $commands.Count -eq 0) {
            $message = ($verifyErrors | ForEach-Object { $_.ToString() }) -join "`r`n"
            if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Invoke-QOdmOperation was not exported by the engine module.' }
            throw "Unable to validate the Quest ODM engine.`r`n$message"
        }

        $timer = New-Object Windows.Threading.DispatcherTimer
        if ($null -eq $timer) { throw 'Unable to create the worker completion timer.' }
        $timer.Interval = [TimeSpan]::FromMilliseconds(250)
        $timer.Add_Tick({ Complete-PendingOperation })

        # Commit resources only after every initialization step succeeds.
        $script:State.WorkerRunspace = $runspace
        $script:State.WorkerTimer = $timer
        $script:State.WorkerModulePreload = $preloadResult
        $runspace = $null
        $timer = $null
    }
    finally {
        if ($null -ne $preloader) { try { $preloader.Dispose() } catch { } }
        if ($null -ne $initializer) { try { $initializer.Dispose() } catch { } }
        if ($null -ne $verifier) { try { $verifier.Dispose() } catch { } }
        if ($null -ne $timer) { try { $timer.Stop() } catch { } }
        if ($null -ne $runspace) {
            try { $runspace.Close() } catch { }
            try { $runspace.Dispose() } catch { }
        }
    }

    $preloadStatus = [string](Get-ObjectPropertyValue -InputObject $script:State.WorkerModulePreload -Names @('Status') -Default 'UNKNOWN')
    $preloadDetails = [string](Get-ObjectPropertyValue -InputObject $script:State.WorkerModulePreload -Names @('Details','Error'))
    $level = if ($preloadStatus -in @('LOADED','ALREADY_LOADED')) { 'SUCCESS' } elseif ($preloadStatus -eq 'NOT_INSTALLED') { 'WARN' } else { 'ERROR' }
    Write-UiLog -Message ("Worker OdmApi preload: {0}. {1}" -f $preloadStatus, $preloadDetails) -Level $level
}

function Reset-UiAfterWorkerRestart {
    $script:State.Connected = $false
    $script:State.Context = $null
    Set-UiSafeModeState -SafeModeState ([pscustomobject]@{Enabled=$true;Reason='Safe Mode reset because the engine worker restarted.'})
    Set-ComboItems -Combo (Get-UiControl 'OrganizationCombo') -Items @()
    (Get-UiControl 'OrganizationIdBox').Text = ''
    Reset-WorkspaceUi
    Set-ConnectionStatus -Connected $false -Text 'Reconnect required'
    Update-UiEnablement
}

function Restart-WorkerRunspace {
    $previousState = Get-WorkerRunspaceState
    Start-WorkerRunspace
    Reset-UiAfterWorkerRestart
    Write-UiLog -Message "The engine worker was restarted after entering state '$previousState'. Quest ODM authentication and context must be re-established." -Level WARN
}

function Ensure-WorkerRunspace {
    param([Parameter(Mandatory = $true)][string]$Operation)

    if (Test-WorkerRunspaceHealthy) { return $false }
    $hadConnection = [bool](Get-ObjectPropertyValue -InputObject $script:State -Names @('Connected') -Default $false)
    Start-WorkerRunspace
    if ($hadConnection) {
        Reset-UiAfterWorkerRestart
        Write-UiLog -Message "The engine worker was unavailable before '$Operation' and was restarted. Reconnect to Quest ODM." -Level WARN
        return $true
    }
    return $false
}

function Write-EngineNonErrorStreams {
    param(
        [AllowNull()][object]$PowerShell,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    if ($null -eq $PowerShell) { return }
    $streams = Get-ObjectPropertyValue -InputObject $PowerShell -Names @('Streams')
    if ($null -eq $streams) { return }
    foreach ($record in (ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $streams -Names @('Warning') -Default @()))) {
        if ($null -ne $record) { Write-UiLog -Message "$Operation warning: $record" -Level WARN }
    }
    foreach ($record in (ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $streams -Names @('Information') -Default @()))) {
        if ($null -eq $record) { continue }
        $message = [string](Get-ObjectPropertyValue -InputObject $record -Names @('MessageData') -Default $record)
        if (-not [string]::IsNullOrWhiteSpace($message)) { Write-UiLog -Message "$Operation information: $message" }
    }
}

function Invoke-EngineSync {
    param([Parameter(Mandatory = $true)][string]$Operation, [hashtable]$Parameters = @{})

    $restarted = Ensure-WorkerRunspace -Operation $Operation
    if ($restarted -and $Operation -notin @('Connect','GetEnvironment','GetOperationCatalog')) {
        throw 'The engine worker was restarted. Reconnect to Quest ODM before retrying this operation.'
    }

    $ps = [PowerShell]::Create()
    if ($null -eq $ps) { throw 'PowerShell.Create returned no command instance.' }
    try {
        $runspace = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerRunspace')
        if ($null -eq $runspace) { throw 'The engine worker runspace is unavailable.' }
        $ps.Runspace = $runspace
        [void]$ps.AddCommand('Invoke-QOdmOperation').AddParameter('Operation', $Operation).AddParameter('Parameters', $Parameters)
        $output = ConvertTo-UiObjectArray -InputObject ($ps.Invoke())
        Write-EngineNonErrorStreams -PowerShell $ps -Operation $Operation
        $streamErrors = ConvertTo-UiObjectArray -InputObject $ps.Streams.Error
        if ($output.Count -eq 0 -and $streamErrors.Count -gt 0) {
            throw (($streamErrors | ForEach-Object { $_.ToString() } | Select-Object -Unique) -join "`r`n")
        }
        if (-not (Test-WorkerRunspaceHealthy)) {
            Restart-WorkerRunspace
            throw 'The engine worker stopped unexpectedly and was restarted. Reconnect to Quest ODM before retrying.'
        }
        if ($output.Count -eq 0) { throw "Engine operation '$Operation' returned no result." }
        return $output[$output.Count - 1]
    }
    finally { try { $ps.Dispose() } catch { } }
}

function Invoke-EngineAsync {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [hashtable]$Parameters = @{},
        [AllowNull()][scriptblock]$OnSuccess,
        [AllowNull()][scriptblock]$OnFailure,
        [AllowNull()][string]$Status
    )

    if ([bool](Get-ObjectPropertyValue -InputObject $script:State -Names @('Busy') -Default $false)) {
        Show-UiMessage -Text 'Another operation is already running.' -Type Warning
        return
    }

    $ps = $null
    try {
        $restarted = Ensure-WorkerRunspace -Operation $Operation
        if ($restarted -and $Operation -ne 'Connect') {
            Show-UiMessage -Text 'The Quest ODM engine worker was restarted. Reconnect before retrying this operation.' -Type Warning
            return
        }

        $runspace = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerRunspace')
        $timer = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerTimer')
        if ($null -eq $runspace -or $null -eq $timer) { throw 'The engine worker is not initialized.' }
        $ps = [PowerShell]::Create()
        if ($null -eq $ps) { throw 'PowerShell.Create returned no command instance.' }
        $ps.Runspace = $runspace
        [void]$ps.AddCommand('Invoke-QOdmOperation').AddParameter('Operation', $Operation).AddParameter('Parameters', $Parameters)
        $async = $ps.BeginInvoke()
        if ($null -eq $async) { throw 'BeginInvoke returned no asynchronous operation handle.' }

        $script:State.Pending = [pscustomobject]@{
            Operation = $Operation
            PowerShell = $ps
            Async      = $async
            OnSuccess  = $OnSuccess
            OnFailure  = $OnFailure
            StartedAt  = Get-Date
        }
        $ps = $null
        Write-UiLog -Message "Started operation: $Operation"
        Set-UiBusy -Busy $true -Status $(if ($Status) { $Status } else { "Running $Operation…" })
        $timer.Start()
    }
    catch {
        $pending = Get-ObjectPropertyValue -InputObject $script:State -Names @('Pending')
        if ($null -ne $pending -and (Get-ObjectPropertyValue -InputObject $pending -Names @('PowerShell')) -eq $ps) {
            $script:State.Pending = $null
            Dispose-UiPendingOperation -Pending $pending -Stop $true
            $ps = $null
        }
        if ($null -ne $ps) {
            try { $ps.Stop() } catch { }
            try { $ps.Dispose() } catch { }
        }
        $timer = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerTimer')
        if ($null -ne $timer) { try { $timer.Stop() } catch { } }
        Set-UiBusy -Busy $false -Status 'Ready.'
        $message = $_.Exception.Message
        Write-UiLog -Message "$Operation could not start: $message" -Level ERROR
        if (-not (Invoke-UiCallbackSafely -Callback $OnFailure -Arguments (New-UiCallbackArguments -First $message -Second $null) -CallbackName 'failure' -Operation $Operation)) { return }
        if ($null -eq $OnFailure) { Show-UiMessage -Text $message -Type Error }
    }
}

function Complete-PendingOperation {
    $pending = Get-ObjectPropertyValue -InputObject $script:State -Names @('Pending')
    if ($null -eq $pending) { return }

    $operation = [string](Get-ObjectPropertyValue -InputObject $pending -Names @('Operation') -Default 'Unknown')
    $async = Get-ObjectPropertyValue -InputObject $pending -Names @('Async')
    $powerShell = Get-ObjectPropertyValue -InputObject $pending -Names @('PowerShell')
    if ($null -eq $async -or $null -eq $powerShell) {
        $timer = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerTimer')
        if ($null -ne $timer) { try { $timer.Stop() } catch { } }
        $script:State.Pending = $null
        Dispose-UiPendingOperation -Pending $pending -Stop $true
        Set-UiBusy -Busy $false -Status 'Ready.'
        $message = "Pending operation '$operation' lost its PowerShell or asynchronous handle. Reconnect and retry."
        Write-UiLog -Message $message -Level ERROR
        $failure = Get-ObjectPropertyValue -InputObject $pending -Names @('OnFailure')
        if ($null -eq $failure) { Show-UiMessage -Text $message -Type Error }
        else { $null = Invoke-UiCallbackSafely -Callback $failure -Arguments (New-UiCallbackArguments -First $message -Second $null) -CallbackName 'failure' -Operation $operation }
        return
    }

    try { if (-not [bool]$async.IsCompleted) { return } }
    catch {
        $timer = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerTimer')
        if ($null -ne $timer) { try { $timer.Stop() } catch { } }
        $script:State.Pending = $null
        Dispose-UiPendingOperation -Pending $pending -Stop $true
        Set-UiBusy -Busy $false -Status 'Ready.'
        $message = "Unable to inspect asynchronous state for '$operation': $($_.Exception.Message)"
        Write-UiLog -Message $message -Level ERROR
        Show-UiMessage -Text $message -Type Error
        return
    }

    $timer = Get-ObjectPropertyValue -InputObject $script:State -Names @('WorkerTimer')
    if ($null -ne $timer) { try { $timer.Stop() } catch { } }
    $script:State.Pending = $null
    $output = @()
    $streamErrors = [System.Collections.Generic.List[object]]::new()
    try { $output = ConvertTo-UiObjectArray -InputObject ($powerShell.EndInvoke($async)) }
    catch { $streamErrors.Add($_) | Out-Null }
    finally {
        try { Write-EngineNonErrorStreams -PowerShell $powerShell -Operation $operation } catch { }
        $streams = Get-ObjectPropertyValue -InputObject $powerShell -Names @('Streams')
        foreach ($record in (ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $streams -Names @('Error') -Default @()))) {
            if ($null -ne $record) {
                $streamErrors.Add($record) | Out-Null
                Write-UiLog -Message "$operation error stream: $record" -Level ERROR
            }
        }
        Dispose-UiPendingOperation -Pending $pending
    }

    Set-UiBusy -Busy $false -Status 'Ready.'
    $onFailure = Get-ObjectPropertyValue -InputObject $pending -Names @('OnFailure')
    $onSuccess = Get-ObjectPropertyValue -InputObject $pending -Names @('OnSuccess')

    if (-not (Test-WorkerRunspaceHealthy)) {
        $recoveryError = $null
        try { Restart-WorkerRunspace }
        catch { $recoveryError = $_.Exception.Message; Reset-UiAfterWorkerRestart }
        $message = if ($recoveryError) { "The Quest ODM engine worker stopped unexpectedly and could not be restarted: $recoveryError" } else { 'The Quest ODM engine worker stopped unexpectedly and was restarted. Reconnect before retrying the operation.' }
        Write-UiLog -Message $message -Level ERROR
        if ($null -eq $onFailure) { Show-UiMessage -Text $message -Type Error }
        else { $null = Invoke-UiCallbackSafely -Callback $onFailure -Arguments (New-UiCallbackArguments -First $message -Second $null) -CallbackName 'failure' -Operation $operation }
        return
    }

    if ($output.Count -eq 0) {
        $message = if ($streamErrors.Count -gt 0) { ($streamErrors.ToArray() | ForEach-Object { $_.ToString() } | Select-Object -Unique) -join "`r`n" } else { "Engine operation '$operation' returned no result." }
        Write-UiLog -Message "$operation failed: $message" -Level ERROR
        if ($null -eq $onFailure) { Show-UiMessage -Text $message -Type Error }
        else { $null = Invoke-UiCallbackSafely -Callback $onFailure -Arguments (New-UiCallbackArguments -First $message -Second $null) -CallbackName 'failure' -Operation $operation }
        return
    }

    $result = $output[$output.Count - 1]
    $hasSuccess = $false
    $successSentinel = [Guid]::NewGuid().ToString()
    $successValue = Get-ObjectPropertyValue -InputObject $result -Names @('Success') -Default $successSentinel
    $hasSuccess = -not [string]::Equals([string]$successValue, $successSentinel, [StringComparison]::Ordinal)
    if (-not $hasSuccess) {
        $message = "Engine operation '$operation' returned an unexpected result object."
        Write-UiLog -Message $message -Level ERROR
        if ($null -eq $onFailure) { Show-UiMessage -Text $message -Type Error }
        else { $null = Invoke-UiCallbackSafely -Callback $onFailure -Arguments (New-UiCallbackArguments -First $message -Second $result) -CallbackName 'failure' -Operation $operation }
        return
    }

    if (-not (Test-ObjectPropertyTrue -InputObject $result -Names @('Success'))) {
        $message = [string](Get-ObjectPropertyValue -InputObject $result -Names @('Error','Message'))
        $diagnosticText = Get-UiDiagnosticText -Result $result -FallbackMessage $message -Operation $operation
        Write-UiLog -Message $diagnosticText -Level ERROR
        if ($null -eq $onFailure) { Show-UiMessage -Text $diagnosticText -Type Error }
        else { $null = Invoke-UiCallbackSafely -Callback $onFailure -Arguments (New-UiCallbackArguments -First $diagnosticText -Second $result) -CallbackName 'failure' -Operation $operation }
        return
    }

    $resultMessage = [string](Get-ObjectPropertyValue -InputObject $result -Names @('Message'))
    if ([string]::IsNullOrWhiteSpace($resultMessage)) { $resultMessage = "$operation completed." }
    Write-UiLog -Message $resultMessage -Level SUCCESS
    foreach ($warning in (ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $result -Names @('Warnings') -Default @()))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$warning)) { Write-UiLog -Message "$operation warning: $warning" -Level WARN }
    }
    foreach ($report in (ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $result -Names @('Reports') -Default @()))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$report)) { Write-UiLog -Message "Report: $report" }
    }
    if ($null -ne $onSuccess) {
        $data = Get-ObjectPropertyValue -InputObject $result -Names @('Data')
        $null = Invoke-UiCallbackSafely -Callback $onSuccess -Arguments (New-UiCallbackArguments -First $data -Second $result) -CallbackName 'success' -Operation $operation
    }
}



function ConvertTo-OverviewCountText {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '0' }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '0' }
    return $text
}

function Format-OverviewRefreshedAt {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToString('yyyy-MM-dd HH:mm:ss') }

    $parsed = [DateTime]::MinValue
    $text = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($text) -and [DateTime]::TryParse($text, [ref]$parsed)) {
        return $parsed.ToString('yyyy-MM-dd HH:mm:ss')
    }
    return $text
}

function Show-OverviewSnapshot {
    [CmdletBinding()]
    param([AllowNull()][object]$Snapshot = $script:State.OverviewSnapshot)

    if ($null -eq $Snapshot) {
        (Get-UiControl 'OverviewObjectCount').Text = '—'
        (Get-UiControl 'OverviewTaskCount').Text = '—'
        (Get-UiControl 'OverviewCollectionCount').Text = '—'
        (Get-UiControl 'OverviewRunningCount').Text = '—'
        (Get-UiControl 'OverviewFailedCount').Text = '—'
    }
    else {
        (Get-UiControl 'OverviewObjectCount').Text = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('ObjectCount'))
        (Get-UiControl 'OverviewTaskCount').Text = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('TaskCount'))
        (Get-UiControl 'OverviewCollectionCount').Text = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('CollectionCount'))
        (Get-UiControl 'OverviewRunningCount').Text = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('RunningTasks'))
        (Get-UiControl 'OverviewFailedCount').Text = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('FailedTasks'))
    }

    $statusText = [string](Get-ObjectPropertyValue -InputObject $script:State -Names @('OverviewStatusText'))
    if ([string]::IsNullOrWhiteSpace($statusText)) {
        if ($null -eq $Snapshot) {
            $statusText = 'No workspace refresh has run.'
        }
        else {
            $refreshedAt = Format-OverviewRefreshedAt -Value (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('RefreshedAt'))
            $statusText = if ([string]::IsNullOrWhiteSpace($refreshedAt)) { 'Workspace snapshot loaded.' } else { "Last refreshed: $refreshedAt" }
        }
    }
    (Get-UiControl 'OverviewRefreshedText').Text = $statusText
}

function Clear-OverviewSnapshot {
    [CmdletBinding()]
    param([string]$StatusText = 'No workspace refresh has run.')

    $script:State.OverviewSnapshot = $null
    $script:State.OverviewStatusText = $StatusText
    Show-OverviewSnapshot
}

function Set-OverviewSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Dashboard)

    $dashboardState = Get-ObjectPropertyValue -InputObject $Dashboard -Names @('State')
    $refreshedAt = Get-ObjectPropertyValue -InputObject $Dashboard -Names @('RefreshedAt') -Default (Get-Date)
    $snapshot = [pscustomobject]@{
        WorkloadId     = [string](Get-ObjectPropertyValue -InputObject $dashboardState -Names @('WorkloadId'))
        ObjectCount    = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Dashboard -Names @('ObjectCount') -Default 0)
        TaskCount      = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Dashboard -Names @('TaskCount') -Default 0)
        CollectionCount = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Dashboard -Names @('CollectionCount') -Default 0)
        RunningTasks   = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Dashboard -Names @('RunningTasks') -Default 0)
        FailedTasks    = ConvertTo-OverviewCountText -Value (Get-ObjectPropertyValue -InputObject $Dashboard -Names @('FailedTasks') -Default 0)
        RefreshedAt    = $refreshedAt
    }

    $script:State.OverviewSnapshot = $snapshot
    $formatted = Format-OverviewRefreshedAt -Value $refreshedAt
    $script:State.OverviewStatusText = if ([string]::IsNullOrWhiteSpace($formatted)) { 'Workspace snapshot loaded.' } else { "Last refreshed: $formatted" }
    Show-OverviewSnapshot -Snapshot $snapshot
}

function Set-OverviewRefreshPending {
    [CmdletBinding()]
    param()

    $snapshot = Get-ObjectPropertyValue -InputObject $script:State -Names @('OverviewSnapshot')
    if ($null -eq $snapshot) {
        $script:State.OverviewStatusText = 'Refreshing workspace…'
    }
    else {
        $previous = Format-OverviewRefreshedAt -Value (Get-ObjectPropertyValue -InputObject $snapshot -Names @('RefreshedAt'))
        $script:State.OverviewStatusText = if ([string]::IsNullOrWhiteSpace($previous)) {
            'Refreshing workspace… showing the last completed snapshot.'
        }
        else {
            "Refreshing workspace… showing the last completed snapshot from $previous."
        }
    }
    Show-OverviewSnapshot -Snapshot $snapshot
}

function Set-OverviewRefreshFailed {
    [CmdletBinding()]
    param([AllowNull()][string]$Message)

    $snapshot = Get-ObjectPropertyValue -InputObject $script:State -Names @('OverviewSnapshot')
    if ($null -eq $snapshot) {
        $script:State.OverviewStatusText = 'Workspace refresh failed. No completed snapshot is available.'
    }
    else {
        $previous = Format-OverviewRefreshedAt -Value (Get-ObjectPropertyValue -InputObject $snapshot -Names @('RefreshedAt'))
        $script:State.OverviewStatusText = if ([string]::IsNullOrWhiteSpace($previous)) {
            'Workspace refresh failed; the last completed snapshot remains displayed.'
        }
        else {
            "Workspace refresh failed; the completed snapshot from $previous remains displayed."
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        Write-UiLog -Message "Workspace refresh retained the previous overview snapshot after failure: $Message" -Level WARN
    }
    Show-OverviewSnapshot -Snapshot $snapshot
}

function Clear-WorkloadDataUi {
    $script:State.WorkloadSelected = $false
    $script:State.TaskItems = @()
    $script:State.CollectionItems = @()
    $script:State.TemplateItems = @()
    foreach ($gridName in @('UserGrid','UserTaskAssociationsGrid','UserCollectionAssociationsGrid','TaskGrid','TaskMembersGrid','CollectionGrid','CollectionMembersGrid','FactorySummaryGrid','BulkResultsGrid')) {
        Set-GridItems -Grid (Get-UiControl $gridName) -Items @()
    }
    foreach ($comboName in @('UserTargetTaskCombo','UserTargetCollectionCombo','FactoryMailTemplateCombo','FactoryOneDriveTemplateCombo','FactoryMeetingLinkTemplateCombo','FactoryMailboxSwitchTemplateCombo')) {
        Set-ComboItems -Combo (Get-UiControl $comboName) -Items @()
    }
    Clear-OverviewSnapshot -StatusText 'No workspace refresh has run for the selected context.'
    Update-UiEnablement
}

function Reset-WorkspaceUi {
    $script:State.WorkloadSelected = $false
    $script:State.TaskItems = @()
    $script:State.CollectionItems = @()
    $script:State.TemplateItems = @()
    foreach ($gridName in @('UserGrid','UserTaskAssociationsGrid','UserCollectionAssociationsGrid','TaskGrid','TaskMembersGrid','CollectionGrid','CollectionMembersGrid','FactorySummaryGrid','BulkResultsGrid')) {
        Set-GridItems -Grid (Get-UiControl $gridName) -Items @()
    }
    foreach ($comboName in @('ProjectCombo','WorkloadCombo','UserTargetTaskCombo','UserTargetCollectionCombo','FactoryMailTemplateCombo','FactoryOneDriveTemplateCombo','FactoryMeetingLinkTemplateCombo','FactoryMailboxSwitchTemplateCombo')) {
        Set-ComboItems -Combo (Get-UiControl $comboName) -Items @()
    }
    Clear-OverviewSnapshot -StatusText 'No workspace refresh has run.'
    (Get-UiControl 'OverviewContextText').Text = 'Connect and select a workload to begin.'
    $script:State.TaskDetails = $null
    (Get-UiControl 'TaskDetailsTextBox').Text = 'No task details loaded.'
    (Get-UiControl 'TaskDetailsStatusText').Text = 'Select one task and refresh details.'
    Set-GridItems -Grid (Get-UiControl 'TaskEventsGrid') -Items @()
    $script:State.LastReadiness = $null
    $script:State.ReadinessHtmlPath = $null
    $script:State.ReadinessJsonPath = $null
    $script:State.BlockedFeatures = @()
    (Get-UiControl 'ReadinessSummaryText').Text = 'No readiness check has run for the active context.'
    Set-GridItems -Grid (Get-UiControl 'ReadinessGrid') -Items @()
    (Get-UiControl 'OpenReadinessReportButton').IsEnabled = $false
    (Get-UiControl 'CopyReadinessSummaryButton').IsEnabled = $false
    Update-UiEnablement
}

function Apply-ContextState {
    param([AllowNull()][object]$Context)
    if ($null -eq $Context) { return }

    $script:State.Context = $Context
    $script:State.BlockedFeatures = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Context -Names @('BlockedFeatures') -Default @())
    Set-UiSafeModeState -SafeModeState ([pscustomobject]@{
        Enabled=[bool](Get-ObjectPropertyValue -InputObject $Context -Names @('SafeMode') -Default $true)
        Reason=[string](Get-ObjectPropertyValue -InputObject $Context -Names @('SafeModeReason') -Default 'Safe Mode enabled.')
    })
    $connected = [bool](Get-ObjectPropertyValue -InputObject $Context -Names @('Connected') -Default $false)
    $contextValid = [bool](Get-ObjectPropertyValue -InputObject $Context -Names @('ContextValid') -Default $true)
    $workloadId = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('WorkloadId'))
    $organizationName = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('OrganizationName'))
    $moduleVersion = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('ModuleVersion'))
    $modulePath = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('ModulePath'))

    $script:State.Connected = $connected
    $script:State.WorkloadSelected = ($connected -and $contextValid -and -not [string]::IsNullOrWhiteSpace($workloadId))
    if ($connected) {
        $label = if (-not [string]::IsNullOrWhiteSpace($organizationName)) { $organizationName } else { 'Connected' }
        if (-not $contextValid) { $label = 'Reconnect required' }
        Set-ConnectionStatus -Connected $contextValid -Text $label
    }
    else { Set-ConnectionStatus -Connected $false -Text 'Disconnected' }

    (Get-UiControl 'OverviewModuleText').Text = if (-not [string]::IsNullOrWhiteSpace($moduleVersion)) { "OdmApi $moduleVersion`r`n$modulePath" } else { 'OdmApi not loaded.' }
    if ($script:State.WorkloadSelected) {
        $region = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('Region'))
        $organizationId = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('OrganizationId'))
        $projectName = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('ProjectName'))
        $projectId = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('ProjectId'))
        $workloadName = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('WorkloadName'))
        $workloadType = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('WorkloadType'))
        (Get-UiControl 'OverviewContextText').Text = "Region: $region`r`nOrganization: $organizationName [$organizationId]`r`nProject: $projectName [$projectId]`r`nWorkload: $workloadName — $workloadType [$workloadId]"
    }
    elseif ($connected -and -not $contextValid) {
        $contextError = [string](Get-ObjectPropertyValue -InputObject $Context -Names @('ContextError') -Default 'The Quest context is invalid. Reconnect before continuing.')
        (Get-UiControl 'OverviewContextText').Text = $contextError
    }
    Update-UiEnablement
}

function Apply-WorkspaceSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    $dashboard = Get-ObjectPropertyValue -InputObject $Snapshot -Names @('Dashboard')
    if ($null -eq $dashboard) { throw 'The workspace snapshot did not contain dashboard data.' }
    Apply-ContextState -Context (Get-ObjectPropertyValue -InputObject $dashboard -Names @('State'))

    $script:State.TaskItems = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('Tasks') -Default @())
    $script:State.CollectionItems = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('Collections') -Default @())
    $script:State.TemplateItems = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('Templates') -Default @())
    Set-GridItems -Grid (Get-UiControl 'TaskGrid') -Items $script:State.TaskItems
    Set-GridItems -Grid (Get-UiControl 'CollectionGrid') -Items $script:State.CollectionItems
    Set-ComboItems -Combo (Get-UiControl 'UserTargetTaskCombo') -Items $script:State.TaskItems
    Set-ComboItems -Combo (Get-UiControl 'UserTargetCollectionCombo') -Items $script:State.CollectionItems
    foreach ($name in @('FactoryMailTemplateCombo','FactoryOneDriveTemplateCombo','FactoryMeetingLinkTemplateCombo','FactoryMailboxSwitchTemplateCombo')) {
        Set-ComboItems -Combo (Get-UiControl $name) -Items $script:State.TemplateItems
    }

    $statusCombo = Get-UiControl 'TaskStatusCombo'
    $statusCombo.ItemsSource = $null
    $statusCombo.Items.Clear()
    [void]$statusCombo.Items.Add('All')
    foreach ($status in (ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Snapshot -Names @('TaskStatuses') -Default @()))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$status)) { [void]$statusCombo.Items.Add([string]$status) }
    }
    $statusCombo.SelectedIndex = 0
    # Commit the new overview snapshot only after the complete workspace payload has
    # been applied successfully. Until this point the prior snapshot stays visible.
    Set-OverviewSnapshot -Dashboard $dashboard
    Update-UiEnablement
    Show-OverviewSnapshot
}

function Refresh-Workspace {
    if (-not $script:State.WorkloadSelected -or $script:State.Busy) { return }
    Set-OverviewRefreshPending
    Invoke-EngineAsync -Operation 'WorkspaceSnapshot' -Parameters @{ Refresh = $true } -Status 'Refreshing ODM objects, tasks, collections, and templates…' -OnSuccess {
        param($data)
        try { Apply-WorkspaceSnapshot -Snapshot $data }
        catch {
            Set-OverviewRefreshFailed -Message $_.Exception.Message
            throw
        }
    } -OnFailure {
        param($message)
        Set-OverviewRefreshFailed -Message $message
    }
}

function Format-EnvironmentInfo {
    param([Parameter(Mandatory = $true)][object]$Data)

    $api = Get-ObjectPropertyValue -InputObject $Data -Names @('ApiSurface')
    $engineState = Get-ObjectPropertyValue -InputObject $Data -Names @('EngineState')
    $preload = Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiPreload')
    $probe = Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiRuntimeProbe')
    $missingRequired = if ($null -ne $api) { (ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $api -Names @('MissingRequired') -Default @())) -join ', ' } else { '' }
    $missingOptional = if ($null -ne $api) { (ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $api -Names @('MissingOptional') -Default @())) -join ', ' } else { '' }
    $contractIssues = if ($null -ne $api) { (ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $api -Names @('ParameterContractIssues') -Default @())) -join '; ' } else { '' }
    $apiAssessed = if ($null -ne $api) { Get-ObjectPropertyValue -InputObject $api -Names @('Assessed') } else { $null }
    $apiCompatible = if ($null -ne $api) { Get-ObjectPropertyValue -InputObject $api -Names @('Compatible') } else { $null }
    $hostRecommendation = if ($null -ne $api) { [string](Get-ObjectPropertyValue -InputObject $api -Names @('HostRecommendation')) } else { '' }
    return @(
        "Computer:              $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('ComputerName')))",
        "User:                  $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('UserName')))",
        "Process:               $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('ProcessPath')))",
        "PowerShell:            $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('PowerShellVersion'))) ($([string](Get-ObjectPropertyValue -InputObject $Data -Names @('PowerShellEdition'))))",
        "Apartment state:       $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('ApartmentState')))",
        "64-bit process:        $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('Is64BitProcess')))",
        "64-bit OS:             $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('Is64BitOperatingSystem')))",
        "Elevated:              $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('IsElevated')))",
        "Data root:             $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('DataRoot')))",
        "Default reports:       $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('DefaultReportDirectory')))",
        "Default logs:          $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('DefaultLogDirectory')))",
        "OdmApi installed:      $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiInstalled')))",
        "OdmApi loaded:         $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiLoaded')))",
        "OdmApi version:        $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiVersion')))",
        "OdmApi path:           $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiPath')))",
        "Feature compatible:    $([string](Get-ObjectPropertyValue -InputObject (Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiModuleStatus')) -Names @('FeatureCompatible')))",
        "Missing feature commands: $((ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject (Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiModuleStatus')) -Names @('MissingFeatureCommands') -Default @())) -join ', ')",
        "Worker preload:        $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiPreloadStatus') -Default 'NOT_RUN'))",
        "Preload details:       $([string](Get-ObjectPropertyValue -InputObject $preload -Names @('Details','Error')))",
        "Runtime probe:         $([string](Get-ObjectPropertyValue -InputObject $Data -Names @('OdmApiRuntimeProbeStatus') -Default 'NOT_RUN'))",
        "Probe details:         $([string](Get-ObjectPropertyValue -InputObject $probe -Names @('Details','Error')))",
        "API surface assessed:  $apiAssessed",
        "API surface compatible:$apiCompatible",
        "Missing required:      $missingRequired",
        "Missing optional:      $missingOptional",
        "Contract issues:       $contractIssues",
        "Host guidance:         $hostRecommendation",
        "Connected:             $([string](Get-ObjectPropertyValue -InputObject $engineState -Names @('Connected')))",
        "Selected workload:     $([string](Get-ObjectPropertyValue -InputObject $engineState -Names @('WorkloadName'))) [$([string](Get-ObjectPropertyValue -InputObject $engineState -Names @('WorkloadId')))]"
    ) -join "`r`n"
}

function Select-MainTabByHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Header)

    $tabs = Get-UiControl 'MainTabControl'
    foreach ($item in (ConvertTo-UiObjectArray -InputObject $tabs.Items)) {
        if ([string]::Equals([string]$item.Header, $Header, [StringComparison]::OrdinalIgnoreCase)) {
            $tabs.SelectedItem = $item
            return $true
        }
    }
    return $false
}

function Apply-OdmApiModuleStatus {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Status,
        [bool]$NavigateWhenMissing = $false
    )

    if ($null -eq $Status) { return }
    $script:State.ModuleStatus = $Status
    $script:State.ModuleStatusKnown = $true
    $script:State.ModuleInstalled = Test-ObjectPropertyTrue -InputObject $Status -Names @('Installed')
    $script:State.ModuleUpdateAvailable = Test-ObjectPropertyTrue -InputObject $Status -Names @('UpdateRecommended','UpdateAvailable')
    $script:State.ModuleCanInstall = Test-ObjectPropertyTrue -InputObject $Status -Names @('CanInstall')
    $script:State.ModuleOnlineChecked = Test-ObjectPropertyTrue -InputObject $Status -Names @('OnlineChecked')

    $statusText = [string](Get-ObjectPropertyValue -InputObject $Status -Names @('StatusText') -Default 'OdmApi status is unavailable.')
    $installed = [string](Get-ObjectPropertyValue -InputObject $Status -Names @('InstalledVersionText'))
    $loaded = [string](Get-ObjectPropertyValue -InputObject $Status -Names @('LoadedVersionText'))
    $minimum = [string](Get-ObjectPropertyValue -InputObject $Status -Names @('MinimumVersionText'))
    $validated = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Status -Names @('ValidatedVersions') -Default @())
    $preferred = [string](Get-ObjectPropertyValue -InputObject $Status -Names @('PreferredValidatedVersion'))
    $latest = [string](Get-ObjectPropertyValue -InputObject $Status -Names @('LatestOnlineVersionText'))
    $compatStatus = [string](Get-ObjectPropertyValue -InputObject $Status -Names @('CompatibilityStatus') -Default 'UNKNOWN')
    $missing = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Status -Names @('MissingFeatureCommands') -Default @())
    $details = [System.Collections.Generic.List[string]]::new()
    $details.Add($statusText) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($installed)) { $details.Add("Installed: $installed") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($loaded)) { $details.Add("Loaded in worker: $loaded") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($minimum)) { $details.Add("Minimum: $minimum") | Out-Null }
    if ($validated.Count -gt 0) { $details.Add("Validated: $($validated -join ', ')") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($latest)) { $details.Add("Latest available: $latest") | Out-Null }
    if ($missing.Count -gt 0) { $details.Add("Missing commands: $($missing -join ', ')") | Out-Null }
    (Get-UiControl 'OdmApiModuleStatusText').Text = ($details -join "`r`n")
    (Get-UiControl 'CompatibilityStatusText').Text = "Compatibility: $compatStatus. Normal installation target: $preferred."
    if (-not [string]::IsNullOrWhiteSpace($preferred)) {
        (Get-UiControl 'InstallModuleCommandBox').Text = "Install-Module OdmApi -RequiredVersion $preferred -Scope CurrentUser -Force -AllowClobber"
    }

    if (-not $script:State.ModuleInstalled) {
        (Get-UiControl 'OdmApiModuleActionText').Text = 'OdmApi is required for Quest connectivity. Install the validated version for the current user.'
        if ($NavigateWhenMissing) { $null = Select-MainTabByHeader -Header 'Diagnostics' }
    }
    elseif ($compatStatus -eq 'VALIDATED') {
        (Get-UiControl 'OdmApiModuleActionText').Text = if ($script:State.ModuleOnlineChecked -and -not [string]::IsNullOrWhiteSpace($latest) -and $latest -ne $installed) { 'The installed version is validated. A newer, unvalidated Gallery version is available as an advanced option.' } else { 'The installed OdmApi version is validated for this console release.' }
    }
    elseif ($compatStatus -eq 'UNVALIDATED') {
        (Get-UiControl 'OdmApiModuleActionText').Text = 'The installed version meets the minimum but has not been validated for this console. Use Repair validated to return to the supported version.'
    }
    else {
        (Get-UiControl 'OdmApiModuleActionText').Text = 'The installed module is below the minimum or lacks required commands. Install the validated version before using affected features.'
    }
    Update-UiEnablement
}

function Update-OdmApiModuleStatus {
    [CmdletBinding()]
    param([bool]$CheckOnline = $false)

    $statusText = if ($CheckOnline) { 'Checking OdmApi against PowerShell Gallery…' } else { 'Checking installed OdmApi module…' }
    Invoke-EngineAsync -Operation 'GetOdmApiModuleStatus' -Parameters @{ CheckOnline = $CheckOnline } -Status $statusText -OnSuccess {
        param($data)
        Apply-OdmApiModuleStatus -Status $data -NavigateWhenMissing $true
        $message = [string](Get-ObjectPropertyValue -InputObject $data -Names @('StatusText'))
        if (-not [string]::IsNullOrWhiteSpace($message)) { Write-UiLog -Message $message }
    }
}

function Invoke-OdmApiModuleAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install','Update')][string]$Action,
        [ValidateSet('Validated','Latest')][string]$Target = 'Validated'
    )

    $targetLabel = if ($Target -eq 'Validated') { 'the console-validated OdmApi version' } else { 'the latest PowerShell Gallery OdmApi version (not necessarily validated)' }
    $confirmation = "$Action $targetLabel for the current user?"
    if ($Target -eq 'Latest') { $confirmation += "`r`n`r`nThis advanced action may install an API version that has not been validated with console 1.1.0-preview.6." }
    if ($script:State.Connected) { $confirmation += "`r`n`r`nThe Quest session will be disconnected and the engine worker will restart." }
    if (-not (Confirm-UiAction -Text $confirmation -Title "$Action OdmApi")) { return }

    $script:State.OdmApiModuleActionContext = [pscustomobject]@{ Action = [string]$Action; Target = [string]$Target }
    $callback = {
        param($data)
        $moduleActionContext = Get-ObjectPropertyValue -InputObject $script:State -Names @('OdmApiModuleActionContext')
        $actionValue = [string](Get-ObjectPropertyValue -InputObject $moduleActionContext -Names @('Action') -Default 'Module action')
        $targetValue = [string](Get-ObjectPropertyValue -InputObject $moduleActionContext -Names @('Target') -Default 'Unknown')
        try {
            $details = [string](Get-ObjectPropertyValue -InputObject $data -Names @('Details') -Default "OdmApi $actionValue completed.")
            (Get-UiControl 'OdmApiModuleActionText').Text = $details
            if (Test-ObjectPropertyTrue -InputObject $data -Names @('RequiresWorkerRestart')) {
                Restart-WorkerRunspace
                Write-UiLog -Message 'The worker restarted to load the selected OdmApi version. Safe Mode was reset and Quest reconnection is required.' -Level WARN
            }
            $statusResult = Invoke-EngineSync -Operation 'GetOdmApiModuleStatus' -Parameters @{ CheckOnline = $true }
            if (Test-ObjectPropertyTrue -InputObject $statusResult -Names @('Success')) { Apply-OdmApiModuleStatus -Status (Get-ObjectPropertyValue -InputObject $statusResult -Names @('Data')) }
            $environmentResult = Invoke-EngineSync -Operation 'GetEnvironment'
            if (Test-ObjectPropertyTrue -InputObject $environmentResult -Names @('Success')) {
                $environmentData = Get-ObjectPropertyValue -InputObject $environmentResult -Names @('Data')
                (Get-UiControl 'EnvironmentTextBox').Text = Format-EnvironmentInfo -Data $environmentData
                Apply-ContextState -Context (Get-ObjectPropertyValue -InputObject $environmentData -Names @('EngineState'))
            }
            Show-UiMessage -Text $details -Type Info
        }
        catch {
            Write-UiLog -Message "OdmApi $actionValue/$targetValue post-install refresh failed: $($_.Exception.Message)" -Level ERROR
            Show-UiMessage -Text ("The module action completed, but the console could not refresh its worker state. Close and reopen the console before connecting.`r`n`r`n{0}" -f $_.Exception.Message) -Type Warning
        }
        finally { $script:State.OdmApiModuleActionContext = $null }
    }
    $failureCallback = {
        param($message,$result)
        $script:State.OdmApiModuleActionContext = $null
        Show-UiMessage -Text $message -Type Error
    }
    Invoke-EngineAsync -Operation 'InstallOdmApiModule' -Parameters @{Action=$Action;Target=$Target} -Status "$Action OdmApi ($Target)…" -OnSuccess $callback -OnFailure $failureCallback
}


function Format-TaskDetailsText {
    [CmdletBinding()]
    param([AllowNull()][object]$Details)

    if ($null -eq $Details) { return 'No task details loaded.' }
    $task = Get-ObjectPropertyValue -InputObject $Details -Names @('Task')
    if ($null -eq $task) { return 'The task details response did not contain a task record.' }
    return @(
        "Name:              $([string](Get-ObjectPropertyValue -InputObject $task -Names @('Name')))",
        "Task ID:           $([string](Get-ObjectPropertyValue -InputObject $task -Names @('Id')))",
        "Type:              $([string](Get-ObjectPropertyValue -InputObject $task -Names @('Type')))",
        "Status:            $([string](Get-ObjectPropertyValue -InputObject $task -Names @('Status')))",
        "Created:           $([string](Get-ObjectPropertyValue -InputObject $task -Names @('Created')))",
        "Started:           $([string](Get-ObjectPropertyValue -InputObject $task -Names @('Started')))",
        "Completed:         $([string](Get-ObjectPropertyValue -InputObject $task -Names @('Completed')))",
        "Duration:          $([string](Get-ObjectPropertyValue -InputObject $task -Names @('Duration')))",
        "Collection:        $([string](Get-ObjectPropertyValue -InputObject $task -Names @('Collection')))",
        "Members/objects:   $([string](Get-ObjectPropertyValue -InputObject $task -Names @('MemberCount')))",
        "Processed:         $([string](Get-ObjectPropertyValue -InputObject $task -Names @('ProcessedCount')))",
        "Succeeded:         $([string](Get-ObjectPropertyValue -InputObject $task -Names @('SucceededCount')))",
        "Failed:            $([string](Get-ObjectPropertyValue -InputObject $task -Names @('FailedCount')))",
        "Last event:        $([string](Get-ObjectPropertyValue -InputObject $task -Names @('LastEvent')))",
        "Last error:        $([string](Get-ObjectPropertyValue -InputObject $task -Names @('LastError')))",
        "Loaded:            $([string](Get-ObjectPropertyValue -InputObject $Details -Names @('LoadedAt')))",
        "Event read error:  $([string](Get-ObjectPropertyValue -InputObject $Details -Names @('EventError')))",
        "Report read error: $([string](Get-ObjectPropertyValue -InputObject $Details -Names @('ReportingError')))"
    ) -join "`r`n"
}

function Apply-TaskDetails {
    [CmdletBinding()]
    param([AllowNull()][object]$Details)

    $script:State.TaskDetails = $Details
    (Get-UiControl 'TaskDetailsTextBox').Text = Format-TaskDetailsText -Details $Details
    Set-GridItems -Grid (Get-UiControl 'TaskEventsGrid') -Items (Get-ObjectPropertyValue -InputObject $Details -Names @('Events') -Default @())
    $task = Get-ObjectPropertyValue -InputObject $Details -Names @('Task')
    $name = [string](Get-ObjectPropertyValue -InputObject $task -Names @('Name') -Default 'Task')
    $status = [string](Get-ObjectPropertyValue -InputObject $task -Names @('Status') -Default 'Unknown')
    $loaded = [string](Get-ObjectPropertyValue -InputObject $Details -Names @('LoadedAt'))
    (Get-UiControl 'TaskDetailsStatusText').Text = "$name — $status — refreshed $loaded"
    Update-UiEnablement
}

function Refresh-SelectedTaskDetails {
    [CmdletBinding()]
    param([bool]$Automatic = $false)

    if ($script:State.Busy) { return }
    $items = ConvertTo-UiObjectArray -InputObject (Get-SelectedGridItems -Grid (Get-UiControl 'TaskGrid'))
    if ($items.Count -ne 1) {
        if (-not $Automatic) { Show-UiMessage -Text 'Select exactly one task.' -Type Warning }
        return
    }
    $taskId = [string](Get-ObjectPropertyValue -InputObject $items[0] -Names @('Id'))
    if ([string]::IsNullOrWhiteSpace($taskId)) { return }
    (Get-UiControl 'TaskDetailsStatusText').Text = if ($Automatic) { 'Auto-refreshing task details…' } else { 'Refreshing task details…' }
    $failureCallback = if ($Automatic) {
        {
            param($message,$result)
            (Get-UiControl 'TaskDetailsStatusText').Text = 'Task detail auto-refresh failed; the previous details remain displayed.'
            Write-UiLog -Message "Task detail auto-refresh failed: $message" -Level WARN
        }
    }
    else {
        {
            param($message,$result)
            (Get-UiControl 'TaskDetailsStatusText').Text = 'Task detail refresh failed; the previous details remain displayed.'
            Show-UiMessage -Text $message -Type Error
        }
    }
    Invoke-EngineAsync -Operation 'GetTaskDetails' -Parameters @{TaskId=$taskId;IncludeEvents=$true;IncludeReporting=$true} -Status $(if ($Automatic) {'Auto-refreshing task details…'} else {'Loading task details…'}) -OnSuccess {
        param($data)
        Apply-TaskDetails -Details $data
    } -OnFailure $failureCallback
}

function Initialize-TaskDetailsTimer {
    [CmdletBinding()]
    param()

    if ($null -ne $script:State.TaskDetailsTimer) { try { $script:State.TaskDetailsTimer.Stop() } catch { } }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(30)
    $timer.Add_Tick({
        try {
            $seconds = ConvertTo-UiInt -Text (Get-ComboText (Get-UiControl 'TaskDetailsRefreshSecondsCombo')) -Default 30 -Minimum 15
            $script:State.TaskDetailsTimer.Interval = [TimeSpan]::FromSeconds($seconds)
            if ([bool](Get-UiControl 'TaskDetailsAutoRefreshCheckBox').IsChecked -and -not $script:State.Busy -and $script:State.WorkloadSelected) {
                Refresh-SelectedTaskDetails -Automatic $true
            }
        }
        catch { Write-UiLog -Message "Task detail auto-refresh warning: $($_.Exception.Message)" -Level WARN }
    })
    $timer.Start()
    $script:State.TaskDetailsTimer = $timer
}

function Apply-ReadinessResult {
    [CmdletBinding()]
    param([AllowNull()][object]$Result)

    if ($null -eq $Result) { return }
    $script:State.LastReadiness=$Result
    $script:State.ReadinessHtmlPath=[string](Get-ObjectPropertyValue -InputObject $Result -Names @('HtmlPath'))
    $script:State.ReadinessJsonPath=[string](Get-ObjectPropertyValue -InputObject $Result -Names @('JsonPath'))
    $summary=Get-ObjectPropertyValue -InputObject $Result -Names @('Summary')
    $overall=[string](Get-ObjectPropertyValue -InputObject $summary -Names @('OverallStatus') -Default 'UNKNOWN')
    $text="Overall: $overall | PASS: $([string](Get-ObjectPropertyValue -InputObject $summary -Names @('Pass') -Default 0)) | WARNING: $([string](Get-ObjectPropertyValue -InputObject $summary -Names @('Warning') -Default 0)) | FAIL: $([string](Get-ObjectPropertyValue -InputObject $summary -Names @('Fail') -Default 0)) | N/A: $([string](Get-ObjectPropertyValue -InputObject $summary -Names @('NotApplicable') -Default 0))"
    $blocked=ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $summary -Names @('BlockedFeatures') -Default @())
    $script:State.BlockedFeatures = $blocked
    if ($blocked.Count -gt 0) { $text += "`r`nBlocked write features: $($blocked -join ', ')" }
    (Get-UiControl 'ReadinessSummaryText').Text=$text
    Set-GridItems -Grid (Get-UiControl 'ReadinessGrid') -Items (Get-ObjectPropertyValue -InputObject $Result -Names @('Checks') -Default @())
    (Get-UiControl 'OpenReadinessReportButton').IsEnabled = -not [string]::IsNullOrWhiteSpace($script:State.ReadinessHtmlPath)
    (Get-UiControl 'CopyReadinessSummaryButton').IsEnabled=$true
    Write-UiLog -Message "Readiness check: $text" -Level $(if ($overall -eq 'FAIL') {'ERROR'} elseif ($overall -eq 'WARNING') {'WARN'} else {'SUCCESS'})
    Update-UiEnablement
}

function Run-ReadinessFromUi {
    [CmdletBinding()]
    param()

    Invoke-EngineAsync -Operation 'RunReadinessCheck' -Parameters @{CheckOnlineModuleVersion=[bool](Get-UiControl 'ReadinessOnlineCheckBox').IsChecked;OutputDirectory=[string](Get-UiControl 'FactoryOutputDirectoryBox').Text} -Status 'Running V1 readiness checks…' -OnSuccess { param($data); Apply-ReadinessResult -Result $data }
}

function Refresh-OperationHistory {
    [CmdletBinding()]
    param()

    Invoke-EngineAsync -Operation 'GetOperationHistory' -Parameters @{Last=250} -Status 'Loading operation history…' -OnSuccess {
        param($data)
        Set-GridItems -Grid (Get-UiControl 'OperationHistoryGrid') -Items (ConvertTo-UiObjectArray -InputObject $data | Sort-Object Timestamp -Descending)
        Update-UiEnablement
    }
}

function Create-SupportBundleFromUi {
    [CmdletBinding()]
    param()

    Invoke-EngineAsync -Operation 'CreateSupportBundle' -Parameters @{OutputDirectory=[string](Get-UiControl 'FactoryOutputDirectoryBox').Text} -Status 'Creating sanitized support bundle…' -OnSuccess {
        param($data)
        $path=[string](Get-ObjectPropertyValue -InputObject $data -Names @('BundlePath'))
        if (-not [string]::IsNullOrWhiteSpace($path)) { [Windows.Clipboard]::SetText($path) }
        Show-UiMessage -Text "Support bundle created:`r`n$path`r`n`r`nThe path was copied to the clipboard." -Type Info
    }
}

function Test-MappingCollisionUtilityAvailable {
    [CmdletBinding()]
    param()

    foreach ($path in @(
        $script:MappingCollisionUtilityBootstrapPath,
        (Join-Path $script:MappingCollisionUtilityRoot 'MappingCollisionUtility.UI.ps1'),
        (Join-Path $script:MappingCollisionUtilityRoot 'Start-MappingCollisionUtility.cmd'),
        $script:MappingCollisionUtilityXamlPath,
        $script:MappingCollisionUtilityEnginePath,
        (Join-Path $script:MappingCollisionUtilityRoot 'Collectors\Export-SourceIdentityInventory.ps1'),
        (Join-Path $script:MappingCollisionUtilityRoot 'Collectors\Export-TargetIdentityInventory.ps1'),
        (Join-Path $script:MappingCollisionUtilityRoot 'Samples\SourceInventory.Sample.csv'),
        (Join-Path $script:MappingCollisionUtilityRoot 'Samples\TargetInventory.Sample.csv')
    )) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    }
    return $true
}

function Update-MappingCollisionUtilityStatus {
    [CmdletBinding()]
    param()

    $status = Get-UiControl 'MappingCollisionUtilityStatusText'
    if (Test-MappingCollisionUtilityAvailable) {
        $status.Text = 'Packaged utility ready. Source and target collectors are included.'
        Set-UiResourceReference -Control $status -Property ([Windows.Controls.TextBlock]::ForegroundProperty) -ResourceKey 'SuccessBrush'
    }
    else {
        $status.Text = 'The Mapping Collision Utility package is incomplete or unavailable.'
        Set-UiResourceReference -Control $status -Property ([Windows.Controls.TextBlock]::ForegroundProperty) -ResourceKey 'DangerBrush'
    }
}

function Start-MappingCollisionUtility {
    [CmdletBinding()]
    param()

    if (-not (Test-MappingCollisionUtilityAvailable)) {
        Update-MappingCollisionUtilityStatus
        Show-UiMessage -Text 'The Mapping Collision Utility package is incomplete. Re-extract the complete console preview package and try again.' -Title 'Mapping Collision Utility unavailable' -Type Error
        return
    }

    try {
        $windowsDirectory = [string]$env:SystemRoot
        if ([string]::IsNullOrWhiteSpace($windowsDirectory)) { throw 'The Windows directory could not be resolved.' }
        $systemFolder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
        $hostPath = Join-Path $windowsDirectory "$systemFolder\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) { throw "Windows PowerShell was not found: $hostPath" }

        $utilityDataRoot = Join-Path $script:DataRoot 'MappingCollisionUtility'
        if (-not (Test-UiDirectoryWritable -Path $utilityDataRoot -Create $true)) { throw "The utility data directory is unavailable or not writable: $utilityDataRoot" }
        $arguments = @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy','Bypass',
            '-STA',
            '-File',('"{0}"' -f $script:MappingCollisionUtilityBootstrapPath.Replace('"','')),
            '-DataRoot',('"{0}"' -f $utilityDataRoot.Replace('"',''))
        )
        $process = Start-Process -FilePath $hostPath -ArgumentList $arguments -WorkingDirectory $script:MappingCollisionUtilityRoot -PassThru -ErrorAction Stop
        (Get-UiControl 'MappingCollisionUtilityStatusText').Text = "Utility launched in process $($process.Id)."
        Set-UiResourceReference -Control (Get-UiControl 'MappingCollisionUtilityStatusText') -Property ([Windows.Controls.TextBlock]::ForegroundProperty) -ResourceKey 'SuccessBrush'
        Write-UiLog -Message "Mapping Collision Utility launched in process $($process.Id). Data root: $utilityDataRoot" -Level SUCCESS
    }
    catch {
        Update-MappingCollisionUtilityStatus
        Write-UiLog -Message "Mapping Collision Utility launch failed: $($_.Exception.Message)" -Level ERROR
        Show-UiMessage -Text ("The Mapping Collision Utility could not be launched: {0}" -f $_.Exception.Message) -Title 'Mapping Collision Utility launch failed' -Type Error
    }
}

function Open-MappingCollisionUtilityFolder {
    [CmdletBinding()]
    param()

    try {
        if (-not (Test-Path -LiteralPath $script:MappingCollisionUtilityRoot -PathType Container)) { throw "Utility folder was not found: $script:MappingCollisionUtilityRoot" }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:MappingCollisionUtilityRoot.Replace('"','')) -ErrorAction Stop | Out-Null
    }
    catch { Show-UiMessage -Text $_.Exception.Message -Title 'Mapping Collision Utility folder' -Type Error }
}

function Format-AboutInfo {
    [CmdletBinding()]
    param([AllowNull()][object]$BuildInfo,[AllowNull()][object]$ModuleStatus)

    return @(
        "$([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('ProductName') -Default 'Quest ODM Operations Console'))",
        "Version:             $([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('Version') -Default '1.1.0-preview.6'))",
        "Build:               $([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('BuildId'))) / $([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('BuildDateUtc')))",
        "Channel:             $([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('ReleaseChannel')))",
        "Supported host:      $([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('SupportedHost')))",
        "Validated OdmApi:    $([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('ValidatedOdmApiVersion')))",
        "Installed OdmApi:    $([string](Get-ObjectPropertyValue -InputObject $ModuleStatus -Names @('InstalledVersionText')))",
        "Compatibility:       $([string](Get-ObjectPropertyValue -InputObject $ModuleStatus -Names @('CompatibilityStatus')))",
        "Support owner:       $([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('SupportOwner')))",
        "Support contact:     $([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('SupportEmail')))",
        "Notice:              $([string](Get-ObjectPropertyValue -InputObject $BuildInfo -Names @('Notice')))"
    ) -join "`r`n"
}

function Show-AboutDialog {
    [CmdletBinding()]
    param()

    $text=Format-AboutInfo -BuildInfo $script:State.BuildInfo -ModuleStatus $script:State.ModuleStatus
    Show-UiMessage -Text $text -Title 'About Quest ODM Operations Console' -Type Info
}

function Get-BulkTemplateDefinition {
    [CmdletBinding()]
    param([AllowNull()][object]$Operation)

    if ($null -eq $Operation) { return $null }
    $key = [string](Get-ObjectPropertyValue -InputObject $Operation -Names @('TemplateKey'))
    $samples = Join-Path $script:AppRoot 'Samples'
    switch ($key) {
        'AccountDiscoveryByUPN' {
            return [pscustomobject]@{ Path=(Join-Path $samples 'AccountDiscoveryByUPNTemplate.csv'); Hint='Quest discovery templates included: AccountDiscoveryByUPNTemplate.csv and AccountDiscoveryByObjectIdTemplate.csv.' }
        }
        'AccountMappingByUPN' {
            return [pscustomobject]@{ Path=(Join-Path $samples 'AccountMappingByUPNTemplate.csv'); Hint='Quest mapping templates included: AccountMappingByUPNTemplate.csv and AccountMappingByObjectIdTemplate.csv.' }
        }
        'TaskReferences' {
            return [pscustomobject]@{ Path=(Join-Path $samples 'TaskReferences.csv'); Hint='Template columns: TaskId,TaskName. Provide either an ID or an exact unique name per row.' }
        }
        default { return $null }
    }
}

function Update-BulkOperationUi {
    [CmdletBinding()]
    param([AllowNull()][object]$Selected)

    if ($null -eq $Selected) {
        (Get-UiControl 'BulkDescriptionText').Text = 'Select an operation.'
        foreach ($name in @('BulkCsvPathBox','BrowseBulkCsvButton','BulkTaskNameBox','BulkStartCreatedTaskCheckBox','OpenBulkTemplateButton')) { (Get-UiControl $name).IsEnabled = $false }
        (Get-UiControl 'BulkTemplateHintText').Text = ''
        return
    }

    $key = [string](Get-ObjectPropertyValue -InputObject $Selected -Names @('Key'))
    $needsCsv = Test-ObjectPropertyTrue -InputObject $Selected -Names @('NeedsCsv')
    $supportsExecute = Test-ObjectPropertyTrue -InputObject $Selected -Names @('SupportsExecute')
    $needsTaskName = Test-ObjectPropertyTrue -InputObject $Selected -Names @('NeedsTaskName')
    $supportsStart = Test-ObjectPropertyTrue -InputObject $Selected -Names @('SupportsStart')
    $definition = Get-BulkTemplateDefinition -Operation $Selected

    (Get-UiControl 'BulkDescriptionText').Text = [string](Get-ObjectPropertyValue -InputObject $Selected -Names @('Description'))
    (Get-UiControl 'BulkCsvPathBox').IsEnabled = $needsCsv
    (Get-UiControl 'BrowseBulkCsvButton').IsEnabled = $needsCsv
    (Get-UiControl 'BulkTaskNameBox').IsEnabled = $needsTaskName
    (Get-UiControl 'BulkTaskNameBox').ToolTip = if ($needsTaskName) { 'Optional. Leave blank to generate a timestamped Quest task name.' } else { $null }
    (Get-UiControl 'BulkStartCreatedTaskCheckBox').IsEnabled = $supportsStart
    if (-not $supportsStart) { (Get-UiControl 'BulkStartCreatedTaskCheckBox').IsChecked = $false }
    (Get-UiControl 'BulkExecuteCheckBox').IsEnabled = $supportsExecute
    if (-not $supportsExecute) { (Get-UiControl 'BulkExecuteCheckBox').IsChecked = $false }
    (Get-UiControl 'BulkStopRunningCheckBox').IsEnabled = ($key -in @('DeleteTasksFromCsv','DeleteTasksAcrossProjects','DeleteAllTasks'))
    (Get-UiControl 'BulkIncludeAllProjectsCheckBox').IsEnabled = ($key -eq 'ExportTasks')
    (Get-UiControl 'BulkConfirmationBox').IsEnabled = ($key -eq 'DeleteAllTasks')
    (Get-UiControl 'OpenBulkTemplateButton').IsEnabled = ($null -ne $definition -and (Test-Path -LiteralPath $definition.Path -PathType Leaf))
    (Get-UiControl 'BulkTemplateHintText').Text = if ($null -ne $definition) { [string]$definition.Hint } else { '' }
}

function Open-BulkTemplate {
    [CmdletBinding()]
    param()

    $selected = (Get-UiControl 'BulkOperationCombo').SelectedItem
    $definition = Get-BulkTemplateDefinition -Operation $selected
    if ($null -eq $definition -or -not (Test-Path -LiteralPath $definition.Path -PathType Leaf)) {
        Show-UiMessage -Text 'No bundled template is available for the selected operation.' -Type Warning
        return
    }
    try { Start-Process -FilePath $definition.Path -ErrorAction Stop }
    catch { Show-UiMessage -Text ("The template could not be opened: {0}" -f $_.Exception.Message) -Type Error }
}

function Update-EnvironmentInfo {
    Invoke-EngineAsync -Operation 'GetEnvironment' -Status 'Checking PowerShell and OdmApi…' -OnSuccess {
        param($data)
        (Get-UiControl 'EnvironmentTextBox').Text = Format-EnvironmentInfo -Data $data
        Apply-OdmApiModuleStatus -Status (Get-ObjectPropertyValue -InputObject $data -Names @('OdmApiModuleStatus')) -NavigateWhenMissing $true
        Apply-ContextState -Context (Get-ObjectPropertyValue -InputObject $data -Names @('EngineState'))
    }
}

function Get-FactoryParameters {
    param([bool]$Execute)
    $csvPath = [string](Get-UiControl 'FactoryCsvPathBox').Text
    if ([string]::IsNullOrWhiteSpace($csvPath)) { throw 'Select a task factory CSV.' }
    $mode = Get-ComboText (Get-UiControl 'FactoryModeCombo')
    $taskKinds = [System.Collections.Generic.List[string]]::new()
    if ((Get-UiControl 'FactoryMailCheckBox').IsChecked) { $taskKinds.Add('Mail') | Out-Null }
    if ((Get-UiControl 'FactoryOneDriveCheckBox').IsChecked) { $taskKinds.Add('OneDrive') | Out-Null }
    if ((Get-UiControl 'FactoryMeetingLinkCheckBox').IsChecked) { $taskKinds.Add('MeetingLink') | Out-Null }
    if ((Get-UiControl 'FactoryMailboxSwitchCheckBox').IsChecked) { $taskKinds.Add('MailboxSwitch') | Out-Null }
    if ($taskKinds.Count -eq 0) { throw 'Select at least one task type.' }

    $mailDate = (Get-UiControl 'FactoryMailFromPicker').SelectedDate
    if ($null -eq $mailDate) { $mailDate = [DateTime]'2025-11-01' }

    return @{
        CsvPath                       = $csvPath
        Mode                          = $mode
        Execute                       = $Execute
        OutputDirectory               = [string](Get-UiControl 'FactoryOutputDirectoryBox').Text
        NotifyRecipients              = [string](Get-UiControl 'FactoryNotifyRecipientsBox').Text
        LinkTasksToCollections        = [bool](Get-UiControl 'FactoryLinkTasksCheckBox').IsChecked
        MailFrom                      = [DateTime]$mailDate
        OneDriveFilterItems           = Get-ComboText (Get-UiControl 'FactoryOneDriveFilterCombo')
        MaxUsersPerTask               = ConvertTo-UiInt -Text (Get-UiControl 'FactoryMaxUsersBox').Text -Default 1000 -Minimum 1
        VerificationRetries           = ConvertTo-UiInt -Text (Get-UiControl 'FactoryVerificationRetriesBox').Text -Default 6 -Minimum 1
        VerificationDelaySeconds      = ConvertTo-UiInt -Text (Get-UiControl 'FactoryVerificationDelayBox').Text -Default 5 -Minimum 0
        ExistingTaskBehavior          = Get-ComboText (Get-UiControl 'ExistingTaskBehaviorCombo')
        TaskKinds                     = $taskKinds.ToArray()
        MailTemplateId                = Get-ComboIdOrText (Get-UiControl 'FactoryMailTemplateCombo')
        OneDriveTemplateId            = Get-ComboIdOrText (Get-UiControl 'FactoryOneDriveTemplateCombo')
        MeetingLinkTemplateId         = Get-ComboIdOrText (Get-UiControl 'FactoryMeetingLinkTemplateCombo')
        MailboxSwitchTemplateId       = Get-ComboIdOrText (Get-UiControl 'FactoryMailboxSwitchTemplateCombo')
        MailSuffix                    = [string](Get-UiControl 'FactoryMailSuffixBox').Text
        OneDriveSuffix                = [string](Get-UiControl 'FactoryOneDriveSuffixBox').Text
        MeetingLinkSuffix             = [string](Get-UiControl 'FactoryMeetingLinkSuffixBox').Text
        MailboxSwitchSuffix           = [string](Get-UiControl 'FactoryMailboxSwitchSuffixBox').Text
        MailPlacement                 = Get-ComboText (Get-UiControl 'FactoryMailPlacementCombo')
        OneDrivePlacement             = Get-ComboText (Get-UiControl 'FactoryOneDrivePlacementCombo')
        MeetingLinkPlacement          = Get-ComboText (Get-UiControl 'FactoryMeetingLinkPlacementCombo')
        MailboxSwitchPlacement        = Get-ComboText (Get-UiControl 'FactoryMailboxSwitchPlacementCombo')
    }
}

function Invoke-TaskFactoryFromUi {
    param([bool]$Execute)
    try { $parameters = Get-FactoryParameters -Execute $Execute }
    catch { Show-UiMessage -Text $_.Exception.Message -Type Warning; return }

    if ($Execute) {
        $text = "Create the selected task types for every valid CollectionName group in the CSV?`r`n`r`nTasks will be created and populated, but they will not be started."
        if (-not (Confirm-UiAction -Text $text -Title 'Create Quest ODM tasks')) { return }
    }

    Invoke-EngineAsync -Operation 'TaskFactory' -Parameters $parameters -Status $(if ($Execute) { 'Creating and verifying ODM tasks…' } else { 'Building task factory preview…' }) -OnSuccess {
        param($data)
        Set-GridItems -Grid (Get-UiControl 'FactorySummaryGrid') -Items (Get-ObjectPropertyValue -InputObject $data -Names @('SummaryRows') -Default @())
        $modeText = [string](Get-ObjectPropertyValue -InputObject $data -Names @('Mode'))
        $executeValue = [bool](Get-ObjectPropertyValue -InputObject $data -Names @('Execute') -Default $false)
        $resolvedCount = [int](Get-ObjectPropertyValue -InputObject $data -Names @('ResolvedRows') -Default 0)
        $unresolvedCount = [int](Get-ObjectPropertyValue -InputObject $data -Names @('UnresolvedRows') -Default 0)
        $groupCount = [int](Get-ObjectPropertyValue -InputObject $data -Names @('CollectionGroups') -Default 0)
        (Get-UiControl 'FactoryStatusText').Text = "Mode: $modeText | Execute: $executeValue | Resolved rows: $resolvedCount | Unresolved rows: $unresolvedCount | Collection groups: $groupCount"
        if ($executeValue) { Refresh-Workspace }
    }
}

function Get-BulkResultRows {
    param([AllowNull()][object]$Data)
    foreach ($name in @('Rows','SummaryRows','MembershipRows','RemovalPlanRows','Matched','NotFound','AssignmentRows','SkippedRows','CreatedTasks')) {
        $value = Get-ObjectPropertyValue -InputObject $Data -Names @($name)
        $items = ConvertTo-UiObjectArray -InputObject $value
        if ($items.Count -gt 0) { return $items }
    }
    return (ConvertTo-UiObjectArray -InputObject $Data)
}

function Invoke-BulkFromUi {
    $selected = (Get-UiControl 'BulkOperationCombo').SelectedItem
    if ($null -eq $selected) { Show-UiMessage -Text 'Select a bulk operation.' -Type Warning; return }
    $key = [string](Get-ObjectPropertyValue -InputObject $selected -Names @('Key'))
    $csvPath = [string](Get-UiControl 'BulkCsvPathBox').Text
    $needsCsv = Test-ObjectPropertyTrue -InputObject $selected -Names @('NeedsCsv')
    if ($needsCsv -and [string]::IsNullOrWhiteSpace($csvPath)) { Show-UiMessage -Text 'This operation requires a CSV file.' -Type Warning; return }

    $execute = [bool](Get-UiControl 'BulkExecuteCheckBox').IsChecked
    $output = [string](Get-UiControl 'BulkOutputDirectoryBox').Text
    $parameters = @{ OutputDirectory = $output }
    switch ($key) {
        'DiscoverAllAccounts'          { $parameters.TaskName=[string](Get-UiControl 'BulkTaskNameBox').Text; $parameters.Execute=$execute; $parameters.StartAfterCreate=[bool](Get-UiControl 'BulkStartCreatedTaskCheckBox').IsChecked }
        'DiscoverAccountsFromCsv'      { $parameters.CsvPath=$csvPath; $parameters.TaskName=[string](Get-UiControl 'BulkTaskNameBox').Text; $parameters.Execute=$execute; $parameters.StartAfterCreate=[bool](Get-UiControl 'BulkStartCreatedTaskCheckBox').IsChecked }
        'MapAccountsFromCsv'           { $parameters.CsvPath=$csvPath; $parameters.TaskName=[string](Get-UiControl 'BulkTaskNameBox').Text; $parameters.Execute=$execute; $parameters.StartAfterCreate=[bool](Get-UiControl 'BulkStartCreatedTaskCheckBox').IsChecked }
        'CreateCollectionsAndAddUsers' { $parameters.CsvPath = $csvPath; $parameters.Execute = $execute }
        'RemoveUsersFromCollections'   { $parameters.CsvPath = $csvPath; $parameters.Execute = $execute }
        'RemoveCollections'            { $parameters.CsvPath = $csvPath; $parameters.Execute = $execute }
        'FindUserCollections'          { $parameters.CsvPath = $csvPath; $parameters.NamePatterns = @(((Get-UiControl 'BulkNamePatternsBox').Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        'FindUserTasks'                { $parameters.CsvPath = $csvPath; $parameters.NamePatterns = @(((Get-UiControl 'BulkNamePatternsBox').Text -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        'MatchObjectInfo'              { $parameters.CsvPath = $csvPath; $parameters.EmailColumn = [string](Get-UiControl 'BulkEmailColumnBox').Text }
        'RemoveUsersFromTasksPlan'     { $parameters.CsvPath = $csvPath; $parameters.Execute = $execute }
        'StartTasksFromCsv'            { $parameters.CsvPath = $csvPath; $parameters.Execute = $execute }
        'StopTasksFromCsv'             { $parameters.CsvPath = $csvPath; $parameters.Execute = $execute }
        'DeleteTasksFromCsv'           { $parameters.CsvPath = $csvPath; $parameters.Execute = $execute; $parameters.StopRunning = [bool](Get-UiControl 'BulkStopRunningCheckBox').IsChecked }
        'DeleteTasksAcrossProjects'    { $parameters.CsvPath = $csvPath; $parameters.Execute = $execute; $parameters.StopRunning = [bool](Get-UiControl 'BulkStopRunningCheckBox').IsChecked }
        'DeleteAllTasks'               { $parameters.Execute = $execute; $parameters.ConfirmationText = [string](Get-UiControl 'BulkConfirmationBox').Text; $parameters.StopRunning = [bool](Get-UiControl 'BulkStopRunningCheckBox').IsChecked }
        'ExportTasks'                  { $parameters.IncludeAllProjects = [bool](Get-UiControl 'BulkIncludeAllProjectsCheckBox').IsChecked }
        'ExportCollections'            { $parameters.IncludeCounts = $true }
        default                        { Show-UiMessage -Text "Unsupported bulk operation: $key" -Type Error; return }
    }

    if ($execute -and (Test-ObjectPropertyTrue -InputObject $selected -Names @('SupportsExecute'))) {
        $confirmation = "Execute '$([string](Get-ObjectPropertyValue -InputObject $selected -Names @('Name')))' against the currently selected workload?"
        if ($key -in @('DiscoverAllAccounts','DiscoverAccountsFromCsv','MapAccountsFromCsv') -and [bool](Get-UiControl 'BulkStartCreatedTaskCheckBox').IsChecked) {
            $confirmation += "`r`n`r`nThe newly created Quest task will also be started."
        }
        if (-not (Confirm-UiAction -Text $confirmation -Title 'Confirm bulk API change')) { return }
    }

    $operationDisplayName = [string](Get-ObjectPropertyValue -InputObject $selected -Names @('Name'))
    $script:State.BulkUiContext = [pscustomobject]@{
        OperationKey = $key
        DisplayName = $operationDisplayName
        ExecuteRequested = $execute
    }
    $successCallback = {
        param($data)
        $bulkContext = Get-ObjectPropertyValue -InputObject $script:State -Names @('BulkUiContext')
        $displayName = [string](Get-ObjectPropertyValue -InputObject $bulkContext -Names @('DisplayName') -Default 'Bulk operation')
        $executeRequested = [bool](Get-ObjectPropertyValue -InputObject $bulkContext -Names @('ExecuteRequested') -Default (Get-ObjectPropertyValue -InputObject $data -Names @('Execute') -Default $false))
        try {
            $displayRows = ConvertTo-UiObjectArray -InputObject (Get-BulkResultRows -Data $data)
            Set-GridItems -Grid (Get-UiControl 'BulkResultsGrid') -Items $displayRows
            $count = $displayRows.Count
            $operationStatus = [string](Get-ObjectPropertyValue -InputObject $data -Names @('Status'))
            (Get-UiControl 'BulkStatusText').Text = if ([string]::IsNullOrWhiteSpace($operationStatus)) { "Completed: $displayName | Displayed rows: $count" } else { "Completed: $displayName | Status: $operationStatus | Displayed rows: $count" }
            if ($executeRequested) { Refresh-Workspace }
        }
        finally { $script:State.BulkUiContext = $null }
    }
    $failureCallback = {
        param($message,$result)
        $script:State.BulkUiContext = $null
        Show-UiMessage -Text $message -Type Error
    }
    Invoke-EngineAsync -Operation 'Bulk' -Parameters @{ Operation = $key; Parameters = $parameters } -Status "Running $operationDisplayName…" -OnSuccess $successCallback -OnFailure $failureCallback
}

# Load settings before event registration.
$env:QUESTODMCONSOLE_UI_PHASE = 'Loading and applying user settings'
Load-UiSettings
Set-UiTheme -Theme ([string](Get-SettingValue -Name 'Theme' -Default 'Light'))
$reportDirectorySetting = [string](Get-SettingValue -Name 'ReportDirectory' -Default '')
try { $reportDirectory = Get-UiReportDirectory -Candidate $reportDirectorySetting }
catch {
    Write-UiLog -Message "$($_.Exception.Message) The per-user default report directory will be used." -Level WARN
    $reportDirectory = $script:ReportsPath
}
foreach ($name in @('TaskOutputDirectoryBox','CollectionOutputDirectoryBox','FactoryOutputDirectoryBox','BulkOutputDirectoryBox')) { (Get-UiControl $name).Text = $reportDirectory }
(Get-UiControl 'FactoryNotifyRecipientsBox').Text = [string](Get-SettingValue -Name 'NotifyRecipients' -Default '')
(Get-UiControl 'OrganizationIdBox').Text = [string](Get-SettingValue -Name 'LastOrganizationId' -Default '')
Select-ComboContent -Combo (Get-UiControl 'RegionCombo') -Content ([string](Get-SettingValue -Name 'Region' -Default 'US'))
Select-ComboContent -Combo (Get-UiControl 'FactoryOneDriveFilterCombo') -Content ([string](Get-SettingValue -Name 'OneDriveFilterItems' -Default 'AfterLastSuccessfulRun'))
Select-ComboContent -Combo (Get-UiControl 'ExistingTaskBehaviorCombo') -Content ([string](Get-SettingValue -Name 'ExistingTaskBehavior' -Default 'Skip'))
(Get-UiControl 'FactoryMailSuffixBox').Text = [string](Get-SettingValue -Name 'MailSuffix' -Default 'Email Sync')
(Get-UiControl 'FactoryOneDriveSuffixBox').Text = [string](Get-SettingValue -Name 'OneDriveSuffix' -Default 'OneDrive Sync')
(Get-UiControl 'FactoryMeetingLinkSuffixBox').Text = [string](Get-SettingValue -Name 'MeetingLinkSuffix' -Default 'Meeting Link Migration')
(Get-UiControl 'FactoryMailboxSwitchSuffixBox').Text = [string](Get-SettingValue -Name 'MailboxSwitchSuffix' -Default 'Mailbox Switch')
Select-ComboContent -Combo (Get-UiControl 'FactoryMailPlacementCombo') -Content ([string](Get-SettingValue -Name 'MailPlacement' -Default 'Suffix'))
Select-ComboContent -Combo (Get-UiControl 'FactoryOneDrivePlacementCombo') -Content ([string](Get-SettingValue -Name 'OneDrivePlacement' -Default 'Suffix'))
Select-ComboContent -Combo (Get-UiControl 'FactoryMeetingLinkPlacementCombo') -Content ([string](Get-SettingValue -Name 'MeetingLinkPlacement' -Default 'Suffix'))
Select-ComboContent -Combo (Get-UiControl 'FactoryMailboxSwitchPlacementCombo') -Content ([string](Get-SettingValue -Name 'MailboxSwitchPlacement' -Default 'Suffix'))
(Get-UiControl 'TaskDetailsAutoRefreshCheckBox').IsChecked = [bool](Get-SettingValue -Name 'TaskDetailsAutoRefresh' -Default $false)
Select-ComboContent -Combo (Get-UiControl 'TaskDetailsRefreshSecondsCombo') -Content ([string](Get-SettingValue -Name 'TaskDetailsRefreshSeconds' -Default 30))
(Get-UiControl 'ReadinessOnlineCheckBox').IsChecked = [bool](Get-SettingValue -Name 'ReadinessCheckOnlineModuleVersion' -Default $false)
$script:State.LogRetentionDays = Get-UiLogRetentionDays -Value (Get-SettingValue -Name 'LogRetentionDays' -Default 30)
Select-ComboContent -Combo (Get-UiControl 'LogRetentionDaysCombo') -Content ([string]$script:State.LogRetentionDays)
try {
    $startupLogMaintenance = Invoke-QOdmLogMaintenance -Application MainConsole -DataRoot $script:DataRoot -CurrentSessionLogPath $script:SessionLogPath -RetentionDays $script:State.LogRetentionDays -Mode Retention
    Set-UiLogMaintenanceStatus -Result $startupLogMaintenance
    if ([int]$startupLogMaintenance.DeletedFileCount -gt 0 -or [int]$startupLogMaintenance.PrunedHistoryRecords -gt 0 -or [int]$startupLogMaintenance.ResetFileCount -gt 0 -or [int]$startupLogMaintenance.FailureCount -gt 0) {
        Write-UiLog -Message ("Startup log retention completed. {0}" -f $startupLogMaintenance.Summary) -Level $(if ([int]$startupLogMaintenance.FailureCount -gt 0) { 'WARN' } else { 'SUCCESS' })
    }
}
catch {
    Set-UiLogMaintenanceStatus -Result $null -Fallback ("Startup log retention failed: {0}" -f $_.Exception.Message)
    Write-UiLog -Message ("Startup log retention failed: {0}" -f $_.Exception.Message) -Level WARN
}
Load-UiProfiles
$mailDateSetting = [string](Get-SettingValue -Name 'MailFrom' -Default '2025-11-01')
$mailDate = [DateTime]::MinValue
if ([DateTime]::TryParse($mailDateSetting, [ref]$mailDate)) { (Get-UiControl 'FactoryMailFromPicker').SelectedDate = $mailDate }

$env:QUESTODMCONSOLE_UI_PHASE = 'Validating UI selection cardinality'
try {
    Assert-UiSelectionCardinalityContract
}
catch {
    # This diagnostic must never block the application from opening. Production
    # selection paths normalize the WPF SelectedItems collection independently.
    Write-UiLog -Message ("UI selection-cardinality diagnostic warning: {0}" -f $_.Exception.Message) -Level WARN
}

$env:QUESTODMCONSOLE_UI_PHASE = 'Starting the Quest ODM engine worker'
Start-WorkerRunspace
try {
    $catalogResult = Invoke-EngineSync -Operation 'GetOperationCatalog'
    if (Test-ObjectPropertyTrue -InputObject $catalogResult -Names @('Success')) {
        $script:State.OperationCatalog = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $catalogResult -Names @('Data') -Default @())
        Set-ComboItems -Combo (Get-UiControl 'BulkOperationCombo') -Items $script:State.OperationCatalog -SelectIndex 0
    }
    $buildResult = Invoke-EngineSync -Operation 'GetBuildInfo'
    if (Test-ObjectPropertyTrue -InputObject $buildResult -Names @('Success')) {
        $script:State.BuildInfo = Get-ObjectPropertyValue -InputObject $buildResult -Names @('Data')
    }
    $environmentResult = Invoke-EngineSync -Operation 'GetEnvironment'
    if (Test-ObjectPropertyTrue -InputObject $environmentResult -Names @('Success')) {
        $environmentData = Get-ObjectPropertyValue -InputObject $environmentResult -Names @('Data')
        (Get-UiControl 'EnvironmentTextBox').Text = Format-EnvironmentInfo -Data $environmentData
        Apply-OdmApiModuleStatus -Status (Get-ObjectPropertyValue -InputObject $environmentData -Names @('OdmApiModuleStatus')) -NavigateWhenMissing $true
        Apply-ContextState -Context (Get-ObjectPropertyValue -InputObject $environmentData -Names @('EngineState'))
        if ($null -eq $script:State.BuildInfo) { $script:State.BuildInfo = Get-ObjectPropertyValue -InputObject $environmentData -Names @('BuildInfo') }
    }
    (Get-UiControl 'AboutTextBox').Text = Format-AboutInfo -BuildInfo $script:State.BuildInfo -ModuleStatus $script:State.ModuleStatus
}
catch { Write-UiLog -Message $_.Exception.Message -Level ERROR }

$env:QUESTODMCONSOLE_UI_PHASE = 'Registering UI event handlers'
# Header and context events.
(Get-UiControl 'ToggleSafeModeButton').Add_Click({ Invoke-UiSafeModeToggle })
(Get-UiControl 'AboutButton').Add_Click({ Show-AboutDialog })
(Get-UiControl 'ConnectButton').Add_Click({
    $region = Get-ComboText (Get-UiControl 'RegionCombo')
    [void](Set-ContextComboItems -Combo (Get-UiControl 'OrganizationCombo') -Items @())
    [void](Set-ContextComboItems -Combo (Get-UiControl 'ProjectCombo') -Items @())
    [void](Set-ContextComboItems -Combo (Get-UiControl 'WorkloadCombo') -Items @())
    Invoke-EngineAsync -Operation 'Connect' -Parameters @{ Region = $region } -Status 'Connecting to Quest On Demand…' -OnSuccess {
        param($data)
        Apply-ContextState -Context (Get-ObjectPropertyValue -InputObject $data -Names @('State'))
        $organizations = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $data -Names @('Organizations') -Default @())
        $savedOrganizationId = [string](Get-UiControl 'OrganizationIdBox').Text
        $organizationCount = Set-ContextComboItems -Combo (Get-UiControl 'OrganizationCombo') -Items $organizations
        $selectedSavedOrganization = Select-ContextComboById -Combo (Get-UiControl 'OrganizationCombo') -Id $savedOrganizationId
        if (-not $selectedSavedOrganization -and $organizationCount -eq 1) { (Get-UiControl 'OrganizationCombo').SelectedIndex = 0 }
        if ((Get-UiControl 'OrganizationCombo').SelectedValue) {
            (Get-UiControl 'OrganizationIdBox').Text = [string](Get-UiControl 'OrganizationCombo').SelectedValue
        }

        $discovery = Get-ObjectPropertyValue -InputObject $data -Names @('OrganizationDiscovery')
        Write-UiDiscoveryDiagnostics -Label 'Organization' -Discovery $discovery
        Write-UiLog -Message "Organizations available in the console: $organizationCount"

        $browserWarning = [string](Get-ObjectPropertyValue -InputObject $data -Names @('OrganizationBrowserWarning'))
        if (-not [string]::IsNullOrWhiteSpace($browserWarning)) {
            Write-UiLog -Message $browserWarning -Level WARN
            (Get-UiControl 'FooterStatusText').Text = 'No organizations were enumerated. Enter the organization GUID manually or review the log.'
            if ($organizationCount -eq 0) { Show-UiMessage -Text $browserWarning -Type Warning }
        }
        else {
            (Get-UiControl 'FooterStatusText').Text = "Connected. $organizationCount organization(s) available."
        }
        Update-UiEnablement
    }
})

(Get-UiControl 'DisconnectButton').Add_Click({
    Invoke-EngineAsync -Operation 'Disconnect' -Status 'Disconnecting…' -OnSuccess {
        param($data)
        $script:State.Connected = $false
        Reset-WorkspaceUi
        [void](Set-ContextComboItems -Combo (Get-UiControl 'OrganizationCombo') -Items @())
        Apply-ContextState -Context $data
    }
})
(Get-UiControl 'RefreshWorkspaceButton').Add_Click({ Refresh-Workspace })
(Get-UiControl 'OverviewRefreshButton').Add_Click({ Refresh-Workspace })

(Get-UiControl 'OrganizationCombo').Add_SelectionChanged({
    if ((Get-UiControl 'OrganizationCombo').SelectedValue) { (Get-UiControl 'OrganizationIdBox').Text = [string](Get-UiControl 'OrganizationCombo').SelectedValue }
})
(Get-UiControl 'SelectOrganizationButton').Add_Click({
    $id = [string](Get-UiControl 'OrganizationIdBox').Text
    if ([string]::IsNullOrWhiteSpace($id)) { Show-UiMessage -Text 'Select an organization or enter its organization GUID.' -Type Warning; return }
    $parsedOrganizationId = [Guid]::Empty
    if (-not [Guid]::TryParse($id.Trim(), [ref]$parsedOrganizationId)) { Show-UiMessage -Text 'The organization ID must be a valid GUID.' -Type Warning; return }
    $name = $null
    $selectedOrganization = (Get-UiControl 'OrganizationCombo').SelectedItem
    if ($null -ne $selectedOrganization) {
        $selectedOrganizationId = [string](Get-ObjectPropertyValue -InputObject $selectedOrganization -Names @('Id'))
        if ([string]::Equals($selectedOrganizationId, $parsedOrganizationId.ToString(), [StringComparison]::OrdinalIgnoreCase)) {
            $name = [string](Get-ObjectPropertyValue -InputObject $selectedOrganization -Names @('Name'))
        }
    }
    Invoke-EngineAsync -Operation 'SelectOrganization' -Parameters @{ OrganizationId = $parsedOrganizationId.ToString(); OrganizationName = $name } -Status 'Loading ODM projects…' -OnSuccess {
        param($data)
        Reset-WorkspaceUi
        Apply-ContextState -Context (Get-ObjectPropertyValue -InputObject $data -Names @('State'))
        $projects = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $data -Names @('Projects') -Default @())
        $projectCount = Set-ContextComboItems -Combo (Get-UiControl 'ProjectCombo') -Items $projects
        $profileProjectSelected = Select-ContextComboById -Combo (Get-UiControl 'ProjectCombo') -Id ([string]$script:State.PreferredProjectId)
        if (-not $profileProjectSelected -and $projectCount -eq 1) { (Get-UiControl 'ProjectCombo').SelectedIndex = 0 }
        $discovery = Get-ObjectPropertyValue -InputObject $data -Names @('ProjectDiscovery')
        Write-UiDiscoveryDiagnostics -Label 'Project' -Discovery $discovery
        $projectWarning = [string](Get-ObjectPropertyValue -InputObject $data -Names @('ProjectWarning'))
        if (-not [string]::IsNullOrWhiteSpace($projectWarning)) {
            Write-UiLog -Message $projectWarning -Level WARN
            (Get-UiControl 'FooterStatusText').Text = 'The organization was selected, but project discovery returned a warning.'
            if ($projectCount -eq 0) { Show-UiMessage -Text $projectWarning -Type Warning }
        }
        else {
            (Get-UiControl 'FooterStatusText').Text = "$projectCount project(s) available."
        }
        Update-UiEnablement
    }
})
(Get-UiControl 'SelectProjectButton').Add_Click({
    $id = [string](Get-UiControl 'ProjectCombo').SelectedValue
    if ([string]::IsNullOrWhiteSpace($id)) { Show-UiMessage -Text 'Select a project.' -Type Warning; return }
    Invoke-EngineAsync -Operation 'SelectProject' -Parameters @{ ProjectId = $id } -Status 'Loading project workloads…' -OnSuccess {
        param($data)
        Clear-WorkloadDataUi
        [void](Set-ContextComboItems -Combo (Get-UiControl 'WorkloadCombo') -Items @())
        Apply-ContextState -Context (Get-ObjectPropertyValue -InputObject $data -Names @('State'))
        $workloads = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $data -Names @('Workloads') -Default @())
        $workloadCount = Set-ContextComboItems -Combo (Get-UiControl 'WorkloadCombo') -Items $workloads
        $profileWorkloadSelected = Select-ContextComboById -Combo (Get-UiControl 'WorkloadCombo') -Id ([string]$script:State.PreferredWorkloadId)
        if (-not $profileWorkloadSelected -and $workloadCount -eq 1) { (Get-UiControl 'WorkloadCombo').SelectedIndex = 0 }
        $discovery = Get-ObjectPropertyValue -InputObject $data -Names @('WorkloadDiscovery')
        Write-UiDiscoveryDiagnostics -Label 'Workload' -Discovery $discovery
        $workloadWarning = [string](Get-ObjectPropertyValue -InputObject $data -Names @('WorkloadWarning'))
        if (-not [string]::IsNullOrWhiteSpace($workloadWarning)) {
            Write-UiLog -Message $workloadWarning -Level WARN
            (Get-UiControl 'FooterStatusText').Text = 'Child workload discovery returned a warning; the root project context remains available.'
        }
        else {
            (Get-UiControl 'FooterStatusText').Text = "$workloadCount selectable workload context(s) available."
        }
        Update-UiEnablement
    }
})
(Get-UiControl 'SelectWorkloadButton').Add_Click({
    $id = [string](Get-UiControl 'WorkloadCombo').SelectedValue
    if ([string]::IsNullOrWhiteSpace($id)) { Show-UiMessage -Text 'Select a workload.' -Type Warning; return }
    Invoke-EngineAsync -Operation 'SelectWorkload' -Parameters @{ WorkloadId = $id } -Status 'Opening selected workload…' -OnSuccess {
        param($data)
        Clear-WorkloadDataUi
        Apply-ContextState -Context $data
        Refresh-Workspace
    }
})

# User events.
(Get-UiControl 'UserSearchButton').Add_Click({
    $max = ConvertTo-UiInt -Text (Get-UiControl 'UserMaxResultsBox').Text -Default 1000 -Minimum 1
    Invoke-EngineAsync -Operation 'SearchObjects' -Parameters @{ Search = [string](Get-UiControl 'UserSearchBox').Text; MaxResults = $max; Refresh = $false } -Status 'Searching ODM objects…' -OnSuccess {
        param($data)
        Set-GridItems -Grid (Get-UiControl 'UserGrid') -Items (Get-ObjectPropertyValue -InputObject $data -Names @('Items') -Default @())
        (Get-UiControl 'FooterStatusText').Text = "Object search: matched $([int](Get-ObjectPropertyValue -InputObject $data -Names @('Matched') -Default 0)), returned $([int](Get-ObjectPropertyValue -InputObject $data -Names @('Returned') -Default 0)), loaded $([int](Get-ObjectPropertyValue -InputObject $data -Names @('TotalLoaded') -Default 0))."
    }
})
(Get-UiControl 'UserRefreshButton').Add_Click({
    $max = ConvertTo-UiInt -Text (Get-UiControl 'UserMaxResultsBox').Text -Default 1000 -Minimum 1
    Invoke-EngineAsync -Operation 'SearchObjects' -Parameters @{ Search = [string](Get-UiControl 'UserSearchBox').Text; MaxResults = $max; Refresh = $true } -Status 'Reloading ODM objects…' -OnSuccess {
        param($data)
        Set-GridItems -Grid (Get-UiControl 'UserGrid') -Items (Get-ObjectPropertyValue -InputObject $data -Names @('Items') -Default @())
    }
})
(Get-UiControl 'UserSearchBox').Add_KeyDown({ param($sender, $eventArgs); if ($eventArgs.Key -eq [Windows.Input.Key]::Enter) { (Get-UiControl 'UserSearchButton').RaiseEvent((New-Object Windows.RoutedEventArgs -ArgumentList ([Windows.Controls.Button]::ClickEvent))) } })
(Get-UiControl 'UserGrid').Add_SelectionChanged({
    $user = Get-SelectedGridItem (Get-UiControl 'UserGrid')
    (Get-UiControl 'SelectedUserText').Text = if ($user) { "$($user.DisplayName) | $($user.SourceUPN) | $($user.Id)" } else { 'No user selected.' }
    Update-UiEnablement
})
(Get-UiControl 'UserTargetTaskCombo').Add_SelectionChanged({ Update-UiEnablement })
(Get-UiControl 'UserTargetCollectionCombo').Add_SelectionChanged({ Update-UiEnablement })
(Get-UiControl 'LoadUserAssociationsButton').Add_Click({
    $user = Get-SelectedGridItem (Get-UiControl 'UserGrid')
    if ($null -eq $user) { return }
    Invoke-EngineAsync -Operation 'FindObjectAssociations' -Parameters @{ ObjectId = [string]$user.Id } -Status 'Scanning task and collection memberships…' -OnSuccess {
        param($data)
        Set-GridItems -Grid (Get-UiControl 'UserTaskAssociationsGrid') -Items (Get-ObjectPropertyValue -InputObject $data -Names @('Tasks') -Default @())
        Set-GridItems -Grid (Get-UiControl 'UserCollectionAssociationsGrid') -Items (Get-ObjectPropertyValue -InputObject $data -Names @('Collections') -Default @())
    }
})

$directUserAction = {
    param([string]$Operation, [string]$TargetType, [bool]$Destructive)
    $user = Get-SelectedGridItem (Get-UiControl 'UserGrid')
    if ($null -eq $user) { return }
    $targetCombo = if ($TargetType -eq 'Task') { Get-UiControl 'UserTargetTaskCombo' } else { Get-UiControl 'UserTargetCollectionCombo' }
    $targetId = [string]$targetCombo.SelectedValue
    if ([string]::IsNullOrWhiteSpace($targetId)) { Show-UiMessage -Text "Select a target $($TargetType.ToLowerInvariant())." -Type Warning; return }
    if ($Destructive -and -not (Confirm-UiAction -Text "Remove $($user.SourceUPN) from the selected $($TargetType.ToLowerInvariant())?")) { return }
    $params = @{ ObjectId = [string]$user.Id }
    if ($TargetType -eq 'Task') { $params.TaskId = $targetId } else { $params.CollectionId = $targetId }
    Invoke-EngineAsync -Operation $Operation -Parameters $params -Status "$Operation…" -OnSuccess {
        (Get-UiControl 'LoadUserAssociationsButton').RaiseEvent((New-Object Windows.RoutedEventArgs -ArgumentList ([Windows.Controls.Button]::ClickEvent)))
    }
}
(Get-UiControl 'AddUserToTaskButton').Add_Click({ & $directUserAction 'AddObjectToTask' 'Task' $false })
(Get-UiControl 'RemoveUserFromTaskButton').Add_Click({ & $directUserAction 'RemoveObjectFromTask' 'Task' $true })
(Get-UiControl 'AddUserToCollectionButton').Add_Click({ & $directUserAction 'AddObjectToCollection' 'Collection' $false })
(Get-UiControl 'RemoveUserFromCollectionButton').Add_Click({ & $directUserAction 'RemoveObjectFromCollection' 'Collection' $true })

# Task events.
(Get-UiControl 'TaskGrid').Add_SelectionChanged({
    $items = ConvertTo-UiObjectArray -InputObject (Get-SelectedGridItems -Grid (Get-UiControl 'TaskGrid'))
    (Get-UiControl 'SelectedTaskText').Text = if ($items.Count -eq 1) { "$($items[0].Name) | $($items[0].Status) | $($items[0].Id)" } elseif ($items.Count -gt 1) { "$($items.Count) tasks selected." } else { 'No task selected.' }
    $loadedTask = Get-ObjectPropertyValue -InputObject (Get-ObjectPropertyValue -InputObject $script:State.TaskDetails -Names @('Task')) -Names @('Id')
    $selectedTask = if ($items.Count -eq 1) { [string](Get-ObjectPropertyValue -InputObject $items[0] -Names @('Id')) } else { $null }
    if ([string]::IsNullOrWhiteSpace([string]$selectedTask) -or -not [string]::Equals([string]$loadedTask,[string]$selectedTask,[StringComparison]::OrdinalIgnoreCase)) {
        $script:State.TaskDetails = $null
        (Get-UiControl 'TaskDetailsTextBox').Text = 'No task details loaded.'
        (Get-UiControl 'TaskDetailsStatusText').Text = if ($items.Count -eq 1) { 'Task selected. Choose Refresh details.' } else { 'Select one task and refresh details.' }
        Set-GridItems -Grid (Get-UiControl 'TaskEventsGrid') -Items @()
    }
    Update-UiEnablement
})
(Get-UiControl 'TaskSearchButton').Add_Click({
    Invoke-EngineAsync -Operation 'GetTasks' -Parameters @{ Search = [string](Get-UiControl 'TaskSearchBox').Text; Status = Get-ComboText (Get-UiControl 'TaskStatusCombo'); Refresh = $false } -Status 'Filtering tasks…' -OnSuccess { param($data); Set-GridItems -Grid (Get-UiControl 'TaskGrid') -Items $data }
})
(Get-UiControl 'TaskRefreshButton').Add_Click({
    Invoke-EngineAsync -Operation 'GetTasks' -Parameters @{ Search = [string](Get-UiControl 'TaskSearchBox').Text; Status = Get-ComboText (Get-UiControl 'TaskStatusCombo'); Refresh = $true } -Status 'Reloading tasks…' -OnSuccess { param($data); $script:State.TaskItems = ConvertTo-UiObjectArray -InputObject $data; Set-GridItems -Grid (Get-UiControl 'TaskGrid') -Items $data; Set-ComboItems -Combo (Get-UiControl 'UserTargetTaskCombo') -Items $data }
})
(Get-UiControl 'LoadTaskMembersButton').Add_Click({
    $task = Get-SelectedGridItem (Get-UiControl 'TaskGrid'); if ($null -eq $task) { return }
    Invoke-EngineAsync -Operation 'GetTaskMembers' -Parameters @{ TaskId = [string]$task.Id } -Status 'Loading task members…' -OnSuccess { param($data); Set-GridItems -Grid (Get-UiControl 'TaskMembersGrid') -Items $data }
})
(Get-UiControl 'StartSelectedTasksButton').Add_Click({
    $items = ConvertTo-UiObjectArray -InputObject (Get-SelectedGridItems -Grid (Get-UiControl 'TaskGrid')); if ($items.Count -eq 0) { return }
    if (-not (Confirm-UiAction -Text "Start $($items.Count) selected task(s)? Quest will determine whether each task state can be started or rerun.")) { return }
    Invoke-EngineAsync -Operation 'StartTasks' -Parameters @{ TaskIds = @($items | ForEach-Object { [string]$_.Id }) } -Status 'Starting selected tasks…' -OnSuccess { Refresh-Workspace }
})
(Get-UiControl 'StopSelectedTasksButton').Add_Click({
    $items = ConvertTo-UiObjectArray -InputObject (Get-SelectedGridItems -Grid (Get-UiControl 'TaskGrid')); if ($items.Count -eq 0) { return }
    if (-not (Confirm-UiAction -Text "Stop $($items.Count) selected task(s)?")) { return }
    Invoke-EngineAsync -Operation 'StopTasks' -Parameters @{ TaskIds = @($items | ForEach-Object { [string]$_.Id }) } -Status 'Stopping selected tasks…' -OnSuccess { Refresh-Workspace }
})
(Get-UiControl 'DeleteSelectedTasksButton').Add_Click({
    $items = ConvertTo-UiObjectArray -InputObject (Get-SelectedGridItems -Grid (Get-UiControl 'TaskGrid')); if ($items.Count -eq 0) { return }
    if (-not (Confirm-UiAction -Text "Permanently delete $($items.Count) selected Quest ODM task(s)? Running tasks will be stopped first when supported." -Title 'Delete selected tasks')) { return }
    Invoke-EngineAsync -Operation 'DeleteTasks' -Parameters @{ TaskIds = @($items | ForEach-Object { [string]$_.Id }); StopRunning = $true } -Status 'Deleting selected tasks…' -OnSuccess { Refresh-Workspace }
})
(Get-UiControl 'RefreshTaskDetailsButton').Add_Click({ Refresh-SelectedTaskDetails })
(Get-UiControl 'ExportTaskDetailsButton').Add_Click({
    $task = Get-SelectedGridItem (Get-UiControl 'TaskGrid'); if ($null -eq $task) { return }
    Invoke-EngineAsync -Operation 'ExportTaskDetails' -Parameters @{TaskId=[string]$task.Id;OutputDirectory=[string](Get-UiControl 'TaskOutputDirectoryBox').Text} -Status 'Exporting task details…' -OnSuccess {
        param($data)
        Apply-TaskDetails -Details (Get-ObjectPropertyValue -InputObject $data -Names @('Details'))
        $json=[string](Get-ObjectPropertyValue -InputObject $data -Names @('JsonPath'))
        $events=[string](Get-ObjectPropertyValue -InputObject $data -Names @('EventCsvPath'))
        Show-UiMessage -Text "Task details exported:`r`n$json`r`n$events" -Type Info
    }
})
(Get-UiControl 'CopyTaskIdButton').Add_Click({
    $task = Get-SelectedGridItem (Get-UiControl 'TaskGrid')
    if ($null -ne $task) { [Windows.Clipboard]::SetText([string]$task.Id); Write-UiLog -Message 'Copied the selected task ID.' }
})
(Get-UiControl 'CopyTaskDiagnosticButton').Add_Click({
    if ($null -ne $script:State.TaskDetails) { [Windows.Clipboard]::SetText((Format-TaskDetailsText -Details $script:State.TaskDetails)); Write-UiLog -Message 'Copied the selected task diagnostic summary.' }
})
(Get-UiControl 'CreateTaskErrorExportButton').Add_Click({
    $task = Get-SelectedGridItem (Get-UiControl 'TaskGrid'); if ($null -eq $task) { return }
    if (-not (Confirm-UiAction -Text "Create a Quest error-log export task for '$($task.Name)'? The new export task will not be started automatically." -Title 'Create task error-log export')) { return }
    Invoke-EngineAsync -Operation 'CreateTaskErrorLogExport' -Parameters @{TaskId=[string]$task.Id} -Status 'Creating Quest error-log export task…' -OnSuccess { param($data); Show-UiMessage -Text 'The Quest error-log export task was created. Refresh the task inventory to review or start it.' -Type Info; Refresh-Workspace }
})
(Get-UiControl 'TaskDetailsAutoRefreshCheckBox').Add_Checked({ Update-UiEnablement })
(Get-UiControl 'TaskDetailsAutoRefreshCheckBox').Add_Unchecked({ Update-UiEnablement })
(Get-UiControl 'TaskDetailsRefreshSecondsCombo').Add_SelectionChanged({
    if ($null -ne $script:State.TaskDetailsTimer) {
        $seconds = ConvertTo-UiInt -Text (Get-ComboText (Get-UiControl 'TaskDetailsRefreshSecondsCombo')) -Default 30 -Minimum 15
        $script:State.TaskDetailsTimer.Interval = [TimeSpan]::FromSeconds($seconds)
    }
})
(Get-UiControl 'BrowseTaskCsvButton').Add_Click({ Browse-ForCsv -TargetTextBox (Get-UiControl 'TaskCsvPathBox') })
(Get-UiControl 'BrowseTaskOutputDirectoryButton').Add_Click({ Browse-ForFolder -TargetTextBox (Get-UiControl 'TaskOutputDirectoryBox') })

function Complete-UiCsvMembershipAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Task','Collection')][string]$EntityType,
        [Parameter(Mandatory = $true)][string]$GridName,
        [AllowNull()][object]$Data
    )

    $reportRows = ConvertTo-UiObjectArray -InputObject (Get-ObjectPropertyValue -InputObject $Data -Names @('Report') -Default @())
    Set-GridItems -Grid (Get-UiControl $GridName) -Items $reportRows

    $execute = [bool](Get-ObjectPropertyValue -InputObject $Data -Names @('Execute') -Default $false)
    $resolvedCount = ConvertTo-UiInt -Text ([string](Get-ObjectPropertyValue -InputObject $Data -Names @('ResolvedCount') -Default 0)) -Default 0 -Minimum 0
    $commandSucceededCount = ConvertTo-UiInt -Text ([string](Get-ObjectPropertyValue -InputObject $Data -Names @('CommandSucceededCount') -Default 0)) -Default 0 -Minimum 0
    $verifiedCount = ConvertTo-UiInt -Text ([string](Get-ObjectPropertyValue -InputObject $Data -Names @('VerifiedCount') -Default 0)) -Default 0 -Minimum 0
    $reportPath = [string](Get-ObjectPropertyValue -InputObject $Data -Names @('ReportPath'))
    if ([string]::IsNullOrWhiteSpace($reportPath)) { $reportPath = '<not returned>' }

    $action = $null
    foreach ($row in $reportRows) {
        $candidate = [string](Get-ObjectPropertyValue -InputObject $row -Names @('Action'))
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $action = $candidate; break }
    }
    $actionText = switch ($action) {
        'Add' { 'add' }
        'Remove' { 'remove' }
        default { 'membership' }
    }

    if ($execute) {
        $complete = ($resolvedCount -gt 0 -and $commandSucceededCount -eq $resolvedCount -and $verifiedCount -eq $resolvedCount)
        $messageType = if ($complete) { 'Info' } else { 'Warning' }
        Show-UiMessage -Text ("{0} CSV {1} completed.`r`n`r`nRows reported: {2}`r`nResolved: {3}`r`nCommands succeeded: {4}`r`nVerified: {5}`r`nReport: {6}" -f $EntityType,$actionText,$reportRows.Count,$resolvedCount,$commandSucceededCount,$verifiedCount,$reportPath) -Type $messageType
    }
    else {
        $messageType = if ($resolvedCount -gt 0) { 'Info' } else { 'Warning' }
        Show-UiMessage -Text ("{0} CSV {1} preview completed. No API changes were submitted.`r`n`r`nRows reported: {2}`r`nResolved: {3}`r`nReport: {4}" -f $EntityType,$actionText,$reportRows.Count,$resolvedCount,$reportPath) -Type $messageType
    }
}

$taskCsvAction = {
    param([string]$Operation, [string]$Verb)
    $task = Get-SelectedGridItem (Get-UiControl 'TaskGrid'); if ($null -eq $task) { return }
    $csv = [string](Get-UiControl 'TaskCsvPathBox').Text; if ([string]::IsNullOrWhiteSpace($csv)) { Show-UiMessage -Text 'Select a CSV file.' -Type Warning; return }
    $execute = [bool](Get-UiControl 'TaskCsvExecuteCheckBox').IsChecked
    if ($execute -and -not (Confirm-UiAction -Text "$Verb the CSV users for task '$($task.Name)'?")) { return }
    Invoke-EngineAsync -Operation $Operation -Parameters @{ EntityType = 'Task'; EntityId = [string]$task.Id; CsvPath = $csv; Execute = $execute; OutputDirectory = [string](Get-UiControl 'TaskOutputDirectoryBox').Text } -Status "$Verb CSV users…" -OnSuccess {
        param($data)
        Complete-UiCsvMembershipAction -EntityType Task -GridName 'TaskMembersGrid' -Data $data
    }
}
(Get-UiControl 'AddCsvUsersToTaskButton').Add_Click({ & $taskCsvAction 'AddUsersToEntityFromCsv' 'Add' })
(Get-UiControl 'RemoveCsvUsersFromTaskButton').Add_Click({ & $taskCsvAction 'RemoveUsersFromEntityFromCsv' 'Remove' })
(Get-UiControl 'ExportTasksButton').Add_Click({
    Invoke-EngineAsync -Operation 'Bulk' -Parameters @{ Operation = 'ExportTasks'; Parameters = @{ OutputDirectory = [string](Get-UiControl 'TaskOutputDirectoryBox').Text; IncludeAllProjects = $false } } -Status 'Exporting task inventory…' -OnSuccess { param($data); Set-GridItems -Grid (Get-UiControl 'TaskMembersGrid') -Items (Get-ObjectPropertyValue -InputObject $data -Names @('Rows') -Default @()) }
})

# Collection events.
(Get-UiControl 'CollectionGrid').Add_SelectionChanged({
    $items = ConvertTo-UiObjectArray -InputObject (Get-SelectedGridItems -Grid (Get-UiControl 'CollectionGrid'))
    (Get-UiControl 'SelectedCollectionText').Text = if ($items.Count -eq 1) { "$($items[0].Name) | $($items[0].Id)" } elseif ($items.Count -gt 1) { "$($items.Count) collections selected." } else { 'No collection selected.' }
    Update-UiEnablement
})
(Get-UiControl 'CollectionSearchButton').Add_Click({
    Invoke-EngineAsync -Operation 'GetCollections' -Parameters @{ Search = [string](Get-UiControl 'CollectionSearchBox').Text; Refresh = $false; IncludeCounts = $false } -Status 'Filtering collections…' -OnSuccess { param($data); Set-GridItems -Grid (Get-UiControl 'CollectionGrid') -Items $data }
})
(Get-UiControl 'CollectionRefreshButton').Add_Click({
    Invoke-EngineAsync -Operation 'GetCollections' -Parameters @{ Search = [string](Get-UiControl 'CollectionSearchBox').Text; Refresh = $true; IncludeCounts = $false } -Status 'Reloading collections…' -OnSuccess { param($data); $script:State.CollectionItems = ConvertTo-UiObjectArray -InputObject $data; Set-GridItems -Grid (Get-UiControl 'CollectionGrid') -Items $data; Set-ComboItems -Combo (Get-UiControl 'UserTargetCollectionCombo') -Items $data }
})
(Get-UiControl 'LoadCollectionMembersButton').Add_Click({
    $collection = Get-SelectedGridItem (Get-UiControl 'CollectionGrid'); if ($null -eq $collection) { return }
    Invoke-EngineAsync -Operation 'GetCollectionMembers' -Parameters @{ CollectionId = [string]$collection.Id } -Status 'Loading collection members…' -OnSuccess { param($data); Set-GridItems -Grid (Get-UiControl 'CollectionMembersGrid') -Items $data }
})
(Get-UiControl 'CreateCollectionButton').Add_Click({
    $name = [string](Get-UiControl 'NewCollectionNameBox').Text
    if ([string]::IsNullOrWhiteSpace($name)) { Show-UiMessage -Text 'Enter a collection name.' -Type Warning; return }
    Invoke-EngineAsync -Operation 'NewCollection' -Parameters @{ Name = $name } -Status 'Creating collection…' -OnSuccess { (Get-UiControl 'NewCollectionNameBox').Clear(); Refresh-Workspace }
})
(Get-UiControl 'DeleteSelectedCollectionsButton').Add_Click({
    $items = ConvertTo-UiObjectArray -InputObject (Get-SelectedGridItems -Grid (Get-UiControl 'CollectionGrid')); if ($items.Count -eq 0) { return }
    if (-not (Confirm-UiAction -Text "Permanently delete $($items.Count) selected collection(s)?" -Title 'Delete selected collections')) { return }
    Invoke-EngineAsync -Operation 'DeleteCollections' -Parameters @{ CollectionIds = @($items | ForEach-Object { [string]$_.Id }) } -Status 'Deleting collections…' -OnSuccess {
        param($data)
        $failed = ConvertTo-UiObjectArray -InputObject ((ConvertTo-UiObjectArray -InputObject $data) | Where-Object { -not (Test-ObjectPropertyTrue -InputObject $_ -Names @('Deleted')) })
        if ($failed.Count -gt 0) {
            $details = @($failed | ForEach-Object {
                $displayName = [string](Get-ObjectPropertyValue -InputObject $_ -Names @('CollectionName','CollectionId') -Default '<unknown collection>')
                $detailText = [string](Get-ObjectPropertyValue -InputObject $_ -Names @('Details','Status') -Default 'No error details were returned.')
                '{0}: {1}' -f $displayName, $detailText
            }) -join "`r`n"
            Show-UiMessage -Text ("Collection deletion completed with {0} failure(s):`r`n`r`n{1}" -f $failed.Count, $details) -Type Warning
        }
        Refresh-Workspace
    }
})
(Get-UiControl 'BrowseCollectionCsvButton').Add_Click({ Browse-ForCsv -TargetTextBox (Get-UiControl 'CollectionCsvPathBox') })
(Get-UiControl 'BrowseCollectionOutputDirectoryButton').Add_Click({ Browse-ForFolder -TargetTextBox (Get-UiControl 'CollectionOutputDirectoryBox') })

$collectionCsvAction = {
    param([string]$Operation, [string]$Verb)
    $collection = Get-SelectedGridItem (Get-UiControl 'CollectionGrid'); if ($null -eq $collection) { return }
    $csv = [string](Get-UiControl 'CollectionCsvPathBox').Text; if ([string]::IsNullOrWhiteSpace($csv)) { Show-UiMessage -Text 'Select a CSV file.' -Type Warning; return }
    $execute = [bool](Get-UiControl 'CollectionCsvExecuteCheckBox').IsChecked
    if ($execute -and -not (Confirm-UiAction -Text "$Verb the CSV users for collection '$($collection.Name)'?")) { return }
    Invoke-EngineAsync -Operation $Operation -Parameters @{ EntityType = 'Collection'; EntityId = [string]$collection.Id; CsvPath = $csv; Execute = $execute; OutputDirectory = [string](Get-UiControl 'CollectionOutputDirectoryBox').Text } -Status "$Verb CSV users…" -OnSuccess {
        param($data)
        Complete-UiCsvMembershipAction -EntityType Collection -GridName 'CollectionMembersGrid' -Data $data
    }
}
(Get-UiControl 'AddCsvUsersToCollectionButton').Add_Click({ & $collectionCsvAction 'AddUsersToEntityFromCsv' 'Add' })
(Get-UiControl 'RemoveCsvUsersFromCollectionButton').Add_Click({ & $collectionCsvAction 'RemoveUsersFromEntityFromCsv' 'Remove' })
(Get-UiControl 'ExportCollectionsButton').Add_Click({
    Invoke-EngineAsync -Operation 'Bulk' -Parameters @{ Operation = 'ExportCollections'; Parameters = @{ OutputDirectory = [string](Get-UiControl 'CollectionOutputDirectoryBox').Text; IncludeCounts = $true } } -Status 'Exporting collection inventory…' -OnSuccess { param($data); Set-GridItems -Grid (Get-UiControl 'CollectionMembersGrid') -Items (Get-ObjectPropertyValue -InputObject $data -Names @('Rows') -Default @()) }
})

# Task factory events.
(Get-UiControl 'FactoryModeCombo').Add_SelectionChanged({ (Get-UiControl 'FactoryTemplateOptionsPanel').IsEnabled = ((Get-ComboText (Get-UiControl 'FactoryModeCombo')) -eq 'Template') })
(Get-UiControl 'BrowseFactoryCsvButton').Add_Click({ Browse-ForCsv -TargetTextBox (Get-UiControl 'FactoryCsvPathBox') })
(Get-UiControl 'BrowseFactoryOutputDirectoryButton').Add_Click({ Browse-ForFolder -TargetTextBox (Get-UiControl 'FactoryOutputDirectoryBox') })
(Get-UiControl 'PreviewTaskFactoryButton').Add_Click({ Invoke-TaskFactoryFromUi -Execute $false })
(Get-UiControl 'RunTaskFactoryButton').Add_Click({ Invoke-TaskFactoryFromUi -Execute $true })

# Bulk operation events.
(Get-UiControl 'BulkOperationCombo').Add_SelectionChanged({
    Update-BulkOperationUi -Selected (Get-UiControl 'BulkOperationCombo').SelectedItem
})
(Get-UiControl 'BrowseBulkCsvButton').Add_Click({ Browse-ForCsv -TargetTextBox (Get-UiControl 'BulkCsvPathBox') })
(Get-UiControl 'OpenBulkTemplateButton').Add_Click({ Open-BulkTemplate })
(Get-UiControl 'BrowseBulkOutputDirectoryButton').Add_Click({ Browse-ForFolder -TargetTextBox (Get-UiControl 'BulkOutputDirectoryBox') })
(Get-UiControl 'RunBulkOperationButton').Add_Click({ Invoke-BulkFromUi })
(Get-UiControl 'LaunchMappingCollisionUtilityButton').Add_Click({ Start-MappingCollisionUtility })
(Get-UiControl 'OpenMappingCollisionUtilityFolderButton').Add_Click({ Open-MappingCollisionUtilityFolder })
(Get-UiControl 'BulkExecuteCheckBox').Add_Checked({ Update-UiEnablement })
(Get-UiControl 'BulkExecuteCheckBox').Add_Unchecked({ Update-UiEnablement })
(Get-UiControl 'TaskCsvExecuteCheckBox').Add_Checked({ Update-UiEnablement })
(Get-UiControl 'TaskCsvExecuteCheckBox').Add_Unchecked({ Update-UiEnablement })
(Get-UiControl 'CollectionCsvExecuteCheckBox').Add_Checked({ Update-UiEnablement })
(Get-UiControl 'CollectionCsvExecuteCheckBox').Add_Unchecked({ Update-UiEnablement })

# Theme events.
(Get-UiControl 'DarkModeCheckBox').Add_Checked({
    if ($script:State.Theme -ne 'Dark') {
        Set-UiTheme -Theme 'Dark'
        Save-UiSettings
        Write-UiLog -Message 'Dark mode enabled.' -Level SUCCESS
    }
})
(Get-UiControl 'DarkModeCheckBox').Add_Unchecked({
    if ($script:State.Theme -ne 'Light') {
        Set-UiTheme -Theme 'Light'
        Save-UiSettings
        Write-UiLog -Message 'Light mode enabled.' -Level SUCCESS
    }
})

# Diagnostics events.
(Get-UiControl 'RefreshEnvironmentButton').Add_Click({ Update-EnvironmentInfo })
(Get-UiControl 'CheckOdmApiVersionButton').Add_Click({ Update-OdmApiModuleStatus -CheckOnline $true })
(Get-UiControl 'InstallOdmApiButton').Add_Click({ Invoke-OdmApiModuleAction -Action Install -Target Validated })
(Get-UiControl 'UpdateOdmApiButton').Add_Click({ Invoke-OdmApiModuleAction -Action Update -Target Validated })
(Get-UiControl 'InstallLatestOdmApiButton').Add_Click({ Invoke-OdmApiModuleAction -Action Update -Target Latest })
(Get-UiControl 'CopyInstallCommandButton').Add_Click({ [Windows.Clipboard]::SetText([string](Get-UiControl 'InstallModuleCommandBox').Text); Write-UiLog -Message 'Copied the OdmApi installation command to the clipboard.' })
(Get-UiControl 'RunReadinessButton').Add_Click({ Run-ReadinessFromUi })
(Get-UiControl 'OpenReadinessReportButton').Add_Click({
    try { if ([string]::IsNullOrWhiteSpace($script:State.ReadinessHtmlPath)) { throw 'No readiness HTML report is available.' }; Start-Process -FilePath $script:State.ReadinessHtmlPath -ErrorAction Stop }
    catch { Show-UiMessage -Text $_.Exception.Message -Type Error }
})
(Get-UiControl 'CopyReadinessSummaryButton').Add_Click({ [Windows.Clipboard]::SetText([string](Get-UiControl 'ReadinessSummaryText').Text); Write-UiLog -Message 'Copied the readiness summary.' })
(Get-UiControl 'ProfileCombo').Add_SelectionChanged({ Update-UiEnablement })
(Get-UiControl 'SaveProfileButton').Add_Click({ Save-CurrentUiProfile })
(Get-UiControl 'LoadProfileButton').Add_Click({ Apply-UiProfile -Profile (Get-UiControl 'ProfileCombo').SelectedItem })
(Get-UiControl 'DeleteProfileButton').Add_Click({ Delete-SelectedUiProfile })
(Get-UiControl 'CreateSupportBundleButton').Add_Click({ Create-SupportBundleFromUi })
(Get-UiControl 'OpenLogsButton').Add_Click({
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:LogsPath.Replace('"','')) -ErrorAction Stop }
    catch { Show-UiMessage -Text $_.Exception.Message -Type Error }
})
(Get-UiControl 'CleanOldLogsButton').Add_Click({ Invoke-UiLogMaintenanceFromUi -Mode Retention })
(Get-UiControl 'ClearStoredLogsButton').Add_Click({ Invoke-UiLogMaintenanceFromUi -Mode ClearHistorical })
(Get-UiControl 'RefreshOperationHistoryButton').Add_Click({ Refresh-OperationHistory })
(Get-UiControl 'OpenOperationHistoryButton').Add_Click({
    try { if (-not (Test-Path -LiteralPath $script:OperationHistoryPath -PathType Leaf)) { throw 'No operation-history file exists yet.' }; Start-Process -FilePath $script:OperationHistoryPath -ErrorAction Stop }
    catch { Show-UiMessage -Text $_.Exception.Message -Type Error }
})
(Get-UiControl 'TestMmpcButton').Add_Click({
    Invoke-EngineAsync -Operation 'TestMmpcFlag' -Status 'Checking MmpcEnrollmentFlag…' -OnSuccess {
        param($data)
        (Get-UiControl 'MmpcStateText').Text = "Exists: $([string](Get-ObjectPropertyValue -InputObject $data -Names @('Exists'))) | Value: $([string](Get-ObjectPropertyValue -InputObject $data -Names @('Value'))) | $([string](Get-ObjectPropertyValue -InputObject $data -Names @('Message')))"
    }
})
(Get-UiControl 'RemoveMmpcButton').Add_Click({
    if (-not (Confirm-UiAction -Text 'Remove only the 64-bit HKLM MmpcEnrollmentFlag registry value on this computer? Administrative rights may be required.' -Title 'Remove MmpcEnrollmentFlag')) { return }
    Invoke-EngineAsync -Operation 'RemoveMmpcFlag' -Parameters @{} -Status 'Removing MmpcEnrollmentFlag…' -OnSuccess {
        param($data)
        $after = Get-ObjectPropertyValue -InputObject $data -Names @('After')
        (Get-UiControl 'MmpcStateText').Text = "$([string](Get-ObjectPropertyValue -InputObject $data -Names @('Message'))) | Exists after: $([string](Get-ObjectPropertyValue -InputObject $after -Names @('Exists')))"
    }
})
(Get-UiControl 'ClearLogButton').Add_Click({ (Get-UiControl 'DiagnosticsLogBox').Clear() })
(Get-UiControl 'SaveLogButton').Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.FileName = [IO.Path]::GetFileName($script:SessionLogPath)
    if ($dialog.ShowDialog($script:Window)) { (Get-UiControl 'DiagnosticsLogBox').Text | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8 }
})
(Get-UiControl 'OpenReportsButton').Add_Click({
    try {
        $path = Get-UiReportDirectory -Candidate ([string](Get-UiControl 'BulkOutputDirectoryBox').Text)
        if (-not (Test-UiDirectoryWritable -Path $path -Create $true)) { throw "The report directory is unavailable or not writable: $path" }
        (Get-UiControl 'BulkOutputDirectoryBox').Text = $path
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $path.Replace('"', '')) -ErrorAction Stop
    }
    catch { Show-UiMessage -Text $_.Exception.Message -Type Error }
})

$script:Window.Dispatcher.Add_UnhandledException({
    param($sender, $eventArgs)
    $message = if ($eventArgs.Exception) { $eventArgs.Exception.ToString() } else { 'An unknown WPF dispatcher error occurred.' }
    Write-UiLog -Message "Unhandled UI exception: $message" -Level ERROR
    try {
        $exception = Get-ObjectPropertyValue -InputObject $eventArgs -Names @('Exception')
        $dialogText = [string](Get-ObjectPropertyValue -InputObject $exception -Names @('Message') -Default $message)
        Show-UiMessage -Text $dialogText -Title 'Quest ODM Console error' -Type Error
    }
    catch { }
    if ($null -ne $eventArgs) { $eventArgs.Handled = $true }
})

$script:Window.Add_Closing({
    try { Save-UiSettings }
    catch { Write-UiLog -Message "Settings could not be saved during shutdown: $($_.Exception.Message)" -Level WARN }
    finally {
        if ($null -ne $script:State.TaskDetailsTimer) { try { $script:State.TaskDetailsTimer.Stop() } catch { }; $script:State.TaskDetailsTimer = $null }
        Stop-WorkerRunspace
    }
})

# Apply the initial bulk-operation selection after the event handler is registered.
Update-BulkOperationUi -Selected (Get-UiControl 'BulkOperationCombo').SelectedItem

# Online module checks are user initiated from Diagnostics. Startup performs only a local check.
Initialize-TaskDetailsTimer

$env:QUESTODMCONSOLE_UI_PHASE = 'Applying branded UI assets'
Set-UiBrandAssets
Update-MappingCollisionUtilityStatus

$env:QUESTODMCONSOLE_UI_PHASE = 'Applying initial UI state'
# Initial visual state.
Reset-WorkspaceUi
Set-ConnectionStatus -Connected $false -Text 'Disconnected'
Write-UiLog -Message "Session started. Log: $script:SessionLogPath"
Update-UiEnablement

$env:QUESTODMCONSOLE_UI_PHASE = 'Opening the main application window'
[void]$script:Window.ShowDialog()
$env:QUESTODMCONSOLE_UI_PHASE = 'Main window closed normally'
