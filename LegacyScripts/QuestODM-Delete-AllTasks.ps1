using module OdmApi
<#
QuestODM-Delete-AllTasks.ps1

Deletes all ODM tasks in the selected project/workload context.

SAFE DEFAULT:
- Dry-run unless -Execute is specified.
- Exports the task list before deleting.
- Exports deletion results.

Requirements:
- Windows PowerShell 5.1
- OdmApi module
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("US","EU","AU","CA","UK","us","eu","au","ca","uk")]
  [string]$Region,

  [Parameter(Mandatory)]
  [string]$OrganizationId,

  [Parameter(Mandatory)]
  [string]$ProjectId,

  # Use the Accounts workload id you have been using:
  # Example: PROJECT_ID_HERE
  [Parameter(Mandatory)]
  [string]$AccountsProjectWorkloadId,

  # Dry-run by default. Add -Execute to actually delete.
  [switch]$Execute,

  # Optional safety: require this exact text when using -Execute
  [string]$ConfirmText,

  [string]$OutDir = "C:\Temp\ODM_Reports",

  [int]$BatchSize = 500
)

function Get-SafeProp {
  param(
    $Obj,
    [string]$Name
  )

  if ($Obj -and ($Obj.PSObject.Properties.Name -contains $Name)) {
    return $Obj.$Name
  }

  return $null
}

# -----------------------------
# Preflight
# -----------------------------
if ($PSVersionTable.PSVersion.Major -ne 5) {
  throw "Run this in Windows PowerShell 5.1."
}

if (-not (Get-Command Remove-OdmTask -ErrorAction SilentlyContinue)) {
  throw "Remove-OdmTask not found. Verify OdmApi is loaded correctly."
}

if (-not (Test-Path $OutDir)) {
  New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
}

if ($Execute -and $ConfirmText -ne "DELETE ALL ODM TASKS") {
  throw "To execute deletion, pass: -ConfirmText 'DELETE ALL ODM TASKS'"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$preDeletePath = Join-Path $OutDir "ODM_Tasks_PreDelete_$stamp.csv"
$resultPath    = Join-Path $OutDir "ODM_Tasks_DeleteResults_$stamp.csv"

# -----------------------------
# Connect + context
# -----------------------------
Connect-OdmService -Region $Region.ToLower() | Out-Null
Select-OdmOrganization -OrganizationId $OrganizationId | Out-Null

$project = Get-OdmProject | Where-Object { $_.Id -eq $ProjectId } | Select-Object -First 1
if (-not $project) {
  throw "Project with Id '$ProjectId' not found."
}

Select-OdmProjectWorkload -ProjectWorkloadId $AccountsProjectWorkloadId | Out-Null

# -----------------------------
# Load all tasks
# -----------------------------
Write-Host "Loading ODM tasks..." -ForegroundColor Cyan

$tasks = @()
try {
  $tasks = @(Get-OdmTask -All)
}
catch {
  $tasks = @(Get-OdmTask)
}

if (-not $tasks -or $tasks.Count -eq 0) {
  Write-Host "No tasks found. Nothing to delete." -ForegroundColor Yellow
  return
}

Write-Host "Tasks found: $($tasks.Count)" -ForegroundColor Yellow

# -----------------------------
# Export pre-delete task list
# -----------------------------
$preDeleteRows = foreach ($t in $tasks) {
  [pscustomobject]@{
    TaskName   = $t.Name
    TaskId     = $t.Id
    Type       = (Get-SafeProp -Obj $t -Name "Type")
    TaskType   = (Get-SafeProp -Obj $t -Name "TaskType")
    Context    = (Get-SafeProp -Obj $t -Name "Context")
    Category   = (Get-SafeProp -Obj $t -Name "Category")
    Status     = (Get-SafeProp -Obj $t -Name "Status")
    Run        = (Get-SafeProp -Obj $t -Name "Run")
    Created    = (Get-SafeProp -Obj $t -Name "Created")
    CreatedAt  = (Get-SafeProp -Obj $t -Name "CreatedAt")
    ProjectId  = (Get-SafeProp -Obj $t -Name "ProjectId")
  }
}

$preDeleteRows |
  Sort-Object TaskName |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path $preDeletePath

Write-Host "Pre-delete task inventory exported:" -ForegroundColor Green
Write-Host "  $preDeletePath"

if (-not $Execute) {
  Write-Host ""
  Write-Host "DRY-RUN ONLY. No tasks were deleted." -ForegroundColor Cyan
  Write-Host "To actually delete all tasks, rerun with:" -ForegroundColor Cyan
  Write-Host "  -Execute -ConfirmText 'DELETE ALL ODM TASKS'" -ForegroundColor Cyan
  return
}

# -----------------------------
# Delete tasks in batches
# -----------------------------
Write-Host ""
Write-Host "EXECUTE MODE: deleting all tasks..." -ForegroundColor Red

$results = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $tasks.Count; $i += $BatchSize) {
  $end = [Math]::Min($i + $BatchSize - 1, $tasks.Count - 1)
  $batch = @($tasks[$i..$end])

  Write-Host ("Deleting batch {0}-{1} of {2}..." -f ($i + 1), ($end + 1), $tasks.Count)

  try {
    Remove-OdmTask -Tasks $batch -Confirm:$false

    foreach ($t in $batch) {
      $results.Add([pscustomobject]@{
        TaskName = $t.Name
        TaskId   = $t.Id
        Status   = "DELETED"
        Details  = "Deleted successfully"
      }) | Out-Null
    }
  }
  catch {
    $err = $_.Exception.Message

    foreach ($t in $batch) {
      $results.Add([pscustomobject]@{
        TaskName = $t.Name
        TaskId   = $t.Id
        Status   = "FAILED"
        Details  = $err
      }) | Out-Null
    }

    Write-Warning "Batch failed: $err"
  }
}

$results |
  Sort-Object Status, TaskName |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path $resultPath

Write-Host ""
Write-Host "Deletion results exported:" -ForegroundColor Green
Write-Host "  $resultPath"

$deleted = @($results | Where-Object { $_.Status -eq "DELETED" }).Count
$failed  = @($results | Where-Object { $_.Status -eq "FAILED" }).Count

Write-Host ""
Write-Host "Deleted: $deleted" -ForegroundColor Green
Write-Host "Failed:  $failed" -ForegroundColor Yellow