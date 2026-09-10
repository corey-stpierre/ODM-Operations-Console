<#
.SYNOPSIS
Remove Quest ODM for 365 tasks from CSV using project context.

.DESCRIPTION
- Reads a CSV with TaskName, ProjectName, and ProjectId
- Connects to Quest ODM
- Selects the project for each row
- Optionally selects workload if possible
- Gets tasks within that project context
- Matches by exact TaskName
- Removes the matching live task
- Writes a results CSV

.NOTES
- Best run in Windows PowerShell 5.1
- If started in PowerShell 7+, it relaunches in powershell.exe
- Assumes these are mail migration tasks unless a Workload column is supplied
- Suppresses per-task confirmation from Remove-OdmTask itself

.CSV FORMAT
TaskName,ProjectName,ProjectId
AB01 - Email Sync,SRCL to WM,6T9sNpcB5WJXsN2w05Wk
AB02 - Email Sync,SRCL to WM,6T9sNpcB5WJXsN2w05Wk

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
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $env:ODM_RELAUNCHED_DELETE_BY_CONTEXT) {
    $env:ODM_RELAUNCHED_DELETE_BY_CONTEXT = "1"

    $argsForWinPS = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-Region", $Region,
        "-OrganizationId", $OrganizationId.ToString(),
        "-CsvPath", $CsvPath
    )

    if ($WhatIfPreference) {
        $argsForWinPS += "-WhatIf"
    }

    if ($PSBoundParameters.ContainsKey('Confirm') -and $ConfirmPreference -eq 'None') {
        $argsForWinPS += "-Confirm:`$false"
    }

    Write-Host "Detected PowerShell $($PSVersionTable.PSVersion). Relaunching in Windows PowerShell..." -ForegroundColor Yellow
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argsForWinPS -Wait -PassThru
    exit $p.ExitCode
}

function Require-Cmdlet {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing cmdlet '$Name'. Ensure the OdmApi module is installed/imported."
    }
}

function Normalize-Text {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return "" }
    return (($Value.ToString() -replace '\s+', ' ').Trim())
}

function Get-PropValue {
    param(
        [Parameter(Mandatory = $true)][object]$Obj,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Obj) { return $null }

    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($null -ne $p) {
            return $p.Value
        }

        try {
            $v = $Obj.$n
            if ($null -ne $v) { return $v }
        }
        catch {}
    }

    return $null
}

function Get-AllProjects {
    $cmd = Get-Command Get-OdmProject -ErrorAction Stop
    if ($cmd.Parameters.ContainsKey("All")) {
        return @(Get-OdmProject -All)
    }
    return @(Get-OdmProject)
}

function Select-ProjectContext {
    param(
        [Parameter(Mandatory = $true)][object]$Project,
        [Parameter(Mandatory = $false)][string]$Workload
    )

    $selectProjectCmd = Get-Command Select-OdmProject -ErrorAction Stop
    $projectId = Get-PropValue -Obj $Project -Names @("Id","ID","ProjectId")

    if ($selectProjectCmd.Parameters.ContainsKey("Project")) {
        Select-OdmProject -Project $Project | Out-Null
    }
    elseif ($selectProjectCmd.Parameters.ContainsKey("ProjectId")) {
        Select-OdmProject -ProjectId $projectId | Out-Null
    }
    else {
        $Project | Select-OdmProject | Out-Null
    }

    $workloadCmd = Get-Command Select-OdmProjectWorkload -ErrorAction SilentlyContinue
    if ($null -eq $workloadCmd) { return }

    if ([string]::IsNullOrWhiteSpace($Workload)) { return }

    try {
        if ($workloadCmd.Parameters.ContainsKey("Workload")) {
            Select-OdmProjectWorkload -Workload $Workload | Out-Null
            return
        }

        if ($workloadCmd.Parameters.ContainsKey("Name")) {
            Select-OdmProjectWorkload -Name $Workload | Out-Null
            return
        }
    }
    catch {
        Write-Warning "Could not select workload '$Workload'. Continuing without explicit workload selection."
    }
}

