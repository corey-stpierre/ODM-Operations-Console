[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ModuleManifest)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$api=Import-Module $ModuleManifest -Global -Force -PassThru | Where-Object {$_.Name -eq 'OdmApi'}
$engine=Import-Module (Join-Path $root 'Engine\QuestODMConsole.Engine.psm1') -Force -PassThru
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('ODM-ManagementTests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
function Assert-Test {param([bool]$Condition,[string]$Message) if(-not $Condition){throw "MANAGEMENT TEST: $Message"}}
# No authentication. Actual exported Quest commands/types, isolated backend fixtures.
& $api {
    $script:TestWrites=0;$script:TestTemplates=@()
    $script:OdmCurrentProject=[OdmProject]::new();$script:OdmCurrentProject.Id='project'
    $script:OdmCurrentProjectWorkload=[OdmProject]::new();$script:OdmCurrentProjectWorkload.Id='workload'
    $script:TestTask=[OdmTeamsProvisionTask]::new();$script:TestTask.Id='task';$script:TestTask.Name='Original';$script:TestTask.ProjectId='workload';$script:TestTask.Run='later';$script:TestTask.Type='provisionteams';$script:TestTask.Status='New';$script:TestTask.NewTeamSuffix='KEEP'
    $script:TestCollection=[OdmCollection]::new();$script:TestCollection.Id='collection';$script:TestCollection.ProjectId='workload';$script:TestCollection.Name='Original collection'
    function script:Check-ProjectIsSet {param($RequiredProjectType,$RequiredWorkloadType)}
    function script:Get-OdmTaskOrThrow {param($Id,$Project) $script:TestTask}
    function script:Get-OdmCollection {param($FilterObject) $script:TestCollection}
    function script:Get-OdmTaskTemplates {param($TemplateId) $script:TestTemplates|Where-Object {$_.Id -eq $TemplateId}}
    function script:Set-QmmpEntity {param($EntityType,$Entity,$Project,[switch]$PassThru) $script:TestWrites++;if($PassThru){$Entity}}
    function script:New-QmmpEntity {param($EntityType,$Entity,$Project,[switch]$PassThru) $script:TestWrites++;$Entity.Id='template'+$script:TestWrites;$script:TestTemplates+=@($Entity);if($PassThru){$Entity}}
    function script:Invoke-QmmpApi {param($Entity,$SubEntity,$Method,$Body) if($Entity -ne 'events' -or $Method -ne 'PATCH'){throw 'Unexpected backend request'};$script:TestWrites++;$script:EventBody=$Body;[pscustomobject]@{errorsCount=0}}
}
$task=& $api {$script:TestTask};$collection=& $api {$script:TestCollection}
& $engine {
    param($t,$c,$a)
    $script:TestApi=$a;$script:TestTask=$t;$script:TestCollection=$c
    $script:QOdmState.Connected=$true;$script:QOdmState.ContextValid=$true;$script:QOdmState.OrganizationId='org';$script:QOdmState.ProjectId='project';$script:QOdmState.WorkloadId='workload';$script:QOdmState.WorkloadType='Teams';$script:QOdmState.SafeMode=$false
    function script:Update-QOdmTaskCache {$script:QOdmState.Tasks=@{task=$script:TestTask};$script:TestTask}
    function script:Update-QOdmCollectionCache {$script:QOdmState.Collections=@{collection=$script:TestCollection};$script:TestCollection}
    function script:Get-QOdmManagementItems {param($Kind) switch($Kind){'Tasks'{Update-QOdmTaskCache} 'Collections'{Update-QOdmCollectionCache} 'Templates'{& $script:TestApi {$script:TestTemplates}} 'Events'{[pscustomobject]@{Id='event';ProjectId='workload';Message='Synthetic event'}}}}
} $task $collection $api
function Invoke-Update {param([hashtable]$P) & $engine {param($m) Invoke-QOdmOperationsTask @m} $P}
function Invoke-Management {param([hashtable]$P) & $engine {param($m) Invoke-QOdmManagement @m} $P}
$p=@{CommandName='Set-OdmTeamsProvisionTask';Values=@{Task='task';Name='Renamed'};ScopeAcknowledged=$true;OutputDirectory=$testRoot}
$preview=Invoke-Update $p
Assert-Test ((& $api {$script:TestWrites}) -eq 0) 'Update preview makes no write'
$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken
$result=Invoke-Update $p
Assert-Test ($result.Plan.Status -eq 'UPDATED_REVIEW_REQUIRED') ('Native setter runs: '+$result.Plan.Error)
Assert-Test ($task.Name -eq 'Renamed' -and $task.NewTeamSuffix -eq 'KEEP' -and $task.Run -eq 'later') 'Only supplied settings change'
$p.Execute=$false;$p.Values=@{Task='task';ScheduledStartTime='2035-01-01T00:00:00Z'};$preview=Invoke-Update $p
Assert-Test ($preview.Plan.Schedule -like 'AUTOMATIC START*') 'Schedule preview is explicit'
$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$result=Invoke-Update $p
Assert-Test ($result.Plan.Status -eq 'UPDATED_REVIEW_REQUIRED' -and $task.Run -eq 'schedule' -and $task.Schedule.StartTime.Year -eq 2035) 'Native schedule conversion'
$p.Execute=$false;$p.Values.ScheduledStartTime='hold';$preview=Invoke-Update $p;$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$null=Invoke-Update $p
Assert-Test ($task.Run -eq 'later' -and $null -eq $task.Schedule) 'Hold removes schedule'
$p.Execute=$false;$p.Values=@{Task='task';Name='Next'};$preview=Invoke-Update $p;$task.Name='Changed elsewhere';$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken
$blocked=$false;try{$null=Invoke-Update $p}catch{$blocked=$_.Exception.Message -match 'Preview again'};Assert-Test $blocked 'External task changes invalidate preview'
$task.Status='Running';$p.Execute=$false;$blocked=$false;try{$null=Invoke-Update $p}catch{$blocked=$_.Exception.Message -match 'active'};Assert-Test $blocked 'Active tasks cannot be edited';$task.Status='New'
$p.Values=@{Task='task';ScheduledStartTime='2020-01-01T00:00:00Z'};$blocked=$false;try{$null=Invoke-Update $p}catch{$blocked=$_.Exception.Message -match 'future'};Assert-Test $blocked 'Past schedules rejected'
$p.CommandName='Set-OdmTeamsMigrationTask';$p.Values=@{Task='task';Name='x'};$blocked=$false;try{$null=Invoke-Update $p}catch{$blocked=$_.Exception.Message -match 'type mismatch'};Assert-Test $blocked 'Task type mismatch blocked'
$p=@{Action='RenameCollection';Id='collection';Name='Renamed collection';OutputDirectory=$testRoot}
$preview=Invoke-Management $p;$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$result=Invoke-Management $p
Assert-Test ($result.Plan.Status -eq 'VERIFIED' -and $collection.Name -eq 'Renamed collection') ('Collection rename verified: '+$result.Plan.Error)
$blocked=$false;try{$null=Invoke-Management $p}catch{$blocked=$true};Assert-Test $blocked 'Management preview cannot replay'
$p=@{Action='SaveTaskTemplate';Id='task';Name='Pilot template';OutputDirectory=$testRoot};$preview=Invoke-Management $p;$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$result=Invoke-Management $p
Assert-Test ($result.Plan.Status -eq 'SUBMITTED_REVIEW_REQUIRED') ('Template save: '+$result.Plan.Error)
$template=@(& $api {$script:TestTemplates})[0];Assert-Test ($template.Name -eq 'Pilot template' -and $template.Values -match 'KEEP') 'Real Quest template serialization'
$p=@{Action='ExportTemplate';Id=$template.Id;OutputDirectory=$testRoot};$preview=Invoke-Management $p
& $engine {$script:QOdmState.SafeMode=$true};$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$result=Invoke-Management $p
Assert-Test ($result.Plan.Status -eq 'EXPORTED') ('Template export in Safe Mode: '+$result.Plan.Error)
$file=$result.Reports[1];$portable=Get-Content $file -Raw|ConvertFrom-Json;$portable.Name='Imported template';$portable|ConvertTo-Json -Depth 20|Set-Content $file -Encoding UTF8
$p=@{Action='ImportTemplates';FilePath=$file;OutputDirectory=$testRoot};$preview=Invoke-Management $p;$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken
$blocked=$false;try{$null=Invoke-Management $p}catch{$blocked=$_.Exception.Message -match 'Safe Mode'};Assert-Test $blocked 'Template import respects Safe Mode'
& $engine {$script:QOdmState.SafeMode=$false};$result=Invoke-Management $p
Assert-Test ($result.Plan.Status -eq 'SUBMITTED_REVIEW_REQUIRED') ('Real template import: '+$result.Plan.Error)
Assert-Test (@(& $api {$script:TestTemplates}).Count -eq 2) 'Template imported once'
$p.Execute=$false;$blocked=$false;try{$null=Invoke-Management $p}catch{$blocked=$_.Exception.Message -match 'Duplicate'};Assert-Test $blocked 'Duplicate template blocked before writes'
$p=@{Action='AcknowledgeEvent';Id='event';OutputDirectory=$testRoot};$preview=Invoke-Management $p;$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$result=Invoke-Management $p
Assert-Test ($result.Plan.Status -eq 'SUBMITTED_REVIEW_REQUIRED' -and ((& $api {$script:EventBody}|ConvertFrom-Json)._id -eq 'event')) ('Exact event acknowledged: '+$result.Plan.Error)
Write-Output 'MANAGEMENT TESTS: PASS (native update, scheduling, templates, rename and acknowledgement; no service calls)'
