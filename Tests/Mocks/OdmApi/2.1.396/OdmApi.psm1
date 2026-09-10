Set-StrictMode -Version 2.0

$script:Connected = $false
$script:OrganizationId = [Guid]::Empty
$script:CurrentProject = $null
$script:ModuleName = $null
$script:ModuleVersion = $null
$script:ConnectCount = 0
$script:IntegratedAuthConnectCount = 0
$script:OrganizationMode = 'Rich'
$script:GetOrganizationsCalls = 0
$script:GetActiveOrganizationsCalls = 0
$script:SkipProjectCheckCount = 0
$script:LastDiscoveryTaskParameters = $null
$script:LastMappingTaskParameters = $null
$script:StartedTaskIds = [System.Collections.Generic.List[string]]::new()
$script:StoppedTaskIds = [System.Collections.Generic.List[string]]::new()

$script:Organizations = [System.Collections.Generic.List[object]]::new()
$script:Organizations.Add([pscustomobject]@{
    OrganizationId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    OrganizationDisplayName = 'Mock Primary Organization'
}) | Out-Null
$script:Organizations.Add([pscustomobject]@{
    OrganizationId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    OrganizationDisplayName = 'Mock Secondary Organization'
}) | Out-Null

$script:Projects = @(
    [pscustomobject]@{
        Id='project-001'; Name='Mock M365 Project'; ProjectType='M365toM365'
        SourceTenantDefaultDomainName='source.example'; TargetTenantDefaultDomainName='target.example'
    },
    [pscustomobject]@{
        Id='project-002'; Name='Mock AD Project'; ProjectType='ActiveDirectory'
        SourceTenantDefaultDomainName='source-ad.example'; TargetTenantDefaultDomainName='target-ad.example'
    }
)
$script:Workloads = @(
    [pscustomobject]@{ Id='workload-accounts'; Name='Accounts'; WorkloadType='accounts'; ParentProjectId='project-001' },
    [pscustomobject]@{ Id='workload-sharepoint'; Name='SharePoint'; WorkloadType='spm'; ParentProjectId='project-001' },
    [pscustomobject]@{ Id='workload-ad'; Name='Directory'; WorkloadType='activedirectory'; ParentProjectId='project-002' }
)
$script:Objects = @(
    [pscustomobject]@{ Id='object-001'; DisplayName='Ada Lovelace'; SourceUserPrincipalName='ada@source.example'; TargetUserPrincipalName='ada@target.example'; SourceEmail='ada@source.example'; TargetEmail='ada@target.example'; Type='User'; Status='Matched'; FailWrites=$false },
    [pscustomobject]@{ Id='object-002'; DisplayName='Grace Hopper'; SourceUserPrincipalName='grace@source.example'; TargetUserPrincipalName='grace@target.example'; SourceEmail='grace@source.example'; TargetEmail='grace@target.example'; Type='User'; Status='Matched'; FailWrites=$false },
    [pscustomobject]@{ Id='object-003'; DisplayName='Write Failure User'; SourceUserPrincipalName='fail@source.example'; TargetUserPrincipalName='fail@target.example'; SourceEmail='fail@source.example'; TargetEmail='fail@target.example'; Type='User'; Status='Matched'; FailWrites=$true }
)
$script:Tasks = [System.Collections.Generic.List[object]]::new()
$script:Collections = [System.Collections.Generic.List[object]]::new()
$script:Templates = @(
    [pscustomobject]@{ Id='11111111-1111-1111-1111-111111111111'; Name='Mock Mail Template'; Type='Mail'; ProjectId='workload-accounts' },
    [pscustomobject]@{ Id='22222222-2222-2222-2222-222222222222'; Name='Root Mail Template'; Type='Mail'; ProjectId='project-001' }
)
$script:Counters = @{ ProjectTaskReads = 0; ProjectWorkloadReads = 0; ContextTaskReads = 0 }

