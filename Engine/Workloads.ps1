# Workload-specific inventory and CSV creation. All reads are scoped to the selected context.
function Get-QOdmContentWorkload {
    Assert-QOdmWorkloadSelected
    switch -Regex ([string]$script:QOdmState.WorkloadType) {
        '^(Teams|mst)$' { return 'Teams' }
        '^(SharePoint|spm)$' { return 'SharePoint' }
        '^(PowerBi|pbi)$' { return 'PowerBI' }
        default { throw 'Open a Teams, SharePoint, or Power BI workload using the context selector first.' }
    }
}

function Get-QOdmContentTaskCatalog {
    @(
        [pscustomobject]@{Key='TeamsProvision';Name='Provision teams';Workload='Teams';ObjectKind='Teams';Command='New-OdmTeamsProvisionTask';TemplateType='';Defaults=@{ProvisionNewOrExistingTeam='createNew';ProvisionNewOrExistingChannel='createNew';NewTeamSuffix='Migrated';NewChannelSuffix='Migrated'}}
        [pscustomobject]@{Key='TeamsMigrate';Name='Migrate teams (template)';Workload='Teams';ObjectKind='Teams';Command='New-OdmTeamsMigrationTask';TemplateType='migrateteams';Defaults=@{}}
        [pscustomobject]@{Key='TeamsStatistics';Name='Collect team statistics';Workload='Teams';ObjectKind='Teams';Command='New-OdmTeamsCollectStatisticsTask';TemplateType='';Defaults=@{DiscoveryOption='selectedteam';StatisticsCollectType='basic';CollectStatisticsFromTargetTenant=$false}}
        [pscustomobject]@{Key='GroupsProvision';Name='Provision Microsoft 365 groups';Workload='Teams';ObjectKind='Groups';Command='New-OdmTeamsGroupsProvisionTask';TemplateType='';Defaults=@{ProvisionNewOrExistingGroup='skip'}}
        [pscustomobject]@{Key='GroupsMigrate';Name='Migrate Microsoft 365 groups (template)';Workload='Teams';ObjectKind='Groups';Command='New-OdmTeamsGroupMigrationTask';TemplateType='migrategroups';Defaults=@{}}
        [pscustomobject]@{Key='ChatsMigrate';Name='Migrate chats (template)';Workload='Teams';ObjectKind='Chats';Command='New-OdmTeamsChatMigrationTask';TemplateType='migratechats';Defaults=@{}}
        [pscustomobject]@{Key='SharePointDiscover';Name='Discover SharePoint contents';Workload='SharePoint';ObjectKind='SharePoint';Command='New-OdmSPDiscoverSharePointContentsTask';TemplateType='';Defaults=@{CollectFormWorkflowStatistics=$false}}
        [pscustomobject]@{Key='SharePointMigrate';Name='Migrate SharePoint contents (template)';Workload='SharePoint';ObjectKind='SharePoint';Command='New-OdmSPMigrationTask';TemplateType='MigrateSharePointContents';Defaults=@{}}
        [pscustomobject]@{Key='PowerBIProvision';Name='Provision Power BI workspaces';Workload='PowerBI';ObjectKind='Workspace';Command='New-OdmPbiProvisionWorkspacesTask';TemplateType='';Defaults=@{ConflictResolution='skip';SetTargetAdminUser=$true;SetTargetAdminUserOption='setIfNoAdminIsMapped';UpdateTargetWorkspacePermissions=$true;UpdateTargetWorkspacePermissionsOption='addFromSource'}}
        [pscustomobject]@{Key='PowerBIMigrate';Name='Migrate Power BI workspaces';Workload='PowerBI';ObjectKind='Workspace';Command='New-OdmPbiMigrateWorkspacesTask';TemplateType='';Defaults=@{IncrementalMigration=$true;UpdateTargetWorkspaceContentPermissions=$true;UpdateTargetWorkspaceContentPermissionsOption='addFromSource';Priority=100}}
    )
}

