@{
    RootModule = 'OdmApi.psm1'
    ModuleVersion = '2.1.396'
    GUID = '26cf6c46-37b8-42bd-b9f5-5edbd5bbcc6b'
    Author = 'Quest ODM Console test fixture'
    Description = 'Offline OdmApi contract mock for Quest ODM Console regression tests.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Set-MockContentScenario','New-OdmTeamsProvisionTask','New-OdmTeamsMigrationTask','New-OdmTeamsCollectStatisticsTask','New-OdmTeamsGroupsProvisionTask','New-OdmTeamsGroupMigrationTask','New-OdmTeamsChatMigrationTask','New-OdmSPMigrationTask','New-OdmSPDiscoverSharePointContentsTask','New-OdmPbiProvisionWorkspacesTask','New-OdmPbiMigrateWorkspacesTask',
        'Connect-OdmService','Disconnect-OdmService','Get-OdmOrganizations','Get-OdmActiveOrganizations','Select-OdmOrganization',
        'Set-MockOrganizationMode','Get-OdmProject','Select-OdmProject','Get-OdmProjectWorkload','Select-OdmProjectWorkload',
        'Get-OdmObject','Get-OdmTask','Get-OdmCollection','Get-OdmTaskTemplates',
        'Add-OdmObject','Remove-OdmObject','New-OdmCollection','Remove-OdmCollection','Remove-OdmTask',
        'Start-OdmTask','Stop-OdmTask','Add-OdmTask','New-OdmMailMigrationTask','New-OdmOneDriveMigrationTask',
        'New-OdmMeetingLinkMigrationTask','New-OdmMailSwitchTask','New-OdmDiscoveryTask','New-OdmMappingFileTask',
        'Get-OdmRoleAssignments','Get-OdmRoles','Get-EffectiveMigrationSubscription','Test-ActiveMigrationSubscription',
        'Get-OdmEvent','Get-OdmReporting','Get-OdmReportInfo','Get-OdmReport','New-OdmReportingErrorLogsExportTask','Get-MockOdmState'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