function Set-ModuleVersion {
    $moduleName = $MyInvocation.MyCommand.ModuleName
    $module = Get-Module -Name $moduleName | Select-Object -First 1
    $script:ModuleName = $moduleName
    $script:ModuleVersion = $module.Version.Major.ToString() + '.' + $module.Version.Minor.ToString() + '.' + $module.Version.Build.ToString()
}
function Assert-MockConnected { if (-not $script:Connected) { throw 'Mock OdmApi is not connected.' } }
function Assert-MockOrganization { Assert-MockConnected; if ($script:OrganizationId -eq [Guid]::Empty) { throw 'Mock organization is not selected.' } }
function Assert-MockProject { Assert-MockOrganization; if ($null -eq $script:CurrentProject) { throw 'Mock project is not selected.' } }
function Get-MockContextId { if ($null -eq $script:CurrentProject) { return $null }; return [string]$script:CurrentProject.Id }
function Copy-MockOrganization {
    param([Parameter(Mandatory=$true)][object]$Organization)
    [pscustomobject]@{
        OrganizationId = [string]$Organization.OrganizationId
        OrganizationDisplayName = [string]$Organization.OrganizationDisplayName
    }
}
function New-MockTask {
    param([string]$Name,[string]$Type,[string]$TemplateId,[string]$ContextId)
    if ([string]::IsNullOrWhiteSpace($ContextId)) { $ContextId = Get-MockContextId }
    $task = [pscustomobject]@{
        Id=[Guid]::NewGuid().ToString(); Name=$Name; Type=$Type; Status='New'; ProjectId=$ContextId; TemplateId=$TemplateId
        CreatedAt=(Get-Date); StartedAt=$null; CompletedAt=$null; SucceededCount=0; FailedCount=0; ProcessedCount=0
        ObjectIds=[System.Collections.Generic.List[string]]::new()
        CollectionIds=[System.Collections.Generic.List[string]]::new()
    }
    $script:Tasks.Add($task) | Out-Null
    return $task
}
function New-MockCollection {
    param([string]$Name,[string]$ContextId)
    $collection=[pscustomobject]@{
        Id=[Guid]::NewGuid().ToString(); Name=$Name; Description=''; ProjectId=$ContextId
        ObjectIds=[System.Collections.Generic.List[string]]::new()
        TaskIds=[System.Collections.Generic.List[string]]::new()
    }
    $script:Collections.Add($collection)|Out-Null
    return $collection
}

# Seed context-specific tasks to validate all-context export and selection.
$null = New-MockTask -Name 'Root Project One Task' -Type 'Mail' -ContextId 'project-001'
$null = New-MockTask -Name 'Accounts Task' -Type 'Mail' -ContextId 'workload-accounts'
$null = New-MockTask -Name 'SharePoint Task' -Type 'SharePoint' -ContextId 'workload-sharepoint'
$null = New-MockTask -Name 'Root Project Two Task' -Type 'Directory' -ContextId 'project-002'
$null = New-MockTask -Name 'Directory Workload Task' -Type 'Directory' -ContextId 'workload-ad'

