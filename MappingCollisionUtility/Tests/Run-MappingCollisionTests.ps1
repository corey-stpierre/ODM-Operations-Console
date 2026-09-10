[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-McuTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "MAPPING COLLISION TEST ASSERTION FAILED: $Message" }
}

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$utilityRoot = Split-Path -Parent $testsRoot
$enginePath = Join-Path $utilityRoot 'Engine\MappingCollisionEngine.psm1'
$sourcePath = Join-Path $utilityRoot 'Samples\SourceInventory.Sample.csv'
$targetPath = Join-Path $utilityRoot 'Samples\TargetInventory.Sample.csv'
foreach ($path in @($enginePath,$sourcePath,$targetPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required test file was not found: $path" }
}

$sourceHashBefore = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$targetHashBefore = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('QuestODM-MappingCollisionTests-{0}' -f [Guid]::NewGuid().ToString('N'))
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
try {
    Import-Module -Name $enginePath -Force -ErrorAction Stop
    $result = Invoke-MappingCollisionAnalysis -SourceCsvPath $sourcePath -TargetCsvPath $targetPath -OutputDirectory $tempRoot

    Assert-McuTest -Condition ($null -ne $result) -Message 'The engine returned no result.'
    Assert-McuTest -Condition ([int]$result.Summary.SourceObjectCount -eq 8) -Message 'Expected eight source objects.'
    Assert-McuTest -Condition ([int]$result.Summary.TargetObjectCount -eq 8) -Message 'Expected eight target objects.'
    Assert-McuTest -Condition ([int]$result.Summary.CollisionCount -gt 0) -Message 'No collisions were produced.'
    Assert-McuTest -Condition ([int]$result.Summary.CandidateCount -gt 0) -Message 'No mapping candidates were produced.'
    Assert-McuTest -Condition ([int]$result.Summary.AmbiguousMappingCount -gt 0) -Message 'No ambiguous mappings were produced.'

    $categories = @($result.Collisions | ForEach-Object { [string]$_.Category } | Select-Object -Unique)
    foreach ($requiredCategory in @('InternalDuplicate','SplitAnchorConflict','ManyToOneMapping','CrossAttributeAnchorMatch')) {
        Assert-McuTest -Condition ($categories -contains $requiredCategory) -Message "Expected collision category '$requiredCategory' was not found."
    }
    $qualityCategories = @($result.InventoryQualityIssues | ForEach-Object { [string]$_.Category } | Select-Object -Unique)
    foreach ($requiredCategory in @('NoUsableAnchors','MalformedEmailAnchor','MalformedProxyAddress')) {
        Assert-McuTest -Condition ($qualityCategories -contains $requiredCategory) -Message "Expected quality category '$requiredCategory' was not found."
    }

    $carolCandidate = @($result.MappingCandidates | Where-Object { $_.SourceUPN -eq 'carol@source.example' -and $_.TargetUPN -eq 'carol@target.example' } | Select-Object -First 1)
    Assert-McuTest -Condition ($carolCandidate.Count -eq 1) -Message 'The known immutable-ID candidate for Carol was not found.'
    Assert-McuTest -Condition ([string]$carolCandidate[0].Disposition -eq 'Recommended') -Message 'The known unambiguous Carol candidate was not recommended.'
    Assert-McuTest -Condition ([int]$carolCandidate[0].Score -ge 90) -Message 'The Carol candidate did not receive strong evidence scoring.'
    Assert-McuTest -Condition (([string]$carolCandidate[0].MatchedNamespaces -split '\s*\|\s*') -contains 'ImmutableId') -Message 'The Carol candidate did not include immutable-ID evidence.'

    $daveCandidates = @($result.MappingCandidates | Where-Object SourceUPN -eq 'dave@source.example')
    Assert-McuTest -Condition ($daveCandidates.Count -eq 2) -Message 'The known split-anchor Dave scenario did not create two candidates.'
    Assert-McuTest -Condition (@($daveCandidates | Where-Object Disposition -eq 'Blocked - Ambiguous').Count -eq 2) -Message 'The Dave candidates were not blocked as ambiguous.'

    Assert-McuTest -Condition (@($result.MappingCandidates | Where-Object SourceUPN -eq 'not-an-upn').Count -eq 0) -Message 'A malformed source email value was used as a mapping anchor.'
    $collisionIds = @($result.Collisions | ForEach-Object { [string]$_.CollisionId })
    Assert-McuTest -Condition (@($collisionIds | Where-Object { $_ -notmatch '^COL-\d{6}$' }).Count -eq 0) -Message 'One or more collision IDs are not deterministic six-digit identifiers.'

    foreach ($reportProperty in @('CollisionDetails','MappingCandidates','AmbiguousMappings','InventoryQualityIssues','UnmatchedSourceObjects','Manifest','HtmlSummary')) {
        $path = [string]$result.Reports.$reportProperty
        Assert-McuTest -Condition (-not [string]::IsNullOrWhiteSpace($path)) -Message "Report property '$reportProperty' is blank."
        Assert-McuTest -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Report '$reportProperty' was not created: $path"
    }

    Assert-McuTest -Condition ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -eq $sourceHashBefore) -Message 'The source sample was modified by analysis.'
    Assert-McuTest -Condition ((Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash -eq $targetHashBefore) -Message 'The target sample was modified by analysis.'

    $manifest = Get-Content -LiteralPath $result.Reports.Manifest -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-McuTest -Condition ([string]$manifest.Source.Sha256 -eq $sourceHashBefore) -Message 'The manifest source hash does not match the input file.'
    Assert-McuTest -Condition ([string]$manifest.Target.Sha256 -eq $targetHashBefore) -Message 'The manifest target hash does not match the input file.'
    $reportFiles = @($manifest.ReportFiles)
    Assert-McuTest -Condition ($reportFiles.Count -eq 6) -Message 'The manifest does not contain all six generated report hashes.'
    foreach ($reportFile in $reportFiles) {
        Assert-McuTest -Condition (Test-Path -LiteralPath ([string]$reportFile.Path) -PathType Leaf) -Message "A manifest report path is unavailable: $($reportFile.Path)"
        $actualReportHash = (Get-FileHash -LiteralPath ([string]$reportFile.Path) -Algorithm SHA256).Hash
        Assert-McuTest -Condition ([string]::Equals([string]$reportFile.Sha256,$actualReportHash,[StringComparison]::OrdinalIgnoreCase)) -Message "A manifest report hash does not match: $($reportFile.Name)"
    }


    # Preview 5 regression: exercise private module functions inside module scope.
    $engineModule = Get-Module -Name MappingCollisionEngine -ErrorAction Stop
    $emptyReportPath = Join-Path $tempRoot 'EmptyRowsRegression.csv'
    & $engineModule { param($Path) Export-McuCsv -Path $Path -Rows @() -Columns @('One','Two') } $emptyReportPath
    Assert-McuTest -Condition (Test-Path -LiteralPath $emptyReportPath -PathType Leaf) -Message 'The empty-row CSV regression report was not created.'
    Assert-McuTest -Condition (-not [string]::IsNullOrWhiteSpace([string](Get-Content -LiteralPath $emptyReportPath -TotalCount 1))) -Message 'The empty-row CSV regression report has no header.'
    $emptyHtml = & $engineModule { ConvertTo-McuHtmlFragment -Rows @() -Columns @('One','Two') }
    Assert-McuTest -Condition ($emptyHtml -match 'No rows\.') -Message 'The empty-row HTML regression did not render safely.'

    # Preview 5 regression: harmless whitespace after SMTP: remains a valid email-like value.
    $spacedSmtpValid = & $engineModule { Test-McuEmailLike -Value 'SMTP: user@example.com' }
    Assert-McuTest -Condition ([bool]$spacedSmtpValid) -Message 'A valid spaced SMTP proxy was rejected.'

    Write-Output 'MAPPING COLLISION TESTS: PASS'
}
finally {
    Remove-Module MappingCollisionEngine -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
