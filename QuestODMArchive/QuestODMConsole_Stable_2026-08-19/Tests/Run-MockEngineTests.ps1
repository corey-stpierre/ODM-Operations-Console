[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appRoot = Split-Path -Parent $testsRoot
$mockRoot = Join-Path $testsRoot 'Mocks'
$mockManifest = Join-Path $mockRoot 'OdmApi\2.1.396\OdmApi.psd1'
$enginePath = Join-Path $appRoot 'Engine\QuestODMConsole.Engine.psm1'
$oldModulePath = $env:PSModulePath
$env:PSModulePath = "$mockRoot$([IO.Path]::PathSeparator)$oldModulePath"


function ConvertTo-TestObjectArray {
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

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
function Invoke-TestOperation {
    param([string]$Operation,[hashtable]$Parameters=@{})
    $result=Invoke-QOdmOperation -Operation $Operation -Parameters $Parameters
    if(-not $result.Success){throw "Operation '$Operation' failed: $($result.Error)`r`n$($result.Details)"}
    $result
}
function Get-DiscoveryAttempt {
    param([Parameter(Mandatory=$true)][object]$Discovery,[Parameter(Mandatory=$true)][string]$Command)
    return (ConvertTo-TestObjectArray -InputObject ((ConvertTo-TestObjectArray -InputObject $Discovery.Attempts) | Where-Object { $_.Command -eq $Command } | Select-Object -First 1))
}
function Reconnect-WithOrganizationMode {
    param([Parameter(Mandatory=$true)][string]$Mode)
    $null=Invoke-TestOperation -Operation Disconnect
    Set-MockOrganizationMode -Mode $Mode
    return (Invoke-TestOperation -Operation Connect -Parameters @{Region='US'})
}

function Enable-TestChanges {
    param(
        [string]$OrganizationId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        [string]$ProjectId='project-001',
        [string]$WorkloadId='workload-accounts'
    )
    $result = Invoke-TestOperation -Operation SetSafeMode -Parameters @{
        Enabled=$false; OrganizationId=$OrganizationId; ProjectId=$ProjectId; WorkloadId=$WorkloadId; ConfirmationText='ENABLE CHANGES'
    }
    Assert-True (-not [bool]$result.Data.Enabled) 'Safe Mode must be disabled for test write operations.'
    return $result
}

$temp=$null
try {
    Remove-Module QuestODMConsole.Engine -Force -ErrorAction SilentlyContinue
    Remove-Module OdmApi -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name QuestODMConsoleOdmApiPreload -Scope Global -ErrorAction SilentlyContinue

    $imported=ConvertTo-TestObjectArray -InputObject (Import-Module -Name $mockManifest -Global -PassThru -ErrorAction Stop)
    $mockCandidates=ConvertTo-TestObjectArray -InputObject ($imported|Where-Object{$_.Name -eq 'OdmApi'}|Sort-Object Version -Descending)
    $mockModule=if($mockCandidates.Count -gt 0){$mockCandidates[0]}else{$null}
    if($null -eq $mockModule){throw 'The mock OdmApi module did not import globally.'}
    $global:QuestODMConsoleOdmApiPreload=[pscustomobject]@{
        Status='LOADED';Installed=$true;Loaded=$true;Version=[string]$mockModule.Version;Path=[string]$mockModule.Path
        ManifestPath=$mockManifest;CommandOwner='OdmApi';Details='Mock OdmApi globally preloaded by regression test.';Error=$null;PreloadedAt=Get-Date
    }
    Import-Module $enginePath -Force -ErrorAction Stop

    Assert-True ($null -eq (Get-Command Set-ModuleVersion -ErrorAction SilentlyContinue)) 'Set-ModuleVersion must remain private.'

    # Zero/one/many cardinality and scalar-preservation regression coverage.
    $emptyList = New-Object System.Collections.Generic.List[object]
    $oneList = New-Object System.Collections.Generic.List[object]
    $oneList.Add([pscustomobject]@{ Id='only' }) | Out-Null
    $manyList = New-Object System.Collections.Generic.List[object]
    $manyList.Add([pscustomobject]@{ Id='first' }) | Out-Null
    $manyList.Add([pscustomobject]@{ Id='second' }) | Out-Null
    Assert-True ((ConvertTo-TestObjectArray -InputObject $emptyList).Count -eq 0) 'An empty New-Object List[object] must normalize to an empty object array.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject $oneList).Count -eq 1) 'A one-item New-Object List[object] must preserve one item.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject $manyList).Count -eq 2) 'A multi-item New-Object List[object] must preserve every item.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject 'literal').Count -eq 1) 'A string must remain a scalar collection item.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject @{ Key='Value' }).Count -eq 1) 'A dictionary must remain a scalar collection item.'

    # Rich organization objects use the exact current OdmApi property names.
    Set-MockOrganizationMode -Mode Rich
    $connect=Invoke-TestOperation -Operation Connect -Parameters @{Region='US'}
    Assert-True ($connect.Data.State.ModuleScopeValidated) 'The actual private OdmApi module-version initializer must pass.'
    Assert-True ($connect.Data.State.ModuleRuntimeProbeStatus -eq 'PASS') 'Runtime probe status must be PASS.'
    Assert-True ($connect.Data.State.ModulePreloadStatus -eq 'LOADED') 'Worker preload status must be preserved.'
    $richOrganizations=ConvertTo-TestObjectArray -InputObject $connect.Data.Organizations
    Assert-True ($richOrganizations.Count -eq 2) 'Two rich mock organizations should be returned.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($richOrganizations|Where-Object{$_.Name -eq 'Mock Primary Organization'})).Count -eq 1) 'OrganizationDisplayName must populate the friendly organization name.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($richOrganizations|Where-Object{$_.DisplayText -match 'Mock Primary Organization'})).Count -eq 1) 'The organization display text must include the friendly name.'
    $richPrimary=ConvertTo-TestObjectArray -InputObject (Get-DiscoveryAttempt -Discovery $connect.Data.OrganizationDiscovery -Command 'Get-OdmOrganizations')
    $richFallback=ConvertTo-TestObjectArray -InputObject (Get-DiscoveryAttempt -Discovery $connect.Data.OrganizationDiscovery -Command 'Get-OdmActiveOrganizations')
    Assert-True ($richPrimary.Count -eq 1 -and $richPrimary[0].Succeeded -and $richPrimary[0].ConvertedCount -eq 2) 'Rich organization discovery must convert both typed organization objects.'
    Assert-True ($richFallback.Count -eq 1 -and $richFallback[0].Succeeded) 'The active-organization fallback command must also be assessed and merged safely.'
    $mockState=Get-MockOdmState
    Assert-True ($mockState.ModuleName -eq 'OdmApi') 'Private Set-ModuleVersion must resolve OdmApi by its own module name.'
    Assert-True ($mockState.IntegratedAuthConnectCount -eq 0) 'The console must use interactive authentication and must not submit integrated Windows authentication.'

    # Primary command returns no results; active IDs must still populate the list.
    $fallbackEmpty=Reconnect-WithOrganizationMode -Mode PrimaryEmpty
    Assert-True ((ConvertTo-TestObjectArray -InputObject $fallbackEmpty.Data.Organizations).Count -eq 2) 'Active organization IDs must populate the list when the rich command returns no rows.'
    $emptyPrimary=ConvertTo-TestObjectArray -InputObject (Get-DiscoveryAttempt -Discovery $fallbackEmpty.Data.OrganizationDiscovery -Command 'Get-OdmOrganizations')
    Assert-True ($emptyPrimary.Count -eq 1 -and $emptyPrimary[0].Succeeded -and $emptyPrimary[0].RawCount -eq 0) 'An empty rich response must be recorded without blocking fallback discovery.'

    # Primary command fails; active IDs must still populate the list and preserve diagnostics.
    $fallbackError=Reconnect-WithOrganizationMode -Mode PrimaryError
    Assert-True ((ConvertTo-TestObjectArray -InputObject $fallbackError.Data.Organizations).Count -eq 2) 'Active organization IDs must populate the list when rich discovery fails.'
    $errorPrimary=ConvertTo-TestObjectArray -InputObject (Get-DiscoveryAttempt -Discovery $fallbackError.Data.OrganizationDiscovery -Command 'Get-OdmOrganizations')
    Assert-True ($errorPrimary.Count -eq 1 -and -not $errorPrimary[0].Succeeded -and -not [string]::IsNullOrWhiteSpace([string]$errorPrimary[0].Error)) 'Primary discovery failure details must be retained.'

    # Wrapped list output must be unwrapped.
    $wrapped=Reconnect-WithOrganizationMode -Mode Wrapped
    Assert-True ((ConvertTo-TestObjectArray -InputObject $wrapped.Data.Organizations).Count -eq 2) 'Wrapped Organizations payloads must be expanded.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($wrapped.Data.Organizations|Where-Object{$_.Name -eq 'Mock Secondary Organization'})).Count -eq 1) 'Wrapped organization friendly names must survive conversion.'

    foreach($envelopeMode in @('WrappedItems','WrappedValue','WrappedResults','WrappedData')){
        $enveloped=Reconnect-WithOrganizationMode -Mode $envelopeMode
        Assert-True ((ConvertTo-TestObjectArray -InputObject $enveloped.Data.Organizations).Count -eq 2) "$envelopeMode organization envelopes must be expanded."
    }

    # Duplicate and invalid rich entries must be de-duplicated/ignored while fallback fills gaps.
    $deduplicated=Reconnect-WithOrganizationMode -Mode DuplicateAndInvalid
    Assert-True ((ConvertTo-TestObjectArray -InputObject $deduplicated.Data.Organizations).Count -eq 2) 'Organization discovery must de-duplicate IDs and ignore invalid GUIDs.'
    $duplicatePrimary=ConvertTo-TestObjectArray -InputObject (Get-DiscoveryAttempt -Discovery $deduplicated.Data.OrganizationDiscovery -Command 'Get-OdmOrganizations')
    Assert-True ($duplicatePrimary.Count -eq 1 -and $duplicatePrimary[0].InvalidIdCount -eq 1) 'Invalid organization IDs must be counted in discovery diagnostics.'

    # Zero/one/many adversarial generic-list cardinality returned as a single
    # pipeline object. Active-organization fallback fills any IDs not returned
    # by the primary command; diagnostics preserve the primary converted count.
    $newObjectEmpty=Reconnect-WithOrganizationMode -Mode NewObjectListEmpty
    $emptyAttempt=ConvertTo-TestObjectArray -InputObject (Get-DiscoveryAttempt -Discovery $newObjectEmpty.Data.OrganizationDiscovery -Command 'Get-OdmOrganizations')
    Assert-True ($emptyAttempt.Count -eq 1 -and $emptyAttempt[0].Succeeded -and $emptyAttempt[0].ConvertedCount -eq 0) 'An empty adversarial generic list must normalize without an exception.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject $newObjectEmpty.Data.Organizations).Count -eq 2) 'Fallback organization IDs must remain available after an empty adversarial primary response.'

    $newObjectSingle=Reconnect-WithOrganizationMode -Mode NewObjectListSingle
    $singleAttempt=ConvertTo-TestObjectArray -InputObject (Get-DiscoveryAttempt -Discovery $newObjectSingle.Data.OrganizationDiscovery -Command 'Get-OdmOrganizations')
    Assert-True ($singleAttempt.Count -eq 1 -and $singleAttempt[0].Succeeded -and $singleAttempt[0].ConvertedCount -eq 1) 'A one-item adversarial generic list must preserve one primary organization.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject $newObjectSingle.Data.Organizations).Count -eq 2) 'Fallback discovery must merge the second organization after a one-item primary response.'

    # Exact regression for PowerShell issue #27558. The mock emits a generic
    # List[object] built with New-Object as a single pipeline object.
    $newObjectList=Reconnect-WithOrganizationMode -Mode NewObjectList
    $newObjectOrganizations=ConvertTo-TestObjectArray -InputObject $newObjectList.Data.Organizations
    Assert-True ($newObjectOrganizations.Count -eq 2) 'A New-Object-created generic list must not trigger Argument types do not match during Connect.'
    $newObjectAttempt=ConvertTo-TestObjectArray -InputObject (Get-DiscoveryAttempt -Discovery $newObjectList.Data.OrganizationDiscovery -Command 'Get-OdmOrganizations')
    Assert-True ($newObjectAttempt.Count -eq 1 -and $newObjectAttempt[0].Succeeded -and $newObjectAttempt[0].ConvertedCount -eq 2) 'The adversarial organization response must be normalized and converted.'

    # Directly exercise the private engine normalizer with the same adversarial list.
    $engineModule=Get-Module -Name QuestODMConsole.Engine -ErrorAction Stop
    $normalizerProbe=& $engineModule {
        $list=New-Object System.Collections.Generic.List[object]
        $list.Add([pscustomobject]@{Id='one'})|Out-Null
        $list.Add([pscustomobject]@{Id='two'})|Out-Null
        $normalized=ConvertTo-QOdmObjectArray -InputObject $list
        [pscustomobject]@{Count=$normalized.Count;FirstId=[string]$normalized[0].Id;SecondId=[string]$normalized[1].Id}
    }
    Assert-True ($normalizerProbe.Count -eq 2 -and $normalizerProbe.FirstId -eq 'one' -and $normalizerProbe.SecondId -eq 'two') 'The engine collection normalizer must handle a New-Object-created generic list directly.'

    # Continue broad engine coverage using the current valid connection.
    Set-MockOrganizationMode -Mode Rich
    $selectedOrganization=ConvertTo-TestObjectArray -InputObject ($newObjectOrganizations|Where-Object{$_.Id -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}|Select-Object -First 1)
    Assert-True ($selectedOrganization.Count -eq 1) 'Primary organization must remain selectable after merged discovery.'
    $org=Invoke-TestOperation -Operation SelectOrganization -Parameters @{OrganizationId=$selectedOrganization[0].Id;OrganizationName='Mock Primary Organization'}
    Assert-True ((ConvertTo-TestObjectArray -InputObject $org.Data.Projects).Count -eq 2) 'Two projects should be returned.'
    Assert-True ($org.Data.ProjectDiscovery.Succeeded) 'Project discovery must report success.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($org.Data.Projects|Where-Object{$_.SourceTenant -eq 'source.example' -and $_.TargetTenant -eq 'target.example'})).Count -eq 1) 'Current project tenant-domain properties must map into the project view.'
    $mockState=Get-MockOdmState
    Assert-True ($mockState.SkipProjectCheckCount -gt 0) 'Organization selection should use SkipProjectCheck when supported, then enumerate projects explicitly.'

    $project=Invoke-TestOperation -Operation SelectProject -Parameters @{ProjectId='project-001'}
    $workloadViews=ConvertTo-TestObjectArray -InputObject $project.Data.Workloads
    Assert-True ($workloadViews.Count -eq 3) 'Two child workloads plus the root project context should be returned.'
    Assert-True ($project.Data.WorkloadDiscovery.Succeeded) 'Workload discovery must report success.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($workloadViews|Where-Object{$_.IsProjectContext})).Count -eq 1) 'Exactly one root project context must be present.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($workloadViews|Where-Object{-not $_.IsProjectContext})).Count -eq 2) 'Both child workloads must be present.'
    $null=Invoke-TestOperation -Operation SelectWorkload -Parameters @{WorkloadId='workload-accounts'}
    $null=Enable-TestChanges

    $workspace=Invoke-TestOperation -Operation WorkspaceSnapshot -Parameters @{Refresh=$true}
    Assert-True ($workspace.Data.Dashboard.ObjectCount -eq 3) 'Workspace should load three objects.'
    $mockState=Get-MockOdmState
    Assert-True ($mockState.ProjectWorkloadReads -gt 0) 'Workload inventory must use the project pipeline contract.'

    $literal=Invoke-TestOperation -Operation SearchObjects -Parameters @{Search='Ada*';MaxResults=100;Refresh=$false}
    Assert-True ($literal.Data.Matched -eq 0) 'Object search must treat wildcard characters literally.'
    $normal=Invoke-TestOperation -Operation SearchObjects -Parameters @{Search='Ada';MaxResults=100;Refresh=$false}
    Assert-True ($normal.Data.Matched -eq 1) 'Literal substring object search should match Ada.'

    # RC6 local OdmApi status must detect the globally loaded mock module without making an online call.
    $moduleStatus=Invoke-TestOperation -Operation GetOdmApiModuleStatus -Parameters @{CheckOnline=$false}
    Assert-True ([bool]$moduleStatus.Data.Installed) 'The module-status operation must detect the installed mock OdmApi module.'
    Assert-True ([string]$moduleStatus.Data.InstalledVersion -eq '2.1.396') 'The module-status operation must return the installed mock version.'
    Assert-True (-not [bool]$moduleStatus.Data.OnlineChecked) 'The local module-status operation must not perform an online lookup.'

    $temp=Join-Path ([IO.Path]::GetTempPath()) ('QuestODMConsoleMock-'+[Guid]::NewGuid().ToString('N'))
    New-Item -Path $temp -ItemType Directory -Force | Out-Null

    # Task Factory naming placement is independent for each task type.
    $namingCsv=Join-Path $temp 'factory-naming.csv'
    @([pscustomobject]@{CollectionName='Wave 01';SourceUPN='ada@source.example'}) | Export-Csv -LiteralPath $namingCsv -NoTypeInformation -Encoding UTF8
    $naming=Invoke-TestOperation -Operation TaskFactory -Parameters @{
        CsvPath=$namingCsv;Mode='Direct';Execute=$false;OutputDirectory=$temp;TaskKinds=@('Mail','OneDrive','MeetingLink','MailboxSwitch')
        MailSuffix='Email Sync';MailPlacement='Prefix';OneDriveSuffix='OneDrive Sync';OneDrivePlacement='Suffix'
        MeetingLinkSuffix='Meeting Link Migration';MeetingLinkPlacement='Prefix';MailboxSwitchSuffix='Mailbox Switch';MailboxSwitchPlacement='Suffix'
    }
    $namingRows=ConvertTo-TestObjectArray -InputObject $naming.Data.SummaryRows
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($namingRows|Where-Object{$_.TaskName -eq 'Email Sync - Wave 01'})).Count -eq 1) 'Mail prefix placement must put the naming text before the collection name.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($namingRows|Where-Object{$_.TaskName -eq 'Wave 01 - OneDrive Sync'})).Count -eq 1) 'OneDrive suffix placement must put the naming text after the collection name.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($namingRows|Where-Object{$_.TaskName -eq 'Meeting Link Migration - Wave 01'})).Count -eq 1) 'Meeting-link prefix placement must be honored.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($namingRows|Where-Object{$_.TaskName -eq 'Wave 01 - Mailbox Switch'})).Count -eq 1) 'Mailbox-switch suffix placement must be honored.'

    # Selected-task start and stop operations.
    $accountsTask=(ConvertTo-TestObjectArray -InputObject ((Invoke-TestOperation -Operation GetTasks -Parameters @{Refresh=$true}).Data|Where-Object{$_.Name -eq 'Accounts Task'}|Select-Object -First 1))[0]
    $started=Invoke-TestOperation -Operation StartTasks -Parameters @{TaskIds=@([string]$accountsTask.Id);DelaySeconds=0}
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($started.Data|Where-Object{$_.StartSucceeded})).Count -eq 1) 'A selected New task must be submitted to Start-OdmTask.'
    $stopped=Invoke-TestOperation -Operation StopTasks -Parameters @{TaskIds=@([string]$accountsTask.Id);DelaySeconds=0}
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($stopped.Data|Where-Object{$_.StopSucceeded})).Count -eq 1) 'A selected in-progress task must be submitted to Stop-OdmTask.'

    # Quest-style account discovery and mapping workflows.
    $runToken=[Guid]::NewGuid().ToString('N').Substring(0,8)
    $discoverAll=Invoke-TestOperation -Operation Bulk -Parameters @{Operation='DiscoverAllAccounts';Parameters=@{TaskName="RC6 Discover All $runToken";Execute=$true;StartAfterCreate=$true;OutputDirectory=$temp}}
    Assert-True ($discoverAll.Data.Created -and $discoverAll.Data.Started) 'Discover-all execution must create and explicitly start the discovery task.'
    $mockState=Get-MockOdmState
    Assert-True (-not [bool]$mockState.LastDiscoveryTaskParameters.DiscoverUsingCSV) 'Discover-all must set DiscoverUsingCSV to false.'

    $discoveryUpnCsv=Join-Path $temp 'discovery-upn.csv'
    @(
        [pscustomobject]@{UserPrincipalName='ada@source.example';Type='user'},
        [pscustomobject]@{UserPrincipalName='group@source.example';Type='Microsoft 365 group'}
    ) | Export-Csv -LiteralPath $discoveryUpnCsv -NoTypeInformation -Encoding UTF8
    $discoverCsv=Invoke-TestOperation -Operation Bulk -Parameters @{Operation='DiscoverAccountsFromCsv';Parameters=@{TaskName="RC6 Discover CSV $runToken";CsvPath=$discoveryUpnCsv;Execute=$true;StartAfterCreate=$false;OutputDirectory=$temp}}
    Assert-True ($discoverCsv.Data.Created -and -not $discoverCsv.Data.Started) 'CSV discovery must create an unstarted task unless StartTask is explicitly selected.'
    Assert-True ([string]$discoverCsv.Data.Validation.Format -eq 'UPN') 'Discovery UPN CSV must be recognized as the UPN Quest template.'
    $mockState=Get-MockOdmState
    Assert-True ([bool]$mockState.LastDiscoveryTaskParameters.DiscoverUsingCSV) 'CSV discovery must set DiscoverUsingCSV to true.'
    Assert-True ([string]$mockState.LastDiscoveryTaskParameters.FilePath -eq $discoveryUpnCsv) 'CSV discovery must pass the validated file path to the constructor.'

    $mappingUpnCsv=Join-Path $temp 'mapping-upn.csv'
    @([pscustomobject]@{
        SourceUPN='ada@source.example';TargetUPN='ada@target.example';TargetDisplayName='Ada Lovelace'
        TargetAlias='ada';TargetPrimaryEmail='ada@target.example';TargetFirstName='Ada';TargetLastName='Lovelace'
    }) | Export-Csv -LiteralPath $mappingUpnCsv -NoTypeInformation -Encoding UTF8
    $mapping=Invoke-TestOperation -Operation Bulk -Parameters @{Operation='MapAccountsFromCsv';Parameters=@{TaskName="RC6 Mapping $runToken";CsvPath=$mappingUpnCsv;Execute=$true;StartAfterCreate=$true;OutputDirectory=$temp}}
    Assert-True ($mapping.Data.Created -and $mapping.Data.Started) 'Account mapping must create and explicitly start the mapping task.'
    Assert-True ([string]$mapping.Data.Validation.Format -eq 'UPN') 'Mapping UPN CSV must be recognized as the UPN Quest template.'
    $mockState=Get-MockOdmState
    Assert-True ([string]$mockState.LastMappingTaskParameters.FilePath -eq $mappingUpnCsv) 'Account mapping must pass the validated mapping file path.'

    $mappingIdCsv=Join-Path $temp 'mapping-objectid.csv'
    @([pscustomobject]@{SourceObjectId='11111111-1111-1111-1111-111111111111';TargetObjectId='22222222-2222-2222-2222-222222222222'}) | Export-Csv -LiteralPath $mappingIdCsv -NoTypeInformation -Encoding UTF8
    $mappingIdPreview=Invoke-TestOperation -Operation Bulk -Parameters @{Operation='MapAccountsFromCsv';Parameters=@{TaskName="RC6 Mapping ID $runToken";CsvPath=$mappingIdCsv;Execute=$false;StartAfterCreate=$false;OutputDirectory=$temp}}
    Assert-True ([string]$mappingIdPreview.Data.Validation.Format -eq 'ObjectId' -and -not $mappingIdPreview.Data.Created) 'Object-ID mapping must validate in dry-run mode without creating a task.'

    $invalidMixedCsv=Join-Path $temp 'discovery-mixed.csv'
    @([pscustomobject]@{UserPrincipalName='ada@source.example';ObjectId='11111111-1111-1111-1111-111111111111';Type='user'}) | Export-Csv -LiteralPath $invalidMixedCsv -NoTypeInformation -Encoding UTF8
    $invalidMixed=Invoke-QOdmOperation -Operation Bulk -Parameters @{Operation='DiscoverAccountsFromCsv';Parameters=@{TaskName="Invalid Mixed $runToken";CsvPath=$invalidMixedCsv;Execute=$false;OutputDirectory=$temp}}
    Assert-True (-not $invalidMixed.Success) 'A discovery CSV containing both supported identifier formats must be rejected.'

    $duplicateDiscoveryCsv=Join-Path $temp 'discovery-duplicate.csv'
    @(
        [pscustomobject]@{UserPrincipalName='ada@source.example';Type='user'},
        [pscustomobject]@{UserPrincipalName='ada@source.example';Type='user'}
    ) | Export-Csv -LiteralPath $duplicateDiscoveryCsv -NoTypeInformation -Encoding UTF8
    $duplicateDiscovery=Invoke-QOdmOperation -Operation Bulk -Parameters @{Operation='DiscoverAccountsFromCsv';Parameters=@{TaskName="Duplicate Discovery $runToken";CsvPath=$duplicateDiscoveryCsv;Execute=$false;OutputDirectory=$temp}}
    Assert-True (-not $duplicateDiscovery.Success) 'Duplicate discovery identifiers must be rejected before task creation.'

    # Account workflows must be blocked outside the Accounts workload and context must remain recoverable.
    $null=Invoke-TestOperation -Operation SelectWorkload -Parameters @{WorkloadId='workload-sharepoint'}
    $wrongWorkload=Invoke-QOdmOperation -Operation Bulk -Parameters @{Operation='DiscoverAllAccounts';Parameters=@{TaskName="Wrong Workload $runToken";Execute=$false;OutputDirectory=$temp}}
    Assert-True (-not $wrongWorkload.Success) 'Account discovery must be blocked outside the Accounts workload.'
    $null=Invoke-TestOperation -Operation SelectWorkload -Parameters @{WorkloadId='workload-accounts'}
    $null=Enable-TestChanges

    # CSV task start/stop operations use the same safe one-at-a-time helpers.
    $taskRefsCsv=Join-Path $temp 'task-references.csv'
    @([pscustomobject]@{TaskName='Accounts Task';TaskId=[string]$accountsTask.Id}) | Export-Csv -LiteralPath $taskRefsCsv -NoTypeInformation -Encoding UTF8
    $bulkStart=Invoke-TestOperation -Operation Bulk -Parameters @{Operation='StartTasksFromCsv';Parameters=@{CsvPath=$taskRefsCsv;Execute=$true;OutputDirectory=$temp;DelaySeconds=0}}
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($bulkStart.Data.Rows|Where-Object{$_.ActionSucceeded})).Count -eq 1) 'Bulk start from CSV must submit the resolved task.'
    $bulkStop=Invoke-TestOperation -Operation Bulk -Parameters @{Operation='StopTasksFromCsv';Parameters=@{CsvPath=$taskRefsCsv;Execute=$true;OutputDirectory=$temp;DelaySeconds=0}}
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($bulkStop.Data.Rows|Where-Object{$_.ActionSucceeded})).Count -eq 1) 'Bulk stop from CSV must submit the resolved task.'

    # Tasks > Members CSV workflow: preview must remain read-only, while explicit
    # execution must add, verify, remove, and re-verify the selected task member.
    $taskMembershipCsv=Join-Path $temp 'task-membership.csv'
    @([pscustomobject]@{SourceUPN='grace@source.example'}) | Export-Csv -LiteralPath $taskMembershipCsv -NoTypeInformation -Encoding UTF8
    $taskPreview=Invoke-TestOperation -Operation AddUsersToEntityFromCsv -Parameters @{EntityType='Task';EntityId=[string]$accountsTask.Id;CsvPath=$taskMembershipCsv;Execute=$false;OutputDirectory=$temp}
    Assert-True (-not [bool]$taskPreview.Data.Execute) 'Task CSV preview must return Execute=false.'
    Assert-True ($taskPreview.Data.ResolvedCount -eq 1 -and $taskPreview.Data.CommandSucceededCount -eq 0 -and $taskPreview.Data.VerifiedCount -eq 0) 'Task CSV preview must resolve the user without submitting or verifying a write.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($taskPreview.Data.Report|Where-Object{$_.Status -eq 'DRY_RUN'})).Count -eq 1) 'Task CSV preview must produce a DRY_RUN row.'
    $membersAfterPreview=ConvertTo-TestObjectArray -InputObject ((Invoke-TestOperation -Operation GetTaskMembers -Parameters @{TaskId=[string]$accountsTask.Id}).Data)
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($membersAfterPreview|Where-Object{$_.SourceUPN -eq 'grace@source.example'})).Count -eq 0) 'Task CSV preview must not change task membership.'

    $taskAdd=Invoke-TestOperation -Operation AddUsersToEntityFromCsv -Parameters @{EntityType='Task';EntityId=[string]$accountsTask.Id;CsvPath=$taskMembershipCsv;Execute=$true;OutputDirectory=$temp}
    Assert-True ([bool]$taskAdd.Data.Execute -and $taskAdd.Data.CommandSucceededCount -eq 1 -and $taskAdd.Data.VerifiedCount -eq 1) 'Task CSV execution must submit and verify the add operation.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($taskAdd.Data.Report|Where-Object{$_.Status -eq 'VERIFIED_ADDED'})).Count -eq 1) 'Task CSV add must return VERIFIED_ADDED.'
    Assert-True (Test-Path -LiteralPath ([string]$taskAdd.Data.ReportPath) -PathType Leaf) 'Task CSV add must export a row-level report.'
    $membersAfterAdd=ConvertTo-TestObjectArray -InputObject ((Invoke-TestOperation -Operation GetTaskMembers -Parameters @{TaskId=[string]$accountsTask.Id}).Data)
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($membersAfterAdd|Where-Object{$_.SourceUPN -eq 'grace@source.example'})).Count -eq 1) 'Task CSV add must make the user visible in the selected task.'

    $taskRemove=Invoke-TestOperation -Operation RemoveUsersFromEntityFromCsv -Parameters @{EntityType='Task';EntityId=[string]$accountsTask.Id;CsvPath=$taskMembershipCsv;Execute=$true;OutputDirectory=$temp}
    Assert-True ($taskRemove.Data.CommandSucceededCount -eq 1 -and $taskRemove.Data.VerifiedCount -eq 1) 'Task CSV execution must submit and verify the remove operation.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($taskRemove.Data.Report|Where-Object{$_.Status -eq 'VERIFIED_REMOVED'})).Count -eq 1) 'Task CSV remove must return VERIFIED_REMOVED.'
    $membersAfterRemove=ConvertTo-TestObjectArray -InputObject ((Invoke-TestOperation -Operation GetTaskMembers -Parameters @{TaskId=[string]$accountsTask.Id}).Data)
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($membersAfterRemove|Where-Object{$_.SourceUPN -eq 'grace@source.example'})).Count -eq 0) 'Task CSV remove must remove the user from the selected task.'

    $newCollection=Invoke-TestOperation -Operation NewCollection -Parameters @{Name='Pilot'}
    $collectionId=[string]$newCollection.Data.Id
    Assert-True (-not [string]::IsNullOrWhiteSpace($collectionId)) 'Collection creation must resolve an ID when New-OdmCollection emits no object.'
    $add=Invoke-TestOperation -Operation AddObjectToCollection -Parameters @{ObjectId='object-001';CollectionId=$collectionId}
    Assert-True ($add.Data.Verified) 'Collection membership add must verify.'
    $remove=Invoke-TestOperation -Operation RemoveObjectFromCollection -Parameters @{ObjectId='object-001';CollectionId=$collectionId}
    Assert-True ($remove.Data.Verified) 'Collection membership removal must verify.'

    $membershipCsv=Join-Path $temp 'membership.csv'
    @(
        [pscustomobject]@{SourceUPN='ada@source.example'},
        [pscustomobject]@{SourceUPN='fail@source.example'}
    ) | Export-Csv -LiteralPath $membershipCsv -NoTypeInformation -Encoding UTF8
    $partial=Invoke-TestOperation -Operation AddUsersToEntityFromCsv -Parameters @{EntityType='Collection';EntityId=$collectionId;CsvPath=$membershipCsv;Execute=$true;OutputDirectory=$temp}
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($partial.Data.Report|Where-Object{$_.Status -eq 'VERIFIED_ADDED'})).Count -eq 1) 'A successful row must remain verified when another row fails.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($partial.Data.Report|Where-Object{$_.Status -eq 'COMMAND_FAILED'})).Count -eq 1) 'A per-object write failure must be isolated to its row.'

    $csv=Join-Path $temp 'factory.csv'
    @([pscustomobject]@{CollectionName='Pilot';SourceUPN='ada@source.example'}) | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $factory=Invoke-TestOperation -Operation TaskFactory -Parameters @{CsvPath=$csv;Mode='Template';Execute=$true;OutputDirectory=$temp;TaskKinds=@('Mail');MailTemplateId='11111111-1111-1111-1111-111111111111';LinkTasksToCollections=$true;VerificationRetries=1;VerificationDelaySeconds=0}
    Assert-True ((ConvertTo-TestObjectArray -InputObject $factory.Data.CreatedTasks).Count -eq 1) 'Task Factory should create one task.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($factory.Data.SummaryRows | Where-Object{$_.TaskType -eq 'Collection Link' -and $_.Status -eq 'VERIFIED'})).Count -eq 1) 'Collection-to-task linking must use CollectionId and verify.'

    $allTasks=Invoke-TestOperation -Operation Bulk -Parameters @{Operation='ExportTasks';Parameters=@{OutputDirectory=$temp;IncludeAllProjects=$true}}
    $contextRows=ConvertTo-TestObjectArray -InputObject ($allTasks.Data.Rows|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_.TaskId)})
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($contextRows|Select-Object -ExpandProperty ProjectId -Unique)).Count -eq 2) 'All-project task export must include both root projects.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject ($contextRows|Where-Object{$_.WorkloadId -eq 'workload-sharepoint'})).Count -ge 1) 'All-project task export must select and read workload contexts.'
    Assert-True ($allTasks.Data.ContextValid) 'Context must remain valid after all-project export.'
    $mockState=Get-MockOdmState
    Assert-True ($mockState.CurrentContextId -eq 'workload-accounts') 'All-project task export must restore the original workload context.'
    $null=Enable-TestChanges

    $duplicate=Invoke-QOdmOperation -Operation NewCollection -Parameters @{Name='Pilot'}
    Assert-True (-not $duplicate.Success) 'Duplicate exact collection names must be rejected as ambiguous.'
    Assert-True ($null -ne $duplicate.Diagnostic) 'Ambiguous writes must return structured diagnostics.'

    $callerParameters=@{Operation='ExportCollections';Parameters=@{OutputDirectory=$temp;IncludeCounts=$false}}
    $beforeKeys=(ConvertTo-TestObjectArray -InputObject ($callerParameters.Parameters.Keys|Sort-Object)) -join '|'
    $null=Invoke-TestOperation -Operation Bulk -Parameters $callerParameters
    $afterKeys=(ConvertTo-TestObjectArray -InputObject ($callerParameters.Parameters.Keys|Sort-Object)) -join '|'
    Assert-True ($beforeKeys -eq $afterKeys) 'The dispatcher must not mutate caller-owned parameter dictionaries.'

    $unknown=Invoke-QOdmOperation -Operation 'DefinitelyUnknown' -Parameters @{}
    Assert-True (-not $unknown.Success) 'Unknown operations must return a failed result rather than terminating the host.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$unknown.DiagnosticId)) 'Failed operations must include a diagnostic ID.'

    $disconnect=Invoke-TestOperation -Operation Disconnect
    Assert-True ($null -ne (Get-Module OdmApi -ErrorAction SilentlyContinue)) 'Disconnect must leave OdmApi loaded for worker lifetime.'
    Set-MockOrganizationMode -Mode Rich
    $reconnect=Invoke-TestOperation -Operation Connect -Parameters @{Region='US'}
    Assert-True ($reconnect.Data.State.ModuleRuntimeProbeStatus -eq 'PASS') 'Reconnect must repeat the real private initialization probe successfully.'
    Assert-True ((ConvertTo-TestObjectArray -InputObject $reconnect.Data.Organizations).Count -eq 2) 'Reconnect must reload organizations.'
    $mockState=Get-MockOdmState
    Assert-True ($mockState.IntegratedAuthConnectCount -eq 0) 'No test connection should use integrated Windows authentication.'

    Write-Output 'MOCK ENGINE TESTS: PASS'
}
finally {
    if($null -ne $temp -and (Test-Path -LiteralPath $temp)){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
    $env:PSModulePath=$oldModulePath
    Remove-Module QuestODMConsole.Engine -Force -ErrorAction SilentlyContinue
    Remove-Module OdmApi -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name QuestODMConsoleOdmApiPreload -Scope Global -ErrorAction SilentlyContinue
}