function Connect-OdmService {
    [CmdletBinding()]
    param([string]$Region='us',[string]$Region2EndpointMapUrl,[string]$UserName,[string]$Password,[string]$TenantId,[switch]$UseIntegratedWindowsAuth,[switch]$PassThru)
    Set-ModuleVersion
    $script:Connected = $true
    $script:ConnectCount++
    if ($UseIntegratedWindowsAuth) { $script:IntegratedAuthConnectCount++ }
    if ($PassThru) { [pscustomobject]@{ Region=$Region; Connected=$true } }
}
function Disconnect-OdmService {
    [CmdletBinding()]
    param()
    $script:Connected=$false
    $script:OrganizationId=[Guid]::Empty
    $script:CurrentProject=$null
}
function Set-MockOrganizationMode {
    [CmdletBinding()]
    param([ValidateSet('Rich','PrimaryEmpty','PrimaryError','Wrapped','WrappedItems','WrappedValue','WrappedResults','WrappedData','DuplicateAndInvalid','NewObjectListEmpty','NewObjectListSingle','NewObjectList')][string]$Mode)
    $script:OrganizationMode = $Mode
}
function Get-OdmOrganizations {
    [CmdletBinding()]
    param()
    Assert-MockConnected
    $script:GetOrganizationsCalls++
    switch ($script:OrganizationMode) {
        'PrimaryEmpty' { return @() }
        'PrimaryError' { throw 'Mock primary organization discovery failure.' }
        'Wrapped' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($organization in $script:Organizations) { $list.Add((Copy-MockOrganization -Organization $organization)) | Out-Null }
            return [pscustomobject]@{ Organizations = $list }
        }
        'WrappedItems' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($organization in $script:Organizations) { $list.Add((Copy-MockOrganization -Organization $organization)) | Out-Null }
            return [pscustomobject]@{ Items = $list }
        }
        'WrappedValue' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($organization in $script:Organizations) { $list.Add((Copy-MockOrganization -Organization $organization)) | Out-Null }
            return [pscustomobject]@{ Value = $list }
        }
        'WrappedResults' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($organization in $script:Organizations) { $list.Add((Copy-MockOrganization -Organization $organization)) | Out-Null }
            return [pscustomobject]@{ Results = $list }
        }
        'WrappedData' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($organization in $script:Organizations) { $list.Add((Copy-MockOrganization -Organization $organization)) | Out-Null }
            return [pscustomobject]@{ Data = $list }
        }
        'DuplicateAndInvalid' {
            $items = [System.Collections.Generic.List[object]]::new()
            $items.Add((Copy-MockOrganization -Organization $script:Organizations[0])) | Out-Null
            $items.Add((Copy-MockOrganization -Organization $script:Organizations[0])) | Out-Null
            $items.Add([pscustomobject]@{ OrganizationId='not-a-guid'; OrganizationDisplayName='Invalid Organization' }) | Out-Null
            return $items
        }
        'NewObjectListEmpty' {
            $list = New-Object System.Collections.Generic.List[object]
            Write-Output -NoEnumerate $list
            return
        }
        'NewObjectListSingle' {
            $list = New-Object System.Collections.Generic.List[object]
            $list.Add((Copy-MockOrganization -Organization $script:Organizations[0])) | Out-Null
            Write-Output -NoEnumerate $list
            return
        }
        'NewObjectList' {
            # Reproduces PowerShell issue #27558: @($list) can throw
            # "Argument types do not match" when the generic list was created
            # through New-Object instead of the CLR constructor.
            $list = New-Object System.Collections.Generic.List[object]
            foreach ($organization in $script:Organizations) {
                $list.Add((Copy-MockOrganization -Organization $organization)) | Out-Null
            }
            Write-Output -NoEnumerate $list
            return
        }
        default {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($organization in $script:Organizations) { $list.Add((Copy-MockOrganization -Organization $organization)) | Out-Null }
            return $list
        }
    }
}
function Get-OdmActiveOrganizations {
    [CmdletBinding()]
    param()
    Assert-MockConnected
    $script:GetActiveOrganizationsCalls++
    return @($script:Organizations | ForEach-Object { [string]$_.OrganizationId })
}
function Select-OdmOrganization {
    [CmdletBinding()]
    param([Guid]$OrganizationId,[switch]$SkipProjectCheck,[switch]$PassThru)
    Assert-MockConnected
    $known = @($script:Organizations | Where-Object { [string]$_.OrganizationId -eq $OrganizationId.ToString() })
    if ($known.Count -eq 0) { throw "Mock organization '$OrganizationId' was not found." }
    $script:OrganizationId=$OrganizationId
    $script:CurrentProject=$null
    if ($SkipProjectCheck) { $script:SkipProjectCheckCount++ }
    if($PassThru){$OrganizationId}
}
function Get-OdmProject {
    [CmdletBinding()] param([string]$ProjectId,[string]$Name,[switch]$All)
    Assert-MockOrganization
    $result=@($script:Projects)
    if($ProjectId){$result=@($result|Where-Object{$_.Id -eq $ProjectId})}
    if($Name){$result=@($result|Where-Object{$_.Name -eq $Name})}
    $result
}
function Select-OdmProject {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)][object]$Project,[string]$ProjectId,[switch]$PassThru)
    process {
        Assert-MockOrganization
        if($null -eq $Project -and $ProjectId){$Project=@(Get-OdmProject -ProjectId $ProjectId)|Select-Object -First 1}
        if($null -eq $Project){throw 'Mock project could not be resolved.'}
        $script:CurrentProject=$Project
        if($PassThru){$Project}
    }
}
function Get-OdmProjectWorkload {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)][object]$Project,[string]$ProjectWorkloadId,[string]$Type,[switch]$All)
    process {
        Assert-MockOrganization
        $result=@($script:Workloads)
        if($Project){$script:Counters.ProjectWorkloadReads++;$result=@($result|Where-Object{$_.ParentProjectId -eq $Project.Id})}
        if($ProjectWorkloadId){$result=@($result|Where-Object{$_.Id -eq $ProjectWorkloadId})}
        if($Type){$result=@($result|Where-Object{$_.WorkloadType -eq $Type})}
        $result
    }
}
function Select-OdmProjectWorkload {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)][object]$Project,[string]$ProjectWorkloadId,[switch]$PassThru)
    process {
        Assert-MockOrganization
        if($null -eq $Project -and $ProjectWorkloadId){$Project=@(Get-OdmProjectWorkload -ProjectWorkloadId $ProjectWorkloadId)|Select-Object -First 1}
        if($null -eq $Project){throw 'Mock workload could not be resolved.'}
        $script:CurrentProject=$Project
        if($PassThru){$Project}
    }
}
function Get-OdmObject {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)][object]$FilterObject,[hashtable]$WildcardFilter,[string]$Id,[string]$Name,[switch]$All,[switch]$IncludeAllProperties,[switch]$IncludeCollections)
    process {
        Assert-MockProject
        $result=@($script:Objects)
        if($null -ne $FilterObject){
            $ids=@($FilterObject.ObjectIds)
            $result=@($result|Where-Object{$ids -contains $_.Id})
        }
        if($Id){$result=@($result|Where-Object{$_.Id -eq $Id})}
        if($Name){$result=@($result|Where-Object{$_.DisplayName -eq $Name})}
        $result
    }
}
function Get-OdmTask {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)][object]$Project,[string]$Type,[hashtable]$WildcardFilter,[switch]$All,[string]$TaskId,[string]$CollectionId,[DateTime]$FromCreated,[DateTime]$ToCreated,[DateTime]$FromModified,[DateTime]$ToModified)
    process {
        Assert-MockProject
        $result=@($script:Tasks)
        $context = $Project
        if($null -eq $context){$context=$script:CurrentProject;$script:Counters.ContextTaskReads++}else{$script:Counters.ProjectTaskReads++}
        if($null -ne $context){$result=@($result|Where-Object{$_.ProjectId -eq $context.Id})}
        if($Type){$result=@($result|Where-Object{$_.Type -eq $Type})}
        if($TaskId){$result=@($result|Where-Object{$_.Id -eq $TaskId})}
        if($CollectionId){$result=@($result|Where-Object{$_.CollectionIds -contains $CollectionId})}
        $result
    }
}
function Get-OdmCollection {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)][object]$FilterObject,[hashtable]$WildcardFilter,[int]$ResultSize,[string]$Name,[switch]$OnlyIdAndName)
    process {
        Assert-MockProject
        $result=@($script:Collections|Where-Object{$_.ProjectId -eq (Get-MockContextId)})
        if($FilterObject){$result=@($result|Where-Object{$_.Id -eq $FilterObject.Id})}
        if($Name){$result=@($result|Where-Object{$_.Name -eq $Name})}
        if($ResultSize -gt 0){$result=@($result|Select-Object -First $ResultSize)}
        $result
    }
}
function Get-OdmTaskTemplates {
    [CmdletBinding()] param([string]$ProjectId,[string]$TemplateId,[string]$Name,[hashtable]$WildcardFilter,[switch]$All)
    Assert-MockProject
    $result=@($script:Templates)
    if($ProjectId){$result=@($result|Where-Object{$_.ProjectId -eq $ProjectId})}
    if($TemplateId){$result=@($result|Where-Object{$_.Id -eq $TemplateId})}
    if($Name){$result=@($result|Where-Object{$_.Name -eq $Name})}
    $result
}
function Add-OdmObject {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][object]$To,[Parameter(Mandatory=$true)][object[]]$Objects,[switch]$PassThru)
    foreach($object in @($Objects)){
        if([bool]$object.FailWrites){throw "Mock write failure for object '$($object.Id)'."}
        if(-not $To.ObjectIds.Contains([string]$object.Id)){$To.ObjectIds.Add([string]$object.Id)|Out-Null}
    }
    if($PassThru){$To}
}
function Remove-OdmObject {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')] param([Parameter(Mandatory=$true)][object]$From,[Parameter(Mandatory=$true)][object[]]$Objects,[switch]$PassThru)
    foreach($object in @($Objects)){
        if([bool]$object.FailWrites){throw "Mock write failure for object '$($object.Id)'."}
        [void]$From.ObjectIds.Remove([string]$object.Id)
    }
    if($PassThru){$From}
}
function New-OdmCollection {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Name)
    $null=New-MockCollection -Name $Name -ContextId (Get-MockContextId)
    # Current OdmApi New-OdmCollection does not guarantee pipeline output.
}
function Remove-OdmCollection { [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')] param([Parameter(Mandatory=$true)][object[]]$Collections); foreach($collection in @($Collections)){[void]$script:Collections.Remove($collection)} }
function Remove-OdmTask { [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')] param([Parameter(Mandatory=$true)][object[]]$Tasks); foreach($task in @($Tasks)){[void]$script:Tasks.Remove($task)} }
function Start-OdmTask {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][object[]]$Tasks)
    foreach($task in @($Tasks)){
        $task.Status='In Progress'
        $task.StartedAt=Get-Date
        $task.CompletedAt=$null
        if(-not $script:StartedTaskIds.Contains([string]$task.Id)){$script:StartedTaskIds.Add([string]$task.Id)|Out-Null}
    }
}
function Stop-OdmTask {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][object[]]$Tasks)
    foreach($task in @($Tasks)){
        $task.Status='Stopped'
        $task.CompletedAt=Get-Date
        if(-not $script:StoppedTaskIds.Contains([string]$task.Id)){$script:StoppedTaskIds.Add([string]$task.Id)|Out-Null}
    }
}
function Add-OdmTask {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][object]$To,[Parameter(Mandatory=$true)][object[]]$Tasks,[switch]$PassThru)
    foreach($task in @($Tasks)){
        if(-not $task.CollectionIds.Contains([string]$To.Id)){$task.CollectionIds.Add([string]$To.Id)|Out-Null}
        if(-not $To.TaskIds.Contains([string]$task.Id)){$To.TaskIds.Add([string]$task.Id)|Out-Null}
    }
    if($PassThru){$Tasks}
}
function New-OdmMailMigrationTask { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Name,[string]$TemplateId,[switch]$PassThru); $task=New-MockTask -Name $Name -Type 'Mail' -TemplateId $TemplateId; if($PassThru){$task} }
function New-OdmOneDriveMigrationTask { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Name,[string]$TemplateId,[switch]$PassThru); $task=New-MockTask -Name $Name -Type 'OneDrive' -TemplateId $TemplateId; if($PassThru){$task} }
function New-OdmMeetingLinkMigrationTask { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Name,[string]$TemplateId,[switch]$PassThru); $task=New-MockTask -Name $Name -Type 'MeetingLink' -TemplateId $TemplateId; if($PassThru){$task} }
function New-OdmMailSwitchTask { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$Name,[string]$TemplateId,[switch]$PassThru); $task=New-MockTask -Name $Name -Type 'MailboxSwitch' -TemplateId $TemplateId; if($PassThru){$task} }
function New-OdmDiscoveryTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][bool]$DiscoverUsingCSV,
        [string]$FilePath,
        [bool]$DiscoverUsingGroups=$false,
        [string]$DiscoveryGroupsFilePath,
        [switch]$PassThru
    )
    if($DiscoverUsingCSV -and [string]::IsNullOrWhiteSpace($FilePath)){throw 'FilePath is required when DiscoverUsingCSV is true.'}
    if($DiscoverUsingCSV -and -not (Test-Path -LiteralPath $FilePath -PathType Leaf)){throw "Mock discovery CSV was not found: $FilePath"}
    $script:LastDiscoveryTaskParameters=[pscustomobject]@{
        Name=$Name;DiscoverUsingCSV=$DiscoverUsingCSV;FilePath=$FilePath
        DiscoverUsingGroups=$DiscoverUsingGroups;DiscoveryGroupsFilePath=$DiscoveryGroupsFilePath
    }
    $task=New-MockTask -Name $Name -Type 'Account Discovery' -TemplateId $null
    if($PassThru){$task}
}
function New-OdmMappingFileTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$FilePath,
        [switch]$PassThru
    )
    if(-not (Test-Path -LiteralPath $FilePath -PathType Leaf)){throw "Mock mapping CSV was not found: $FilePath"}
    $script:LastMappingTaskParameters=[pscustomobject]@{Name=$Name;FilePath=$FilePath}
    $task=New-MockTask -Name $Name -Type 'Account Mapping' -TemplateId $null
    if($PassThru){$task}
}

