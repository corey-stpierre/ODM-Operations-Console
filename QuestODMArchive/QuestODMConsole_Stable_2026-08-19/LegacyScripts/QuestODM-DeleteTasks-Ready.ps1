<#
.SYNOPSIS
Remove Quest ODM for 365 tasks from a CSV using project context.

.DESCRIPTION
- Reads a CSV with required columns: TaskName, ProjectId
- ProjectName is optional and used for logging only
- Connects to Quest ODM
- Selects the correct ODM project before each delete batch
- Loads tasks inside that selected project context
- Matches by TaskName (or TaskId if the CSV also includes TaskId)
- Removes matching tasks using the exact OdmApi signature: Remove-OdmTask -Tasks ... -Confirm $false
- Writes a results CSV beside the input CSV

.NOTES
- Best run in Windows PowerShell 5.1
- If started in PowerShell 7+, it relaunches in powershell.exe
- If the same TaskName exists multiple times inside the same project and TaskId is not supplied,
  all exact-name matches in that project are removed.

.CSV FORMAT
TaskName,ProjectName,ProjectId
AB01 - Email Sync,SRCL to WM,6T9sNpcB5WJXsN2w05Wk
AB02 - Email Sync,SRCL to WM,6T9sNpcB5WJXsN2w05Wk

.Optional more precise CSV format
TaskName,ProjectName,ProjectId,TaskId
AB01 - Email Sync,SRCL to WM,6T9sNpcB5WJXsN2w05Wk,aR807JsB9y-BY1HeyFfX

.EXAMPLE
.\QuestODM-DeleteTasks.ps1 `
  -Region US `
  -OrganizationId "00759f6f-8b29-0576-c0ee-266b5c0cf06b" `
  -CsvPath "C:\Temp\TasksToRemove.csv" `
  -WhatIf

.EXAMPLE
.\QuestODM-DeleteTasks.ps1 `
  -Region US `
  -OrganizationId "00759f6f-8b29-0576-c0ee-266b5c0cf06b" `
  -CsvPath "C:\Temp\TasksToRemove.csv" `
  -Confirm:$false
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Region = "us",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [Guid]$OrganizationId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Relaunch in Windows PowerShell if started in PowerShell 7+
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $env:ODM_DELETE_RELAUNCHED_WINPS) {
    $env:ODM_DELETE_RELAUNCHED_WINPS = '1'

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-Region', $Region,
        '-OrganizationId', $OrganizationId.ToString(),
        '-CsvPath', $CsvPath
    )

    if ($WhatIfPreference) {
        $argList += '-WhatIf'
    }

    if ($PSBoundParameters.ContainsKey('Confirm') -and $ConfirmPreference -eq 'None') {
        $argList += '-Confirm:$false'
    }

    Write-Host "Detected PowerShell $($PSVersionTable.PSVersion). Relaunching in Windows PowerShell (powershell.exe)..." -ForegroundColor Yellow
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru
    exit $proc.ExitCode
}

function Require-Cmdlet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing cmdlet '$Name'. Ensure the OdmApi module is installed/imported."
    }
}

function Normalize-Text {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return '' }
    return (($Value.ToString() -replace '\s+', ' ').Trim())
}

function Get-PropValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Obj,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $Obj) { return $null }

    foreach ($name in $Names) {
        $prop = $Obj.PSObject.Properties[$name]
        if ($null -ne $prop) {
            return $prop.Value
        }

        try {
            $value = $Obj.$name
            if ($null -ne $value) {
                return $value
            }
        }
        catch {}
    }

    return $null
}

function Get-AllProjects {
    $cmd = Get-Command Get-OdmProject -ErrorAction Stop

    if ($cmd.Parameters.ContainsKey('All')) {
        return @(Get-OdmProject -All)
    }

    return @(Get-OdmProject)
}

function Select-ProjectContext {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Project
    )

    $selectCmd = Get-Command Select-OdmProject -ErrorAction Stop

    if ($selectCmd.Parameters.ContainsKey('Project')) {
        Select-OdmProject -Project $Project | Out-Null
        return
    }

    $projectIdValue = Normalize-Text (Get-PropValue -Obj $Project -Names @('Id','ID','ProjectId'))
    if ([string]::IsNullOrWhiteSpace($projectIdValue)) {
        throw 'Project object does not contain a usable Id/ProjectId value.'
    }

    Select-OdmProject -ProjectId $projectIdValue | Out-Null
}

function Get-TasksForCurrentProject {
    $cmd = Get-Command Get-OdmTask -ErrorAction Stop

    if ($cmd.Parameters.ContainsKey('All')) {
        return @(Get-OdmTask -All)
    }

    return @(Get-OdmTask)
}

