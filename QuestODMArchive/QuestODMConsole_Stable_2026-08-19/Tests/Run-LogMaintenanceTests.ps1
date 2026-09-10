[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$helperPath = Join-Path $root 'Shared\LogMaintenance.ps1'
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) { throw "Log-maintenance helper was not found: $helperPath" }
. $helperPath

function Assert-LogMaintenance {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw "LOG MAINTENANCE ASSERTION FAILED: $Message" }
}

function Write-TestUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    [IO.File]::WriteAllLines($Path,$Lines,(New-Object System.Text.UTF8Encoding -ArgumentList $true))
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('QuestODMConsole-LogMaintenanceTests-{0}' -f ([Guid]::NewGuid().ToString('N')))
try {
    $mainRoot = Join-Path $testRoot 'MainConsole'
    $mainLogs = Join-Path $mainRoot 'Logs'
    New-Item -Path $mainLogs -ItemType Directory -Force | Out-Null

    $currentMain = Join-Path $mainLogs 'QuestODMConsole_20260812-150000.log'
    $recentMain = Join-Path $mainLogs 'QuestODMConsole_20260811-150000.log'
    $oldMain = Join-Path $mainLogs 'QuestODMConsole_20260101-120000.log'
    $oldArchivedBootstrap = Join-Path $mainLogs 'QuestODMConsole-bootstrap.20260101-120000.log'
    $bootstrap = Join-Path $mainLogs 'QuestODMConsole-bootstrap.log'
    $history = Join-Path $mainLogs 'OperationHistory.jsonl'

    Write-TestUtf8File -Path $currentMain -Lines @('current session')
    Write-TestUtf8File -Path $recentMain -Lines @('recent session')
    Write-TestUtf8File -Path $oldMain -Lines @('old session')
    Write-TestUtf8File -Path $oldArchivedBootstrap -Lines @('old archived bootstrap')
    Write-TestUtf8File -Path $bootstrap -Lines @('old bootstrap content','another old bootstrap line')
    Write-TestUtf8File -Path $history -Lines @(
        '{"Timestamp":"2025-01-01T00:00:00Z","Operation":"Expired"}',
        '{"Timestamp":"2099-01-01T00:00:00Z","Operation":"Retained"}',
        'malformed support evidence must be retained'
    )

    foreach ($path in @($oldMain,$oldArchivedBootstrap,$bootstrap)) {
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-60)
    }
    (Get-Item -LiteralPath $recentMain).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
    (Get-Item -LiteralPath $currentMain).LastWriteTimeUtc = [DateTime]::UtcNow
    $bootstrapLengthBefore = (Get-Item -LiteralPath $bootstrap).Length

    $retention = Invoke-QOdmLogMaintenance -Application MainConsole -DataRoot $mainRoot -CurrentSessionLogPath $currentMain -RetentionDays 30 -Mode Retention
    Assert-LogMaintenance -Condition (-not (Test-Path -LiteralPath $oldMain)) -Message 'Expired console session log was not removed.'
    Assert-LogMaintenance -Condition (-not (Test-Path -LiteralPath $oldArchivedBootstrap)) -Message 'Expired archived bootstrap log was not removed.'
    Assert-LogMaintenance -Condition (Test-Path -LiteralPath $recentMain) -Message 'Recent console session log was removed.'
    Assert-LogMaintenance -Condition (Test-Path -LiteralPath $currentMain) -Message 'Active console session log was removed.'
    Assert-LogMaintenance -Condition ((Get-Item -LiteralPath $bootstrap).Length -lt $bootstrapLengthBefore) -Message 'Expired active bootstrap log was not reset.'
    Assert-LogMaintenance -Condition ([int]$retention.PrunedHistoryRecords -eq 1) -Message 'Exactly one expired operation-history record should have been pruned.'
    $historyText = [IO.File]::ReadAllText($history)
    Assert-LogMaintenance -Condition ($historyText -notmatch 'Expired') -Message 'Expired operation-history record remains.'
    Assert-LogMaintenance -Condition ($historyText -match 'Retained') -Message 'Recent operation-history record was removed.'
    Assert-LogMaintenance -Condition ($historyText -match 'malformed support evidence') -Message 'Malformed support evidence was not preserved during retention.'
    Assert-LogMaintenance -Condition ([int]$retention.FailureCount -eq 0) -Message 'Retention reported an unexpected failure.'

    $clearMain = Invoke-QOdmLogMaintenance -Application MainConsole -DataRoot $mainRoot -CurrentSessionLogPath $currentMain -RetentionDays 30 -Mode ClearHistorical
    Assert-LogMaintenance -Condition (Test-Path -LiteralPath $currentMain) -Message 'Active console session log was removed by ClearHistorical.'
    Assert-LogMaintenance -Condition (-not (Test-Path -LiteralPath $recentMain)) -Message 'Prior console session log was not removed by ClearHistorical.'
    Assert-LogMaintenance -Condition ((Get-Item -LiteralPath $history).Length -le 3) -Message 'Operation history was not cleared.'
    Assert-LogMaintenance -Condition ([int]$clearMain.FailureCount -eq 0) -Message 'Console ClearHistorical reported an unexpected failure.'

    $utilityRoot = Join-Path $testRoot 'MappingCollisionUtility'
    $utilityLogs = Join-Path $utilityRoot 'Logs'
    New-Item -Path $utilityLogs -ItemType Directory -Force | Out-Null
    $currentUtility = Join-Path $utilityLogs 'MappingCollisionUtility_20260812-150000.log'
    $recentUtility = Join-Path $utilityLogs 'MappingCollisionUtility_20260811-150000.log'
    $oldUtility = Join-Path $utilityLogs 'MappingCollisionUtility_20260101-120000.log'
    Write-TestUtf8File -Path $currentUtility -Lines @('current utility')
    Write-TestUtf8File -Path $recentUtility -Lines @('recent utility')
    Write-TestUtf8File -Path $oldUtility -Lines @('old utility')
    (Get-Item -LiteralPath $oldUtility).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-60)
    (Get-Item -LiteralPath $recentUtility).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)

    $utilityRetention = Invoke-QOdmLogMaintenance -Application MappingCollisionUtility -DataRoot $utilityRoot -CurrentSessionLogPath $currentUtility -RetentionDays 30 -Mode Retention
    Assert-LogMaintenance -Condition (-not (Test-Path -LiteralPath $oldUtility)) -Message 'Expired utility session log was not removed.'
    Assert-LogMaintenance -Condition (Test-Path -LiteralPath $recentUtility) -Message 'Recent utility session log was removed.'
    Assert-LogMaintenance -Condition (Test-Path -LiteralPath $currentUtility) -Message 'Active utility session log was removed.'
    Assert-LogMaintenance -Condition ([int]$utilityRetention.FailureCount -eq 0) -Message 'Utility retention reported an unexpected failure.'

    $utilityClear = Invoke-QOdmLogMaintenance -Application MappingCollisionUtility -DataRoot $utilityRoot -CurrentSessionLogPath $currentUtility -RetentionDays 30 -Mode ClearHistorical
    Assert-LogMaintenance -Condition (Test-Path -LiteralPath $currentUtility) -Message 'Active utility session log was removed by ClearHistorical.'
    Assert-LogMaintenance -Condition (-not (Test-Path -LiteralPath $recentUtility)) -Message 'Prior utility session log was not removed by ClearHistorical.'
    Assert-LogMaintenance -Condition ([int]$utilityClear.FailureCount -eq 0) -Message 'Utility ClearHistorical reported an unexpected failure.'

    Assert-LogMaintenance -Condition ((ConvertTo-QOdmLogRetentionDays -Value 'not-a-number' -Default 30) -eq 30) -Message 'Invalid retention input did not resolve to the default.'
    Write-Output 'LOG MAINTENANCE TESTS: PASS'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