function Get-OdmRoleAssignments {
    [CmdletBinding()]
    param()
    Assert-MockOrganization
    @(
        [pscustomobject]@{ Id='role-assignment-001'; PrincipalName='mock.user@example'; RoleName='Migration Administrator'; OrganizationId=$script:OrganizationId.ToString() }
    )
}
function Get-OdmRoles {
    [CmdletBinding()]
    param()
    Assert-MockOrganization
    @(
        [pscustomobject]@{ Id='role-001'; Name='Migration Administrator'; Description='Mock migration role.' },
        [pscustomobject]@{ Id='role-002'; Name='Viewer'; Description='Mock read-only role.' }
    )
}
function Get-EffectiveMigrationSubscription {
    [CmdletBinding()]
    param()
    Assert-MockOrganization
    [pscustomobject]@{ Id='subscription-001'; Name='Mock Migration Subscription'; Status='Active'; ExpiresAt=(Get-Date).AddDays(90) }
}
function Test-ActiveMigrationSubscription {
    [CmdletBinding()]
    param()
    Assert-MockOrganization
    return $true
}
function Get-OdmEvent {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true)][object]$FilterObject,
        [string]$Category,
        [datetime]$From,
        [datetime]$To,
        [string]$Severity,
        [switch]$CurrentOnly,
        [hashtable]$WildcardFilter,
        [switch]$All
    )
    process {
        Assert-MockProject
        $taskId = $null
        $taskName = 'Mock Task'
        if ($null -ne $FilterObject) {
            $taskId = [string]$FilterObject.Id
            $taskName = [string]$FilterObject.Name
        }
        @(
            [pscustomobject]@{ Timestamp=(Get-Date).AddMinutes(-2); Severity='Information'; Category='Task'; Message="Task '$taskName' is available in the mock service."; ObjectId=$taskId; Acknowledged=$false },
            [pscustomobject]@{ Timestamp=(Get-Date).AddMinutes(-1); Severity='Warning'; Category='Task'; Message="Mock warning event for '$taskName'."; ObjectId=$taskId; Acknowledged=$false }
        )
    }
}
function Get-OdmReporting {
    [CmdletBinding()]
    param(
        [string]$ProjectId,
        [string]$ObjectState,
        [string]$ObjectType,
        [string]$SourceName,
        [string]$TargetName,
        [hashtable]$WildcardFilter,
        [switch]$All
    )
    Assert-MockProject
    $context = $ProjectId
    if ([string]::IsNullOrWhiteSpace($context)) { $context = Get-MockContextId }
    $rows=[System.Collections.Generic.List[object]]::new()
    foreach($task in @($script:Tasks|Where-Object{$_.ProjectId -eq $context})){
        $rows.Add([pscustomobject]@{TaskId=$task.Id;TaskName=$task.Name;ObjectId='object-001';ObjectState='Succeeded';ObjectType='User';SourceName='ada@source.example';TargetName='ada@target.example'})|Out-Null
        $rows.Add([pscustomobject]@{TaskId=$task.Id;TaskName=$task.Name;ObjectId='object-002';ObjectState='Failed';ObjectType='User';SourceName='grace@source.example';TargetName='grace@target.example'})|Out-Null
    }
    $result=$rows.ToArray()
    if($ObjectState){$result=@($result|Where-Object{$_.ObjectState -eq $ObjectState})}
    if($ObjectType){$result=@($result|Where-Object{$_.ObjectType -eq $ObjectType})}
    if($SourceName){$result=@($result|Where-Object{$_.SourceName -eq $SourceName})}
    if($TargetName){$result=@($result|Where-Object{$_.TargetName -eq $TargetName})}
    $result
}
function Get-OdmReportInfo {
    [CmdletBinding()]
    param([string]$ProjectId,[switch]$All)
    Assert-MockProject
    $context = $ProjectId
    if ([string]::IsNullOrWhiteSpace($context)) { $context = Get-MockContextId }
    @([pscustomobject]@{Id='report-info-001';Name='Mock report';ProjectId=$context})
}
function Get-OdmReport {
    [CmdletBinding()]
    param([string]$ReportId,[string]$ProjectId,[switch]$All)
    Assert-MockProject
    $resolvedReportId = $ReportId
    if ([string]::IsNullOrWhiteSpace($resolvedReportId)) { $resolvedReportId = 'report-001' }
    $context = $ProjectId
    if ([string]::IsNullOrWhiteSpace($context)) { $context = Get-MockContextId }
    @([pscustomobject]@{Id=$resolvedReportId;Name='Mock report';Status='Ready';ProjectId=$context})
}
function New-OdmReportingErrorLogsExportTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$ProjectId,
        [switch]$PassThru
    )
    Assert-MockProject
    $source=@($script:Tasks|Where-Object{$_.Id -eq $TaskId})|Select-Object -First 1
    if($null -eq $source){throw "Mock source task not found: $TaskId"}
    $context = $ProjectId
    if ([string]::IsNullOrWhiteSpace($context)) { $context = Get-MockContextId }
    $task=New-MockTask -Name $Name -Type 'Reporting Error Logs Export' -TemplateId $null -ContextId $context
    if($PassThru){$task}
}

