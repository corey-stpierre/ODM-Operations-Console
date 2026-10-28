Set-StrictMode -Version 2.0

$engineRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:QOdmEngineRoot = $engineRoot
$script:QOdmAppRoot = Split-Path -Parent $engineRoot
foreach ($file in @('Common.ps1','Governance.ps1','Context.ps1','Inventory.ps1','Membership.ps1','Accounts.ps1','Bulk.ps1','TaskFactory.ps1','Workloads.ps1','OperationsCenter.ps1','Management.ps1','ActiveDirectory.ps1','LocalPreflight.ps1')) {
    $path = Join-Path -Path $engineRoot -ChildPath $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Quest ODM engine component not found: $path" }
    . $path
}
Initialize-QOdmState

function Get-QOdmWorkspaceSnapshot {
    [CmdletBinding()]
    param([bool]$Refresh = $true)

    Assert-QOdmWorkloadSelected
    Set-QOdmOperationPhase -Phase 'Refreshing dashboard inventory'
    $dashboard = Get-QOdmDashboard -Refresh $Refresh
    $tasks = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmTasksView -Refresh $false)
    $collections = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCollectionsView -Refresh $false)
    $templates = @()
    try {
        Set-QOdmOperationPhase -Phase 'Refreshing task-template inventory'
        $templates = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmTemplatesView -Refresh $Refresh)
    }
    catch {
        Add-QOdmWarning -Message ("Task templates could not be loaded; the rest of the workspace remains available. {0}" -f $_.Exception.Message)
    }
    $statuses = ConvertTo-QOdmObjectArray -InputObject ($tasks | ForEach-Object { Get-QOdmProperty -InputObject $_ -Names @('Status') } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    Set-QOdmOperationPhase -Phase 'Workspace ready'

    [pscustomobject]@{
        Dashboard    = $dashboard
        Tasks        = $tasks
        Collections  = $collections
        Templates    = $templates
        TaskStatuses = $statuses
        Warnings     = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmOperationWarnings)
    }
}

function Get-QOdmOperationCatalog {
    [CmdletBinding()]
    param()

    @(
        [pscustomobject]@{Key='DiscoverAllAccounts';Name='Discover all accounts';NeedsCsv=$false;SupportsExecute=$true;NeedsTaskName=$true;SupportsStart=$true;TemplateKey=$null;Description='Creates a Quest Accounts discovery task for all supported source accounts.'},
        [pscustomobject]@{Key='DiscoverAccountsFromCsv';Name='Discover accounts from Quest CSV';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$true;SupportsStart=$true;TemplateKey='AccountDiscoveryByUPN';Description='Creates a Quest discovery task from a UserPrincipalName/Type or ObjectId/Type CSV.'},
        [pscustomobject]@{Key='MapAccountsFromCsv';Name='Match/map accounts from Quest CSV';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$true;SupportsStart=$true;TemplateKey='AccountMappingByUPN';Description='Creates a Quest Account Mapping from File task using UPN or object-ID mapping columns.'},
        [pscustomobject]@{Key='CreateCollectionsAndAddUsers';Name='Create collections and add users';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='CSV: CollectionName plus any supported source identity column.'},
        [pscustomobject]@{Key='RemoveUsersFromCollections';Name='Remove users from collections';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='CSV: CollectionName plus any supported source identity column.'},
        [pscustomobject]@{Key='RemoveCollections';Name='Remove collections from CSV';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='CSV: CollectionName or CollectionId.'},
        [pscustomobject]@{Key='FindUserCollections';Name='Find user collection memberships';NeedsCsv=$true;SupportsExecute=$false;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='Produces membership, removal-plan, unresolved-user, and read-error reports.'},
        [pscustomobject]@{Key='FindUserTasks';Name='Find user task memberships';NeedsCsv=$true;SupportsExecute=$false;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='Produces membership, removal-plan, unresolved-user, and read-error reports.'},
        [pscustomobject]@{Key='MatchObjectInfo';Name='Match CSV users to ODM objects';NeedsCsv=$true;SupportsExecute=$false;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='Uses SourceEmail by default and exports matched/not-found reports.'},
        [pscustomobject]@{Key='RemoveUsersFromTasksPlan';Name='Apply task removal plan';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='CSV: TaskId or TaskName plus ObjectId or a supported source identity column.'},
        [pscustomobject]@{Key='StartTasksFromCsv';Name='Start tasks from CSV';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$false;SupportsStart=$false;TemplateKey='TaskReferences';Description='CSV: TaskId or TaskName. Dry run is the default.'},
        [pscustomobject]@{Key='StopTasksFromCsv';Name='Stop tasks from CSV';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$false;SupportsStart=$false;TemplateKey='TaskReferences';Description='CSV: TaskId or TaskName. Only stoppable task states are submitted.'},
        [pscustomobject]@{Key='DeleteTasksFromCsv';Name='Delete tasks from CSV';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$false;SupportsStart=$false;TemplateKey='TaskReferences';Description='CSV: TaskId or TaskName. Duplicate names are rejected; eligible live tasks can be stopped first.'},
        [pscustomobject]@{Key='DeleteTasksAcrossProjects';Name='Delete tasks across projects from CSV';NeedsCsv=$true;SupportsExecute=$true;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='CSV: ProjectId or workload ID plus TaskName or TaskId. The original context is restored and verified.'},
        [pscustomobject]@{Key='DeleteAllTasks';Name='Delete all tasks in selected workload';NeedsCsv=$false;SupportsExecute=$true;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description="Execution requires the exact text 'DELETE ALL ODM TASKS'."},
        [pscustomobject]@{Key='ExportTasks';Name='Export task inventory';NeedsCsv=$false;SupportsExecute=$false;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='Exports the current workload, or all project/workload contexts when selected.'},
        [pscustomobject]@{Key='ExportCollections';Name='Export collection inventory';NeedsCsv=$false;SupportsExecute=$false;NeedsTaskName=$false;SupportsStart=$false;TemplateKey=$null;Description='Exports collections and optional object/task counts.'}
    )
}

