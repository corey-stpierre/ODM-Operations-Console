[CmdletBinding()]param([string]$ModuleManifest)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not $ModuleManifest){$installed=Get-Module -ListAvailable OdmApi | Sort-Object Version -Descending | Select-Object -First 1;if(-not $installed){throw 'Install a supported OdmApi module or pass ModuleManifest. No service access is required.'};$ModuleManifest=$installed.Path}
$api=Import-Module $ModuleManifest -Global -Force -PassThru | Where-Object {$_.Name -eq 'OdmApi'}
$engine=Import-Module (Join-Path $root 'Engine\QuestODMConsole.Engine.psm1') -Force -PassThru
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('ODM-OperationsTests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$env:QUESTODMCONSOLE_DATA_ROOT=$testRoot
function Assert-Operations {param([bool]$Condition,[string]$Message) if(-not $Condition){throw "OPERATIONS TEST: $Message"}}
# Read command metadata only. NO authentication or real Quest service calls.
$count=0;$unavailable=0
foreach($workload in @('Accounts','Teams','SharePoint','PowerBi','PowerPlatform','PublicFolders','HybridExchange')){
    & $engine {param($w) $script:QOdmState.Connected=$true;$script:QOdmState.ContextValid=$true;$script:QOdmState.OrganizationId='org';$script:QOdmState.ProjectId='project';$script:QOdmState.WorkloadId='workload';$script:QOdmState.WorkloadType=$w} $workload
    $catalog=& $engine {Get-QOdmOperationsCatalog}
    foreach($item in $catalog){
        if(-not $item.Available){
            $unavailable++
            $blocked=$false;try{& $engine {param($c) Get-QOdmOperationsDefinition $c} $item.Command|Out-Null}catch{$blocked=$true}
            Assert-Operations $blocked "Unavailable contract must be blocked: $($item.Command)"
            if($api.Version -eq [version]'2.1.401'){Assert-Operations ($item.Command -in @('New-OdmAddressRewritingTask','New-OdmSPMapListTask','New-OdmSPMapSiteTask','New-OdmSPMapWebTask','New-OdmSPRemoveSharePointObjectsTask')) "Unexpected missing .401 contract: $($item.Command)"}
            continue
        }
        $definition=& $engine {param($c) Get-QOdmOperationsDefinition $c} $item.Command
        Assert-Operations ($definition.Fields.Count -gt 0) "Fields missing: $($item.Command)"
        if($definition.Mode -eq 'Create'){Assert-Operations (-not @($definition.Fields | Where-Object {$_.Name -eq 'ScheduledStartTime'}).Count) 'Creation must remain held'}
        foreach($field in $definition.Fields){
            if($field.Kind -eq 'Choice'){
                foreach($choice in $field.Choices){
                    $null=& $engine {param($c,$n,$v) ConvertTo-QOdmOperationsValue -Metadata (Get-QOdmOperationsCommand $c).Parameters[$n] -Value $v} $item.Command $field.Name $choice
                }
            }
        }
        $count++
    }
}
# Replace only the selected vendor command and read helpers in their module scopes.
# The production dispatcher, validation, preview, write gates and reporting remain real.
& $api {
    $script:OpsTestWrites=0
    $script:OdmCurrentProject=[pscustomobject]@{Id='workload'}
    function script:Check-ProjectIsSet {param($RequiredProjectType,$RequiredWorkloadType)}
    function script:Get-OdmProjectWorkload {param($Type,$ProjectWorkloadId) [pscustomobject]@{Id='workload'}}
    function script:Get-NewPbiTaskCommonProperties {param($TaskType,$Category,$StartTime,$Name,$Workload) @{Name=$Name;ProjectId='workload';Run='later';Type=$TaskType}}
    function script:New-QmmpEntity {
        [CmdletBinding()]param($EntityType,$Entity,$Project,[switch]$PassThru)
        $script:OpsTestWrites++
        if($Entity.Name -eq 'timeout'){throw 'Synthetic timeout after a possible write'}
        [pscustomobject]@{Id='created-task';Name=$Entity.Name;ProjectId='workload';Run=$Entity.Run}
    }
}
& $engine {
    $script:QOdmState.WorkloadType='PowerBi';$script:QOdmState.SafeMode=$true
    function script:Update-QOdmTaskCache { @() }
}
function Invoke-Ops {param([hashtable]$P) & $engine {param($argsMap) Invoke-QOdmOperationsTask @argsMap} $P}
$p=@{CommandName='New-OdmPbiTestPowerBIConnectionTask';Values=@{Name='Synthetic task'};ScopeAcknowledged=$true;OutputDirectory=$testRoot}
$preview=Invoke-Ops $p
Assert-Operations ($preview.Plan.Status -eq 'PREVIEW' -and $preview.PreviewToken) 'Preview returns token'
Assert-Operations ((& $api {$script:OpsTestWrites}) -eq 0) 'Preview does not write'
$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken
$blocked=$false;try{Invoke-Ops $p|Out-Null}catch{$blocked=$_.Exception.Message -match 'Safe Mode'}
Assert-Operations $blocked 'Safe Mode blocks execute'
& $engine {$script:QOdmState.SafeMode=$false}
$p.Values.Name='Changed task'
$blocked=$false;try{Invoke-Ops $p|Out-Null}catch{$blocked=$_.Exception.Message -match 'Preview again'}
Assert-Operations $blocked 'Editing settings invalidates preview'
$p.Execute=$false;$preview=Invoke-Ops $p;$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken
$created=Invoke-Ops $p
Assert-Operations ($created.Plan.Status -eq 'CREATED_HELD' -and $created.Plan.TaskId -eq 'created-task') 'Creates a held task with ID'
$blocked=$false;try{Invoke-Ops $p|Out-Null}catch{$blocked=$_.Exception.Message -match 'Preview again'}
Assert-Operations $blocked 'Preview cannot execute twice'
Assert-Operations ((& $api {$script:OpsTestWrites}) -eq 1) 'No duplicate creation'
$p.Execute=$false;$p.Values.Name='timeout';$preview=Invoke-Ops $p;$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken
$failed=Invoke-Ops $p
Assert-Operations ($failed.Plan.Status -eq 'REVIEW_REQUIRED' -and (Test-Path $failed.Reports[0])) 'Ambiguous write persists review report'
Assert-Operations ((& $api {$script:OpsTestWrites}) -eq 2) 'Timeout is not retried'
$p.Execute=$false;$p.CommandName='Remove-OdmTask'
$blocked=$false;try{Invoke-Ops $p|Out-Null}catch{$blocked=$true}
Assert-Operations $blocked 'Arbitrary commands rejected'
$p.CommandName='New-OdmPbiTestPowerBIConnectionTask';$p.Values=@{Name='x';ScheduledStartTime='2030-01-01T00:00:00Z'}
$blocked=$false;try{Invoke-Ops $p|Out-Null}catch{$blocked=$true}
Assert-Operations $blocked 'Reserved schedule rejected'
& $engine {$script:QOdmState.WorkloadType='Teams'}
$p.Values=@{Name='x'};$blocked=$false;try{Invoke-Ops $p|Out-Null}catch{$blocked=$true}
Assert-Operations $blocked 'Wrong workload rejected'
# Parser behavior on malformed CSVs and quoted multiline values.
foreach($text in @('A,A' + "`n1,2", 'A,B'+"`n1,2,3", 'A,B'+"`n1", 'A,'+"`n1,2", 'A,B')){
    $path=Join-Path $testRoot 'invalid.csv';[IO.File]::WriteAllText($path,$text)
    $blocked=$false;try{& $engine {param($f) Import-QOdmCsv $f} $path|Out-Null}catch{$blocked=$true}
    Assert-Operations $blocked 'Malformed CSV must be rejected'
}
$path=Join-Path $testRoot 'valid.csv';[IO.File]::WriteAllText($path,"Name,Value`n`"Team, One`",`"line1`nline2`"")
$rows=@(& $engine {param($f) Import-QOdmCsv $f} $path)
Assert-Operations ($rows.Count -eq 1 -and $rows[0].Name -eq 'Team, One' -and $rows[0].Value -match "line1\r?\nline2") 'Quoted CSV commas and newlines retained'
# Preview expiry, context changes, secrets and changed native file contents.
& $engine {$script:QOdmState.WorkloadType='PowerBi'}
$p=@{CommandName='New-OdmPbiTestPowerBIConnectionTask';Values=@{Name='Expiry test'};ScopeAcknowledged=$true;OutputDirectory=$testRoot}
$preview=Invoke-Ops $p;& $engine {$script:QOdmOperationsPreview.At=[DateTime]::UtcNow.AddMinutes(-16)}
$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$blocked=$false;try{$null=Invoke-Ops $p}catch{$blocked=$_.Exception.Message -match 'Preview again'}
Assert-Operations $blocked 'Expired preview is rejected'
$p.Execute=$false;$preview=Invoke-Ops $p;& $engine {$script:QOdmState.WorkloadId='changed'}
$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$blocked=$false;try{$null=Invoke-Ops $p}catch{$blocked=$_.Exception.Message -match 'Preview again'}
Assert-Operations $blocked 'Changed workload rejects old preview';& $engine {$script:QOdmState.WorkloadId='workload'}
$p=@{CommandName='New-OdmPbiCreateNewConnectionProfileTask';Values=@{Name='Secret test';ProfileName='Synthetic profile';UserName='test@example.test';Password='synthetic-sensitive-value'};ScopeAcknowledged=$true;OutputDirectory=$testRoot}
$preview=Invoke-Ops $p
Assert-Operations ((Get-Content $preview.Reports[0] -Raw) -notmatch 'synthetic-sensitive-value') 'Password absent from preview file'
$clean=& $engine {ConvertTo-QOdmSanitizedValue ([pscustomobject]@{Values='{"password":"embedded-sensitive-value","name":"sample"}'})}
Assert-Operations (($clean|ConvertTo-Json) -notmatch 'embedded-sensitive-value') 'Embedded template JSON is sanitized'
$path=Join-Path $testRoot 'workspaces.csv';[IO.File]::WriteAllText($path,"Source Workspace Name,Target Workspace Name`nSource,Target")
$p=@{CommandName='New-OdmPbiMapWorkspacesFromFileTask';Values=@{Name='File change';FilePath=$path};ScopeAcknowledged=$true;OutputDirectory=$testRoot};$preview=Invoke-Ops $p
[IO.File]::WriteAllText($path,"Source Workspace Name,Target Workspace Name`nSource,Different")
$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$blocked=$false;try{$null=Invoke-Ops $p}catch{$blocked=$_.Exception.Message -match 'Preview again'}
Assert-Operations $blocked 'File contents are bound to preview'
# A future module must not prompt the worker for an unknown mandatory parameter.
$available=& $engine {
    $script:ContractProbe=(Get-QOdmOperationsCommand 'New-OdmPbiTestPowerBIConnectionTask').Parameters
    $extra=[Management.Automation.ParameterMetadata]::new('UnexpectedRequired',[string]);$attribute=[Management.Automation.ParameterAttribute]::new();$attribute.Mandatory=$true;$extra.Attributes.Add($attribute);$script:ContractProbe.Add('UnexpectedRequired',$extra)
    function script:Get-QOdmOperationsCommand {param($Name) if($Name -eq 'New-OdmPbiTestPowerBIConnectionTask'){return [pscustomobject]@{Parameters=$script:ContractProbe}};return (Get-QOdmLoadedApiModule).ExportedCommands[$Name]}
    (Get-QOdmOperationsCatalog|Where-Object Command -eq 'New-OdmPbiTestPowerBIConnectionTask').Available
}
Assert-Operations (-not $available) 'New mandatory vendor parameters fail closed'
Write-Output "OPERATIONS CENTER TESTS: PASS ($count available workload-command contracts; $unavailable blocked; module $($api.Version); no service calls)"