function Stop-TaskIfRunning {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Task
    )

    $status = Normalize-Text (Get-PropValue -Obj $Task -Names @('Status','State'))
    $runningStates = @('In Progress','Starting','Stopping','Queued','Running')

    if ($runningStates -notcontains $status) {
        return
    }

    try {
        Stop-OdmTask -Tasks @($Task) -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 2
    }
    catch {
        throw "Stop-OdmTask failed for running task: $($_.Exception.Message)"
    }
}

function Remove-LiveTask {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Task
    )

    try {
        Remove-OdmTask -Tasks @($Task) -Confirm $false -ErrorAction Stop
    }
    catch {
        throw "Remove-OdmTask failed: $($_.Exception.Message)"
    }
}

# Validate CSV path
if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV file not found: $CsvPath"
}

# Load module
if (-not (Get-Module -ListAvailable -Name 'OdmApi')) {
    throw "OdmApi module not found. Install with: Install-Module OdmApi -Repository PSGallery"
}

Import-Module OdmApi -ErrorAction Stop

Require-Cmdlet -Name 'Connect-OdmService'
Require-Cmdlet -Name 'Select-OdmOrganization'
Require-Cmdlet -Name 'Get-OdmProject'
Require-Cmdlet -Name 'Select-OdmProject'
Require-Cmdlet -Name 'Get-OdmTask'
Require-Cmdlet -Name 'Remove-OdmTask'

$stopCmd = Get-Command Stop-OdmTask -ErrorAction SilentlyContinue
$canStop = $null -ne $stopCmd

# Connect
$regionNormalized = $Region.ToLowerInvariant()
Connect-OdmService -Region $regionNormalized
Select-OdmOrganization -OrganizationId $OrganizationId

# Read CSV
$csvRows = @(Import-Csv -LiteralPath $CsvPath)
if ($csvRows.Count -eq 0) {
    throw "CSV is empty: $CsvPath"
}

foreach ($requiredColumn in @('TaskName','ProjectId')) {
    if (-not ($csvRows[0].PSObject.Properties.Name -contains $requiredColumn)) {
        throw "CSV must contain a '$requiredColumn' column."
    }
}

# Build live project index
$projects = @(Get-AllProjects | Where-Object { $null -ne $_ })
if ($projects.Count -eq 0) {
    throw "No projects found for OrganizationId $OrganizationId"
}

$projectIndex = @{}
foreach ($project in $projects) {
    $projectIdValue = Normalize-Text (Get-PropValue -Obj $project -Names @('Id','ID','ProjectId'))
    if (-not [string]::IsNullOrWhiteSpace($projectIdValue) -and -not $projectIndex.ContainsKey($projectIdValue)) {
        $projectIndex[$projectIdValue] = $project
    }
}

# Group requested rows by project to avoid repeated task reads
$groupedRows = $csvRows |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace((Normalize-Text $_.TaskName)) -and
        -not [string]::IsNullOrWhiteSpace((Normalize-Text $_.ProjectId))
    } |
    Group-Object -Property ProjectId

$results = @()
$groupCounter = 0

