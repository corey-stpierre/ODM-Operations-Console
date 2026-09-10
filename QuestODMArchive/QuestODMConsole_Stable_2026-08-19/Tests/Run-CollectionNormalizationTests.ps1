[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $testsRoot

function Assert-NormalizationCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "COLLECTION NORMALIZATION ASSERTION FAILED: $Message" }
}

function Get-FunctionDefinitionText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$FunctionName
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($null -ne $errors -and $errors.Count -gt 0) {
        throw "Cannot extract '$FunctionName' because '$Path' contains parser errors: $((@($errors | ForEach-Object { $_.Message })) -join '; ')"
    }

    $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            [string]::Equals([string]$node.Name, $FunctionName, [StringComparison]::OrdinalIgnoreCase)
    }, $true))
    if ($matches.Count -ne 1) {
        throw "Expected exactly one '$FunctionName' definition in '$Path'; found $($matches.Count)."
    }
    return [string]$matches[0].Extent.Text
}

function ConvertTo-TestArray {
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

$engineDefinition = Get-FunctionDefinitionText -Path (Join-Path $appRoot 'Engine\Common.ps1') -FunctionName 'ConvertTo-QOdmObjectArray'
$uiPath = Join-Path $appRoot 'QuestODMConsole.UI.ps1'
$uiDefinition = Get-FunctionDefinitionText -Path $uiPath -FunctionName 'ConvertTo-UiObjectArray'
$selectedGridDefinition = Get-FunctionDefinitionText -Path $uiPath -FunctionName 'Get-SelectedGridItems'
$uiSafeCountDefinition = Get-FunctionDefinitionText -Path $uiPath -FunctionName 'Get-UiSafeCount'
. ([scriptblock]::Create($engineDefinition))
. ([scriptblock]::Create($uiDefinition))
. ([scriptblock]::Create($selectedGridDefinition))
. ([scriptblock]::Create($uiSafeCountDefinition))

function Invoke-NormalizerCase {
    param(
        [Parameter(Mandatory = $true)][string]$NormalizerName,
        [Parameter(Mandatory = $true)][scriptblock]$Normalizer,
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][int]$ExpectedCount,
        [AllowNull()][string[]]$ExpectedIds = $null
    )

    $raw = & $Normalizer $Value
    $items = ConvertTo-TestArray -InputObject $raw
    Assert-NormalizationCondition -Condition ($items.Count -eq $ExpectedCount) -Message "$NormalizerName returned $($items.Count) item(s); expected $ExpectedCount."
    if ($null -ne $ExpectedIds) {
        $actual = @($items | ForEach-Object {
            if ($null -eq $_) { return '<null>' }
            $property = $_.PSObject.Properties['Id']
            if ($null -ne $property) { return [string]$property.Value }
            return [string]$_
        })
        Assert-NormalizationCondition -Condition (($actual -join '|') -eq ($ExpectedIds -join '|')) -Message "$NormalizerName returned unexpected item order/content: $($actual -join '|')."
    }
}

$normalizers = @(
    [pscustomobject]@{ Name='Engine'; Invoke={ param($value) ConvertTo-QOdmObjectArray -InputObject $value } },
    [pscustomobject]@{ Name='UI'; Invoke={ param($value) ConvertTo-UiObjectArray -InputObject $value } }
)

foreach ($normalizer in $normalizers) {
    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value $null -ExpectedCount 0

    $empty = New-Object System.Collections.Generic.List[object]
    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value $empty -ExpectedCount 0

    $one = New-Object System.Collections.Generic.List[object]
    $one.Add([pscustomobject]@{ Id='one' }) | Out-Null
    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value $one -ExpectedCount 1 -ExpectedIds @('one')

    $many = New-Object System.Collections.Generic.List[object]
    $many.Add([pscustomobject]@{ Id='one' }) | Out-Null
    $many.Add([pscustomobject]@{ Id='two' }) | Out-Null
    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value $many -ExpectedCount 2 -ExpectedIds @('one','two')

    $wrapped = [System.Management.Automation.PSObject]::AsPSObject($many)
    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value $wrapped -ExpectedCount 2 -ExpectedIds @('one','two')

    $arrayList = [System.Collections.ArrayList]::new()
    [void]$arrayList.Add([pscustomobject]@{ Id='first' })
    [void]$arrayList.Add([pscustomobject]@{ Id='second' })
    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value $arrayList -ExpectedCount 2 -ExpectedIds @('first','second')

    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value ([object[]]@([pscustomobject]@{ Id='array-one' },[pscustomobject]@{ Id='array-two' })) -ExpectedCount 2 -ExpectedIds @('array-one','array-two')
    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value 'literal' -ExpectedCount 1 -ExpectedIds @('literal')
    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value @{ Key='Value' } -ExpectedCount 1
    Invoke-NormalizerCase -NormalizerName $normalizer.Name -Normalizer $normalizer.Invoke -Value ([pscustomobject]@{ Id='scalar' }) -ExpectedCount 1 -ExpectedIds @('scalar')
}


# Validate the production UI selection helper itself. This is intentionally
# independent of WPF so the zero/one/many cardinality contract can be tested on
# any PowerShell host with the native parser available.
$selectionCases = @(
    [pscustomobject]@{ Name='empty'; Items=[object[]]@(); Expected=0 },
    [pscustomobject]@{ Name='single'; Items=[object[]]@([pscustomobject]@{ Id='one' }); Expected=1 },
    [pscustomobject]@{ Name='multiple'; Items=[object[]]@([pscustomobject]@{ Id='one' },[pscustomobject]@{ Id='two' }); Expected=2 }
)
foreach ($case in $selectionCases) {
    $grid = [pscustomobject]@{ SelectedItems=$case.Items }
    $selected = Get-SelectedGridItems -Grid $grid
    Assert-NormalizationCondition -Condition ($null -ne $selected) -Message "Get-SelectedGridItems returned null for the $($case.Name) case."
    Assert-NormalizationCondition -Condition ($selected -is [System.Array]) -Message "Get-SelectedGridItems did not preserve object[] identity for the $($case.Name) case."
    $actual = Get-UiSafeCount -Value $selected
    Assert-NormalizationCondition -Condition ($actual -eq [int]$case.Expected) -Message "Get-SelectedGridItems returned $actual item(s) for the $($case.Name) case; expected $($case.Expected)."
}

Write-Output 'COLLECTION NORMALIZATION TESTS: PASS'