function Get-TasksInCurrentContext {
    $cmd = Get-Command Get-OdmTask -ErrorAction Stop

    try {
        if ($cmd.Parameters.ContainsKey("All")) {
            return @(Get-OdmTask -All)
        }
        return @(Get-OdmTask)
    }
    catch {
        throw "Failed to retrieve tasks in current project context: $($_.Exception.Message)"
    }
}

function Remove-LiveTask {
    param([Parameter(Mandatory = $true)][object]$Task)

    try {
        $null = $Task | Remove-OdmTask -Confirm:$false -ErrorAction Stop
    }
    catch {
        throw "Remove-OdmTask failed: $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV file not found: $CsvPath"
}

if (-not (Get-Module -ListAvailable -Name "OdmApi")) {
    throw "OdmApi module not found. Install with: Install-Module OdmApi -Scope CurrentUser"
}

Import-Module OdmApi -ErrorAction Stop

Require-Cmdlet -Name "Connect-OdmService"
Require-Cmdlet -Name "Select-OdmOrganization"
Require-Cmdlet -Name "Get-OdmProject"
Require-Cmdlet -Name "Select-OdmProject"
Require-Cmdlet -Name "Get-OdmTask"
Require-Cmdlet -Name "Remove-OdmTask"

$regionNorm = $Region.ToLowerInvariant()
Connect-OdmService -Region $regionNorm
Select-OdmOrganization -OrganizationId $OrganizationId

$csvRows = @(Import-Csv -LiteralPath $CsvPath)
if ($csvRows.Count -eq 0) {
    throw "CSV is empty: $CsvPath"
}

foreach ($required in @("TaskName","ProjectId")) {
    if (-not ($csvRows[0].PSObject.Properties.Name -contains $required)) {
        throw "CSV must contain a '$required' column."
    }
}

$projects = @(Get-AllProjects | Where-Object { $null -ne $_ })
if ($projects.Count -eq 0) {
    throw "No projects found for OrganizationId $OrganizationId"
}

$projectIndex = @{}
foreach ($project in $projects) {
    $pid = Normalize-Text (Get-PropValue -Obj $project -Names @("Id","ID","ProjectId"))
    if (-not [string]::IsNullOrWhiteSpace($pid) -and -not $projectIndex.ContainsKey($pid)) {
        $projectIndex[$pid] = $project
    }
}

$results = @()
$counter = 0
$total = $csvRows.Count

foreach ($row in $csvRows) {
    $counter++

    $requestedTaskName = Normalize-Text $row.TaskName
    $requestedProjectName = Normalize-Text $row.ProjectName
    $requestedProjectId = Normalize-Text $row.ProjectId
    $requestedWorkload = Normalize-Text $row.Workload

    if ([string]::IsNullOrWhiteSpace($requestedWorkload)) {
        $requestedWorkload = "Mail"
    }

    Write-Progress -Activity "Removing ODM tasks" `
        -Status "Processing $counter/$total : $requestedTaskName" `
        -PercentComplete ([int](($counter / [Math]::Max(1, $total)) * 100))

    if ([string]::IsNullOrWhiteSpace($requestedTaskName) -or [string]::IsNullOrWhiteSpace($requestedProjectId)) {
        $results += [pscustomobject]@{
            RequestedTaskName   = $requestedTaskName
            RequestedProjectId  = $requestedProjectId
            RequestedProjectName= $requestedProjectName
            TaskId              = $null
            Result              = "Failed"
            Error               = "Row is missing TaskName or ProjectId"
        }
        continue
    }

    if (-not $projectIndex.ContainsKey($requestedProjectId)) {
        $results += [pscustomobject]@{
            RequestedTaskName    = $requestedTaskName
            RequestedProjectId   = $requestedProjectId
            RequestedProjectName = $requestedProjectName
            TaskId               = $null
            Result               = "NotFound"
            Error                = "ProjectId not found in live ODM projects"
        }
        Write-Warning "ProjectId '$requestedProjectId' not found for task '$requestedTaskName'"
        continue
    }

    $project = $projectIndex[$requestedProjectId]
    $liveProjectName = Normalize-Text (Get-PropValue -Obj $project -Names @("Name","ProjectName"))

    try {
        Select-ProjectContext -Project $project -Workload $requestedWorkload
        $contextTasks = @(Get-TasksInCurrentContext)
    }
    catch {
        $results += [pscustomobject]@{
            RequestedTaskName    = $requestedTaskName
            RequestedProjectId   = $requestedProjectId
            RequestedProjectName = $requestedProjectName
            TaskId               = $null
            Result               = "Failed"
            Error                = $_.Exception.Message
        }
        Write-Warning "Failed to load tasks for project '$liveProjectName': $($_.Exception.Message)"
        continue
    }

    $matches = @(
        $contextTasks | Where-Object {
            (Normalize-Text (Get-PropValue -Obj $_ -Names @("Name","TaskName","DisplayName"))) -eq $requestedTaskName
        }
    )

    if ($matches.Count -eq 0) {
        $results += [pscustomobject]@{
            RequestedTaskName    = $requestedTaskName
            RequestedProjectId   = $requestedProjectId
            RequestedProjectName = $requestedProjectName
            TaskId               = $null
            Result               = "NotFound"
            Error                = "No live task matched TaskName in selected project context"
        }
        Write-Warning "No live task matched '$requestedTaskName' in project '$liveProjectName'"
        continue
    }

    foreach ($task in $matches) {
        $taskName = Normalize-Text (Get-PropValue -Obj $task -Names @("Name","TaskName","DisplayName"))
        $taskId = Normalize-Text (Get-PropValue -Obj $task -Names @("Id","ID","TaskId","TaskID"))
        $taskStatus = Normalize-Text (Get-PropValue -Obj $task -Names @("Status","State"))

        $target = "TaskName='$taskName' | Project='$liveProjectName' | TaskId='$taskId'"

        try {
            if ($PSCmdlet.ShouldProcess($target, "Remove-OdmTask")) {
                Remove-LiveTask -Task $task

                $results += [pscustomobject]@{
                    RequestedTaskName    = $requestedTaskName
                    RequestedProjectId   = $requestedProjectId
                    RequestedProjectName = $requestedProjectName
                    LiveProjectName      = $liveProjectName
                    TaskName             = $taskName
                    TaskId               = $taskId
                    Status               = $taskStatus
                    Result               = "Removed"
                    Error                = $null
                }

                Write-Host "Removed: $taskName [$taskId]" -ForegroundColor Green
            }
            else {
                $results += [pscustomobject]@{
                    RequestedTaskName    = $requestedTaskName
                    RequestedProjectId   = $requestedProjectId
                    RequestedProjectName = $requestedProjectName
                    LiveProjectName      = $liveProjectName
                    TaskName             = $taskName
                    TaskId               = $taskId
                    Status               = $taskStatus
                    Result               = "Skipped"
                    Error                = "ShouldProcess declined"
                }
            }
        }
        catch {
            $results += [pscustomobject]@{
                RequestedTaskName    = $requestedTaskName
                RequestedProjectId   = $requestedProjectId
                RequestedProjectName = $requestedProjectName
                LiveProjectName      = $liveProjectName
                TaskName             = $taskName
                TaskId               = $taskId
                Status               = $taskStatus
                Result               = "Failed"
                Error                = $_.Exception.Message
            }

            Write-Warning "Failed to remove task '$taskName' [$taskId] in project '$liveProjectName' : $($_.Exception.Message)"
        }
    }
}

Write-Progress -Activity "Removing ODM tasks" -Completed

$resultsPath = [System.IO.Path]::ChangeExtension($CsvPath, ".delete-results.csv")
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $resultsPath

$removed  = @($results | Where-Object Result -eq "Removed").Count
$failed   = @($results | Where-Object Result -eq "Failed").Count
$skipped  = @($results | Where-Object Result -eq "Skipped").Count
$notFound = @($results | Where-Object Result -eq "NotFound").Count

Write-Host ""
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "-------"
Write-Host "Removed  : $removed"
Write-Host "Failed   : $failed"
Write-Host "Skipped  : $skipped"
Write-Host "NotFound : $notFound"
Write-Host "Results  : $resultsPath"