foreach ($group in $groupedRows) {
    $groupCounter++

    $requestedProjectId = Normalize-Text $group.Name
    $project = $projectIndex[$requestedProjectId]

    if ($null -eq $project) {
        foreach ($row in $group.Group) {
            $results += [pscustomobject]@{
                RequestedTaskName    = Normalize-Text $row.TaskName
                RequestedProjectName = Normalize-Text $row.ProjectName
                RequestedProjectId   = $requestedProjectId
                TaskName             = $null
                TaskId               = $null
                LiveProjectName      = $null
                Status               = $null
                Result               = 'NotFound'
                Error                = 'ProjectId not found in live ODM projects'
            }
        }
        continue
    }

    $liveProjectName = Normalize-Text (Get-PropValue -Obj $project -Names @('Name','ProjectName'))
    if ([string]::IsNullOrWhiteSpace($liveProjectName)) {
        $liveProjectName = $requestedProjectId
    }

    Write-Progress -Activity 'Removing ODM tasks' `
        -Status "Project $groupCounter/$($groupedRows.Count): $liveProjectName" `
        -PercentComplete ([int](($groupCounter / [Math]::Max(1, $groupedRows.Count)) * 100))

    try {
        Select-ProjectContext -Project $project
        $projectTasks = @(Get-TasksForCurrentProject)
    }
    catch {
        foreach ($row in $group.Group) {
            $results += [pscustomobject]@{
                RequestedTaskName    = Normalize-Text $row.TaskName
                RequestedProjectName = Normalize-Text $row.ProjectName
                RequestedProjectId   = $requestedProjectId
                TaskName             = $null
                TaskId               = $null
                LiveProjectName      = $liveProjectName
                Status               = $null
                Result               = 'Failed'
                Error                = "Could not load tasks for project context: $($_.Exception.Message)"
            }
        }
        continue
    }

    foreach ($row in $group.Group) {
        $requestedTaskName = Normalize-Text $row.TaskName
        $requestedTaskId   = if ($row.PSObject.Properties.Name -contains 'TaskId') { Normalize-Text $row.TaskId } else { '' }

        $matches = @(
            $projectTasks | Where-Object {
                $liveTaskName = Normalize-Text (Get-PropValue -Obj $_ -Names @('Name','TaskName','DisplayName'))
                $liveTaskId   = Normalize-Text (Get-PropValue -Obj $_ -Names @('Id','ID','TaskId','TaskID'))

                if (-not [string]::IsNullOrWhiteSpace($requestedTaskId)) {
                    return $liveTaskId -eq $requestedTaskId
                }

                return $liveTaskName -eq $requestedTaskName
            }
        )

        if ($matches.Count -eq 0) {
            $results += [pscustomobject]@{
                RequestedTaskName    = $requestedTaskName
                RequestedProjectName = Normalize-Text $row.ProjectName
                RequestedProjectId   = $requestedProjectId
                TaskName             = $null
                TaskId               = $requestedTaskId
                LiveProjectName      = $liveProjectName
                Status               = $null
                Result               = 'NotFound'
                Error                = 'No live ODM task matched in the selected project context'
            }
            continue
        }

        foreach ($task in $matches) {
            $taskName = Normalize-Text (Get-PropValue -Obj $task -Names @('Name','TaskName','DisplayName'))
            $taskId   = Normalize-Text (Get-PropValue -Obj $task -Names @('Id','ID','TaskId','TaskID'))
            $status   = Normalize-Text (Get-PropValue -Obj $task -Names @('Status','State'))

            $target = "TaskName='$taskName' | Project='$liveProjectName' | TaskId='$taskId'"

            try {
                if ($PSCmdlet.ShouldProcess($target, 'Remove-OdmTask')) {
                    if ($canStop) {
                        Stop-TaskIfRunning -Task $task
                    }

                    # Re-select the project immediately before delete.
                    # Remove-OdmTask deletes against the current ODM project context.
                    Select-ProjectContext -Project $project
                    Remove-LiveTask -Task $task

                    $results += [pscustomobject]@{
                        RequestedTaskName    = $requestedTaskName
                        RequestedProjectName = Normalize-Text $row.ProjectName
                        RequestedProjectId   = $requestedProjectId
                        TaskName             = $taskName
                        TaskId               = $taskId
                        LiveProjectName      = $liveProjectName
                        Status               = $status
                        Result               = 'Removed'
                        Error                = $null
                    }

                    # Prevent duplicate processing within the in-memory task list
                    $projectTasks = @(
                        $projectTasks | Where-Object {
                            (Normalize-Text (Get-PropValue -Obj $_ -Names @('Id','ID','TaskId','TaskID'))) -ne $taskId
                        }
                    )

                    Write-Host "Removed: $taskName [$taskId]" -ForegroundColor Green
                }
                else {
                    $results += [pscustomobject]@{
                        RequestedTaskName    = $requestedTaskName
                        RequestedProjectName = Normalize-Text $row.ProjectName
                        RequestedProjectId   = $requestedProjectId
                        TaskName             = $taskName
                        TaskId               = $taskId
                        LiveProjectName      = $liveProjectName
                        Status               = $status
                        Result               = 'Skipped'
                        Error                = 'ShouldProcess declined'
                    }
                }
            }
            catch {
                $results += [pscustomobject]@{
                    RequestedTaskName    = $requestedTaskName
                    RequestedProjectName = Normalize-Text $row.ProjectName
                    RequestedProjectId   = $requestedProjectId
                    TaskName             = $taskName
                    TaskId               = $taskId
                    LiveProjectName      = $liveProjectName
                    Status               = $status
                    Result               = 'Failed'
                    Error                = $_.Exception.Message
                }

                Write-Warning "Failed to remove task '$taskName' [$taskId] in project '$liveProjectName' : $($_.Exception.Message)"
            }
        }
    }
}

Write-Progress -Activity 'Removing ODM tasks' -Completed

$resultsPath = [System.IO.Path]::ChangeExtension($CsvPath, '.delete-results.csv')
$results |
    Sort-Object RequestedProjectId, RequestedTaskName, TaskId |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $resultsPath

$removed  = @($results | Where-Object Result -eq 'Removed').Count
$failed   = @($results | Where-Object Result -eq 'Failed').Count
$skipped  = @($results | Where-Object Result -eq 'Skipped').Count
$notFound = @($results | Where-Object Result -eq 'NotFound').Count

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host '-------'
Write-Host "Removed  : $removed"
Write-Host "Failed   : $failed"
Write-Host "Skipped  : $skipped"
Write-Host "NotFound : $notFound"
Write-Host "Results  : $resultsPath"