function Get-QOdmContentReadParameters {
    param([Parameter(Mandatory=$true)][string]$ObjectKind)
    $workload = Get-QOdmContentWorkload
    $parameters = @{All=$true}
    switch ($workload) {
        'Teams' {
            if ($ObjectKind -notin @('Teams','Groups','Chats')) { throw 'Choose Teams, Groups, or Chats for this workload.' }
            $parameters.TypeOfTeam = $ObjectKind
        }
        'SharePoint' {
            if ($ObjectKind -ne 'SharePoint') { throw 'Choose SharePoint objects for this workload.' }
        }
        'PowerBI' {
            if ($ObjectKind -notin @('Workspace','Gateway','Connection')) { throw 'Choose Workspace, Gateway, or Connection for this workload.' }
            $parameters.TypeOfPowerBi = $ObjectKind
        }
    }
    return $parameters
}

function Get-QOdmContentObjects {
    param([Parameter(Mandatory=$true)][string]$ObjectKind, [AllowNull()][object]$Entity)
    $parameters = Get-QOdmContentReadParameters -ObjectKind $ObjectKind
    if ($null -ne $Entity) { $parameters.FilterObject = $Entity }
    Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmObject' -Parameters $parameters -RequiredParameters @($parameters.Keys)
}

function Get-QOdmContentInventory {
    param([Parameter(Mandatory=$true)][string]$ObjectKind)
    $workload = Get-QOdmContentWorkload
    $items = foreach ($object in (Get-QOdmContentObjects -ObjectKind $ObjectKind)) {
        [pscustomobject]@{
            ObjectId=Get-QOdmId $object; Name=Get-QOdmName $object
            Workload=$workload; ObjectKind=$ObjectKind; WorkloadId=$script:QOdmState.WorkloadId
            Type=ConvertTo-QOdmDisplayString (Get-QOdmProperty $object @('SpmType','Type','ObjectType'))
            Status=ConvertTo-QOdmDisplayString (Get-QOdmProperty $object @('Status','State','MigrationStatus','MigrationState'))
            SourceUrl=[string](Get-QOdmProperty $object @('SourceUrl','SpmSourceUrl'))
            TargetUrl=[string](Get-QOdmProperty $object @('TargetUrl','SpmTargetUrl'))
            TargetName=[string](Get-QOdmProperty $object @('TargetName','WorkspaceTargetWorkspaceName','TargetGateway'))
            Owner=[string](Get-QOdmProperty $object @('SourceOwner','WorkspaceOwner'))
            WorkspaceId=[string](Get-QOdmProperty $object @('WorkspaceId'))
            CollectionName=''; TaskName=''
        }
    }
    [pscustomobject]@{Workload=$workload;ObjectKind=$ObjectKind;Rows=ConvertTo-QOdmObjectArray $items}
}

function Get-QOdmContentOptions {
    $workload = Get-QOdmContentWorkload
    $kinds = switch ($workload) { 'Teams' {@('Teams','Groups','Chats')} 'SharePoint' {@('SharePoint')} 'PowerBI' {@('Workspace','Gateway','Connection')} }
    $catalog = foreach ($spec in (Get-QOdmContentTaskCatalog | Where-Object {$_.Workload -eq $workload})) {
        $required = @('Name','ScheduledStartTime') + @($spec.Defaults.Keys)
        if ($spec.TemplateType) { $required += 'TemplateId' }
        if ($workload -eq 'PowerBI') { $required += @('Workspaces','DefaultAdminUser') }
        $available = @()
        if (Test-QOdmCommand -Name $spec.Command) { $available = @(Get-QOdmCommandParameterNames -CommandName $spec.Command) }
        $missing = @($required | Where-Object {$_ -notin $available})
        [pscustomobject]@{
            Key=$spec.Key;Name=$spec.Name;ObjectKind=$spec.ObjectKind;RequiresTemplate=[bool]$spec.TemplateType
            Available=($missing.Count -eq 0);Details=if($missing.Count){'Unavailable parameters: '+($missing -join ', ')}else{'Ready'}
            Settings=ConvertTo-Json -InputObject $spec.Defaults -Compress
        }
    }
    [pscustomobject]@{Workload=$workload;ObjectKinds=@($kinds);TaskKinds=@($catalog)}
}