function Get-MockOdmState {
    [CmdletBinding()] param()
    [pscustomobject]@{
        Connected=$script:Connected; ConnectCount=$script:ConnectCount; IntegratedAuthConnectCount=$script:IntegratedAuthConnectCount
        ModuleName=$script:ModuleName; ModuleVersion=$script:ModuleVersion; CurrentContextId=(Get-MockContextId)
        OrganizationMode=$script:OrganizationMode; GetOrganizationsCalls=$script:GetOrganizationsCalls; GetActiveOrganizationsCalls=$script:GetActiveOrganizationsCalls
        SkipProjectCheckCount=$script:SkipProjectCheckCount; SelectedOrganizationId=$script:OrganizationId.ToString()
        ProjectTaskReads=$script:Counters.ProjectTaskReads; ProjectWorkloadReads=$script:Counters.ProjectWorkloadReads
        ContextTaskReads=$script:Counters.ContextTaskReads; TaskCount=$script:Tasks.Count; CollectionCount=$script:Collections.Count
        LastDiscoveryTaskParameters=$script:LastDiscoveryTaskParameters; LastMappingTaskParameters=$script:LastMappingTaskParameters
        StartedTaskIds=$script:StartedTaskIds.ToArray(); StoppedTaskIds=$script:StoppedTaskIds.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Connect-OdmService','Disconnect-OdmService','Get-OdmOrganizations','Get-OdmActiveOrganizations','Select-OdmOrganization',
    'Set-MockOrganizationMode','Get-OdmProject','Select-OdmProject','Get-OdmProjectWorkload','Select-OdmProjectWorkload',
    'Get-OdmObject','Get-OdmTask','Get-OdmCollection','Get-OdmTaskTemplates',
    'Add-OdmObject','Remove-OdmObject','New-OdmCollection','Remove-OdmCollection','Remove-OdmTask',
    'Start-OdmTask','Stop-OdmTask','Add-OdmTask','New-OdmMailMigrationTask','New-OdmOneDriveMigrationTask',
    'New-OdmMeetingLinkMigrationTask','New-OdmMailSwitchTask','New-OdmDiscoveryTask','New-OdmMappingFileTask',
    'Get-OdmRoleAssignments','Get-OdmRoles','Get-EffectiveMigrationSubscription','Test-ActiveMigrationSubscription',
    'Get-OdmEvent','Get-OdmReporting','Get-OdmReportInfo','Get-OdmReport','New-OdmReportingErrorLogsExportTask','Get-MockOdmState'
)
