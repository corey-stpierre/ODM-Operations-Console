[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ParseErrors {
    param([Parameter(Mandatory = $true)][string]$Source)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    return @($errors)
}

$invalidSource = '$message = "$Label discovery via $command: available=$available"'
$validSource = '$message = "${Label} discovery via ${command}: available=$available"'

$invalidErrors = @(Get-ParseErrors -Source $invalidSource)
if ($invalidErrors.Count -eq 0) {
    throw 'Regression failure: the native parser did not reject the RC2 variable-plus-colon expression.'
}

$validErrors = @(Get-ParseErrors -Source $validSource)
if ($validErrors.Count -ne 0) {
    throw ('Regression failure: the corrected braced-variable expression did not parse: ' +
        (($validErrors | ForEach-Object Message) -join '; '))
}

$runtimeFiles = @(
    Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\QuestODMConsole.ps1')
    Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\QuestODMConsole.UI.ps1')
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\Engine') -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') }
) | Sort-Object FullName -Unique

$allErrors = [System.Collections.Generic.List[string]]::new()
foreach ($file in @($runtimeFiles)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($errorRecord in @($errors)) {
        $allErrors.Add(('{0}:{1}:{2}: {3}' -f $file.FullName,
                $errorRecord.Extent.StartLineNumber,
                $errorRecord.Extent.StartColumnNumber,
                $errorRecord.Message))
    }
}

if ($allErrors.Count -gt 0) {
    throw ("Runtime parser regression test failed:`r`n" + ($allErrors -join "`r`n"))
}

Write-Output 'PARSER REGRESSION TESTS: PASS'