function Get-QOdmReportsFromData {
    [CmdletBinding()]
    param([AllowNull()][object]$Data)

    if ($null -eq $Data) { return @() }
    $reports = [System.Collections.Generic.List[string]]::new()
    $propertyNames = @(
        'Reports','ReportPath','AssignmentPath','SummaryPath','MembershipPath','MembershipReportPath',
        'RemovalPlanPath','MatchedPath','NotFoundPath','UnresolvedPath','SkippedPath','ReadErrorPath',
        'ReadErrorsPath','LogPath','JsonPath','HtmlPath','BundlePath','EventCsvPath','HistoryPath'
    )
    foreach ($propertyName in $propertyNames) {
        $values = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmProperty -InputObject $Data -Names @($propertyName) -Default @())
        foreach ($value in $values) {
            $path = [string]$value
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            if (-not $reports.Contains($path)) { $reports.Add($path) | Out-Null }
        }
    }
    return $reports.ToArray()
}

function Get-QOdmMembershipMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Data,
        [Parameter(Mandatory = $true)][string]$SuccessText,
        [Parameter(Mandatory = $true)][string]$NotVerifiedText
    )

    $state = [string](Get-QOdmProperty -InputObject $Data -Names @('VerificationState','VerificationStatus') -Default 'NOT_VERIFIED')
    switch ($state) {
        'VERIFIED'                { return $SuccessText }
        'VERIFIED_PRESENT'        { return $SuccessText }
        'VERIFIED_ABSENT'         { return $SuccessText }
        'VERIFICATION_READ_FAILED' { return 'The Quest API change completed, but the verification read failed. Refresh the entity and review the operation details before another write.' }
        'READ_FAILED'             { return 'The Quest API change completed, but the verification read failed. Refresh the entity and review the operation details before another write.' }
        default                   { return $NotVerifiedText }
    }
}