function Assert-QOdmContentCommandContract {
    param([string]$CommandName,[string[]]$RequiredParameters)
    $available = @(Get-QOdmCommandParameterNames -CommandName $CommandName)
    foreach ($name in $RequiredParameters) {
        if ($name -notin $available) { throw "$CommandName is missing required parameter '$name'. No changes submitted." }
    }
}

function Test-QOdmContentTemplate {
    param([string]$TemplateId,[object]$Spec)
    if (-not $Spec.TemplateType) {
        if ($TemplateId) { throw 'The selected task uses explicit settings and does not accept a template.' }
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($TemplateId)) { throw 'Enter the exact Quest template ID for this migration task.' }
    # Do not use the legacy unscoped template fallback: an ID must belong to this project/workload.
    $templates = @(Invoke-QOdmSupportedCommandArray -CommandName 'Get-OdmTaskTemplates' -Parameters @{TemplateId=$TemplateId;All=$true} -RequiredParameters @('TemplateId','All'))
    if ($templates.Count -ne 1) { throw 'The template ID did not resolve to exactly one template.' }
    $template = $templates[0]
    $owner = [string](Get-QOdmProperty $template @('ProjectId'))
    if ($owner -notin @([string]$script:QOdmState.ProjectId,[string]$script:QOdmState.WorkloadId)) { throw 'The template is not owned by the selected project or workload.' }
    $values = [string](Get-QOdmProperty $template @('Values'))
    $settings = ConvertFrom-Json -InputObject $values -ErrorAction Stop
    if ([string](Get-QOdmProperty $settings @('type')) -ne $Spec.TemplateType) { throw "Template type does not match $($Spec.Name)." }
    return $settings
}

