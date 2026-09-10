[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$xamlPath = Join-Path $root 'Resources\QuestODMConsole.xaml'
$logoPath = Join-Path $root 'Resources\QuestSoftwareLogo.png'
$uiPath = Join-Path $root 'QuestODMConsole.UI.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:failures.Add($Message) | Out-Null
}

foreach ($required in @($xamlPath,$logoPath,$uiPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { Add-Failure "Missing required branding file: $required" }
}

if ($failures.Count -eq 0) {
    try {
        [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -ErrorAction Stop
        $ns = New-Object System.Xml.XmlNamespaceManager($xaml.NameTable)
        $ns.AddNamespace('p','http://schemas.microsoft.com/winfx/2006/xaml/presentation')
        $ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')

        $logoNode = $xaml.SelectSingleNode('//*[@x:Name="QuestLogoImage"]',$ns)
        if ($null -eq $logoNode) { Add-Failure 'QuestLogoImage is missing from production XAML.' }
        else {
            if ([string]$logoNode.Stretch -ne 'Uniform') { Add-Failure 'QuestLogoImage must use Stretch="Uniform".' }
            if ([string]$logoNode.Width -ne '122') { Add-Failure 'QuestLogoImage width must remain 122 pixels.' }
            if ([string]$logoNode.Height -ne '31') { Add-Failure 'QuestLogoImage height must remain 31 pixels.' }
        }

        $tabStyle = $xaml.SelectSingleNode('//p:Style[@TargetType="TabItem"]',$ns)
        if ($null -eq $tabStyle) { Add-Failure 'Production TabItem style was not found.' }
        else {
            $padding = $tabStyle.SelectSingleNode('./p:Setter[@Property="Padding"]',$ns)
            $margin = $tabStyle.SelectSingleNode('./p:Setter[@Property="Margin"]',$ns)
            $minHeight = $tabStyle.SelectSingleNode('./p:Setter[@Property="MinHeight"]',$ns)
            $tabBorder = $tabStyle.SelectSingleNode('.//p:Border[@x:Name="TabBorder"]',$ns)
            if ($null -eq $padding -or [string]$padding.Value -ne '15,8') { Add-Failure 'Tab padding does not match the accepted V1.0.0 layout.' }
            if ($null -eq $margin -or [string]$margin.Value -ne '0,0,6,0') { Add-Failure 'Tab margin does not match the accepted V1.0.0 layout.' }
            if ($null -ne $minHeight) { Add-Failure 'A MinHeight setter was reintroduced into the global TabItem style.' }
            if ($null -eq $tabBorder -or [string]$tabBorder.CornerRadius -ne '16') { Add-Failure 'Tab corner radius does not match the accepted V1.0.0 layout.' }
        }
    }
    catch { Add-Failure ("XAML branding validation failed: {0}" -f $_.Exception.Message) }

    try {
        $bytes = [IO.File]::ReadAllBytes($logoPath)
        $expected = [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A)
        if ($bytes.Length -lt 32) { Add-Failure 'QuestSoftwareLogo.png is unexpectedly small.' }
        else {
            for ($i=0; $i -lt $expected.Length; $i++) {
                if ($bytes[$i] -ne $expected[$i]) { Add-Failure 'QuestSoftwareLogo.png has an invalid PNG signature.'; break }
            }
        }
    }
    catch { Add-Failure ("PNG validation failed: {0}" -f $_.Exception.Message) }

    try {
        $ui = Get-Content -LiteralPath $uiPath -Raw -ErrorAction Stop
        foreach ($required in @('function Set-UiBrandAssets','QuestSoftwareLogo.png','Get-UiControl ''QuestLogoImage''','Set-UiBrandAssets')) {
            if ($ui -notlike "*$required*") { Add-Failure "UI branding marker missing: $required" }
        }
        if ($ui -match 'Text="Q"\s+Foreground="White"') { Add-Failure 'The legacy single-letter Q header tile remains in the UI.' }
    }
    catch { Add-Failure ("UI branding-source validation failed: {0}" -f $_.Exception.Message) }

    if ($env:OS -eq 'Windows_NT') {
        try {
            Add-Type -AssemblyName PresentationCore -ErrorAction Stop
            $bitmap = New-Object Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.UriSource = [Uri]::new($logoPath,[UriKind]::Absolute)
            $bitmap.EndInit()
            if ($bitmap.PixelWidth -lt 400 -or $bitmap.PixelHeight -lt 90) { Add-Failure "WPF loaded an undersized logo: $($bitmap.PixelWidth)x$($bitmap.PixelHeight)." }
        }
        catch { Add-Failure ("WPF logo-load validation failed: {0}" -f $_.Exception.Message) }
    }
}

if ($failures.Count -gt 0) {
    $message = [System.Collections.Generic.List[string]]::new()
    $message.Add('V1 BRANDING TESTS: FAIL') | Out-Null
    foreach ($failure in $failures) { $message.Add("  - $failure") | Out-Null }
    throw ($message.ToArray() -join "`r`n")
}

Write-Output 'V1 BRANDING TESTS: PASS'
Write-Output '  - Quest Software wordmark asset and UI loader are present.'
Write-Output '  - Global tab geometry matches the accepted V1.0.0 layout.'
