function Set-MockContentScenario {
    $script:ContentScenario=$true
    $script:Collections.Clear()
    $script:Tasks.Clear()
    $script:Workloads = @('Teams','SharePoint','PowerBI') | ForEach-Object { [pscustomobject]@{Id="content-$_";Name=$_;WorkloadType=$_;ParentProjectId='project-001'} }
    $script:Objects = foreach($pair in @('Teams:Teams','Teams:Groups','Teams:Chats','SharePoint:SharePoint','PowerBI:Workspace','PowerBI:Gateway','PowerBI:Connection')) {
        $workload,$kind=$pair.Split(':')
        foreach($number in 1,2) { [pscustomobject]@{Id="$kind-$number";Name="Same name $number";DisplayName="Same name $number";ProjectId="content-$workload";Kind=$kind;FailWrites=$false;Type=$kind;SourceUrl='https://source.example/sites/test';TargetUrl='https://target.example/sites/test'} }
    }
    $script:Templates = foreach($pair in @('Teams:migrateteams','Teams:migrategroups','Teams:migratechats','SharePoint:MigrateSharePointContents')) {
        $workload,$type=$pair.Split(':')
        [pscustomobject]@{Id="template-$type";Name="$type template";ProjectId="content-$workload";Values=('{"type":"'+$type+'","Run":"now"}')}
    }
}
function New-MockContentTask {
    param($Name,$Type,$ScheduledStartTime,$Workspaces)
    if($null -ne $ScheduledStartTime){throw 'Tasks must be held.'}
    $task=New-MockTask -Name $Name -Type $Type
    $task | Add-Member -NotePropertyName Run -NotePropertyValue 'later'
    if($null -ne $Workspaces) {
        Add-OdmObject -To $task -Objects $Workspaces
        # Power BI constructors do not reliably emit the created task.
        return
    }
    $task
}
function New-OdmTeamsProvisionTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$ProvisionNewOrExistingTeam,$ProvisionNewOrExistingChannel,$NewTeamSuffix,$NewChannelSuffix)
    New-MockContentTask -Name $Name -Type provisionteams -ScheduledStartTime $ScheduledStartTime
}
function New-OdmTeamsMigrationTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$TemplateId)
    New-MockContentTask -Name $Name -Type migrateteams -ScheduledStartTime $ScheduledStartTime
}
function New-OdmTeamsCollectStatisticsTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$DiscoveryOption,$StatisticsCollectType,$CollectStatisticsFromTargetTenant)
    New-MockContentTask -Name $Name -Type collectstatistics -ScheduledStartTime $ScheduledStartTime
}
function New-OdmTeamsGroupsProvisionTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$ProvisionNewOrExistingGroup)
    New-MockContentTask -Name $Name -Type provisiongroups -ScheduledStartTime $ScheduledStartTime
}
function New-OdmTeamsGroupMigrationTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$TemplateId)
    New-MockContentTask -Name $Name -Type migrategroups -ScheduledStartTime $ScheduledStartTime
}
function New-OdmTeamsChatMigrationTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$TemplateId)
    New-MockContentTask -Name $Name -Type migratechats -ScheduledStartTime $ScheduledStartTime
}
function New-OdmSPMigrationTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$TemplateId)
    New-MockContentTask -Name $Name -Type MigrateSharePointContents -ScheduledStartTime $ScheduledStartTime
}
function New-OdmSPDiscoverSharePointContentsTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$CollectFormWorkflowStatistics)
    New-MockContentTask -Name $Name -Type DiscoverSharePointContents -ScheduledStartTime $ScheduledStartTime
}
function New-OdmPbiProvisionWorkspacesTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$Workspaces,$DefaultAdminUser,$ConflictResolution,$SetTargetAdminUser,$SetTargetAdminUserOption,$UpdateTargetWorkspacePermissions,$UpdateTargetWorkspacePermissionsOption)
    New-MockContentTask -Name $Name -Type ProvisionWorkspaces -ScheduledStartTime $ScheduledStartTime -Workspaces $Workspaces
}
function New-OdmPbiMigrateWorkspacesTask {
    [CmdletBinding()]param($Name,$ScheduledStartTime,$Workspaces,$DefaultAdminUser,$IncrementalMigration,$UpdateTargetWorkspaceContentPermissions,$UpdateTargetWorkspaceContentPermissionsOption,$Priority)
    New-MockContentTask -Name $Name -Type MigrateWorkspaces -ScheduledStartTime $ScheduledStartTime -Workspaces $Workspaces
}
Export-ModuleMember -Function Set-MockContentScenario,New-OdmTeamsProvisionTask,New-OdmTeamsMigrationTask,New-OdmTeamsCollectStatisticsTask,New-OdmTeamsGroupsProvisionTask,New-OdmTeamsGroupMigrationTask,New-OdmTeamsChatMigrationTask,New-OdmSPMigrationTask,New-OdmSPDiscoverSharePointContentsTask,New-OdmPbiProvisionWorkspacesTask,New-OdmPbiMigrateWorkspacesTask
