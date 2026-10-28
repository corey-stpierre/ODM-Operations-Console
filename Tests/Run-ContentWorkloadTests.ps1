[CmdletBinding()]param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ODM-ContentTests-'+[Guid]::NewGuid().ToString('N'))
$oldDataRoot=$env:QUESTODMCONSOLE_DATA_ROOT
New-Item -ItemType Directory -Path $temp | Out-Null
$env:QUESTODMCONSOLE_DATA_ROOT=$temp
function Assert-ContentTest {param($Condition,[string]$Message) if(-not $Condition){throw "CONTENT TEST: $Message"}}
function Invoke-ContentTest {
    param([string]$Operation,[hashtable]$Parameters=@{})
    $result=Invoke-QOdmOperation -Operation $Operation -Parameters $Parameters
    if(-not $result.Success){throw "$Operation failed: $($result.Error)`n$($result.Details)"}
    $result.Data
}
function Select-ContentTestContext {
    param([string]$Workload)
    $null=Invoke-ContentTest SelectWorkload @{WorkloadId="content-$Workload"}
}
function Enable-ContentTestChanges {
    param([string]$Workload)
    $null=Invoke-ContentTest SetSafeMode @{Enabled=$false;OrganizationId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';ProjectId='project-001';WorkloadId="content-$Workload";ConfirmationText='ENABLE CHANGES'}
}
try {
    Remove-Module QuestODMConsole.Engine,OdmApi -Force -ErrorAction SilentlyContinue
    $manifest=Join-Path $PSScriptRoot 'Mocks\OdmApi\2.1.396\OdmApi.psd1'
    $mock=Import-Module $manifest -Global -Force -PassThru
    $global:QuestODMConsoleOdmApiPreload=[pscustomobject]@{Status='LOADED';Installed=$true;Loaded=$true;Version=[string]$mock.Version;Path=$mock.Path;ManifestPath=$manifest;CommandOwner='OdmApi';Details='Content workload test mock';Error=$null;PreloadedAt=Get-Date}
    $engine=Import-Module (Join-Path $root 'Engine\QuestODMConsole.Engine.psm1') -Force -PassThru
    Set-MockContentScenario
    $null=Invoke-ContentTest Connect @{Region='US'}
    $null=Invoke-ContentTest SelectOrganization @{OrganizationId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}
    $null=Invoke-ContentTest SelectProject @{ProjectId='project-001'}
    $catalog=& $engine {Get-QOdmContentTaskCatalog}
    foreach($workload in @('Teams','SharePoint','PowerBI')) {
        Select-ContentTestContext $workload
        $options=Invoke-ContentTest ContentOptions
        Assert-ContentTest (@($options.TaskKinds | Where-Object {-not $_.Available}).Count -eq 0) "$workload command contracts"
        foreach($kind in $options.ObjectKinds) {
            $inventory=Invoke-ContentTest ContentInventory @{ObjectKind=$kind}
            Assert-ContentTest ($inventory.Rows.Count -eq 2) "$workload/$kind typed inventory"
            Assert-ContentTest (@($inventory.Rows | Where-Object {$_.ObjectId -notlike "$kind-*"}).Count -eq 0) 'No foreign types in inventory'
        }
        foreach($spec in @($catalog | Where-Object {$_.Workload -eq $workload})) {
            $csv=Join-Path $temp ($spec.Key+'.csv')
            $taskName='Wave - '+$spec.Key
            @(
                [pscustomobject]@{CollectionName='Wave';ObjectId=$spec.ObjectKind+'-1';TaskName=$taskName}
                [pscustomobject]@{CollectionName='Wave';ObjectId=$spec.ObjectKind+'-2';TaskName=$taskName}
                [pscustomobject]@{CollectionName='Wave';ObjectId=$spec.ObjectKind+'-1';TaskName=$taskName}
            ) | Export-Csv $csv -NoTypeInformation
            $p=@{CsvPath=$csv;ObjectKind=$spec.ObjectKind;Action='Tasks';TaskKind=$spec.Key;OutputDirectory=$temp;DefaultAdminUser='admin@target.example'}
            if($spec.TemplateType){$p.TemplateId='template-'+$spec.TemplateType}
            $before=Get-MockOdmState
            $preview=Invoke-ContentTest ContentCsv $p
            Assert-ContentTest ($preview.Status -eq 'PREVIEW' -and $preview.Rows.Count -eq 3) 'Preview reports all input rows'
            Assert-ContentTest ((Get-MockOdmState).TaskCount -eq $before.TaskCount -and (Get-MockOdmState).CollectionCount -eq $before.CollectionCount) 'Preview performs no writes'
            $p.Execute=$true
            if($spec -eq @($catalog | Where-Object {$_.Workload -eq $workload})[0]) {
                $blocked=Invoke-QOdmOperation -Operation ContentCsv -Parameters $p
                Assert-ContentTest (-not $blocked.Success -and $blocked.Error -match 'Safe Mode') 'Safe Mode blocks content writes'
                Enable-ContentTestChanges $workload
            }
            $result=Invoke-ContentTest ContentCsv $p
            Assert-ContentTest ($result.Status -eq 'COMPLETED') "$($spec.Key) creation: $($result.Rows[0].Details)"
            Assert-ContentTest (@($result.Rows | Where-Object {$_.Status -ne 'VERIFIED'}).Count -eq 0) 'All memberships and links verified'
            $task=@(Get-OdmTask -All | Where-Object {$_.Name -eq $taskName})[0]
            Assert-ContentTest ($task.ObjectIds.Count -eq 2) 'Duplicate CSV IDs do not duplicate membership'
            Assert-ContentTest ($task.Run -eq 'later') 'Created tasks remain held'
            $count=(Get-MockOdmState).TaskCount
            $rerun=Invoke-ContentTest ContentCsv $p
            Assert-ContentTest ($rerun.Rows[0].Status -eq 'SKIPPED_EXISTING' -and (Get-MockOdmState).TaskCount -eq $count) 'Existing tasks are not duplicated or modified'
            Assert-ContentTest (Test-Path -LiteralPath $result.ReportPath) 'Results written to CSV'
        }
    }
    Select-ContentTestContext Teams
    Enable-ContentTestChanges Teams
    $invalid=Join-Path $temp 'invalid.csv'
    'CollectionName,ObjectId,TaskName','InvalidWave,Teams-1,InvalidTask','InvalidWave,Workspace-1,InvalidTask' | Set-Content $invalid
    $p=@{CsvPath=$invalid;ObjectKind='Teams';Action='Tasks';TaskKind='TeamsProvision';OutputDirectory=$temp;Execute=$true}
    $before=Get-MockOdmState
    $result=Invoke-ContentTest ContentCsv $p
    Assert-ContentTest ($result.Status -eq 'VALIDATION_FAILED' -and $result.Rows[0].Status -eq 'BLOCKED') 'One invalid object blocks the complete file'
    Assert-ContentTest ((Get-MockOdmState).TaskCount -eq $before.TaskCount -and (Get-MockOdmState).CollectionCount -eq $before.CollectionCount) 'Invalid input makes no writes'
    'CollectionName,ObjectId,TaskName','WaveA,Teams-1,DuplicateTask','WaveB,Teams-2,DuplicateTask' | Set-Content $invalid
    $result=Invoke-ContentTest ContentCsv $p
    Assert-ContentTest ($result.Status -eq 'VALIDATION_FAILED') 'Conflicting task groups rejected'
    'CollectionName,ObjectId,TaskName,WorkloadId','Wave,Teams-1,WrongContext,content-PowerBI' | Set-Content $invalid
    Assert-ContentTest ((Invoke-ContentTest ContentCsv $p).Status -eq 'VALIDATION_FAILED') 'Stale exported context rejected'
    'CollectionName,ObjectId,TaskName','Wave,Teams-1,WrongTemplate' | Set-Content $invalid
    $p.TaskKind='TeamsMigrate';$p.TemplateId='template-migrategroups'
    $bad=Invoke-QOdmOperation ContentCsv $p
    Assert-ContentTest (-not $bad.Success -and $bad.Error -match 'Template type') 'Wrong task template rejected'
    $p.TemplateId='template-migrateteams'
    & $mock {($script:Templates | Where-Object {$_.Id -eq 'template-migrateteams'}).ProjectId='another-project'}
    $bad=Invoke-QOdmOperation ContentCsv $p
    Assert-ContentTest (-not $bad.Success -and $bad.Error -match 'not owned') 'Foreign project template rejected'
    $p.Action='Collections';$p.Remove('TemplateId');$p.Remove('TaskKind')
    & $mock {($script:Objects | Where-Object {$_.Id -eq 'Teams-1'}).FailWrites=$true}
    'CollectionName,ObjectId','PartialWave,Teams-1' | Set-Content $invalid
    $partial=Invoke-ContentTest ContentCsv $p
    Assert-ContentTest ($partial.Status -eq 'REVIEW_REQUIRED' -and $partial.Rows[0].CollectionId) 'Partial write retains created ID and reports review required'
    Assert-ContentTest ((Get-MockOdmState).StartedTaskIds.Count -eq 0) 'No task starts anywhere in the CSV creation flow'
    Select-ContentTestContext SharePoint
    Assert-ContentTest ((Invoke-ContentTest GetState).SafeMode) 'Workload switching resets Safe Mode'
    $bad=Invoke-QOdmOperation ContentInventory @{ObjectKind='Teams'}
    Assert-ContentTest (-not $bad.Success) 'Mismatched object kind rejected'
    Write-Output 'CONTENT WORKLOAD TESTS: PASS'
}
finally {
    $env:QUESTODMCONSOLE_DATA_ROOT=$oldDataRoot
    # Test artifacts remain in the isolated temp directory for failure diagnostics.
    Remove-Module QuestODMConsole.Engine,OdmApi -Force -ErrorAction SilentlyContinue
    Remove-Variable QuestODMConsoleOdmApiPreload -Scope Global -ErrorAction SilentlyContinue
}