function Invoke-QOdmOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [AllowNull()][System.Collections.IDictionary]$Parameters = $null
    )

    $started = Get-Date
    $arguments = Copy-QOdmHashtable -InputHashtable $Parameters
    Start-QOdmOperationScope -Operation $Operation
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    $result = $null

    try {
        Assert-QOdmOperationAllowed -Operation $Operation -Parameters $arguments
        $data = $null
        $message = $null
        switch ($Operation) {
            'OpenActiveDirectory' { $data=Open-QOdmActiveDirectory; $message='Active Directory workspace opened in Safe Mode.' }
            'AdInventory' { $data=Get-QOdmAdInventoryView @arguments; $message=$data.Note }
            'AdDefinition' { $data=Get-QOdmAdDefinition @arguments; $message='AD action fields loaded.' }
            'AdAction' { $data=Invoke-QOdmAdAction @arguments; $message="Active Directory: $($data.Plan.Status)." }
            'ManagementView' { $data=Get-QOdmManagementView @arguments; $message='Management inventory loaded.' }
            'Management' { $data=Invoke-QOdmManagement @arguments; $message="Management: $($data.Plan.Status)." }
            'OperationsCatalog' { $data=ConvertTo-QOdmObjectArray (Get-QOdmOperationsCatalog); $message='Workload operation catalog loaded.' }
            'OperationsDefinition' { $data=Get-QOdmOperationsDefinition @arguments; $message='Operation fields loaded.' }
            'OperationsInventory' { $data=Get-QOdmOperationsInventoryView @arguments; $message='Inventory loaded.' }
            'OperationsTask' { $data=Invoke-QOdmOperationsTask @arguments; $message="Operation: $($data.Plan.Status)." }
            'ContentOptions' {
                $data = Get-QOdmContentOptions
                $message = 'Workload options loaded.'
            }
            'ContentInventory' {
                $data = Get-QOdmContentInventory @arguments
                $message = 'Workload object inventory loaded.'
            }
            'ContentCsv' {
                $data = Invoke-QOdmContentCsv @arguments
                $message = "Workload CSV result: $($data.Status)."
            }
            'Connect' {
                $data = Connect-QOdmConsole @arguments
                $message = 'Connected to Quest On Demand.'
            }
            'Disconnect' {
                $data = Disconnect-QOdmConsole
                $message = 'Disconnected from Quest On Demand.'
            }
            'GetState' {
                $data = Get-QOdmContextState
                $message = 'Context state returned.'
            }
            'GetEnvironment' {
                $data = Get-QOdmEnvironmentInfo
                $message = 'Environment information returned.'
            }
            'GetBuildInfo' {
                $data = Get-QOdmBuildInfo
                $message = 'Build information returned.'
            }
            'GetCompatibilityPolicy' {
                $data = Get-QOdmCompatibilityPolicy @arguments
                $message = 'OdmApi compatibility policy returned.'
            }
            'GetCompatibilityAssessment' {
                $moduleStatus = Get-QOdmApiModuleStatus -CheckOnline ([bool](Get-QOdmProperty -InputObject $arguments -Names @('CheckOnline') -Default $false))
                $data = Get-QOdmCompatibilityAssessment -ModuleStatus $moduleStatus
                $message = 'OdmApi compatibility assessment returned.'
            }
            'GetOdmApiModuleStatus' {
                $data = Get-QOdmApiModuleStatus @arguments
                $message = 'OdmApi module status returned.'
            }
            'InstallOdmApiModule' {
                $data = Install-QOdmApiModule @arguments
                $message = [string](Get-QOdmProperty -InputObject $data -Names @('Details') -Default 'OdmApi module action completed.')
            }
            'TestApiSurface' {
                $data = Get-QOdmApiSurfaceReport @arguments
                $message = 'OdmApi command-surface assessment completed.'
            }
            'GetSafeModeState' {
                $data = Get-QOdmSafeModeState
                $message = 'Safe Mode state returned.'
            }
            'SetSafeMode' {
                $enabled = [bool](Get-QOdmProperty -InputObject $arguments -Names @('Enabled') -Default $true)
                if ($enabled) {
                    $reason = [string](Get-QOdmProperty -InputObject $arguments -Names @('Reason') -Default 'Safe Mode enabled by the operator.')
                    $data = Enable-QOdmSafeMode -Reason $reason
                    $message = 'Safe Mode enabled.'
                }
                else {
                    $data = Disable-QOdmSafeMode `
                        -OrganizationId ([string](Get-QOdmProperty -InputObject $arguments -Names @('OrganizationId'))) `
                        -ProjectId ([string](Get-QOdmProperty -InputObject $arguments -Names @('ProjectId'))) `
                        -WorkloadId ([string](Get-QOdmProperty -InputObject $arguments -Names @('WorkloadId'))) `
                        -ConfirmationText ([string](Get-QOdmProperty -InputObject $arguments -Names @('ConfirmationText')))
                    $message = 'Changes enabled for the active Quest context.'
                }
            }
            'RunReadinessCheck' {
                $data = Invoke-QOdmReadinessCheck @arguments
                $message = "Readiness check completed: $($data.Summary.OverallStatus)."
            }
            'GetOperationHistory' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmOperationHistory @arguments)
                $message = 'Operation history returned.'
            }
            'CreateSupportBundle' {
                $data = New-QOdmSupportBundle @arguments
                $message = 'Sanitized support bundle created.'
            }
            'GetOperationCatalog' {
                $data = Get-QOdmOperationCatalog
                $message = 'Operation catalog returned.'
            }
            'SelectOrganization' {
                $data = Select-QOdmOrganizationContext @arguments
                $message = 'Organization selected.'
            }
            'SelectProject' {
                $data = Select-QOdmProjectContext @arguments
                $message = 'Project selected.'
            }
            'SelectWorkload' {
                $data = Select-QOdmWorkloadContext @arguments
                $message = 'Workload selected.'
            }
            'WorkspaceSnapshot' {
                $data = Get-QOdmWorkspaceSnapshot @arguments
                $message = 'Workspace refreshed.'
            }
            'Dashboard' {
                $data = Get-QOdmDashboard @arguments
                $message = 'Dashboard refreshed.'
            }
            'SearchObjects' {
                $data = Get-QOdmObjectsView @arguments
                $message = 'Object search completed.'
            }
            'GetTasks' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmTasksView @arguments)
                $message = 'Tasks returned.'
            }
            'GetTaskDetails' {
                $data = Get-QOdmTaskDetails @arguments
                $message = 'Task details returned.'
            }
            'ExportTaskDetails' {
                $data = Export-QOdmTaskDetails @arguments
                $message = 'Task details exported.'
            }
            'CreateTaskErrorLogExport' {
                $data = New-QOdmTaskErrorLogExport @arguments
                $message = 'Quest task error-log export task created.'
            }
            'GetCollections' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCollectionsView @arguments)
                $message = 'Collections returned.'
            }
            'GetTemplates' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmTemplatesView @arguments)
                $message = 'Task templates returned.'
            }
            'GetTaskMembers' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmTaskMembers @arguments)
                $message = 'Task members returned.'
            }
            'GetCollectionMembers' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Get-QOdmCollectionMembers @arguments)
                $message = 'Collection members returned.'
            }
            'FindObjectAssociations' {
                $data = Find-QOdmObjectAssociations @arguments
                $message = 'Object associations returned.'
            }
            'AddObjectToTask' {
                $data = Add-QOdmObjectToTask @arguments
                $message = Get-QOdmMembershipMessage -Data $data -SuccessText 'Object added to task and verified.' -NotVerifiedText 'The add command completed, but task membership was not verified.'
            }
            'RemoveObjectFromTask' {
                $data = Remove-QOdmObjectFromTask @arguments
                $message = Get-QOdmMembershipMessage -Data $data -SuccessText 'Object removed from task and verified.' -NotVerifiedText 'The remove command completed, but task membership was not verified.'
            }
            'AddObjectToCollection' {
                $data = Add-QOdmObjectToCollection @arguments
                $message = Get-QOdmMembershipMessage -Data $data -SuccessText 'Object added to collection and verified.' -NotVerifiedText 'The add command completed, but collection membership was not verified.'
            }
            'RemoveObjectFromCollection' {
                $data = Remove-QOdmObjectFromCollection @arguments
                $message = Get-QOdmMembershipMessage -Data $data -SuccessText 'Object removed from collection and verified.' -NotVerifiedText 'The remove command completed, but collection membership was not verified.'
            }
            'NewCollection' {
                $data = New-QOdmCollection @arguments
                $message = 'Collection created and resolved.'
            }
            'DeleteCollections' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Remove-QOdmCollections @arguments)
                $deleted = (ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $data) | Where-Object { [bool](Get-QOdmProperty -InputObject $_ -Names @('Deleted') -Default $false) })).Count
                $message = "Collection deletion completed: $deleted deleted, $((Get-QOdmSafeCount -Value $data) - $deleted) not deleted."
            }
            'StartTasks' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Start-QOdmTasks @arguments)
                $submitted = (ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $data) | Where-Object { [bool](Get-QOdmProperty -InputObject $_ -Names @('StartSucceeded') -Default $false) })).Count
                $message = "Task start processing completed: $submitted submitted, $((Get-QOdmSafeCount -Value $data) - $submitted) skipped or failed."
            }
            'StopTasks' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Stop-QOdmTasks @arguments)
                $submitted = (ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $data) | Where-Object { [bool](Get-QOdmProperty -InputObject $_ -Names @('StopSucceeded') -Default $false) })).Count
                $message = "Task stop processing completed: $submitted submitted, $((Get-QOdmSafeCount -Value $data) - $submitted) skipped or failed."
            }
            'DeleteTasks' {
                $data = ConvertTo-QOdmObjectArray -InputObject (Remove-QOdmTasks @arguments)
                $deleted = (ConvertTo-QOdmObjectArray -InputObject ((ConvertTo-QOdmObjectArray -InputObject $data) | Where-Object { [bool](Get-QOdmProperty -InputObject $_ -Names @('Deleted') -Default $false) })).Count
                $message = "Task deletion completed: $deleted deleted, $((Get-QOdmSafeCount -Value $data) - $deleted) not deleted."
            }
            'AddUsersToEntityFromCsv' {
                $data = Add-QOdmUsersToEntityFromCsv @arguments
                $message = 'CSV add operation completed.'
            }
            'RemoveUsersFromEntityFromCsv' {
                $data = Remove-QOdmUsersFromEntityFromCsv @arguments
                $message = 'CSV removal operation completed.'
            }
            'TaskFactory' {
                $data = Invoke-QOdmTaskFactory @arguments
                $message = if ([bool](Get-QOdmProperty -InputObject $data -Names @('Execute') -Default $false)) { 'Task Factory execution completed.' } else { 'Task Factory preview completed.' }
            }
            'Bulk' {
                $bulkOperation = [string](Get-QOdmProperty -InputObject $arguments -Names @('Operation'))
                if ([string]::IsNullOrWhiteSpace($bulkOperation)) { throw 'Bulk operation name is required.' }
                $nested = Get-QOdmProperty -InputObject $arguments -Names @('Parameters') -Default @{}
                if ($nested -isnot [System.Collections.IDictionary]) { throw 'Bulk Parameters must be a hashtable or dictionary.' }
                $data = Invoke-QOdmBulkOperation -Operation $bulkOperation -Parameters $nested
                $message = "Bulk operation '$bulkOperation' completed."
            }
            'TestMmpcFlag' {
                $data = Get-QOdmMmpcEnrollmentFlagState
                $message = 'Registry preflight check completed.'
            }
            'RemoveMmpcFlag' {
                $data = Remove-QOdmMmpcEnrollmentFlag @arguments
                $message = 'Registry preflight action completed.'
            }
            default { throw "Unknown engine operation: $Operation" }
        }

        $elapsed = (Get-Date) - $started
        $result = New-QOdmOperationResult -Operation $Operation -Success $true -Data $data -Message $message -Error $null `
            -Details ("Elapsed: {0:n1} seconds" -f $elapsed.TotalSeconds) -Reports (Get-QOdmReportsFromData -Data $data) `
            -Warnings (Get-QOdmOperationWarnings) -Diagnostic $null
    }
    catch {
        $elapsed = (Get-Date) - $started
        $phase = [string](Get-QOdmProperty -InputObject $script:QOdmState -Names @('CurrentPhase') -Default 'Unknown')
        $diagnostic = New-QOdmErrorDiagnostic -ErrorRecord $_ -Operation $Operation -Phase $phase
        $details = "Elapsed: {0:n1} seconds`r`n{1}" -f $elapsed.TotalSeconds, (Format-QOdmDiagnosticText -Diagnostic $diagnostic)
        $result = New-QOdmOperationResult -Operation $Operation -Success $false -Data $null -Message 'The operation failed.' `
            -Error $_.Exception.Message -Details $details -Reports @() -Warnings (Get-QOdmOperationWarnings) -Diagnostic $diagnostic
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    try { Write-QOdmOperationHistory -Operation $Operation -Parameters $arguments -Result $result -StartedAt $started -EndedAt (Get-Date) }
    catch { }
    return $result
}

Export-ModuleMember -Function Invoke-QOdmOperation