function Test-QOdmContentMembership {
    param([object]$Entity,[string]$ObjectKind,[string[]]$ObjectIds)
    # TypeOfTeam / TypeOfPowerBi must also be supplied during verification.
    for($attempt=1;$attempt -le 3;$attempt++) {
        $members = Get-QOdmContentObjects -ObjectKind $ObjectKind -Entity $Entity
        $ids = Get-QOdmContentIdSet -Entities $members
        $missing = @($ObjectIds | Where-Object {-not $ids.ContainsKey($_)})
        if (-not $missing.Count) { return }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    throw "Membership verification did not find $($missing.Count) expected object(s). Refresh Quest before retrying."
}

function Get-QOdmContentIdSet {
    param([AllowNull()][object]$Entities)
    $ids=@{}
    foreach($entity in (ConvertTo-QOdmObjectArray -InputObject $Entities)) {
        $id=Get-QOdmId $entity
        if($id){$ids[$id]=$true}
    }
    return $ids
}

function Invoke-QOdmContentCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$CsvPath,
        [Parameter(Mandatory=$true)][string]$ObjectKind,
        [ValidateSet('Collections','Tasks')][string]$Action='Collections',
        [string]$TaskKind,
        [string]$TemplateId,
        [string]$DefaultAdminUser,
        [bool]$LinkTasksToCollections=$true,
        [bool]$Execute=$false,
        [AllowNull()][string]$OutputDirectory
    )
    $workload = Get-QOdmContentWorkload
    if ($Execute) {
        Assert-QOdmWriteAllowed -Feature 'Membership'
        if ($Action -eq 'Tasks') { Assert-QOdmWriteAllowed -Feature 'ContentTasks' }
    }
    $null = Get-QOdmContentReadParameters -ObjectKind $ObjectKind
    $rows = ConvertTo-QOdmObjectArray (Import-QOdmCsv -Path $CsvPath)
    if ($rows.Count -eq 0) { throw 'The CSV contains no data rows.' }
    $requiredHeaders = @('CollectionName','ObjectId')
    if ($Action -eq 'Tasks') { $requiredHeaders += 'TaskName' }
    Assert-QOdmCsvHasAllHeaders -Headers (Get-QOdmCsvHeaders -Rows $rows) -RequiredHeaders $requiredHeaders
    $output = Get-QOdmOutputDirectory -OutputDirectory $OutputDirectory
    $reportPath = New-QOdmReportPath -OutputDirectory $output -BaseName ('Content{0}' -f $Action)
    $objectsById = @{}
    foreach ($object in (Get-QOdmContentObjects -ObjectKind $ObjectKind)) {
        $id = Get-QOdmId $object
        if ($id) {
            if ($objectsById.ContainsKey($id)) { throw "Inventory contains duplicate object ID '$id'." }
            $objectsById[$id] = $object
        }
    }
    $null = Update-QOdmCollectionCache
    $spec = $null
    $settings = @{}
    if ($Action -eq 'Tasks') {
        $specs = @(Get-QOdmContentTaskCatalog | Where-Object {$_.Key -eq $TaskKind -and $_.Workload -eq $workload -and $_.ObjectKind -eq $ObjectKind})
        if ($specs.Count -ne 1) { throw 'Choose a task kind that matches the active workload and object kind.' }
        $spec = $specs[0]
        $settings = Copy-QOdmHashtable $spec.Defaults
        $templateSettings = Test-QOdmContentTemplate -TemplateId $TemplateId -Spec $spec
        if ($spec.TemplateType) { $settings.TemplateId = $TemplateId }
        if ($workload -eq 'PowerBI') {
            if ([string]::IsNullOrWhiteSpace($DefaultAdminUser)) { throw 'Specify the default target Power BI administrator UPN.' }
            $settings.DefaultAdminUser = $DefaultAdminUser.Trim()
        }
        $required = @('Name','ScheduledStartTime') + @($settings.Keys)
        if ($workload -eq 'PowerBI') { $required += 'Workspaces' }
        Assert-QOdmContentCommandContract -CommandName $spec.Command -RequiredParameters $required
        $null = Update-QOdmTaskCache
    }
    Assert-QOdmContentCommandContract -CommandName 'Add-OdmObject' -RequiredParameters @('Objects','To')
    Assert-QOdmContentCommandContract -CommandName 'New-OdmCollection' -RequiredParameters @('Name')
    if ($Action -eq 'Tasks' -and $LinkTasksToCollections) {
        Assert-QOdmContentCommandContract -CommandName 'Add-OdmTask' -RequiredParameters @('Tasks','To')
    }

    # Validate every input before any API mutation. One bad row blocks the entire submission.
    $plan = [System.Collections.Generic.List[object]]::new()
    $groups = @{}
    $line = 1
    foreach ($row in $rows) {
        $line++
        $id = ([string](Get-QOdmProperty $row @('ObjectId'))).Trim()
        $collectionName = Normalize-QOdmName ([string](Get-QOdmProperty $row @('CollectionName')))
        $taskName = ([string](Get-QOdmProperty $row @('TaskName'))).Trim()
        $status = 'READY'; $details = ''
        $csvContext = ([string](Get-QOdmProperty $row @('WorkloadId'))).Trim()
        $csvKind = ([string](Get-QOdmProperty $row @('ObjectKind'))).Trim()
        if (-not $collectionName -or -not $id -or ($Action -eq 'Tasks' -and -not $taskName)) { $status='INVALID';$details='Required value is blank.' }
        elseif ($csvContext -and $csvContext -ne $script:QOdmState.WorkloadId) { $status='INVALID';$details='CSV WorkloadId differs from the active workload.' }
        elseif ($csvKind -and $csvKind -ne $ObjectKind) { $status='INVALID';$details='CSV ObjectKind differs from the selected object kind.' }
        elseif (-not $objectsById.ContainsKey($id)) { $status='INVALID';$details='Object ID was not found in the selected workload/object kind.' }
        $key = if ($Action -eq 'Tasks') { $taskName } else { $collectionName }
        if ($status -eq 'READY') {
            $collections = @($script:QOdmState.Collections.Values | Where-Object {(Get-QOdmName $_) -eq $collectionName})
            if ($collections.Count -gt 1) { $status='INVALID';$details='Collection name is ambiguous.' }
            if ($groups.ContainsKey($key) -and $groups[$key].CollectionName -ne $collectionName) { $status='INVALID';$details='One task name cannot refer to multiple collections.' }
            if ($status -eq 'READY') {
                if (-not $groups.ContainsKey($key)) {
                    $existingTasks = @()
                    if ($Action -eq 'Tasks') { $existingTasks = @($script:QOdmState.Tasks.Values | Where-Object {(Get-QOdmName $_) -eq $taskName}) }
                    if ($existingTasks.Count -gt 1) { $status='INVALID';$details='Task name is ambiguous.' }
                    $groups[$key] = [pscustomobject]@{CollectionName=$collectionName;TaskName=$taskName;Objects=@{};Rows=[System.Collections.Generic.List[object]]::new();ExistingTasks=$existingTasks}
                }
                $groups[$key].Objects[$id] = $objectsById[$id]
            }
        }
        $record = [pscustomobject]@{
            Row=$line;Workload=$workload;WorkloadId=$script:QOdmState.WorkloadId;ObjectKind=$ObjectKind
            ObjectId=$id;CollectionName=$collectionName;TaskName=$taskName;TaskKind=$TaskKind
            Settings=(ConvertTo-Json -InputObject $settings -Compress);CollectionId='';TaskId=''
            TemplateSettings=if($Action -eq 'Tasks' -and $null -ne $templateSettings){ConvertTo-Json -InputObject $templateSettings -Depth 30 -Compress}else{''}
            Status=$status;Details=$details;ReportPath=$reportPath
        }
        $plan.Add($record) | Out-Null
        if ($status -eq 'READY') { $groups[$key].Rows.Add($record) | Out-Null }
    }
    $invalid = @($plan | Where-Object {$_.Status -eq 'INVALID'})
    if ($invalid.Count) {
        foreach ($record in $plan) { if ($record.Status -eq 'READY') {$record.Status='BLOCKED';$record.Details='Fix invalid CSV rows before resubmitting.'} }
    }
    else {
        $null = Export-QOdmCsv -Rows $plan.ToArray() -Path $reportPath
        foreach ($key in @($groups.Keys | Sort-Object)) {
            $group = $groups[$key]
            $collection = $null; $task = $null
            $stage = 'Preflight'
            try {
                if ($Action -eq 'Tasks' -and $group.ExistingTasks.Count -gt 0) {
                    foreach ($record in $group.Rows) { $record.Status='SKIPPED_EXISTING';$record.TaskId=Get-QOdmId $group.ExistingTasks[0];$record.Details='Existing task left unchanged. Inspect its membership/settings before starting or retrying.' }
                    continue
                }
                if (-not $Execute) {
                    foreach ($record in $group.Rows) { $record.Status='PREVIEW';$record.Details='Validated. Execute creates/reuses the collection and, for Tasks, creates a held task with the selected objects.' }
                    continue
                }
                $stage = 'Collection creation'
                $null = Update-QOdmCollectionCache
                $matches = @($script:QOdmState.Collections.Values | Where-Object {(Get-QOdmName $_) -eq $group.CollectionName})
                if ($matches.Count -gt 1) { throw 'Collection name became ambiguous after preview.' }
                if ($matches.Count -eq 1) { $collection=$matches[0] }
                else {
                    $before = Get-QOdmContentIdSet -Entities $script:QOdmState.Collections.Values
                    $created = Invoke-QOdmSupportedCommandArray -CommandName 'New-OdmCollection' -Parameters @{Name=$group.CollectionName} -RequiredParameters @('Name')
                    $collection = Resolve-QOdmCreatedEntityAfterWrite -EntityType Collection -Name $group.CollectionName -ExistingIds $before -ReturnedObjects $created
                }
                foreach ($record in $group.Rows) {$record.CollectionId=Get-QOdmId $collection}
                $stage = 'Collection membership'
                $present = Get-QOdmContentIdSet -Entities (Get-QOdmContentObjects -ObjectKind $ObjectKind -Entity $collection)
                $pending = @($group.Objects.Values | Where-Object {-not $present.ContainsKey((Get-QOdmId $_))})
                if ($pending.Count) { $null = Add-QOdmObjectsToEntity -Entity $collection -Objects $pending }
                Test-QOdmContentMembership -Entity $collection -ObjectKind $ObjectKind -ObjectIds @($group.Objects.Keys)
                if ($Action -eq 'Tasks') {
                    $stage = 'Task creation'
                    $null = Update-QOdmTaskCache
                    if (@($script:QOdmState.Tasks.Values | Where-Object {(Get-QOdmName $_) -eq $group.TaskName}).Count) { throw 'Task name now exists. Task creation stopped.' }
                    $before = Get-QOdmContentIdSet -Entities $script:QOdmState.Tasks.Values
                    $parameters = Copy-QOdmHashtable $settings
                    $parameters.Name = $group.TaskName
                    $parameters.ScheduledStartTime = $null
                    if ($workload -eq 'PowerBI') { $parameters.Workspaces = @($group.Objects.Values) }
                    $returned = Invoke-QOdmSupportedCommandArray -CommandName $spec.Command -Parameters $parameters -RequiredParameters @($parameters.Keys)
                    $task = Resolve-QOdmCreatedEntityAfterWrite -EntityType Task -Name $group.TaskName -ExistingIds $before -ReturnedObjects $returned
                    foreach ($record in $group.Rows) {$record.TaskId=Get-QOdmId $task}
                    $stage = 'Task membership'
                    if ($workload -ne 'PowerBI') { $null = Add-QOdmObjectsToEntity -Entity $task -Objects @($group.Objects.Values) }
                    Test-QOdmContentMembership -Entity $task -ObjectKind $ObjectKind -ObjectIds @($group.Objects.Keys)
                    if ($LinkTasksToCollections) {
                        $stage = 'Task collection link'
                        $null = Add-QOdmTasksToCollection -Tasks @($task) -Collection $collection
                        $link = Test-QOdmTaskCollectionLink -Collection $collection -Tasks @($task)
                        if (-not $link.Verified) { throw 'The task-to-collection link could not be verified.' }
                    }
                }
                foreach ($record in $group.Rows) { $record.Status='VERIFIED';$record.Details='Collection membership verified. Any created task remains held for review in Tasks.' }
            }
            catch {
                foreach ($record in $group.Rows) { $record.Status='REVIEW_REQUIRED';$record.Details="$stage failed: $($_.Exception.Message) Prior writes may have completed; review IDs and Quest state before retrying." }
            }
            finally { $null = Export-QOdmCsv -Rows $plan.ToArray() -Path $reportPath }
        }
    }
    $null = Export-QOdmCsv -Rows $plan.ToArray() -Path $reportPath
    $status = if($invalid.Count){'VALIDATION_FAILED'}elseif(@($plan | Where-Object {$_.Status -eq 'REVIEW_REQUIRED'}).Count){'REVIEW_REQUIRED'}elseif($Execute){'COMPLETED'}else{'PREVIEW'}
    [pscustomobject]@{Status=$status;Execute=$Execute;Rows=$plan.ToArray();ReportPath=$reportPath;Settings=$settings;TasksStarted=0}
}
