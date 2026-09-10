[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $testsRoot
$uiPath = Join-Path $appRoot 'QuestODMConsole.UI.ps1'

function Assert-CallbackCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "UI CALLBACK SCOPE ASSERTION FAILED: $Message" }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($uiPath,[ref]$tokens,[ref]$parseErrors)
if ($null -eq $ast) { throw 'The PowerShell parser returned no AST for QuestODMConsole.UI.ps1.' }
$errors = @($parseErrors)
Assert-CallbackCondition -Condition ($errors.Count -eq 0) -Message ('The UI source contains parser errors: ' + (($errors | ForEach-Object { $_.Message }) -join '; '))

$closureCalls = @($ast.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) { return $false }
    return [string]::Equals([string]$node.Member.Extent.Text,'GetNewClosure',[StringComparison]::OrdinalIgnoreCase)
},$true))
Assert-CallbackCondition -Condition ($closureCalls.Count -eq 0) -Message 'Production UI callbacks still use GetNewClosure, which can detach them from script-scope helper functions.'

$uiText = Get-Content -LiteralPath $uiPath -Raw -ErrorAction Stop
foreach ($marker in @(
    'function Get-BulkResultRows',
    '$script:State.BulkUiContext = [pscustomobject]@{',
    "Get-BulkResultRows -Data `$data",
    "Invoke-EngineAsync -Operation 'Bulk'",
    '-OnSuccess $successCallback -OnFailure $failureCallback',
    '$script:State.ProfileLoadContext',
    '$script:State.OdmApiModuleActionContext',
    '$button.Tag = [pscustomobject]@{ Action = $action; ErrorText = $Text; Dialog = $dialog }',
    'The underlying operation was not rolled back. Verify the generated report and Quest state before retrying an executed write.'
)) {
    Assert-CallbackCondition -Condition ($uiText.IndexOf($marker,[StringComparison]::Ordinal) -ge 0) -Message "Required callback-scope marker is missing: $marker"
}

$bulkFunction = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]::Equals($node.Name,'Invoke-BulkFromUi',[StringComparison]::OrdinalIgnoreCase)
},$true))
Assert-CallbackCondition -Condition ($bulkFunction.Count -eq 1) -Message "Expected exactly one Invoke-BulkFromUi function; found $($bulkFunction.Count)."
$bulkText = [string]$bulkFunction[0].Extent.Text
Assert-CallbackCondition -Condition ($bulkText -match [regex]::Escape('Get-BulkResultRows -Data $data')) -Message 'Invoke-BulkFromUi no longer routes completed engine data through Get-BulkResultRows.'
Assert-CallbackCondition -Condition ($bulkText -match [regex]::Escape('$script:State.BulkUiContext')) -Message 'Invoke-BulkFromUi does not preserve callback context in script scope.'
Assert-CallbackCondition -Condition ($bulkText -notmatch 'GetNewClosure') -Message 'Invoke-BulkFromUi reintroduced a detached closure.'

Write-Output 'UI CALLBACK SCOPE TESTS: PASS'
