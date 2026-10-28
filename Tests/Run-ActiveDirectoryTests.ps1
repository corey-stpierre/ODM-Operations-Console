[CmdletBinding()]param([string]$ModuleManifest)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not $ModuleManifest){$ModuleManifest=(Get-Module -ListAvailable OdmApi|Sort-Object Version -Descending|Select-Object -First 1).Path}
$api=Import-Module $ModuleManifest -Force -Global -PassThru|Where-Object {$_.Name -eq 'OdmApi'}
$engine=Import-Module (Join-Path $root 'Engine\QuestODMConsole.Engine.psm1') -Force -PassThru
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('ODM-AdTests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$env:QUESTODMCONSOLE_DATA_ROOT=$testRoot
function Assert-Ad {param($Condition,[string]$Message) if(-not $Condition){throw "AD TEST: $Message"}}
function Assert-AdThrows {param([scriptblock]$Code,[string]$Pattern) $thrown=$false;try{& $Code|Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw "Unexpected error (expected $Pattern): $($_.Exception.Message)"};$thrown=$true};Assert-Ad $thrown "Expected failure: $Pattern"}
& $engine {
    $script:QOdmState.Connected=$true;$script:QOdmState.OrganizationId='11111111-1111-1111-1111-111111111111';$script:QOdmState.OrganizationName='Synthetic AD pilot';$script:QOdmState.Region='US'
    $script:QOdmState.ProjectId='old-project';$script:QOdmState.WorkloadId='old-workload'
}
$opened=& $engine {Open-QOdmActiveDirectory}
Assert-Ad ($opened.State.ContextMode -eq 'ActiveDirectory' -and -not $opened.State.ProjectId -and -not $opened.State.WorkloadId -and $opened.State.SafeMode) 'Opening AD clears M365 context and resets Safe Mode'
Assert-AdThrows {& $engine {Assert-QOdmWorkloadSelected}} 'Microsoft 365'
$available=@($opened.Catalog.Operations|Where-Object {$_.Available});$reads=@($opened.Catalog.Inventories|Where-Object {$_.Available})
if($api.Version -eq [version]'2.1.401'){Assert-Ad ($available.Count -eq 20 -and $reads.Count -eq 27) 'Full inspected .401 command surface'}
foreach($entry in $available){
    $definition=& $engine {param($name) Get-QOdmAdDefinition $name} $entry.Command
    Assert-Ad ($definition.Command -eq $entry.Command) 'Definition resolves'
    foreach($field in $definition.Fields){Assert-Ad ($field.Description.Length -gt 0) "Field guidance exists: $($field.Name)"}
}
# Compiled cmdlets are NOT invoked. Only the single service-call boundary is mocked.
# Everything above/below it (catalog, conversion, context, validation, preview and journal) is production code.
& $engine {
    $script:AdTestWrites=0;$script:AdTestCalls=@();$script:AdTestFailAt=0;$script:AdTestSsErrors=$false;$script:AdTestWrongId=$false;$script:AdTestProfile=1
    function script:Invoke-QOdmAdNative {
        param([string]$CommandName,[Collections.IDictionary]$Parameters)
        Assert-QOdmAdContext
        $script:AdTestCalls+=@([pscustomobject]@{Name=$CommandName;Parameters=$Parameters})
        if($CommandName -like 'Get-*'){
            $spec=@((Get-QOdmAdCatalog).Inventories|Where-Object {$_.Command -eq $CommandName})[0]
            $id=if($Parameters.Contains($spec.IdentityParameter)){[string]$Parameters[$spec.IdentityParameter]}else{'1'}
            if($script:AdTestWrongId){$id='999'}
            if($id -eq '404'){return}
            if($spec.Kind -eq 'Devices'){
                # Real SDK output model catches its integer DeviceId and non-Id identity shape.
                $type=(Get-QOdmOperationsCommand 'Get-OdmAdDevice').OutputType[0].Type
                $device=[Activator]::CreateInstance($type);$device.DeviceId=[int]$id;$device.EnvironmentId=7;$device.SAMAccountName='AD-PILOT-'+$id;$device.ReACLProfileId=$script:AdTestProfile
                $device.AgentKey=[guid]'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';$device.ServiceKey=[guid]'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                return $device
            }
            if($spec.Kind -like 'SelfService*'){
                $type=(Get-QOdmOperationsCommand $CommandName).OutputType[0].Type
                $model=[Activator]::CreateInstance($type)
                $model.Id=[Quest.ODMAD.SDK.Graphql.GraphqlGlobalId]::new($id,'Device')
                return $model
            }
            $row=[ordered]@{Name='Synthetic '+$spec.Kind;EnvironmentId=7;AuthKey='synthetic-auth-key';SourcePassword='synthetic-password';Value='synthetic-variable-value'}
            if($spec.IdentityProperty){$row[$spec.IdentityProperty]=$id}
            [pscustomobject]$row;return
        }
        $script:AdTestWrites++
        # Verify real installed parameter types, without binding to or invoking service code.
        $cmd=Get-QOdmOperationsCommand $CommandName
        foreach($key in $Parameters.Keys){$null=[Management.Automation.LanguagePrimitives]::ConvertTo($Parameters[$key],$cmd.Parameters[$key].ParameterType)}
        if($script:AdTestFailAt -eq $script:AdTestWrites){throw 'Synthetic ambiguous transport error'}
        if($CommandName -match '-ODMSS'){
            return [pscustomobject]@{TotalUpdatedCount=1;Errors=@($(if($script:AdTestSsErrors){'Synthetic service error'}));TotalFilteredCount=1}
        }
        [pscustomobject]@{DeviceJobId=500+$script:AdTestWrites;Status='Queued';AuthKey='synthetic-auth-key'}
    }
}
function Invoke-Ad {param([hashtable]$P) & $engine {param($a) Invoke-QOdmAdAction @a} $P}
$inventory=& $engine {Get-QOdmAdInventoryView -Kind Devices -Limit 5}
Assert-Ad ($inventory.Rows[0].TargetId -eq '1' -and $inventory.Note -match 'bounded') 'Device identity and bounded query note'
$details=$inventory.Rows[0].Details
Assert-Ad ($details -notmatch 'aaaaaaaa|bbbbbbbb') 'Real device AgentKey and ServiceKey redacted'
$secrets=& $engine {ConvertTo-QOdmAdSnapshot ([pscustomobject]@{AuthKey='synthetic-auth-key';Password='synthetic-password';Value='synthetic-variable-value';Name='retained';Child=[pscustomobject]@{Password='secret'}})|ConvertTo-Json}
Assert-Ad ($secrets -notmatch 'synthetic-|"Child"' -and $secrets -match 'retained') 'Secrets and nested SDK objects excluded'
Assert-AdThrows {& $engine {Get-QOdmAdInventoryView -Kind DeviceJobs}} 'requires'
$null=& $engine {Get-QOdmAdInventoryView -Kind DeviceJobs -ParentId 1}
Assert-Ad ((& $engine {$script:AdTestCalls[-1].Parameters.Device.DeviceId}) -eq 1) 'Device jobs use resolved parent model'
$null=& $engine {Get-QOdmAdInventoryView -Kind WorkflowLogs -ParentId 1}
Assert-AdThrows {& $engine {Get-QOdmAdInventoryView -Kind Devices -Id 1 -Filter 'Name eq x'}} 'alone'
Assert-AdThrows {& $engine {Get-QOdmAdInventoryView -Kind Devices -Limit 0}} 'range|greater|validate'
# Pure identity conversion methods from the compiled vendor module, no ProcessRecord/service execution.
$deviceCmdlet=[Activator]::CreateInstance($api.ExportedCommands['Get-ODMSSDevice'].ImplementingType)
$identityMethod=$deviceCmdlet.GetType().GetMethod('GetSSDeviceIdentity',[Reflection.BindingFlags]'Instance,NonPublic,Public')
$opaque='RGV2aWNlOjEyMw=='
Assert-Ad ($identityMethod.Invoke($deviceCmdlet,[object[]]@($opaque)) -ceq $opaque) 'Vendor pure identity helper preserves exported self-service ID'
$ssView=& $engine {Get-QOdmAdInventoryView -Kind SelfServiceDevices -Id 'RGV2aWNlOjEyMw=='}
Assert-Ad ($ssView.Rows[0].TargetId -ceq $opaque) 'Real SDK GraphqlGlobalId round-trips exactly'
$readiness=& $engine {param($out) Invoke-QOdmReadinessCheck -OutputDirectory $out} $testRoot
Assert-Ad (@($readiness.Checks|Where-Object {$_.Name -eq 'AD pilot prerequisites' -and $_.Status -eq 'WARNING'}).Count -eq 1) 'AD readiness explicitly leaves tenant prerequisites unverified'
Assert-Ad (@($readiness.Checks|Where-Object {$_.Name -eq 'Active migration subscription' -and $_.Status -eq 'NOT APPLICABLE'}).Count -eq 1) 'AD readiness does not query the M365 subscription API'
Assert-Ad ($readiness.ContextDisplay -match 'Active Directory') 'Readiness reports correct context'
foreach($read in $reads){
    $argsMap=@{Kind=$read.Kind;Limit=5};if($read.ParentKind){$argsMap.ParentId='1'}
    $view=& $engine {param($a) Get-QOdmAdInventoryView @a} $argsMap
    Assert-Ad ($view.Rows.Count -eq 1) "Inventory/cardinality and snapshot: $($read.Kind)"
    Assert-Ad (($view.Rows|ConvertTo-Json -Depth 5) -notmatch 'synthetic-auth-key|synthetic-password|synthetic-variable-value') "Inventory redaction: $($read.Kind)"
}
Assert-Ad ((& $engine {@($script:AdTestCalls|Where-Object {$_.Parameters.Contains('AsPlainText')}).Count}) -eq 0) 'No inventory requests plaintext credentials'
$p=@{CommandName='Start-OdmAdDeviceDiscovery';TargetIds='1,2';OutputDirectory=$testRoot}
$preview=Invoke-Ad $p
Assert-Ad ($preview.Plan.Status -eq 'PREVIEW' -and $preview.Plan.Targets.Count -eq 2 -and $preview.PreviewToken) 'Preview explicit batch'
Assert-Ad ((& $engine {$script:AdTestWrites}) -eq 0) 'All reads and preview have no writes'
$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$p.Acknowledged=$true;$p.ConfirmationText='APPLY AD ACTION'
Assert-AdThrows {Invoke-Ad $p} 'Safe Mode'
$null=& $engine {Disable-QOdmSafeMode -OrganizationId $script:QOdmState.OrganizationId -ProjectId '' -WorkloadId '' -ConfirmationText 'ENABLE CHANGES'}
Assert-AdThrows {& $engine {Assert-QOdmWriteAllowed Membership}} 'Microsoft 365'
$p.ConfirmationText='apply ad action';Assert-AdThrows {Invoke-Ad $p} 'exactly';$p.ConfirmationText='APPLY AD ACTION'
$p.Values=@{DoNotStartBefore='invalid'};Assert-AdThrows {Invoke-Ad $p} 'ISO';$p.Values=@{}
$p.TargetIds='1,3';Assert-AdThrows {Invoke-Ad $p} 'Preview again';$p.TargetIds='1,2'
& $engine {$script:AdTestProfile=2};Assert-AdThrows {Invoke-Ad $p} 'Preview again';& $engine {$script:AdTestProfile=1}
$p.Execute=$false;$preview=Invoke-Ad $p;$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken
$result=Invoke-Ad $p
Assert-Ad ($result.Plan.Status -eq 'SUBMITTED_REVIEW_REQUIRED' -and (& $engine {$script:AdTestWrites}) -eq 2) 'Explicit batch submits once per target'
Assert-Ad ((Get-Content $result.Reports[0] -Raw|ConvertFrom-Json).Targets[1].Status -eq 'SUBMITTED_REVIEW_REQUIRED') 'Final journal persists'
Assert-AdThrows {Invoke-Ad $p} 'Preview again'
$p.Execute=$false;$p.TargetIds='1,1';Assert-AdThrows {Invoke-Ad $p} 'Duplicate'
$p.TargetIds='404';Assert-AdThrows {Invoke-Ad $p} 'resolve'
$p.TargetIds='1';& $engine {$script:AdTestWrongId=$true};Assert-AdThrows {Invoke-Ad $p} 'resolve';& $engine {$script:AdTestWrongId=$false}
$p.TargetIds='1,2,3';$preview=Invoke-Ad $p;$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken
& $engine {$script:AdTestFailAt=$script:AdTestWrites+2}
$result=Invoke-Ad $p
Assert-Ad ($result.Plan.Status -eq 'REVIEW_REQUIRED' -and $result.Plan.Targets[0].Status -eq 'SUBMITTED_REVIEW_REQUIRED' -and $result.Plan.Targets[1].Status -eq 'REVIEW_REQUIRED' -and $result.Plan.Targets[2].Status -eq 'NOT_SUBMITTED') 'Partial/uncertain failure stops remaining batch'
& $engine {$script:AdTestFailAt=0}
# Exercise every installed action and all reviewed fields using metadata-derived choices.
foreach($entry in $available){
    $values=@{}
    foreach($field in $entry.Parameters){
        $type=$api.ExportedCommands[$entry.Command].Parameters[$field.Name].ParameterType;$underlying=[Nullable]::GetUnderlyingType($type);if($underlying){$type=$underlying}
        $values[$field.Name]=if($field.ReferenceKind){'1'}elseif($type -eq [bool] -or $type -eq [Management.Automation.SwitchParameter]){'false'}elseif($type.IsEnum){[Enum]::GetNames($type)[0]}elseif($type -eq [int]){'1'}elseif($type -eq [guid]){'11111111-2222-3333-4444-555555555555'}elseif($type -eq [datetime] -or $type -eq [datetimeoffset]){[datetimeoffset]::UtcNow.AddDays(2).ToString('o')}elseif($type -eq [string[]]){"C:\Test,Comma`nC:\Other"}else{'Synthetic pilot setting'}
    }
    $argsMap=@{CommandName=$entry.Command;Values=$values;TargetIds=if($entry.TargetKind -like 'SelfService*'){'RGV2aWNlOjEyMw=='}else{'1'};OutputDirectory=$testRoot}
    $preview=Invoke-Ad $argsMap
    $argsMap.Execute=$true;$argsMap.PreviewToken=$preview.PreviewToken;$argsMap.Acknowledged=$true;$argsMap.ConfirmationText='APPLY AD ACTION'
    $result=Invoke-Ad $argsMap
    Assert-Ad ($result.Plan.Status -eq 'SUBMITTED_REVIEW_REQUIRED') "Reviewed action parameter conversion and dispatch: $($entry.Command)"
}
$p=@{CommandName='Start-ODMSSDeviceMigrateNow';TargetIds='RGV2aWNlOjEyMw==';OutputDirectory=$testRoot}
$preview=Invoke-Ad $p;$p.Execute=$true;$p.Acknowledged=$true;$p.ConfirmationText='APPLY AD ACTION';$p.PreviewToken=$preview.PreviewToken
& $engine {$script:AdTestSsErrors=$true}
$result=Invoke-Ad $p
Assert-Ad ($result.Plan.Status -eq 'REVIEW_REQUIRED') 'Self-service Errors cannot report success'
& $engine {$script:AdTestSsErrors=$false}
$csv=Join-Path $testRoot 'targets.csv'
"OrganizationId,TargetId,EnvironmentId`n11111111-1111-1111-1111-111111111111,1,7"|Set-Content -LiteralPath $csv -Encoding UTF8
$p=@{CommandName='Start-OdmAdDeviceDiscovery';CsvPath=$csv;OutputDirectory=$testRoot}
$preview=Invoke-Ad $p
$p.Execute=$true;$p.Acknowledged=$true;$p.ConfirmationText='APPLY AD ACTION';$p.PreviewToken=$preview.PreviewToken
"OrganizationId,TargetId,EnvironmentId`n11111111-1111-1111-1111-111111111111,2,7"|Set-Content -LiteralPath $csv -Encoding UTF8
Assert-AdThrows {Invoke-Ad $p} 'Preview again'
$p.Execute=$false
"OrganizationId,TargetId,EnvironmentIdTypo`n11111111-1111-1111-1111-111111111111,1,7"|Set-Content -LiteralPath $csv -Encoding UTF8
Assert-AdThrows {Invoke-Ad $p} 'Unsupported AD CSV column'
"OrganizationId,TargetId,EnvironmentId`nwrong-org,1,7"|Set-Content -LiteralPath $csv -Encoding UTF8
Assert-AdThrows {Invoke-Ad $p} 'organization'
"OrganizationId,TargetId,EnvironmentId`n11111111-1111-1111-1111-111111111111,1,8"|Set-Content -LiteralPath $csv -Encoding UTF8
Assert-AdThrows {Invoke-Ad $p} 'Environment mismatch'
$p=@{CommandName='Start-OdmAdDeviceDiscovery';TargetIds='1';Values=@{DoNotStartBefore='2020-01-01T00:00:00Z'};OutputDirectory=$testRoot}
Assert-AdThrows {Invoke-Ad $p} 'ISO'
$p.Values=@{IgnoreMadeUp='true'};Assert-AdThrows {Invoke-Ad $p} 'Unsupported field'
$p.Values=@{};$preview=Invoke-Ad $p
& $engine {$script:QOdmAdPreview.At=[datetime]::UtcNow.AddMinutes(-16)}
$p.Execute=$true;$p.PreviewToken=$preview.PreviewToken;$p.Acknowledged=$true;$p.ConfirmationText='APPLY AD ACTION'
Assert-AdThrows {Invoke-Ad $p} 'Preview again'
$null=& $engine {Open-QOdmActiveDirectory}
Assert-Ad ((& $engine {$script:QOdmState.SafeMode -and -not $script:QOdmAdPreview})) 'Reopen invalidates prior write authorization and preview'
$null=& $engine {Clear-QOdmSessionContext -PreserveConnection $true}
Assert-AdThrows {& $engine {Get-QOdmAdInventoryView}} 'organization|workspace'
Write-Output "AD command contracts: $($available.Count) actions, $($reads.Count) inventories; no authentication or service calls."
Write-Output 'ACTIVE DIRECTORY TESTS: PASS'
